<#
.SYNOPSIS
Claude Code CLI Security Hook - PowerShell Version
Analyzes PowerShell commands and approves read-only operations while denying modifying ones

.DESCRIPTION
This hook script integrates with Claude Code's PreToolUse hooks to:
- Auto-approve read-only commands (PowerShell, AWS, Docker, Terraform, Linux/Unix, SSH)
- Prompt for approval on modifying operations
- Parse command chains (&&, ||, |, ;) and analyze each sub-command
- Handle SSH commands specially (extract remote command and analyze it)
- Detect script executions and always prompt for approval
- Support pattern-based AWS detection (describe-, create-, delete- etc)

.NOTES
Returns exit code 0 for approval, 1 for denial (prompt required)
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string]$FullCommand
)

# Configuration - Regex Patterns
# ==================================================

# Script Execution Patterns - Always prompt (execute unknown code)
$ScriptPatterns = @(
    '^\.\/[^\s]+\.sh$',      # ./script.sh
    '^\.\/[^\s]+$',          # ./anything
    '^bash\s+[^\s]+\.sh$',   # bash script.sh
    '^sh\s+[^\s]+\.sh$',     # sh script.sh
    '^sh\s+[^\s]+$',          # sh /path/to/script
    '^python\d?\s+[^\s]+$',   # python script.py
    '^python\d?\.\d?\s+[^\s]+$', # python3.8 script.py
    '^perl\s+[^\s]+$',        # perl script.pl
    '^node\s+[^\s]+$',        # node script.js
    '^source\s+[^\s]+$',      # source script.sh
    '^\.\s+[^\s]+$',          # . script.sh
    '^\.\/[^\s]+',            # ./gradlew, ./configure
    '^\.\/gradlew\s+',         # ./gradlew build
    '^\.\/mvnw\s+'            # ./mvnw package
)

# SSH Command Pattern
$SSHPattern = '^ssh\s+'

# AWS Read-Only Patterns (pattern-based to avoid hardcoding)
$AWSReadOnlyPatterns = @(
    '^aws\s+\S+\s+(describe|list|get|show|head)-',  # describe-, list-, get-, show-, head-
    '^aws\s+s3\s+ls'                                   # aws s3 ls (special case)
)

# AWS Modifying Patterns
$AWSModifyingPatterns = @(
    '^aws\s+\S+\s+(create|delete|remove|terminate|stop|start|reboot|modify|update|put|upload|download|sync|rm)-',
    '^aws\s+s3\s+(rm|cp|mv|sync)',                    # aws s3 rm|cp|mv|sync
    '^aws\s+s3api\s+(put|delete)-'                  # aws s3api put-|delete-
)

# Linux/Unix Read-Only Commands
$LinuxReadOnlyCommands = @(
    'ls', 'pwd', 'cd', 'echo', 'cat', 'head', 'tail', 'grep', 'find', 'which',
    'whoami', 'id', 'groups', 'file', 'ps', 'df', 'du', 'free', 'uname',
    'hostname', 'date', 'uptime', 'who', 'wc', 'sort', 'uniq', 'less', 'more'
)

# Linux/Unix Modifying Commands
$LinuxModifyingCommands = @(
    'rm', 'rmdir', 'mv', 'cp', 'scp', 'rsync', 'touch', 'mkdir',
    'chmod', 'chown', 'chgrp', 'setfacl', 'useradd', 'userdel',
    'usermod', 'passwd', 'groupadd', 'groupdel', 'mount', 'umount',
    'fsck', 'mkfs', 'dd', 'shutdown', 'reboot', 'halt', 'poweroff',
    'yum', 'apt-get', 'dnf', 'pip', 'npm', 'composer', 'gem',
    'mysql', 'psql', 'redis-cli', 'mongosh', 'mongo'
)

# PowerShell Read-Only Verbs (Get-, Test-, Select-, etc.)
$PowerShellReadOnlyVerbs = @('Get-', 'Test-', 'Select-', 'Where-', 'Measure-', 'Find-', 'Write-')

# PowerShell Modifying Verbs (Remove-, New-, Set-, etc.)
$PowerShellModifyingVerbs = @('Remove-', 'Move-', 'Copy-', 'New-', 'Set-', 'Clear-', 'Rename-', 'Stop-', 'Start-', 'Restart-', 'Invoke-')

# ==================================================
# Helper Functions
# ==================================================

function Test-IsScriptExecution {
    param([string]$Command)

    foreach ($pattern in $ScriptPatterns) {
        if ($Command -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-IsSSHCommand {
    param([string]$Command)
    return $Command -match $SSHPattern
}

function Test-IsAWSReadOnly {
    param([string]$Command)

    foreach ($pattern in $AWSReadOnlyPatterns) {
        if ($Command -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-IsAWSModifying {
    param([string]$Command)

    foreach ($pattern in $AWSModifyingPatterns) {
        if ($Command -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-IsLinuxReadOnly {
    param([string]$Command)

    $cmdName = ($Command -split '\s+')[0]
    return $LinuxReadOnlyCommands -contains $cmdName
}

function Test-IsLinuxModifying {
    param([string]$Command)

    $cmdName = ($Command -split '\s+')[0]
    return $LinuxModifyingCommands -contains $cmdName
}

function Test-IsPowerShellReadOnly {
    param([string]$Command)

    foreach ($verb in $PowerShellReadOnlyVerbs) {
        if ($Command -match "^$verb") {
            return $true
        }
    }
    return $false
}

function Test-IsPowerShellModifying {
    param([string]$Command)

    foreach ($verb in $PowerShellModifyingVerbs) {
        if ($Command -match "^$verb") {
            return $true
        }
    }
    return $false
}

function Extract-SSHRemoteCommand {
    param([string]$Command)

    # Extract text within quotes (the remote command)
    # Example: ssh user@host "cat file && grep pattern" -> "cat file && grep pattern"
    if ($Command -match '"(.+)"') {
        return $matches[1]
    }

    # Handle single quotes as well
    if ($Command -match "'(.+)'") {
        return $matches[1]
    }

    return $null
}

function Split-ChainedCommands {
    param([string]$Command)

    # Split by common operators, preserving quoted strings
    $operators = @(' && ', ' || ', ' | ', '; ', ' & ', ' ;')

    # Replace operators with a special marker
    $markedCmd = $Command
    $marker = "@@@"

    foreach ($op in $operators) {
        $markedCmd = $markedCmd -replace [regex]::Escape($op), $marker
    }

    # Split by marker
    $segments = $markedCmd -split $marker

    # Clean up segments
    $cleanSegments = foreach ($segment in $segments) {
        $clean = $segment.Trim()
        if ($clean) { $clean }
    }

    return $cleanSegments
}

function Get-CLICommandType {
    param([string]$Command)

    $cmd = $Command.Trim()

    # Check for script execution first
    if (Test-IsScriptExecution $cmd) {
        return "Script"
    }

    # Check for SSH
    if (Test-IsSSHCommand $cmd) {
        return "SSH"
    }

    # Check for AWS
    if ($cmd -match '^aws\s+') {
        return "AWS"
    }

    # Check for PowerShell (starts with capitalized verb or common cmdlets)
    if ($cmd -match '^[A-Z][a-z]+-' -or $cmd -match '^(Get-|Test-|Select-|Where-|Measure-|Find-|Write-|Remove-|Move-|Copy-|New-|Set-|Clear-|Rename-|Stop-|Start-|Restart-|Invoke-)') {
        return "PowerShell"
    }

    # Default to Linux/Unix
    return "Linux"
}

function Test-IsReadOnly {
    param([string]$Command)

    $cliType = Get-CLICommandType $Command

    switch ($cliType) {
        "Script" { return $false }  # Scripts never read-only

        "SSH" {
            $remoteCmd = Extract-SSHRemoteCommand $Command
            if (-not $remoteCmd) {
                return $false
            }

            # Check all remote sub-commands
            $subCommands = Split-ChainedCommands $remoteCmd
            foreach ($subCmd in $subCommands) {
                if (-not (Test-IsReadOnly $subCmd)) {
                    return $false  # One modifying means entire SSH command modifies
                }
            }
            return $true
        }

        "AWS" { return Test-IsAWSReadOnly $Command }
        "PowerShell" { return Test-IsPowerShellReadOnly $Command }
        "Linux" { return Test-IsLinuxReadOnly $Command }
        default { return $false }
    }
}

function Test-IsModifying {
    param([string]$Command)

    $cliType = Get-CLICommandType $Command

    switch ($cliType) {
        "Script" { return $true }  # Scripts always modifying

        "SSH" {
            $remoteCmd = Extract-SSHRemoteCommand $Command
            if (-not $remoteCmd) {
                return $true
            }

            # Check all remote sub-commands
            $subCommands = Split-ChainedCommands $remoteCmd
            foreach ($subCmd in $subCommands) {
                if (Test-IsModifying $subCmd) {
                    return $true  # One modifying means entire SSH command modifies
                }
            }
            return $false
        }

        "AWS" { return Test-IsAWSModifying $Command }
        "PowerShell" { return Test-IsPowerShellModifying $Command }
        "Linux" { return Test-IsLinuxModifying $Command }
        default { return $true }  # Better safe than sorry
    }
}

function New-DecisionResult {
    param(
        [string]$action,
        [string]$reason
    )

    $result = @{
        action = $action
        reason = $reason
    }

    return $result | ConvertTo-Json -Compress
}

# ==================================================
# Main Analysis Logic
# ==================================================

function Analyze-Command {
    param([string]$Command)

    if (-not $Command -or $Command.Trim().Length -eq 0) {
        return New-DecisionResult "approve" "Empty command"
    }

    # Check: Script Execution (Highest priority - always prompt)
    if (Test-IsScriptExecution $Command) {
        return New-DecisionResult "prompt" "EXECUTES_SCRIPT: Executes external script (unknown code cannot be verified)"
    }

    # Check: SSH Commands with remote operations
    if (Test-IsSSHCommand $Command) {
        $remoteCmd = Extract-SSHRemoteCommand $Command
        if (-not $remoteCmd) {
            return New-DecisionResult "prompt" "SSH_INCOMPLETE: SSH command without remote command"
        }

        # Check all remote sub-commands
        $subCommands = Split-ChainedCommands $remoteCmd
        $modifyingCmds = @()

        foreach ($subCmd in $subCommands) {
            if (Test-IsModifying $subCmd) {
                $modifyingCmds += $subCmd
            }
        }

        if ($modifyingCmds.Count -gt 0) {
            $modList = ($modifyingCmds -join '|')
            return New-DecisionResult "prompt" "SSH_MODIFIES: Remote command contains modifying operation(s): $modList"
        }

        return New-DecisionResult "approve" "SSH_READ_ONLY: All remote commands are read-only"
    }

    # Check: Command Chains (&&, ||, |, ;)
    $subCommands = Split-ChainedCommands $Command

    if ($subCommands.Count -gt 1) {
        $modifyingCmds = @()
        $sshCommands = @()

        foreach ($subCmd in $subCommands) {
            if (Test-IsSSHCommand $subCmd) {
                $sshCommands += $subCmd
            }
            elseif (Test-IsModifying $subCmd) {
                $modifyingCmds += $subCmd
            }
        }

        if ($sshCommands.Count -gt 0) {
            # Re-analyze SSH commands individually
            foreach ($sshCmd in $sshCommands) {
                $sshResult = Analyze-Command $sshCmd
                if (($sshResult | ConvertFrom-Json).action -eq "prompt") {
                    return $sshResult
                }
            }
        }

        if ($modifyingCmds.Count -gt 0) {
            $modList = ($modifyingCmds -join '|')
            return New-DecisionResult "prompt" "CHAIN_MODIFIES: Command chain contains modifying operation(s): $modList"
        }

        return New-DecisionResult "approve" "CHAIN_READ_ONLY: All commands in chain are read-only"
    }

    # Single command analysis
    if (Test-IsReadOnly $Command) {
        return New-DecisionResult "approve" "READ_ONLY: Read-only command"
    }

    if (Test-IsModifying $Command) {
        return New-DecisionResult "prompt" "MODIFIES: Modifying command"
    }

    # Unknown command - safe default
    return New-DecisionResult "prompt" "UNKNOWN: Unknown command type (safe default)"
}

# ==================================================
# Main Execution
# ==================================================

if ($FullCommand) {
    # Called directly from command line
    $resultJson = Analyze-Command $FullCommand
    $result = $resultJson | ConvertFrom-Json

    Write-Host @"

==============================================
CLI Security Analysis
==============================================
Command: $FullCommand
Decision: $($result.action.ToUpper())
Reason: $($result.reason)
==============================================
"@

    # Return JSON output
    Write-Output $resultJson

    # Exit code
    if ($result.action -eq "approve") {
        exit 0
    } else {
        exit 1
    }
} else {
    # No command provided, show help
    Write-Host @"

Pre-CLI Hook for Claude Code
============================

Usage: pwsh pre-cli-hook.ps1 <command>

Examples:
  pwsh pre-cli-hook.ps1 "Get-ChildItem"
  pwsh pre-cli-hook.ps1 "Remove-Item file.txt"
  pwsh pre-cli-hook.ps1 "ls -la"
  pwsh pre-cli-hook.ps1 "sh user@host 'cat /var/log/app.log'"
  pwsh pre-cli-hook.ps1 "./script.sh"
  pwsh pre-cli-hook.ps1 "aws ec2 describe-instances"

Returns:
  Exit code 0 = APPROVE (read-only)
  Exit code 1 = PROMPT (modifying or unknown)

With JSON output showing decision and reason.
"@
}

