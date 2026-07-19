## Goal
Design and ship an LLM-facing guidance artifact (shared file + skill) that teaches agents to emit shell/PowerShell commands in forms the PreToolUse hook can classify, plus fill the config.json gaps behind real "unknown command" hits — without restricting what agents may do.

## Log scan findings (2026-07-19, C:\temp\logs\prehook\)
- 895 "unknown command" hits: 507 (57%) heredoc/commit-message shrapnel, 388 (43%) real unclassifiable commands.
- Top real offenders: powershell.exe -Command blobs (~43), cmd //c (30), gradlew (20), adb (14), reg query (11), git worktree/branch/tag/ls-files (32), unzip/javap/gh/net share/sc qc.

## Completed Steps
- Spec committed: docs/superpowers/specs/2026-07-19-agent-command-guidelines-design.md (ed07383). Plan committed (d187853).
- Executed on branch agent-command-guidelines:
  - Baseline confirmed all 9 suites (fullpipe requires pwsh, not powershell.exe).
  - 31 LogGap adhoc cases RED → config.json gap-fill → GREEN 94/94.
  - Differential: test-cases 487/487, var-assignment 63/64, fullpath 20/20, redirect-normal 20/25, redirect-strict 24/25, trustedpattern 1/6, new-samples 14/14, fullpipe 19/19 — all byte-identical to baseline.
  - Bugs found & fixed: `.\gradlew` regex-invalid (hook fail-closed blocked all tools; user repaired manually); gh entries initially in unreachable GitHub_CLI domain → moved into Linux fallback domain; bare `adb logcat` pattern shadowed the -c lookahead (dropped).
  - Commits: faafc9b (config+tests), fe2ed1a (guidance.md, hook-friendly-commands/SKILL.md, README.md).

## Current Step
DONE — implementation complete on branch agent-command-guidelines. Awaiting merge decision.

## Next Steps
- Merge agent-command-guidelines → master (per finishing-a-development-branch options).
- Optional: install guidance — add `@C:\git\cc\pretoolhook\docs\agent-command-guidelines\guidance.md` to ~/.claude/CLAUDE.md; paste guidance.md into ~/.copilot/AGENTS.md and ~/.codex/AGENTS.md.
- Optional: push to origin.

## Blockers / Notes
- Meta-validation: a broken config.json makes the hook fail-closed on ALL tool calls (total agent deadlock). Fail-safe by design, but worth a future "config lint" guard before writes.
- Pre-existing issues (unchanged): var-assignment #14, redirect/trustedpattern environment-dependent reds.
