# =============================================================================
# Run-Tests.ps1 - workspace_roots fixture runner (VS Code multi-root CWD)
# =============================================================================
#
# WHAT THIS FILE IS
#   Dedicated suite for the workspace_roots feature. Small isolated fixture
#   configs, runs in seconds, NO network, NO GUI, and NO dependence on the
#   real %APPDATA%\Code\User\workspaceStorage tree (a fake storage root is
#   built under %TEMP% and injected through -StorageRoots).
#
# FEATURE UNDER TEST
#   Folders of the CURRENT VS Code multi-root workspace must be treated
#   EXACTLY like the CWD by the path policy, so that e.g.
#       git -C 'C:\git\cc\kimi' commit -m "test"
#   is not vetoed by the Stage-2 path guard when C:\git\cc\kimi is simply the
#   second folder opened in the same window. Rules:
#     * OPT-IN via config.workspace_roots.enabled (default false)
#     * VS Code (Copilot) ONLY - Claude Code / Codex / DSH never use it
#     * explicit paths[] union discovery (discover: ["vscode"])
#     * discovery must anchor-match the current CWD, so an unrelated
#       workspace's folders are never adopted
#     * fail-closed: no roots resolved => behavior identical to today (ask)
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/workspace-roots/Run-Tests.ps1
#   Exit code 0 = all green. Exit code 1 = at least one check failed.
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
# =============================================================================

param()

$ErrorActionPreference = "Stop"

$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"

. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "LlmReview.ps1")

$script:total = 0; $script:passed = 0; $script:failed = 0; $script:failures = @()

function Record-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    $script:total++
    if ($Ok) {
        $script:passed++
        Write-Host "  PASS $Name" -ForegroundColor Green
    }
    else {
        $script:failed++
        $script:failures += [PSCustomObject]@{ Name = $Name; Detail = $Detail }
        Write-Host "  FAIL $Name" -ForegroundColor Red
        Write-Host "       $Detail"
    }
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return [bool](Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty -ErrorAction SilentlyContinue)
}

function Get-MemberValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $m = Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty -ErrorAction SilentlyContinue
    if (-not $m) { return $null }
    # -NoEnumerate keeps empty arrays empty instead of collapsing them to $null.
    return (Write-Output -NoEnumerate $Object.$Name)
}

function Format-Roots {
    param($Roots)
    if ($null -eq $Roots) { return "<null>" }
    return (@($Roots) -join " | ")
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# Build the URI shape VS Code actually writes into workspace.json / a
# .code-workspace file: "file:///c%3A/git/cc/kimi" (colon percent-encoded).
function ConvertTo-VsCodeUri {
    param([string]$Path)
    $abs = ($Path -replace '\\', '/')
    if ($abs -match '^[A-Za-z]:') {
        $uri = 'file:///' + $abs
        $uri = $uri -replace '^file:///([A-Za-z]):', 'file:///$1%3A'
        return $uri
    }
    return 'file:///' + $abs.TrimStart('/')
}

function Write-StorageEntry {
    param([string]$Dir, $JsonObject, [double]$AgeHours = 0)
    $null = New-Item -ItemType Directory -Path $Dir -Force
    $file = Join-Path $Dir 'workspace.json'
    $text = if ($null -eq $JsonObject) { '{}' } else { ($JsonObject | ConvertTo-Json -Depth 6 -Compress) }
    [System.IO.File]::WriteAllText($file, $text)
    if ($AgeHours -ne 0) {
        [System.IO.File]::SetLastWriteTimeUtc($file, [datetime]::UtcNow.AddHours(-$AgeHours))
    }
    return $file
}

# A fake VS Code workspaceStorage tree:
#   multi-unrelated  (NEWEST entry)  -> a different workspace: must be SKIPPED
#   multi-team                       -> {projA, projB}  (the workspace we are in)
#   single-solo                      -> {soloFolder}    (single-folder window)
#   empty-entry                      -> {}              (corrupt/empty: ignored)
function Initialize-FakeStorage {
    param([string]$Root)

    $store  = Join-Path $Root 'workspaceStorage'
    $wsDir  = Join-Path $Root 'ws'
    $projA  = Join-Path $Root 'projA'
    $projB  = Join-Path $Root 'projB'
    $solo   = Join-Path $Root 'soloFolder'
    $otherA = Join-Path $Root 'unrelatedA'
    $otherB = Join-Path $Root 'unrelatedB'
    foreach ($d in @($store, $wsDir, $projA, $projB, $solo, $otherA, $otherB)) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }

    # Real .code-workspace files mix plain paths and file URIs - exercise both.
    $teamWs = Join-Path $wsDir 'team.code-workspace'
    $teamJson = @{
        folders = @(
            @{ path = ($projA -replace '\\', '/') },
            @{ path = (ConvertTo-VsCodeUri $projB); name = 'projB' }
        )
    }
    [System.IO.File]::WriteAllText($teamWs, ($teamJson | ConvertTo-Json -Depth 6))

    $otherWs = Join-Path $wsDir 'unrelated.code-workspace'
    $otherJson = @{
        folders = @(
            @{ path = ($otherA -replace '\\', '/') },
            @{ path = ($otherB -replace '\\', '/') }
        )
    }
    [System.IO.File]::WriteAllText($otherWs, ($otherJson | ConvertTo-Json -Depth 6))

    $null = Write-StorageEntry -Dir (Join-Path $store 'multi-unrelated') -JsonObject @{ workspace = (ConvertTo-VsCodeUri $otherWs) } -AgeHours -2
    $null = Write-StorageEntry -Dir (Join-Path $store 'multi-team')      -JsonObject @{ workspace = (ConvertTo-VsCodeUri $teamWs) }
    $null = Write-StorageEntry -Dir (Join-Path $store 'single-solo')     -JsonObject @{ folder    = (ConvertTo-VsCodeUri $solo) } -AgeHours 1
    $null = Write-StorageEntry -Dir (Join-Path $store 'empty-entry')     -JsonObject $null -AgeHours 3

    return [PSCustomObject]@{
        Store = $store
        ProjA = $projA
        ProjB = $projB
        Solo  = $solo
    }
}

# Load a fixture config with a deterministic CWD (d:\work) instead of whatever
# directory this test process happens to run in.
function New-TestConfig {
    param(
        [string]$ConfigName,
        [string]$Cwd = 'd:\work',
        [string]$IDE = $null
    )
    $path = Join-Path $fixtureDir $ConfigName
    $cfg = Load-Config -Path $path

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $unified = ($Cwd -replace '[/\\]', $sep)
    if (-not $unified.EndsWith($sep)) { $unified += $sep }
    $cfg | Add-Member -MemberType NoteProperty -Name '_cwd' -Value $unified -Force
    $cfg | Add-Member -MemberType NoteProperty -Name '_cwdNorm' -Value $unified.ToLowerInvariant() -Force

    if ($IDE) {
        $null = Add-WorkspaceRoots -Config $cfg -IDE $IDE -StorageRoots @($script:fake.Store)
    }
    return $cfg
}

function Get-NormRoots {
    param($Roots)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $out = @()
    foreach ($r in @($Roots)) {
        if (-not $r) { continue }
        $u = ($r -replace '[/\\]', $sep)
        if (-not $u.EndsWith($sep)) { $u += $sep }
        $out += $u.ToLowerInvariant()
    }
    return @($out | Sort-Object)
}

function Test-RootsEqual {
    param($Actual, [string[]]$Expected)
    $a = @(Get-NormRoots $Actual)
    $e = @(Get-NormRoots $Expected)
    if ($a.Count -ne $e.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $e[$i]) { return $false } }
    return $true
}

function Test-ThrowsMatching {
    param([scriptblock]$Action, [string]$Pattern)
    try { $null = & $Action } catch { return ($_.Exception.Message -match $Pattern) }
    return $false
}

$script:fake = Initialize-FakeStorage -Root (Join-Path $env:TEMP ("pretoolhook-wr-" + [guid]::NewGuid().ToString('N').Substring(0, 10)))

Write-Host ""
Write-Host "--- WR: schema (workspace_roots block validation) ---" -ForegroundColor Cyan

# WR-01: no workspace_roots key at all -> loads, and the internal root lists
# exist and are empty (so downstream code can always iterate them).
try {
    $cfg = New-TestConfig -ConfigName 'config.noblock.json'
    $hasR = Test-HasProperty -Object $cfg -Name '_workspaceRoots'
    $hasN = Test-HasProperty -Object $cfg -Name '_workspaceRootsNorm'
    $r = @($cfg._workspaceRoots)
    $n = @($cfg._workspaceRootsNorm)
    $ok = $hasR -and $hasN -and ($r.Count -eq 0) -and ($n.Count -eq 0)
    Record-Result -Ok $ok -Name "WR-01 loader initializes empty root lists (no block)" -Detail "_workspaceRoots exists=$hasR count=$($r.Count) ; _workspaceRootsNorm exists=$hasN count=$($n.Count)"
}
catch { Record-Result -Ok $false -Name "WR-01 loader initializes empty root lists (no block)" -Detail $_.Exception.Message }

# WR-02: the loader must never invent roots on its own (discovery is opt-in and
# config-driven), so a config that declares them still loads with empty lists.
try {
    $cfg = New-TestConfig -ConfigName 'config.json'
    $hasR = Test-HasProperty -Object $cfg -Name '_workspaceRoots'
    $r = @($cfg._workspaceRoots)
    Record-Result -Ok ($hasR -and ($r.Count -eq 0)) -Name "WR-02 loader does not add roots by itself" -Detail "exists=$hasR count=$($r.Count)"
}
catch { Record-Result -Ok $false -Name "WR-02 loader does not add roots by itself" -Detail $_.Exception.Message }

# WR-03: unsupported discover source must THROW (fail-closed), not be ignored.
Record-Result -Ok (Test-ThrowsMatching -Action { Load-Config -Path (Join-Path $fixtureDir 'config.bad-discover.json') } -Pattern 'workspace_roots') `
    -Name "WR-03 bad discover source throws" -Detail "expected an exception mentioning 'workspace_roots'"

# WR-04: paths must be an array (a bare string would silently widen the policy).
Record-Result -Ok (Test-ThrowsMatching -Action { Load-Config -Path (Join-Path $fixtureDir 'config.bad-type.json') } -Pattern 'workspace_roots\.paths') `
    -Name "WR-04 non-array paths throws" -Detail "expected an exception mentioning 'workspace_roots.paths'"

# WR-05: enabled must be a real boolean.
Record-Result -Ok (Test-ThrowsMatching -Action { Load-Config -Path (Join-Path $fixtureDir 'config.bad-enabled.json') } -Pattern 'workspace_roots\.enabled') `
    -Name "WR-05 non-boolean enabled throws" -Detail "expected an exception mentioning 'workspace_roots.enabled'"

Write-Host ""
Write-Host "--- WR: VS Code URI conversion ---" -ForegroundColor Cyan

foreach ($case in @(
    @{ Uri = 'file:///c%3A/git/cc/kimi';                    Expect = 'c:\git\cc\kimi';        Name = 'WR-06 drive form + %3A' },
    @{ Uri = 'file://server/share/x';                       Expect = '\\server\share\x';      Name = 'WR-07 UNC form' },
    @{ Uri = 'file:///c%3A/temp/my%20docs';                 Expect = 'c:\temp\my docs';       Name = 'WR-08 percent-decoding (%20)' },
    @{ Uri = 'C:/git/cc/kimi';                              Expect = 'C:\git\cc\kimi';        Name = 'WR-09 plain path passthrough' }
)) {
    try {
        $got = ConvertFrom-VsCodeUri -Uri $case.Uri
        Record-Result -Ok ($got -eq $case.Expect) -Name $case.Name -Detail "expected '$($case.Expect)', got '$got'"
    }
    catch { Record-Result -Ok $false -Name $case.Name -Detail $_.Exception.Message }
}

Write-Host ""
Write-Host "--- WR: IDE gate + enabled gate ---" -ForegroundColor Cyan

# WR-10: explicit paths[] are adopted for Copilot.
try {
    $cfg = New-TestConfig -ConfigName 'config.json' -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok (Test-RootsEqual $r @('d:\other-repo')) -Name "WR-10 Copilot adopts paths[]" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-10 Copilot adopts paths[]" -Detail $_.Exception.Message }

# WR-11..13: other IDEs must never treat a workspace folder as CWD.
foreach ($ide in @('ClaudeCode', 'Codex', 'DSH')) {
    $label = switch ($ide) { 'ClaudeCode' { 'WR-11' } 'Codex' { 'WR-12' } 'DSH' { 'WR-13' } }
    try {
        $cfg = New-TestConfig -ConfigName 'config.json' -IDE $ide
        $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
        Record-Result -Ok (@($r).Count -eq 0) -Name "$label $ide adds no roots" -Detail "got [$(Format-Roots $r)]"
    }
    catch { Record-Result -Ok $false -Name "$label $ide adds no roots" -Detail $_.Exception.Message }
}

# WR-14: enabled=false must add nothing even for Copilot.
try {
    $cfg = New-TestConfig -ConfigName 'config.noroots.json' -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok (@($r).Count -eq 0) -Name "WR-14 enabled=false adds no roots" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-14 enabled=false adds no roots" -Detail $_.Exception.Message }

Write-Host ""
Write-Host "--- WR: VS Code workspace discovery (fake storage root) ---" -ForegroundColor Cyan

# WR-15..17: the anchor (CWD) lives in / under a folder of the multi-root
# workspace, so ALL of its folders become CWD-equivalent.
foreach ($case in @(
    @{ Anchor = $script:fake.ProjA;                              Name = "WR-15 anchor = folder A"; },
    @{ Anchor = (Join-Path $script:fake.ProjA 'src\deep\sub');   Name = "WR-16 anchor = subdir of folder A"; },
    @{ Anchor = $script:fake.ProjB;                              Name = "WR-17 anchor = second folder B"; }
)) {
    try {
        $cfg = New-TestConfig -ConfigName 'config.discover.json' -Cwd $case.Anchor -IDE 'Copilot'
        $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
        $exp = @($script:fake.ProjA, $script:fake.ProjB)
        $ok  = (Test-RootsEqual $r $exp) -and (@($r).Count -eq 2)
        Record-Result -Ok $ok -Name $case.Name -Detail "expected A+B, got [$(Format-Roots $r)]"
    }
    catch { Record-Result -Ok $false -Name $case.Name -Detail $_.Exception.Message }
}

# WR-18: a single-folder window contributes exactly that one folder.
try {
    $cfg = New-TestConfig -ConfigName 'config.discover.json' -Cwd $script:fake.Solo -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok ((@($r).Count -eq 1) -and (Test-RootsEqual $r @($script:fake.Solo))) -Name "WR-18 single-folder window" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-18 single-folder window" -Detail $_.Exception.Message }

# WR-19: an anchor that belongs to NO stored workspace must produce nothing -
# in particular it must not fall back to "the most recently used workspace"
# (multi-unrelated is the newest entry on purpose).
try {
    $cfg = New-TestConfig -ConfigName 'config.discover.json' -Cwd 'q:\no\such\workspace' -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok (@($r).Count -eq 0) -Name "WR-19 unknown anchor adopts nothing" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-19 unknown anchor adopts nothing" -Detail $_.Exception.Message }

# WR-20: 'discover' key absent means the documented default (vscode).
try {
    $cfg = New-TestConfig -ConfigName 'config.discover-absent.json' -Cwd $script:fake.ProjA -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok ((@($r).Count -eq 2) -and (Test-RootsEqual $r @($script:fake.ProjA, $script:fake.ProjB))) `
        -Name "WR-20 discover absent defaults to vscode" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-20 discover absent defaults to vscode" -Detail $_.Exception.Message }

# WR-21: discover: [] must disable discovery entirely (hermetic switch).
try {
    $cfg = New-TestConfig -ConfigName 'config.json' -Cwd $script:fake.ProjA -IDE 'Copilot'
    $r   = Get-MemberValue -Object $cfg -Name '_workspaceRoots'
    Record-Result -Ok (Test-RootsEqual $r @('d:\other-repo')) -Name "WR-21 discover [] disables discovery" -Detail "got [$(Format-Roots $r)]"
}
catch { Record-Result -Ok $false -Name "WR-21 discover [] disables discovery" -Detail $_.Exception.Message }

Write-Host ""
Write-Host "--- WR: path policy treats roots exactly like CWD ---" -ForegroundColor Cyan

# WR-22: reason string from the choke point every consumer shares.
try {
    $cfg = New-TestConfig -ConfigName 'config.json' -IDE 'Copilot'
    $reason = Test-EditableOrCwd -TargetPath 'd:\other-repo\src\a.txt' -Config $cfg
    Record-Result -Ok ($reason -eq 'under workspace folder') -Name "WR-22 Test-EditableOrCwd reason" -Detail "expected 'under workspace folder', got '$reason'"
}
catch { Record-Result -Ok $false -Name "WR-22 Test-EditableOrCwd reason" -Detail $_.Exception.Message }

# WR-23: Resolve-PathPolicy must ALLOW a write under the workspace folder even
# though editable_paths is enabled (which kills the normal-mode fallback).
try {
    $cfg = New-TestConfig -ConfigName 'config.json' -IDE 'Copilot'
    $p   = Resolve-PathPolicy -Path 'd:\other-repo\src\a.txt' -Config $cfg -Verb 'file write to'
    Record-Result -Ok (($p.Decision -eq 'allow') -and ($p.Reason -match 'workspace folder')) -Name "WR-23 Resolve-PathPolicy allows under root" -Detail "decision=$($p.Decision) reason=$($p.Reason)"
}
catch { Record-Result -Ok $false -Name "WR-23 Resolve-PathPolicy allows under root" -Detail $_.Exception.Message }

# WR-24: same path with the feature disabled -> still ask (no behavior change
# for anyone who does not opt in).
try {
    $cfg = New-TestConfig -ConfigName 'config.noroots.json' -IDE 'Copilot'
    $p   = Resolve-PathPolicy -Path 'd:\other-repo\src\a.txt' -Config $cfg -Verb 'file write to'
    Record-Result -Ok ($p.Decision -eq 'ask') -Name "WR-24 disabled -> still ask" -Detail "decision=$($p.Decision) reason=$($p.Reason)"
}
catch { Record-Result -Ok $false -Name "WR-24 disabled -> still ask" -Detail $_.Exception.Message }

# WR-25: the reported production case. The Stage-2 guard vetoes the LLM's
# "modifying" verdict because a path token asks; a workspace root must clear it.
$gitCmd = 'git -C ''d:\other-repo'' commit -m "test"'
try {
    $cfgOn  = New-TestConfig -ConfigName 'config.json' -IDE 'Copilot'
    $cfgOff = New-TestConfig -ConfigName 'config.noroots.json' -IDE 'Copilot'
    $safeOn  = Test-GatedInvocationSafe -Command $gitCmd -Config $cfgOn
    $safeOff = Test-GatedInvocationSafe -Command $gitCmd -Config $cfgOff
    Record-Result -Ok (($safeOn -eq $true) -and ($safeOff -eq $false)) -Name "WR-25 git -C <workspace folder> commit is guard-safe" -Detail "with roots=$safeOn (expected True), without=$safeOff (expected False)"
}
catch { Record-Result -Ok $false -Name "WR-25 git -C <workspace folder> commit is guard-safe" -Detail $_.Exception.Message }

# WR-26: a path outside every root still asks - the widening must be exactly
# the declared/discovered folders, nothing else.
try {
    $cfg = New-TestConfig -ConfigName 'config.json' -IDE 'Copilot'
    $p   = Resolve-PathPolicy -Path 'd:\nope\x.txt' -Config $cfg -Verb 'file write to'
    Record-Result -Ok ($p.Decision -eq 'ask') -Name "WR-26 unrelated path still asks" -Detail "decision=$($p.Decision) reason=$($p.Reason)"
}
catch { Record-Result -Ok $false -Name "WR-26 unrelated path still asks" -Detail $_.Exception.Message }

Write-Host ""
Write-Host "--- WR: end to end through Hook.ps1 ---" -ForegroundColor Cyan

function Invoke-Hook {
    param([string]$PayloadJson, [string]$ConfigPath)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'pwsh'
    $psi.Arguments              = "-NoProfile -NonInteractive -File `"$(Join-Path $srcDir 'Hook.ps1')`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $fixtureDir

    $previousConfig = $env:PRETOOLHOOK_CONFIG_PATH
    $env:PRETOOLHOOK_CONFIG_PATH = $ConfigPath
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($PayloadJson)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $null = $proc.WaitForExit(30000)
        $exit = $proc.ExitCode
    }
    finally {
        $env:PRETOOLHOOK_CONFIG_PATH = $previousConfig
    }

    $decision = ''
    $reason   = ''
    if ($stdout -and $stdout.Trim()) {
        try {
            $parsed = $stdout.Trim() | ConvertFrom-Json
            $decision = $parsed.hookSpecificOutput.permissionDecision
            $reason   = $parsed.hookSpecificOutput.permissionDecisionReason
        }
        catch { $reason = "unparseable stdout: $stdout" }
    }
    return [PSCustomObject]@{ Decision = $decision; Reason = $reason; ExitCode = $exit; Stderr = $stderr; Stdout = $stdout }
}

function New-CopilotPayload {
    param([string]$ToolName, $ToolInput)
    return (@{
        hook_event_name = 'preToolUse'
        timestamp       = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        cwd             = $fixtureDir
        tool_name       = $ToolName
        tool_input      = $ToolInput
    } | ConvertTo-Json -Depth 8 -Compress)
}

function New-ClaudeCodePayload {
    param([string]$ToolName, $ToolInput)
    return (@{
        hook_event_name = 'PreToolUse'
        tool_use_id     = 'toolu_01WRtest'
        timestamp       = '2026-10-21T06:00:00.000Z'
        transcript_path = "$env:USERPROFILE\.claude\projects\x\transcript.jsonl"
        cwd             = $fixtureDir
        tool_name       = $ToolName
        tool_input      = $ToolInput
    } | ConvertTo-Json -Depth 8 -Compress)
}

$writeInput = @{ file_path = 'd:\other-repo\a.txt'; content = 'x' }

# WR-27: Copilot + roots -> allow (this is the whole point of the feature).
try {
    $r = Invoke-Hook -PayloadJson (New-CopilotPayload -ToolName 'Write' -ToolInput $writeInput) -ConfigPath (Join-Path $fixtureDir 'config.json')
    Record-Result -Ok (($r.Decision -eq 'allow') -and ($r.Reason -match 'workspace folder')) -Name "WR-27 e2e Copilot Write under root -> allow" -Detail "decision=$($r.Decision) reason=$($r.Reason) exit=$($r.ExitCode) stderr=$($r.Stderr)"
}
catch { Record-Result -Ok $false -Name "WR-27 e2e Copilot Write under root -> allow" -Detail $_.Exception.Message }

# WR-28: same call, feature disabled -> ask (negative control).
try {
    $r = Invoke-Hook -PayloadJson (New-CopilotPayload -ToolName 'Write' -ToolInput $writeInput) -ConfigPath (Join-Path $fixtureDir 'config.noroots.json')
    Record-Result -Ok ($r.Decision -eq 'ask') -Name "WR-28 e2e Copilot + disabled -> ask" -Detail "decision=$($r.Decision) reason=$($r.Reason) exit=$($r.ExitCode)"
}
catch { Record-Result -Ok $false -Name "WR-28 e2e Copilot + disabled -> ask" -Detail $_.Exception.Message }

# WR-29: same call from Claude Code -> ask (VS Code-only gate, end to end).
try {
    $r = Invoke-Hook -PayloadJson (New-ClaudeCodePayload -ToolName 'Write' -ToolInput $writeInput) -ConfigPath (Join-Path $fixtureDir 'config.json')
    Record-Result -Ok ($r.Decision -eq 'ask') -Name "WR-29 e2e Claude Code -> ask (IDE gate)" -Detail "decision=$($r.Decision) reason=$($r.Reason) exit=$($r.ExitCode)"
}
catch { Record-Result -Ok $false -Name "WR-29 e2e Claude Code -> ask (IDE gate)" -Detail $_.Exception.Message }

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
try { Remove-Item -Path $script:fake.Store -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -Path (Split-Path $script:fake.Store -Parent) -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ""
Write-Host "Total: $($script:total)  Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) {
    Write-Host "Failed checks:"
    $script:failures | ForEach-Object { Write-Host "  - $($_.Name): $($_.Detail)" }
    exit 1
}
exit 0
