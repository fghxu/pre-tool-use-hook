# test-cases.ide-detect.ps1 - Unit tests for Detect-IDE payload fingerprinting
#
# WHY THIS SUITE EXISTS
#   VS Code 1.141.x stopped sending the two fields Detect-IDE relied on
#   (tool_use_id with "__vscode-", and transcript_path with "GitHub.copilot-chat").
#   Every VS Code payload then fell through to the majority-vote tie-break and was
#   labelled "ClaudeCode", so its decisions were appended to <date>.claude.log.
#
#   The payload census over c:\temp\logs\prehook (17104 records) shows the
#   discriminator that actually holds:
#     Claude Code CLI : "timestamp" NEVER present, tool_use_id ALWAYS present,
#                       transcript_path -> ...\.claude\projects\...
#     VS Code Copilot : "timestamp" ALWAYS present, tool_use_id absent (1.141+),
#                       transcript_path absent (1.141+) or -> GitHub.copilot-chat
#   i.e. presence of "timestamp" alongside ABSENCE of "tool_use_id" is unique to
#   Copilot. Codex (turn_id) and DSH (dsh) are caught earlier by decisive signals.
#
# Payloads are built by piping raw JSON through ConvertFrom-Json, exactly like
# Hook.ps1 step 3, so the .NET DateTime coercion of "timestamp" is exercised
# (a string-only regex test would hide that defect).
#
# Usage: pwsh -NoProfile -File test/config/live/test-cases.ide-detect.ps1

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
        $script:failures.Add([PSCustomObject]@{ Name = $Name; Expected = $Expected; Got = $Got })
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        Write-Host "    Expected: $Expected" -ForegroundColor Red
        Write-Host "    Got:      $Got" -ForegroundColor Red
    }
}

# Parse a raw JSON payload the same way Hook.ps1 does (ConvertFrom-Json coerces
# an ISO-8601 "timestamp" into a System.DateTime).
function New-Payload([string]$Json) {
    return $Json | ConvertFrom-Json
}

# =============================================================================
# Part 1: Detect-IDE - the live VS Code 1.141.x payload
# =============================================================================
Write-Host ""
Write-Host "=== Detect-IDE: VS Code Copilot payload fingerprint ===" -ForegroundColor Cyan

# 1a: the exact payload VS Code 1.141.2 sent on 2026-10-15 (captured in
#     2026-10-15.claude.records.jsonl). No tool_use_id, no transcript_path.
$vscodeLive = New-Payload @'
{"hook_event_name":"PreToolUse","session_id":"0f3e1360-5f83-4922-a2cc-bd72ac370b1b","timestamp":"2026-10-15T17:17:03.438Z","cwd":"c:\\git\\cc\\pretoolhook","tool_name":"Bash","tool_input":{"command":"remove-item c:\\a.test.txt","description":"Delete a test file"}}
'@
Assert-Equal "VS Code 1.141 payload (timestamp present, no tool_use_id) -> Copilot" "Copilot" (Detect-IDE -InputObject $vscodeLive)

# 1b: same shape through the Read/Grep tools VS Code uses today
$vscodeRead = New-Payload @'
{"hook_event_name":"PreToolUse","session_id":"f6d5f99a-9eb5-4a38-bbc7-b9a0fa791b71","timestamp":"2026-10-15T18:53:33.100Z","cwd":"c:\\git\\cc\\pretoolhook","tool_name":"Read","tool_input":{"file_path":"c:\\git\\cc\\pretoolhook\\PROGRESS.md"}}
'@
Assert-Equal "VS Code Read tool payload -> Copilot" "Copilot" (Detect-IDE -InputObject $vscodeRead)

# 1c: older VS Code Copilot shape (tool_use_id __vscode- + copilot-chat transcript)
$vscodeOld = New-Payload @'
{"hook_event_name":"PreToolUse","tool_name":"run_in_terminal","tool_input":{"command":"ls"},"tool_use_id":"toolu_bdrk_abc__vscode-1111-2222","timestamp":"2026-06-15T14:30:00.123Z","transcript_path":"c:\\Users\\fghxu\\AppData\\Roaming\\Code\\User\\workspaceStorage\\ce8aeb6b\\GitHub.copilot-chat\\transcripts\\4c5a4d02.jsonl"}
'@
Assert-Equal "VS Code legacy payload (__vscode- tool_use_id) -> Copilot" "Copilot" (Detect-IDE -InputObject $vscodeOld)

# 1d: legacy camelCase preToolUse + epoch timestamp (pre-Claude-protocol Copilot)
$vscodeCamel = New-Payload @'
{"hook_event_name":"preToolUse","tool_name":"run_in_terminal","tool_input":{"command":"ls"},"timestamp":"1715568000"}
'@
Assert-Equal "VS Code legacy camelCase payload -> Copilot" "Copilot" (Detect-IDE -InputObject $vscodeCamel)

# =============================================================================
# Part 2: Detect-IDE - Claude Code CLI must NOT be mistaken for Copilot
# =============================================================================
Write-Host ""
Write-Host "=== Detect-IDE: Claude Code CLI payload fingerprint ===" -ForegroundColor Cyan

# 2a: the exact payload Claude Code CLI sends today (prompt_id / permission_mode /
#     effort, .claude transcript, call_* tool_use_id, NO timestamp)
$ccLive = New-Payload @'
{"session_id":"c5efba87-a693-433e-91ee-2eed8b239f2e","transcript_path":"C:\\Users\\fghxu\\.claude\\projects\\C--git-cc-pretoolhook\\c5efba87-a693-433e-91ee-2eed8b239f2e.jsonl","cwd":"C:\\git\\cc\\pretoolhook","prompt_id":"fee852fe-8d16-47f1-bf0f-3a2e07005800","permission_mode":"acceptEdits","effort":{"level":"high"},"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"C:\\git\\cc\\pretoolhook\\PROGRESS.md"},"tool_use_id":"call_00_Zza1jm90YVQ4xd5bdYDS5522"}
'@
Assert-Equal "Claude Code CLI payload (no timestamp, tool_use_id present) -> ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $ccLive)

# 2b: Claude Code payload that DOES carry an ISO timestamp plus a .claude
#     transcript_path (the 1269-record historical shape). transcript_path must
#     stay decisive so the new timestamp rule cannot swallow these.
$ccWithTs = New-Payload @'
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"toolu_01ABC","timestamp":"2026-06-15T14:30:00.123Z","transcript_path":"/home/user/.claude/projects/test/session.jsonl"}
'@
Assert-Equal "Claude Code payload with timestamp + .claude transcript -> ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $ccWithTs)

# 2c: Claude Code payload with no transcript_path but tool_use_id present
$ccNoTp = New-Payload @'
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"call_test001"}
'@
Assert-Equal "Claude Code payload (tool_use_id, no timestamp) -> ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $ccNoTp)

# =============================================================================
# Part 3: Detect-IDE - Codex / DSH decisive signals still win
# =============================================================================
Write-Host ""
Write-Host "=== Detect-IDE: Codex and DSH still detected ===" -ForegroundColor Cyan

$codex = New-Payload @'
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"call_cx001","timestamp":"2026-06-15T14:30:00.123Z","turn_id":"turn_01"}
'@
Assert-Equal "Codex payload (turn_id) -> Codex" "Codex" (Detect-IDE -InputObject $codex)

$dsh = New-Payload @'
{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"call_abc123","timestamp":"2026-06-15T14:30:00.123Z","dsh":{"harness":"DeepSeek Harness","call_id":"call_abc123"}}
'@
Assert-Equal "DSH payload (dsh.harness) -> DSH" "DSH" (Detect-IDE -InputObject $dsh)

# 3c: null input still defaults to ClaudeCode (warning goes to stderr)
$origErr = [Console]::Error
try {
    [Console]::SetError([System.IO.TextWriter]::Null)
    Assert-Equal "Null input defaults to ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $null)
}
finally {
    [Console]::SetError($origErr)
}

# =============================================================================
# Part 4: Logger - VS Code payload lands in .copilot.*, not .claude.*
# =============================================================================
Write-Host ""
Write-Host "=== Logger: VS Code record/log file suffix ===" -ForegroundColor Cyan

$ide = Detect-IDE -InputObject $vscodeLive
$classify = [PSCustomObject]@{
    Decision = "ask"; Reason = "remove-item (high)"; ExitCode = 0
    IDE = $ide; ToolName = "Bash"; Command = "remove-item c:\a.test.txt"
    SubResults = @(); IsSkipped = $false; IsUnknown = $false
}

$tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("prehook-ide-test-" + [guid]::NewGuid().ToString("N"))
try {
    Write-RecordEntry -RawInput $vscodeLive -ClassifyResult $classify -LogDir $tempLogDir -IDE $ide
    Write-LogEntry -RawInput $vscodeLive -ClassifyResult $classify -Elapsed ([TimeSpan]::FromMilliseconds(120)) -LogDir $tempLogDir -IDE $ide

    $copilotRecords = @(Get-ChildItem -Path $tempLogDir -Filter "*.copilot.records.jsonl" -File -ErrorAction SilentlyContinue)
    Assert-Equal "VS Code record written to .copilot.records.jsonl" 1 $copilotRecords.Count

    $copilotLogs = @(Get-ChildItem -Path $tempLogDir -Filter "*.copilot.log" -File -ErrorAction SilentlyContinue)
    Assert-Equal "VS Code log written to .copilot.log" 1 $copilotLogs.Count

    $claudeRecords = @(Get-ChildItem -Path $tempLogDir -Filter "*.claude.records.jsonl" -File -ErrorAction SilentlyContinue)
    Assert-Equal "VS Code record NOT written to .claude fallback" 0 $claudeRecords.Count

    $claudeLogs = @(Get-ChildItem -Path $tempLogDir -Filter "*.claude.log" -File -ErrorAction SilentlyContinue)
    Assert-Equal "VS Code log NOT written to .claude fallback" 0 $claudeLogs.Count

    # The human-readable header must carry the detected IDE label
    if ($copilotLogs.Count -eq 1) {
        $headerLine = (Get-Content $copilotLogs[0].FullName -TotalCount 1)
        $script:total++
        if ($headerLine -match 'IDE:Copilot') {
            $script:passed++
            Write-Host "  PASS: .copilot.log header says IDE:Copilot" -ForegroundColor Green
        } else {
            $script:failed++
            $script:failures.Add([PSCustomObject]@{ Name = ".copilot.log header says IDE:Copilot"; Expected = "IDE:Copilot"; Got = $headerLine })
            Write-Host "  FAIL: .copilot.log header says IDE:Copilot" -ForegroundColor Red
            Write-Host "    Got: $headerLine" -ForegroundColor Red
        }
    }
}
finally {
    if (Test-Path $tempLogDir) { Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "IDE Detection Unit Tests Complete"
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

Write-Host "All IDE detection tests passed." -ForegroundColor Green
exit 0
