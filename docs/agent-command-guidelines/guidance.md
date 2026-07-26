# Command Guidelines for AI Agents (PreToolUse-Hook Friendly)

A PreToolUse safety hook on this machine classifies every shell command before it runs. Commands it can classify run immediately (read-only) or prompt once (modifying). Commands it **cannot parse** are reported as "unknown command" and force a manual review every single time — slowing the whole session.

Follow these rules when composing commands. They do not limit what you may do — only the *shape* of what you emit.

## R1 — Never use heredocs

Do not write files or pass multi-line input with heredocs (`<<EOF`, `<<'EOF'`, `@"..."@`). Embedded content shatters into phantom "commands" and is the single largest source of unknown classifications.

**Instead:** use the file-writing tool (Write / create) to create the file, then run commands against it.

## R2 — Multi-line git messages: repeated `-m`, never embedded newlines

```
git commit -m "Subject line" -m "Body paragraph" -m "Co-Authored-By: Name <n@x>"
git tag -a v1.0 -m "Release 1.0"
```

Never: a literal multi-line `-m` string, `\n` escapes inside `-m`, or `git commit -F -` fed by a heredoc.

## R3 — No `powershell.exe -Command` blobs

Do not wrap pipelines in `powershell.exe -NoProfile -Command "Get-X | Where-Object {...} | Format-Y"` — the wrapper plus nested quoting is unclassifiable.

**Instead:** run the pipeline directly in the shell tool, one statement per line. If a wrapper is truly unavoidable, keep the inner command a single simple cmdlet.

## R4 — No `cmd //c` wrappers

Invoke the real command directly. `cmd //c "sc query x"` → `sc query x`.

## R5 — One quoting layer

No `\$var` / `\"` escape stacks inside nested strings. If the logic needs variables and quoting, write a `.ps1` file with the file tool and run that.

## R6 — One command per line

Do not chain independent commands with `&&`, `||`, or `;` — emit them as separate invocations. Keep pipelines short and linear.

## R7 — Known-gap commands: run plainly, expect the prompt

A few forms are **intentionally** not auto-classified and will always prompt (the hook is fail-safe by design):

- `python3 -c "..."` / `python -c "..."` (arbitrary code)
- `powershell.exe -File script.ps1` (opaque script file)
- `adb` with `-s <serial>` global flags, `adb exec-out`, `adb shell` forms outside the read-only list (`getprop`, `pm list`)
- Interactive/TUI commands (`top` without `-b`, `less` on a TTY)

Run them unwrapped and simply quoted when the task needs them. Do not contort a command to dodge the prompt.

*(Maintainers: when `config.json` adds coverage for a command, remove it from this list.)*

## Quick reference

| Task | Emit this | Not this |
|---|---|---|
| Write a file | file-writing tool | `cat <<EOF > f` |
| Multi-line commit | `git commit -m a -m b` | `git commit -m "a\nb"` or heredoc |
| PowerShell pipeline | direct cmdlet line | `powershell.exe -NoProfile -Command "..."` |
| CMD builtin | direct command | `cmd //c "..."` |
| Script with logic | write `.ps1`, then run it | inline `-Command` escape soup |
