# Requirements: Read-Only CLI Command Security Hook

## Executive Summary
A VS Code Copilot **PreToolUse hook** (`pre-cli-hook-copilot.ps1`) that intercepts CLI commands before execution. Receives JSON via stdin from Copilot's PreToolUse event, analyzes the command against categorized patterns in `cli-commands.json`, and outputs either `allow` (auto-execute) or `ask` (prompt user for approval). Supports PowerShell, AWS CLI, Docker, Terraform, Git, kubectl, Linux/Unix, DOS, and SSH commands.

## Goals
1. Automatically execute read-only CLI commands without human intervention
2. Prompt for approval before executing any command that modifies the system
3. Support complex command chains (using operators like `&&`, `||`, `|`, `;`, `$()`)
4. Analyze each sub-command in a chain/block independently
5. Extract and analyze PowerShell cmdlets hidden inside `{ }` script blocks (if/while/foreach/etc.)
6. Handle multi-line PowerShell commands using `n` (backtick-n) separators

## Requirements

### 1. Hook Configuration
**Location**: VS Code Copilot hooks directory
- The hook integrates with Copilot's PreToolUse event via JSON stdin/stdout
- No external dependencies — pure PowerShell
- Debug mode via `-DebugInputFile` parameter for local testing

### 2. Command Categories

#### 2.1 Read-Only Commands (Auto-Approved)

Commands that can be safely auto-executed:

**Unix/Linux Commands** (Base Commands - Context Matters):
- `ls`, `pwd`, `cd`, `echo`, `cat`, `head`, `tail`, `grep`, `find`, `which`, `whoami`, `id`, `groups`, `file`
- `ps`, `top`, `htop`, `df`, `du`, `free`, `uname`, `hostname`, `date`, `uptime`, `who`
- `git status`, `git log`, `git show`, `git diff`, `git branch`, `git branch -a`, `git remote -v`
- `npm list`, `yarn list`, `pip list`, `composer show`, `gem list`
- `crontab -l` (list only), `iptables -L` (list only), `systemctl list-units` (list only)

Note: **Context matters!** `iptables` could be read-only or modifying depending on flags.

**AWS CLI Commands** (Pattern-Based Detection):
- **Regex for read-only**: `^aws\s+\S+\s+(describe|list|get|show|head)-\S+`
  - Examples: `aws ec2 describe-instances`, `aws s3 ls`, `aws s3api head-object`, `aws rds describe-db-instances`

**Explanation**: AWS CLI commands follow pattern: `aws {service} {verb}-{resource}`
- {service} = service name (ec2, s3, rds, cloudformation, etc.)
- {verb} = operation verb (describe, list, get, show, head)
- Verbs `describe`, `list`, `get`, `show`, `head` are typically read-only

**PowerShell Commands** (by verb):
- `Get-*` verbs: `Get-ChildItem`, `Get-Location`, `Get-Content`, `Get-Process`, `Get-Service`, `Get-EventLog`
- `Test-*`, `Select-*`, `Where-*`, `Measure-*`, `Find-*` verbs
- `Write-Host`, `Write-Output`, `Write-Error` (output operations)

**Docker Commands**:
- `docker ps`, `docker ps -a`, `docker images`, `docker inspect`, `docker logs`, `docker stats`, `docker info`
- `docker-compose ps`, `docker-compose config`, `docker-compose logs`

**Terraform Commands**:
- `terraform show`, `terraform output`, `terraform plan` (note: plan may lock state file)

**SSH Remote Commands** (when all sub-commands are read-only):
- `ssh user@host "cat /var/log/app.log"`
- `ssh user@host "ls -la /opt/app"`
- `ssh user@host "sudo cat /etc/config.conf | grep db_host"`

#### 2.2 Modifying Commands (Require Approval)
Commands that will trigger approval prompts:

**Script Executions** (ALWAYS require approval):
- `./script.sh`, `./configure`, `./anything` (relative path execution)
- `bash script.sh`, `bash /path/to/script.sh`
- `sh script.sh`, `sh /path/to/script.sh`
- `source script.sh`, `. script.sh`
- `python script.py`, `python3 script.py`, `python3.8 script.py`
- `perl script.pl`, `perl /path/to/script.pl`
- `node script.js`, `node /path/to/script.js`
- `./gradlew build`, `./mvnw package` (wrapper scripts)

**Unix/Linux Commands**:
- `rm`, `rmdir`, `mv`, `cp`, `scp`, `rsync` (copy/move operations)
- `touch`, `mkdir`, `mkdir -p`
- `chmod`, `chown`, `chgrp`, `setfacl`
- `useradd`, `userdel`, `usermod`, `passwd`, `groupadd`, `groupdel`
- `mount`, `umount`, `fsck`, `mkfs.*`, `dd`
- `shutdown`, `reboot`, `halt`, `poweroff`, `systemctl` (with stop/start/restart)
- `apt-get install/remove`, `yum install/remove`, `dnf install/remove`
- `pip install/uninstall`, `npm install/uninstall`, `php composer install`
- Database clients with modifying operations:
  - `mysql -e "UPDATE ..."`, `mysql -e "DELETE ..."`, `mysql -e "INSERT ..."`
  - `psql -c "DELETE ..."`, `psql -c "DROP ..."`
  - `redis-cli DEL ...`, `redis-cli FLUSHALL`, `mongosh --eval "db.collection.remove(...)"`

**AWS CLI Commands** (Pattern-Based Detection):
- **Regex for modifying**: `^aws\s+\S+\s+(create|delete|remove|terminate|stop|start|reboot|modify|update|put|upload|download|sync|rm|cp|mv)-\S+`
  - Examples: `aws s3 rm`, `aws s3 cp`, `aws s3 mv`, `aws s3 sync`
  - `aws ec2 terminate-instances`, `aws ec2 create-volume`, `aws ec2 modify-*`

**Special Cases:**
- `aws s3 ls` - read-only (use exact match)
- `aws s3api head-object` - read-only (use exact match for s3api)
- Object operations: `aws s3 rm`, `aws s3 cp`, `aws s3 mv`, `aws s3 sync` - modifying

**Implementation**: 
1. Check if command starts with `aws`
2. Extract service name
3. Extract verb (operation type)
4. Match against Pattern-Based Detection
5. Handle exact matches for special cases

**PowerShell Commands**:
- `Remove-Item`, `Move-Item`, `Copy-Item`, `New-Item`, `Set-Content`, `Clear-Content`
- `Rename-Item`, `Stop-Service`, `Start-Service`, `Restart-Service`
- `Restart-Computer`, `Stop-Computer`
- `New-LocalUser`, `Remove-LocalUser`, `Set-LocalUser`, `Set-ExecutionPolicy`

**Docker Commands**:
- `docker run`, `docker exec`, `docker rm`, `docker rmi`, `docker stop`, `docker kill`
- `docker build`, `docker push`, `docker pull`, `docker commit`, `docker tag`
- `docker network create`, `docker network rm`, `docker volume create`, `docker volume rm`
- `docker-compose up`, `docker-compose down`, `docker-compose exec`, `docker-compose build`

**Terraform Commands**:
- `terraform apply`, `terraform destroy`, `terraform taint`, `terraform import`, `terraform refresh`
- `terraform state mv`, `terraform state rm`, `terraform state push`

**SSH Remote Commands** (when any sub-command is modifying):
- `ssh user@host "cat /tmp/test | grep java && rm /var/a.txt"` (contains rm)
- `ssh user@host "sudo systemctl restart nginx"` (system modification)
- `ssh user@host "bash /tmp/setup.sh"` (executes remote script)
- `ssh user@host "mysql -u root -e \"DROP TABLE users\""` (dangerous DB operation)

#### 2.3 Ambiguous Commands
Commands that require context to determine read-only status:
- `terraform plan` - technically read-only but may lock state
- `kubectl get` vs `kubectl apply` - determined by verb
- `curl` with different flags (-X POST vs GET)
- `wget` downloads files (modifying if saved to disk)

### 3. Command Chain Analysis

#### 3.1 Supported Operators
The hook parses and analyzes the following command operators:
- `&&` (AND — execute second command only if first succeeds)
- `||` (OR — execute second command only if first fails)
- `|` (pipe — pass first command's output to second)
- `;` (semicolon — execute commands sequentially)
- `$()` (command substitution)
- `>` / `>>` (file output redirection — always requires approval, except `2>&1` and `2>/dev/null` which are read-only)
- `n` (PowerShell backtick-n — multi-line separator)

#### 3.2 PowerShell Script Block Extraction (v2.4.0+)

PowerShell commands can hide modifying cmdlets inside `{ }` blocks within control flow statements:

```powershell
while($true) {if (-not $cred) { get-content a.txt`n} Remove-Item b.txt; exit 1 }; Enter-PSSession ...
```

The hook uses a **stack-based, non-recursive algorithm** (`Extract-CmdletsFromScriptBlocks`):

1. **Find ALL `{ }` pairs** via character-by-character stack matching
2. **Process innermost blocks first** — extract content, remove block from line
3. **Split block contents by `;`** once (after ALL blocks extracted)
4. **Split remaining line** (without blocks) by `;`
5. **Combine** all extracted cmdlets and remaining segments

After extraction, `Remove-ControlFlowPrefix` strips control flow remnants (`if (...)`, `while (...)`, `foreach (...)`, `else`, `do`, `}`) from each segment, exposing the actual cmdlet for verb analysis.

**Multi-line support** (v2.5.0): Block extraction runs on the FULL command BEFORE `n` splitting, ensuring `{ }` blocks spanning multiple lines are handled correctly.

**Pipe/chain handling** (v2.8.0/v2.9.0): `Test-IsPowerShellModifying` splits on `|`, `&&`, `||` and checks each segment independently. This prevents `get-content a.txt | Remove-Item b.txt` from being missed (the `Get-` prefix would otherwise short-circuit the check).

#### 3.3 SSH Remote Command Extraction
```
ssh -v -p 2222 user@server "cat /var/log/app.log | grep java && rm /var/a.txt"
                              └────────────────────────────────────────────┘
                                        extracted remote command
```

1. Detect SSH command via `^ssh\s+` pattern
2. Extract remote command from quoted string (supports both `"` and `'`)
3. Extract commands from bash block structures (if/for/while/case)
4. Split by chain operators (`&&`, `||`, `|`, `;`)
5. Analyze each sub-command independently
6. If ALL read-only → auto-approve; if ANY modifying → prompt

#### 3.4 Chain Analysis Logic

**Primary Rule:** If ANY sub-command is modifying or a script → prompt for approval

**Decision Flow (Get-CommandDecision):**
1. Empty command → allow
2. File output redirections (`>`, `>>`, `1>`) → ask (exception: `2>&1`, `2>/dev/null` → allow)
3. Trusted scripts → allow (configured via `trusted_script_files` in config)
4. Script execution (`./script.sh`, `bash deploy.sh`, `python migrate.py`, etc.) → ask
5. SSH commands → extract remote command, analyze each sub-command
6. PowerShell blocks → extract cmdlets from `{ }` blocks, check each
7. Chained commands → split by operators, analyze each segment
8. Single commands → check read-only vs modifying
9. Unknown → ask (safe default)

### 4. Approval Prompt Design (Copilot Hook API)

#### 4.1 JSON Response Format
The hook outputs JSON to stdout:
```json
// Auto-approve:
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"READ_ONLY: Read-only command"}}

// Require approval:
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"MODIFIES: Modifying command"}}
```

#### 4.2 Decision Reasons (Examples)
| Reason | Decision | Example |
|--------|----------|---------|
| `READ_ONLY: Read-only command` | allow | `Get-Process` |
| `MODIFIES: Modifying command` | ask | `Remove-Item file.txt` |
| `PS_BLOCK_MODIFIES: ...` | ask | `if ($x) { Remove-Item a.txt }` |
| `PS_BLOCK_READ_ONLY: ...` | allow | `if ($x) { Get-Process }` |
| `SSH_MODIFIES: Remote command is not confirmed read-only: rm ...` | ask | `ssh user@host "rm file"` |
| `SSH_READ_ONLY: All remote commands are read-only` | allow | `ssh user@host "cat /var/log/app.log"` |
| `CHAIN_MODIFIES: Command chain contains modifying operation(s): ...` | ask | `ls && rm file.txt` |
| `REDIRECT: Command contains file output redirection (modifying)` | ask | `cat file.txt > output.txt` |
| `EXECUTES_SCRIPT: Executes external script (unknown code)` | ask | `bash deploy.sh` |
| `TRUSTED_SCRIPT: Script file is in trusted list` | allow | `pwsh test-runner-copilot.ps1` |

### 5. Configuration File

#### 5.1 File Location
`cli-commands.json` — must be in the same directory as `pre-cli-hook-copilot.ps1`. Alternatively, configurable via the `$ConfigFile` fallback path in the script.

#### 5.2 Configuration Schema (v2.9.0)
```json
{
  "_comment": "CLI Command Patterns for Pre-Tool-Use Hook",
  "version": "2.9.0",

  "trusted_script_files": ["test-runner-copilot.ps1"],
  "script_patterns": ["^\\.\\/[^\\s]+\\.sh$", ...],
  "ssh_pattern": "^ssh\\s+",

  "aws_read_only_patterns": ["^aws\\s+\\S+\\s+(describe|list|get|show|head|lookup)-", ...],
  "aws_modifying_patterns": ["^aws\\s+\\S+\\s+(create|delete|remove|...)-", ...],

  "linux_read_only_commands": ["ls", "pwd", "cd", "echo", ...],
  "linux_modifying_commands": ["rm", "rmdir", "mv", "cp", ...],

  "powershell_read_only_verbs": ["Get-", "Test-", "Select-", ...],
  "powershell_modifying_verbs": ["Remove-", "Move-", "Copy-", "New-", ...],

  "docker_read_only_commands": ["ps", "images", "inspect", "logs", ...],
  "docker_modifying_commands": ["run", "exec", "rm", "rmi", ...],

  "terraform_read_only_commands": ["show", "output", "plan", "validate", ...],
  "terraform_modifying_commands": ["apply", "destroy", "taint", "import", ...],

  "git_read_only_commands": ["status", "log", "show", "diff", ...],
  "git_modifying_commands": ["add", "commit", "push", "pull", ...],

  "kubectl_read_only_commands": ["get", "describe", "logs", "top", ...],
  "kubectl_modifying_commands": ["apply", "create", "delete", "edit", ...],

  "dos_read_only_commands": ["dir", "type", "cd", "echo", ...],
  "dos_modifying_commands": ["del", "rmdir", "copy", "move", ...]
}
```

Note: JSON regex patterns require double-escaped backslashes (e.g., `\\s` instead of `\s`). PowerShell read-only verbs take precedence over modifying verbs (e.g., `Set-Location` is read-only despite `Set-` being a modifying verb).

#### 5.3 User Customization
- Add/remove patterns from JSON — no need to modify the PowerShell script
- `trusted_script_files`: list scripts that bypass the script-execution check
- Regex patterns for AWS/script detection use standard .NET regex syntax
- Plain string lists for Linux commands, PowerShell verbs, Docker/Terraform/Git/kubectl subcommands

## Priority Implementation Order

### Phase 1: Core Hook + PowerShell Block Extraction ✅ COMPLETED
- JSON stdin/stdout interface matching Copilot PreToolUse API
- Stack-based `Extract-CmdletsFromScriptBlocks` for `{ }` block analysis
- Multi-line PowerShell support via `n` splitting
- `Remove-ControlFlowPrefix` for stripping control flow remnants
- `Test-IsPowerShellModifying` with pipe/chain operator handling (`|`, `&&`, `||`)

### Phase 2: All CLI Categories ✅ COMPLETED
- AWS CLI pattern-based detection (describe/list/get vs create/delete/terminate)
- Docker subcommand classification (ps/images/logs vs run/exec/rm)
- Terraform subcommand classification (plan/show vs apply/destroy)
- Git subcommand classification (single + two-word: status/log vs commit/push, stash pop/remote add)
- kubectl subcommand classification (get/describe/logs vs apply/delete/exec)
- Linux/Unix command lists (ls/cat/grep vs rm/mv/chmod)
- DOS/CMD commands + `cmd /c` wrapper extraction
- SSH remote command extraction and sub-analysis

### Phase 3: Chain Analysis & Edge Cases ✅ COMPLETED
- Command chain splitting (`&&`, `||`, `|`, `;`, `$()`)
- Output redirect detection (`>`, `>>`, `1>` → ask; `2>&1`, `2>/dev/null` → allow)
- Script execution detection with trusted script override
- File output redirection detection

### Phase 4: Testing ✅ COMPLETED
- 132 test cases covering all 48 categories — 100% pass rate
- Automated test runner (`test-runner-copilot.ps1`)
- Debug input file for VS Code debugger integration

### 7. Testing Strategy

#### 7.1 Test File Format
`test-commands.txt` — one test per line:
```
Y/N;Category;Command;Description
```
- `Y` = expect auto-approve (allow), `N` = expect manual approval (ask)
- Semicolons in commands are handled by the parser (joins parts between Category and Description)

#### 7.2 Test Runner
`test-runner-copilot.ps1`: builds Copilot-format JSON (`{"tool_name":"run_in_terminal","tool_input":{"command":"..."}}`), pipes to hook via `pwsh -File`, parses the `permissionDecision` from the JSON response, compares expected vs actual.

### 8. Security Considerations

1. **Never auto-approve unknown commands**: When in doubt, prompt for approval (safe default)
2. **Safe defaults**: Empty/corrupt input results in allow — the hook must never block Copilot from functioning
3. **Command injection prevention**: Commands analyzed structurally, not executed
4. **No credential logging**: Log files truncate commands and never store credentials
5. **Read-only precedence**: Read-only verbs take precedence over modifying verbs (e.g., `Set-Location` is read-only despite `Set-` being a modifying verb)
6. **SSH remote command validation**: Incomplete SSH commands (no quoted remote command) default to ask
7. **PowerShell call operator**: `&` is NOT split as a chain operator in PowerShell (it's the call/invoke operator)

### 9. Future Enhancements

1. **Machine learning**: Learn user's approval patterns over time
2. **Integration with policy engines**: Connect to OPA or similar for policy enforcement
3. **Team configuration**: Share configurations across teams
4. **Audit logging**: Log all command approvals/denials for compliance
5. **Remote configuration**: Pull approved command lists from central repository

### 10. Implementation Phases (UPDATED)

**Phase 1: MVP - COMPLETED** ✅
- Hook framework architecture (command + prompt hooks)
- SSH command parsing and remote analysis
- Script execution detection (always prompt)
- AWS pattern-based detection (regex for describe/list/create/delete)
- PowerShell verb-based classification (Get-, Remove-, etc.)
- Linux/Unix command lists (ls, cat, rm, etc.)
- Command chain parsing (&&, ||, |, ;)
- Test framework with 59 test cases
- GitHub repository published: https://github.com/fghxu/pre-tool-use-hook

**Phase 2: DevOps Tools - COMPLETED** ✅
- Fixed read-only command classification (PowerShell, Linux, AWS)
- Moved all patterns from hardcoded arrays to cli-commands.json
- Added Docker command detection (ps, images, logs vs run, exec, rm)
- Added Terraform command detection (show, plan vs apply, destroy)
- Added sudo prefix handling (strips sudo and checks actual command)
- Added output redirect detection (> and >> always prompt)
- Added systemctl to modifying commands
- All 59 test cases passing (100%)

**Phase 3: Polish - IN PROGRESS** ⚠️
- Enhanced prompt formatting with colors
- Detailed command impact analysis
- Add kubectl (Kubernetes) command detection
- Add remaining test cases for edge cases
- Documentation and usage examples

### 11. Test Results (v2.9.0)

**Full Test Suite Run**:

```
==========================================
  Copilot Hook Test Runner
==========================================

Total Tests: 132
Passed: 132 (100%)
Failed: 0 (0%)

Test File: test-commands.txt
Hook Script: pre-cli-hook-copilot.ps1
```

**Breakdown by Category (48 categories, all 100%):**

| Category | Tests | Rate |
|----------|-------|------|
| PowerShell Read-Only | 4 | 100% |
| PowerShell Modifying | 3 | 100% |
| PS Block Modifying (MultiLine, Nested, Simple, Complex, IfElse, Deep, TopLevel) | 22 | 100% |
| PS Block Read-Only (Simple, Multi, WhereObj, Foreach, Nested, EnterPSSession) | 12 | 100% |
| PS MultiLine Read-Only/Modifying | 4 | 100% |
| PS Inline Command | 2 | 100% |
| PS Chain Operators (&&, \|\|) | 4 | 100% |
| Linux Read-Only | 7 | 100% |
| Linux Modifying | 8 | 100% |
| AWS Read-Only | 6 | 100% |
| AWS Modifying | 6 | 100% |
| SSH Read-Only / Chained / Modifying | 7 | 100% |
| Script Execution | 8 | 100% |
| Chained Commands (ReadOnly + Modifying) | 6 | 100% |
| Complex / ComplexPipe (ReadOnly + Modifying) | 4 | 100% |
| kubectl Read-Only / Modifying | 9 | 100% |
| DOS Read-Only / Modifying | 11 | 100% |
| DOS cmd /c Wrapper | 4 | 100% |
| Dollar-Substitution $() | 3 | 100% |
| Trusted/Untrusted Scripts | 4 | 100% |

**Key Findings:**
- All 132 test cases pass (100%) across 48 categories
- PowerShell block extraction correctly handles nested, multi-line, and chained blocks
- Pipe/chain operators (`|`, `&&`, `||`) correctly split and analyzed in both PowerShell and Linux paths
- SSH remote command extraction works for read-only, chained, and modifying remote operations
- File output redirect detection correctly identifies `>`, `>>`, `1>` while allowing `2>&1` and `2>/dev/null`
- DOS `cmd /c` wrapper extraction correctly unwraps and analyzes inner commands
- Trusted scripts auto-approve while unknown scripts prompt
- All patterns loaded from `cli-commands.json` (no hardcoded patterns)

### 12. Review and Update Progress

**Last Updated**: 2026-05-04
**Current Phase**: All phases complete — v2.9.0
**Test Status**: 132/132 passing (100%) across 48 categories
**Next Action**: Edge case testing for deeply nested parens in `Remove-ControlFlowPrefix`, additional real-world multi-line PowerShell scripts