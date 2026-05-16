# Hook.ps1 — Main stdin/stdout entry point for the PreToolUse Hook System
# Invoked by Claude Code or Copilot as the hook script.
# Reads JSON from stdin, classifies the command, and outputs the decision to stdout.

# ----------------------------------------------------
# Step 4: Dot-source all dependencies from $PSScriptRoot
# ----------------------------------------------------
. "$PSScriptRoot\HookAdapter.ps1"
. "$PSScriptRoot\ConfigLoader.ps1"
. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Classifier.ps1"

# ----------------------------------------------------
# Step 1: Read stdin — the IDE writes JSON to the process stdin stream.
# Use [Console]::In.ReadToEnd() to read from the raw stdin stream.
# Note: Do NOT use $input (PowerShell pipeline variable) — $input only
# works when data is piped via | (e.g. echo '...' | pwsh ...). When the
# IDE spawns pwsh as a child process and writes to its stdin, the data
# arrives on [Console]::In, not the PowerShell pipeline.
# ----------------------------------------------------
$rawJson = [Console]::In.ReadToEnd()

# ----------------------------------------------------
# Step 2: Validate input — empty/whitespace = fatal
# ----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($rawJson)) {
    [Console]::Error.WriteLine("Hook: No input received on stdin")
    exit 2
}

# ----------------------------------------------------
# Step 3: Parse JSON — on failure write error to stderr and exit 2
# ----------------------------------------------------
$parsedInput = $null
try {
    $parsedInput = $rawJson | ConvertFrom-Json -ErrorAction Stop
}
catch {
    [Console]::Error.WriteLine("Hook: Failed to parse JSON input: $($_.Exception.Message)")
    exit 2
}

# ----------------------------------------------------
# Step 4: Validate required fields (post-parse sanity checks)
# ----------------------------------------------------
# Missing tool_name is fatal — we cannot classify without it
if (-not $parsedInput.tool_name -or [string]::IsNullOrWhiteSpace($parsedInput.tool_name)) {
    [Console]::Error.WriteLine("Hook: Missing required field: tool_name")
    exit 2
}

# Missing both hook_event_name AND timestamp — can't detect IDE reliably
# Non-fatal: default IDE to "ClaudeCode" with a warning
if ((-not $parsedInput.hook_event_name) -and (-not $parsedInput.timestamp)) {
    [Console]::Error.WriteLine("Hook: Warning: Missing both hook_event_name and timestamp, defaulting IDE detection")
}

# ----------------------------------------------------
# Step 5: Start timer
# ----------------------------------------------------
$startTime = Get-Date

# ----------------------------------------------------
# Step 6: Load config — on failure write error to stderr and exit 2
# ----------------------------------------------------
$config = $null
try {
    $configPath = "$PSScriptRoot\..\config.json"
    $config = Load-Config -Path $configPath
}
catch {
    [Console]::Error.WriteLine("Hook: Failed to load config: $($_.Exception.Message)")
    exit 2
}

# ----------------------------------------------------
# Step 7: Detect IDE (ClaudeCode or Copilot)
# ----------------------------------------------------
$ide = Detect-IDE -InputObject $parsedInput

# ----------------------------------------------------
# Step 8: Classify the command through the full pipeline
# ----------------------------------------------------
$classifyResult = Invoke-Classify -RawInput $parsedInput -IDE $ide -Config $config

# ----------------------------------------------------
# Step 9: Calculate elapsed time
# ----------------------------------------------------
$elapsed = (Get-Date) - $startTime

# ----------------------------------------------------
# Step 10: Timeout checks — 500ms warning, 1000ms hard override
# ----------------------------------------------------
if ($elapsed.TotalMilliseconds -gt 1000) {
    # Hard timeout: force "ask" regardless of classification result
    $classifyResult = [PSCustomObject]@{
        Decision    = "ask"
        Reason      = "classification timed out"
        ExitCode    = 2
        IDE         = $ide
        ToolName    = $classifyResult.ToolName
        Command     = $classifyResult.Command
        SubResults  = @()
        IsSkipped   = $false
        IsUnknown   = $false
    }
}
elseif ($elapsed.TotalMilliseconds -gt 500) {
    # Soft timeout: add PerformanceWarning but don't change the decision
    $classifyResult | Add-Member -MemberType NoteProperty -Name 'PerformanceWarning' -Value "classification took $([math]::Round($elapsed.TotalMilliseconds, 0))ms (>500ms threshold)" -Force
}

# ----------------------------------------------------
# Step 11: Log (non-fatal) — write record and log entries; warn on failure
# ----------------------------------------------------
try {
    $logDir = New-LogDirectory -Config $config
    Write-RecordEntry -RawInput $parsedInput -ClassifyResult $classifyResult -LogDir $logDir -IDE $ide
    Write-LogEntry -RawInput $parsedInput -ClassifyResult $classifyResult -Elapsed $elapsed -LogDir $logDir -IDE $ide
}
catch {
    [Console]::Error.WriteLine("Hook: Warning: Logging failed: $($_.Exception.Message)")
}

# ----------------------------------------------------
# Step 12: Format output for the detected IDE
# ----------------------------------------------------
$output = Format-Output -ClassifyResult $classifyResult -IDE $ide

# ----------------------------------------------------
# Step 13: Write stdout as compressed JSON
# ----------------------------------------------------
$outputJson = $output | ConvertTo-Json -Compress
Write-Output $outputJson

# ----------------------------------------------------
# Step 14: Exit with the classification result's exit code
# ----------------------------------------------------
exit $classifyResult.ExitCode
