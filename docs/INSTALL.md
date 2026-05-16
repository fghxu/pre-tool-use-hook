# Installing the PreToolUse Hook

This guide walks through installing the PreToolUse hook system for Claude Code and GitHub Copilot. No prior hook experience is assumed.

## Prerequisites

- **PowerShell 7+** (pwsh.exe) — required. Windows PowerShell 5.1 will not work.
  ```powershell
  # Check your version:
  pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
  # Should show Major >= 7
  ```
  Install from: `winget install Microsoft.PowerShell` or https://github.com/PowerShell/PowerShell

- **Git** (optional, for cloning)

## Quick Install

```powershell
# Clone to a location of your choice:
git clone <repo-url> C:\git\pretoolusehook

# Or just copy the folder anywhere you like — no installer needed.
# The hook finds its own dependencies relative to Hook.ps1 via $PSScriptRoot.

# Verify everything loads:
cd C:\git\pretoolusehook
pwsh -NoProfile -Command ". .\src\ConfigLoader.ps1; . .\src\Parser.ps1; . .\src\Resolver.ps1; . .\src\HookAdapter.ps1; . .\src\Classifier.ps1; Write-Host 'All modules loaded successfully'"
```

### Step 3: Adjust the Config for Your System

Under the root dir of the cloned location  (e.g. C:\git\pretoolusehook\).   Edit `config.json` to set your log path for the hook execution:

```json
{
  "log_file_path": "C:/Users/<user>/pretoolusehook/logs/"
}
```

On Windows, use a full path or a path relative to your user directory. On macOS/Linux, `~/pretoolusehook/logs/` is a good default.


## Where to Put the Project

The project has **no fixed location requirement**. You can place it anywhere. The hook script finds its dependencies relative to its own location using `$PSScriptRoot`.

Recommended locations:

| Platform | Path |
|----------|------|
| Windows | `C:\git\pretoolusehook\` |
| macOS/Linux | `~/pretoolusehook/` or `~/git/pretoolusehook/` |

## Installing for Claude Code

### Step 1: Understand How Claude Code Hooks Work

Claude Code invokes hooks by piping a JSON object to your script's **stdin** and reading the decision from your script's **stdout**. A `PreToolUse` hook fires before every tool call.

The input JSON looks like this (sent to stdin):
```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm -rf /tmp/build",
    "description": "Remove build directory"
  },
  "tool_use_id": "call_01ABC123...",
  "hook_event_name": "PreToolUse",
  "timestamp": "2026-05-15T14:30:00.123Z",
  "session_id": "...",
  "cwd": "/path/to/project",
  "transcript_path": "/home/user/.claude/projects/.../session.jsonl",
  "permission_mode": "acceptEdits"
}
```

The hook must output a decision JSON on stdout:
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"rm -rf (medium)"}}
```

### Step 2: Configure the Hook

Hooks are configured in Claude Code's settings. You have two options for where to place this configuration:

#### Option A: Project-Level (`.claude/settings.local.json`)

Create or edit `.claude/settings.local.json` in your project root. This only affects the current project. **This is the recommended location** — Claude Code watches project-level `settings.local.json` for hook changes.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -NonInteractive -File C:/git/pretoolusehook/src/Hook.ps1"
          }
        ]
      }
    ]
  }
}
```

The `"matcher": "*"` forwards **all** tool calls to the hook script — regardless of tool name. Filtering (which tools to intercept, which to ignore) is handled inside the hook script via `intercept_tool_name` and `ignore_tool_name` in `config.json`. This way new tool names added by Claude Code in the future are automatically visible to the hook.

**Important formatting notes:**
- Each matcher must use the nested `"hooks"` array with `{"type": "command", "command": "..."}` — flat `{"matcher": "*", "command": "..."}` is silently rejected by schema validation
- Use forward slashes in paths (`C:/git/...`) — backslashes may be mangled by bash
- Do NOT use `-NoLogo` in the pwsh command — it can cause pwsh to reject arguments in Claude Code's shell context

#### Option B: User-Level Global (`~/.claude/settings.json`)

Create or edit `~/.claude/settings.json` (user home `.claude` directory). This applies the hook to **all** your Claude Code projects.

Use the same format as Option A above, adjusting the path to Hook.ps1 if your clone location differs.

> **Note:** Hooks should go in `settings.json`, not `settings.local.json`.


### Step 4: macOS/Linux Notes

On macOS and Linux, adjust the path separators and the PowerShell command:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -NonInteractive -File ~/pretoolusehook/src/Hook.ps1"
          }
        ]
      }
    ]
  }
}
```

Make sure `pwsh` is on your PATH:
```bash
which pwsh
# Should output something like /usr/local/bin/pwsh or /opt/microsoft/powershell/7/pwsh
```

### Step 5: Verify the Installation

```powershell
# Test that the hook loads and can classify a command:
cd C:\git\pretoolusehook
echo '{"tool_name":"Bash","tool_input":{"command":"Get-Process"},"hook_event_name":"PreToolUse","timestamp":"2026-05-15T14:30:00.123Z","tool_use_id":"test123","transcript_path":"C:\\Users\\Frank\\.claude\\projects\\test\\session.jsonl"}' | pwsh -NoProfile -NonInteractive -File src/Hook.ps1

# Expected output (compressed JSON):
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-only"}}

# Test with a modifying command:
echo '{"tool_name":"Bash","tool_input":{"command":"Stop-Process -Name notepad"},"hook_event_name":"PreToolUse","timestamp":"2026-05-15T14:30:00.123Z","tool_use_id":"test456","transcript_path":"C:\\Users\\Frank\\.claude\\projects\\test\\session.jsonl"}' | pwsh -NoProfile -NonInteractive -File src/Hook.ps1

# Expected output:
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Stop-Process (low)"}}
```

## Installing for VS Code Copilot (Coding Agent)

> **Important**: VS Code Copilot (the Coding Agent in VS Code) and Copilot CLI are different products with different hook configuration formats and locations. This section covers VS Code Copilot. For Copilot CLI, see the section below.

### Step 1: Understand How VS Code Copilot Hooks Work

VS Code Copilot is built on Claude Code's protocol. It sends JSON to the hook's **stdin** via process spawn (not a shell pipe). The payload looks like this:

```json
{
  "tool_name": "run_in_terminal",
  "tool_input": {
    "command": "powershell -NoProfile -Command { ... }",
    "explanation": "Running PowerShell script",
    "goal": "Execute the code block",
    "isBackground": false,
    "timeout": 10000
  },
  "tool_use_id": "toolu_bdrk_...__vscode-...",
  "hook_event_name": "PreToolUse",
  "timestamp": "2026-05-15T22:25:06.607Z",
  "session_id": "...",
  "cwd": "c:\\path\\to\\project",
  "transcript_path": "c:\\Users\\...\\GitHub.copilot-chat\\transcripts\\..."
}
```

Key differences from Claude Code CLI:
- `tool_input` is always an object with subfields (`command`, `explanation`, `goal`, `isBackground`, `timeout`)
- Contains `transcript_path` with `GitHub.copilot-chat` in the path
- `tool_use_id` ends with `__vscode-...`

The hook's `Detect-IDE` function uses `transcript_path` to identify VS Code Copilot payloads.

### Step 2: Configure the Hook

VS Code Copilot reads hook configuration from the workspace `.claude/settings.local.json` or user `.claude/settings.json`. The format is the **same nested format** as Claude Code:

**Option A: Workspace-Level** — Create or edit `.claude/settings.local.json` in your project root:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -NonInteractive -File C:/git/pretoolusehook/src/Hook.ps1"
          }
        ]
      }
    ]
  }
}
```

**Option B: User-Level** — Edit `~/.claude/settings.json` (user home `.claude` directory):

Use the same format as Option A. This applies the hook to all VS Code workspaces.

> **Note**: VS Code Copilot may also read hooks from `.github/hooks/*.json` in the workspace. The `.claude/settings.local.json` approach is more consistently supported.

### Step 3: Verify

```powershell
# Test from Claude Code CLI, sample prompt:
Write a PowerShell code block to check if there is a file named test.txt under the c:\temp, if yes, output its content, use custom recursively function to search the file in each subdirectory, run the code block directly in the console, do not save scripts and run from disk.

```


Both Claude Code and VS Code Copilot use the same `hookSpecificOutput` wrapper output format.

---

## Installing for Copilot CLI

Copilot CLI is a command-line tool separate from VS Code Copilot. Its hook protocol differs significantly.

### Step 1: Understand How Copilot CLI Hooks Work

Copilot CLI sends JSON with these differences:
- `hook_event_name` is `"preToolUse"` (camelCase)
- No `tool_use_id` field
- `timestamp` is a Unix epoch integer (e.g., `1715568000`)

### Step 2: Configure the Hook

#### Option A: Workspace-Level (`Project/.github/hooks/pretooluse.json`)

json file name does not matter.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "pwsh -NoProfile -NonInteractive -File C:/git/pretoolusehook/src/Hook.ps1",
        "timeout": 10
      }
    ]
  }
}
```

#### Option B: User-Level Global (`~/.copilot/hooks/pre-cli-hook.json`)

Copilot CLI hook configuration is placed at `~/.copilot/hooks/pre-cli-hook.json`:

```json
{
  "version": 1,
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -NonInteractive -File C:/git/pretoolusehook/src/Hook.ps1"
          }
        ]
      }
    ]
  }
}
```

### Step 3: Verify

```powershell
# Test from VScode copilot, sample prompt:
Write a PowerShell code block to check if there is a file named test.txt under the c:\temp, if yes, output its content, use custom recursively function to search the file in each subdirectory, run the code block directly in the console, do not save scripts and run from disk.

```


## Customizing the Configuration

### Adding a New Read-Only Command

Edit `config.json`, find the right domain section, and add to `read_only`:

```jsonc
{
  "commands": {
    "Linux": {
      "read_only": [
        // ... existing entries ...
        { "name": "ncdu", "patterns": ["ncdu *"], "description": "NCurses disk usage analyzer (read-only)" }
      ],
      "modifying": [ /* ... */ ]
    }
  }
}
```

### Adding a New Modifying Command with Risk Level

```jsonc
{
  "commands": {
    "Linux": {
      "modifying": [
        // ... existing entries ...
        { "name": "truncate", "patterns": ["truncate -s *", "truncate --size *"], "risk": "medium", "description": "Truncate shrinks or extends files" }
      ]
    }
  }
}
```

Risk levels: `"low"`, `"medium"`, `"high"`. They're informational — they appear in the reason string shown to the user.

### Adding a New Tool Name to Intercept

If your IDE uses a tool name not already in the intercept list:

```jsonc
{
  "intercept_tool_name": [
    "send_to_terminal",
    "run_in_terminal",
    "execute_command"  // <-- add new tool name here
  ],
  "tool_name_mapping": {
    // ...
    "execute_command": "command"  // <-- add the field path mapping
  }
}
```

### Adding a Trusted Pattern (Always Allow)

```jsonc
{
  "trusted_pattern": [
    "^git status$",
    "^git diff$",
    "^npm test$"  // <-- always allow npm test
  ]
}
```

### Adding an Untrusted Pattern (Always Block)

```jsonc
{
  "untrusted_pattern": [
    "^rm -rf /$",
    "^kubectl delete --all$",
    "^git push --force origin main$"  // <-- always block force push to main
  ]
}
```

### Adding a New Command Domain

If you want to classify commands for a tool not currently supported (e.g., `pip`, `cargo`), add a new domain section:

```jsonc
{
  "commands": {
    // ... existing domains ...
    "Python_Pip": {
      "read_only": [
        { "name": "pip list", "patterns": ["pip list *", "pip show *", "pip freeze *"], "description": "List/show installed packages" }
      ],
      "modifying": [
        { "name": "pip install", "patterns": ["pip install *"], "risk": "medium", "description": "Install packages" },
        { "name": "pip uninstall", "patterns": ["pip uninstall *"], "risk": "high", "description": "Remove packages" }
      ]
    }
  }
}
```

Then add the binary prefix to `KnownBinaryPrefixes` in `src/Parser.ps1` and add patterns to `Get-CommandDomain` if automatic domain detection is needed.

## Logs

The hook writes logs split by IDE into four files daily:

| File | Content | IDE |
|------|---------|-----|
| `YYYY-MM-DD.claude.records.jsonl` | Raw JSON input records | Claude Code |
| `YYYY-MM-DD.claude.log` | Human-readable classification log | Claude Code |
| `YYYY-MM-DD.copilot.records.jsonl` | Raw JSON input records | Copilot |
| `YYYY-MM-DD.copilot.log` | Human-readable classification log | Copilot |

**JSONL Records** (e.g., `2026-05-15.claude.records.jsonl`):
```
{"received_at":"2026-05-15T19:30:00.123Z","raw":{"tool_name":"run_in_terminal","tool_input":"Get-Process","hook_event_name":"PreToolUse","timestamp":"2026-05-15T14:30:00.123Z","tool_use_id":"toolu_01ABC..."}}
```

**Human-Readable Logs** (e.g., `2026-05-15.claude.log`):
```
[2026-05-15 14:30:01.234] IDE:ClaudeCode Tool:[run_in_terminal] Decision:[allow] Time:[6ms]
  Reason: read-only
  Command: [[[Get-Process]]]

[2026-05-15 14:30:05.456] IDE:ClaudeCode Tool:[run_in_terminal] Decision:[ask] Time:[5ms]
  Reason: terraform apply (high)
  Command: [[[terraform apply -auto-approve]]]
```

Set the log directory in `config.json`:
```json
{
  "log_file_path": "~/pretoolusehook/logs/"
}
```

## Testing Your Installation

Run the full test suite to verify everything works:

```powershell
cd C:\git\pretoolusehook
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "C:\git\pretoolusehook\test\test-cases.xml"
```

Expected: `339 passed, 0 failed, 100%`.

If you change `config.json`, re-run the tests to verify nothing broke.

## Troubleshooting

### Hook not firing at all (no log files created)

This is usually a configuration issue. Check these items in order:

**1. Verify the hook schema format**

Claude Code requires a nested `"hooks"` array with `{"type": "command", "command": "..."}`. Flat format `{"matcher": "X", "command": "..."}` is silently rejected by schema validation.

```jsonc
// WRONG (schema rejects silently):
{"matcher": "*", "command": "pwsh ..."}

// CORRECT:
{"matcher": "*", "hooks": [{"type": "command", "command": "pwsh ..."}]}
```

**2. Check which settings file is loaded**

Claude Code watches these files (shown in its debug log at startup):
- `C:\Users\<name>\.claude\settings.json`
- `<project>\.claude\settings.json`
- `<project>\.claude\settings.local.json`

The **project-level** `.claude/settings.local.json` is the recommended place for hook config. The user-level `settings.local.json` may not be monitored.

To check: Search Claude Code's debug log for `Matched 0 unique hooks` — this means no hooks were found despite being configured, indicating a schema format problem.

**3. Check for pwsh command errors**

If the debug log shows `Hook PreToolUse:Bash (PreToolUse) error:` followed by pwsh usage/help text, the pwsh command arguments are being rejected. Common causes:
- `-NoLogo` flag — remove it; it can cause pwsh to reject arguments in Claude Code's shell context
- Backslash paths (`C:\\git\\...`) — use forward slashes (`C:/git/...`) which are safer through bash
- Missing `-File` before the script path

Correct command: `pwsh -NoProfile -NonInteractive -File C:/git/pretoolusehook/src/Hook.ps1`

### The hook runs but every command is "ask"

Check that the hook config loaded correctly:
```powershell
cd C:\git\pretoolusehook
pwsh -NoProfile -Command ". .\src\ConfigLoader.ps1; `$c = Load-Config -Path '.\config.json'; `$c._compiled.trusted.Count; `$c._compiled.untrusted.Count"
```

### "Hook: Failed to parse JSON input"

The IDE is sending JSON the hook doesn't expect. Run this to see what the IDE is sending:
```powershell
# Add to Hook.ps1 temporarily after Step 1:
$rawJson | Out-File -FilePath "debug_input.json" -Encoding UTF8
```

Then inspect `debug_input.json` to see the actual input format.

### "Cannot find path" error on macOS/Linux

Use forward slashes and avoid Windows-style paths in all config files. The `log_file_path` in `config.json` must use forward slashes on macOS/Linux.

### Performance warnings (>500ms)

The hook logs a warning if classification exceeds 500ms. If you see this frequently:
- Check that antivirus isn't scanning PowerShell scripts on every invocation
- Reduce the number of patterns in `config.json`
- Consider removing unused domains from the config

If classification exceeds **1000ms**, the hook forces an "ask" decision as a safety fallback.

### Hook works in terminal but not in the IDE

Ensure the IDE is invoking `pwsh` (PowerShell 7), not `powershell` (Windows PowerShell 5.1). The hook requires PowerShell 7+ for AST parsing features.

```powershell
# Check what "pwsh" resolves to:
Get-Command pwsh | Select-Object Source
# Should show a PowerShell 7 path, not System32\WindowsPowerShell
```
