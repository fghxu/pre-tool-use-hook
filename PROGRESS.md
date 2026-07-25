## Goal
Design and implement the strictness_gated config section + per-domain strictness (global guard): a third tier per domain that allows in normal/loose but asks in strict, with per-domain strictness honored by strictness_gated + AWS flag-strip + parameter_commands. Spec: docs/superpowers/specs/2026-07-25-strictness-gated-design.md

## State note (2026-07-25)
- master @ 539f8eb. path-branch merged (864e85c) + test consolidation done.
- strictness_gated implementation branches from master.

## Completed Steps
- path-branch: merged to master; all suites green (byte-identical + trustedpattern 69/74).
- Test consolidation: test-cases.xml now 690 cases (merged adhoc, fullpath, var-assignment, redirect-normal); 4 source files + redirect-normal.xml deleted (content merged). 684/690, 6 pre-existing fails (1 git-add + 5 redirect-non-system). Remaining separate files (by necessity): redirect-strict (strict-mode), trustedpattern (cwd-keyed), fullpipe (different runner).
- strictness_gated spec written + self-reviewed + committed (5b27112).
- Plan Tasks 1-4 (branch strictness-gated, all dormant): TestRunner -ConfigPath (d23c2b6) → ConfigLoader compiles/validates strictness_gated + per-domain modifying_strictness (1b652c5) → Resolver Get-EffectiveStrictness + step 1a.5 + effective-strictness reach for AWS flag-strip/param_commands (5c4b780).
- Plan Task 5 (5e8b277): fixtures test/config/config.{git-strict,strict}.json + 3 suites test/test-cases.strictness-gated.{normal,strict,git-strict}.xml. RED baseline confirmed: normal 24/24 GREEN; strict 6/24 (6 controls pass, 18 gated fail — still read_only); git-strict 6/12 (isolation+AWS-reach pass, 6 Git-gated fail). Both fixtures load via Load-Config. Live config.json untouched.
- Plan Task 6 (221c1b8): config.json migration — moved Git×10 (pull, switch, init, clone, tag -d, add, worktree add, commit, rev-parse, stash) + Linux printf read_only → strictness_gated; git switch gained risk:low; comments updated (_comment_planned→_comment_gated, "(planned)"→live). Fixtures regenerated from migrated config. Normal-mode byte-identical (684/690); suites flipped GREEN: normal 24/24, strict 24/24, git-strict 12/12.
- Plan Task 7 (ae1197b): redirect-strict now fixture-driven — `-ConfigPath test/config/config.strict.json` (no -Strictness) verified identical to -Strictness strict (24/25, same #22 pre-existing fail). README updated.

## Locked decisions (L1-L5)
- L1 name: strictness_gated. L2 scope: third section + per-domain strictness. L3 guard: global strict/loose forces all domains; global normal defers to per-domain. L4 reach: strictness_gated + AWS flag-strip + parameter_commands use effective strictness; path policy stays global. L5 testing: separate test config fixtures via new -ConfigPath param; live config.json untouched by feature tests.

## Design summary
- Get-EffectiveStrictness(Config, Domain): global!=normal → global; else domain's own modifying_strictness; else normal.
- New match step 1a.5 (between read_only and modifying): strictness_gated → ask iff effective==strict, else allow.
- AWS flag-strip (Resolver:180) + param_commands unrecognized (Resolver:890) use effective strictness; path policy unchanged.
- Move list (read_only-with-risk → strictness_gated): Git×10 (pull, switch, init, clone, tag -d, add, worktree add, commit, rev-parse, stash) + Linux printf (cross-domain isolation demo). No per-domain strictness shipped by default → normal behavior byte-identical.
- Fixtures: test/config/config.git-strict.json (Git=strict) + config.strict.json. New suites: test-cases.strictness-gated.{normal,strict,git-strict}.xml.

## Current Step
ALL 8 plan tasks COMPLETE on branch strictness-gated (070586a..70d292e, 9 commits). Final whole-implementation review: READY TO MERGE. Awaiting explicit user approval to merge to master.

## Next Steps
- Merge strictness-gated → master ONLY with explicit user approval.
- Optional follow-ups (non-blocking, from final review): config.aws-strict.json fixture for AWS-reach differentiating test; make Evaluate-ParameterRules -Domain mandatory.
- After merge: regenerate fixtures from config.json whenever it changes (noted in fixture _comment_fixture).

## Blockers / Notes
- 6 pre-existing test-cases.xml fails are documented (editable_paths populated disables normal-mode fallback for the redirect-non-system cases; git add is read_only).
