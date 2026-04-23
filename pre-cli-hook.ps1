<#
.SYNOPSIS
Claude Code CLI Security Hook - PowerShell Version
Analyzes PowerShell commands and approves read-only operations while denying modifying ones

.DESCRIPTION
This hook script integrates with Claude Code's PreToolUse hooks to:
- Auto-approve read-only PowerShell commands
- Prompt for approval on modifying operations
- Parse command chains and analyze each sub-command

.NOTES
Returns exit code 0 for approval, 1 for denial (prompt required)
#>

param()

# Configuration
$ConfigFile = "$env:USERPROFILE\.claude\cli-commands.json"
$LogFile = "$env:USERPROFILE\.claude\hook-approvals.log"

# Initialize arrays for different command categories
$script:ReadOnlyCommands = @()
$script:ModifyingPatterns = @()

function Write-DebugLog {
    param([string]$Message)
    if ($env:HOOK_DEBUG -eq "true") {
        Write-Host "[DEBUG] $Message" -ForegroundColor Gray
    }
}

function Write-ApprovalLog {
    param(
        [string]$Status,
        [string]$Reason
    )
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    if (Test-Path $LogFile) {
        Add-Content -Path $LogFile -Value "[$timestamp] [$Status] $Command - $Reason"
    }
}

function Load-Configuration {
    if (Test-Path $ConfigFile) {
        try {
            $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $script:ReadOnlyCommands = $config.read_only_commands.powershell
            $script:ModifyingPatterns = $config.modifying_patterns.powershell
            Write-DebugLog "Loaded configuration with $($script:ReadOnlyCommands.Count) read-only commands and $($script:ModifyingPatterns.Count) modifying patterns"
            return $true
        } catch {
            Write-DebugLog "Error loading configuration: $_"
            return $false
        }
    } else {
        Write-DebugLog "Configuration file not found: $ConfigFile"
        return $false
    }
}

function Test-ReadOnlyCommand {
    param([string]$Cmd)

    $cmdLower = $Cmd.ToLower().Trim()

    # Simple pattern matching for common read-only commands
    $readOnlyPatterns = @(
        "^get-", "^test-", "^select-", "^where-", "^sort-", "^measure-",
        "^group-", "^format-", "^compare-", "^write-",
        # Aliases
        "^ls$", "^dir$", "^pwd$", "^echo$", "^cat$", "^type$", "^gc$",
        "^where$", "^select$", "^sort$", "^measure$", "^group$", "^format$"
    )

    foreach ($pattern in $readOnlyPatterns) {
        if ($cmdLower -match $pattern) {
            Write-DebugLog "Command '$Cmd' matches read-only pattern: $pattern"
            return $true
        }
    }

    # Check against configured read-only commands
    if ($script:ReadOnlyCommands -and $script:ReadOnlyCommands.Count -gt 0) {
        foreach ($roCmd in $script:ReadOnlyCommands) {
            $cmdBase = $Cmd -split '\s+' | Select-Object -First 1
            if ($cmdBase -eq $roCmd -or $Cmd.StartsWith($roCmd + " ")) {
                Write-DebugLog "Command '$Cmd' matches configured read-only: $roCmd"
                return $true
            }
        }
    }

    return $false
}

function Test-ModifyingCommand {
    param([string]$Cmd)

    $cmdLower = $Cmd.ToLower().Trim()

    # Simple pattern matching for modifying commands
    $modifyingPatterns = @(
        "^new-", "^set-", "^remove-", "^stop-", "^start-", "^restart-",
        "^add-", "^clear-", "^rename-", "^move-", "^copy-"
    )

    foreach ($pattern in $modifyingPatterns) {
        if ($cmdLower -match $pattern) {
            Write-DebugLog "Command '$Cmd' matches modifying pattern: $pattern"
            return $true
        }
    }

    # Check against configured modifying patterns
    if ($script:ModifyingPatterns -and $script:ModifyingPatterns.Count -gt 0) {
        foreach ($modPattern in $script:ModifyingPatterns) {
            if ($Cmd -like "$modPattern*") {
                Write-DebugLog "Command '$Cmd' matches configured modifying pattern: $modPattern"
                return $true
            }
        }
    }

    return $false
}

function Split-CommandChain {
    param([string]$FullCommand)

    # Split on PowerShell operators: ;, |, &&, ||
    # Note: && and || are not native PowerShell but may appear in Claude Code
    $operators = @(";", "|", "&&", "||")
    $segments = @($FullCommand)

    foreach ($op in $operators) {
        $newSegments = @()
        foreach ($segment in $segments) {
            $split = $segment -split [regex]::Escape($op)
            $newSegments += $split
        }
        $segments = $newSegments
    }

    # Clean up segments
    $cleanSegments = foreach ($segment in $segments) {
        $clean = $segment.Trim()
        if ($clean) {
            $clean
        }
    }

    return $cleanSegments
}

# Main function
function Test-CommandApproval {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-DebugLog "No command provided, approving by default"
        return $true
    }

    # Load configuration if available
    Load-Configuration | Out-Null

    # Split command chain
    $commands = Split-CommandChain -FullCommand $Command
    Write-DebugLog "Split command chain into $($commands.Count) commands: $($commands -join ', ')"

    # Analyze each command
    $modifyingCommands = @()
    $readOnlyCommands = @()
    $ambiguousCommands = @()

    foreach ($cmd in $commands) {
        if (Test-ReadOnlyCommand -Cmd $cmd) {
            $readOnlyCommands += $cmd
        } elseif (Test-ModifyingCommand -Cmd $cmd) {
            $modifyingCommands += $cmd
        } else {
            $ambiguousCommands += $cmd
        }
    }

    Write-DebugLog "Read-only: $($readOnlyCommands.Count) - $readOnlyCommands"
    Write-DebugLog "Modifying: $($modifyingCommands.Count) - $modifyingCommands"
    Write-DebugLog "Ambiguous: $($ambiguousCommands.Count) - $ambiguousCommands"

    # Decision logic
    if ($modifyingCommands.Count -eq 0 -and $ambiguousCommands.Count -eq 0) {
        # All commands are read-only
        Write-ApprovalLog -Status "AUTO-APPROVE" -Reason "All commands are read-only"
        Write-DebugLog "Auto-approving all read-only commands"
        return $true
    } elseif ($modifyingCommands.Count -gt 0) {
        # Found modifying commands
        Write-ApprovalLog -Status "DENY" -Reason "Modifying commands detected: $($modifyingCommands -join ', ')"
        Write-DebugLog "Denying due to modifying commands"
        return $false
    } else {
        # Only ambiguous commands - defer to prompt hook
        Write-ApprovalLog -Status "AMBIGUOUS" -Reason "Ambiguous commands: $($ambiguousCommands -join ', ')"
        Write-DebugLog "Deferring to prompt hook for ambiguous commands"
        return $false
    }
}

# Read input from stdin (Claude Code passes JSON)
$inputJson = $null
if ($PSCmdlet.MyInvocation.PipelineLength -gt 1) {
    $inputJson = $input
} else {
    $inputJson = [Console]::In.ReadToEnd()
}

if ([string]::IsNullOrWhiteSpace($inputJson)) {
    Write-DebugLog "No input received"
    exit 0
}

try {
    # Parse JSON input
    $inputObj = $inputJson | ConvertFrom-Json
    $script:Command = $inputObj.tool_input.command
    $chained = $inputObj.tool_input.chained

    Write-DebugLog "Hook received command: $script:Command"
    Write-DebugLog "Chained: $chained"

    # Test command approval
    $approved = Test-CommandApproval -Command $script:Command

    if ($approved) {
        exit 0  # Approve
    } else {
        exit 1  # Deny (needs prompt)
    }
}
catch {
    Write-DebugLog "Error in hook: $_"
    Write-Error "Hook failed: $_"
    exit 1  # Deny on error
}