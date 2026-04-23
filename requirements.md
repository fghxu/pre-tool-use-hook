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

**Unix/Linux Commands**:
- `ls`, `pwd`, `cd`, `echo`, `cat`, `head`, `tail`, `grep`, `find`, `which`, `whoami`, `id`, `groups`
- `ps`, `top`, `htop`, `df`, `du`, `free`, `uname`, `hostname`, `date`, `uptime`
- `git status`, `git log`, `git show`, `git diff`, `git branch`, `git remote -v`
- `npm list`, `yarn list`, `pip list`, `composer show`, `gem list`

**AWS CLI Commands** (read-only operations):
- `aws s3 ls`, `aws s3api head-object`, `aws ec2 describe-instances`, `aws ec2 describe-vpcs`
- `aws rds describe-db-instances`, `aws cloudformation describe-stacks`
- Most `describe-*`, `list-*`, `get-*`, `head-*` operations

**PowerShell Commands**:
- `Get-ChildItem`, `Get-Location`, `Get-Content`, `Get-Process`, `Get-Service`
- `Get-EventLog`, `Get-Date`, `Get-Host`, `Get-Command`, `Get-Help`

**Docker Commands**:
- `docker ps`, `docker images`, `docker inspect`, `docker logs`, `docker stats`
- `docker-compose config`, `docker-compose ps`

**Terraform Commands**:
- `terraform show`, `terraform output`, `terraform plan` (though plan is borderline - read-only but may require state locking)

#### 2.2 Modifying Commands (Require Approval)
Commands that will trigger approval prompts:

**Unix/Linux Commands**:
- `rm`, `rmdir`, `mv`, `cp`, `touch`, `mkdir`, `chmod`, `chown`, `useradd`, `userdel`
- `mount`, `umount`, `shutdown`, `reboot`, `systemctl` (with stop/start/restart)
- `apt-get`, `yum`, `dnf`, `pip install/uninstall`
- Database commands: `mysql`, `psql`, `mongo`, `redis-cli` with INSERT/UPDATE/DELETE

**AWS CLI Commands** (modifying operations):
- `aws s3 rm`, `aws s3 cp`, `aws s3 mv`, `aws s3 sync`
- `aws ec2 terminate-instances`, `aws ec2 create-volume`
- All `delete-*`, `remove-*`, `terminate-*`, `create-*` operations

**PowerShell Commands**:
- `Remove-Item`, `Move-Item`, `Copy-Item`, `New-Item`, `Set-Content`, `Clear-Content`
- `Stop-Service`, `Start-Service`, `Restart-Service`
- `New-LocalUser`, `Remove-LocalUser`, `Set-ExecutionPolicy`

**Docker Commands**:
- `docker run`, `docker exec`, `docker rm`, `docker rmi`, `docker stop`, `docker kill`
- `docker-compose up`, `docker-compose down`, `docker-compose exec`
- `docker build`, `docker push`, `docker pull`

**Terraform Commands**:
- `terraform apply`, `terraform destroy`, `terraform taint`, `terraform import`

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

#### 3.2 Chain Analysis Logic
For each command in a chain:
1. Parse the command string to extract all sub-commands
2. Evaluate each sub-command individually against the read-only whitelist
3. If **ALL** sub-commands are read-only → auto-approve
4. If **ANY** sub-command is modifying → prompt for approval (show which command is modifying and why)

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

### 6. Implementation Approach

#### 6.1 Hook Architecture
Multi-stage validation using both command and prompt hooks:

**Stage 1: Fast Command Hook (Shell Script)**
- Runs a bash script to quickly identify obviously read-only commands
- Exits with status 0 for auto-approval
- Exits with status 1 to defer to prompt hook
- Timeout: 5 seconds

**Stage 2: Detailed Prompt Hook (LLM Analysis)**
- For commands that need deeper analysis
- Uses Claude to analyze command safety
- Generates detailed approval prompts
- Handles complex chained commands
- Timeout: 15 seconds

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

### 10. Implementation Phases

**Phase 1: MVP** (Week 1)
- JSON configuration file structure
- Basic read-only command lists for Unix/Linux
- Simple command hook for common commands
- Prompt hook for analysis
- Support for && and | operators

**Phase 2: DevOps Tools** (Week 2)
- Add AWS CLI command lists
- Add PowerShell command lists
- Add Docker command lists
- Add Terraform command lists
- Support for all chained operators

**Phase 3: Polish** (Week 3)
- Enhanced prompt formatting
- Command impact analysis
- Configuration reload on change
- Comprehensive testing
- Documentation and examples

---

**Next Steps**: Proceed with creating the implementation plan and actual hook scripts.