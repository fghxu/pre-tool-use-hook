## Goal
Design (brainstorm → spec → plan) an LLM-facing guidance artifact (prompt file vs skill) that teaches agents to emit shell/PowerShell commands in forms the PreToolUse hook can classify, reducing "unknown command" fallbacks without restricting what agents may do.

## Log scan findings (2026-07-19, C:\temp\logs\prehook\)
- ~330 "unknown command" occurrences across 20 log files (claude/copilot/codex).
- Two root causes seen:
  1. Commands missing from the classification DB: `git tag -a`, `git worktree`, `git branch --show-current`, `./gradlew`, `unzip`, `javap`, `net share`, `reg query`, `sc qc`, `cmd //c`, `powershell.exe -File`.
  2. Format the parser can't decompose: `powershell.exe -NoProfile -Command "<long pipeline>"`, heredocs, nested/escaped quoting (`\$`, `\"`), multi-line inline scripts, trailing `2>/dev/null`.

## Completed Steps
- Log scan: 895 unknowns → 507 heredoc/message shrapnel (57%), 388 real commands (43%). Offender table built.
- Design decisions locked: prevention-only guidance (no retry loop possible); both Option A (guidance.md) + B (skill) + install README; config.json gap-fill for real DB gaps; multi-line commits → repeated -m.
- Spec written + self-reviewed + committed: docs/superpowers/specs/2026-07-19-agent-command-guidelines-design.md (ed07383).

## Current Step
Awaiting user review of the spec before invoking writing-plans.

## Next Steps
- User approves spec → invoke writing-plans skill → implement 4 deliverables: guidance.md, hook-friendly-commands/SKILL.md, README.md (all under docs/agent-command-guidelines/), config.json additions + adhoc test cases + full differential suite run.

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
DONE — ast-arbiter merged into master (merge commit d97c272). All suites verified green on master after merge.

## Next Steps
- Optional: push master to origin (not done — awaiting user decision).
- Optional: fast-forward fix-var-assignment-detection to master (it is exactly one merge behind; `git checkout fix-var-assignment-detection; git merge master`).
- Optional: delete the merged ast-arbiter branch.

## Blockers / Notes
- Pre-existing issues found (not caused by this work, flagged to user): test-cases.var-assignment #14 ($x = git add . — config lists git add read_only but test expects ask); redirect/trustedpattern suites have environment-dependent reds.

