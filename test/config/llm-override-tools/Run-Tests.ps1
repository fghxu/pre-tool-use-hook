# =============================================================================
# Run-Tests.ps1 - one-shot runner for the T33 tool-gate suites (design
# 2026-10-16, D5) in this folder (llm-override-tools/). Proves the
# strictness_gated_tool_name gate is UNAFFECTED by global normal_override_llm:
# the gate mode comes from global + tool_name_modifying_strictness, and the new
# value is a normal-FAMILY value (never forces strict, never loosens).
#
# Layout (mirrors test/config/test-strictness-gate/tool-gate):
#   config.ov-tools-strict.json  global normal_override_llm + tool STRICT
#   config.ov-tools-normal.json  global normal_override_llm + tool ABSENT
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File test/config/llm-override-tools/Run-Tests.ps1
#   powershell.exe -ExecutionPolicy Bypass -File test/config/llm-override-tools/Run-Tests.ps1 -Filter strict
#
# Exit code: 1 if any suite has failures, 0 otherwise.
# =============================================================================

param(
    [string]$Filter = "",   # only run suite files whose name contains this
    [switch]$ShowOutput     # stream each suite's full output, not just the result line
)

$ErrorActionPreference = "Stop"

$folder     = $PSScriptRoot
$repoRoot   = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$testRunner = Join-Path $repoRoot 'src\TestRunner.ps1'

# Explicit run table: suite path (relative to this folder) + its config.
$runs = @(
    @{ Xml = 'test-cases.ov-tools.strict.xml'; Config = (Join-Path $folder 'config.ov-tools-strict.json') },
    @{ Xml = 'test-cases.ov-tools.normal.xml'; Config = (Join-Path $folder 'config.ov-tools-normal.json') }
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
Write-Host "Override-Tools (T33) Suites Summary"
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
Write-Host "OVERALL: override-tools suites fully green ($gPassed/$gTotal)" -ForegroundColor Green
exit 0
