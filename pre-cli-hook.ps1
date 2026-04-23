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
- Load all patterns from cli-commands.json for easy customization

.NOTES
Returns exit code 0 for approval, 1 for denial (prompt required)
Config file: cli-commands.json (must be in same directory as this script)
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string]$FullCommand
)

# ==================================================
# Load Configuration from cli-commands.json
# ==================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "cli-commands.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Script Execution Patterns - Always prompt (execute unknown code)
$ScriptPatterns = @($Config.script_patterns)

# SSH Command Pattern
$SSHPattern = $Config.ssh_pattern

# AWS Read-Only Patterns
$AWSReadOnlyPatterns = @($Config.aws_read_only_patterns)

# AWS Modifying Patterns
$AWSModifyingPatterns = @($Config.aws_modifying_patterns)

# Linux/Unix Read-Only Commands
$LinuxReadOnlyCommands = @($Config.linux_read_only_commands)

# Linux/Unix Modifying Commands
$LinuxModifyingCommands = @($Config.linux_modifying_commands)

# PowerShell Read-Only Verbs
$PowerShellReadOnlyVerbs = @($Config.powershell_read_only_verbs)

# PowerShell Modifying Verbs
$PowerShellModifyingVerbs = @($Config.powershell_modifying_verbs)

# Docker Read-Only Commands
$DockerReadOnlyCommands = @($Config.docker_read_only_commands)

# Docker Modifying Commands
$DockerModifyingCommands = @($Config.docker_modifying_commands)

# Terraform Read-Only Commands
$TerraformReadOnlyCommands = @($Config.terraform_read_only_commands)

# Terraform Modifying Commands
$TerraformModifyingCommands = @($Config.terraform_modifying_commands)

# ==================================================
# Logging Function
# ==================================================

function Log-Decision {
    param(
        [string]$Command,
        [string]$Action,
        [string]$Reason
    )

    $logFile = "C:\temp\command-hook.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp | Command: $Command | Action: $Action | Reason: $Reason"

    try {
        if (-not (Test-Path "C:\temp")) {
            New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null
        }
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Logging failure should not block the hook
    }
}

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

    $cmdToCheck = $Command
    # Strip leading sudo to check the actual command
    if ($cmdToCheck -match '^sudo\s+') {
        $cmdToCheck = $cmdToCheck -replace '^sudo\s+', ''
    }

    $cmdName = ($cmdToCheck -split '\s+')[0]
    return $LinuxReadOnlyCommands -contains $cmdName
}

function Test-IsLinuxModifying {
    param([string]$Command)

    $cmdToCheck = $Command
    # Strip leading sudo to check the actual command
    if ($cmdToCheck -match '^sudo\s+') {
        $cmdToCheck = $cmdToCheck -replace '^sudo\s+', ''
    }

    $cmdName = ($cmdToCheck -split '\s+')[0]
    return $LinuxModifyingCommands -contains $cmdName
}

function Test-IsDockerReadOnly {
    param([string]$Command)

    if ($Command -match '^docker\s+(\S+)') {
        $subCmd = $Matches[1]
        return $DockerReadOnlyCommands -contains $subCmd
    }
    if ($Command -match '^docker-compose\s+(\S+)') {
        $subCmd = $Matches[1]
        return $DockerReadOnlyCommands -contains $subCmd
    }
    return $false
}

function Test-IsDockerModifying {
    param([string]$Command)

    if ($Command -match '^docker\s+(\S+)') {
        $subCmd = $Matches[1]
        return $DockerModifyingCommands -contains $subCmd
    }
    if ($Command -match '^docker-compose\s+(\S+)') {
        $subCmd = $Matches[1]
        return $DockerModifyingCommands -contains $subCmd
    }
    return $false
}

function Test-IsTerraformReadOnly {
    param([string]$Command)

    if ($Command -match '^terraform\s+(\S+)') {
        $subCmd = $Matches[1]
        return $TerraformReadOnlyCommands -contains $subCmd
    }
    return $false
}

function Test-IsTerraformModifying {
    param([string]$Command)

    if ($Command -match '^terraform\s+(\S+)') {
        $subCmd = $Matches[1]
        return $TerraformModifyingCommands -contains $subCmd
    }
    return $false
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
    # Example: ssh user@host "cat file && grep pattern" -> cat file && grep pattern
    if ($Command -match '"(.+)"') {
        return $Matches[1]
    }

    # Handle single quotes as well
    if ($Command -match "'(.+)'") {
        return $Matches[1]
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

    # Check for Docker
    if ($cmd -match '^docker(\s|-compose\s)') {
        return "Docker"
    }

    # Check for Terraform
    if ($cmd -match '^terraform\s+') {
        return "Terraform"
    }

    # Check for PowerShell (starts with Verb-Noun pattern)
    if ($cmd -match '^[A-Z][a-z]+-') {
        return "PowerShell"
    }

    # Default to Linux/Unix
    return "Linux"
}

function Test-IsReadOnly {
    param([string]$Command)

    $cliType = Get-CLICommandType $Command

    switch ($cliType) {
        "Script" { return $false } # Scripts never read-only

        "SSH" {
            $remoteCmd = Extract-SSHRemoteCommand $Command
            if (-not $remoteCmd) {
                return $false
            }

            # Check all remote sub-commands
            $subCommands = Split-ChainedCommands $remoteCmd
            foreach ($subCmd in $subCommands) {
                if (-not (Test-IsReadOnly $subCmd)) {
                    return $false
                }
            }
            return $true
        }

        "AWS" { return Test-IsAWSReadOnly $Command }
        "Docker" { return Test-IsDockerReadOnly $Command }
        "Terraform" { return Test-IsTerraformReadOnly $Command }
        "PowerShell" { return Test-IsPowerShellReadOnly $Command }
        "Linux" { return Test-IsLinuxReadOnly $Command }
        default { return $false }
    }
}

function Test-IsModifying {
    param([string]$Command)

    $cliType = Get-CLICommandType $Command

    switch ($cliType) {
        "Script" { return $true } # Scripts always modifying

        "SSH" {
            $remoteCmd = Extract-SSHRemoteCommand $Command
            if (-not $remoteCmd) {
                return $true
            }

            # Check all remote sub-commands
            $subCommands = Split-ChainedCommands $remoteCmd
            foreach ($subCmd in $subCommands) {
                if (Test-IsModifying $subCmd) {
                    return $true
                }
            }
            return $false
        }

        "AWS" { return Test-IsAWSModifying $Command }
        "Docker" { return Test-IsDockerModifying $Command }
        "Terraform" { return Test-IsTerraformModifying $Command }
        "PowerShell" { return Test-IsPowerShellModifying $Command }
        "Linux" { return Test-IsLinuxModifying $Command }
        default { return $true } # Better safe than sorry
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

    # Check: Output redirection (always modifying - creates/overwrites files)
    if ($Command -match '\s*>>?\s*\S' -and $Command -notmatch '^\s*$') {
        return New-DecisionResult "prompt" "REDIRECT: Command contains output redirection (modifying)"
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

    Write-Host ""

    Write-Host "=============================================="
    Write-Host "CLI Security Analysis"
    Write-Host "=============================================="
    Write-Host "Command: $FullCommand"
    Write-Host "Decision: $($result.action.ToUpper())"
    Write-Host "Reason: $($result.reason)"
    Write-Host "=============================================="
    Write-Host ""

    # Log the decision
    Log-Decision -Command $FullCommand -Action $result.action -Reason $result.reason

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
    Write-Host ""
    Write-Host "Pre-CLI Hook for Claude Code"
    Write-Host "============================"
    Write-Host ""
    Write-Host "Usage: pwsh pre-cli-hook.ps1 <command>"
    Write-Host ""
    Write-Host "Config: cli-commands.json (same directory as this script)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host '  pwsh pre-cli-hook.ps1 "Get-ChildItem"'
    Write-Host '  pwsh pre-cli-hook.ps1 "Remove-Item file.txt"'
    Write-Host '  pwsh pre-cli-hook.ps1 "ls -la"'
    Write-Host "  pwsh pre-cli-hook.ps1 `"ssh user@host 'cat /var/log/app.log'`""
    Write-Host '  pwsh pre-cli-hook.ps1 "./script.sh"'
    Write-Host '  pwsh pre-cli-hook.ps1 "aws ec2 describe-instances"'
    Write-Host '  pwsh pre-cli-hook.ps1 "docker ps"'
    Write-Host '  pwsh pre-cli-hook.ps1 "terraform plan"'
    Write-Host ""
    Write-Host "Returns:"
    Write-Host "  Exit code 0 = APPROVE (read-only)"
    Write-Host "  Exit code 1 = PROMPT (modifying or unknown)"
    Write-Host ""
    Write-Host "With JSON output showing decision and reason."
    Write-Host "All decisions logged to C:\temp\command-hook.log"
    Write-Host ""
}
