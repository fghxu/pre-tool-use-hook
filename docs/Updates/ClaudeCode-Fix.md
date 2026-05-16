# Claude Code & VS Code Copilot Hook Fixes — May 2026

This document describes four bugs discovered and fixed when integrating the PreToolUse hook with VS Code Copilot (the Coding Agent in VS Code, not Copilot CLI). The hook previously worked only with Claude Code.

---

## Fix 1: stdin Reading — `$input` Does Not Work for Process stdin

### Symptom

VS Code Copilot hook never fired. No log files, no errors — the hook script was never invoked.

### Root Cause

`Hook.ps1` line 19 used `$input | Out-String` to read stdin. `$input` is a PowerShell **pipeline variable** — it only contains data when content is piped via `|` (e.g., `echo '...' | pwsh -File script.ps1`).

When an IDE spawns `pwsh.exe -File script.ps1` as a child process and writes JSON to the process's stdin, the data arrives on `[Console]::In` — the raw console input stream. The `$input` variable sees nothing because no PowerShell pipeline was constructed.

Claude Code CLI invoked the hook via a shell pipe (`echo ... | pwsh ...`), which is why it worked. VS Code Copilot spawns `pwsh` as a child process and writes directly to process stdin.

### Fix

Changed `Hook.ps1` line 19 from:
```powershell
$rawJson = $input | Out-String
```
to:
```powershell
$rawJson = [Console]::In.ReadToEnd()
```

`[Console]::In.ReadToEnd()` reads from the raw stdin stream and works for **both** input methods — piped input (Claude Code CLI) and process stdin (VS Code Copilot). This is a single code path that handles both IDEs.

### Key Insight

A working POC hook (`C:\git\pretooluse\pretooluse.ps1`) that used `[Console]::In.ReadToEnd()` confirmed this was the correct approach. The `$input` variable is only for PowerShell pipeline scenarios, not for general process stdin.

---

## Fix 2: Command Extraction — `tool_input` Is an Object for VS Code Copilot

### Symptom

After Fix 1, the hook fired but classification failed with:
```
Reason: could not extract command from input
Command: [[[]]]
```

### Root Cause

VS Code Copilot sends `tool_input` as a **nested object** with subfields:
```json
{
  "tool_input": {
    "command": "powershell -NoProfile -Command { ... }",
    "explanation": "Running PowerShell script",
    "goal": "Execute the code block directly in console",
    "isBackground": false,
    "timeout": 10000
  }
}
```

Claude Code also sends `tool_input` as an object, but with the command directly in a `.command` sub-field:
```json
{
  "tool_input": {
    "command": "git status",
    "description": "Show working tree status"
  }
}
```

The `tool_name_mapping` in `config.json` mapped `run_in_terminal` → `tool_input` (1 level deep), which returned the entire object. `Get-CommandFromInput` then checked `$current -is [string]` — which failed for objects — and returned `$null` **without falling through to the heuristic fallback**.

Two bugs overlapped here:
1. The config mapping didn't traverse deep enough (`tool_input` → should be `tool_input.command`)
2. `Get-CommandFromInput` had two premature `return $null` statements that prevented fallthrough to the `_WalkForCommand` heuristic

The `bash` mapping key was also lowercase (`"bash"`) while the actual Claude Code tool name is PascalCase (`"Bash"`). PowerShell property key comparison via `-contains` is case-sensitive, so `"bash"` never matched `"Bash"`.

### Fix

**`config.json` — `tool_name_mapping`**:
```json
"tool_name_mapping": {
    "run_in_terminal": "tool_input.command",
    "send_to_terminal": "tool_input.command",
    "Bash": "tool_input.command"
}
```
- Changed path from `"tool_input"` to `"tool_input.command"` for `run_in_terminal` and `send_to_terminal`
- Fixed case: `"bash"` → `"Bash"`

**`HookAdapter.ps1` — `Get-CommandFromInput`**:

1. Removed premature `return $null` when `$fieldPath` is null — now falls through to `_WalkForCommand` heuristic
2. Removed premature `return $null` when traversal result is a non-string object — now tries `.command` sub-field first, then falls through to heuristic
3. Added object `.command` sub-field extraction as a safety net for VS Code Copilot's pattern:
```powershell
# Result is an object — try .command sub-field (VS Code Copilot pattern)
if ($current.PSObject.Properties.Name -contains 'command' -and $current.command -is [string]) {
    $trimmed = $current.command.Trim()
    if ($trimmed.Length -gt 0) {
        return $trimmed
    }
}
```

---

## Fix 3: IDE Detection — VS Code Copilot Masquerades as Claude Code

### Symptom

Log files were named `2026-05-15.claude.*` instead of `2026-05-15.copilot.*` when the hook was triggered by VS Code Copilot.

### Root Cause

VS Code Copilot is built on Claude Code's protocol. It sends almost identical payloads:

| Signal | VS Code Copilot | Claude Code |
|--------|----------------|-------------|
| `hook_event_name` | `"PreToolUse"` (PascalCase) | `"PreToolUse"` (PascalCase) |
| `tool_use_id` | Present | Present |
| `timestamp` | ISO 8601 with ms | ISO 8601 with ms |
| `session_id` | Present | Present |
| `cwd` | Present | Present |

All three original `Detect-IDE` signals voted "ClaudeCode" for VS Code Copilot payloads (3-0). The only reliable differentiator is `transcript_path`:
- VS Code Copilot: `...\GitHub.copilot-chat\transcripts\...`
- Claude Code: `...\\.claude\\...`

### Fix

Added **Signal 4** — `transcript_path` — as a **decisive** signal in `Detect-IDE`. When `transcript_path` is present, it overrides the majority vote of the other signals:

```powershell
# Signal 4: transcript_path — decisive when present
if ($InputObject.transcript_path -match 'GitHub\.copilot-chat') {
    return "Copilot"
}
elseif ($InputObject.transcript_path -match '\.claude') {
    return "ClaudeCode"
}
```

The other 3 signals remain as a fallback for payloads that lack `transcript_path`.

---

## Fix 4: Output Format — VS Code Copilot Expects `hookSpecificOutput` Wrapper

### Symptom

After Fix 3 correctly detected VS Code Copilot, the output format would have been wrong — `Format-Output` had a Copilot path that produced flat output `{ permissionDecision, permissionDecisionReason }` without the `hookSpecificOutput` wrapper.

### Root Cause

The original code assumed "Copilot" = Copilot CLI (which may need flat output). But VS Code Copilot (the Coding Agent) is built on Claude Code and expects the **same** `hookSpecificOutput` wrapper format that Claude Code expects.

### Fix

Simplified `Format-Output` to always produce the `hookSpecificOutput` wrapper regardless of IDE:

```powershell
# Both Claude Code and VS Code Copilot (built on Claude Code) expect the
# hookSpecificOutput wrapper format.
return [PSCustomObject]@{
    hookSpecificOutput = [PSCustomObject]@{
        hookEventName            = "PreToolUse"
        permissionDecision       = $ClassifyResult.Decision
        permissionDecisionReason = $ClassifyResult.Reason
    }
}
```

The IDE label from `Detect-IDE` is still used for log file naming (`.claude.*` vs `.copilot.*`) but no longer affects the output format.

---

## Summary of Changed Files

| File | Change |
|------|--------|
| `src/Hook.ps1` | `$input \| Out-String` → `[Console]::In.ReadToEnd()` |
| `src/HookAdapter.ps1` | Fixed `Get-CommandFromInput` fallthrough, added `.command` extraction, added `transcript_path` signal to `Detect-IDE`, unified `Format-Output` |
| `config.json` | Updated `tool_name_mapping` paths and keys |
