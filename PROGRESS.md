## Goal
Implement the AST-as-arbiter design (spec 2026-07-18-ast-aware-safe-expressions-design.md, plan 2026-07-18-ast-arbiter-implementation-plan.md) so 14 canonical misclassified read-only commands are auto-allowed, with zero behavior change on existing suites.

## Baseline (pre-change), captured 2026-07-18 in ast-arbiter worktree @ 202be06 (corrected trusted_pattern)

| Suite | Invocation | Result |
|---|---|---|
| test-cases.xml | default | 487/487 pass |
| test-cases.adhoc.xml | default | 39/39 pass |
| test-cases.var-assignment.xml | default | 63/64 (1 pre-existing fail) |
| test-cases.fullpath.xml | default | 20/20 pass |
| test-cases.redirect-normal.xml | `-Strictness normal` | 20/25 (5 pre-existing fails) |
| test-cases.redirect-strict.xml | `-Strictness strict` | 24/25 (1 pre-existing fail) |
| test-cases.trustedpattern.xml | default | 1/6 (5 pre-existing fails: expects custom trusted patterns) |
| test-cases.new-samples.xml | default | 1/14 (13 fails = the work to implement) |
| test-fullpipe.xml | FullPipeTestRunner.ps1 | 19/19 pass |

Differential acceptance: pre-existing suites must be byte-identical after implementation; adhoc grows by +24 (14 canonical + 10 guard), all passing; new-samples 14/14.

## Completed Steps
- Reverted corrupted debug trusted_pattern (^.*$) on branch (202be06); merged into worktree.
- Captured true baseline (above). HEAD code identical to f84bf50 — no half-implemented code anywhere.
- P2 config (f34c2cc): aws configure get/list read_only + safe_expressions dotnet allowlist.
- P3 (a0c75d7): hardened Test-SafeAst + Get-PowerShellSafeExpressions; '(safe expression)' early-allow in Resolver; zero-command fallback in Classifier.
- P4 (0b80eaf): string-constant heuristic fix (top-level CommandExpressionAst check).
- P5 (b750094): call-operator & { } handling (InvocationOperator skip + wrapper safety-net).
- P6: Step 0e aws --version ≥2-token guard.
- P7: arbiter gate — Invoke-PowerShellArbitration + Resolve-AsArbiter + activation gate in Invoke-Classify.
- P7 hardening (review findings): CommandExpressionAst/NamedBlockAst cases in Test-SafeAst; nested-first wrapper resolution (pwsh read_only must not bypass inner-command classification); Find-NestedCommands-only wrapper extraction (ssh -W flag-value table); 2.5h heredoc rule narrowed to exclude .NET invocations ($proc.Kill() hole); flow-control statements in Test-SafeAst; fixed unbalanced paren in VarAssignment-PS-ForLoop test (was invalid PowerShell, previously masked by the 2.5h hole).
- P8: merged 14 canonical + 10 AST-Arbiter-Guard tests into adhoc (now 63 cases).

## Final verification (all green / byte-identical to baseline)
- test-cases.xml 487/487 ✓ · adhoc 63/63 ✓ (+24) · var-assignment 63/64 ✓ (same pre-existing test-14 fail) · fullpath 20/20 ✓ · redirect-normal 20/25 ✓ · redirect-strict 24/25 ✓ · trustedpattern 1/6 ✓ · new-samples 14/14 ✓ · fullpipe 19/19 ✓

## Current Step
P10: finalize docs, final review, merge back to fix-var-assignment-detection.

## Next Steps
- Mark spec approved; merge ast-arbiter branch; clean up worktrees (ast-safe-expressions, probe-f84bf50).

## Blockers / Notes
- Pre-existing issues found (not caused by this work, flagged to user): test-cases.var-assignment #14 ($x = git add . — config lists git add read_only but test expects ask); redirect/trustedpattern suites have environment-dependent reds.

