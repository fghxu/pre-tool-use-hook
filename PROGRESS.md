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

## Current Step
Task P2: config additions (aws configure entries + safe_expressions allowlist).

## Next Steps
- P2 config → P3 Test-SafeAst → P4 string heuristic → P5 call-operator → P6 Step 0e guard → P7 arbiter → P8 tests → P9 verification → P10 docs.

## Blockers / Notes
- Execution constrained to ONE subagent at a time; reviews done in main thread.
