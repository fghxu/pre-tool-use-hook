---
name: hook-friendly-commands
description: Use when composing shell or PowerShell commands to run in a terminal - emits forms the PreToolUse safety hook can auto-classify, avoiding "unknown command" approval prompts and session slowdowns
---

# Hook-Friendly Commands

A PreToolUse hook classifies every command before it runs. Unclassifiable commands become "unknown command" and force manual review. Emit commands in these shapes:

1. **No heredocs.** Use the file-writing tool for file contents. Heredoc content shatters into phantom unknown commands.
2. **Multi-line git messages:** repeated `-m` flags (`git commit -m "subj" -m "body"`). Never literal newlines or `\n` inside `-m`.
3. **No `powershell.exe -NoProfile -Command "<pipeline>"` blobs** — run cmdlets directly, one statement per line.
4. **No `cmd //c "..."` wrappers** — invoke the command directly.
5. **One quoting layer.** No `\$` / `\"` escape stacks; write a `.ps1` file for non-trivial logic instead.
6. **One command per line.** No `&&` / `||` / `;` chains of independent commands. Short linear pipelines.
7. **Known-gap forms always prompt — that is fine.** `python3 -c`, `powershell.exe -File`, `adb -s <serial> ...`, interactive TUI commands. Run them plainly; don't contort to avoid the prompt.

Full source of truth: `docs/agent-command-guidelines/guidance.md` (pretoolhook repo).
