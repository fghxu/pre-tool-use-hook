# Run-Tests.ps1 - one-shot runner for the ALL-GATED duplicate suites in this folder.
#
# Layout (split by config, 2026-07-27):
#   normal/   config.normal.json  = all domains have strictness_gated; every
#                                   risk:low command moved from modifying to
#                                   strictness_gated. Drives 4 suites.
#   strict/   config.strict.json  = same + global modifying_strictness = strict
#                                   and editable_paths.linux reduced to /tmp/.
#                                   Drives the redirect-strict suite only.
#
# Strict-mode behavior of the strictness_gated tier itself needs NO separate
# config: the SG-strict suite passes -Strictness strict to TestRunner.ps1, which
# overrides the GLOBAL modifying_strictness in memory after loading
# normal/config.normal.json (global strict then forces every domain).
# strict/config.strict.json exists only because the redirect suite also needs
# the editable_paths divergence.
#
# test-fullpipe.xml is deliberately NOT duplicated: it spawns Hook.ps1 per case,
# which always loads the live config.json and cannot be pointed at these configs.
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1
#   powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1 -Filter strictness
#   powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1 -ShowOutput
#
# Exit code: 1 if any suite has failures, 0 otherwise (no KnownFails baselines
# here - the all-gated config is expected to be fully green).

param(
    [string]$Filter = "",   # only run suite files whose name contains this
    [switch]$ShowOutput     # stream each suite's full output, not just the result line
)

$ErrorActionPreference = "Stop"

$folder     = $PSScriptRoot
$repoRoot   = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$testRunner = Join-Path $repoRoot 'src\TestRunner.ps1'
$normalCfg  = Join-Path $folder 'normal\config.normal.json'
$strictCfg  = Join-Path $folder 'strict\config.strict.json'

# Explicit run table: suite path (relative to this folder) + its config + extra args.
$runs = @(
    @{ Xml = 'normal\test-cases.xml';                         Config = $normalCfg; Extra = @() },
    @{ Xml = 'normal\test-cases.strictness-gated.normal.xml'; Config = $normalCfg; Extra = @() },
    @{ Xml = 'normal\test-cases.strictness-gated.strict.xml'; Config = $normalCfg; Extra = @('-Strictness', 'strict') },
    @{ Xml = 'normal\test-cases.trustedpattern.xml';          Config = $normalCfg; Extra = @('-Cwd', 'C:\git\repo') },
    @{ Xml = 'strict\test-cases.redirect-strict.xml';         Config = $strictCfg; Extra = @() }
)

if ($Filter) {
    $runs = @($runs | Where-Object { $_.Xml -like "*$Filter*" })
}
if ($runs.Count -eq 0) {
    Write-Host "No suites matched filter '$Filter'" -ForegroundColor Red
    exit 1
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$anyFailure = $false

foreach ($run in $runs) {
    $xmlPath = Join-Path $folder $run.Xml
    $name    = $run.Xml

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = $null
    $runError = $null
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testRunner -XmlPath $xmlPath -ConfigPath $run.Config @($run.Extra) 2>&1 | Out-String
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
        $anyFailure = $true
    }
    else {
        $mTotal  = [regex]::Match($output, '(?m)^Total:\s+(\d+)')
        $mPassed = [regex]::Match($output, '(?m)^Passed:\s+(\d+)')
        $mFailed = [regex]::Match($output, '(?m)^Failed:\s+(\d+)')

        if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
            $status = "ERROR: could not parse suite summary"
            $color = 'Red'
            $anyFailure = $true
        }
        else {
            $total  = [int]$mTotal.Groups[1].Value
            $passed = [int]$mPassed.Groups[1].Value
            $failed = [int]$mFailed.Groups[1].Value

            if ($failed -gt 0) {
                $status = "FAIL ($failed failed)"
                $color = 'Red'
                $anyFailure = $true
                $idx = $output.IndexOf('Failed Tests:')
                if ($idx -ge 0) { Write-Host ($output.Substring($idx)) -ForegroundColor Red }
            }
            else {
                $status = 'PASS'
            }
        }
    }

    $results.Add([PSCustomObject]@{
        Suite = $name; Total = $total; Passed = $passed; Failed = $failed
        Status = $status; Color = $color
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    })
    Write-Host ("  {0}/{1} passed, {2} failed ({3}s) - {4}" -f $passed, $total, $failed, $sw.Elapsed.TotalSeconds.ToString('n1'), $status) -ForegroundColor $color
}

Write-Host ""
Write-Host "========================================"
Write-Host "All-Gated Suites Summary"
Write-Host "========================================"
Write-Host ("{0,-50} {1,5} {2,7} {3,7} {4,6}  {5}" -f 'Suite', 'Total', 'Passed', 'Failed', 'Seconds', 'Status')
foreach ($r in $results) {
    Write-Host ("{0,-50} {1,5} {2,7} {3,7} {4,6}  {5}" -f $r.Suite, $r.Total, $r.Passed, $r.Failed, $r.Seconds, $r.Status) -ForegroundColor $r.Color
}

$gTotal  = ($results | Measure-Object Total -Sum).Sum
$gPassed = ($results | Measure-Object Passed -Sum).Sum
$gFailed = ($results | Measure-Object Failed -Sum).Sum
Write-Host "----------------------------------------"
Write-Host ("{0,-50} {1,5} {2,7} {3,7}" -f 'GRAND TOTAL', $gTotal, $gPassed, $gFailed)

Write-Host ""
if ($anyFailure) {
    Write-Host "OVERALL: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "OVERALL: all-gated suites fully green ($gPassed/$gTotal)" -ForegroundColor Green
exit 0
