## Goal
Design and implement the strictness_gated config section + per-domain strictness (global guard): a third tier per domain that allows in normal/loose but asks in strict, with per-domain strictness honored by strictness_gated + AWS flag-strip + parameter_commands. Spec: docs/superpowers/specs/2026-07-25-strictness-gated-design.md

## State note (2026-07-25)
- master @ 539f8eb. path-branch merged (864e85c) + test consolidation done.
- strictness_gated implementation branches from master.

## Completed Steps
- path-branch: merged to master; all suites green (byte-identical + trustedpattern 69/74).
- Test consolidation: test-cases.xml now 690 cases (merged adhoc, fullpath, var-assignment, redirect-normal); 4 source files + redirect-normal.xml deleted (content merged). 684/690, 6 pre-existing fails (1 git-add + 5 redirect-non-system). Remaining separate files (by necessity): redirect-strict (strict-mode), trustedpattern (cwd-keyed), fullpipe (different runner).
- strictness_gated spec written + self-reviewed + committed (5b27112).

## Locked decisions (L1-L5)
- L1 name: strictness_gated. L2 scope: third section + per-domain strictness. L3 guard: global strict/loose forces all domains; global normal defers to per-domain. L4 reach: strictness_gated + AWS flag-strip + parameter_commands use effective strictness; path policy stays global. L5 testing: separate test config fixtures via new -ConfigPath param; live config.json untouched by feature tests.

## Design summary
- Get-EffectiveStrictness(Config, Domain): global!=normal → global; else domain's own modifying_strictness; else normal.
- New match step 1a.5 (between read_only and modifying): strictness_gated → ask iff effective==strict, else allow.
- AWS flag-strip (Resolver:180) + param_commands unrecognized (Resolver:890) use effective strictness; path policy unchanged.
- Move list (read_only-with-risk → strictness_gated): Git×10 (pull, switch, init, clone, tag -d, add, worktree add, commit, rev-parse, stash) + Linux printf (cross-domain isolation demo). No per-domain strictness shipped by default → normal behavior byte-identical.
- Fixtures: test/config/config.git-strict.json (Git=strict) + config.strict.json. New suites: test-cases.strictness-gated.{normal,strict,git-strict}.xml.

## Current Step
Spec awaiting user review. Then writing-plans.

## Next Steps
- User approves spec → writing-plans → implement on feature branch from master (TestRunner -ConfigPath, fixtures, suites, ConfigLoader + Resolver changes, config move).
- redirect-strict becomes fixture-driven (config.strict.json) once -ConfigPath lands.

## Blockers / Notes
- 6 pre-existing test-cases.xml fails are documented (editable_paths populated disables normal-mode fallback for the redirect-non-system cases; git add is read_only).
