# =============================================================================
# Run-Tests.ps1 - one-shot runner for the tool_name_modifying_strictness suites
#                 in this folder (tool-gate/).
#
# Layout (split by config, one per effective tool-gate mode):
#   config.tool-gate-normal.json   global normal + tool normal
#   config.tool-gate-strict.json   global normal + tool strict  (effective strict)
#   config.tool-gate-loose.json    global normal + tool loose   (effective loose)
#
# Each config drives one XML suite of the same mode. system_paths is ABSOLUTE in
# every mode (asks); only the non-system behavior varies (normal/loose allow,
# strict = full path policy). See
# docs/superpowers/specs/2026-08-26-tool-gate-system-paths-absolute-design.md
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/tool-gate/Run-Tests.ps1
#   powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/tool-gate/Run-Tests.ps1 -Filter strict
#
# Exit code: 1 if any suite has failures, 0 otherwise.
# =============================================================================

param(
    [string]$Filter = "",   # only run suite files whose name contains this
    [switch]$ShowOutput     # stream each suite's full output, not just the result line
)

$ErrorActionPreference = "Stop"

$folder     = $PSScriptRoot
$repoRoot   = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
$testRunner = Join-Path $repoRoot 'src\TestRunner.ps1'

# Explicit run table: suite path (relative to this folder) + its config.
$runs = @(
    @{ Xml = 'test-cases.tool-gate.normal.xml'; Config = (Join-Path $folder 'config.tool-gate-normal.json') },
    @{ Xml = 'test-cases.tool-gate.strict.xml'; Config = (Join-Path $folder 'config.tool-gate-strict.json') },
    @{ Xml = 'test-cases.tool-gate.loose.xml';  Config = (Join-Path $folder 'config.tool-gate-loose.json') }
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
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testRunner -XmlPath $xmlPath -ConfigPath $run.Config 2>&1 | Out-String
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
Write-Host "Tool-Gate Suites Summary"
Write-Host "========================================"
Write-Host ("{0,-40} {1,5} {2,7} {3,7} {4,6}  {5}" -f 'Suite', 'Total', 'Passed', 'Failed', 'Seconds', 'Status')
foreach ($r in $results) {
    Write-Host ("{0,-40} {1,5} {2,7} {3,7} {4,6}  {5}" -f $r.Suite, $r.Total, $r.Passed, $r.Failed, $r.Seconds, $r.Status) -ForegroundColor $r.Color
}

$gTotal  = ($results | Measure-Object Total -Sum).Sum
$gPassed = ($results | Measure-Object Passed -Sum).Sum
$gFailed = ($results | Measure-Object Failed -Sum).Sum
Write-Host "----------------------------------------"
Write-Host ("{0,-40} {1,5} {2,7} {3,7}" -f 'GRAND TOTAL', $gTotal, $gPassed, $gFailed)
# Machine-parseable one-liner for Run-AllTests.ps1 (matches 'Total: X  Passed: Y  Failed: Z')
Write-Host ("Total: {0}  Passed: {1}  Failed: {2}" -f $gTotal, $gPassed, $gFailed)

Write-Host ""
if ($anyFailure) {
    Write-Host "OVERALL: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "OVERALL: tool-gate suites fully green ($gPassed/$gTotal)" -ForegroundColor Green
exit 0
