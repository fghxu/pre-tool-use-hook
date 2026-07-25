## Goal
Design and implement the path-branch: file-tool writes (Write/Edit/Copilot file tools) observe system_paths/editable_paths/CWD directly — single source of truth for path policy, canonicalization, default-ask for unlisted paths. Spec: docs/superpowers/specs/2026-07-25-path-branch-design.md

## State note (2026-07-25)
- master now at 180411d — contains ALL agent-command-guidelines work (user carried 3 files as unstaged changes; reconciled via fast-forward merge of agent-command-guidelines).
- Path-branch implementation branches from master.

## Completed Steps (prior work, merged)
- Agent guidance artifacts: docs/agent-command-guidelines/ (guidance.md, SKILL.md, README.md).
- config.json gap-fill: 31 LogGap adhoc cases, adhoc 94/94.
- File-tool gating (config-only bridge): trusted/untrusted path patterns, 60 trustedpattern cases (suite 61/66), TestRunner tool-name/tool-input-json support.
- Reference docs: docs/config-json-guide.md, docs/trusted-untrusted-patterns.md.
- Log scan (2026-07-19): 895 unknowns — 507 (57%) heredoc/message shrapnel, 388 (43%) real commands.
- Path-branch T3/T4: ConfigLoader path_tool_mapping (3acae30), Resolve-PathPolicy + redirect refactor (a3053e1).
- Fix (778643f): ConvertTo-CanonicalWritePath handles \\?\UNC\ prefix (fail-open to network share closed) and whitespace-only path guard. Suites verified at baseline.

## Current Step
Path-branch spec written and self-reviewed (docs/superpowers/specs/2026-07-25-path-branch-design.md). Awaiting user review before writing-plans.

## Locked decisions (D1-D6)
- D1 default-ask for unlisted file-tool writes; D2 redirect analysis shares the canonicalize+check function; D3 path entries retired from trusted/untrusted (except legacy scaffolding + command-side exe pattern); D4 location-only write policy (no exe guard); D5 NO C:\git in editable_paths — writability = editable_paths + CWD subtree (other projects ask); D6 strictness semantics preserved verbatim (CWD editable every mode).

## Next Steps
- User approves spec → writing-plans → implement on feature branch from master.

## Blockers / Notes
- Key behavior table in spec §3.5: Write C:\git\other-project flips allow→ask (D5); [RESIDUAL] cases flip allow→ask (fixed); Write C:\temp\evil.exe flips ask→allow (D4).
- Multi-path Copilot payloads (edit_files, apply_patch) need real-payload capture for mapping verification.
