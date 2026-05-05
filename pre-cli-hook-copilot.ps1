<#
.SYNOPSIS
VS Code Copilot PreToolUse Hook - PowerShell Version
Analyzes CLI commands and auto-approves read-only operations, prompts for modifying ones.

.DESCRIPTION
This hook integrates with VS Code Copilot's PreToolUse hook system to:
- Auto-approve read-only commands (PowerShell, AWS, Docker, Terraform, Linux/Unix, SSH)
- Prompt for approval on modifying operations
- Parse command chains (&&, ||, |, ;) and analyze each sub-command
- Handle SSH commands specially (extract remote command and analyze it)
- Detect script executions and always prompt for approval
- Load all patterns from cli-commands.json for easy customization

VS Code Copilot Hook API:
Input:  JSON via stdin { hook_event_name, tool_name, tool_input: { command, ... }, ... }
Output: JSON to stdout { hookSpecificOutput: { hookEventName, permissionDecision, permissionDecisionReason } }
permissionDecision: "allow" = auto-execute (no prompt), "ask" = show Allow/Skip prompt

.NOTES
Config file: cli-commands.json (must be in same directory as this script)
Hook config: C:\Users\<you>\.copilot\hooks\pre-cli-hook.json
Log file:    C:\Users\<you>\.copilot\logs\copilot-hook-yyyy-MM-dd.log
#>

# ================================================
# Parameter for debug/testing via VS Code debugger
# ================================================
param(
    [string]$DebugInput,
    [string]$DebugInputFile
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# ================================================
# Load Configuration from cli-commands.json
# ================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "cli-commands.json"

if (-not (Test-Path $ConfigFile)) {
    # Try same dir as hooks file if running from hooks folder
    $ConfigFile = "C:\git\pre-tool-use-hook\cli-commands.json"
}

if (-not (Test-Path $ConfigFile)) {
    # Fallback: write allow and exit so we don't block Copilot
    @{ hookSpecificOutput = @{ hookEventName = "PreToolUse"; permissionDecision = "allow"; permissionDecisionReason = "Config file not found; defaulting to allow" } } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$ScriptPatterns        = @($config.script_patterns)
$SSHPattern            = $config.ssh_pattern
$AWSReadOnlyPatterns   = @($config.aws_read_only_patterns)
$AWSModifyingPatterns  = @($config.aws_modifying_patterns)
$LinuxReadOnlyCommands = @($config.linux_read_only_commands)
$LinuxModifyingCommands = @($config.linux_modifying_commands)
$PSReadOnlyVerbs       = @($config.powershell_read_only_verbs)
$PSModifyingVerbs      = @($config.powershell_modifying_verbs)
$DockerReadOnlyCmds    = @($config.docker_read_only_commands)
$DockerModifyingCmds   = @($config.docker_modifying_commands)
$TerraformReadOnlyCmds = @($config.terraform_read_only_commands)
$TerraformModifyingCmds = @($config.terraform_modifying_commands)
$GIT_ReadOnlyCommands = @($config.git_read_only_commands)
$GIT_ModifyingCommands = @($config.git_modifying_commands)
$KubectlReadOnlyCmds    = @($config.kubectl_read_only_commands)
$KubectlModifyingCmds   = @($config.kubectl_modifying_commands)
$CondaReadOnlyCmds      = @($config.conda_read_only_commands)
$CondaModifyingCmds     = @($config.conda_modifying_commands)
$DOSReadOnlyCommands    = @($config.dos_read_only_commands)
$DOSModifyingCommands   = @($config.dos_modifying_commands)
$TrustedScriptFiles     = if ($config.trusted_script_files) { @($config.trusted_script_files) } else { @() }

# ================================================
# Logging
# ================================================

$logDir = "C:\Users\$env:USERNAME\.copilot\logs"
$logFile = $null

function Initialize-Log {
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $script:logFile = Join-Path $logDir ("copilot-hook-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")
    } catch { }
}

function Write-Log {
    param([string]$Level, [string]$Message)
    if ($script:logFile) {
        try {
            Add-Content -Path $script:logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ErrorAction SilentlyContinue
        } catch { }
    }
}

# ================================================
# Output Helpers - Format VS Code Hook Responses
# ================================================

function Write-Allow {
    <#
    .SYNOPSIS
    Output JSON response to auto-approve command execution.
    .DESCRIPTION
    Formats and returns a JSON object indicating the command should be auto-executed
    without prompting the user. Used for verified read-only operations.
    .PARAMETER reason
    Brief explanation why the command was auto-approved (appears in logs).
    .EXAMPLE
    Write-Allow "AWS read-only operation"
    #>
    param([string]$reason)
    @{
        hookSpecificOutput = @{
            hookEventName        = "PreToolUse"
            permissionDecision   = "allow"
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

function Write-Ask {
    <#
    .SYNOPSIS
    Output JSON response to prompt user for command approval.
    .DESCRIPTION
    Formats and returns a JSON object requesting user confirmation before executing
    the command. Used for potentially modifying operations that require human review.
    .PARAMETER reason
    Explanation why user approval is needed (shown in Allow/Skip prompt).
    .EXAMPLE
    Write-Ask "Command modifies AWS IAM policy"
    #>
    param([string]$reason)
    @{
        hookSpecificOutput = @{
            hookEventName        = "PreToolUse"
            permissionDecision   = "ask"
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

# ================================================
# Command Analysis Functions (shared logic)
# ================================================

function Test-IsScriptExecution {
    <#
    .SYNOPSIS
    Detect if command executes an external script or executable.
    .DESCRIPTION
    Scripts are unknown code requiring manual approval. Tests patterns like:
    ./script.sh, bash deploy.sh, python migrate.py, node server.js, etc.
    Trusted scripts (in trusted_script_files config) override this check.
    Always returns modifying behavior for safety.
    .PARAMETER Command
    The command string to analyze.
    .OUTPUTS
    [bool] $true if command executes a script; $false otherwise.
    #>
    param([string]$Command)
    # Check trusted scripts first — if filename is trusted, this is NOT a script execution
    if (Test-IsTrustedScript $Command) { return $false }
    foreach ($pattern in $ScriptPatterns) {
        if ($Command -match $pattern) { return $true }
    }
    return $false
}

function Test-IsTrustedScript {
    <#
    .SYNOPSIS
    Check if a command references a trusted script file (auto-approve).
    .DESCRIPTION
    Reads the trusted_script_files list from cli-commands.json. If the command
    string contains any trusted filename (case-insensitive substring match),
    the script is considered trusted and will be auto-approved.
    
    This allows testing/debugging scripts to run without prompting, without
    modifying the core script_patterns detection logic.
    
    To disable: remove the trusted_script_files entry from cli-commands.json.
    .PARAMETER Command
    The command string to check.
    .OUTPUTS
    [bool] $true if command references a trusted script; $false otherwise.
    #>
    param([string]$Command)
    if (-not $TrustedScriptFiles -or $TrustedScriptFiles.Count -eq 0) { return $false }
    foreach ($trusted in $TrustedScriptFiles) {
        if ($Command -match [regex]::Escape($trusted)) { return $true }
    }
    return $false
}

function Test-IsSSHCommand {
    <#
    .SYNOPSIS
    Detect if command is an SSH remote execution.
    .DESCRIPTION
    SSH commands require special handling: extract the remote command string
    and analyze it independently. Remote modifying operations need approval.
    .PARAMETER Command
    The command string to analyze.
    .OUTPUTS
    [bool] $true if command starts with 'ssh'; $false otherwise.
    #>
    param([string]$Command)
    return $Command -match $SSHPattern
}

function Test-IsAWSReadOnly {
    <#
    .SYNOPSIS
    Detect AWS read-only operations (query, describe, list, get, head).
    .DESCRIPTION
    Tests AWS patterns against read-only verb list: describe-*, list-*, get-*, show-*, head-*,
    aws s3 ls, sts decode-authorization-message, etc.
    .PARAMETER Command
    The AWS command string to analyze.
    .OUTPUTS
    [bool] $true if command is safe read-only AWS operation; $false otherwise.
    #>
    param([string]$Command)
    foreach ($pattern in $AWSReadOnlyPatterns) {
        if ($Command -match $pattern) { return $true }
    }
    return $false
}

function Test-IsAWSModifying {
    <#
    .SYNOPSIS
    Detect AWS modifying operations (create, delete, modify, update, etc).
    .DESCRIPTION
    Tests AWS patterns against modifying verb list: create-*, delete-*, modify-*,
    aws s3 rm, aws lambda invoke, aws sns publish, etc.
    These operations require user confirmation due to potential impact.
    .PARAMETER Command
    The AWS command string to analyze.
    .OUTPUTS
    [bool] $true if command modifies AWS resources; $false otherwise.
    #>
    param([string]$Command)
    foreach ($pattern in $AWSModifyingPatterns) {
        if ($Command -match $pattern) { return $true }
    }
    return $false
}

function Test-IsLinuxReadOnly {
    <#
    .SYNOPSIS
    Detect Linux/Unix read-only commands (ls, cat, grep, find, ps, etc).
    .DESCRIPTION
    Analyzes Linux commands by extracting base command name (strips sudo prefix)
    and checking against whitelist of safe read-only commands.
    Handles sudo elevation transparently.
    .PARAMETER Command
    The Linux command string to analyze.
    .OUTPUTS
    [bool] $true if base command is in read-only whitelist; $false otherwise.
    #>
    param([string]$Command)
    $cmdToCheck = $Command -replace '^sudo\s+', ''
    $cmdName = ($cmdToCheck -split '\s+')[0]
    return $LinuxReadOnlyCommands -contains $cmdName
}

function Test-IsLinuxModifying {
    <#
    .SYNOPSIS
    Detect Linux/Unix modifying commands (rm, cp, mv, chmod, useradd, etc).
    .DESCRIPTION
    Analyzes Linux commands by extracting base command name (strips sudo prefix)
    and checking against list of potentially modifying/dangerous commands.
    Treats unknown Linux commands as read-only (conservative list).
    .PARAMETER Command
    The Linux command string to analyze.
    .OUTPUTS
    [bool] $true if base command is in modifying list; $false otherwise.
    #>
    param([string]$Command)
    $cmdToCheck = $Command -replace '^sudo\s+', ''
    $cmdName = ($cmdToCheck -split '\s+')[0]
    return $LinuxModifyingCommands -contains $cmdName
}

function Test-IsDockerReadOnly {
    <#
    .SYNOPSIS
    Detect Docker read-only operations (ps, images, inspect, logs, etc).
    .DESCRIPTION
    Extracts Docker/docker-compose subcommand and checks if it's read-only.
    Supports both 'docker' and 'docker-compose' command prefixes.
    .PARAMETER Command
    The Docker command string to analyze.
    .OUTPUTS
    [bool] $true if Docker subcommand is safe and read-only; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^docker(?:-compose)?\s+(\S+)') {
        return $DockerReadOnlyCmds -contains $Matches[1]
    }
    return $false
}

function Test-IsDockerModifying {
    <#
    .SYNOPSIS
    Detect Docker modifying operations (run, rm, stop, build, push, etc).
    .DESCRIPTION
    Extracts Docker/docker-compose subcommand and checks if it modifies state.
    Supports both 'docker' and 'docker-compose' command prefixes.
    Modifying operations require user confirmation.
    .PARAMETER Command
    The Docker command string to analyze.
    .OUTPUTS
    [bool] $true if Docker subcommand modifies containers/images; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^docker(?:-compose)?\s+(\S+)') {
        return $DockerModifyingCmds -contains $Matches[1]
    }
    return $false
}

function Test-IsTerraformReadOnly {
    <#
    .SYNOPSIS
    Detect Terraform read-only operations (plan, show, validate, fmt, etc).
    .DESCRIPTION
    Extracts Terraform subcommand (plan, show, output, state list, etc)
    and checks if it only reads state without modification.
    .PARAMETER Command
    The Terraform command string to analyze.
    .OUTPUTS
    [bool] $true if Terraform command is read-only; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^terraform\s+(\S+)') {
        return $TerraformReadOnlyCmds -contains $Matches[1]
    }
    return $false
}

function Test-IsTerraformModifying {
    <#
    .SYNOPSIS
    Detect Terraform modifying operations (apply, destroy, taint, import, etc).
    .DESCRIPTION
    Extracts Terraform subcommand and checks if it modifies infrastructure.
    These operations require explicit user approval due to infrastructure impact.
    .PARAMETER Command
    The Terraform command string to analyze.
    .OUTPUTS
    [bool] $true if Terraform command modifies infrastructure; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^terraform\s+(\S+)') {
        return $TerraformModifyingCmds -contains $Matches[1]
    }
    return $false
}

function Test-IsGitReadOnly {
    <#
    .SYNOPSIS
    Detect Git read-only operations (status, log, show, diff, branch, etc).
    .DESCRIPTION
    Extracts Git subcommand and checks if it's a read-only query operation.
    Handles both single-word (status, log) and multi-word (stash list, config --list) subcommands.
    Examples: git status, git log, git show, git branch, git stash list, etc.
    .PARAMETER Command
    The Git command string to analyze.
    .OUTPUTS
    [bool] $true if Git command is read-only; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^git\s+(.+)$') {
        $rest = $Matches[1]
        # Try to match multi-word subcommands first (e.g., "stash list", "config --list")
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($GIT_ReadOnlyCommands -contains $twoWordCmd) { return $true }
        }
        # Then try single-word subcommand
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $GIT_ReadOnlyCommands -contains $subcmd
        }
    }
    return $false
}

function Test-IsGitModifying {
    <#
    .SYNOPSIS
    Detect Git modifying operations (commit, push, pull, merge, rebase, etc).
    .DESCRIPTION
    Extracts Git subcommand and checks if it modifies repository state.
    Handles both single-word (commit, push) and multi-word (remote add, stash pop) subcommands.
    These operations require user confirmation.
    .PARAMETER Command
    The Git command string to analyze.
    .OUTPUTS
    [bool] $true if Git command modifies repository; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^git\s+(.+)$') {
        $rest = $Matches[1]
        # Try to match multi-word subcommands first (e.g., "remote add", "stash pop")
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($GIT_ModifyingCommands -contains $twoWordCmd) { return $true }
        }
        # Then try single-word subcommand
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $GIT_ModifyingCommands -contains $subcmd
        }
    }
    return $false
}

function Test-IsKubectlReadOnly {
    <#
    .SYNOPSIS
    Detect kubectl read-only operations (get, describe, logs, top, etc).
    .DESCRIPTION
    Extracts kubectl subcommand and checks if it's read-only.
    .PARAMETER Command
    The kubectl command string to analyze.
    .OUTPUTS
    [bool] $true if kubectl command is read-only; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^kubectl\s+(.+)$') {
        $rest = $Matches[1]
        # Try two-word subcommands first (e.g., "config view", "rollout status")
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($KubectlReadOnlyCmds -contains $twoWordCmd) { return $true }
        }
        # Then single-word subcommand
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $KubectlReadOnlyCmds -contains $subcmd
        }
    }
    return $false
}

function Test-IsKubectlModifying {
    <#
    .SYNOPSIS
    Detect kubectl modifying operations (apply, delete, exec, etc).
    .DESCRIPTION
    Extracts kubectl subcommand and checks if it modifies cluster state.
    .PARAMETER Command
    The kubectl command string to analyze.
    .OUTPUTS
    [bool] $true if kubectl command modifies cluster; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^kubectl\s+(.+)$') {
        $rest = $Matches[1]
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($KubectlModifyingCmds -contains $twoWordCmd) { return $true }
        }
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $KubectlModifyingCmds -contains $subcmd
        }
    }
    return $false
}

function Test-IsCondaReadOnly {
    <#
    .SYNOPSIS
    Detect conda read-only operations (list, info, search, etc).
    .DESCRIPTION
    Extracts conda subcommand and checks if it's read-only.
    .PARAMETER Command
    The conda command string to analyze.
    .OUTPUTS
    [bool] $true if conda command is read-only; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^conda\s+(.+)$') {
        $rest = $Matches[1]
        # Try two-word subcommands first (e.g., "env list", "config --show")
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($CondaReadOnlyCmds -contains $twoWordCmd) { return $true }
        }
        # Then single-word subcommand
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $CondaReadOnlyCmds -contains $subcmd
        }
    }
    return $false
}

function Test-IsCondaModifying {
    <#
    .SYNOPSIS
    Detect conda modifying operations (run, install, create, etc).
    .DESCRIPTION
    Extracts conda subcommand and checks if it modifies state.
    `conda run` executes arbitrary code and is always modifying.
    .PARAMETER Command
    The conda command string to analyze.
    .OUTPUTS
    [bool] $true if conda command modifies state; $false otherwise.
    #>
    param([string]$Command)
    if ($Command -match '^conda\s+(.+)$') {
        $rest = $Matches[1]
        # Try two-word subcommands first (e.g., "env create", "env remove")
        if ($rest -match '^(\S+\s+\S+)(?:\s|$)') {
            $twoWordCmd = $Matches[1]
            if ($CondaModifyingCmds -contains $twoWordCmd) { return $true }
        }
        # Then single-word subcommand
        if ($rest -match '^(\S+)') {
            $subcmd = $Matches[1]
            return $CondaModifyingCmds -contains $subcmd
        }
    }
    return $false
}

function Test-IsDOSReadOnly {
    <#
    .SYNOPSIS
    Detect DOS/CMD read-only commands (dir, type, find, etc).
    .DESCRIPTION
    Extracts base DOS command and checks if it's in the read-only list.
    .PARAMETER Command
    The DOS command string to analyze.
    .OUTPUTS
    [bool] $true if DOS command is read-only; $false otherwise.
    #>
    param([string]$Command)
    $cmdName = ($Command -split '\s+')[0].ToLower()
    return $DOSReadOnlyCommands -contains $cmdName
}

function Test-IsDOSModifying {
    <#
    .SYNOPSIS
    Detect DOS/CMD modifying commands (del, rmdir, copy, etc).
    .DESCRIPTION
    Extracts base DOS command and checks if it modifies files/system.
    .PARAMETER Command
    The DOS command string to analyze.
    .OUTPUTS
    [bool] $true if DOS command is modifying; $false otherwise.
    #>
    param([string]$Command)
    $cmdName = ($Command -split '\s+')[0].ToLower()
    return $DOSModifyingCommands -contains $cmdName
}

function Extract-DOSFromCmdWrapper {
    <#
    .SYNOPSIS
    Extract the actual DOS command from a cmd /c wrapper.
    .DESCRIPTION
    Handles cmd /c "command" or cmd /c command wrappers.
    Returns the inner command without the cmd /c prefix.
    .PARAMETER Command
    The command string containing cmd /c wrapper.
    .OUTPUTS
    [string] The extracted DOS command, or $null if not a cmd wrapper.
    #>
    param([string]$Command)
    if ($Command -match 'cmd(?:\.exe)?\s+/c\s+(.+)$') {
        $innerCmd = $Matches[1].Trim()
        # Remove surrounding quotes if present
        $innerCmd = $innerCmd -replace '^"|"$', ''
        $innerCmd = $innerCmd -replace "^'|'$", ''
        return $innerCmd
    }
    return $null
}

function Test-IsDOSCommand {
    <#
    .SYNOPSIS
    Check if a command is a known DOS command.
    .DESCRIPTION
    Checks if the base command is in either DOS read-only or modifying list.
    .PARAMETER Command
    The command string to check.
    .OUTPUTS
    [bool] $true if command is a known DOS command; $false otherwise.
    #>
    param([string]$Command)
    $cmdName = ($Command -split '\s+')[0].ToLower()
    $allDosCommands = $DOSReadOnlyCommands + $DOSModifyingCommands
    return $allDosCommands -contains $cmdName
}

function Remove-ControlFlowPrefix {
    <#
    .SYNOPSIS
    Strip PowerShell control flow remnants from a command segment.
    .DESCRIPTION
    After extracting { } blocks, control flow keywords and closing braces
    may remain prepended to cmdlets. This function strips them so the
    actual cmdlet can be analyzed.
    
    Handles patterns like:
    - if (...) Remove-Item x   →  Remove-Item x
    - } Remove-Item x          →  Remove-Item x
    - while(...) Get-Process   →  Get-Process
    - else Remove-Item x       →  Remove-Item x
    - do Get-Process           →  Get-Process
    .PARAMETER Segment
    The command segment to clean.
    .OUTPUTS
    [string] The segment with control flow prefixes stripped.
    #>
    param([string]$Segment)

    $cleaned = $Segment

    # Strip do/else (simple keywords without parens)
    $cleaned = $cleaned -replace '^(?:do|else|then)\s+', ''

    # Strip control flow keywords with condition: if (...), while (...), foreach (...), for (...), elseif (...), switch (...), until (...)
    # Use a balanced-paren approach: match keyword + (...)+ with arbitrary nesting
    $cleaned = $cleaned -replace '^(?:if|elseif|while|foreach|for|switch|until)\s*(\(((?:[^()]|\((?<Depth>)|\)(?<-Depth>))*(?(Depth)(?!))\))\s*)+', ''

    # Strip stray } at start (closing braces from removed blocks)
    $cleaned = $cleaned -replace '^}\s*', ''

    # Strip leading/trailing whitespace and semicolons
    $cleaned = $cleaned.Trim()
    $cleaned = $cleaned -replace '^;\s*', ''
    $cleaned = $cleaned -replace '\s*;$', ''

    return $cleaned
}

function Extract-PowerShellCommands {
    <#
    .SYNOPSIS
    Extract individual PowerShell cmdlets from a command string.
    .DESCRIPTION
    Handles multi-line blocks separated by backtick-n (`n) or backslash-n (\n),
    semicolons, and strips comments. Also extracts cmdlets from { } blocks inside
    if/foreach/while/do/switch/etc statements and regex operators.
    
    CRITICAL: Block extraction happens FIRST on the full command string,
    before splitting by `n. This ensures { } blocks that span multiple
    lines are properly extracted.
    
    After extraction, control flow remnants (if (...), while (...), }, etc.)
    are stripped so the actual cmdlets can be analyzed.
    
    Returns array of individual cmdlets.
    .PARAMETER Command
    The PowerShell command string to parse.
    .OUTPUTS
    [string[]] Array of individual PowerShell cmdlets.
    #>
    param([string]$Command)

    $commands = @()

    # Normalize all line separators to `n literal text:
    #   - Real newline chars (from JSON \n decoding) -> `n
    #   - \n literal text (from debug input files)    -> `n
    $Command = $Command.Replace("`n", '`n').Replace('\n', '`n')

    # STEP 1: Extract ALL { } blocks from the ENTIRE command FIRST
    # This must happen BEFORE `n splitting since blocks can span `n lines
    $processed = Extract-CmdletsFromScriptBlocks $Command

    # STEP 2: Split by `n line separator (literal backtick-n text)
    $lines = $processed -split '`n'

    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()
        if (-not $trimmedLine) { continue }

        # STEP 3: Remove inline comments (# to end of line)
        $trimmedLine = $trimmedLine -replace '\s+#.*$', ''
        if ($trimmedLine -match '^#') { continue }

        # STEP 4: Split by semicolons for inline cmdlet separation
        $segments = $trimmedLine -split ';'
        foreach ($seg in $segments) {
            # STEP 5: Strip control flow remnants, then trim
            $cleaned = Remove-ControlFlowPrefix ($seg.Trim())
            if ($cleaned) {
                $commands += $cleaned
            }
        }
    }

    return $commands
}

function Extract-CmdletsFromScriptBlocks {
    <#
    .SYNOPSIS
    Extract cmdlets from { } script blocks within a line using stack-based extraction.
    .DESCRIPTION
    PowerShell allows inline script blocks in control flow statements like:
    - if ($x) { Remove-Item a.txt; Stop-Process b }
    - foreach ($i in 1..10) { Copy-Item a b }
    - while(true) { if ($x) { remove-item a.txt } }
    - Get-Process | Where-Object { $_.CPU -gt 100 }

    Algorithm (stack-based, non-recursive):
    1. Find ALL matched { } pairs using a stack
    2. Process innermost blocks FIRST (no { inside), extract their content
    3. Remove each processed block from the line
    4. Repeat until no blocks remain
    5. Split ALL block contents by semicolons (once, after extraction)
    6. Split remaining line (without blocks) by semicolons
    7. Return everything as a single ;-separated string

    KEY INSIGHT: Don't split by semicolons until ALL block extraction is complete.
    This prevents the doubling bug from the old recursive approach.

    .PARAMETER Line
    The PowerShell line that may contain script blocks.
    .OUTPUTS
    [string] A ;-separated string of all extracted cmdlets and remaining segments.
    #>
    param([string]$Line)

    $lineWithoutBlocks = $Line
    $blockContents = @()     # Raw content of each extracted block
    $maxIterations = 50
    $iteration = 0

    # Phase 1: Extract ALL blocks, innermost first
    while ($lineWithoutBlocks.Contains('{') -and $iteration -lt $maxIterations) {
        $iteration++

        # Build stack of all matched { } pairs
        $stack = @()
        $pairs = @()
        for ($i = 0; $i -lt $lineWithoutBlocks.Length; $i++) {
            if ($lineWithoutBlocks[$i] -eq '{') {
                $stack += $i
            }
            elseif ($lineWithoutBlocks[$i] -eq '}') {
                if ($stack.Count -gt 0) {
                    $openPos = $stack[-1]
                    # Pop: remove last element properly (avoid [0..-1] edge case)
                    if ($stack.Count -gt 1) {
                        $stack = $stack[0..($stack.Count - 2)]
                    } else {
                        $stack = @()
                    }
                    $pairs += [PSCustomObject]@{ Open = $openPos; Close = $i }
                }
            }
        }

        if ($pairs.Count -eq 0) { break }

        # Find innermost pair(s): those with no { inside their content
        # Process them from right-to-left (innermost first)
        $pairs = $pairs | Sort-Object Open -Descending
        $found = $false

        foreach ($pair in $pairs) {
            $innerContent = $lineWithoutBlocks.Substring($pair.Open + 1, $pair.Close - $pair.Open - 1)
            if (-not $innerContent.Contains('{')) {
                # Innermost block — extract content as-is (don't split yet!)
                $blockContents += $innerContent
                # Remove this block from the line
                $lineWithoutBlocks = $lineWithoutBlocks.Substring(0, $pair.Open) + $lineWithoutBlocks.Substring($pair.Close + 1)
                $found = $true
                break  # Restart while loop with updated line
            }
        }

        if (-not $found) { break }
    }

    # Phase 2: Split block contents by semicolons (once!)
    # Also clean up `n and \n line continuations that may appear in block content
    $allCmdlets = @()
    foreach ($block in $blockContents) {
        # Replace `n and \n with space (blocks spanning lines get their newlines cleaned here)
        # Replace real newlines, `n, and \n with space
        $cleanBlock = $block.Replace("`n", ' ').Replace('`n', ' ').Replace('\n', ' ')
        if ($cleanBlock.Contains(';')) {
            $subs = @($cleanBlock -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $allCmdlets += $subs
        }
        else {
            $trimmed = $cleanBlock.Trim()
            if ($trimmed) { $allCmdlets += $trimmed }
        }
    }

    # Phase 3: Split remaining line (without blocks) by semicolons
    $remaining = @()
    if ($lineWithoutBlocks.Contains(';')) {
        $remaining = @($lineWithoutBlocks -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    elseif ($lineWithoutBlocks.Trim()) {
        $remaining = @($lineWithoutBlocks.Trim())
    }

    # Phase 4: Combine — block cmdlets first, then remaining segments
    $allParts = $allCmdlets + $remaining

    if ($allParts.Count -gt 0) {
        return ($allParts -join '; ')
    }
    return $lineWithoutBlocks
}

function Test-IsPowerShellReadOnly {
    <#
    .SYNOPSIS
    Detect PowerShell read-only cmdlets (Get-*, Test-*, Select-*, Format-*, etc).
    .DESCRIPTION
    Checks if cmdlet starts with approved read-only verb.
    PowerShell cmdlets follow standard verb-noun naming convention.
    .PARAMETER Command
    The PowerShell command string to analyze.
    .OUTPUTS
    [bool] $true if cmdlet verb is in read-only list; $false otherwise.
    #>
    param([string]$Command)
    foreach ($verb in $PSReadOnlyVerbs) {
        if ($Command -match "^$verb") { return $true }
    }
    return $false
}

function Test-IsPowerShellModifying {
    <#
    .SYNOPSIS
    Detect PowerShell modifying cmdlets (Remove-*, New-*, Set-*, Copy-*, etc).
    .DESCRIPTION
    Checks if cmdlet starts with verb known to modify system state.
    Handles piped commands (|) by checking each pipe segment independently.
    Examples: Remove-Item, Stop-Service, New-ItemProperty, etc.
    IMPORTANT: Read-only verbs take precedence. If a command matches both a read-only
    and modifying verb (e.g., "Set-Location"), return $false (read-only wins).
    .PARAMETER Command
    The PowerShell command string to analyze.
    .OUTPUTS
    [bool] $true if cmdlet verb is in modifying list; $false otherwise.
    #>
    param([string]$Command)

    # Handle piped/chained commands: check each segment independently.
    # "get-content a.txt | Remove-Item b.txt" — the first segment is read-only
    # but the second is modifying, so the whole command is modifying.
    # Also handles && (AND) and || (OR) chain operators (PowerShell 7+).
    # ; is already split by Extract-PowerShellCommands before this function.
    # & is the call operator in PowerShell, NOT a chain operator — do NOT split on it.
    if ($Command -match '\|\||&&|\|') {
        $segments = $Command -split '\|\||&&|\|'
        foreach ($seg in $segments) {
            $trimmed = $seg.Trim()
            if (-not $trimmed) { continue }
            $isReadOnly = $false
            foreach ($verb in $PSReadOnlyVerbs) {
                if ($trimmed -match "^$verb") { $isReadOnly = $true; break }
            }
            if ($isReadOnly) { continue }
            foreach ($verb in $PSModifyingVerbs) {
                if ($trimmed -match "^$verb") { return $true }
            }
        }
        return $false
    }

    # Read-only verbs take precedence over modifying verbs
    # This allows exceptions like Set-Location to be read-only
    foreach ($verb in $PSReadOnlyVerbs) {
        if ($Command -match "^$verb") { return $false }
    }

    foreach ($verb in $PSModifyingVerbs) {
        if ($Command -match "^$verb") { return $true }
    }

    return $false
}

function Extract-SSHRemoteCommand {
    <#
    .SYNOPSIS
    Extract the remote command string from an SSH command.
    .DESCRIPTION
    SSH commands wrap remote commands in quotes. Extracts the remote command string
    so it can be analyzed independently. Supports both double and single quotes.
    Returns $null if no quoted command found (incomplete SSH command).
    .PARAMETER Command
    The SSH command string (e.g., ssh user@server "cat /var/log/app.log")
    .OUTPUTS
    [string] The extracted remote command, or $null if not found.
    .EXAMPLE
    Extract-SSHRemoteCommand 'ssh user@server "cat /var/log/app.log"'
    # Returns: cat /var/log/app.log
    #>
    param([string]$Command)
    if ($Command -match '"(.+)"') { return $Matches[1] }
    if ($Command -match "'(.+)'") { return $Matches[1] }
    return $null
}

function Extract-BashBlockCommands {
    <#
    .SYNOPSIS
    Extract commands from bash bracket structures (if, for, while, case, etc).
    .DESCRIPTION
    Bash allows control flow structures with brackets:
    - if [ condition ]; then ...; fi
    - for var in ...; do ...; done
    - while [ condition ]; do ...; done
    - case $var in ...) ... ;; esac
    
    This function extracts commands from these block structures so they can be
    analyzed independently. Handles ARBITRARY nesting levels.
    .PARAMETER Command
    The bash command string that may contain bracket structures.
    .OUTPUTS
    [string[]] Array of individual commands extracted from blocks.
    #>
    param([string]$Command)
    
    $extracted = @()
    
    # Patterns for bash control structures
    # if [ condition ]; then BODY fi
    # for x in ...; do BODY done
    # while [ condition ]; do BODY done
    # case $var in PATTERN) BODY ;; esac
    
    # Pattern: if statements - extract body between then and fi
    $ifPattern = 'if\s+\[.*?\]\s*;\s*then\s+(.*?)\s+fi'
    foreach ($match in [regex]::Matches($Command, $ifPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $body = $match.Groups[1].Value
        $extracted += $body -split ';'
    }
    
    # Pattern: for loops - extract body between do and done
    $forPattern = 'for\s+\w+\s+in\s+.*?;\s*do\s+(.*?)\s+done'
    foreach ($match in [regex]::Matches($Command, $forPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $body = $match.Groups[1].Value
        $extracted += $body -split ';'
    }
    
    # Pattern: while loops - extract body between do and done
    $whilePattern = 'while\s+\[.*?\]\s*;\s*do\s+(.*?)\s+done'
    foreach ($match in [regex]::Matches($Command, $whilePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $body = $match.Groups[1].Value
        $extracted += $body -split ';'
    }
    
    # Pattern: case statements - extract body between ) and ;; or esac
    $casePattern = 'case\s+\$?\w+\s+in\s+(.*?)\s+esac'
    foreach ($match in [regex]::Matches($Command, $casePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $body = $match.Groups[1].Value
        # Split by ;; to get individual case patterns
        $cases = $body -split ';;'
        foreach ($c in $cases) {
            # Extract command after )
            if ($c -match '\)(.*)') {
                $extracted += $Matches[1].Trim()
            }
        }
    }
    
    # Clean up and return
    $result = @()
    foreach ($cmd in $extracted) {
        $trimmed = $cmd.Trim()
        if ($trimmed) { $result += $trimmed }
    }
    
    return $result
}

function Split-ChainedCommands {
    <#
    .SYNOPSIS
    Split command strings by operators (&&, ||, |, ;, etc).
    .DESCRIPTION
    Commands can be chained using multiple operators. This function normalizes
    operators to a marker, splits on that marker, and returns cleaned segments.
    Used to analyze each sub-command in a chain independently.
    Handles operators: && (AND), || (OR), | (pipe), ; (sequential), & (background).
    .PARAMETER Command
    The command chain to split.
    .OUTPUTS
    [string[]] Array of individual commands (empty strings filtered out).
    .EXAMPLE
    Split-ChainedCommands 'ls && cd /tmp && pwd'
    # Returns: @('ls', 'cd /tmp', 'pwd')
    #>
    param([string]$Command)
    $operators = @('&&', '||', '|', ';', '&')
    $markedCmd = $Command
    $marker = "@@@"

    # Extract $() command substitutions before splitting
    $substitutions = @()
    if ($markedCmd -match '\$\([^)]+\)') {
        $matches = [regex]::Matches($markedCmd, '\$\(([^)]+)\)')
        foreach ($m in $matches) {
            $substitutions += $m.Groups[1].Value
        }
        $markedCmd = [regex]::Replace($markedCmd, '\$\([^)]+\)', $marker)
    }

    # Split by standard operators
    foreach ($op in $operators) {
        $markedCmd = $markedCmd -replace [regex]::Escape($op), $marker
    }

    $segments = $markedCmd -split $marker
    $segments = @($segments | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # Add back any $() substitutions
    $allSegments = $segments + $substitutions

    return $allSegments
}

function Get-CLICommandType {
    <#
    .SYNOPSIS
    Determine the CLI tool type (AWS, Docker, Terraform, PowerShell, Linux, SSH, Script).
    .DESCRIPTION
    Classifies commands by their tool prefix to route to appropriate analyzer.
    Checks in order: script execution, SSH, AWS, Docker, Terraform, PowerShell, Linux.
    Default fallback is Linux for unknown commands.
    .PARAMETER Command
    The command string to classify.
    .OUTPUTS
    [string] One of: Script, SSH, AWS, Docker, Terraform, PowerShell, Linux.
    #>
    param([string]$Command)
    $cmd = $Command.Trim()
    if (Test-IsScriptExecution $cmd)       { return "Script" }
    if (Test-IsSSHCommand $cmd)              { return "SSH" }
    if ($cmd -match '^aws\s+')                { return "AWS" }
    if ($cmd -match '^docker(?:-compose)?\s') { return "Docker" }
    if ($cmd -match '^terraform\s+')          { return "Terraform" }
    if ($cmd -match '^git\s+')                { return "Git" }
    if ($cmd -match '^kubectl\s+')           { return "kubectl" }
    if ($cmd -match '^conda\s+')              { return "Conda" }
    if ($cmd -match '^[A-Z][a-z]+-')          { return "PowerShell" }
    if ($cmd -match '^cmd(?:\.exe)?\s+/c\s+') { return "DOS" }
    $baseCmd = ($cmd -split '\s+')[0].ToLower()
    if ($DOSReadOnlyCommands -contains $baseCmd -or $DOSModifyingCommands -contains $baseCmd) { return "DOS" }
    return "Linux"
}

function Test-IsReadOnly {
    <#
    .SYNOPSIS
    Determine if a command is safe to auto-approve (read-only).
    .DESCRIPTION
    Route command analysis to appropriate tool-specific detector.
    Scripts are never read-only (unknown code).
    SSH commands must have ALL sub-commands be read-only to approve.
    Other commands delegate to tool-specific logic.
    .PARAMETER Command
    The command string to analyze.
    .OUTPUTS
    [bool] $true if command is confirmed safe and read-only; $false otherwise.
    #>
    param([string]$Command)
    switch (Get-CLICommandType $Command) {
        "Script"     { return $false }
        "SSH"        {
            $remote = Extract-SSHRemoteCommand $Command
            if (-not $remote) { return $false }
            foreach ($sub in (Split-ChainedCommands $remote)) {
                if (-not (Test-IsReadOnly $sub)) { return $false }
            }
            return $true
        }
        "AWS"        { return Test-IsAWSReadOnly $Command }
        "Docker"     { return Test-IsDockerReadOnly $Command }
        "Terraform"  { return Test-IsTerraformReadOnly $Command }
        "Git"        { return Test-IsGitReadOnly $Command }
        "kubectl"    { return Test-IsKubectlReadOnly $Command }
        "Conda"      { return Test-IsCondaReadOnly $Command }
        "DOS"        {
            $inner = Extract-DOSFromCmdWrapper $Command
            if ($inner) { return Test-IsDOSReadOnly $inner }
            return Test-IsDOSReadOnly $Command
        }
        "PowerShell" { return Test-IsPowerShellReadOnly $Command }
        "Linux"      { return Test-IsLinuxReadOnly $Command }
        default      { return $false }
    }
}

function Test-IsModifying {
    <#
    .SYNOPSIS
    Determine if a command modifies system state (requires approval).
    .DESCRIPTION
    Route command analysis to appropriate tool-specific detector.
    Scripts always require approval (unknown code).
    SSH: if ANY sub-command is modifying, the whole chain is modifying.
    If remote command cannot be extracted, treat as modifying (incomplete/unsafe).
    Other commands delegate to tool-specific logic.
    .PARAMETER Command
    The command string to analyze.
    .OUTPUTS
    [bool] $true if command modifies state; $false if confirmed read-only.
    #>
    param([string]$Command)
    switch (Get-CLICommandType $Command) {
        "Script"     { return $true }
        "SSH"        {
            $remote = Extract-SSHRemoteCommand $Command
            if (-not $remote) { return $true }
            foreach ($sub in (Split-ChainedCommands $remote)) {
                if (Test-IsModifying $sub) { return $true }
            }
            return $false
        }
        "AWS"        { return Test-IsAWSModifying $Command }
        "Docker"     { return Test-IsDockerModifying $Command }
        "Terraform"  { return Test-IsTerraformModifying $Command }
        "Git"        { return Test-IsGitModifying $Command }
        "kubectl"    { return Test-IsKubectlModifying $Command }
        "Conda"      { return Test-IsCondaModifying $Command }
        "DOS"        {
            $inner = Extract-DOSFromCmdWrapper $Command
            if ($inner) { return Test-IsDOSModifying $inner }
            return Test-IsDOSModifying $Command
        }
        "PowerShell" { return Test-IsPowerShellModifying $Command }
        "Linux"      { return Test-IsLinuxModifying $Command }
        default      { return $true }
    }
}

# ================================================
# Core Decision Logic
# ================================================

function Get-CommandDecision {
    <#
    .SYNOPSIS
    Make final decision whether to auto-approve or prompt for command.
    .DESCRIPTION
    Applies security checks in order:
    1. Empty command  -> allow
    2. File redirections (> file, >> file, 1> file) -> ask (modifying)
       Exception: console-only redirections (2>&1, 2>/dev/null) -> allow
    3. Script execution -> ask (unknown code)
    4. SSH commands -> extract remote command and analyze sub-commands
    5. Chained commands -> check if ANY sub-command modifies
    6. Single commands -> check if read-only vs modifying
    7. Unknown commands -> ask (safe default)
    .PARAMETER Command
    The command string to make a decision on.
    .OUTPUTS
    Hashtable with 'decision' (allow|ask) and 'reason' (explanation).
    #>
    param([string]$Command)

    if (-not $Command -or $Command.Trim().Length -eq 0) {
        return @{ decision = "allow"; reason = "Empty command" }
    }

    # Output redirection to files modifies (creates/overwrites files)
    # Exception: allow stderr->stdout console redirections like "2>&1" (non-modifying)
    $testCmd = $Command -replace '2>&1', ''  # Remove safe stderr->stdout redirect
    $testCmd = $testCmd -replace '2>/dev/null', ''  # Remove stderr to /dev/null

    # if ($testCmd -match '(?<!&)>\s*\w' -or $testCmd -match '>>\s*\w' -or $testCmd -match '1>\s*\w') {
    if ($testCmd -match '(?:^|\s)(?:\d+)?>>?\s+[a-zA-Z./~\\]') {
        return @{ decision = "ask"; reason = "REDIRECT: Command contains file output redirection (modifying)" }
    }

    # Trusted scripts — auto-approve regardless of classification
    # (configured via trusted_script_files in cli-commands.json)
    if (Test-IsTrustedScript $Command) {
        return @{ decision = "allow"; reason = "TRUSTED_SCRIPT: Script file is in trusted list" }
    }

    # Script execution - always ask (unless trusted)
    if (Test-IsScriptExecution $Command) {
        return @{ decision = "ask"; reason = "EXECUTES_SCRIPT: Executes external script (unknown code)" }
    }

    # SSH commands - analyze remote sub-commands
    if (Test-IsSSHCommand $Command) {
        $remote = Extract-SSHRemoteCommand $Command
        if (-not $remote) {
            return @{ decision = "ask"; reason = "SSH_INCOMPLETE: SSH command without quoted remote command" }
        }
        
        $notReadOnly = @()
        
        # First, extract commands from bash bracket structures (if, for, while, case)
        $blockCmds = Extract-BashBlockCommands $remote
        foreach ($sub in $blockCmds) {
            $trimmed = $sub.Trim()
            if (-not $trimmed) { continue }
            # Check if this sub-command is read-only
            if (-not (Test-IsReadOnly $trimmed)) { $notReadOnly += $trimmed }
        }
        
        # Also check the chained commands at the top level
        foreach ($sub in (Split-ChainedCommands $remote)) {
            $trimmed = $sub.Trim()
            if (-not $trimmed) { continue }
            # Skip if already checked in block extraction
            if ($blockCmds -contains $trimmed) { continue }
            if (-not (Test-IsReadOnly $trimmed)) { $notReadOnly += $trimmed }
        }
        
        if ($notReadOnly.Count -gt 0) {
            return @{ decision = "ask"; reason = "SSH_MODIFIES: Remote command is not confirmed read-only: $($notReadOnly -join '|')" }
        }
        return @{ decision = "allow"; reason = "SSH_READ_ONLY: All remote commands are read-only" }
    }

    # PowerShell code blocks — extract individual cmdlets and analyze each
    # Guard: only enter PowerShell block path for actual PowerShell commands
    # or commands with { } blocks (non-PS commands with ; are handled by chain analysis below)
    $cmdType = Get-CLICommandType $Command
    $originalHadBlocks = $Command.Contains('{') -and $Command.Contains('}')
    $psCmdlets = Extract-PowerShellCommands $Command
    if (($cmdType -eq "PowerShell" -and $psCmdlets.Count -gt 1) -or ($originalHadBlocks -and $psCmdlets.Count -gt 0)) {
        $modifyingCmds = @()
        foreach ($cmdlet in $psCmdlets) {
            # Use full Test-IsModifying to catch script executions, DOS, PS, conda, etc.
            if (Test-IsModifying $cmdlet) {
                $modifyingCmds += $cmdlet
                break
            }
        }
        if ($modifyingCmds.Count -gt 0) {
            return @{ decision = "ask"; reason = "PS_BLOCK_MODIFIES: PowerShell block contains modifying operations: $($modifyingCmds -join '|')" }
        }
        return @{ decision = "allow"; reason = "PS_BLOCK_READ_ONLY: All PowerShell cmdlets are read-only" }
    }

    # Command chains - check each segment
    $subCommands = Split-ChainedCommands $Command
    if ($subCommands.Count -gt 1) {
        $modifyingCmds = @()
        foreach ($sub in $subCommands) {
            if (Test-IsSSHCommand $sub) {
                $sshDecision = Get-CommandDecision $sub
                if ($sshDecision.decision -eq "ask") { return $sshDecision }
            } elseif (Test-IsModifying $sub) {
                $modifyingCmds += $sub
            }
        }
        if ($modifyingCmds.Count -gt 0) {
            return @{ decision = "ask"; reason = "CHAIN_MODIFIES: Command chain contains modifying operation(s): $($modifyingCmds -join '|')" }
        }
        return @{ decision = "allow"; reason = "CHAIN_READ_ONLY: All commands in chain are read-only" }
    }

    # Single command
    if (Test-IsReadOnly $Command) {
        return @{ decision = "allow"; reason = "READ_ONLY: Read-only command" }
    }
    if (Test-IsModifying $Command) {
        return @{ decision = "ask"; reason = "MODIFIES: Modifying command" }
    }

    # Unknown - safe default
    return @{ decision = "ask"; reason = "UNKNOWN: Unknown command type (safe default)" }
}

# ================================================
# MAIN ENTRY POINT
# Called by VS Code Copilot PreToolUse hook via stdin
# ================================================

# This section:
# 1. Reads JSON payload from stdin (VS Code Copilot hook API)
# 2. Validates it's a run_in_terminal call
# 3. Extracts the command string
# 4. Invokes decision logic via Get-CommandDecision
# 5. Outputs JSON response (allow or ask)

# Start timing immediately - measures total hook latency from entry to exit
$HookStartTime = Get-Date

Initialize-Log

# Read JSON payload from stdin (or from -DebugInputFile/-DebugInput for VS Code debugger)
if ($DebugInputFile) {
    if (Test-Path $DebugInputFile) {
        $stdinRaw = Get-Content $DebugInputFile -Raw
    } else {
        Write-Allow "Debug input file not found; defaulting to allow"
        exit 0
    }
} elseif ($DebugInput) {
    $stdinRaw = $DebugInput
} else {
    $stdinRaw = [Console]::In.ReadToEnd()
}

# Log raw payload (truncated)
#$rawTrimmed = if ($stdinRaw.Length -gt 2048) { $stdinRaw.Substring(0, 2048) + "..." } else { $stdinRaw }
#$rawClean = $rawTrimmed -replace "`n", " " -replace "`r", ""
#Write-Log "DEBUG" "RAW=$rawClean"

# Also dump full payload for inspection
if ($script:logFile) {
    try { Add-Content -Path "$($script:logFile).full.json" -Value $stdinRaw -ErrorAction SilentlyContinue } catch { }
}

# Parse stdin
if (-not $stdinRaw -or $stdinRaw.Trim().Length -eq 0) {
    Write-Log "WARN" "Empty stdin - defaulting to allow"
    Write-Allow "Empty hook input; defaulting to allow"
    exit 0
}

try {
    $payload = $stdinRaw | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Could not parse hook input JSON: $stdinRaw"
    Write-Allow "Could not parse hook input; defaulting to allow"
    exit 0
}

# Only intercept run_in_terminal tool calls
$toolName = $payload.tool_name
if ($toolName -notin @('run_in_terminal', 'Bash', 'bash', 'terminal', 'execute_command')) {
    Write-Log "SKIP" "Non-terminal tool ($toolName)"
    Write-Allow "Non-terminal tool ($toolName) - skipping analysis"
    exit 0
}

# Extract command
$cmdToAnalyze = $payload.tool_input.command
if (-not $cmdToAnalyze) { $cmdToAnalyze = $payload.tool_input.cmd }

if ([string]::IsNullOrWhiteSpace($cmdToAnalyze)) {
    Write-Allow "No command field in tool_input"
    exit 0
}

# Log extracted fields
$logCmd = $cmdToAnalyze.Substring(0, [Math]::Min(2048, $cmdToAnalyze.Length))
$logCmd = "---[$logCmd]---"  #easier to spot in log
#Write-Log "PARSE" "tool=$toolName cmd=$logCmd"

# Run analysis
$decision = Get-CommandDecision $cmdToAnalyze

# Calculate total hook execution time
$elapsedMs = [int]((Get-Date) - $HookStartTime).TotalMilliseconds

# Log and output decision
if ($decision.decision -eq "allow") {
    Write-Log "ALLOW" "$($decision.reason) | cmd=$logCmd"
    Write-Log "TIMING" "decision=allow elapsed=$($elapsedMs)ms"
    Write-Allow $decision.reason
} else {
    Write-Log "ASK   " "$($decision.reason) | cmd=$logCmd"
    Write-Log "TIMING" "decision=ask elapsed=$($elapsedMs)ms"
    Write-Ask $decision.reason
}

exit 0
