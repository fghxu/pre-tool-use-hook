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
. "$PSScriptRoot\LlmReview.ps1"
. "$PSScriptRoot\Notify-Ask.ps1"

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
    # Env override exists so test runners can point the hook at a fixture copy;
    # production always uses the repo-root config.json.
    $configPath = if ($env:PRETOOLHOOK_CONFIG_PATH) { $env:PRETOOLHOOK_CONFIG_PATH } else { "$PSScriptRoot\..\config.json" }
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
# Step 8b: Second-opinion LLM cross-check (no-op unless
# llm_second_opinion.enabled is true in config). The LLM can
# only escalate an allow to ask - never downgrade.
# ----------------------------------------------------
$llmLog = $null
if ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $llmOutcome = Invoke-LlmReview -ClassifyResult $classifyResult -Config $config
    $classifyResult = $llmOutcome.Result
    $llmLog = $llmOutcome.Log
}

# ----------------------------------------------------
# Step 9: Calculate elapsed time
# ----------------------------------------------------
$elapsed = (Get-Date) - $startTime

# ----------------------------------------------------
# Step 10: Timeout checks — 500ms warning, hard-cap override
# ----------------------------------------------------
# Hard cap: 3000ms normally; timeout_ms + 2000 headroom when the LLM
# second opinion is enabled (its wait budget dwarfs local classification).
$hardCapMs = 3000
if ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $hardCapMs = $config._compiled.llmSecondOpinion.TimeoutMs + 2000
}
if ($elapsed.TotalMilliseconds -gt $hardCapMs) {
    # Hard timeout: force "ask" regardless of classification result
    $classifyResult = [PSCustomObject]@{
        Decision    = "ask"
        Reason      = "classification timed out"
        ExitCode    = 0
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

# ----------------------------------------------------# Step 10b: Ask notification (toast + sound on ask decisions)
# Fire-and-forget; never blocks the hook, never changes the decision.
# ----------------------------------------------------
Send-AskNotification -ClassifyResult $classifyResult -Config $config

# ----------------------------------------------------# Step 11: Log (non-fatal) — write record and log entries; warn on failure
# ----------------------------------------------------
try {
    $logDir = New-LogDirectory -Config $config
    Write-RecordEntry -RawInput $parsedInput -ClassifyResult $classifyResult -LogDir $logDir -IDE $ide -LlmLog $llmLog
    Write-LogEntry -RawInput $parsedInput -ClassifyResult $classifyResult -Elapsed $elapsed -LogDir $logDir -IDE $ide -LlmLog $llmLog
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
