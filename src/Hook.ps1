# Hook.ps1 — Main stdin/stdout entry point for the PreToolUse Hook System
# Invoked by Claude Code, Copilot (VS Code), Codex CLI, or the DeepSeek
# Harness bridge (dsh-plugin-pretoolhook) as the hook script.
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
# Step 3a: Detect the harness on the RAW payload shape (F1).
# MUST run before normalization: the camelCase toolName signal is
# decisive for Copilot and the normalizer removes that field.
# (ClaudeCode, Copilot, Local, Codex, or DSH)
# ----------------------------------------------------
$ide = Detect-IDE -InputObject $parsedInput

# ----------------------------------------------------
# Step 3.5: Boundary normalization (F1, quad-contract migration).
# The Copilot harness sends camelCase (toolName/toolArgs/sessionId);
# every internal consumer reads snake_case. Rewrite the parsed object
# in place so Step 4's tool_name check and the whole pipeline see the
# canonical shape. snake_case payloads pass through untouched.
# ----------------------------------------------------
$parsedInput = ConvertTo-CanonicalPayload -InputObject $parsedInput

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
# Step 7: (IDE detection moved to Step 3a - must precede normalization)
# ----------------------------------------------------

# ----------------------------------------------------
# Step 7b: Adopt the other folders of the VS Code workspace
# (no-op unless workspace_roots.enabled; Copilot/Local only).
# They are treated exactly like the cwd by the path policy.
# ----------------------------------------------------
try {
    $null = Add-WorkspaceRoots -Config $config -IDE $ide
}
catch {
    [Console]::Error.WriteLine("Hook: workspace_roots skipped: $($_.Exception.Message)")
}

# ----------------------------------------------------
# Step 8: Classify the command through the full pipeline
# ----------------------------------------------------
$classifyResult = Invoke-Classify -RawInput $parsedInput -IDE $ide -Config $config

# ----------------------------------------------------
# Step 8a (F3, 2026-11-14): answer deadline for the detected harness.
# config answer_deadline_ms keeps the hook's verdict BELOW the harness's
# own kill timer (Copilot/Local bare registrations: 30 s) so a verdict is
# never discarded. Effective budget = min(deadline, timeout_ms + 2000)
# when the LLM wait is enabled (Get-AnswerDeadlineBudgetMs). Checked
# BEFORE the LLM wait and again after it; on deadline-before-verdict the
# Decision is a fail-closed ask with the contractual reason template.
# ----------------------------------------------------
$deadlineBudgetMs = Get-AnswerDeadlineBudgetMs -Config $config -IDE $ide
$deadlineExceeded = ($deadlineBudgetMs -gt 0 -and
                     ((Get-Date) - $startTime).TotalMilliseconds -gt $deadlineBudgetMs)

# ----------------------------------------------------
# Step 8b: Second-opinion LLM cross-check (no-op unless
# llm_second_opinion.enabled is true in config). The LLM can
# only escalate an allow to ask - never downgrade.
# Skipped when the answer deadline already passed (fail-closed:
# a verdict that cannot arrive before the kill timer is not worth
# the tokens; the ask below is emitted immediately). The LLM wait
# is additionally clamped to the remaining deadline budget.
# ----------------------------------------------------
$llmLog = $null
if ($deadlineExceeded) {
    # deadline-before-verdict: no LLM call, the forced ask follows Step 8c
}
elseif ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $remainingMs = 0
    if ($deadlineBudgetMs -gt 0) {
        $remainingMs = [long]($deadlineBudgetMs - ((Get-Date) - $startTime).TotalMilliseconds)
        if ($remainingMs -lt 1000) { $remainingMs = 1000 }   # IRM TimeoutSec floor
    }
    $llmOutcome = Invoke-LlmReview -ClassifyResult $classifyResult -Config $config -DeadlineMs $remainingMs
    $classifyResult = $llmOutcome.Result
    $llmLog = $llmOutcome.Log
}
elseif ($config._compiled.llmThirdOpinion -and $config._compiled.llmThirdOpinion.Enabled) {
    # D3 (2026-09-30 pair design 6): the pair cannot fire without its primary.
    # No LLM calls; an explicit skip log object makes the state records-visible
    # (D13) and renders the dedicated 'LLM2 skipped' line in the .log.
    $llmLog = New-Llm2SkipLog -Config $config
}

# ----------------------------------------------------
# Step 8c (F3): deadline-before-verdict -> fail-closed ask. Re-check the
# budget AFTER the LLM path: either it was already spent before the wait
# (Step 8a) or the bounded wait abandoned the LLM at the deadline. Either
# way the verdict did not arrive in time, so ask NOW with the contractual
# reason instead of risking a discarded response.
# ----------------------------------------------------
if (-not $deadlineExceeded -and $deadlineBudgetMs -gt 0) {
    $deadlineExceeded = ((Get-Date) - $startTime).TotalMilliseconds -gt $deadlineBudgetMs
}
if ($deadlineExceeded) {
    $classifyResult = New-AnswerDeadlineAskResult -ClassifyResult $classifyResult -IDE $ide -BudgetMs $deadlineBudgetMs
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
