# =============================================================================
# Run-Tests.ps1 - ask_notification fixture runner
# =============================================================================
#
# WHAT THIS FILE IS
#   The dedicated test suite for the ask_notification feature (toast popup +
#   sound whenever the hook decides "ask"). Deliberately SEPARATE from the main
#   suites: runs in seconds, never pops a real GUI (mock mode).
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/ask-notification/Run-Tests.ps1
#   Exit code 0 = all green. Exit code 1 = at least one check failed.
#
# THE MOCK (why no toast pops during tests)
#   Send-AskNotification checks env var PRETOOLHOOK_ASKNOTIFY_MOCK FIRST.
#   When set to a directory path, the notifier writes a marker file
#   "<dir>\ask-notified.txt" (with the decision reason inside) instead of
#   popping a toast/sound. Tests assert on the marker's presence/absence.
#
# THE CHECKS
#   Pre-flight (3):
#     - AskNotifyConfig-BadType   : enabled="yes" (string) MUST throw
#     - AskNotifyConfig-Defaults  : block absent -> compiled defaults (all on)
#     - AskNotifyConfig-Compile   : full block -> compiled fields match config
#   Unit (5):
#     - AskNotify-AskFires        : decision=ask, enabled -> marker written
#     - AskNotify-AllowSkips      : decision=allow, enabled -> NO marker
#     - AskNotify-DisabledSkips   : decision=ask, disabled -> NO marker
#     - AskNotify-NoPopupNoSound  : popup=false sound=false -> marker still
#                                   written (mock fires regardless; real run
#                                   would be silent), no crash
#     - AskNotify-MissingSoundOk  : sound_file missing -> no crash, marker ok
#   Fullpipe (2): spawn the REAL Hook.ps1
#     - AskNotify-Fullpipe-Ask    : rm command -> ask -> marker written
#     - AskNotify-Fullpipe-Allow  : ls command -> allow -> NO marker
# =============================================================================

param()

$ErrorActionPreference = "Stop"

# Paths
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"
$hookPath   = Join-Path $srcDir "Hook.ps1"

# Dot-source the REAL engine modules
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "Classifier.ps1")

# TDD scaffold: the feature under test
$NotifyLoaded = $false
if (Test-Path (Join-Path $srcDir "Notify-Ask.ps1")) {
    . (Join-Path $srcDir "Notify-Ask.ps1")
    $NotifyLoaded = $true
}

# Counters + failure list
$script:total = 0; $script:passed = 0; $script:failed = 0; $script:failures = @()

function Record-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    $script:total++
    if ($Ok) { $script:passed++ }
    else {
        $script:failed++
        $script:failures += [PSCustomObject]@{ Name = $Name; Detail = $Detail }
        Write-Host "FAIL [$Name]" -ForegroundColor Red
        Write-Host "  $Detail"
    }
}

# Temp dir for mock marker files (unique per run)
$mockDir = Join-Path $env:TEMP ("asknotify-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
$markerPath = Join-Path $mockDir "ask-notified.txt"

function Remove-Marker {
    if (Test-Path $markerPath) { Remove-Item $markerPath -Force }
}

# =============================================================================
# PRE-FLIGHT 1: AskNotifyConfig-BadType — enabled="yes" (string) MUST throw
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badtype.json")
    Record-Result -Ok $false -Name "AskNotifyConfig-BadType" -Detail "Load-Config did NOT throw for enabled='yes' (string)"
}
catch {
    $ok = $_.Exception.Message -match 'ask_notification\.enabled'
    Record-Result -Ok $ok -Name "AskNotifyConfig-BadType" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 2: AskNotifyConfig-Defaults — block absent -> compiled defaults
# =============================================================================
try {
    $cfgNoBlock = Load-Config -Path (Join-Path $fixtureDir "config.disabled.json")
    # config.disabled.json HAS the block (enabled=false). Build a no-block variant in-memory.
    $cfgRaw = Get-Content (Join-Path $fixtureDir "config.disabled.json") -Raw | ConvertFrom-Json
    $cfgRaw.PSObject.Properties.Remove('ask_notification')
    $tmpNoBlock = Join-Path $env:TEMP "asknotify-noblock-config.json"
    $cfgRaw | ConvertTo-Json -Depth 10 | Set-Content $tmpNoBlock -Encoding UTF8
    $cfgNoBlock = Load-Config -Path $tmpNoBlock
    Remove-Item $tmpNoBlock -Force -ErrorAction SilentlyContinue

    $an = $cfgNoBlock._compiled.askNotification
    $ok = ($null -ne $an) -and ($an.Enabled -eq $true) -and ($an.Popup -eq $true) -and ($an.Sound -eq $true) -and ($an.SoundFile -eq '')
    Record-Result -Ok $ok -Name "AskNotifyConfig-Defaults" -Detail "absent block -> compiled: Enabled=$($an.Enabled) Popup=$($an.Popup) Sound=$($an.Sound) SoundFile='$($an.SoundFile)' (expected all defaults: True/True/True/'')"
}
catch {
    Record-Result -Ok $false -Name "AskNotifyConfig-Defaults" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 3: AskNotifyConfig-Compile — full block -> compiled fields match
# =============================================================================
try {
    $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
    $an = $cfg._compiled.askNotification
    $ok = ($null -ne $an) -and ($an.Enabled -eq $true) -and ($an.Popup -eq $true) -and ($an.Sound -eq $true) -and ($an.SoundFile -eq '')
    Record-Result -Ok $ok -Name "AskNotifyConfig-Compile" -Detail "config.json -> compiled: Enabled=$($an.Enabled) Popup=$($an.Popup) Sound=$($an.Sound) SoundFile='$($an.SoundFile)'"
}
catch {
    Record-Result -Ok $false -Name "AskNotifyConfig-Compile" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# UNIT 1: AskNotify-AskFires — decision=ask, enabled -> marker written
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-AskFires" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
        $result = [PSCustomObject]@{ Decision = "ask"; Reason = "modifying command: rm"; Command = "rm -rf /tmp/x" }
        Send-AskNotification -ClassifyResult $result -Config $cfg
        Start-Sleep -Milliseconds 200   # fire-and-forget: give the worker a beat
        $ok = Test-Path $markerPath
        Record-Result -Ok $ok -Name "AskNotify-AskFires" -Detail "decision=ask, enabled -> marker exists=$ok (expected True)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-AskFires" -Detail "threw: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# UNIT 2: AskNotify-AllowSkips — decision=allow, enabled -> NO marker
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-AllowSkips" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
        $result = [PSCustomObject]@{ Decision = "allow"; Reason = "read-only"; Command = "ls /tmp" }
        Send-AskNotification -ClassifyResult $result -Config $cfg
        Start-Sleep -Milliseconds 200
        $ok = -not (Test-Path $markerPath)
        Record-Result -Ok $ok -Name "AskNotify-AllowSkips" -Detail "decision=allow, enabled -> marker exists=$(-not $ok) (expected False)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-AllowSkips" -Detail "threw: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# UNIT 3: AskNotify-DisabledSkips — decision=ask, disabled -> NO marker
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-DisabledSkips" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $cfg = Load-Config -Path (Join-Path $fixtureDir "config.disabled.json")
        $result = [PSCustomObject]@{ Decision = "ask"; Reason = "modifying command: rm"; Command = "rm -rf /tmp/x" }
        Send-AskNotification -ClassifyResult $result -Config $cfg
        Start-Sleep -Milliseconds 200
        $ok = -not (Test-Path $markerPath)
        Record-Result -Ok $ok -Name "AskNotify-DisabledSkips" -Detail "decision=ask, enabled=false -> marker exists=$(-not $ok) (expected False)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-DisabledSkips" -Detail "threw: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# UNIT 4: AskNotify-NoPopupNoSound — popup=false sound=false -> marker still
# written in mock mode (mock proves the trigger fired; popup/sound are
# presentational and don't gate the trigger)
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-NoPopupNoSound" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
        $cfg._compiled.askNotification.Popup = $false
        $cfg._compiled.askNotification.Sound = $false
        $result = [PSCustomObject]@{ Decision = "ask"; Reason = "modifying"; Command = "rm x" }
        Send-AskNotification -ClassifyResult $result -Config $cfg
        Start-Sleep -Milliseconds 200
        $ok = Test-Path $markerPath
        Record-Result -Ok $ok -Name "AskNotify-NoPopupNoSound" -Detail "popup=false sound=false, decision=ask -> marker exists=$ok (expected True; mock fires regardless of presentation)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-NoPopupNoSound" -Detail "threw: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# UNIT 5: AskNotify-MissingSoundOk — sound_file missing -> no crash, marker ok
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-MissingSoundOk" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $cfg = Load-Config -Path (Join-Path $fixtureDir "config.missingsound.json")
        $result = [PSCustomObject]@{ Decision = "ask"; Reason = "modifying"; Command = "rm x" }
        Send-AskNotification -ClassifyResult $result -Config $cfg
        Start-Sleep -Milliseconds 200
        $ok = Test-Path $markerPath
        Record-Result -Ok $ok -Name "AskNotify-MissingSoundOk" -Detail "sound_file missing, decision=ask -> marker exists=$ok, no crash (expected True)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-MissingSoundOk" -Detail "threw (should never crash the hook): $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# FULLPIPE 1: AskNotify-Fullpipe-Ask — rm command -> ask -> marker written
# =============================================================================
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-Fullpipe-Ask" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $fixtureDir "config.json"
        $payload = (@{
            tool_name       = "Bash"
            tool_input      = @{ command = "rm -rf /tmp/test-x" }
            hook_event_name = "preToolUse"
            timestamp       = "1790000000000"
        } | ConvertTo-Json -Compress -Depth 5)
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 300   # fire-and-forget: give the child a beat

        $out = $stdout | ConvertFrom-Json -ErrorAction Stop
        $decision = $out.hookSpecificOutput.permissionDecision
        $markerExists = Test-Path $markerPath
        $ok = ($decision -eq "ask") -and ($exitCode -eq 0) -and $markerExists
        Record-Result -Ok $ok -Name "AskNotify-Fullpipe-Ask" -Detail "rm -> decision=$decision exit=$exitCode marker=$markerExists (expected ask+0+True)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-Fullpipe-Ask" -Detail "threw: $($_.Exception.Message) | stdout: $stdout"
    }
}

# =============================================================================
# FULLPIPE 2: AskNotify-Fullpipe-Allow — ls command -> allow -> NO marker
# =============================================================================
if (-not $NotifyLoaded) {
    Record-Result -Ok $false -Name "AskNotify-Fullpipe-Allow" -Detail "Notify-Ask.ps1 not loaded (TDD red phase)"
}
else {
    try {
        Remove-Marker
        $env:PRETOOLHOOK_ASKNOTIFY_MOCK = $mockDir
        $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $fixtureDir "config.json"
        $payload = (@{
            tool_name       = "Bash"
            tool_input      = @{ command = "ls /tmp" }
            hook_event_name = "preToolUse"
            timestamp       = "1790000000000"
        } | ConvertTo-Json -Compress -Depth 5)
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PRETOOLHOOK_ASKNOTIFY_MOCK -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 300

        $out = $stdout | ConvertFrom-Json -ErrorAction Stop
        $decision = $out.hookSpecificOutput.permissionDecision
        $markerExists = Test-Path $markerPath
        $ok = ($decision -eq "allow") -and ($exitCode -eq 0) -and (-not $markerExists)
        Record-Result -Ok $ok -Name "AskNotify-Fullpipe-Allow" -Detail "ls -> decision=$decision exit=$exitCode marker=$markerExists (expected allow+0+False)"
    }
    catch {
        Record-Result -Ok $false -Name "AskNotify-Fullpipe-Allow" -Detail "threw: $($_.Exception.Message) | stdout: $stdout"
    }
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "Total: $($script:total)  Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) {
    Write-Host "Failed checks:"
    $script:failures | ForEach-Object { Write-Host "  - $($_.Name)" }
    exit 1
}
exit 0
