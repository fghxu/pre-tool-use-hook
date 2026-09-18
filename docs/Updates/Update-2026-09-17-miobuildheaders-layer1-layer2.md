# Update — September 17, 2026: MiobuildHeaders "unknown command" — Layer 1 allowlist + Layer 2 atomic unknown

## Requirement / Spec

Production log 2026-09-17 11:01:47: a purely in-memory Basic-auth header assignment
forced `ask` (tiers `[1]=unclassified [2]=unclassified`, reason showed **two** bogus
fragments). The LLM second-opinion correctly said read-only, but "LLM never downgrades"
kept the local ask.

```powershell
$global:MiobuildHeaders = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($global:MiobuildCredential.UserName):$($global:MiobuildCredential.GetNetworkCredential().Password)")) }
```

Two approved fixes (handoff `C:\temp\handoff-pretoolhook-layer1-layer2-2026-09-17.md`):

- **Layer 1** — config-only: allowlist the unlisted instance method so the statement
  certifies as safe.
- **Layer 2** — structural: when a command has **zero cmdlets and zero safe
  expressions** but the AST parse **succeeded**, classify it as **one atomic unknown**
  instead of regex-splitting it into phantom fragments.

## Root cause (verified by probe)

1. `GetNetworkCredential()` is an instance-style call checked against the **name-only**
   `dotnet_method_allowlist` (`Test-SafeAst` → `InvokeMemberExpressionAst`, Parser.ps1).
   It was absent → `Test-SafeAst` false → safe-expressions path empty AND the AST
   arbiter (STEP 4f) inconclusive.
2. With both AST paths empty, the combination logic fell to **regex `Split-Commands`**,
   which misreads the `:` inside `$($user:$pwd)` string interpolation and splits into two
   phantom fragments; each resolves to `unknown command` / tier `unclassified` → ask.

**Correction to the handoff doc:** the incident command's domain is **linux, not
powershell** — the assignment-strip in `Get-CommandDomain` leaves `@{ ... }`, which has
no Verb-Noun/PS marker. Consequences:

- Layer 1 works via the **domain-agnostic arbiter** (STEP 4f), not the powershell-gated
  safe-expressions path.
- The originally approved Layer 2 gate (`domain==powershell`) would have been a **no-op**
  for every incident case. User-approved Option 1: drop the domain gate and key on the
  real discriminator (zero cmdlets + zero safe exprs + parse OK).

## Behavior

### Layer 1

`"GetNetworkCredential"` added to `safe_expressions.dotnet_method_allowlist` in
`config.json`, `config.local.json` (live), `test/config/live/config.json`. Rationale:
pure read accessor on `PSCredential` (materializes a `NetworkCredential` from the
in-memory `SecureString`; no I/O) — same class as existing `GetBytes`. The incident
command now resolves `allow` / "read-only (PowerShell AST arbitration)".

### Layer 2 — atomic unknown

New helper `Test-PowerShellParses` (Parser.ps1): wraps
`[System.Management.Automation.Language.Parser]::ParseInput`, returns
`$errors.Count -eq 0`. Needed because `Get-PowerShellCommands` and
`Get-PowerShellSafeExpressions` both return `@()` for **both** a syntax error and a
genuinely-zero-cmdlet expression — the two cases must now diverge.

New combination branch in `Invoke-Classify` (Classifier.ps1, STEP 4b-3), placed after
the safe-expressions branch:

```
Get-PowerShellCommands(cmd) == 0   AND   safeExpressions == 0   AND   Test-PowerShellParses(cmd)
    => ONE atomic sub-command = the whole statement:
         ask / tier 'unclassified' /
         reason "unsafe PowerShell expression (fail-closed): <80-char stmt>"
       (nested/subshell commands still unioned — a wrapped modifying inner is not lost)
otherwise
    legacy behavior (regex split / nested path)
```

Design invariants:

- **Real commands never reach the branch.** Any bare-word command (`rm`, `git status`,
  `curl -o …`) yields ≥1 `CommandAst` from the recursive AST walk, so it is excluded.
  Only *pure unsafe expressions* (unlisted .NET method calls, property sets, unlisted
  statics) qualify.
- **Parse failure keeps the legacy path** (e.g. a bash for-loop is a PS syntax error →
  regex split as before).
- **Tier reuses `unclassified`** — no new tier, so `check_blindspot` default tiers and
  the LLM merge logic need zero changes.
- **Reason-text refinement:** an unlisted `[Type]::Method(...)` keeps the specific
  "static method not on allowlist: …" wording (unanchored match, guarded against
  naming an *allowlisted* static — checked against `_dotnetStaticMethodAllowlist`).
  Decision is `ask` either way; only the guidance quality differs.
- **Tier upgrade after arbitration:** when the arbiter returns Conclusive=true, any
  SubResult still carrying tier `unclassified` (atomic entries and subshell fragments
  have no CommandAst → no TierMap entry) is upgraded to `read_only`. The G5 stamp-back
  only fills *empty* tiers from the TierMap; pure expressions never get a map entry, so
  without this they would display as "unclassified" in logs/LLM input despite being
  provably safe. Only `unclassified` is touched — never strictness_gated/read_only/
  safe_expr. Safe because it runs only on the Conclusive=true (allow) path: the LLM
  merge and check_blindspot see a truthful tier, and no decision can change (the
  command is already allowed).

### Critical bug caught by regression

The first implementation gated on `$astCommands.Count -eq 0`, but `$astCommands` is only
populated for **powershell-domain** inputs — it stays `@()` for every non-powershell
command, and since most shell text parses as valid PowerShell syntax, the branch fired
for `git status`, `curl -o …`, while-loops, etc. → **17 regressions** (5 in
test-cases.xml, 8 llm-review.small, 3 phase-I, 1 check-blindspot). Fix: call
`Get-PowerShellCommands` **directly** in the condition so the true cmdlet count is used
for any domain.

## Test impact

- `TestRunner.ps1`: optional per-case `reason-contains` XML attribute — asserts reason
  text when present; absent on all pre-existing cases, so decision-only behavior is
  unchanged.
- New `PSAtomic-Unknown` category-group in `test/config/live/test-cases.xml` (5 cases):
  - MiobuildHeaders exact repro → `allow` (Layer 1)
  - `$proc.Kill()` → ask, reason-contains "unsafe PowerShell expression"
  - `[Console]::Title = 'x'` → ask, reason-contains "unsafe PowerShell expression"
  - `$x = [System.IO.File]::Delete('c:\temp\x.txt')` → ask, reason-contains
    "static method not on allowlist" (specific wording preserved)
  - bash for-loop guard → parse error → legacy regex path (no atomic reason)

## TDD red/green log

| Step | Result |
|------|--------|
| RED (Layer 1+2 cases added, no fix) | 4/5 failing: MiobuildHeaders ask≠allow; Kill/ConsoleTitle/FileDelete wrong reason text; for-loop guard passes |
| GREEN Layer 1 (allowlist entry) | MiobuildHeaders → allow (arbiter); 2/5 passing |
| GREEN Layer 2 v1 (domain-gated branch) | PSAtomic-Unknown 5/5, but **full regression 17 failures** (domain-gating bug) |
| GREEN Layer 2 v2 (direct Get-PowerShellCommands in condition) | full regression **1272/1272** (baseline 1267 + 5 new), zero regressions |

Baseline verified by `git stash` → clean-HEAD run (1267/1267) → `git stash pop`.

## Files changed

- `config.json`, `config.local.json`, `test/config/live/config.json` — allowlist entry
- `src/Parser.ps1` — `Test-PowerShellParses`
- `src/Classifier.ps1` — STEP 4b-3 atomic branch + STEP 4e `AtomicReason` handling
- `src/TestRunner.ps1` — optional `reason-contains` assertion
- `test/config/live/test-cases.xml` — PSAtomic-Unknown group (5 cases)
