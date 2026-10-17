# =============================================================================
# Run-Ov-Preflights.ps1 - config/validator/guard preflights for the
# normal_override_llm suite (design doc A1/A2, PF-1..PF-6).
#
# HOW TO RUN (repo root):
#   pwsh -NoProfile -File test/config/llm-review/Run-Ov-Preflights.ps1
# Exit 0 = all green. Exit 1 = at least one check failed.
#
# CHECKS
#   PF-1  config.ov.json loads (4th enum value legal at global + domain + entry)
#   PF-2  a typo'd global value ("normal_override_llictness") FAILS Load-Config
#         with a message listing the legal values
#   PF-3  tool_name_modifying_strictness REJECTS the 4th value (stays 3-value)
#   PF-4  Get-EffectiveStrictness(Linux, config.ov.json)      = normal_override_llm (inherit)
#   PF-5  Get-EffectiveStrictness(Linux, config.ov-strictdomain) = strict (domain wins)
#   PF-6  Get-EffectiveStrictness(PowerShell, config.ov.json) = normal (explicit opt-out)
#
# RED PHASE: PF-1/4 fail at load (validator rejects the value, the 2026-10-16
# throw message says "must be 'normal', 'strict', or 'loose'"); PF-2/3 PASS
# only if the 4th value is still illegal (PF-2) / tool_name unchanged (PF-3);
# PF-5/6 fail at load. Record actuals, then implement A1/A2 and re-run.
#
# Temp files are written under the repo temp/ dir and removed on exit.
# =============================================================================
param()
$ErrorActionPreference = "Stop"

$fixtureDir = $PSScriptRoot
$repoRoot   = Resolve-Path (Join-Path $fixtureDir "..\..\..")
$srcDir     = Join-Path $repoRoot "src"
$tempDir    = Join-Path $repoRoot "temp"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")

$script:Total = 0; $script:Passed = 0; $script:FailedNames = @()
function Record([bool]$Ok, [string]$Name, [string]$Detail) {
    $script:Total++
    if ($Ok) { $script:Passed++ } else {
        $script:FailedNames += $Name
        Write-Host "FAIL [$Name]"; Write-Host "  $Detail"
    }
}

$baseConfigPath = Join-Path $fixtureDir "config.ov.json"
$tempFiles = @()

try {
    # PF-1: base fixture loads with the 4th value at global + domain(entry) level
    try {
        $cfg = Load-Config -Path $baseConfigPath
        Record $true "PF-1-BaseLoads" ""
    }
    catch {
        Record $false "PF-1-BaseLoads" "Load-Config threw: $($_.Exception.Message)"
        $cfg = $null
    }

    # PF-2: typo'd global value must throw
    $bad2 = Join-Path $tempDir "ov-pf2-bad-global.json"
    $tempFiles += $bad2
    (Get-Content $baseConfigPath -Raw) -replace '"normal_override_llm"', '"normal_override_llictness"' | Set-Content -Path $bad2 -Encoding UTF8
    try {
        Load-Config -Path $bad2 | Out-Null
        Record $false "PF-2-BadGlobalThrows" "load succeeded but must throw"
    }
    catch {
        $msg = "$($_.Exception.Message)"
        $ok = $msg -match 'global_modifying_strictness'
        Record $ok "PF-2-BadGlobalThrows" "threw OK but message lacks the key name: $msg"
    }

    # PF-3: tool_name_modifying_strictness must REJECT the 4th value
    $bad3 = Join-Path $tempDir "ov-pf3-bad-toolname.json"
    $tempFiles += $bad3
    (Get-Content $baseConfigPath -Raw) -replace '"global_modifying_strictness": "normal_override_llm"', '"global_modifying_strictness": "normal", "tool_name_modifying_strictness": "normal_override_llm"' | Set-Content -Path $bad3 -Encoding UTF8
    try {
        Load-Config -Path $bad3 | Out-Null
        Record $false "PF-3-ToolNameRejects4th" "load succeeded but tool_name must stay 3-value"
    }
    catch {
        $msg = "$($_.Exception.Message)"
        $ok = $msg -match 'tool_name_modifying_strictness'
        Record $ok "PF-3-ToolNameRejects4th" "threw OK but message lacks the key name: $msg"
    }

    # PF-4/5/6: Get-EffectiveStrictness resolution (guard + inherit + opt-out)
    if ($cfg) {
        $got = Get-EffectiveStrictness -Config $cfg -Domain "Linux"
        Record ($got -eq 'normal_override_llm') "PF-4-InheritOverride" "Linux (no key) expected normal_override_llm got '$got'"

        $cfgStrict = Load-Config -Path (Join-Path $fixtureDir "config.ov-strictdomain.json")
        $got5 = Get-EffectiveStrictness -Config $cfgStrict -Domain "Linux"
        Record ($got5 -eq 'strict') "PF-5-DomainStrictWins" "Linux explicit strict expected strict got '$got5'"

        $got6 = Get-EffectiveStrictness -Config $cfg -Domain "PowerShell"
        Record ($got6 -eq 'normal') "PF-6-PsExplicitOptOut" "PowerShell explicit key expected normal got '$got6'"
    }
    else {
        foreach ($n in @("PF-4-InheritOverride", "PF-5-DomainStrictWins", "PF-6-PsExplicitOptOut")) {
            Record $false $n "skipped: base config did not load (PF-1 failed)"
        }
    }
}
finally {
    foreach ($f in $tempFiles) { Remove-Item $f -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "OV-PREFLIGHTS: Total $Total / Passed $Passed / Failed $($Total - $Passed)"
# Machine-parseable one-liner for Run-AllTests.ps1 (matches 'Total: X  Passed: Y  Failed: Z')
Write-Host ("Total: {0}  Passed: {1}  Failed: {2}" -f $Total, $Passed, ($Total - $Passed))
if ($FailedNames.Count -gt 0) { $FailedNames | ForEach-Object { Write-Host "  FAILED: $_" }; exit 1 }
exit 0
