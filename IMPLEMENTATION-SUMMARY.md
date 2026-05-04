# Implementation Summary — Pre-CLI Hook for Copilot (poc3)

## Overview

A VS Code Copilot **PreToolUse hook** (`pre-cli-hook-copilot.ps1`) that intercepts CLI commands before execution. It analyzes each command against categorized patterns in `cli-commands.json` and returns one of two decisions:

- **`allow`** — Auto-execute (all sub-commands confirmed read-only)
- **`ask`** — Prompt user for approval (modifying operation detected)

## Architecture

```
Copilot PreToolUse event
        │
        ▼
  JSON via stdin ───▶ pre-cli-hook-copilot.ps1 ───▶ JSON to stdout
        │                    │                          │
        │            cli-commands.json            { permissionDecision:
        │            (patterns/config)              "allow" | "ask" }
```

### Decision Pipeline (Get-CommandDecision)

1. **Empty command** → allow
2. **File redirections** (`>`, `>>`, `1>`) → ask (exception: `2>&1`, `2>/dev/null` → allow)
3. **Trusted scripts** → allow (configured via `trusted_script_files`)
4. **Script execution** (`./script.sh`, `bash deploy.sh`, `python migrate.py`, etc.) → ask
5. **SSH commands** → extract remote command from quotes, analyze sub-commands
6. **PowerShell blocks** → extract individual cmdlets from `{ }` blocks and `;`/`n` separators
7. **Chained commands** (`&&`, `||`, `|`, `;`) → split and analyze each segment
8. **Single commands** → check read-only vs modifying
9. **Unknown** → ask (safe default)

## Supported Tool Categories

| Category | Detection | Examples |
|----------|-----------|----------|
| **PowerShell** | Verb-based (Get-, Remove-, etc.) + `{ }` block extraction | `Get-Process`, `Remove-Item`, `if ($x) { ... }` |
| **AWS CLI** | Regex patterns for read-only vs modifying verbs | `aws ec2 describe-instances`, `aws s3 rm ...` |
| **Docker** | Subcommand extraction (`docker ps` vs `docker rm`) | `docker ps`, `docker-compose down` |
| **Terraform** | Subcommand extraction (`plan` vs `apply`) | `terraform plan`, `terraform destroy` |
| **Git** | Subcommand extraction (single + two-word) | `git status`, `git stash pop` |
| **kubectl** | Subcommand extraction (single + two-word) | `kubectl get pods`, `kubectl delete pod` |
| **Linux/Unix** | Base command name lookup | `ls`, `cat`, `grep` (read-only); `rm`, `mv`, `chmod` (modifying) |
| **DOS/CMD** | Base command name lookup + `cmd /c` wrapper | `dir`, `type` (read-only); `del`, `rmdir` (modifying) |
| **SSH** | Remote command extraction and sub-analysis | `ssh user@host "cat /var/log/app.log"` |
| **Scripts** | Regex patterns (`./script.sh`, `bash`, `python`, `node`, etc.) | Always ask unless in trusted list |

## Key Algorithm: PowerShell Block Extraction

The most complex part of the hook. PowerShell commands can contain control flow blocks with `{ }` that hide modifying cmdlets:

```powershell
while($true) {if (-not $cred) { get-content a.txt`n} Remove-Item b.txt; exit 1 }; Enter-PSSession ...
```

### Stack-Based Extraction (v2.4.0+)

`Extract-CmdletsFromScriptBlocks` uses a non-recursive, 4-phase stack algorithm:

1. **Find ALL `{ }` pairs** via stack matching, process innermost first
2. **Split block contents by `;`** once (after ALL blocks extracted, not during)
3. **Split remaining line** (without blocks) by `;`
4. **Combine** block cmdlets + remaining segments into a single `;`-separated string

`Remove-ControlFlowPrefix` then strips `if (...)`, `while (...)`, `foreach (...)`, `else`, `do`, `}` remnants from each segment, exposing the actual cmdlet for analysis.

### Multi-line Support (v2.5.0)

`Extract-CmdletsFromScriptBlocks` runs on the FULL command BEFORE `n` splitting. This ensures `{ }` blocks spanning multiple `n`-separated lines are extracted correctly. `n` in block contents is cleaned (replaced with space).

### Pipe/Chain Handling in PowerShell (v2.8.0+)

`Test-IsPowerShellModifying` splits piped/chained commands (`|`, `&&`, `||`) and checks each segment independently. This prevents cases like `get-content a.txt | Remove-Item b.txt` from being missed (the `Get-` prefix would otherwise short-circuit the check).

## Configuration: cli-commands.json

All patterns are externalized into `cli-commands.json` (v2.9.0). No patterns are hardcoded in the hook script.

Sections:
- `script_patterns` — regex for script execution detection
- `ssh_pattern` — SSH command detection
- `aws_read_only_patterns` / `aws_modifying_patterns` — AWS CLI regex
- `linux_read_only_commands` / `linux_modifying_commands` — Linux command lists
- `powershell_read_only_verbs` / `powershell_modifying_verbs` — PowerShell verb lists
- `docker_read_only_commands` / `docker_modifying_commands` — Docker subcommands
- `terraform_read_only_commands` / `terraform_modifying_commands` — Terraform subcommands
- `git_read_only_commands` / `git_modifying_commands` — Git subcommands
- `kubectl_read_only_commands` / `kubectl_modifying_commands` — kubectl subcommands
- `dos_read_only_commands` / `dos_modifying_commands` — DOS/CMD commands
- `trusted_script_files` — scripts that bypass the script-execution check

## Test Framework

- **Test file**: `test-commands.txt` — one test per line, format `Y/N;Category;Command;Description`
- **Test runner**: `test-runner-copilot.ps1` — reads test file, sends each command as JSON stdin to the hook, compares expected vs actual decision
- **Debug input**: `debug-input.json` — sample Copilot hook payload for `-DebugInputFile` parameter

## Version History

| Version | Change |
|---------|--------|
| v2.4.0 | Stack-based `Extract-CmdletsFromScriptBlocks` (replaced recursive approach) |
| v2.5.0 | Multi-line `{ }` block support via `n` handling |
| v2.6.0 | Trusted script files mechanism |
| v2.7.0 | Segment trimming before `Remove-ControlFlowPrefix` + `originalHadBlocks` check |
| v2.8.0 | `Test-IsPowerShellModifying` pipe handling (`\|`) |
| v2.9.0 | Extended chain operator handling (`&&`, `\|\|`) in PowerShell block analysis + full test coverage |

## Test Results (Current)

```
Total Tests: 132
Passed: 132 (100%)
Failed: 0
Categories: 48 (all at 100%)
```

## Files

| File | Purpose |
|------|---------|
| `pre-cli-hook-copilot.ps1` | Main hook script (~1300 lines) |
| `cli-commands.json` | Configuration with all command patterns |
| `test-commands.txt` | 132 test cases across all categories |
| `test-runner-copilot.ps1` | Automated test runner |
| `debug-input.json` | Sample hook input for debugging |
| `requirements.md` | Full requirements documentation |
| `current.md` | Technical deep-dive on algorithms and fixes |
| `problem.md` | Original bug analysis (PowerShell block extraction) |
