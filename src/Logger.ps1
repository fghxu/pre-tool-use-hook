# Logger.ps1 — Audit Logging
# Writes record files (JSONL) and log files (human-readable text).
# See: docs/superpowers/specs/2026-05-15-architecture-design.md

function New-LogDirectory {
    <#
    .SYNOPSIS
        Resolves the log directory path from config and creates it if missing.
    .PARAMETER Config
        The parsed config.json config object.
    .OUTPUTS
        String. The resolved log directory path.
    #>
    param([PSCustomObject]$Config)

    $logDir = ''

    if ($Config -and $Config.log_file_path -and $Config.log_file_path -ne '') {
        $logDir = $Config.log_file_path
    }
    else {
        if ($IsWindows) {
            $logDir = "$env:USERPROFILE\.pretoolhook\"
        }
        else {
            $logDir = "$HOME/.pretoolhook/"
        }
    }

    # If no path could be resolved, throw a descriptive error
    if (-not $logDir -or $logDir -eq '' -or $logDir -eq '/.pretoolhook/' -or $logDir -eq '\.pretoolhook\') {
        throw "New-LogDirectory: Cannot resolve log directory path. Config log_file_path is empty and neither `$env:USERPROFILE nor `$HOME is available."
    }

    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    return $logDir
}

function Write-RecordEntry {
    <#
    .SYNOPSIS
        Writes a single JSONL line to the daily record file (per-IDE split).
    .PARAMETER RawInput
        The raw PSCustomObject received from the IDE.
    .PARAMETER ClassifyResult
        The classification result object (currently unused for record content,
        available for future audit enrichment).
    .PARAMETER LogDir
        Path to the log directory.
    .PARAMETER IDE
        The IDE identifier ("ClaudeCode", "Copilot", or "Codex"). Used to split logs by IDE.
    #>
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [string]$LogDir,
        [string]$IDE,
        [PSCustomObject]$LlmLog = $null
    )

    # received_at is an instant in time (UTC, denoted by Z suffix).
    # The daily record FILE is named by LOCAL computer date so that a late-
    # evening run does not roll over to "tomorrow's" file (user is in EST).
    $utcNow = (Get-Date).ToUniversalTime()
    $localNow = Get-Date
    $receivedAt = $utcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Defensive: ensure log directory exists before writing
    if ($LogDir -and -not (Test-Path $LogDir)) {
        try {
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        }
        catch {
            [Console]::Error.WriteLine("Logger: Warning: Could not create log directory: $($_.Exception.Message)")
        }
    }

    # Edge case: null RawInput → use placeholder record
    if ($null -eq $RawInput) {
        $record = [PSCustomObject]@{
            received_at = $receivedAt
            raw         = "null input"
        }
    }
    else {
        # Deep-copy RawInput to preserve exact incoming data
        $deepCopy = $RawInput | ConvertTo-Json -Compress -Depth 10 | ConvertFrom-Json

        $record = [PSCustomObject]@{
            received_at = $receivedAt
            raw         = $deepCopy
        }
    }

    # Optional second-opinion LLM record (spec section 8)
    if ($LlmLog) {
        $record | Add-Member -MemberType NoteProperty -Name 'llm' -Value $LlmLog -Force
    }

    $jsonLine = $record | ConvertTo-Json -Compress -Depth 10

    $ideSuffix = if ($IDE -eq 'Copilot') { 'copilot' } elseif ($IDE -eq 'Codex') { 'codex' } elseif ($IDE -eq 'DSH') { 'dsh' } else { 'claude' }
    $fileName = $localNow.ToString('yyyy-MM-dd') + '.' + $ideSuffix + '.records.jsonl'
    $filePath = Join-Path $LogDir $fileName

    # Append single line, close immediately (crash-safe)
    # Retry loop: up to 3 attempts with 10ms delay to reduce collision probability
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $maxRetries = 3
    $retryDelayMs = 10
    $written = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($filePath, $jsonLine + "`n", $utf8NoBom)
            $written = $true
            break
        }
        catch [System.IO.IOException] {
            if ($attempt -lt $maxRetries) {
                Start-Sleep -Milliseconds $retryDelayMs
            }
            else {
                [Console]::Error.WriteLine("Logger: Warning: Failed to write record entry after $maxRetries attempts: $($_.Exception.Message)")
            }
        }
        catch {
            [Console]::Error.WriteLine("Logger: Warning: Failed to write record entry: $($_.Exception.Message)")
            break
        }
    }
}

function Get-SuppressedTierLabel {
    <#
    .SYNOPSIS
        Option B: derive the tier label for the suppressed sub-commands from the
        log's per-index tiers ($LlmLog.tiers, 0-based; suppressed indices are 1-based).
        Backward-compatible: all strictness_gated => 'strictness_gated' (the pre-Option-B
        label); all trusted_program => 'trusted_program'; mixed => joined with '+'.
        Returns '' when there is nothing to label.
    #>
    param([PSCustomObject]$LlmLog)
    $suppressed = @($LlmLog.suppressed)
    if ($suppressed.Count -eq 0) { return '' }
    $tiers = @()
    foreach ($ix in $suppressed) {
        $t = ''
        if ($LlmLog.tiers -and $ix -ge 1 -and $ix -le $LlmLog.tiers.Count) { $t = "$($LlmLog.tiers[$ix - 1])" }
        if (-not $t) { $t = 'unlabeled' }
        $tiers += $t
    }
    return (@($tiers | Select-Object -Unique) -join '+')
}

function Format-LlmLogBlock {
    <#
    .SYNOPSIS
        Shared reconciliation formatter (phase-II spec section 7 + P9).
        Returns the multi-line LLM evidence block for the human-readable .log
        when a call actually happened (in_scope), a one-line summary when the
        feature was enabled but out of scope, and '' when $LlmLog is null.
        Used by Write-LogEntry (production) and by test runners (per-run logs).
    #>
    param(
        [PSCustomObject]$Result,
        [PSCustomObject]$LlmLog
    )
    if ($null -eq $LlmLog) { return '' }

    # D3 skip-note (design 5.1): llm_third_opinion enabled but
    # llm_second_opinion disabled/absent - the pair cannot fire. Dedicated
    # line naming LLM2 explicitly (user requirement), rendered before the
    # generic out-of-scope one-liner. Only fires for this one effect value.
    if ("$($LlmLog.effect)" -eq 'skipped-primary-disabled') {
        return "  LLM2          : llm_third_opinion enabled but llm_second_opinion disabled - LLM2 skipped`n"
    }

    # Out-of-scope: keep the phase-I one-liner (with the sub-command count, so
    # threshold tuning for complex_min_subcommands is auditable from the log),
    # AND carry the level + the scope reason so the log alone explains WHY the
    # LLM was skipped (user requirement 2026-08-04). level/scope_reason are
    # null-safe: older Log objects without them just render empty.
    if (-not $LlmLog.in_scope) {
        $lvl = ''
        if (Get-Member -InputObject $LlmLog -Name level -MemberType Properties -ErrorAction SilentlyContinue) { $lvl = "$($LlmLog.level)" }
        $scopeReason = ''
        if (Get-Member -InputObject $LlmLog -Name scope_reason -MemberType Properties -ErrorAction SilentlyContinue) { $scopeReason = "$($LlmLog.scope_reason)" }
        return "  LLM: [ $($LlmLog.sub_command_count) subcommand ] | in_scope=$($LlmLog.in_scope) | level=$lvl | reason=$scopeReason | verdict=$($LlmLog.verdict) effect=$($LlmLog.effect) latency_ms=$($LlmLog.latency_ms)`n"
    }

    # ----------------------------------------------------------------
    # R2 trusted/editable PRE-SKIP (2026-10-20 production-log defect): the skip
    # path never calls the LLM, so the generic SENT/RECV/LOCAL triple rendered an
    # EMPTY exchange - "LLM-RECV: '' (ms, recovered=False)" plus a blank local
    # decision - which reads like a failed/empty round-trip. Render ONE
    # self-documenting line instead: the reason the call was skipped, the
    # per-index tiers, and the local decision that stands on its own.
    # ----------------------------------------------------------------
    if ("$($LlmLog.effect)" -eq 'llm-skipped-trusted-editable') {
        $sReason = ''
        if (Get-Member -InputObject $LlmLog -Name scope_reason -MemberType Properties -ErrorAction SilentlyContinue) { $sReason = "$($LlmLog.scope_reason)" }
        $skipLine = "  LLM           : skipped (all tiers trusted/editable) | [ $($LlmLog.sub_command_count) subcommand ] | level=$($LlmLog.level) | reason=$sReason"
        $skipTiers = @()
        if ($LlmLog.tiers -and $LlmLog.tiers.Count -gt 0) {
            for ($i = 0; $i -lt $LlmLog.tiers.Count; $i++) {
                $t = "$($LlmLog.tiers[$i])"; if (-not $t) { $t = 'unlabeled' }
                $skipTiers += "[$($i + 1)]=$t"
            }
            $skipLine += " | tiers: " + ($skipTiers -join ' ')
        }
        $skipLocal = "$($LlmLog.local_decision)"
        if (-not $skipLocal) { $skipLocal = 'n/a' }
        $skipLine += " | local=$skipLocal"
        # The armed pair is skipped too (D14) - name it only when it exists.
        if ($null -ne (Get-Member -InputObject $LlmLog -Name llm2 -MemberType Properties -ErrorAction SilentlyContinue)) {
            $skipLine += " | pair skipped (comparison not applicable)"
        }
        $skipLine += " -> FINAL: $($Result.Decision)`n"
        return $skipLine
    }

    $mockMark = if ($LlmLog.mocked) { ' (mock)' } else { '' }

    # Pair (llm_third_opinion) helpers: the llm2 sub-object exists whenever the
    # pair was armed; 'called' = a real pair consult happened (the states that
    # get the SENT extension + the LLM2-RECV line).
    $hasLlm2 = ($null -ne (Get-Member -InputObject $LlmLog -Name llm2 -MemberType Properties -ErrorAction SilentlyContinue))
    $llm2Compare = if ($hasLlm2) { "$($LlmLog.llm2.compare)" } else { '' }
    $pairCalled = ($hasLlm2 -and $llm2Compare -in @('agree', 'disagree', 'llm1-down', 'llm2-down'))

    # --- LLM-SENT: sub-command count + model + timeout + the numbered list (<=120 chars each)
    $sentLine = "  LLM-SENT      : [ $($LlmLog.sub_command_count) subcommand ] | model=$($LlmLog.model)"
    if ($LlmLog.timeout_ms) { $sentLine += " timeout=$($LlmLog.timeout_ms)ms" }
    # design 5.2: when the pair was called, name LLM2 + its clamped timeout.
    if ($pairCalled) {
        $sentLine += " model2=$($LlmLog.llm2.model) timeout2=$($LlmLog.llm2.effective_timeout_ms)ms"
    }
    if ($LlmLog.sent -and $LlmLog.sent.Count -gt 0) {
        $parts = @()
        for ($i = 0; $i -lt $LlmLog.sent.Count; $i++) {
            $t = "$($LlmLog.sent[$i])"
            if ($t.Length -gt 120) { $t = $t.Substring(0, 120) }
            $parts += "[$($i + 1)] $t"
        }
        $sentLine += " | " + ($parts -join ' | ')
    }
    $sentLine += "`n"

    # --- LLM-RECV: raw response (single line) or the error, latency, recovered, mock
    $recvLine = "  LLM-RECV      : "
    if ($LlmLog.verdict -eq 'down') {
        $err = "$($LlmLog.error)"
        if ($err.Length -gt 200) { $err = $err.Substring(0, 200) }
        $recvLine += "ERROR '$err'"
    }
    else {
        $rawDisplay = $LlmLog.raw_full
        if (-not $rawDisplay) { $rawDisplay = $LlmLog.raw_excerpt }
        # Collapse to single line for log readability
        $rawDisplay = ($rawDisplay -replace '\s+', ' ').Trim()
        $displayLimit = if ($LlmLog.raw_display_limit) { $LlmLog.raw_display_limit } else { 500 }
        if ($rawDisplay.Length -gt $displayLimit) { $rawDisplay = $rawDisplay.Substring(0, $displayLimit) + '…' }
        $recvLine += "'$rawDisplay'"
    }
    $recvLine += " ($($LlmLog.latency_ms)ms, recovered=$($LlmLog.recovered)$mockMark) -> verdict=$($LlmLog.verdict)"
    if ($LlmLog.indices) { $recvLine += " indices=[$($LlmLog.indices -join ',')]" }
    $recvLine += "`n"

    # --- LLM2-RECV (design 5.3): exact mirror of the LLM-RECV rules, directly
    # under it, when the pair was actually called. Label padded to the same
    # 14-char field so the ':' column aligns with LLM-RECV/LLM-LOCAL/
    # LLM-RECONCILE (LLM2-RECV is 9 chars + 5 spaces).
    $llm2RecvLine = ''
    if ($pairCalled) {
        $l2 = $LlmLog.llm2
        $l2MockMark = if ($l2.mocked) { ' (mock)' } else { '' }
        $l2Line = "  LLM2-RECV     : "
        if ("$($l2.verdict)" -eq 'down') {
            $l2err = "$($l2.error)"
            if ($l2err.Length -gt 200) { $l2err = $l2err.Substring(0, 200) }
            $l2Line += "ERROR '$l2err'"
        }
        else {
            $l2RawDisplay = $l2.raw_full
            if (-not $l2RawDisplay) { $l2RawDisplay = $l2.raw_excerpt }
            $l2RawDisplay = ("$l2RawDisplay" -replace '\s+', ' ').Trim()
            $l2DisplayLimit = if ($LlmLog.raw_display_limit) { $LlmLog.raw_display_limit } else { 500 }
            if ($l2RawDisplay.Length -gt $l2DisplayLimit) { $l2RawDisplay = $l2RawDisplay.Substring(0, $l2DisplayLimit) + '…' }
            $l2Line += "'$l2RawDisplay'"
        }
        $l2Line += " ($($l2.latency_ms)ms, recovered=$($l2.recovered)$l2MockMark) -> verdict=$($l2.verdict)"
        if ($l2.indices) { $l2Line += " indices=[$($l2.indices -join ',')]" }
        $l2Line += "`n"
        $llm2RecvLine = $l2Line
    }

    # --- LLM-LOCAL: the pre-merge local decision + per-index tier
    $localReason = "$($LlmLog.local_reason)"
    if ($localReason.Length -gt 120) { $localReason = $localReason.Substring(0, 120) }
    $localLine = "  LLM-LOCAL     : decision=$($LlmLog.local_decision) ($localReason)"
    if ($LlmLog.tiers -and $LlmLog.tiers.Count -gt 0) {
        $tierParts = @()
        for ($i = 0; $i -lt $LlmLog.tiers.Count; $i++) {
            $tier = "$($LlmLog.tiers[$i])"
            if (-not $tier) { $tier = 'unlabeled' }
            $tierParts += "[$($i + 1)]=$tier"
        }
        $localLine += "; tiers: " + ($tierParts -join ' ')
    }
    $localLine += "`n"

    # --- LLM-RECONCILE: how the final decision was reached
    $reconLine = "  LLM-RECONCILE : "
    # design 5.4: pair prefixes / disagree rendering.
    $reconPrefix = ''
    if ($pairCalled -and $llm2Compare -in @('agree', 'llm1-down', 'llm2-down')) {
        if ($llm2Compare -eq 'agree') { $reconPrefix = 'llm2-agree | ' }
        elseif ($llm2Compare -eq 'llm1-down') { $reconPrefix = 'llm1-down | ' }
        else { $reconPrefix = 'llm2-down (proceeded on LLM1) | ' }
    }
    # enforce_disagree=false (2026-10-10): the pair disagreed but the early-return
    # did NOT fire, so compare='disagree' fell through to LLM1's merge (effect is
    # the merge's own: veto / agree / veto-suppressed-policy / ...). Mark it so the
    # log shows the disagreement was detected but not enforced. The enforced case
    # (effect='llm2-disagree') is handled by the branch below.
    if ($pairCalled -and $llm2Compare -eq 'disagree' -and "$($LlmLog.effect)" -ne 'llm2-disagree') {
        $reconPrefix = 'llm2-disagree (not enforced) | '
    }
    if ("$($LlmLog.effect)" -eq 'llm2-disagree') {
        # The pair disagreed: the ask came from the comparison, not from LLM1's
        # merge. Name both verdicts (spec: "log mentions LLM and LLM2 return
        # same result" - the disagree counterpart).
        $s1 = "$($LlmLog.verdict)"
        if ("$($LlmLog.verdict)" -eq 'modifying' -and $LlmLog.indices) { $s1 += " indices=[$($LlmLog.indices -join ',')]" }
        $s2 = "$($LlmLog.llm2.verdict)"
        if ("$($LlmLog.llm2.verdict)" -eq 'modifying' -and $LlmLog.llm2.indices) { $s2 += " indices=[$($LlmLog.llm2.indices -join ',')]" }
        $reconLine += "disagree LLM=$s1 vs LLM2=$s2 -> FINAL: $($Result.Decision)"
        $reconLine += "`n"
        return ($sentLine + $recvLine + $llm2RecvLine + $localLine + $reconLine)
    }
    $reconLine += $reconPrefix
    switch ($LlmLog.effect) {
        'veto' {
            $reconLine += "flagged=[$($LlmLog.flagged -join ',')]"
            if ($LlmLog.suppressed -and $LlmLog.suppressed.Count -gt 0) {
                # Option B: label the suppressed tier(s) accurately (strictness_gated /
                # trusted_program / mixed). All-gated still renders 'strictness_gated'.
                $suppLabel = Get-SuppressedTierLabel -LlmLog $LlmLog
                $reconLine += " suppressed=[$($LlmLog.suppressed -join ',')]($suppLabel)"
            }
            $vetoIdx = @($LlmLog.flagged | Where-Object { $LlmLog.suppressed -notcontains $_ })
            $reconLine += " veto=[$($vetoIdx -join ',')]"
            if ($LlmLog.path_guard_denied -and $LlmLog.path_guard_denied.Count -gt 0) {
                $reconLine += " path-guard denied: [$($LlmLog.path_guard_denied -join ',')]"
            }
            $reconLine += " -> FINAL: $($Result.Decision)"
        }
        'veto-suppressed-policy' {
            # Option B: name the tier(s) that were suppressed. All-gated still renders
            # 'strictness_gated policy'; a trusted_program suppression reads 'trusted_program policy'.
            $suppLabel = Get-SuppressedTierLabel -LlmLog $LlmLog
            if (-not $suppLabel) { $suppLabel = 'policy' }
            $reconLine += "flagged=[$($LlmLog.flagged -join ',')] all suppressed ($suppLabel policy) -> FINAL: $($Result.Decision)"
        }
        'agree' { $reconLine += "agree -> FINAL: $($Result.Decision)" }
        'disagree-kept-ask' { $reconLine += "LLM read-only but local ask (LLM never downgrades) -> FINAL: $($Result.Decision)" }
        'forced-ask' { $reconLine += "fail-closed ($($LlmLog.verdict)) -> FINAL: $($Result.Decision)" }
        default { $reconLine += "$($LlmLog.effect) -> FINAL: $($Result.Decision)" }
    }
    # design 5.4: R2 pre-skip with an armed pair self-documents the skip.
    if ($hasLlm2 -and $llm2Compare -eq 'skipped-trusted-editable') {
        $reconLine += " (pair skipped - comparison not applicable)"
    }
    $reconLine += "`n"

    return ($sentLine + $recvLine + $llm2RecvLine + $localLine + $reconLine)
}

function Write-LogEntry {
    <#
    .SYNOPSIS
        Writes a human-readable log entry to the daily log file (per-IDE split).
    .PARAMETER RawInput
        The raw PSCustomObject received from the IDE.
    .PARAMETER ClassifyResult
        The classification result object with Decision, Reason, IDE, SubResults, etc.
    .PARAMETER Elapsed
        The elapsed time from start to end of classification.
    .PARAMETER LogDir
        Path to the log directory.
    .PARAMETER IDE
        The IDE identifier ("ClaudeCode", "Copilot", or "Codex"). Used to split logs by IDE.
    #>
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [TimeSpan]$Elapsed,
        [string]$LogDir,
        [string]$IDE,
        [PSCustomObject]$LlmLog = $null
    )

    # Defensive: ensure log directory exists before writing
    if ($LogDir -and -not (Test-Path $LogDir)) {
        try {
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        }
        catch {
            [Console]::Error.WriteLine("Logger: Warning: Could not create log directory: $($_.Exception.Message)")
        }
    }

    # Edge case: null ClassifyResult → use safe defaults
    if ($null -eq $ClassifyResult) {
        $ClassifyResult = [PSCustomObject]@{
            Decision   = "error"
            Reason     = "null classify result"
            ExitCode   = 2
            IDE        = "Unknown"
            ToolName   = "unknown"
            Command    = ""
            SubResults = @()
            IsSkipped  = $false
            IsUnknown  = $false
        }
    }

    # --- Header line ---
    $timestamp = (Get-Date).ToString('[yyyy-MM-dd HH:mm:ss.fff]')
    $ide       = if ($ClassifyResult.IDE) { $ClassifyResult.IDE } else { 'Unknown' }
    $tool      = if ($RawInput -and $RawInput.tool_name) { $RawInput.tool_name } else { 'Unknown' }
    $decision  = if ($ClassifyResult.Decision) { $ClassifyResult.Decision } else { 'error' }
    $timeMs    = [math]::Round($Elapsed.TotalMilliseconds, 0)

    $marker = ''
    if ($ClassifyResult.IsSkipped) {
        $marker = ' [SKIP]'
    }
    elseif ($ClassifyResult.IsUnknown) {
        $marker = ' [UNKNOWN_TOOL]'
    }

    $header = "${timestamp} IDE:${ide} Tool:[${tool}] Decision:[${decision}] Time:[${timeMs}ms${marker}]`n"

    # --- Body ---
    $body = ''

    if ($ClassifyResult.IsSkipped -or $ClassifyResult.IsUnknown) {
        # SKIP or UNKNOWN_TOOL format: show truncated input JSON
        if ($null -eq $RawInput) {
            $body = "  Input: null input`n"
        }
        else {
            $inputJson = $RawInput | ConvertTo-Json -Compress -Depth 5
            if ($inputJson.Length -gt 360) {
                $inputJson = $inputJson.Substring(0, 360)
            }
            $body = "  Input: ${inputJson}`n"
        }
    }
    else {
        # Normal classified command
        $reasonLine = ''

        if ($decision -eq 'ask' -and $ClassifyResult.SubResults) {
            # Build detailed blocking reason with pipeline info
            $blockingParts = [System.Collections.Generic.List[string]]::new()
            $pipelineParts = [System.Collections.Generic.List[string]]::new()

            foreach ($sr in $ClassifyResult.SubResults) {
                if ($sr.Decision -eq 'ask') {
                    $blockingParts.Add("$($sr.Command) ($($sr.Reason))")
                }
                if ($sr.IsPipeline) {
                    $pipelineParts.Add($sr.Command)
                }
            }

            if ($blockingParts.Count -gt 0) {
                $reasonLine = "  Reason: $($blockingParts -join ', ')"
            }

            if ($pipelineParts.Count -gt 0) {
                $reasonLine += ". Pipeline: $($pipelineParts -join " $([char]0x2192) ")"
            }
            $reasonLine += "`n"
        }
        else {
            # Simple reason (allow decision or no sub-results)
            $reasonText = if ($ClassifyResult.Reason) { $ClassifyResult.Reason } else { '' }
            $reasonLine = "  Reason: ${reasonText}`n"
        }

        $commandText = if ($ClassifyResult.Command) { $ClassifyResult.Command } else { '' }
        # Truncate commands >10KB to 10240 chars in log (full command preserved in record)
        if ($commandText.Length -gt 10240) {
            $commandText = $commandText.Substring(0, 10240) + "..."
        }
        $body = "${reasonLine}  Command: ___ [${commandText}] ___`n"
    }

    # Optional second-opinion LLM reconciliation block (phase II)
    if ($LlmLog) {
        $body += (Format-LlmLogBlock -Result $ClassifyResult -LlmLog $LlmLog)
    }

    $logEntry = $header + $body + "`n"

    # --- Write to file (UTF-8 without BOM, LF line endings) ---
    # Daily file is named by LOCAL computer date so a late-evening run does
    # not roll over to "tomorrow's" file (user is in EST; body timestamps
    # are already local, so the filename should match them).
    $ideSuffix = if ($IDE -eq 'Copilot') { 'copilot' } elseif ($IDE -eq 'Codex') { 'codex' } elseif ($IDE -eq 'DSH') { 'dsh' } else { 'claude' }
    $logFileName = (Get-Date).ToString('yyyy-MM-dd') + '.' + $ideSuffix + '.log'
    $logFilePath = Join-Path $LogDir $logFileName

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($logFilePath, $logEntry, $utf8NoBom)
}
