# =============================================================================
# Run-Tests.ps1 - safe_expressions regex allowlists fixture runner (R3)
# =============================================================================
#
# WHAT THIS FILE IS
#   Dedicated suite for the safe_expressions.*_allowlist_regex feature. Small
#   isolated fixture config, runs in seconds, no network, no GUI.
#
# FEATURE UNDER TEST (config keys:
#   safe_expressions.dotnet_method_allowlist_regex,
#   safe_expressions.dotnet_static_method_allowlist_regex,
#   safe_expressions.dotnet_static_method_denylist,          (2026-09-19)
#   safe_expressions.dotnet_static_method_denylist_regex)    (2026-09-19)
#   Allow regex entries tried AFTER the exact HashSets miss, case-insensitive,
#   anchored -match. Static branch checks the written key then the reflected
#   full-name key. A miss on both stays ask (fail-closed). The static DENYLIST
#   is checked FIRST and outranks every allow path (exact + regex); exact deny
#   entries may be Type::Method or bare Method (any type).
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/safe-expr-regex/Run-Tests.ps1
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
# PRE-FLIGHT 1: SER-BadRegex - invalid regex entry -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badregex.json")
    Record-Result -Ok $false -Name "SER-BadRegex" -Detail "Load-Config did NOT throw for dotnet_static_method_allowlist_regex=['^(']"
}
catch {
    $ok = $_.Exception.Message -match 'dotnet_static_method_allowlist_regex'
    if ($ok) {
        Record-Result -Ok $true -Name "SER-BadRegex" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SER-BadRegex" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 1b: SDEN-BadDenyRegex - invalid DENY regex entry -> Load-Config throws
# (fail-fast parity with the allowlist regex keys; RED until ConfigLoader compiles it)
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.baddenylregex.json")
    Record-Result -Ok $false -Name "SDEN-BadDenyRegex" -Detail "Load-Config did NOT throw for dotnet_static_method_denylist_regex=['^(']"
}
catch {
    $ok = $_.Exception.Message -match 'dotnet_static_method_denylist_regex'
    if ($ok) {
        Record-Result -Ok $true -Name "SDEN-BadDenyRegex" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDEN-BadDenyRegex" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 2: SER-CompiledPresent - valid config compiles both regex arrays
# =============================================================================
try {
    $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
    $hasStatic = [bool](Get-Member -InputObject $cfg -Name '_dotnetStaticMethodAllowlistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)
    $hasInstance = [bool](Get-Member -InputObject $cfg -Name '_dotnetMethodAllowlistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)
    if (-not ($hasStatic -and $hasInstance)) {
        Record-Result -Ok $false -Name "SER-CompiledPresent" -Detail "_dotnetStaticMethodAllowlistRegex present=$hasStatic, _dotnetMethodAllowlistRegex present=$hasInstance (both expected)"
    }
    else {
        $staticRe = @($cfg._dotnetStaticMethodAllowlistRegex)[0]
        $instanceRe = @($cfg._dotnetMethodAllowlistRegex)[0]
        # Spot-checks: static regex must hit both spellings and miss Compile;
        # instance regex must hit tochararray and miss mutate. (2026-09-19: the
        # R3 row now includes replace/split/escape/unescape, so Replace is no
        # longer a valid miss probe - Compile is.)
        $m1 = [bool]("regex::ismatch" -match $staticRe)
        $m2 = [bool]("system.text.regularexpressions.regex::matches" -match $staticRe)
        $m3 = [bool]("regex::compile" -match $staticRe)
        $m4 = [bool]("tochararray" -match $instanceRe)
        $m5 = [bool]("mutate" -match $instanceRe)
        if ($m1 -and $m2 -and (-not $m3) -and $m4 -and (-not $m5)) {
            Record-Result -Ok $true -Name "SER-CompiledPresent" -Detail "both arrays compiled; spot-checks pass"
        }
        else {
            Record-Result -Ok $false -Name "SER-CompiledPresent" -Detail "spot-check failed: staticWritten=$m1 staticReflected=$m2 staticMiss=$m3 (want false) instanceHit=$m4 instanceMiss=$m5 (want false)"
        }
    }
}
catch {
    Record-Result -Ok $false -Name "SER-CompiledPresent" -Detail "Load-Config threw: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 3: SDEN-Anchoring - D1 proof: NO allow row may match known-bad keys
# (unanchored rows would let 'int::' substring-match point:: / printqueue:: etc.)
# =============================================================================
try {
    $cfg = Load-Config -Path (Join-Path $fixtureDir "config.json")
    $rows = @($cfg.safe_expressions.dotnet_static_method_allowlist_regex)
    # Known-bad keys: type names that CONTAIN an allowlisted type name as a substring.
    # NOTE: only method names OUTSIDE the Class-C families (parse/get/is/to/from) are
    # valid here - a Get*/Parse* etc. on ANY type is allowed BY DESIGN (threat model,
    # section 11 Risk 1), so e.g. point::getx would match the get family legitimately.
    $badKeys = @(
        'system.drawing.point::x',          # contains 'int::' (point) - primitive row hazard
        'printqueue::foo',                  # contains 'int::' - primitive row hazard
        'profile::read',                    # contains 'file::read' - file Class-B row hazard
        'notmath::abs',                     # contains 'math::abs' tail - math row hazard
        'myregex::compile'                  # contains 'regex::' but Compile is not in the R3 alternation
    )
    $violations = @()
    foreach ($row in $rows) {
        foreach ($bk in $badKeys) {
            if ($bk -match $row) { $violations += ("'{0}' matched by row '{1}'" -f $bk, $row) }
        }
    }
    # Deny rows must NOT over-deny pure neighbors (spot-checks).
    $denyRows = @($cfg.safe_expressions.dotnet_static_method_denylist_regex)
    foreach ($dr in $denyRows) {
        if ('system.io.file::getattributes' -match $dr) { $violations += "deny row over-matches file::GetAttributes: '$dr'" }
        if ('system.math::abs' -match $dr) { $violations += "deny row over-matches math::Abs: '$dr'" }
    }
    if ($violations.Count -gt 0) {
        Record-Result -Ok $false -Name "SDEN-Anchoring" -Detail ("D1 anchoring violated: " + ($violations -join ' | '))
    }
    else {
        Record-Result -Ok $true -Name "SDEN-Anchoring" -Detail "$($rows.Count) allow rows x $($badKeys.Count) bad keys: no substring over-matches; deny rows do not over-deny pure neighbors"
    }
}
catch {
    Record-Result -Ok $false -Name "SDEN-Anchoring" -Detail "Load-Config threw: $($_.Exception.Message)"
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
    Record-Result -Ok $false -Name "SER-XmlSuite" -Detail "could not parse TestRunner summary (exit=$childExit). Output tail: $($output.Substring([Math]::Max(0, $output.Length - 800)))"
}
else {
    $xTotal  = [int]$mTotal.Groups[1].Value
    $xPassed = [int]$mPassed.Groups[1].Value
    $xFailed = [int]$mFailed.Groups[1].Value

    if ($xFailed -gt 0) {
        $failIdx = $output.IndexOf('Failed Tests:')
        $detail = if ($failIdx -ge 0) { $output.Substring($failIdx).Trim() } else { "exit=$childExit" }
        Record-Result -Ok $false -Name "SER-XmlSuite" -Detail "$xFailed/$xTotal XML cases failed. $detail"
    }
    else {
        Record-Result -Ok $true -Name "SER-XmlSuite" -Detail "$xPassed/$xTotal XML cases passed"
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
