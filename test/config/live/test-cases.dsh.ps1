# test-cases.dsh.ps1 — Unit tests for DeepSeek Harness (DSH) IDE detection, output mapping, and logging
#
# Tests three DSH-specific behaviors:
#   1. Detect-IDE — must identify DeepSeek Harness payloads via the `dsh` field
#      (the signature the dsh-plugin-pretoolhook bridge stamps on every call)
#   2. Format-Output — must keep allow/ask/deny as-is for DSH (DSH supports ask
#      natively through its approval seam; only Codex maps ask→deny)
#   3. Write-RecordEntry — must log DSH records to a <date>.dsh.records.jsonl
#      file (per-IDE split), not the claude fallback
#
# Usage: pwsh -NoProfile -File test/config/live/test-cases.dsh.ps1

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\..\..\src\HookAdapter.ps1"
. "$scriptDir\..\..\..\src\Logger.ps1"

$total = 0
$passed = 0
$failed = 0
$failures = [System.Collections.Generic.List[PSCustomObject]]::new()

function Assert-Equal($Name, $Expected, $Got) {
    $script:total++
    if ($Expected -eq $Got) {
        $script:passed++
        Write-Host "  PASS: $Name" -ForegroundColor Green
    } else {
        $script:failed++
        $f = [PSCustomObject]@{ Name = $Name; Expected = $Expected; Got = $Got }
        $script:failures.Add($f)
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        Write-Host "    Expected: $Expected" -ForegroundColor Red
        Write-Host "    Got:      $Got" -ForegroundColor Red
    }
}

# =============================================================================
# Part 1: Detect-IDE — DSH detection via the `dsh` field (decisive signal)
# =============================================================================
Write-Host ""
Write-Host "=== Detect-IDE: DeepSeek Harness Identification ===" -ForegroundColor Cyan

# 1a: DSH bash command payload (the exact shape the bridge sends)
$dshInput1 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_abc123"
    timestamp       = "2026-06-15T14:30:00.123Z"
    session_id      = "session-abc-123"
    tool_input      = [PSCustomObject]@{ command = "ls" }
    dsh             = [PSCustomObject]@{
        harness      = "DeepSeek Harness"
        call_id      = "call_abc123"
        root_call_id = "call_abc123"
    }
}
Assert-Equal "DSH detected via dsh.harness field" "DSH" (Detect-IDE -InputObject $dshInput1)

# 1b: DSH file-write payload (Write tool, path input)
$dshInput2 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Write"
    tool_use_id     = "call_def456"
    timestamp       = "2026-06-15T14:30:01.123Z"
    tool_input      = [PSCustomObject]@{ file_path = "C:\temp\notes.txt"; content = "x" }
    dsh             = [PSCustomObject]@{ harness = "DeepSeek Harness" }
}
Assert-Equal "DSH Write tool detected via dsh.harness" "DSH" (Detect-IDE -InputObject $dshInput2)

# 1c: DSH payload WITHOUT tool_use_id (bridge omits nothing, but be defensive)
$dshInput3 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    timestamp       = "2026-06-15T14:30:02.123Z"
    tool_input      = [PSCustomObject]@{ command = "git status" }
    dsh             = [PSCustomObject]@{ harness = "DeepSeek Harness" }
}
Assert-Equal "DSH detected without tool_use_id" "DSH" (Detect-IDE -InputObject $dshInput3)

# 1d: dsh field present but harness mismatch → NOT DSH (must fall through to
#     the normal signals, not hard-fail)
$dshInput4 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_ghi789"
    timestamp       = "2026-06-15T14:30:03.123Z"
    tool_input      = [PSCustomObject]@{ command = "ls" }
    dsh             = [PSCustomObject]@{ harness = "something-else" }
}
Assert-Equal "dsh.harness mismatch falls through to ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $dshInput4)

# 1e: Regression — Claude Code still detected (PascalCase + tool_use_id + ISO + .claude transcript)
$ccInput = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_cc123"
    timestamp       = "2026-06-15T14:30:00.123Z"
    transcript_path = "C:\Users\frank\.claude\projects\test\session.jsonl"
    tool_input      = [PSCustomObject]@{ command = "git status" }
}
Assert-Equal "Claude Code still detected via transcript_path" "ClaudeCode" (Detect-IDE -InputObject $ccInput)

# 1f: Regression — Copilot still detected (camelCase + epoch)
$copilotInput = [PSCustomObject]@{
    hook_event_name = "preToolUse"
    tool_name       = "run_in_terminal"
    timestamp       = "1715568000"
    tool_input      = [PSCustomObject]@{ command = "dir" }
}
Assert-Equal "Copilot still detected via camelCase + epoch" "Copilot" (Detect-IDE -InputObject $copilotInput)

# 1g: Regression — VS Code Copilot via __vscode- still detected
$vscodeInput = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "run_in_terminal"
    tool_use_id     = "toolu_bdrk_abc__vscode-xyz"
    timestamp       = "2026-06-15T14:30:00.123Z"
    tool_input      = [PSCustomObject]@{ command = "Get-Process" }
}
Assert-Equal "VS Code Copilot still detected via __vscode-" "Copilot" (Detect-IDE -InputObject $vscodeInput)

# 1h: Regression — Codex still detected via turn_id
$codexInput = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_cx123"
    timestamp       = "2026-06-15T14:30:00.123Z"
    turn_id         = "turn_xyz789"
    tool_input      = [PSCustomObject]@{ command = "ls" }
}
Assert-Equal "Codex still detected via turn_id" "Codex" (Detect-IDE -InputObject $codexInput)

# 1i: Edge case — null input defaults to ClaudeCode (the Detect-IDE warning is
#     expected; silence stderr so Run-AllTests' `2>&1 | Out-String` capture
#     does not treat it as a terminating error record)
$origErr = [Console]::Error
try {
    [Console]::SetError([System.IO.TextWriter]::Null)
    Assert-Equal "Null input defaults to ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $null)
}
finally {
    [Console]::SetError($origErr)
}

# =============================================================================
# Part 2: Format-Output — decision mapping for DSH
# =============================================================================
Write-Host ""
Write-Host "=== Format-Output: Decision Mapping (DSH) ===" -ForegroundColor Cyan

function New-ClassifyResult($Decision, $Reason) {
    return [PSCustomObject]@{ Decision = $Decision; Reason = $Reason }
}

# 2a: DSH — allow stays allow
$r2a = Format-Output -ClassifyResult (New-ClassifyResult "allow" "read-only") -IDE "DSH"
Assert-Equal "DSH: allow → allow" "allow" $r2a.hookSpecificOutput.permissionDecision

# 2b: DSH — ask stays ask (KEY behavior: DSH's approval seam prompts the user)
$r2b = Format-Output -ClassifyResult (New-ClassifyResult "ask" "rm -rf (high)") -IDE "DSH"
Assert-Equal "DSH: ask → ask" "ask" $r2b.hookSpecificOutput.permissionDecision
Assert-Equal "DSH: ask reason preserved" "rm -rf (high)" $r2b.hookSpecificOutput.permissionDecisionReason

# 2c: DSH — deny stays deny
$r2c = Format-Output -ClassifyResult (New-ClassifyResult "deny" "matched untrusted pattern") -IDE "DSH"
Assert-Equal "DSH: deny → deny" "deny" $r2c.hookSpecificOutput.permissionDecision
Assert-Equal "DSH: deny reason preserved" "matched untrusted pattern" $r2c.hookSpecificOutput.permissionDecisionReason

# 2d: DSH — hookEventName wrapper is the standard PreToolUse shape the bridge parses
Assert-Equal "DSH: hookEventName wrapper" "PreToolUse" $r2a.hookSpecificOutput.hookEventName

# =============================================================================
# Part 3: Logger — per-IDE record file suffix for DSH
# =============================================================================
Write-Host ""
Write-Host "=== Write-RecordEntry: DSH log file suffix ===" -ForegroundColor Cyan

$tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("prehook-dsh-test-" + [guid]::NewGuid().ToString("N"))
try {
    $dshResult = [PSCustomObject]@{
        Decision = "allow"; Reason = "read-only"; ExitCode = 0
        IDE = "DSH"; ToolName = "Bash"; Command = "ls"
        SubResults = @(); IsSkipped = $false; IsUnknown = $false
    }
    Write-RecordEntry -RawInput $dshInput1 -ClassifyResult $dshResult -LogDir $tempLogDir -IDE "DSH"

    $expectedSuffix = ".dsh.records.jsonl"
    $matching = @(Get-ChildItem -Path $tempLogDir -Filter "*.dsh.records.jsonl" -File -ErrorAction SilentlyContinue)
    Assert-Equal "DSH record written to .dsh.records.jsonl" 1 $matching.Count

    $claudeFiles = @(Get-ChildItem -Path $tempLogDir -Filter "*.claude.records.jsonl" -File -ErrorAction SilentlyContinue)
    Assert-Equal "DSH record NOT written to .claude fallback" 0 $claudeFiles.Count
}
finally {
    if (Test-Path $tempLogDir) { Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "DeepSeek Harness Unit Tests Complete"
Write-Host "========================================"
Write-Host "Total:    $total"
Write-Host "Passed:   $passed"
Write-Host "Failed:   $failed"
Write-Host ""

if ($failed -gt 0) {
    Write-Host "Failed Tests:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  $($f.Name)" -ForegroundColor Red
        Write-Host "    Expected: $($f.Expected)  Got: $($f.Got)" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}

Write-Host "All DeepSeek Harness tests passed." -ForegroundColor Green
exit 0
