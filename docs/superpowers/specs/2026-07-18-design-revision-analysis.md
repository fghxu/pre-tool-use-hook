# Design Revision Analysis: AST-as-Arbiter Spec vs. Original Plan

**Date:** 2026-07-18
**Compares:**
- **NEW:** `docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md` (AST-as-arbiter design, commit `897f9f8`)
- **OLD:** `docs/superpowers/plans/2026-07-18-ast-aware-safe-expressions-plan.md` (implementation plan for the original downstream-patching design, partially executed in the `ast-safe-expressions` worktree)

---

## 1. Executive summary

The original design **patched the PowerShell AST path** (string heuristic, call-operator, safe-expression fallback) but left the **regex-based domain router** in front of it untouched. Implementation on a stale base plus a full trace of the target cases showed **6 of 10 misclassified commands never reach the PowerShell path at all** — the original fixes were correct but addressed only 40% of the problem.

The new design keeps every proven downstream fix and adds one architectural mechanism: an **AST-as-arbiter fallback** that re-tries any line the pipeline can only reject as "unknown command" through the real PowerShell parser, converting to `allow` only under complete per-statement accounting.

**Verdict on the original plan: its mechanisms were ~70% right and are retained; its architecture was incomplete and its Test-SafeAst had two critical safety holes.**

---

## 2. What in the original design is still good (retained unchanged or refined)

| Original element (old plan task) | Status in new spec | Evidence it works |
|---|---|---|
| **String-constant heuristic fix** (Task 3 → §3.1): don't treat quoted parameter values as command strings | **Retained**, with the code-review correction: top-level means parent is `CommandExpressionAst` whose parent is `PipelineAst`/`NamedBlockAst`, and the original conjunction (separator/newline **and** word-pair) is preserved | On old base: both `Select-String` regex cases passed, main suite stayed 467/467 (commit `ab0e5bf`) |
| **Call-operator `& { ... }` handling** (Task 4 → §3.2) | **Retained**, with the implementation-learned refinement: detect via `InvocationOperator -eq 'Ampersand'` + caller-side skip in `Get-AstCommands`. The old plan's `$CommandName -eq '&'` check was **dead code** (the wrapper helper is unreachable for single-element CommandAsts, and `&` is the invocation operator, not a command element) | Call-operator case passed on old base, 467/467 (commit `fe4a4fc`) |
| **Safe-expression fallback for zero-command lines** (Task 5 → §3.3) | **Retained** as the primary-path fallback, but `Test-SafeAst` is replaced by the hardened shared version (see §4 below) | Committed on old base (`ecd99c7`) but only partially effective — see §3 |
| **AWS `configure get`/`configure list` config entries** (Task 2 → §3.5) | **Retained unchanged** | `aws configure get sso_role_name` passed (commit `c6c7d19`) |
| **Canonical empirical test file** (`test-cases.new-samples.xml`) + merge into adhoc | **Retained and expanded** to 14 cases with a documented transcription-normalization policy | 7 cases reproduced 6 failures + 1 pass as expected (commit `6dda607`) |
| **TDD execution with full-suite regression gates per task** | **Retained**, upgraded to a byte-identical differential acceptance criterion (new spec §4.4) | Baseline 467/467 established before any change |

---

## 3. Key differences and why they were needed

### 3.1 Architecture: downstream patching → upstream arbitration

**Original:** All fixes lived behind `if ($domain -eq 'powershell')`. Domain detection (anchored Verb-Noun + four markers) decides *before* any AST work whether the PowerShell path runs at all.

**Trace of the 10 target scenarios through the current branch:**

| Case | Domain detected | Original plan helps? |
|---|---|---|
| `Select-String -Pattern "a\|b" \| ...` | powershell | ✅ |
| `$line -replace 'a\|b', { ... }` | powershell (`$_` marker) | ✅ |
| `$arr = 1, 2, @(3, 4)` | powershell (`@(` marker) | ✅ (after Test-SafeAst fix) |
| `& { Get-Content ... }` | **linux** | ❌ |
| `$log -split "\`n" \| Select-Object` | **linux** | ❌ |
| `$headers = @{ ... }`, bare `@{ ... }` | **linux** | ❌ |
| `$raw = [System.IO.File]::ReadAllText(...)` | **linux** | ❌ |
| `$key='...'; ssh ... 'whoami;hostname'` | **linux** | ❌ |
| `aws --version; Get-Content $file` | aws_cli (+ resolver ordering bug) | ❌ |

**New:** the arbiter gate in `Invoke-Classify` — after aggregation, if the decision is `ask` and **every** blocker is the unknown-command fallback, re-parse the whole line with the PowerShell AST and allow only when every statement is fully accounted for. One arbitration point covers all misrouted cases, including future PowerShell constructs nobody has written a marker for yet.

### 3.2 Implementation base

**Original:** executed on `ClaudeCode-v1` (0c6954f) — stale. Phantom regressions resulted (curl test 208: on the old base the *unanchored* Verb-Noun regex accidentally routes curl through the PowerShell path where Step 7 catches `-X POST`; the current branch anchors it deliberately and classifies curl in the Linux domain via `parameter_commands`).

**New:** mandates `fix-var-assignment-detection` as the base (spec §1.3) and a captured baseline before any change.

### 3.3 Test-SafeAst: two critical safety holes in the original, plus coverage gaps

| Rule | Original plan | New spec §3.0.2 | Why the change matters |
|---|---|---|---|
| `.NET method calls` (`InvokeMemberExpressionAst`) | **Blanket safe** | Safe only if method name ∈ `safe_expressions.dotnet_method_allowlist` (config) | Original would auto-allow `$x = [System.IO.File]::Delete('c:\a.txt')` and `$proc.Kill()` — a critical false-allow hole, found while drafting the new spec |
| `ScriptBlockAst` | **Blanket unsafe** | Safe iff all body statements certify recursively | Original fails the user's `-replace 'a\|b', { $_.Value -replace 'BC','PC' }` case forever — the scriptblock body is pure expressions |
| `ArrayExpressionAst` (`@(...)`), `StatementBlockAst` | **Missing** | Included (all children/statements safe) | `$arr = 1, 2, @(3, 4)` failed even with the original fallback implemented (observed in worktree) |
| Assignment LHS | Any safe node | Must be a variable (or index/array of one) | `[Console]::Title = 'x'` is a property **set** — a side effect; original would have allowed it |
| Redirections in subtree | Unspecified | `FileRedirectionAst` (`>`, `>>`) ⇒ never safe | An expression with a redirect writes a file; must stay with `Test-RedirectionTarget` |
| `allowedCommands` parameter | Not present | A `CommandAst` is safe iff its text was already resolved ALLOW by the arbiter | Enables mixed statements (`$json = Get-Content ...`) to certify |

### 3.4 `aws --version` resolver ordering bug

**Original:** test case listed, but no fix specified. Root cause found during review: Resolver Step 0e (normal-mode AWS flag stripping) strips `--version` **before** Step 1a checks the explicit `aws --version` read_only entry, leaving bare `aws` → unknown → ask.

**New:** §3.4 — Step 0e only applies the stripped result when ≥2 tokens (service + operation) remain; otherwise the original command proceeds so the explicit entry matches.

### 3.5 Deliberately discarded pieces

| Piece | Where it appeared | Why discarded |
|---|---|---|
| `VerbNounRegex` anchor change | Uncommitted worktree edit | Caused real regressions on the old base (curl 208, adhoc 22); unnecessary under arbitration |
| `& {`/`. {` domain marker in `Get-CommandDomain` | Uncommitted worktree edit | Arbiter makes all new markers unnecessary; fewer moving parts, zero router regression risk |
| Resolver Step 0b "empty-RHS assignment ⇒ allow" | Considered during review | Arbiter covers `$key='...'` via whole-line re-parse; no need to touch the hot resolver path |
| "Improved ask reasons" for known-modifying found during arbitration | Considered | Deferred to future work — v1 keeps the original ask untouched (smallest possible behavioral surface) |

---

## 4. How the new design solves the new requirements without breaking existing tests

### 4.1 Structural isolation from all currently-passing tests

The arbiter activates only when **both** hold: final decision is `ask`, and every blocking sub-result has `MatchedPattern = null` (the unknown-command fallback). Consequences:

| Existing suite class | Resolves via | Arbiter can touch it? |
|---|---|---|
| Any expected **allow** | known patterns / verbs / `parameter_commands` | **No** — no blockers exist |
| Expected **ask** with known modifying (`rm`, `git push`, `curl -X POST`, system-path redirects, `terraform destroy`, …) | matched pattern (non-null) | **No** — gate requires all blockers pattern-less |
| Expected **ask** with unknown (`git --online -3`, test 467) | Step 3 fallback | Runs — and must stay ask (§4.2) |
| Redirect blocks | `MatchedPattern = "redirection-target"` (non-null) | **No** — gate excludes them |

### 4.2 Conclusive-coverage keeps unknown-asks as ask

The arbiter converts to `allow` only when *every* top-level statement is accounted for: each `CommandAst` resolves to a **known** allow (directly, or as a wrapper whose extracted inner commands all allow), and every remaining node passes the hardened `Test-SafeAst`. Therefore:

- `git --online -3` → parses fine, but resolves unknown ⇒ **inconclusive ⇒ original ask kept**.
- Multi-line bash (`for ...; do ...; done`, `case`, heredocs) → PowerShell parse **errors** ⇒ arbiter aborts.
- One unknown command anywhere (`weirdcmd -x | Get-Process`) poisons the whole line.
- The arbiter adds **no new per-command resolution logic** — a false allow would require a modifying command that is already mis-registered as read-only in config, a pre-existing risk identical in today's pipeline.

### 4.3 Guard tests that did not exist in the original plan

Ten negative tests (new spec §4.3) specifically target the arbiter's fail-safe property — including the two safety-hole regressions the original `Test-SafeAst` would have caused (`[System.IO.File]::Delete`, `$proc.Kill()`), the property-set case (`[Console]::Title = 'x'`), a redirect-outside-CWD case, and an `ssh ... 'rm -rf ...'` case proving known-modifying blockers bypass the arbiter entirely.

### 4.4 Traceability instead of assumption

The original plan listed test cases but never traced *which stage* resolves each one. The new spec's §4.5 matrix maps all 14 canonical cases to their resolving stage (primary path vs. arbiter, and why), making coverage reviewable — this is precisely the step whose absence let 6 of 10 cases slip through the original design.

### 4.5 Acceptance criterion with teeth

Original: "run the suites, expect them to pass." New: **byte-identical results before/after** across all eight suite files on the correct base branch; any diff halts implementation. Plus `test-cases.new-samples.xml` must reach 14/14.

---

## 5. Evidence appendix (from the old-base implementation attempt)

| Commit (worktree) | Content | Result |
|---|---|---|
| `7a6d178`→`6dda607` | 7 empirical regression tests | 1 pass / 6 fail (reproduced the user's reports) |
| `c6c7d19` | aws configure get/list config | aws case passes; 2/7 |
| `ab0e5bf` | string-heuristic fix (review-corrected) | Select-String cases pass; 4/7; main suite 467/467 |
| `fe4a4fc` | call-operator handling (dead code removed) | call-operator passes; 5/7; main suite 467/467 |
| `ecd99c7` | original safe-expression fallback | partial — `.NET`/array/scriptblock/ssh cases still fail |
| uncommitted | VerbNoun anchor + `& {` marker + adhoc merge | **Regressions identified**: curl 208 wrongly allowed (anchor), 4 adhoc cases failing for four distinct root causes — the analysis that produced the new design |

The remaining failures at that point decomposed into: stale base (no `parameter_commands` for IRM), domain misrouting (5 cases), resolver ordering (`aws --version`), and Test-SafeAst gaps (arrays/scriptblocks/.NET) — exactly the categories the new spec addresses.

---

## 6. Bottom line

- **Keep:** string-heuristic fix, call-operator handling (corrected), safe-expression fallback (hardened), AWS configure config, canonical test files, TDD-with-regression-gates execution.
- **Add:** the AST-as-arbiter gate (one arbitration point, conclusive-coverage rule), the .NET method allowlist, the Step 0e `aws --version` guard, 10 arbiter-guard negative tests, the traceability matrix, and the byte-identical differential acceptance criterion.
- **Discard:** domain-marker additions, the anchor change, the Step 0b empty-RHS patch, and any execution on bases other than `fix-var-assignment-detection`.
