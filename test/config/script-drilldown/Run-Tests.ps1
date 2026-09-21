# =============================================================================
# Run-Tests.ps1 - script_drilldown fixture runner (2026-09-20)
# =============================================================================
#
# WHAT THIS FILE IS
#   Dedicated suite for the script_drilldown feature. Small isolated fixture
#   config, runs in seconds, no network, no GUI. Mirrors the house style of
#   test/config/trusted-programs-regex/Run-Tests.ps1.
#
# FEATURE UNDER TEST (config key: script_drilldown)
#   When the agent runs `pwsh -File <script>.ps1`, the hook opens the file,
#   splits it into statements via the existing AST walker, and classifies each
#   as if typed on the command line. Numbered [N] sub-commands are prefixed
#   <script:basename> in the log + LLM prompt. Gated by the script_drilldown
#   config block; absent/disabled => byte-identical to today (spec D2 / I1).
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/script-drilldown/Run-Tests.ps1
#   Exit code 0 = all green. Exit code 1 = at least one check failed.
#
# CHECKS
#   Preflights (in-process, this runner):
#     SDD-BadRunner / SDD-BadScope / SDD-BadCap : invalid config must throw
#                                                  fail-closed with a message
#                                                  naming the offending key.
#     SDD-CompiledPresent                       : config.json compiles to
#                                                  _compiled.scriptDrilldown with
#                                                  Runners=@('powershell'), caps
#                                                  3/4096, LlmScope 'count'.
#     SDD-OffNoCompile                          : config.off.json (block absent)
#                                                  => _compiled.scriptDrilldown
#                                                  is $null.
#   XML suites (child powershell.exe 5.1, like production, via TestRunner):
#     SDD-CoreSuite    : test-cases.xml against config.json (drilldown ON).
#                        -Cwd <fixtureDir> so relative script paths anchor.
#     SDD-OFF-Parity   : test-cases.off.xml against config.off.json (block
#                        absent) - every case must yield TODAY's decision.
#   Programmatic:
#     SDD-AbsolutePath : build `pwsh -NoProfile -File "<abs>\readonly.ps1"`,
#                        Invoke-Classify with the fixture config, assert allow
#                        (D8 absolute-path-as-is; not baked into the XML).
#
# TDD NOTE: this is the RED runner. Before any src/ change, every ON-case fails
# (no expansion => untrusted -File path asks via `unknown command`), the three
# bad-config preflights fail (no validation yet), and SDD-CompiledPresent /
# SDD-AbsolutePath fail. SDD-OFF-Parity + SDD-OffNoCompile PASS already.
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
# =============================================================================

param()

$ErrorActionPreference = "Stop"

# Paths
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"

# Dot-source the REAL engine modules (preflights + the programmatic check).
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
$ClassifierLoaded = $false
if (Test-Path (Join-Path $srcDir "Classifier.ps1")) {
    . (Join-Path $srcDir "Classifier.ps1")
    $ClassifierLoaded = $true
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

# =============================================================================
# PRE-FLIGHT 1: SDD-BadRunner - unknown runner entry -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badrunner.json")
    Record-Result -Ok $false -Name "SDD-BadRunner" -Detail "Load-Config did NOT throw for script_drilldown.runners=['python']"
}
catch {
    $ok = $_.Exception.Message -match 'runners'
    if ($ok) {
        Record-Result -Ok $true -Name "SDD-BadRunner" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDD-BadRunner" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 2: SDD-BadScope - invalid llm_scope -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badscope.json")
    Record-Result -Ok $false -Name "SDD-BadScope" -Detail "Load-Config did NOT throw for script_drilldown.llm_scope='sometimes'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_scope'
    if ($ok) {
        Record-Result -Ok $true -Name "SDD-BadScope" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDD-BadScope" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 3: SDD-BadCap - max_chained_files=0 -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badcap.json")
    Record-Result -Ok $false -Name "SDD-BadCap" -Detail "Load-Config did NOT throw for script_drilldown.max_chained_files=0"
}
catch {
    $ok = $_.Exception.Message -match 'max_chained_files'
    if ($ok) {
        Record-Result -Ok $true -Name "SDD-BadCap" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDD-BadCap" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 4: SDD-CompiledPresent - valid config compiles the drilldown block
# =============================================================================
try {
    $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
    $dd = $null
    if ($cfg._compiled.PSObject.Properties['scriptDrilldown']) { $dd = $cfg._compiled.scriptDrilldown }
    if (-not $dd) {
        Record-Result -Ok $false -Name "SDD-CompiledPresent" -Detail "_compiled.scriptDrilldown missing after Load-Config (TDD red phase or compile not implemented)"
    }
    else {
        $runners = @($dd.Runners) -join ','
        $capsOk  = ($dd.MaxChainedFiles -eq 3) -and ($dd.MaxFileBytes -eq 4096)
        $scopeOk = ("$($dd.LlmScope)" -eq 'count')
        if (($runners -eq 'powershell') -and $capsOk -and $scopeOk) {
            Record-Result -Ok $true -Name "SDD-CompiledPresent" -Detail "Runners=$runners caps=3/4096 LlmScope=count"
        }
        else {
            Record-Result -Ok $false -Name "SDD-CompiledPresent" -Detail "compiled block wrong: Runners='$runners' MaxChainedFiles=$($dd.MaxChainedFiles) MaxFileBytes=$($dd.MaxFileBytes) LlmScope=$($dd.LlmScope)"
        }
    }
}
catch {
    Record-Result -Ok $false -Name "SDD-CompiledPresent" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 5: SDD-OffNoCompile - block absent => no compiled block, gate $null
# =============================================================================
try {
    $cfgOff = Load-Config -Path (Join-Path $fixtureDir "config.off.json")
    $ddOff = $null
    if ($cfgOff._compiled.PSObject.Properties['scriptDrilldown']) { $ddOff = $cfgOff._compiled.scriptDrilldown }
    if ($null -eq $ddOff) {
        Record-Result -Ok $true -Name "SDD-OffNoCompile" -Detail "_compiled.scriptDrilldown is $null for config.off.json"
    }
    else {
        Record-Result -Ok $false -Name "SDD-OffNoCompile" -Detail "_compiled.scriptDrilldown present although the block is absent"
    }
}
catch {
    Record-Result -Ok $false -Name "SDD-OffNoCompile" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# XML SUITE HELPER - run one TestRunner XML file in a child powershell.exe 5.1
# (like production) and fold its Total/Passed/Failed into our counters.
# $Cwd is passed so relative script paths anchor to the fixture dir (F9).
# =============================================================================
function Invoke-XmlSuite {
    param([string]$Name, [string]$Xml, [string]$CfgJson, [string]$Cwd)
    $runner = Join-Path $srcDir "TestRunner.ps1"
    Write-Host ""
    Write-Host "--- $Name (TestRunner, powershell.exe) ---" -ForegroundColor Cyan

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -XmlPath $Xml -ConfigPath $CfgJson -Cwd $Cwd 2>&1 | Out-String
    $childExit = $LASTEXITCODE

    $mTotal  = [regex]::Match($output, '(?m)^Total:\s+(\d+)')
    $mPassed = [regex]::Match($output, '(?m)^Passed:\s+(\d+)')
    $mFailed = [regex]::Match($output, '(?m)^Failed:\s+(\d+)')

    if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
        Record-Result -Ok $false -Name $Name -Detail "could not parse TestRunner summary (exit=$childExit). Output tail: $($output.Substring([Math]::Max(0, $output.Length - 800)))"
    }
    else {
        $xTotal  = [int]$mTotal.Groups[1].Value
        $xPassed = [int]$mPassed.Groups[1].Value
        $xFailed = [int]$mFailed.Groups[1].Value
        if ($xFailed -gt 0) {
            $failIdx = $output.IndexOf('Failed Tests:')
            $detail = if ($failIdx -ge 0) { $output.Substring($failIdx).Trim() } else { "exit=$childExit" }
            Record-Result -Ok $false -Name $Name -Detail "$xFailed/$xTotal XML cases failed. $detail"
        }
        else {
            Record-Result -Ok $true -Name $Name -Detail "$xPassed/$xTotal XML cases passed"
        }
    }
}

# =============================================================================
# XML SUITE 1: SDD-CoreSuite - the ON matrix (config.json, drilldown enabled)
# =============================================================================
Invoke-XmlSuite -Name "SDD-CoreSuite" `
    -Xml (Join-Path $fixtureDir "test-cases.xml") `
    -CfgJson (Join-Path $fixtureDir "config.json") `
    -Cwd $fixtureDir

# =============================================================================
# XML SUITE 2: SDD-OFF-Parity - same commands, block ABSENT (config.off.json).
# Must yield TODAY's decisions both in the RED phase and after implementation.
# =============================================================================
Invoke-XmlSuite -Name "SDD-OFF-Parity" `
    -Xml (Join-Path $fixtureDir "test-cases.off.xml") `
    -CfgJson (Join-Path $fixtureDir "config.off.json") `
    -Cwd $fixtureDir

# =============================================================================
# PROGRAMMATIC: SDD-AbsolutePath - D8 absolute-path-as-is.
# The fixture dir is machine-specific, so this check lives here instead of in
# the static XML. Reload config.json FIRST so the published gate (when
# implemented) reflects the ON config for this in-process classify.
# =============================================================================
if (-not $ClassifierLoaded) {
    Record-Result -Ok $false -Name "SDD-AbsolutePath" -Detail "Classifier.ps1 not loaded"
}
else {
    try {
        $cfgAbs = Load-Config -Path (Join-Path $fixtureDir "config.json")
        # Mirror TestRunner -Cwd: anchor relative paths to the fixture dir.
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $cwdResolved = ($fixtureDir -replace '[/\\]', $sep)
        if (-not $cwdResolved.EndsWith($sep)) { $cwdResolved += $sep }
        $cfgAbs._cwd = $cwdResolved
        $cfgAbs._cwdNorm = $cwdResolved.ToLowerInvariant()

        $absScript = Join-Path $fixtureDir "scripts\readonly.ps1"
        $cmd = "pwsh -NoProfile -File $absScript"
        $rawInput = [PSCustomObject]@{
            tool_name  = "Bash"
            tool_input = [PSCustomObject]@{ command = $cmd }
        }
        $r = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $cfgAbs
        if ($r.Decision -eq 'allow') {
            Record-Result -Ok $true -Name "SDD-AbsolutePath" -Detail "absolute -File path allowed: $($r.Reason)"
        }
        else {
            Record-Result -Ok $false -Name "SDD-AbsolutePath" -Detail "expected allow, got $($r.Decision): $($r.Reason)"
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-AbsolutePath" -Detail "threw: $($_.Exception.Message)"
    }
}

# =============================================================================
# Summary (ONE line - Run-AllTests parses the first Total: match)
# =============================================================================
Write-Host ""
Write-Host "Total: $($script:total)  Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) {
    Write-Host "Failed checks:"
    $script:failures | ForEach-Object { Write-Host "  - $($_.Name): $($_.Detail)" }
    exit 1
}
exit 0
