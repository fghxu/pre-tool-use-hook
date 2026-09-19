# =============================================================================
# Run-Tests.ps1 - editable_paths deletion authority fixture runner (R2)
# =============================================================================
#
# WHAT THIS FILE IS
#   Dedicated suite for the Step 0g-delete feature. Small isolated fixture
#   config, runs in seconds, no network, no GUI.
#
# FEATURE UNDER TEST (Step 0g-delete in Resolver.ps1)
#   A deletion whose EVERY target canonicalizes under an editable path / CWD /
#   temp form is ALLOWED (tier editable_delete). System, foreign, mixed, and
#   unresolvable targets still ask (fail-closed). Deleters stay registered as
#   modifying/high so the carve-out (not a tier change) is what flips them.
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/editable-delete/Run-Tests.ps1
#   Exit code 0 = all green. Exit code 1 = at least one check failed.
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.
# =============================================================================

param()

$ErrorActionPreference = "Stop"

# Paths
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"

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
# XML CASES via the real TestRunner (powershell.exe 5.1, like production)
# CWD = d:\work (a NON-editable dir whose subtree is always editable). This keeps
# the two allow branches distinct: absolute c:\temp\... targets hit the
# "editable path" branch, while the relative target in case 8 (log.txt) anchors
# to d:\work\log.txt and hits the "under current directory" branch. If CWD were
# c:\temp itself, every absolute c:\temp target would be mislabeled as CWD.
# =============================================================================
$runner  = Join-Path $srcDir "TestRunner.ps1"
$xml     = Join-Path $fixtureDir "test-cases.xml"
$cfgJson = Join-Path $fixtureDir "config.json"

Write-Host ""
Write-Host "--- XML cases (TestRunner, powershell.exe, Cwd=d:\work) ---" -ForegroundColor Cyan

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -XmlPath $xml -ConfigPath $cfgJson -Cwd "d:\work" 2>&1 | Out-String
$childExit = $LASTEXITCODE

$mTotal  = [regex]::Match($output, '(?m)^Total:\s+(\d+)')
$mPassed = [regex]::Match($output, '(?m)^Passed:\s+(\d+)')
$mFailed = [regex]::Match($output, '(?m)^Failed:\s+(\d+)')

if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
    Record-Result -Ok $false -Name "ED-XmlSuite" -Detail "could not parse TestRunner summary (exit=$childExit). Output tail: $($output.Substring([Math]::Max(0, $output.Length - 800)))"
}
else {
    $xTotal  = [int]$mTotal.Groups[1].Value
    $xPassed = [int]$mPassed.Groups[1].Value
    $xFailed = [int]$mFailed.Groups[1].Value

    if ($xFailed -gt 0) {
        # Surface the failing cases in our own failure list (one entry per case)
        $failIdx = $output.IndexOf('Failed Tests:')
        $detail = if ($failIdx -ge 0) { $output.Substring($failIdx).Trim() } else { "exit=$childExit" }
        Record-Result -Ok $false -Name "ED-XmlSuite" -Detail "$xFailed/$xTotal XML cases failed. $detail"
    }
    else {
        Record-Result -Ok $true -Name "ED-XmlSuite" -Detail "$xPassed/$xTotal XML cases passed"
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
