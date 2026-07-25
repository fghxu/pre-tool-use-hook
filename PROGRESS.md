## Goal
Design and implement the path-branch: file-tool writes (Write/Edit/Copilot file tools) observe system_paths/editable_paths/CWD directly via a shared Resolve-PathPolicy — single source of truth for path policy, canonicalization, default-ask for unlisted paths. Spec: docs/superpowers/specs/2026-07-25-path-branch-design.md. Plan: docs/superpowers/plans/2026-07-25-path-branch-plan.md.

## State note (2026-07-25)
- Branch path-branch (off master @ 180411d) holds the implementation.
- master 180411d contains all prior agent-command-guidelines work.

## Completed Steps — path-branch (all on branch path-branch)
- T2 trustedpattern migration (RED): 60 cases re-keyed to path-branch policy + 8 new (TP-PathBranch + ~ home + extraction-failure); -Cwd C:\git\repo pin documented in suite header.
- T3 ConfigLoader path_tool_mapping (3acae30): default empty object + PSCustomObject validation.
- T4 Resolve-PathPolicy + redirect refactor (a3053e1, fix 778643f): ConvertTo-CanonicalWritePath (\\?\ and \\?\UNC\ strip, .. collapse, POSIX/~ special-case, whitespace guard) + Resolve-PathPolicy ladder (temp[raw] → system[canonical] → CWD/editable → loose → normal → default ask); Test-RedirectionTarget >/> refactored to call it — byte-identical redirect behavior.
- T5 Classifier path-branch (880c9c3): Get-InputFieldValue helper (HookAdapter) + STEP 1.5 in Invoke-Classify (path_tool_mapping → Resolve-PathPolicy -Verb 'file write to'; extraction failure → ask).
- T6 config.json activation (e6ab26f): path_tool_mapping (12 file tools); tool_name_mapping reduced to command tools; trusted/untrusted path patterns retired (kept legacy scaffolding + command-side exe pattern).
- T7 full differential: byte-identical on all 8 non-TP suites (test-cases 487/487, adhoc 94/94, var-assignment 63/64, fullpath 20/20, redirect-normal 20/25, redirect-strict 24/25, new-samples 14/14, fullpipe 19/19); trustedpattern 61→69/74 (only 5 pre-existing docker-comfyui fails remain).
- T8 docs (592642f): config-json-guide.md (S5/S7 + new S7.5 path_tool_mapping), trusted-untrusted-patterns.md (path patterns retired, residuals→fixed table).

## Current Step
DONE — path-branch implementation complete and verified. Awaiting final review + finishing-a-development-branch decision.

## Locked decisions (D1-D6) — all implemented
- D1 default-ask for unlisted file-tool writes ✓; D2 redirect shares Resolve-PathPolicy ✓; D3 path entries retired from trusted/untrusted ✓; D4 location-only write policy ✓; D5 NO C:\git in editable_paths — CWD subtree rule (other projects ask) ✓; D6 strictness preserved verbatim ✓.

## Next Steps
- Final whole-feature code review, then finishing-a-development-branch (merge/PR/keep/discard).
- Follow-up: edit_files/apply_patch payload-shape capture (currently unmapped, prompt fail-safe); review the debug escape-hatch entries in config.json trusted_pattern (src.Parser.ps1 / C..git.cc.pretoolhook etc.) — inert (dot-vs-slash mismatch) but should be cleaned before merge.

## Blockers / Notes
- config.json was concurrently edited by user during the workflow (debug escape-hatch entries in trusted_pattern); committed as-is per user intent — flagged for cleanup.
- 5 pre-existing docker-comfyui trustedpattern fails unchanged (expect an opt-in `docker exec comfyui` trusted pattern, not shipped).
