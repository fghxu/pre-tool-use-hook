# Run-AllTests.ps1 - one-shot runner for every test suite under test/config/live/
#                    plus the zero-quota llm-review fixture suites.
#
# Discovers test/config/live/*.xml automatically and runs each with its required
# invocation (some suites need -Strictness/-Cwd/-ConfigPath or the full-pipe runner).
# Then runs the llm-review suites (small/large/phase-I/http-mock - mocked verdicts,
# no network). The LIVE LLM suite (real gateway, ~2k tokens) is NOT run here.
#
# Documented pre-existing failures are encoded per suite (KnownFails) so the
# overall verdict is meaningful: a suite is OK when its failures match the
# baseline, REGRESSION when it has more, IMPROVED when it has fewer (update
# the baseline then). Baselines are tracked in PROGRESS.md.
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
#   powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1 -Filter strictness
#   powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1 -ShowOutput
#
# Exit code: 1 if any suite regresses or errors, 0 otherwise.

param(
    [string]$Filter = "",   # only run suite files whose name contains this
    [switch]$ShowOutput     # stream each suite's full output, not just the result line
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir  = Join-Path $repoRoot 'test\config\live'

# Per-suite invocation + documented failure baseline (see PROGRESS.md).
# Any *.xml NOT listed here runs with default TestRunner args and KnownFails 0,
# so new suites are picked up automatically.
# Suites run against the TEST COPY $testDir\config.json (refresh with
# test/config/live/Sync-Fixtures.ps1 after editing the repo-root config.json),
# NOT the repo-root config.json directly.
$suiteConfig = @{
    'test-cases.xml' = @{
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.json'))
        KnownFails = 0
    }
    'test-cases.strictness-gated.normal.xml' = @{
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.json'))
        KnownFails = 0
    }
    'test-cases.redirect-strict.xml' = @{
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.strict.json'))
        KnownFails = 0
    }
    'test-cases.trustedpattern.xml' = @{
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.json'), '-Cwd', 'C:\git\repo')   # CWD-dependent cases (see xml header)
        KnownFails = 0
    }
    'test-cases.strictness-gated.strict.xml' = @{
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.json'), '-Strictness', 'strict')
        KnownFails = 0
    }
    'test-fullpipe.xml' = @{
        Runner     = 'FullPipe'                 # pwsh + spawns Hook.ps1 per case
        Args       = @('-ConfigPath', (Join-Path $testDir 'config.json'))
        KnownFails = 0
    }
}

$xmlFiles = @(Get-ChildItem -Path $testDir -Filter '*.xml' -File | Sort-Object Name)
if ($Filter) {
    $xmlFiles = @($xmlFiles | Where-Object { $_.Name -like "*$Filter*" })
}

# Extra zero-quota suites with their own runners (no TestRunner XML form).
# The llm-review fixture suites inject verdicts via the mock env var / a local
# mock server - no network, no quota. Two llm-review suites are deliberately
# NOT here: the 80-check large matrix (user call 2026-08-03 - kept as an
# opt-in -XmlPath run) and the LIVE suite (real gateway, ~2k tokens, user-run
# only).
$extraSuites = @(
    @{ Name = 'llm-review.small';    File = (Join-Path $repoRoot 'test\config\llm-review\Run-Tests.ps1'); Args = @() },
    @{ Name = 'llm-review.phase-I';  File = (Join-Path $repoRoot 'test\config\llm-review\Run-Tests.ps1'); Args = @('-XmlPath', (Join-Path $repoRoot 'test\config\llm-review\test-cases.xml')) },
    @{ Name = 'llm-review.safetynet'; File = (Join-Path $repoRoot 'test\config\llm-review\Run-Tests.ps1'); Args = @('-XmlPath', (Join-Path $repoRoot 'test\config\llm-review\test-cases.safetynet.xml')) },
    @{ Name = 'llm-review.http-mock'; File = (Join-Path $repoRoot 'test\config\llm-review\http\Run-LlmCallTests.ps1'); Args = @() }
)
if ($Filter) {
    $extraSuites = @($extraSuites | Where-Object { $_.Name -like "*$Filter*" })
}

if ($xmlFiles.Count -eq 0 -and $extraSuites.Count -eq 0) {
    Write-Host "No test suites found under $testDir (filter: '$Filter')" -ForegroundColor Red
    exit 1
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$anyRegression = $false

foreach ($file in $xmlFiles) {
    $cfg        = $suiteConfig[$file.Name]
    $runner     = if ($cfg -and $cfg.Runner) { $cfg.Runner } else { 'TestRunner' }
    $extraArgs  = if ($cfg) { @($cfg.Args) } else { @() }
    $knownFails = if ($cfg) { $cfg.KnownFails } else { 0 }

    Write-Host ""
    Write-Host "=== $($file.Name) ===" -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = $null
    $runError = $null
    try {
        if ($runner -eq 'FullPipe') {
            if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
                $runError = "pwsh not found - full-pipe suite requires PowerShell 7+"
            }
            else {
                $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testDir 'FullPipeTestRunner.ps1') -XmlPath $file.FullName @extraArgs 2>&1 | Out-String
            }
        }
        else {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'TestRunner.ps1') -XmlPath $file.FullName @extraArgs 2>&1 | Out-String
        }
    }
    catch {
        $runError = $_.Exception.Message
    }
    $sw.Stop()

    if ($ShowOutput -and $output) { Write-Host $output }

    $status = $null
    $color = 'Green'
    $total = 0; $passed = 0; $failed = 0

    if ($runError) {
        $status = "ERROR: $runError"
        $color = 'Red'
        $anyRegression = $true
    }
    else {
        $mTotal  = [regex]::Match($output, '(?m)^Total:\s+(\d+)')
        $mPassed = [regex]::Match($output, '(?m)^Passed:\s+(\d+)')
        $mFailed = [regex]::Match($output, '(?m)^Failed:\s+(\d+)')

        if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
            $status = "ERROR: could not parse suite summary"
            $color = 'Red'
            $anyRegression = $true
        }
        else {
            $total  = [int]$mTotal.Groups[1].Value
            $passed = [int]$mPassed.Groups[1].Value
            $failed = [int]$mFailed.Groups[1].Value

            if ($failed -gt $knownFails) {
                $status = "REGRESSION ($failed > $knownFails known)"
                $color = 'Red'
                $anyRegression = $true
                # Show which tests failed - this is what you need on a regression
                $idx = $output.IndexOf('Failed Tests:')
                if ($idx -ge 0) { Write-Host ($output.Substring($idx)) -ForegroundColor Red }
            }
            elseif ($failed -eq $knownFails) {
                if ($failed -eq 0) { $status = 'PASS' }
                else { $status = "OK ($failed known)"; $color = 'Yellow' }
            }
            else {
                $status = "IMPROVED ($failed < $knownFails known - update baseline)"
                $color = 'Yellow'
            }
        }
    }

    $results.Add([PSCustomObject]@{
        Suite = $file.Name; Total = $total; Passed = $passed; Failed = $failed
        Known = $knownFails; Status = $status; Color = $color
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    })
    Write-Host ("  {0}/{1} passed, {2} failed ({3}s) - {4}" -f $passed, $total, $failed, $sw.Elapsed.TotalSeconds.ToString('n1'), $status) -ForegroundColor $color
}

# --- Extra runner-owned suites (llm-review fixture; zero quota) --------------
foreach ($suite in $extraSuites) {
    Write-Host ""
    Write-Host "=== $($suite.Name) ===" -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = $null
    $runError = $null
    try {
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            $runError = "pwsh not found - llm-review suites require PowerShell 7+"
        }
        else {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $suite.File @($suite.Args) 2>&1 | Out-String
        }
    }
    catch {
        $runError = $_.Exception.Message
    }
    $sw.Stop()

    if ($ShowOutput -and $output) { Write-Host $output }

    $status = $null
    $color = 'Green'
    $total = 0; $passed = 0; $failed = 0

    if ($runError) {
        $status = "ERROR: $runError"
        $color = 'Red'
        $anyRegression = $true
    }
    else {
        # The llm-review runners print "Total: X  Passed: Y  Failed: Z" on ONE
        # line (unlike TestRunner's one-value-per-line), so these are
        # deliberately NOT ^-anchored.
        $mTotal  = [regex]::Match($output, 'Total:\s+(\d+)')
        $mPassed = [regex]::Match($output, 'Passed:\s+(\d+)')
        $mFailed = [regex]::Match($output, 'Failed:\s+(\d+)')

        if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
            $status = "ERROR: could not parse suite summary"
            $color = 'Red'
            $anyRegression = $true
        }
        else {
            $total  = [int]$mTotal.Groups[1].Value
            $passed = [int]$mPassed.Groups[1].Value
            $failed = [int]$mFailed.Groups[1].Value

            if ($failed -gt 0) {
                $status = "REGRESSION ($failed > 0 known)"
                $color = 'Red'
                $anyRegression = $true
                $idx = $output.IndexOf('Failed:')
                if ($idx -ge 0) { Write-Host ($output.Substring($idx)) -ForegroundColor Red }
            }
            else {
                $status = 'PASS'
            }
        }
    }

    $results.Add([PSCustomObject]@{
        Suite = $suite.Name; Total = $total; Passed = $passed; Failed = $failed
        Known = 0; Status = $status; Color = $color
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    })
    Write-Host ("  {0}/{1} passed, {2} failed ({3}s) - {4}" -f $passed, $total, $failed, $sw.Elapsed.TotalSeconds.ToString('n1'), $status) -ForegroundColor $color
}

Write-Host ""
Write-Host "========================================"
Write-Host "All Suites Summary"
Write-Host "========================================"
Write-Host ("{0,-46} {1,5} {2,7} {3,7} {4,6} {5,7}  {6}" -f 'Suite', 'Total', 'Passed', 'Failed', 'Known', 'Seconds', 'Status')
foreach ($r in $results) {
    Write-Host ("{0,-46} {1,5} {2,7} {3,7} {4,6} {5,7}  {6}" -f $r.Suite, $r.Total, $r.Passed, $r.Failed, $r.Known, $r.Seconds, $r.Status) -ForegroundColor $r.Color
}

$gTotal  = ($results | Measure-Object Total -Sum).Sum
$gPassed = ($results | Measure-Object Passed -Sum).Sum
$gFailed = ($results | Measure-Object Failed -Sum).Sum
$gKnown  = ($results | Measure-Object Known -Sum).Sum
Write-Host "----------------------------------------"
Write-Host ("{0,-46} {1,5} {2,7} {3,7} {4,6}" -f 'GRAND TOTAL', $gTotal, $gPassed, $gFailed, $gKnown)

Write-Host ""
if ($anyRegression) {
    Write-Host "OVERALL: REGRESSION - at least one suite exceeds its known-failure baseline" -ForegroundColor Red
    exit 1
}
Write-Host "OVERALL: all suites match expectations ($gPassed/$gTotal passed, $gFailed failures all within baseline)" -ForegroundColor Green
exit 0
