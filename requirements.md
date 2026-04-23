# Requirements: Read-Only CLI Command Security Hook

## Executive Summary
Implement a Claude Code PreToolUse hook that automatically approves read-only CLI commands while requiring human approval for any commands that modify the system. This enhances security and automation for DevOps workflows.

## Goals
1. Automatically execute read-only CLI commands without human intervention
2. Prompt for approval before executing any command that modifies the system
3. Support complex command chains (using operators like &&, ||, |, $)
4. Analyze each sub-command in a chain independently
5. Provide detailed analysis when prompting for approval

## Requirements

### 1. Hook Configuration
**Location**: Global Claude Code configuration
- The hook will be configured in Claude Code's global settings (not project-specific)
- Affects all projects on the user's machine
- Uses native Claude Code PreToolUse hooks (no external dependencies)

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
The hook must parse and analyze the following command operators:
- `&&` (AND - execute second command only if first succeeds)
- `||` (OR - execute second command only if first fails)
- `|` (pipe - pass first command's output to second)
- `;` (semicolon - execute commands sequentially)
- `&` (background execution)
- `$()` (command substitution)
- `` ` `` (backticks - command substitution)
- `>` (redirect stdout)
- `>>` (append stdout)
- `<` (redirect stdin)

#### 3.2 Special Command Types

**SSH Commands:**
```javascript
// Detection patterns
const sshPattern = /^ssh\s+(?:-\w+\s+)*(?:[^@]+@)?[^"\s]+(\s+"[^"]+")/;

// Examples to handle:
ssh user@host "command"                    // Single command
ssh user@host "cmd1 && cmd2 | cmd3"       // Chained commands
ssh -i key.pem user@host "sudo cat file"  // With options
ssh host "$(cat script.sh)"              // Command substitution
```

**Script Execution Commands:**
```javascript
// Patterns to detect (ALWAYS require approval)
const scriptPatterns = [
  /^\.\/[^\s]+\.sh$/,      // ./script.sh
  /^\.\/[^\s]+$/,          // ./anything (any executable)
  /^bash\s+[^\s]+\.sh$/,   // bash script.sh
  /^sh\s+[^\s]+\.sh$/,     // sh script.sh
  /^python\d?\s+[^\s]+/,   // python script.py
  /^perl\s+[^\s]+/,        // perl script.pl
  /^node\s+[^\s]+/,        // node script.js
  /^source\s+[^\s]+/,     // source script.sh
  /^\.\s+[^\s]+/,          // . script.sh (dot operator)
];
```

#### 3.3 Chain Analysis Logic

**Primary Rule:** If ANY sub-command is modifying or a script → prompt for approval

**Decision Flow:**
1. Check if command is script execution → prompt (executes unknown code)
2. Check if command is SSH → extract remote command and analyze sub-commands
3. Parse chained commands separated by operators
4. For each sub-command:
   - Identify CLI type (PowerShell, AWS, Docker, Terraform, Linux/Unix)
   - Check against read-only whitelist for that CLI
   - If not in whitelist → treat as modifying → need approval
5. If **ALL** commands are read-only → **auto-approve**
6. If **ANY** command is modifying → **prompt with details**

**Example Analysis:**
```bash
# Example: ssh user@server01 "cat /opt/a.txt | grep java && sudo rm /var/a.txt"

Step 1: Detect SSH command ✓
Step 2: Extract remote command: "cat /opt/a.txt | grep java && sudo rm /var/a.txt"
Step 3: Parse sub-commands:
  - cat /opt/a.txt (read-only ✓)
  - grep java (read-only ✓)
  - sudo rm /var/a.txt (modifying ✗)
Step 4: Decision: PROMPT (contains rm)
```

**Example 2:**
```bash
# Example: bash deploy.sh

Step 1: Match script pattern ✓
Step 2: Decision: PROMPT (script execution)
```

### 4. Approval Prompt Design

#### 4.1 Prompt Format (Detailed Analysis Mode)
When approval is required, display:
```
⚠️  Command requires approval - Detected modifying operation

Command: aws s3 rm s3://my-bucket/file.txt

Analysis:
  ✓ aws s3 ls s3://my-bucket/ - READ ONLY
  ✗ aws s3 rm s3://my-bucket/file.txt - MODIFYING (will delete file)

This operation will:
  - Delete the file 'file.txt' from S3 bucket 'my-bucket'
  - This action cannot be undone

Chain impact: The subsequent commands will not be executed if this is denied

Proceed with execution? [y/N] 
```

#### 4.2 Prompt Features
- **Command breakdown**: Show each sub-command with its read-only status
- **Impact analysis**: Explain what the modifying command will do
- **Chain awareness**: Inform about dependent commands that won't run if denied
- **Default to No**: User must explicitly type 'y' or 'yes' to approve
- **Timeout**: Prompt automatically denies after 60 seconds of inactivity

### 5. Configuration File

#### 5.1 File Location
`~/.claude/cli-commands.json`

#### 5.2 Configuration Schema
```json
{
  "read_only_commands": {
    "unix": ["ls", "pwd", "cd", "echo", ...],
    "aws_cli": ["aws s3 ls", "aws ec2 describe-*", ...],
    "powershell": ["Get-ChildItem", "Get-Location", ...],
    "docker": ["docker ps", "docker images", ...],
    "terraform": ["terraform show", "terraform output"]
  },
  "modifying_patterns": {
    "unix": ["rm", "mv", "cp", "mkdir", "touch"],
    "aws_cli": ["aws s3 rm", "aws s3 cp", "aws ec2 terminate-*"],
    "powershell": ["Remove-Item", "New-Item", "Stop-Service"],
    "docker": ["docker rm", "docker rmi", "docker run"],
    "terraform": ["terraform apply", "terraform destroy"]
  },
  "settings": {
    "prompt_timeout_seconds": 60,
    "auto_deny_on_timeout": true,
    "show_command_analysis": true,
    "show_impact_preview": true,
    "chain_aware_prompting": true
  }
}
```

#### 5.3 User Customization
- Users can add/remove commands from the JSON configuration
- Configuration reloads automatically when file changes
- Provides default configuration for common DevOps tools

## Priority Implementation Order (UPDATED)

### Phase 1: SSH Command Support (HIGHEST PRIORITY)
Handle remote commands executed via SSH that may contain chained operations.

**Examples:**
- `ssh user@host "cat /var/log/app.log | grep ERROR"` → Auto-approve (read-only)
- `ssh user@host "cat /tmp/test | grep java && rm /var/a.txt"` → Prompt (contains rm)
- `ssh user@host "sudo systemctl restart nginx"` → Prompt (modifies system)

**Requirements:**
1. Detect SSH commands starting with `ssh`
2. Extract remote command from last quoted string
3. Parse chained commands within remote command (`&&`, `||`, `|`, `;`)
4. If ANY sub-command is modifying → prompt for approval
5. Only if ALL sub-commands are read-only → auto-approve

**Implementation Logic:**
```javascript
if (isSSHCommand(command)) {
  const remoteCommand = extractRemoteCommand(command);
  const subCommands = parseChainedCommands(remoteCommand);
  const hasModifying = subCommands.some(cmd => isModifyingCommand(cmd, 'linux'));
  
  if (hasModifying) return { decision: 'prompt', reason: 'SSH remote command contains modifying operations' };
  return { decision: 'approve' };
}
```

### Phase 2: Script Execution Detection
All script executions require manual approval as they execute unknown code.

**Patterns to detect:**
- `./script.sh`
- `./configure`
- `./any-executable`
- `bash script.sh`
- `sh script.sh`
- `python script.py`
- `python3 script.py`
- `perl script.pl`
- `node script.js`
- `/path/to/script`

**Examples:**
- `bash deploy.sh` → Prompt (executes script)
- `./test.sh` → Prompt (executes script)
- `python migrate.py` → Prompt (executes Python script)

**Implementation:**
- Match against regex patterns for script execution
- Always require approval (executes arbitrary code)
- Explain that script contents cannot be verified

### Phase 3: Standard CLI Commands
Handle direct PowerShell, AWS CLI, Docker, Terraform, and Linux/Unix commands.

**Examples:**
- `ls`, `pwd`, `cd` → Auto-approve (read-only)
- `rm file.txt`, `mv a b` → Prompt (modifying)
- `aws s3 ls` → Auto-approve (read-only)
- `aws s3 rm s3://bucket/file` → Prompt (modifying)
- `docker ps` → Auto-approve (read-only)
- `docker rm container` → Prompt (modifying)

### Implementation Approach

#### Fast Command Hook (Shell Script)
- Runs bash script for quick identification
- Exit 0 for auto-approval, Exit 1 for prompt hook
- 5 second timeout

#### Detailed Prompt Hook (LLM Analysis)
- For complex analysis (chained commands, SSH, scripts)
- Uses Claude for safety analysis
- 15 second timeout

#### 6.2 File Structure
```
~/.claude/
├── settings.json           # Main Claude Code settings
├── cli-commands.json       # Read-only command configuration
└── hooks/
    └── pre-cli-hook.sh     # Command hook script
```

#### 6.3 Hook Registration
In `~/.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-cli-hook.sh",
            "timeout": 5
          },
          {
            "type": "prompt",
            "prompt": "Analyze CLI command chain for read-only operations: $TOOL_INPUT\n\nConfiguration: ~/.claude/cli-commands.json\n\nRules:\n1. Parse chained commands separated by &&, ||, |, ;\n2. Check each sub-command against read-only whitelist\n3. If any modifying operation detected, deny with detailed analysis\n4. Explain why approval is needed\n5. Default to safe (deny on uncertainty)\n\nReturn: approve|deny with explanation",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

### 7. Testing Strategy

#### 7.1 Test Cases
1. **Read-only single command**: `ls -la` → auto-approve
2. **Modifying single command**: `rm file.txt` → prompt for approval
3. **Chained all read-only**: `pwd && ls` → auto-approve
4. **Chained with one modifying**: `ls && rm file.txt` → prompt for approval
5. **Complex AWS chain**: `aws s3 ls && aws s3 rm s3://bucket/file` → prompt for approval
6. **Terraform plan**: `terraform plan` → prompt for approval (explain state lock)
7. **Docker: `docker ps && docker images` → auto-approve
8. **Docker: `docker ps && docker rm container` → prompt for approval

#### 7.2 Test Commands
Create test script to validate hook behavior:
```bash
# test-hook.sh
echo "Test 1: Read-only command" && claude "ls -la" && echo "✓ Passed"
echo "Test 2: Modifying command" && claude "touch test.txt" && echo "Should prompt"
...
```

### 8. Security Considerations

1. **Never auto-approve unknown commands**: When in doubt, prompt for approval
2. **Safe defaults**: Timeout or error should result in denial, not approval
3. **Command injection prevention**: Sanitize command strings before parsing
4. **No credential logging**: Never log commands that might contain secrets
5. **Minimal privileges**: Hook scripts should run with minimal required permissions

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

**Phase 2: DevOps Tools - IN PROGRESS** ⚠️
- Fix read-only command classification (PowerShell, Linux, AWS)
- Expand verb patterns and command lists
- Add Docker command detection
- Add Terraform command detection
- Add kubectl (Kubernetes) command detection

**Phase 3: Polish**
- Enhanced prompt formatting with colors
- Detailed command impact analysis
- Configuration hot-reload
- Add remaining test cases for edge cases
- Documentation and usage examples

### 11. Test Results

**Full Test Suite Run**:

```
==========================================
  Pre-CLI Hook Test Runner
==========================================

Total Tests: 59
✅ Passed: 39 (66.1%)
❌ Failed: 20 (33.9%)

Test File: test-commands.txt
Hook Script: pre-cli-hook.ps1
```

**Breakdown by Category:**

| Category | Total | Passed | Failed | Rate | Status |
|----------|-------|--------|--------|------|--------|
| **Script Execution** | 8 | 8 | 0 | 100% | ✅ Working |
| **AWS Modifying** | 6 | 6 | 0 | 100% | ✅ Working |
| **SSH (with chains)** | 6 | 5 | 1 | 83% | ✅ Most Working |
| **Command Chains** | 9 | 9 | 0 | 100% | ✅ Working |
| **PowerShell Read-Only** | 4 | 0 | 4 | 0% | ⚠️ Fix Needed |
| **Linux Read-Only** | 7 | 0 | 7 | 0% | ⚠️ Fix Needed |
| **AWS Read-Only** | 6 | 0 | 6 | 0% | ⚠️ Fix Needed |
| **SSH Simple** | 3 | 1 | 2 | 33% | ⚠️ Fix Needed |

**Key Findings:**
- ✅ Modifying commands correctly prompt (safe)
- ✅ Unknown commands safely default to prompt
- ✅ Command chain analysis works correctly
- ✅ SSH remote command extraction works
- ⚠️ Read-only commands classified as UNKNOWN
- ⚠️ Pattern matching needs strengthening

**Fix Priorities:**
1. PowerShell verb detection (Get-, Test-, etc.)
2. Linux base command recognition (ls, cat, echo, etc.)
3. AWS read-only pattern matching (describe-, list-, get-)
4. SSH simple command recognition

### 12. Review and Update Progress

**Last Updated**: 2026-04-23
**Current Phase**: Phase 1 (MVP) completed, Phase 2 in progress
**Next Action**: Fix read-only command classification patterns

---

**Next Steps**: Proceed with creating the implementation plan and actual hook scripts.