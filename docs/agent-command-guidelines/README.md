# Agent Command Guidelines — Install Companion

`guidance.md` is the single source of truth. `hook-friendly-commands/SKILL.md` is the same rules in skill format (backup). Install per IDE below; edit only `guidance.md` and re-propagate on change.

All directories referenced below were verified to exist on this machine (2026-07-19).

## Claude Code

**Option A (recommended):** add an import line to `~/.claude/CLAUDE.md`:

```
@C:\git\cc\pretoolhook\docs\agent-command-guidelines\guidance.md
```

**Option B (backup skill):** copy `hook-friendly-commands/` into `~/.claude/skills/` so it becomes `~/.claude/skills/hook-friendly-commands/SKILL.md`.

**Verify:** start a session and ask the agent to recite rule R1 — or check that `~/.claude/skills/hook-friendly-commands/SKILL.md` exists.

## GitHub Copilot CLI

Copilot does **not** follow Claude's `@path` file-link syntax. Paste the full contents of `guidance.md` into one of:

- `~/.copilot/AGENTS.md` (global, all repos), or
- `<repo>/AGENTS.md` or `<repo>/.github/copilot-instructions.md` (per-repo)

Skills load only via installed plugins, so the paste route above is the practical install for Copilot.

**Verify:** ask the agent in a Copilot session to recite rule R1.

## Codex CLI

Codex reads `AGENTS.md` (no import syntax). Paste the full contents of `guidance.md` into `~/.codex/AGENTS.md` (global) or the repo's `AGENTS.md`.

Optional skill install (current Codex builds load skills natively — verify on your version): copy `hook-friendly-commands/` to `~/.codex/skills/hook-friendly-commands/`.

**Verify:** ask the agent in a Codex session to recite rule R1.

## Maintenance

1. Edit `guidance.md` only.
2. Re-paste into any AGENTS.md / copilot-instructions.md targets (they are copies, not links).
3. If `config.json` adds coverage for a command listed in guidance rule R7, remove it from R7.
4. Regenerate `hook-friendly-commands/SKILL.md` if the rules change (it is a condensed copy).
