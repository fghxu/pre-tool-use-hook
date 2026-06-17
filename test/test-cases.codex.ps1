# test-cases.codex.ps1 — Unit tests for Codex-specific IDE detection and output mapping
#
# Tests two Codex-specific functions in HookAdapter.ps1:
#   1. Detect-IDE — must identify Codex payloads via turn_id / model fields
#   2. Format-Output — must map ask→deny for Codex (Codex doesn't support "ask")
#
# Usage: pwsh -NoProfile -File test/test-cases.codex.ps1

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\src\HookAdapter.ps1"

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
# Part 1: Detect-IDE — Codex detection via turn_id / model fields
# =============================================================================
Write-Host ""
Write-Host "=== Detect-IDE: Codex Identification ===" -ForegroundColor Cyan

# 1a: Codex payload with turn_id (decisive signal 5)
$codexInput1 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_abc123"
    timestamp       = "2026-06-15T14:30:00.123Z"
    turn_id         = "turn_xyz789"
    tool_input      = [PSCustomObject]@{ command = "ls" }
}
Assert-Equal "Codex detected via turn_id field" "Codex" (Detect-IDE -InputObject $codexInput1)

# 1b: Codex payload with model field (decisive signal 6)
$codexInput2 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_def456"
    timestamp       = "2026-06-15T14:30:00.123Z"
    model           = "gpt-5.5"
    tool_input      = [PSCustomObject]@{ command = "ls" }
}
Assert-Equal "Codex detected via model field" "Codex" (Detect-IDE -InputObject $codexInput2)

# 1c: Codex payload with BOTH turn_id and model
$codexInput3 = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_ghi789"
    timestamp       = "2026-06-15T14:30:00.123Z"
    turn_id         = "turn_abc123"
    model           = "gpt-5.5"
    tool_input      = [PSCustomObject]@{ command = "ls" }
}
Assert-Equal "Codex detected via both turn_id and model" "Codex" (Detect-IDE -InputObject $codexInput3)

# 1d: Claude Code payload (PascalCase event, tool_use_id present, ISO timestamp, .claude transcript)
$ccInput = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "Bash"
    tool_use_id     = "call_cc123"
    timestamp       = "2026-06-15T14:30:00.123Z"
    transcript_path = "C:\Users\frank\.claude\projects\test\session.jsonl"
    tool_input      = [PSCustomObject]@{ command = "git status" }
}
Assert-Equal "Claude Code detected via transcript_path" "ClaudeCode" (Detect-IDE -InputObject $ccInput)

# 1e: Copilot payload (camelCase event, no tool_use_id, Unix epoch timestamp)
$copilotInput = [PSCustomObject]@{
    hook_event_name = "preToolUse"
    tool_name       = "run_in_terminal"
    timestamp       = "1715568000"
    tool_input      = [PSCustomObject]@{ command = "dir" }
}
Assert-Equal "Copilot detected via camelCase + epoch" "Copilot" (Detect-IDE -InputObject $copilotInput)

# 1f: VS Code Copilot via transcript_path (shares Claude Code protocol but has copilot-chat path)
$vscodeCopilotInput = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "run_in_terminal"
    tool_use_id     = "toolu_bdrk_abc__vscode-xyz"
    timestamp       = "2026-06-15T14:30:00.123Z"
    transcript_path = "C:\Users\frank\GitHub.copilot-chat\transcripts\session.jsonl"
    tool_input      = [PSCustomObject]@{ command = "ls" }
}
Assert-Equal "VS Code Copilot detected via transcript_path" "Copilot" (Detect-IDE -InputObject $vscodeCopilotInput)

# 1g: VS Code Copilot via __vscode- without transcript_path (bug fix — was logging to claude.log)
$vscodeCopilotNoTranscript = [PSCustomObject]@{
    hook_event_name = "PreToolUse"
    tool_name       = "run_in_terminal"
    tool_use_id     = "toolu_bdrk_abc__vscode-xyz"
    timestamp       = "2026-06-15T14:30:00.123Z"
    tool_input      = [PSCustomObject]@{ command = "Get-Process" }
}
Assert-Equal "VS Code Copilot detected via __vscode- without transcript_path" "Copilot" (Detect-IDE -InputObject $vscodeCopilotNoTranscript)

# 1h: Edge case — null input defaults to ClaudeCode
Assert-Equal "Null input defaults to ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $null)

# =============================================================================
# Part 2: Format-Output — decision mapping per IDE
# =============================================================================
Write-Host ""
Write-Host "=== Format-Output: Decision Mapping ===" -ForegroundColor Cyan

# Helper to build a minimal classify result
function New-ClassifyResult($Decision, $Reason) {
    return [PSCustomObject]@{ Decision = $Decision; Reason = $Reason }
}

# 2a: Codex — allow stays allow
$r2a = Format-Output -ClassifyResult (New-ClassifyResult "allow" "read-only") -IDE "Codex"
Assert-Equal "Codex: allow → allow" "allow" $r2a.hookSpecificOutput.permissionDecision

# 2b: Codex — ask maps to deny (KEY behavior)
$r2b = Format-Output -ClassifyResult (New-ClassifyResult "ask" "rm -rf (high)") -IDE "Codex"
Assert-Equal "Codex: ask → deny" "deny" $r2b.hookSpecificOutput.permissionDecision
Assert-Equal "Codex: deny reason preserved" "rm -rf (high)" $r2b.hookSpecificOutput.permissionDecisionReason

# 2c: ClaudeCode — allow stays allow
$r2c = Format-Output -ClassifyResult (New-ClassifyResult "allow" "read-only") -IDE "ClaudeCode"
Assert-Equal "ClaudeCode: allow → allow" "allow" $r2c.hookSpecificOutput.permissionDecision

# 2d: ClaudeCode — ask stays ask
$r2d = Format-Output -ClassifyResult (New-ClassifyResult "ask" "terraform apply (high)") -IDE "ClaudeCode"
Assert-Equal "ClaudeCode: ask → ask" "ask" $r2d.hookSpecificOutput.permissionDecision

# 2e: Copilot — allow stays allow
$r2e = Format-Output -ClassifyResult (New-ClassifyResult "allow" "read-only") -IDE "Copilot"
Assert-Equal "Copilot: allow → allow" "allow" $r2e.hookSpecificOutput.permissionDecision

# 2f: Copilot — ask stays ask
$r2f = Format-Output -ClassifyResult (New-ClassifyResult "ask" "kubectl delete (high)") -IDE "Copilot"
Assert-Equal "Copilot: ask → ask" "ask" $r2f.hookSpecificOutput.permissionDecision

# 2g: Codex — reason contains full pipeline context
$r2g = Format-Output -ClassifyResult (New-ClassifyResult "deny" "docker rm (high). Pipeline: docker ps -> docker rm -f") -IDE "Codex"
Assert-Equal "Codex: deny → deny" "deny" $r2g.hookSpecificOutput.permissionDecision
Assert-Equal "Codex: pipeline reason preserved" "docker rm (high). Pipeline: docker ps -> docker rm -f" $r2g.hookSpecificOutput.permissionDecisionReason

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "Codex Unit Tests Complete"
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

Write-Host "All Codex tests passed." -ForegroundColor Green
exit 0
