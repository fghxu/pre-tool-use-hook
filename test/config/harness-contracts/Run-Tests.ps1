# Run-Tests.ps1 - RED suite for the quad-contract harness migration (2026-11-14)
#
# WHY THIS SUITE EXISTS
#   VS Code 1.146 split chat into four harnesses (Local deprecated Feb 2027,
#   Copilot/Claude/Codex). The Copilot harness sends camelCase payloads and
#   reads TOP-LEVEL permissionDecision fields, ignoring the nested
#   hookSpecificOutput envelope we emit today. Design:
#   docs/Updates/Update-2026-11-14-copilot-harness-migration.md (+ ADR 0001).
#
#   This suite is committed in the RED state on purpose (project TDD):
#   the failing cases below define the target behavior for slices F1-F4.
#   GREEN = all cases pass after implementation.
#
#   Case map (RED cases fail today for the RIGHT reasons; PIN cases pass
#   today and must keep passing):
#     F1 detection : HC-01a PIN (accidental, see body) + HC-01b RED,
#                    HC-02 RED, HC-03..HC-06 PIN
#     F1 normalizer: HC-07..HC-09 RED (functions do not exist yet)
#     F1 gate      : HC-10 RED (Add-WorkspaceRoots Copilot-only gate), HC-11 PIN
#     F2 output    : HC-12 RED, HC-13 PIN, HC-14 RED, HC-15a PIN + HC-15b RED
#     F2 policy    : HC-16 RED (unknown tool: exit 2 -> ask/exit 0)
#     F3 deadline  : HC-17..HC-19 RED (key unvalidated / uncompiled today)
#     F4 fullpipe  : HC-20 RED (camel payload), HC-21 RED (.local suffix),
#                    HC-22..HC-23 PIN
#
# Usage: pwsh -NoProfile -File test/config/harness-contracts/Run-Tests.ps1
# Exit code: 0 when every case passes, 1 otherwise.

$ErrorActionPreference = "Stop"

$suiteDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path (Split-Path (Split-Path $suiteDir -Parent) -Parent) -Parent

# Mirror Hook.ps1's dot-source order so unit targets see the real scope.
. (Join-Path $repoRoot 'src\HookAdapter.ps1')
. (Join-Path $repoRoot 'src\ConfigLoader.ps1')
. (Join-Path $repoRoot 'src\Logger.ps1')
. (Join-Path $repoRoot 'src\Classifier.ps1')
. (Join-Path $repoRoot 'src\LlmReview.ps1')

$total = 0
$passed = 0
$failed = 0
$failures = [System.Collections.Generic.List[PSCustomObject]]::new()

function Assert-Equal($Name, $Expected, $Got) {
    $script:total++
    if ("$Expected" -eq "$Got") {
        $script:passed++
        Write-Host "  PASS: $Name" -ForegroundColor Green
    }
    else {
        $script:failed++
        $script:failures.Add([PSCustomObject]@{ Name = $Name; Expected = "$Expected"; Got = "$Got" })
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        Write-Host "    Expected: $Expected" -ForegroundColor Red
        Write-Host "    Got:      $Got" -ForegroundColor Red
    }
}

function Assert-True($Name, $Condition) {
    Assert-Equal $Name $true ([bool]$Condition)
}

# Runs a case body; a MISSING function/property must FAIL the case, not crash
# the suite (that is the RED signal for not-yet-implemented slices).
function Invoke-Case($Name, $ScriptBlock) {
    try {
        & $ScriptBlock
    }
    catch {
        Assert-Equal $Name "<case body succeeded>" "THREW: $($_.Exception.Message)"
    }
}

function New-Payload([string]$Json) { $Json | ConvertFrom-Json }

# =============================================================================
# Part 1 (F1): Detect-IDE - the four harness payload shapes
# =============================================================================
Write-Host ""
Write-Host "=== F1: Detect-IDE harness fingerprints ===" -ForegroundColor Cyan

# HC-01a PIN (accidental): camel payload WITHOUT tool_use_id is labelled
# Copilot today only because Signal 2's else-branch votes Copilot on absence.
# HC-01b RED (the real rule): camel fields WITH tool_use_id + ISO timestamp
# (the PascalCase-alias shape the Copilot CLI sends) currently vote
# ClaudeCode - the exact 2026-11-13 masquerade. A decisive camelCase signal
# (toolName present) must beat the snake_case vote.
Invoke-Case "HC-01 camelCase toolName/toolArgs payload -> Copilot" {
    $p = New-Payload '{"toolName":"runInTerminal","toolArgs":{"command":"Get-Date"},"sessionId":"7f3a2c"}'
    Assert-Equal "HC-01a camel payload (no tool_use_id) -> Copilot" "Copilot" (Detect-IDE -InputObject $p)
    $q = New-Payload '{"toolName":"runInTerminal","toolArgs":{"command":"Get-Date"},"sessionId":"7f3a2c","tool_use_id":"toolu_01","timestamp":"2026-11-14T10:00:00.000Z"}'
    Assert-Equal "HC-01b camel payload WITH tool_use_id -> Copilot (decisive)" "Copilot" (Detect-IDE -InputObject $q)
}

# HC-02 RED: VS Code-origin snake_case payload must now be labelled Local.
Invoke-Case "HC-02 __vscode- tool_use_id payload -> Local" {
    $p = New-Payload '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"toolu_bdrk_abc__vscode-1111-2222","timestamp":"2026-11-14T10:00:00.000Z","transcript_path":"c:\\x\\GitHub.copilot-chat\\transcripts\\t.jsonl"}'
    Assert-Equal "HC-02 __vscode- payload -> Local" "Local" (Detect-IDE -InputObject $p)
}

# HC-03 PIN: Codex fingerprint (turn_id) already detected.
Invoke-Case "HC-03 turn_id payload -> Codex (pin)" {
    $p = New-Payload '{"session_id":"s1","cwd":"c:\\git","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"t1","turn_id":"turn_7f","model":"gpt-5-codex"}'
    Assert-Equal "HC-03 turn_id payload -> Codex" "Codex" (Detect-IDE -InputObject $p)
}

# HC-04 PIN: DSH bridge marker already detected.
Invoke-Case "HC-04 dsh marker payload -> DSH (pin)" {
    $p = New-Payload '{"tool_name":"Bash","tool_input":{"command":"Get-Date"},"dsh":{"harness":"DeepSeek Harness"}}'
    Assert-Equal "HC-04 dsh marker payload -> DSH" "DSH" (Detect-IDE -InputObject $p)
}

# HC-05 PIN: plain snake_case Claude payload stays ClaudeCode.
Invoke-Case "HC-05 plain snake_case payload -> ClaudeCode (pin)" {
    $p = New-Payload '{"session_id":"s1","transcript_path":"c:\\Users\\u\\.claude\\projects\\p.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"toolu_01"}'
    Assert-Equal "HC-05 plain snake payload -> ClaudeCode" "ClaudeCode" (Detect-IDE -InputObject $p)
}

# HC-06 PIN: 1.141-era VS Code shape (timestamp, no tool_use_id) -> Copilot.
Invoke-Case "HC-06 timestamp-without-tool_use_id -> Copilot (pin)" {
    $p = New-Payload '{"hook_event_name":"PreToolUse","session_id":"s1","timestamp":"2026-10-15T17:17:03.438Z","cwd":"c:\\git","tool_name":"Bash","tool_input":{"command":"Get-Date"}}'
    Assert-Equal "HC-06 1.141-era payload -> Copilot" "Copilot" (Detect-IDE -InputObject $p)
}

# =============================================================================
# Part 2 (F1): boundary normalizer (camelCase -> internal snake_case)
# =============================================================================
Write-Host ""
Write-Host "=== F1: ConvertTo-CanonicalPayload + lookup kebabing ===" -ForegroundColor Cyan

Invoke-Case "HC-07 camel payload normalized to snake_case fields" {
    $p = New-Payload '{"toolName":"runInTerminal","toolArgs":{"command":"Get-Date"},"sessionId":"7f3a2c"}'
    $c = ConvertTo-CanonicalPayload -InputObject $p
    Assert-True  "HC-07a canonical has tool_name"    ($null -ne $c.tool_name)
    Assert-Equal "HC-07b tool_name keeps raw value"  "runInTerminal" $c.tool_name
    Assert-Equal "HC-07c tool_input.command mapped"  "Get-Date" $c.tool_input.command
    Assert-Equal "HC-07d session_id mapped"          "7f3a2c" $c.session_id
    Assert-True  "HC-07e camel toolName removed"     (-not ($c.PSObject.Properties.Name -contains 'toolName'))
}

Invoke-Case "HC-08 snake_case payload passes through unchanged" {
    $p = New-Payload '{"tool_name":"Bash","tool_input":{"command":"Get-Date"},"session_id":"s1","tool_use_id":"toolu_01"}'
    $c = ConvertTo-CanonicalPayload -InputObject $p
    Assert-Equal "HC-08a tool_name unchanged"  "Bash" $c.tool_name
    Assert-Equal "HC-08b command unchanged"    "Get-Date" $c.tool_input.command
    Assert-Equal "HC-08c session_id unchanged" "s1" $c.session_id
}

Invoke-Case "HC-09 tool-name lookup kebabing" {
    Assert-Equal "HC-09a runInTerminal -> run_in_terminal" "run_in_terminal" (ConvertTo-ToolNameLookupKey 'runInTerminal')
    Assert-Equal "HC-09b Bash -> bash"                      "bash"            (ConvertTo-ToolNameLookupKey 'Bash')
    Assert-Equal "HC-09c mcp name unchanged"                "mcp__brave-search__brave_web_search" (ConvertTo-ToolNameLookupKey 'mcp__brave-search__brave_web_search')
    Assert-Equal "HC-09d ReadPowershell -> read_powershell" "read_powershell" (ConvertTo-ToolNameLookupKey 'ReadPowershell')
}

# =============================================================================
# Part 3 (F1, amendment 7.3.1): workspace_roots gate widened to Copilot|Local
# =============================================================================
Write-Host ""
Write-Host "=== F1: Add-WorkspaceRoots IDE gate (Copilot|Local) ===" -ForegroundColor Cyan

Invoke-Case "HC-10 Add-WorkspaceRoots adopts roots for IDE=Local" {
    $cfg = Load-Config -Path (Join-Path $suiteDir 'config.json')
    $null = Add-WorkspaceRoots -Config $cfg -IDE 'Local' -ExtraRoots @('d:\other-repo')
    Assert-True "HC-10a _workspaceRootsNorm non-empty for Local" (@($cfg._workspaceRootsNorm).Count -gt 0)
    Assert-True "HC-10b adopted root normalized with trailing sep" (@($cfg._workspaceRootsNorm) -contains 'd:\other-repo\')
}

Invoke-Case "HC-11 Add-WorkspaceRoots still ignores DSH (pin)" {
    $cfg = Load-Config -Path (Join-Path $suiteDir 'config.json')
    $null = Add-WorkspaceRoots -Config $cfg -IDE 'DSH' -ExtraRoots @('d:\other-repo')
    Assert-True "HC-11 no roots adopted for DSH" (@($cfg._workspaceRootsNorm).Count -eq 0)
}

# =============================================================================
# Part 4 (F2): dual output envelope + Codex vocabulary
# =============================================================================
Write-Host ""
Write-Host "=== F2: Format-Output dual envelope ===" -ForegroundColor Cyan

function New-Result([string]$Decision, [string]$Reason) {
    [PSCustomObject]@{ Decision = $Decision; Reason = $Reason }
}

Invoke-Case "HC-12 ask/Copilot carries TOP-LEVEL permissionDecision" {
    $o = Format-Output -ClassifyResult (New-Result 'ask' 'modifying (high)') -IDE 'Copilot'
    Assert-Equal "HC-12 top-level permissionDecision" "ask" $o.permissionDecision
    Assert-True  "HC-12b top-level reason present"    (-not [string]::IsNullOrWhiteSpace($o.permissionDecisionReason))
}

Invoke-Case "HC-13 ask/Copilot keeps nested envelope (pin)" {
    $o = Format-Output -ClassifyResult (New-Result 'ask' 'modifying (high)') -IDE 'Copilot'
    Assert-Equal "HC-13 nested permissionDecision" "ask" $o.hookSpecificOutput.permissionDecision
}

Invoke-Case "HC-14 ask/Codex -> deny + systemMessage" {
    $o = Format-Output -ClassifyResult (New-Result 'ask' 'delete of non-editable path (high risk)') -IDE 'Codex'
    Assert-Equal "HC-14a top-level deny"                 "deny" $o.permissionDecision
    Assert-True  "HC-14b reason marks the ask->deny map" ($o.permissionDecisionReason -like 'ask unsupported on Codex*')
    Assert-True  "HC-14c systemMessage present"          ($o.systemMessage -like '*Codex has no ask*')
    Assert-Equal "HC-14d nested deny too"                "deny" $o.hookSpecificOutput.permissionDecision
}

Invoke-Case "HC-15 allow/ClaudeCode both envelopes" {
    $o = Format-Output -ClassifyResult (New-Result 'allow' 'read-only') -IDE 'ClaudeCode'
    Assert-Equal "HC-15a nested allow (pin)"  "allow" $o.hookSpecificOutput.permissionDecision
    Assert-Equal "HC-15b top-level allow"     "allow" $o.permissionDecision
}

# =============================================================================
# Part 5 (F2 policy): unknown tool asks instead of hard-denying
# =============================================================================
Write-Host ""
Write-Host "=== F2: unknown tool -> ask with exit 0 ===" -ForegroundColor Cyan

Invoke-Case "HC-16 unknown tool yields Decision=ask ExitCode=0" {
    $cfg = Load-Config -Path (Join-Path $suiteDir 'config.json')
    $p = New-Payload '{"session_id":"s1","cwd":"c:\\git","hook_event_name":"PreToolUse","tool_name":"read_powershell","tool_input":{"delay":10},"tool_use_id":"toolu_01"}'
    $r = Invoke-Classify -RawInput $p -IDE 'ClaudeCode' -Config $cfg
    Assert-Equal "HC-16a unknown tool Decision" "ask" $r.Decision
    Assert-Equal "HC-16b unknown tool ExitCode" "0"   "$($r.ExitCode)"
}

# =============================================================================
# Part 6 (F3): answer_deadline_ms config surface
# =============================================================================
Write-Host ""
Write-Host "=== F3: answer_deadline_ms validation + compile ===" -ForegroundColor Cyan

Invoke-Case "HC-17 good answer_deadline_ms loads and compiles" {
    $cfg = Load-Config -Path (Join-Path $suiteDir 'config.deadline.json')
    Assert-True "HC-17a compiled _answerDeadlines exists" ($null -ne ($cfg.PSObject.Properties['_answerDeadlines']))
    Assert-True "HC-17b Copilot deadline = 28000"         ("$($cfg._answerDeadlines.Copilot)" -eq '28000')
}

Invoke-Case "HC-18 non-int deadline value throws at load" {
    $threw = $false
    try { $null = Load-Config -Path (Join-Path $suiteDir 'config.deadline-bad-type.json') } catch { $threw = $true }
    Assert-True "HC-18 string deadline rejected" $threw
}

Invoke-Case "HC-19 Copilot deadline >= 30000 throws at load" {
    $threw = $false
    try { $null = Load-Config -Path (Join-Path $suiteDir 'config.deadline-bad-range.json') } catch { $threw = $true }
    Assert-True "HC-19 over-30s deadline rejected" $threw
}

# =============================================================================
# Part 7 (F4): fullpipe - spawn the real Hook.ps1 per payload shape
# =============================================================================
Write-Host ""
Write-Host "=== F4: fullpipe spawns (real src/Hook.ps1) ===" -ForegroundColor Cyan

$logDir = 'c:\temp\pretoolhook-harness-contracts-testlogs'
if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force }
$null = New-Item -ItemType Directory -Path $logDir -Force
$hookPath = Join-Path $repoRoot 'src\Hook.ps1'
$todayLog = (Get-Date).ToString('yyyy-MM-dd')

function Invoke-HookSpawn([string]$Json) {
    $prev = $env:PRETOOLHOOK_CONFIG_PATH
    $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $suiteDir 'config.json'
    try {
        $out = $Json | & pwsh -NoProfile -NonInteractive -File $hookPath 2>$null
        return [PSCustomObject]@{ Code = $LASTEXITCODE; Stdout = ($out -join "`n") }
    }
    finally { $env:PRETOOLHOOK_CONFIG_PATH = $prev }
}

Invoke-Case "HC-20 camelCase payload through the real hook" {
    $r = Invoke-HookSpawn '{"toolName":"runInTerminal","toolArgs":{"command":"Get-Date"},"sessionId":"7f3a2c","cwd":"c:\\git"}'
    Assert-Equal "HC-20a exit code 0" "0" "$($r.Code)"
    $j = $null; try { $j = $r.Stdout | ConvertFrom-Json } catch { }
    Assert-True "HC-20b stdout is JSON" ($null -ne $j)
    Assert-True "HC-20c decision present" ($null -ne $j.permissionDecision)
    Assert-True "HC-20d wrote .copilot.log" (Test-Path (Join-Path $logDir "$todayLog.copilot.log"))
}

Invoke-Case "HC-21 Local payload writes .local.log" {
    $r = Invoke-HookSpawn '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"toolu_bdrk_abc__vscode-1111-2222","timestamp":"2026-11-14T10:00:00.000Z","cwd":"c:\\git"}'
    Assert-Equal "HC-21a exit code 0" "0" "$($r.Code)"
    Assert-True "HC-21b wrote .local.log"    (Test-Path (Join-Path $logDir "$todayLog.local.log"))
    Assert-True "HC-21c NOT .copilot.log"    (-not (Test-Path (Join-Path $logDir "$todayLog.copilot.log")))
}

Invoke-Case "HC-22 Claude payload (pin)" {
    $r = Invoke-HookSpawn '{"session_id":"s1","transcript_path":"c:\\Users\\u\\.claude\\projects\\p.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"toolu_01","cwd":"c:\\git"}'
    Assert-Equal "HC-22a exit code 0" "0" "$($r.Code)"
    Assert-True "HC-22b wrote .claude.log" (Test-Path (Join-Path $logDir "$todayLog.claude.log"))
}

Invoke-Case "HC-23 Codex payload (pin)" {
    $r = Invoke-HookSpawn '{"session_id":"s1","cwd":"c:\\git","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-Date"},"tool_use_id":"t1","turn_id":"turn_7f","model":"gpt-5-codex"}'
    Assert-Equal "HC-23a exit code 0" "0" "$($r.Code)"
    Assert-True "HC-23b wrote .codex.log" (Test-Path (Join-Path $logDir "$todayLog.codex.log"))
}

# =============================================================================
# Summary (machine-parseable)
# =============================================================================
Write-Host ""
Write-Host "SUMMARY: total=$total passed=$passed failed=$failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
if ($failed -gt 0) {
    Write-Host "RED expected until F1-F4 land (see docs/Updates/Update-2026-11-14-copilot-harness-migration.md)." -ForegroundColor Yellow
}
exit $(if ($failed -gt 0) { 1 } else { 0 })
