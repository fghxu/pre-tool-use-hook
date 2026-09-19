# =============================================================================
# Run-Tests.ps1 - trusted_programs_regex fixture runner (R1)
# =============================================================================
#
# WHAT THIS FILE IS
#   Dedicated suite for the trusted_programs_regex feature. Small isolated
#   fixture config, runs in seconds, no network, no GUI.
#
# FEATURE UNDER TEST (config key: trusted_programs_regex)
#   Regex entries matched AFTER the literal trusted_programs list, against the
#   normalized program token (lowercased, '/' -> '\'), unanchored -match,
#   case-insensitive. A match grants tier=trusted_program with reason
#   "trusted program (regex): <pattern>". Option B arg-scan and sibling
#   worst-case-wins are unchanged.
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/trusted-programs-regex/Run-Tests.ps1
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

# Dot-source the REAL engine modules (for pre-flight Load-Config checks)
. (Join-Path $srcDir "ConfigLoader.ps1")

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
# PRE-FLIGHT 1: TPR-BadRegex - invalid regex entry -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badregex.json")
    Record-Result -Ok $false -Name "TPR-BadRegex" -Detail "Load-Config did NOT throw for trusted_programs_regex=['(']"
}
catch {
    $ok = $_.Exception.Message -match 'trusted_programs_regex'
    if ($ok) {
        Record-Result -Ok $true -Name "TPR-BadRegex" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "TPR-BadRegex" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 2: TPR-CompiledPresent - valid config compiles regex entries
# =============================================================================
try {
    $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
    $hasProp = [bool](Get-Member -InputObject $cfg._compiled -Name 'trustedProgramRegexes' -MemberType NoteProperty -ErrorAction SilentlyContinue)
    if (-not $hasProp) {
        Record-Result -Ok $false -Name "TPR-CompiledPresent" -Detail "_compiled.trustedProgramRegexes missing after Load-Config"
    }
    else {
        $count = @($cfg._compiled.trustedProgramRegexes).Count
        if ($count -ne 2) {
            Record-Result -Ok $false -Name "TPR-CompiledPresent" -Detail "expected 2 compiled regex entries, got $count"
        }
        else {
            # Spot-check: the src pattern must match a future name and miss a .cmd
            $re = @($cfg._compiled.trustedProgramRegexes)[0]
            $m1 = [bool]("src\brand-new.ps1" -match $re)
            $m2 = [bool]("tools\notps1.cmd" -match $re)
            if ($m1 -and (-not $m2)) {
                Record-Result -Ok $true -Name "TPR-CompiledPresent" -Detail "2 entries compiled; spot-checks pass"
            }
            else {
                Record-Result -Ok $false -Name "TPR-CompiledPresent" -Detail "spot-check failed: src\brand-new.ps1 matched=$m1, tools\notps1.cmd matched=$m2 (want true/false)"
            }
        }
    }
}
catch {
    Record-Result -Ok $false -Name "TPR-CompiledPresent" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# XML CASES via the real TestRunner (powershell.exe 5.1, like production)
# =============================================================================
$runner = Join-Path $srcDir "TestRunner.ps1"
$xml    = Join-Path $fixtureDir "test-cases.xml"
$cfgJson = Join-Path $fixtureDir "config.json"

Write-Host ""
Write-Host "--- XML cases (TestRunner, powershell.exe) ---" -ForegroundColor Cyan

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -XmlPath $xml -ConfigPath $cfgJson 2>&1 | Out-String
$childExit = $LASTEXITCODE

$mTotal  = [regex]::Match($output, '(?m)^Total:\s+(\d+)')
$mPassed = [regex]::Match($output, '(?m)^Passed:\s+(\d+)')
$mFailed = [regex]::Match($output, '(?m)^Failed:\s+(\d+)')

if (-not ($mTotal.Success -and $mPassed.Success -and $mFailed.Success)) {
    Record-Result -Ok $false -Name "TPR-XmlSuite" -Detail "could not parse TestRunner summary (exit=$childExit). Output tail: $($output.Substring([Math]::Max(0, $output.Length - 800)))"
}
else {
    $xTotal  = [int]$mTotal.Groups[1].Value
    $xPassed = [int]$mPassed.Groups[1].Value
    $xFailed = [int]$mFailed.Groups[1].Value

    if ($xFailed -gt 0) {
        # Surface the failing cases in our own failure list (one entry per case)
        $failIdx = $output.IndexOf('Failed Tests:')
        $detail = if ($failIdx -ge 0) { $output.Substring($failIdx).Trim() } else { "exit=$childExit" }
        Record-Result -Ok $false -Name "TPR-XmlSuite" -Detail "$xFailed/$xTotal XML cases failed. $detail"
    }
    else {
        Record-Result -Ok $true -Name "TPR-XmlSuite" -Detail "$xPassed/$xTotal XML cases passed"
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
