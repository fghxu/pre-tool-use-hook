# AST-as-Arbiter: Safe PowerShell Expression Handling — Design Spec

**Date:** 2026-07-18 (revised after implementation review)
**Status:** Approved — implemented (branch `ast-arbiter`, all suites byte-identical to baseline + new-samples 14/14)
**Depends on:** `2026-05-15-architecture-design.md`, `2026-07-13-parameter-commands-and-editable-paths-design.md`
**Implementation base:** `fix-var-assignment-detection` branch (NOT `ClaudeCode-v1` — see §1.3)

---

## 1. Problem

### 1.1 Observed failures

Real-world log samples (14 cases in `test/test-cases.new-samples.xml`) are misclassified as `ask` with reason `unknown command: ...` even though they are legitimate read-only commands. All parse successfully with `System.Management.Automation.Language.Parser`.

### 1.2 Two root causes

1. **Downstream:** When PowerShell-shaped input *does* reach the AST path, the extraction logic (a) treats quoted parameter values (regex strings with `|`) as fake commands, (b) has no handling for the `& { ... }` call-operator, and (c) has no certification for pure expressions (assignments, hashtables, .NET reads), so zero-command inputs fall back to regex splitting.

2. **Upstream (the blind spot):** `Get-CommandDomain` is a regex heuristic bolted onto the front of the pipeline. Every downstream fix is hostage to it. Tracing the target cases through the current branch shows **6 of 10 never reach the PowerShell AST path at all**:

| Case | Detected domain | Reaches PS AST path? |
|---|---|---|
| `Select-String -Pattern "a\|b" \| ...` | powershell | ✅ |
| `$line -replace 'a\|b', { ... }` | powershell (via `$_` marker) | ✅ |
| `& { Get-Content ... }` | **linux** (`&` start, no marker) | ❌ |
| `$log -split "\`n" \| Select-Object` | **linux** (`Select-Object` is not a marker) | ❌ |
| `$headers = @{ ... }` / bare `@{ ... }` | **linux** (`@{` is not a marker; only `@(` is) | ❌ |
| `$raw = [System.IO.File]::ReadAllText(...)` | **linux** (after assignment strip, `[System...` matches nothing) | ❌ |
| `$key='...'; ssh ... 'whoami;hostname'` | **linux**; `$key='...'` segment → unknown | ❌ |
| `aws --version; Get-Content $file` | aws_cli; Step 0e strips `--version` *before* the explicit `aws --version` read_only entry is checked → bare `aws` → unknown | ❌ (resolver ordering bug) |
| `$arr = 1, 2, @(3, 4)` | powershell (via `@(` marker) | ✅ |
| `git tag -a ... ; git log ...` (expected **ask**) | git | n/a |

Enriching the marker list (`^\$`, `^@{`, `& {`, `::`, …) is permanent whack-a-mole and risks misrouting bash lines that look PowerShell-ish.

### 1.3 Stale-base lesson

A first implementation attempt was built on `ClaudeCode-v1` (0c6954f) and produced phantom regressions (e.g., curl test 208) because that base lacks `parameter_commands` and its unanchored Verb-Noun regex is accidentally load-bearing. **All work for this feature must target `fix-var-assignment-detection`**, which has the anchored regex, Step 7 parameter_commands, and `editable_paths`.

## 2. Goals / Non-Goals

**Goals**
- One arbitration point that classifies *any* line the primary pipeline can only reject as "unknown command", using the real PowerShell AST as arbiter.
- Fix the downstream AST-path gaps (string heuristic, call-operator, pure expressions) since they remain the primary path for powershell-detected lines.
- Fix the `aws --version` resolver ordering bug.
- Provably zero behavior change for every line that currently resolves to a known decision (see §4, Regression Safety).

**Non-Goals**
- No new domain-detection markers; routing regexes are left untouched.
- No blanket "pipe is read-only" rule; pipes are operators, only elements are classified.
- No expression-aware handling for Linux/DOS parsing.
- v1 does not *improve ask reasons* for lines where arbitration finds known-modifying commands (it simply keeps the original ask). Reason improvement is future work.

## 3. Design

### 3.0 Core mechanism: AST-as-arbiter fallback

**Placement:** `Classifier.ps1::Invoke-Classify`, after the existing aggregation computes `$blockingCommands`, before returning the ask result.

**Activation (both must hold):**
1. `$blockingCommands.Count -gt 0`, and
2. **Every** blocking sub-result has `MatchedPattern -eq $null` — i.e., the ask comes *only* from the Step 3 "unknown command" fallback, never from a recognized modifying rule and never from a redirection block (`redirection-target`).

When active, run `Invoke-PowerShellArbitration -Command $command -Config $Config`:

```
parse the WHOLE original line with PS AST
  → parse errors?                       → NOT conclusive (keep original ask)
  → Begin/Process blocks present?       → NOT conclusive
for each top-level statement in EndBlock.Statements:
  cmdAsts = statement.FindAll(CommandAst)
  for each cmdAst:
    verdict = Resolve-AsArbiter(cmdAst)          # see 3.0.2
    if verdict is not ALLOW           → NOT conclusive
    add cmdAst.Extent.Text to allowedCommands
for each top-level statement:
  if not Test-SafeAst(statement, allowedCommands) → NOT conclusive
return CONCLUSIVE-ALLOW
```

If conclusive: return `allow`, reason `read-only (PowerShell AST arbitration)`. Otherwise: fall through to the **unchanged** original ask path with original reasons.

#### 3.0.1 Resolve-AsArbiter(cmdAst)

- **Call-operator:** `InvocationOperator` is `Ampersand`/`Dot` and the element list is a single `ScriptBlockExpressionAst` → recursively apply the arbitration statement-loop to the scriptblock's statements. ALLOW iff all inner statements are conclusive-allow.
- Try `Resolve-Command(cmdAst.Extent.Text)` → `allow` ⇒ ALLOW.
- Else try wrapper/nested extraction on the command text (`Get-AstWrapperInnerCommands`, `Find-NestedCommands`, `Split-SubshellCommands`). If inner commands are extracted, the wrapper is *explained by its children* (mirrors the existing parent-filter semantics): ALLOW iff every extracted inner command recursively resolves ALLOW.
- Otherwise → not ALLOW.

This makes `ssh -i $key -o X -o Y user@server 'whoami;hostname'` conclusive: the wrapper itself has no config entry (unknown), but its inner commands (`whoami`, `hostname`) resolve allow, so the wrapper is ALLOW.

#### 3.0.2 Test-SafeAst(statement, allowedCommands) — shared certification

Used by the arbiter and by the primary-path safe-expression fallback (§3.3). Walks the statement subtree:

| Node | Safe when |
|---|---|
| `AssignmentStatementAst` | LHS is a `VariableExpressionAst` (or index/array of one) **and** RHS is safe. (LHS like `[Console]::Title` — a `MemberExpressionAst` on a type — is a property **set** with side effects ⇒ unsafe.) |
| `HashtableAst`, `ArrayLiteralAst`, `ParenExpressionAst`, `ArrayExpressionAst`, `SubExpressionAst` | all children safe |
| `StatementBlockAst` (body of `@(...)`, scriptblocks) | all statements safe |
| `StringConstantExpressionAst`, `ExpandableStringExpressionAst` (nested exprs safe), `VariableExpressionAst`, `ConstantExpressionAst`, `TypeExpressionAst` | always |
| `MemberExpressionAst` (property **read**: `$x.Length`, `[Math]::PI`) | target is safe |
| `InvokeMemberExpressionAst` (`.NET method call`) | target safe **and** method name ∈ `safe_expressions.dotnet_method_allowlist` (config, §3.6) **and** all arguments safe. `[System.IO.File]::Delete(...)` / `$proc.Kill()` are **not** on the list ⇒ unsafe ⇒ ask. |
| `BinaryExpressionAst`, `UnaryExpressionAst` | operands safe |
| `CommandAst` | its `Extent.Text` ∈ `allowedCommands` (already resolved ALLOW by 3.0.1); otherwise unsafe |
| `ScriptBlockAst` / `ScriptBlockExpressionAst` | all body statements safe (recursive; covers `-replace` operator scriptblocks like `{ $_.Value -replace 'BC','PC' }`) |
| `FileRedirectionAst` (`>`, `>>` anywhere in subtree) | **never** safe (writes a file; leave it to `Test-RedirectionTarget`) |
| anything unrecognized | unsafe |

### 3.1 Primary path: fix string-constant extraction heuristic

In `Parser.ps1::Get-AstCommands` section 4, a `StringConstantExpressionAst` is currently treated as command-like whenever it contains `[;&|]` or a newline — so `-Pattern 'a|b'` is extracted as a fake Linux command.

**Change:** treat a string constant as command-like only if
- it is a top-level statement (its parent is `CommandExpressionAst` whose parent is `PipelineAst`/`NamedBlockAst`) **and** it contains a separator/newline **and** a word pair; or
- it starts with a known command prefix (`aws|docker|kubectl|...`; existing branch, unchanged).

### 3.2 Primary path: call-operator `& { ... }`

In `Get-AstCommands`: skip the outer `CommandAst` when `InvocationOperator -eq 'Ampersand'` and its single element is a `ScriptBlockExpressionAst` (inner commands are already found by the `ScriptBlockAst` recursion). In `Get-AstWrapperInnerCommands`: safety-net — any `CommandAst` whose first element is a `ScriptBlockExpressionAst` yields the scriptblock body as an inner `powershell` command.

### 3.3 Primary path: safe-expression fallback (zero-command lines)

When domain is `powershell` and `Get-PowerShellCommands` returns 0 commands, run `Get-PowerShellSafeExpressions`: parse, and if every top-level statement passes `Test-SafeAst` (§3.0.2, empty allowedCommands), emit one synthetic sub-command `'(safe expression)'`; `Resolve-Command` returns `allow` for that marker immediately. Covers `$arr = 1, 2, @(3, 4)` and similar on the primary path. If any statement is unsafe → no synthetic commands → existing regex fallback (fail-safe).

### 3.4 Resolver: `aws --version` ordering fix

Step 0e (normal-mode AWS flag stripping) currently strips `aws --version` down to bare `aws`, which then falls through to `unknown`. **Change:** only apply the stripped result if it still contains ≥2 tokens (a service and an operation). If stripping would leave bare `aws`, keep the original command so the explicit `aws --version` read_only entry (Step 1a) can match.

### 3.5 Config: AWS configure read-only entries

```json
{ "name": "aws configure get",  "patterns": ["^aws\\s+configure\\s+get\\b"],  "description": "Read an AWS configure value" },
{ "name": "aws configure list", "patterns": ["^aws\\s+configure\\s+list\\b"], "description": "List AWS configure values" }
```

### 3.6 Config: `safe_expressions`

```jsonc
"safe_expressions": {
  "description": "Allowlist for the safe-expression certifier (arbiter + zero-command fallback).",
  "dotnet_method_allowlist": [
    "ReadAllText", "ReadAllLines", "ReadLines", "OpenRead",
    "Substring", "Split", "Replace", "ToString", "ToUpper", "ToLower",
    "Trim", "TrimStart", "TrimEnd", "Contains", "StartsWith", "EndsWith",
    "IndexOf", "LastIndexOf", "PadLeft", "PadRight",
    "Max", "Min", "Abs", "Round", "Floor", "Ceiling", "Sqrt", "Pow",
    "Compare", "Equals", "GetHashCode", "GetType"
  ]
}
```

ConfigLoader: optional; defaults to this list when absent. Method names matched case-insensitively.

## 4. Regression Safety

### 4.1 Structural guarantee

The arbiter activates only when the final decision is `ask` **and** every blocker is the unknown-fallback. Therefore:

| Existing test class | Resolves via | Arbiter runs? |
|---|---|---|
| Expected **allow** | known patterns/verbs/parameter_commands | No (no blockers) |
| Expected **ask**, known modifying (`rm`, `git push`, `curl -X POST`, redirect to system path, …) | matched pattern (non-null) | No |
| Expected **ask**, unknown (`git --online -3`) | Step 3 fallback | Yes — must stay ask (see 4.2) |

The only existing outcomes the arbiter can touch are unknown-asks, and it can only convert them to allow under full per-statement accounting.

### 4.2 Why unknown-ask tests stay ask

- `git -C C:\repo --online -3` (test 467): parses fine, but `git --online -3` resolves unknown ⇒ not conclusive ⇒ original ask kept.
- Multi-line bash (`for ...; do ...; done`, `case`, heredocs): PowerShell parse errors ⇒ arbiter aborts.
- Any line containing one genuinely unknown command: that command poisons conclusiveness.

A false allow would require a genuinely-modifying command resolving as *known read-only* — a pre-existing config risk identical in today's pipeline; the arbiter adds no new per-command resolution logic.

### 4.3 Negative tests guarding the arbiter (new)

| Command | Expected |
|---|---|
| `git --online -3` | ask |
| `Some-UnknownCmdlet -Foo` | ask |
| `weirdcmd -x \| Get-Process` | ask (one unknown poisons the line) |
| `$x = Invoke-Expression 'evil'` | ask (command inside assignment is never a safe expression) |
| `for f in /etc/*; do weirdcmd $f; done` | ask (bash parse error ⇒ abort) |
| `$x = [System.IO.File]::Delete('c:\temp\x.txt')` | ask (method not in allowlist) |
| `$proc.Kill()` | ask (method not in allowlist) |
| `[Console]::Title = 'x'` | ask (property set = side effect) |
| `echo hi > ..\outside\file.txt` (editable_paths set, normal mode) | ask (redirect blocker has a pattern ⇒ arbiter skipped) |
| `ssh user@host 'rm -rf /tmp/x'` | ask (inner `rm` is known-modifying ⇒ arbiter never runs) |

### 4.4 Empirical proof: differential runs

Acceptance criterion: full matrix **before and after**, byte-identical results on `fix-var-assignment-detection`:

- `test-cases.xml` (467/467), `test-cases.adhoc.xml` (pre-existing cases), `test-cases.redirect-normal.xml`, `test-cases.redirect-strict.xml`, `test-cases.var-assignment.xml`, `test-cases.fullpath.xml`, `test-cases.trustedpattern.xml`, `test/test-fullpipe.xml`
- Any diff ⇒ stop; it is a bug, not a judgment call.
- `test-cases.new-samples.xml` must reach 14/14.

### 4.5 Traceability matrix (14 canonical cases)

| # | Case | Expected | Resolved by |
|---|---|---|---|
| 1 | `$headers = @{'provate-token' = $gittoken}` | allow | arbiter (assignment + hashtable safe) |
| 2 | `$log -split "\`n" \| Select-Object -First 40` | allow | arbiter (safe expr + known-allow cmdlet) |
| 3 | `Invoke-RestMethod -Method Get ...; ($b801log ... \| Select-String ... \| Select-Object ...)` | allow | primary path (powershell domain + §3.1 + IRM `parameter_commands`) |
| 4 | `$key='...'; ssh -i $key -o ... 'whoami;hostname'` | allow | arbiter (assignment safe + ssh wrapper → inner commands allow) |
| 5 | `aws --version; Get-Content $file` | allow | arbiter + §3.4 (`aws --version` reaches explicit read_only) |
| 6 | `@{ authorization = "Basice $encodeed" }` | allow | arbiter (hashtable safe) |
| 7 | `$body = '{"id": "1", ... }'` | allow | arbiter (string assignment safe) |
| 8 | `git tag -a ... ; git log --oneline -3; git tag -l \| Sort-Object \| Select-Object` | **ask** | primary (git domain; `git tag -a` unknown); arbiter not conclusive ⇒ ask kept |
| 9 | `Select-String -Path ... -Pattern "a\|b" \| ForEach-Object ... \| Where-Object ...` | allow | primary path (powershell domain + §3.1) |
| 10 | `Select-String -Pattern '^## \| ^### '` | allow | primary path (§3.1) |
| 11 | `$line = $line -replace 'a\|b', { $_.Value -replace ... }` | allow | primary path (`$_` marker → powershell; zero commands ⇒ §3.3; scriptblock recursively certified) |
| 12 | `& { $json = Get-Content ...; $b = $json \| ConvertFrom-Json; }` | allow | arbiter (call-operator recursion; inner commands allow) |
| 13 | `aws configure get sso_role_name` | allow | primary (§3.5 config) |
| 14 | `$raw = [System.IO.File]::ReadAllText(...); $tail = $raw.Substring(...)` | allow | arbiter (allowlisted .NET reads) |

## 5. Affected Files

| File | Change |
|---|---|
| `src/Classifier.ps1` | Add arbiter activation gate + `Invoke-PowerShellArbitration` (orchestrates Parser/Resolver helpers). |
| `src/Parser.ps1` | §3.1 string-heuristic fix; §3.2 call-operator skip + wrapper safety-net; §3.3 `Get-PowerShellSafeExpressions`; shared `Test-SafeAst` (with `allowedCommands` set + .NET allowlist check). |
| `src/Resolver.ps1` | Early `allow` for `'(safe expression)'` marker; §3.4 Step 0e ≥2-token guard. |
| `src/ConfigLoader.ps1` | Optional `safe_expressions.dotnet_method_allowlist` with built-in default; validate. |
| `config.json` | §3.5 AWS configure entries; §3.6 `safe_expressions` block. |
| `test/test-cases.new-samples.xml` | Canonical 14-case empirical set (already written). |
| `test/test-cases.adhoc.xml` | Merge canonical cases + §4.3 negative tests. |

## 6. Test Plan

### 6.0 Canonical empirical samples

The authoritative reproduction set is `test/test-cases.new-samples.xml` (14 cases):

- **Batch 1 — `PS-Safe-Expressions` (7):** original log-observed misclassifications, transcribed from a log and normalized to valid ASCII PowerShell. Corrections applied: missing `$` sigils (`headers`, `gittoken`, `log`, `key`, `hdr`), stray trailing quote, Unicode `−`/`∣`/`′` → `-`/`|`/`'`, mangled cmdlet names (`select−ogject−first40` → `Select-Object -First 40`), `apath` → `a path`, one missing closing paren, `aws --version, get-content $file` → `aws --version; Get-Content $file`. Policy: LLM-generated commands are assumed syntactically valid; only transcription artifacts are corrected, never semantics.
- **Batch 2 — `New-Samples-Regex-Confusion` (7):** follow-up samples (git tag multi-line message, `Select-String` regex with pipes/brackets, `-replace` with scriptblock, `& { ... }`, `aws configure get`, `[System.IO.File]::ReadAllText`).

All cases expected **allow** except batch 2's `git tag -a` (**ask**).

### 6.1 Adhoc merge

Merge the 14 canonical cases into `test/test-cases.adhoc.xml` under `PS-Safe-Expressions` and `AWS-Configure` groups, plus the §4.3 negative tests under `AST-Arbiter-Guard`.

### 6.2 Regression

Full differential matrix per §4.4.

## 7. Backward Compatibility & Performance

- The arbiter only runs on lines whose current outcome is ask-with-only-unknown-blockers — rare in practice. Cost: one extra `ParseInput` + subtree walks + resolutions on those lines only.
- Primary-path changes (§3.1–§3.3) are more restrictive or additive; the safe-expression fallback only replaces the regex fallback when certification succeeds.
- `safe_expressions` is optional; absent ⇒ built-in default list.
- No config/schema breaking changes; no changes to trusted/untrusted gates, redirection logic, or domain detection.

## 8. Future Work (out of scope)

- Arbiter-assisted *reason improvement*: when arbitration finds known-modifying commands inside a misrouted line, return their precise reasons instead of `unknown command` (decision is already correctly `ask` in v1).
- Config entry for `git tag -a` (create annotated tag) as modifying-low so its ask reason is precise.
- Extend `dotnet_method_allowlist` governance (per-type lists) if needed.
- `InvokeMemberExpressionAst` on non-allowlisted but provably-pure getters.
