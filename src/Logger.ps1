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
        The IDE identifier ("ClaudeCode" or "Copilot"). Used to split logs by IDE.
    #>
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [string]$LogDir,
        [string]$IDE
    )

    $utcNow = (Get-Date).ToUniversalTime()
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

    $jsonLine = $record | ConvertTo-Json -Compress -Depth 10

    $ideSuffix = if ($IDE -eq 'Copilot') { 'copilot' } else { 'claude' }
    $fileName = $utcNow.ToString('yyyy-MM-dd') + '.' + $ideSuffix + '.records.jsonl'
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
        The IDE identifier ("ClaudeCode" or "Copilot"). Used to split logs by IDE.
    #>
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [TimeSpan]$Elapsed,
        [string]$LogDir,
        [string]$IDE
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
            if ($inputJson.Length -gt 50) {
                $inputJson = $inputJson.Substring(0, 50)
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
        # Truncate commands >10KB to 500 chars in log (full command preserved in record)
        if ($commandText.Length -gt 10240) {
            $commandText = $commandText.Substring(0, 500) + "..."
        }
        $body = "${reasonLine}  Command: [[[${commandText}]]]`n"
    }

    $logEntry = $header + $body + "`n"

    # --- Write to file (UTF-8 without BOM, LF line endings) ---
    $ideSuffix = if ($IDE -eq 'Copilot') { 'copilot' } else { 'claude' }
    $logFileName = (Get-Date -AsUTC).ToString('yyyy-MM-dd') + '.' + $ideSuffix + '.log'
    $logFilePath = Join-Path $LogDir $logFileName

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($logFilePath, $logEntry, $utf8NoBom)
}
