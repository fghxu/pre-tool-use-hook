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
#     SDD-WrapperEntryShape  : entry ORDER/shape - [1] is the wrapper line (no
#                              origin), statements carry OriginScript/LineNumber/
#                              DisplayText (design 3.2 / 11.1).
#     SDD-NestedFileExpanded : the collapsed nested 'pwsh -File z' path IS expanded
#                              => z's statements surface (design 11.6 / RUL-1).
#     SDD-TrustOnlyNoRead    : config.trustonly.json trusts every scripts\*.ps1 =>
#                              a MODIFYING script must still allow via
#                              trusted_program, proving the file was never read (D9).
#     SDD-StateReset         : the visited-file HT is cleared per classification (7).
#     SDD-LineNumberReason   : a blocking statement's reason carries '(line N)' and the
#                              SubResult exposes LineNumber (appendix A / 8.3).
#     SDD-CompoundSiteB      : the linux-domain SITE B path yields wrapper + prefixed
#                              statements and stays allow for a read-only script (11.5).
#   Validation preflights for the remaining 4.2 rules:
#     SDD-EmptyRunners : runners:[] throws (rule 4 / RUL-6)
#     SDD-BadMaxBytes  : max_file_bytes:0 throws (rule 6)
#     SDD-Defaults     : omitted runners/llm_scope + an in-block _comment_* => defaults (rules 2/4/7)
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
# PRE-FLIGHT 6: SDD-EmptyRunners - explicit `runners: []` must throw (4.2 rule 4 /
# RUL-6): an empty list would arm zero matchers and silently no-op enabled:true.
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.emptyrunner.json")
    Record-Result -Ok $false -Name "SDD-EmptyRunners" -Detail "Load-Config did NOT throw for script_drilldown.runners=[]"
}
catch {
    $ok = $_.Exception.Message -match 'at least one implemented runner'
    if ($ok) {
        Record-Result -Ok $true -Name "SDD-EmptyRunners" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDD-EmptyRunners" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 7: SDD-BadMaxBytes - max_file_bytes=0 must throw (4.2 rule 6).
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badbytes.json")
    Record-Result -Ok $false -Name "SDD-BadMaxBytes" -Detail "Load-Config did NOT throw for script_drilldown.max_file_bytes=0"
}
catch {
    $ok = $_.Exception.Message -match 'max_file_bytes'
    if ($ok) {
        Record-Result -Ok $true -Name "SDD-BadMaxBytes" -Detail "threw as expected: $($_.Exception.Message)"
    }
    else {
        Record-Result -Ok $false -Name "SDD-BadMaxBytes" -Detail "threw but unexpected message: $($_.Exception.Message)"
    }
}

# =============================================================================
# PRE-FLIGHT 8: SDD-Defaults - block without `runners` / `llm_scope` and WITH an
# ignored `_comment_*` INSIDE the block (4.2 rules 2/4/7) must load and compile to
# the documented defaults.
# =============================================================================
try {
    $cfgDef = Load-Config -Path (Join-Path $fixtureDir "config.defaults.json")
    $ddDef = $null
    if ($cfgDef._compiled.PSObject.Properties['scriptDrilldown']) { $ddDef = $cfgDef._compiled.scriptDrilldown }
    if (-not $ddDef) {
        Record-Result -Ok $false -Name "SDD-Defaults" -Detail "_compiled.scriptDrilldown missing for the defaults config"
    }
    else {
        $defRunners = @($ddDef.Runners) -join ','
        if (($defRunners -eq 'powershell') -and ("$($ddDef.LlmScope)" -eq 'count') -and ($ddDef.MaxChainedFiles -eq 3) -and ($ddDef.MaxFileBytes -eq 4096)) {
            Record-Result -Ok $true -Name "SDD-Defaults" -Detail "defaults applied: Runners=$defRunners LlmScope=count caps=3/4096 (_comment_* ignored)"
        }
        else {
            Record-Result -Ok $false -Name "SDD-Defaults" -Detail "wrong defaults: Runners='$defRunners' LlmScope=$($ddDef.LlmScope) caps=$($ddDef.MaxChainedFiles)/$($ddDef.MaxFileBytes)"
        }
    }
}
catch {
    Record-Result -Ok $false -Name "SDD-Defaults" -Detail "Load-Config threw: $($_.Exception.Message)"
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
# PROGRAMMATIC CHECKS (gap coverage added 2026-09-21)
# These four assertions cannot be expressed with TestRunner's static XML
# attributes (they inspect entry ORDER / entry SHAPE / per-entry metadata), so
# they run here in-process, mirroring SDD-AbsolutePath.
# =============================================================================

# Helper: classify one command against a fixture config with the fixture dir as
# the effective cwd (exactly like TestRunner -Cwd).
function Invoke-FixtureClassify {
    param([string]$CfgPath, [string]$Command, [string]$Cwd)
    $cfg = Load-Config -Path $CfgPath
    $sepX = [System.IO.Path]::DirectorySeparatorChar
    $cwdX = ($Cwd -replace '[/\\]', $sepX)
    if (-not $cwdX.EndsWith($sepX)) { $cwdX += $sepX }
    $cfg._cwd = $cwdX
    $cfg._cwdNorm = $cwdX.ToLowerInvariant()
    $raw = [PSCustomObject]@{ tool_name = "Bash"; tool_input = [PSCustomObject]@{ command = $Command } }
    return Invoke-Classify -RawInput $raw -IDE "ClaudeCode" -Config $cfg
}

if (-not $ClassifierLoaded) {
    Record-Result -Ok $false -Name "SDD-WrapperEntryShape" -Detail "Classifier.ps1 not loaded"
    Record-Result -Ok $false -Name "SDD-NestedFileExpanded" -Detail "Classifier.ps1 not loaded"
    Record-Result -Ok $false -Name "SDD-TrustOnlyNoRead" -Detail "Classifier.ps1 not loaded"
    Record-Result -Ok $false -Name "SDD-StateReset" -Detail "Classifier.ps1 not loaded"
}
else {
    # -------------------------------------------------------------------------
    # SDD-WrapperEntryShape - design 3.2 / 11.1: entry [1] is the WRAPPER line
    # ('pwsh ... -File <script>'), shown FIRST, with NO origin metadata; every
    # statement that follows carries OriginScript + the '<script:basename>' prefix.
    # -------------------------------------------------------------------------
    try {
        $rShape = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -NoProfile -File scripts\readonly.ps1" -Cwd $fixtureDir
        $subs = @($rShape.SubResults)
        $shapeProblems = @()
        if ($subs.Count -lt 3) { $shapeProblems += "expected >=3 subs (wrapper + 2 statements), got $($subs.Count)" }
        if ($subs.Count -ge 1) {
            if ("$($subs[0].Command)" -notmatch '(?i)^pwsh .*-File ') { $shapeProblems += "sub[0] is not the wrapper line: '$($subs[0].Command)'" }
            if ($subs[0].PSObject.Properties['OriginScript']) { $shapeProblems += "sub[0] (wrapper) must NOT carry OriginScript" }
            if ($subs[0].Tier -ne 'read_only') { $shapeProblems += "sub[0] tier is '$($subs[0].Tier)', expected read_only" }
        }
        $originSubs = @($subs | Where-Object { $_.PSObject.Properties['OriginScript'] })
        if ($originSubs.Count -eq 0) { $shapeProblems += "no statement carried OriginScript" }
        foreach ($os in $originSubs) {
            if ("$($os.OriginScript)" -ne 'readonly.ps1') { $shapeProblems += "OriginScript '$($os.OriginScript)' != readonly.ps1" }
            if ("$($os.DisplayText)" -notmatch '^<script:readonly\.ps1> ') { $shapeProblems += "DisplayText not prefixed: '$($os.DisplayText)'" }
            if (-not $os.PSObject.Properties['LineNumber']) { $shapeProblems += "statement missing LineNumber: '$($os.Command)'" }
            else {
                # Type check (2026-09-21): LineNumber must be a real integer. A
                # '[int]$x' cast written in ARGUMENT position is parsed as an
                # expandable string by PowerShell, which silently stored a string.
                $lv = $os.LineNumber
                if ($lv -isnot [int] -and $lv -isnot [long]) { $shapeProblems += "LineNumber is $($lv.GetType().Name) ('$lv'), expected an integer" }
            }
        }
        if ($shapeProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-WrapperEntryShape" -Detail "wrapper first ($($subs[0].Command)), $($originSubs.Count) prefixed statements with line numbers"
        }
        else {
            Record-Result -Ok $false -Name "SDD-WrapperEntryShape" -Detail ($shapeProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-WrapperEntryShape" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-NestedFileExpanded - design 11.6 / RUL-1: the COLLAPSED bare path of a
    # nested 'pwsh -File z' statement IS expanded, so z's statements appear with
    # OriginScript='nested-target.ps1' (>=3 subs: wrapper + Write-Host + Get-Content).
    # -------------------------------------------------------------------------
    try {
        $rNest = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -File scripts\calls-nested.ps1" -Cwd $fixtureDir
        $nSubs = @($rNest.SubResults)
        $nProblems = @()
        if ($rNest.Decision -ne 'allow') { $nProblems += "decision=$($rNest.Decision) ($($rNest.Reason))" }
        if ($nSubs.Count -lt 3) { $nProblems += "expected >=3 subs, got $($nSubs.Count)" }
        $nOrigin = @($nSubs | Where-Object { $_.PSObject.Properties['OriginScript'] -and "$($_.OriginScript)" -eq 'nested-target.ps1' })
        if ($nOrigin.Count -eq 0) { $nProblems += "no sub carries OriginScript='nested-target.ps1' (nested file not expanded)" }
        if ($nProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-NestedFileExpanded" -Detail "$($nSubs.Count) subs incl. $($nOrigin.Count) from nested-target.ps1"
        }
        else {
            Record-Result -Ok $false -Name "SDD-NestedFileExpanded" -Detail ($nProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-NestedFileExpanded" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-TrustOnlyNoRead - design D9 / 13.1 (config.trustonly.json): the fixture
    # trusts EVERY scripts\*.ps1 via trusted_programs_regex, so a MODIFYING script
    # must still ALLOW with tier trusted_program. If the engine read the file it
    # would ask (Copy-Item) - so this is the "trusted paths are never read" proof.
    # -------------------------------------------------------------------------
    try {
        $rTrust = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.trustonly.json") `
            -Command "pwsh -NoProfile -File scripts\modifying.ps1" -Cwd $fixtureDir
        $tProblems = @()
        if ($rTrust.Decision -ne 'allow') { $tProblems += "decision=$($rTrust.Decision) ($($rTrust.Reason)) - the trusted script was READ" }
        $tTier = @($rTrust.SubResults | Where-Object { "$($_.Tier)" -eq 'trusted_program' })
        if ($tTier.Count -eq 0) { $tProblems += "no SubResult carries tier trusted_program" }
        if ($tProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-TrustOnlyNoRead" -Detail "modifying.ps1 allowed via trusted_program (file never read)"
        }
        else {
            Record-Result -Ok $false -Name "SDD-TrustOnlyNoRead" -Detail ($tProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-TrustOnlyNoRead" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-StateReset - design 7: the visited-file HT is per tool call. Classify a
    # LOOP command (ask), then the SAME single-file command again: the second must
    # be allow, proving Reset-ScriptDrilldownState runs at STEP 4 (a leaked HT
    # would turn it into a bogus 'recursive script invocation detected' ask).
    # -------------------------------------------------------------------------
    try {
        $null = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -File scripts\loop-a.ps1" -Cwd $fixtureDir
        $rAfter = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -NoProfile -File scripts\readonly.ps1" -Cwd $fixtureDir
        if ($rAfter.Decision -eq 'allow') {
            Record-Result -Ok $true -Name "SDD-StateReset" -Detail "visited-set cleared between classifications (2nd classify allow)"
        }
        else {
            Record-Result -Ok $false -Name "SDD-StateReset" -Detail "2nd classify leaked state: $($rAfter.Decision) - $($rAfter.Reason)"
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-StateReset" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-LineNumberReason - design appendix A / 8.3: a blocking statement's reason
    # must carry the '(line N)' suffix AND the SubResult must expose LineNumber, so
    # the operator can jump to the offending line. The XML case can only assert one
    # substring, so both halves are checked here.
    # -------------------------------------------------------------------------
    try {
        $rLine = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -NoProfile -File scripts\modifying.ps1" -Cwd $fixtureDir
        $lProblems = @()
        if ($rLine.Decision -ne 'ask') { $lProblems += "decision=$($rLine.Decision)" }
        if ("$($rLine.Reason)" -notmatch '\(line 6\)') { $lProblems += "reason lacks '(line 6)': $($rLine.Reason)" }
        $srMod = @($rLine.SubResults | Where-Object { "$($_.Reason)" -match 'contains modifying command' })
        if ($srMod.Count -eq 0) { $lProblems += "no SubResult carries the modifying reason" }
        else {
            $ln = $srMod[0].PSObject.Properties['LineNumber']
            if (-not $ln) { $lProblems += "SubResult lacks LineNumber" }
            else {
                $lnVal = $srMod[0].LineNumber
                if ($lnVal -ne 6) { $lProblems += "LineNumber=$lnVal, expected 6" }
            }
            if ("$($srMod[0].Reason)" -notmatch '(?i)Copy-Item') { $lProblems += "reason does not name Copy-Item" }
        }
        if ($lProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-LineNumberReason" -Detail "reason + SubResult carry line 6"
        }
        else {
            Record-Result -Ok $false -Name "SDD-LineNumberReason" -Detail ($lProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-LineNumberReason" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-CompoundSiteB - design 11.5: a compound (linux-domain) command reaches
    # the regex SITE B. Entries must be [1] the leading segment, [2] the wrapper
    # line, [3..] the script's prefixed statements - and the decision must be allow
    # (the 2026-09-17 safety property: an UNTRUSTED script must never be allowed
    # without inspection; here it is inspected and read-only).
    # -------------------------------------------------------------------------
    try {
        $rComp = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "cd c:\work; pwsh -NoProfile -File scripts\readonly.ps1" -Cwd $fixtureDir
        $cSubs = @($rComp.SubResults)
        $cProblems = @()
        if ($rComp.Decision -ne 'allow') { $cProblems += "decision=$($rComp.Decision) ($($rComp.Reason))" }
        $cWrapper = @($cSubs | Where-Object { "$($_.Command)" -match '(?i)^pwsh .*-File ' })
        if ($cWrapper.Count -eq 0) { $cProblems += "no wrapper-line SubResult (SITE B wrapper entry missing)" }
        $cStmts = @($cSubs | Where-Object { $_.PSObject.Properties['OriginScript'] })
        if ($cStmts.Count -eq 0) { $cProblems += "no script-origin SubResult (SITE B statements missing)" }
        if ($cProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-CompoundSiteB" -Detail "$($cSubs.Count) subs: wrapper + $($cStmts.Count) script statements"
        }
        else {
            Record-Result -Ok $false -Name "SDD-CompoundSiteB" -Detail ($cProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-CompoundSiteB" -Detail "threw: $($_.Exception.Message)"
    }

    # -------------------------------------------------------------------------
    # SDD-FailureSingleSubResult - design RUL-4 / 3.2 / 6.4: an expansion FAILURE
    # (here: not-found) is a SINGLE SubResult whose Command is the script PATH
    # (today's shape; the outer wrapper is suppressed via IsTerminal), whose Reason
    # IS the section-6 cause string, and which is a KNOWN blocker
    # (MatchedPattern='script-drilldown') so the AST-arbiter gate stays closed.
    # -------------------------------------------------------------------------
    try {
        $rFail = Invoke-FixtureClassify -CfgPath (Join-Path $fixtureDir "config.json") `
            -Command "pwsh -File scripts\no-such.ps1" -Cwd $fixtureDir
        $fSubs = @($rFail.SubResults)
        $fProblems = @()
        if ($rFail.Decision -ne 'ask') { $fProblems += "decision=$($rFail.Decision)" }
        if ($fSubs.Count -ne 1) { $fProblems += "expected exactly 1 SubResult (RUL-4), got $($fSubs.Count)" }
        else {
            if ("$($fSubs[0].Command)" -ne 'scripts\no-such.ps1') { $fProblems += "SubResult.Command='$($fSubs[0].Command)', expected the script path" }
            if ("$($fSubs[0].MatchedPattern)" -ne 'script-drilldown') { $fProblems += "MatchedPattern='$($fSubs[0].MatchedPattern)', expected 'script-drilldown'" }
            if ("$($fSubs[0].Reason)" -notmatch '^script file not found: scripts\\no-such\.ps1') { $fProblems += "Reason is not the cause string: $($fSubs[0].Reason)" }
        }
        if ($fProblems.Count -eq 0) {
            Record-Result -Ok $true -Name "SDD-FailureSingleSubResult" -Detail "single path-only SubResult, script-drilldown blocker, cause-string reason"
        }
        else {
            Record-Result -Ok $false -Name "SDD-FailureSingleSubResult" -Detail ($fProblems -join "; ")
        }
    }
    catch {
        Record-Result -Ok $false -Name "SDD-FailureSingleSubResult" -Detail "threw: $($_.Exception.Message)"
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
