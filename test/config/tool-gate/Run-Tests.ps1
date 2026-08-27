# =============================================================================
# Run-Tests.ps1 - strictness_gated_tool_name fixture runner
# =============================================================================
#
# WHAT THIS FILE IS
#   The dedicated test suite for the strictness-gated tool-name gate.
#   Deliberately SEPARATE from the main suites: small fixture configs, runs in
#   seconds, no network, no GUI.
#
# FEATURE UNDER TEST (config key: strictness_gated_tool_name)
#   v2 (2026-08-26): system_paths is ABSOLUTE - no tool (gated or ignored) may
#   write to a system_paths target without an ask. Gated tools are governed by
#   tool_name_modifying_strictness (strict|normal|loose, default normal):
#     effective mode = strict if EITHER global OR tool strictness is strict,
#     else the tool value. Global loose NEVER loosens the tool gate.
#   Gate behavior by effective mode (tool in strictness_gated_tool_name):
#     strict -> full path policy (system/foreign ask; editable+CWD allow;
#               unextractable path asks - fail closed)
#     normal -> system_paths ask; all other paths allow; unextractable allows
#     loose  -> system_paths ask; all other paths allow; unextractable allows
#   ignore_tool_name: skipped as before EXCEPT a payload path resolving into
#   system_paths asks (the absolute rule applies to ignored tools too).
#   apply_patch / edit_files: paths are extracted best-effort from patch TEXT.
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/tool-gate/Run-Tests.ps1
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
$hookPath   = Join-Path $srcDir "Hook.ps1"

# Dot-source the REAL engine modules
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "Classifier.ps1")

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

# Load the mode fixtures once
$cfgNormal     = Load-Config -Path (Join-Path $fixtureDir "config.normal.json")
$cfgLoose      = Load-Config -Path (Join-Path $fixtureDir "config.loose.json")
$cfgStrict     = Load-Config -Path (Join-Path $fixtureDir "config.strict.json")
$cfgToolLoose  = Load-Config -Path (Join-Path $fixtureDir "config.toolloose.json")
$cfgToolStrict = Load-Config -Path (Join-Path $fixtureDir "config.toolstrict.json")

# =============================================================================
# PRE-FLIGHT 1: ToolGate-BadType - key holds a string -> Load-Config throws
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badtype.json")
    Record-Result -Ok $false -Name "ToolGate-BadType" -Detail "Load-Config did NOT throw for strictness_gated_tool_name='Write' (string)"
}
catch {
    $ok = $_.Exception.Message -match 'strictness_gated_tool_name'
    Record-Result -Ok $ok -Name "ToolGate-BadType" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 2: ToolGate-OverlapIntercept - Write in intercept + gated -> throw
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.overlap.json")
    Record-Result -Ok $false -Name "ToolGate-OverlapIntercept" -Detail "Load-Config did NOT throw for Write in both intercept_tool_name and strictness_gated_tool_name"
}
catch {
    $ok = $_.Exception.Message -match 'strictness_gated_tool_name'
    Record-Result -Ok $ok -Name "ToolGate-OverlapIntercept" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 3: ToolGate-OverlapIgnore - Write in ignore + gated -> throw
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.ignoreoverlap.json")
    Record-Result -Ok $false -Name "ToolGate-OverlapIgnore" -Detail "Load-Config did NOT throw for Write in both ignore_tool_name and strictness_gated_tool_name"
}
catch {
    $ok = $_.Exception.Message -match 'strictness_gated_tool_name'
    Record-Result -Ok $ok -Name "ToolGate-OverlapIgnore" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT 4: ToolGate-KeyAbsent - key missing -> no throw (optional key)
# =============================================================================
try {
    $cfgRaw = Get-Content (Join-Path $fixtureDir "config.normal.json") -Raw | ConvertFrom-Json
    $cfgRaw.PSObject.Properties.Remove('strictness_gated_tool_name')
    $tmpNoKey = Join-Path $env:TEMP ("toolgate-nokey-" + [guid]::NewGuid().ToString("N") + ".json")
    $cfgRaw | ConvertTo-Json -Depth 10 | Set-Content $tmpNoKey -Encoding UTF8
    try {
        $cfgNoKey = Load-Config -Path $tmpNoKey
        # Absent key = feature off: Write is no longer gated and is in no other
        # list, so the gate must not skip it (falls through to unknown).
        $f = Test-ToolNameFilter -ToolName "Write" -Config $cfgNoKey
        $ok = ($f -eq "unknown")
        Record-Result -Ok $ok -Name "ToolGate-KeyAbsent" -Detail "key absent -> loaded fine; Test-ToolNameFilter(Write)='$f' (expected 'unknown' - no gate, no list entry)"
    }
    finally {
        Remove-Item $tmpNoKey -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Record-Result -Ok $false -Name "ToolGate-KeyAbsent" -Detail "Load-Config threw with key absent: $($_.Exception.Message)"
}

# =============================================================================
# UNIT 1: ToolGate-NormalSkip - normal mode, non-system path -> gated tool skips
# =============================================================================
$rawInput = [PSCustomObject]@{ tool_name = "Write"; tool_input = [PSCustomObject]@{ file_path = "C:\temp\notes.txt" } }
$r = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGate-NormalSkip" -Detail "normal mode: Write C:\temp -> Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow+skipped)"

# =============================================================================
# UNIT 2: ToolGate-LooseSkip - global loose + tool normal -> non-system skips
# =============================================================================
$r = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $cfgLoose
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGate-LooseSkip" -Detail "global loose + tool normal: Write C:\temp -> Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow+skipped; global loose does NOT loosen the gate)"

# =============================================================================
# UNIT 3: ToolGate-StrictClassify - strict global -> gated tool path-checked
# =============================================================================
$rawInputEdit = [PSCustomObject]@{ tool_name = "Write"; tool_input = [PSCustomObject]@{ file_path = "C:\temp\notes.txt" } }
$r = Invoke-Classify -RawInput $rawInputEdit -IDE "ClaudeCode" -Config $cfgStrict
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $false)) -Name "ToolGate-StrictClassify" -Detail "strict global: Write C:\temp -> Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow via editable path, NOT skipped)"

# =============================================================================
# UNIT 4: ToolGate-IgnoreUnaffected - ignored tool still skips in strict mode
# =============================================================================
$r = Test-ToolNameFilter -ToolName "Read" -Config $cfgStrict
Record-Result -Ok ($r -eq "skip") -Name "ToolGate-IgnoreUnaffected" -Detail "strict mode: Test-ToolNameFilter(Read)='$r' (expected 'skip' - ignore list is never gated)"

# =============================================================================
# UNIT 5: ToolGate-InterceptUnaffected - intercepted command tool classifies
# =============================================================================
$rawBash = [PSCustomObject]@{ tool_name = "Bash"; tool_input = [PSCustomObject]@{ command = "ls /tmp" } }
$r = Invoke-Classify -RawInput $rawBash -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.Reason -match "read-only")) -Name "ToolGate-InterceptUnaffected" -Detail "normal mode: Bash 'ls /tmp' -> Decision=$($r.Decision) Reason='$($r.Reason)' (expected allow via command classification)"

# =============================================================================
# UNIT 6: ToolGate-UnknownUnaffected - tool in NO list still unknown
# =============================================================================
$r = Test-ToolNameFilter -ToolName "SomeOtherTool" -Config $cfgNormal
Record-Result -Ok ($r -eq "unknown") -Name "ToolGate-UnknownUnaffected" -Detail "normal mode: Test-ToolNameFilter(SomeOtherTool)='$r' (expected 'unknown')"

# =============================================================================
# V2 — system_paths is ABSOLUTE: gated tool to a system path ASKS in every mode
# =============================================================================

# --- normal mode ---
$rawSys = [PSCustomObject]@{ tool_name = "Write"; tool_input = [PSCustomObject]@{ file_path = "C:\Windows\evil.dll" } }
$r = Invoke-Classify -RawInput $rawSys -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-NormalSystemAsks" -Detail "normal: Write C:\Windows\evil.dll -> Decision=$($r.Decision) (expected ask; system_paths is absolute)"

# --- loose global + tool normal (effective normal) ---
$r = Invoke-Classify -RawInput $rawSys -IDE "ClaudeCode" -Config $cfgLoose
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-LooseGlobalSystemAsks" -Detail "global loose + tool normal: Write C:\Windows -> Decision=$($r.Decision) (expected ask; system_paths absolute)"

# --- tool loose (effective loose) ---
$r = Invoke-Classify -RawInput $rawSys -IDE "ClaudeCode" -Config $cfgToolLoose
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-ToolLooseSystemAsks" -Detail "tool loose: Write C:\Windows -> Decision=$($r.Decision) (expected ask; even loose may not touch system_paths)"

# --- strict global ---
$r = Invoke-Classify -RawInput $rawSys -IDE "ClaudeCode" -Config $cfgStrict
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-StrictSystemAsks" -Detail "strict: Write C:\Windows -> Decision=$($r.Decision) (expected ask)"

# =============================================================================
# V2 — foreign (non-editable, non-CWD) paths: ask ONLY in strict
# =============================================================================
$rawForeign = [PSCustomObject]@{ tool_name = "Write"; tool_input = [PSCustomObject]@{ file_path = "D:\work\x.txt" } }
$r = Invoke-Classify -RawInput $rawForeign -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-NormalForeignSkips" -Detail "normal: Write D:\work -> Decision=$($r.Decision) (expected allow/skip; only system_paths enforced)"

$r = Invoke-Classify -RawInput $rawForeign -IDE "ClaudeCode" -Config $cfgToolStrict
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-StrictForeignAsks" -Detail "tool strict: Write D:\work -> Decision=$($r.Decision) (expected ask; strict = full path policy)"

$r = Invoke-Classify -RawInput $rawForeign -IDE "ClaudeCode" -Config $cfgToolLoose
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-LooseForeignAllows" -Detail "tool loose: Write D:\work -> Decision=$($r.Decision) (expected allow/skip)"

# =============================================================================
# V2 — editable / CWD paths allow in every mode
# =============================================================================
$r = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $cfgToolStrict
Record-Result -Ok ($r.Decision -eq "allow") -Name "ToolGateV2-StrictEditableAllows" -Detail "tool strict: Write C:\temp -> Decision=$($r.Decision) (expected allow; editable path)"

# =============================================================================
# V2 — unextractable path: strict asks (fail-closed), normal/loose allow
# =============================================================================
$rawNoPath = [PSCustomObject]@{ tool_name = "NoPathTool"; tool_input = [PSCustomObject]@{ foo = "bar" } }
$r = Invoke-Classify -RawInput $rawNoPath -IDE "ClaudeCode" -Config $cfgToolStrict
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-StrictUnextractableAsks" -Detail "tool strict: NoPathTool (no path mapping) -> Decision=$($r.Decision) (expected ask; fail-closed)"

$r = Invoke-Classify -RawInput $rawNoPath -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-NormalUnextractableSkips" -Detail "normal: NoPathTool (no path) -> Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow/skip; fail-open)"

# =============================================================================
# V2 — ignore_tool_name: system_paths STILL asks; other paths skip
# =============================================================================
$rawIgnoreSys = [PSCustomObject]@{ tool_name = "IgnorePathTool"; tool_input = [PSCustomObject]@{ file_path = "C:\Windows\x.dll" } }
$r = Invoke-Classify -RawInput $rawIgnoreSys -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-IgnoredSystemAsks" -Detail "ignored tool with system path: IgnorePathTool C:\Windows -> Decision=$($r.Decision) (expected ask; system_paths absolute even for ignored tools)"

$rawIgnoreOk = [PSCustomObject]@{ tool_name = "IgnorePathTool"; tool_input = [PSCustomObject]@{ file_path = "C:\temp\x.txt" } }
$r = Invoke-Classify -RawInput $rawIgnoreOk -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-IgnoredNonSystemSkips" -Detail "ignored tool with temp path: Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow/skip)"

$rawIgnoreNoPath = [PSCustomObject]@{ tool_name = "Read"; tool_input = [PSCustomObject]@{ file_path = "C:\Windows\x.dll" } }
$r = Invoke-Classify -RawInput $rawIgnoreNoPath -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-IgnoredNoMappingSkips" -Detail "ignored tool with NO path mapping: Read (payload path ignored) -> Decision=$($r.Decision) (expected allow/skip; only mapped paths are scanned)"

# =============================================================================
# V2 — apply_patch: best-effort path extraction from patch TEXT
# =============================================================================
$patchSys = "*** Begin Patch`n*** Update File: C:\Windows\system32\drivers\etc\hosts`n@@`n+x`n*** End Patch"
$rawPatchSys = [PSCustomObject]@{ tool_name = "apply_patch"; tool_input = [PSCustomObject]@{ patch = $patchSys } }
$r = Invoke-Classify -RawInput $rawPatchSys -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-PatchSystemAsks" -Detail "apply_patch with system path in patch text -> Decision=$($r.Decision) (expected ask; patch text scanned)"

$patchOk = "*** Begin Patch`n*** Update File: C:\temp\notes.txt`n@@`n+x`n*** End Patch"
$rawPatchOk = [PSCustomObject]@{ tool_name = "apply_patch"; tool_input = [PSCustomObject]@{ patch = $patchOk } }
$r = Invoke-Classify -RawInput $rawPatchOk -IDE "ClaudeCode" -Config $cfgNormal
Record-Result -Ok (($r.Decision -eq "allow") -and ($r.IsSkipped -eq $true)) -Name "ToolGateV2-PatchTempSkips" -Detail "apply_patch with temp path -> Decision=$($r.Decision) IsSkipped=$($r.IsSkipped) (expected allow/skip)"

# =============================================================================
# V2 — inheritance pinning
# =============================================================================
# global loose + tool strict => STRICT (tool strict wins even under global loose)
$cfgGlobalLooseToolStrictRaw = Get-Content (Join-Path $fixtureDir "config.toolstrict.json") -Raw | ConvertFrom-Json
$cfgGlobalLooseToolStrictRaw.global_modifying_strictness = "loose"
$tmpGLTS = Join-Path $env:TEMP ("toolgate-glts-" + [guid]::NewGuid().ToString("N") + ".json")
$cfgGlobalLooseToolStrictRaw | ConvertTo-Json -Depth 10 | Set-Content $tmpGLTS -Encoding UTF8
try {
    $cfgGLTS = Load-Config -Path $tmpGLTS
    $r = Invoke-Classify -RawInput $rawForeign -IDE "ClaudeCode" -Config $cfgGLTS
    Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-GlobalLooseToolStrict" -Detail "global loose + tool strict: Write D:\work -> Decision=$($r.Decision) (expected ask; strict wins)"
}
finally { Remove-Item $tmpGLTS -Force -ErrorAction SilentlyContinue }

# global strict + tool loose => STRICT (global strict wins even under tool loose)
$cfgGlobalStrictToolLooseRaw = Get-Content (Join-Path $fixtureDir "config.toolloose.json") -Raw | ConvertFrom-Json
$cfgGlobalStrictToolLooseRaw.global_modifying_strictness = "strict"
$tmpGSTL = Join-Path $env:TEMP ("toolgate-gstl-" + [guid]::NewGuid().ToString("N") + ".json")
$cfgGlobalStrictToolLooseRaw | ConvertTo-Json -Depth 10 | Set-Content $tmpGSTL -Encoding UTF8
try {
    $cfgGSTL = Load-Config -Path $tmpGSTL
    $r = Invoke-Classify -RawInput $rawForeign -IDE "ClaudeCode" -Config $cfgGSTL
    Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-GlobalStrictToolLoose" -Detail "global strict + tool loose: Write D:\work -> Decision=$($r.Decision) (expected ask; strict wins)"
}
finally { Remove-Item $tmpGSTL -Force -ErrorAction SilentlyContinue }

# =============================================================================
# V2 — tool_name_modifying_strictness validation
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badstrictness.json")
    Record-Result -Ok $false -Name "ToolGateV2-BadStrictnessValue" -Detail "Load-Config did NOT throw for tool_name_modifying_strictness='bogus'"
}
catch {
    $ok = $_.Exception.Message -match 'tool_name_modifying_strictness'
    Record-Result -Ok $ok -Name "ToolGateV2-BadStrictnessValue" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# absent key => defaults to normal (gate active)
try {
    $cfgRaw = Get-Content (Join-Path $fixtureDir "config.normal.json") -Raw | ConvertFrom-Json
    $cfgRaw.PSObject.Properties.Remove('tool_name_modifying_strictness')
    $tmpNoKey = Join-Path $env:TEMP ("toolgate-nokey2-" + [guid]::NewGuid().ToString("N") + ".json")
    $cfgRaw | ConvertTo-Json -Depth 10 | Set-Content $tmpNoKey -Encoding UTF8
    try {
        $cfgNoKey = Load-Config -Path $tmpNoKey
        $r = Invoke-Classify -RawInput $rawSys -IDE "ClaudeCode" -Config $cfgNoKey
        Record-Result -Ok ($r.Decision -eq "ask") -Name "ToolGateV2-DefaultStrictnessNormal" -Detail "tool_name_modifying_strictness absent -> defaults normal: Write C:\Windows -> Decision=$($r.Decision) (expected ask)"
    }
    finally { Remove-Item $tmpNoKey -Force -ErrorAction SilentlyContinue }
}
catch {
    Record-Result -Ok $false -Name "ToolGateV2-DefaultStrictnessNormal" -Detail "Load-Config threw with key absent: $($_.Exception.Message)"
}

# =============================================================================
# FULLPIPE 1: ToolGate-Fullpipe-NormalSystemAsks - system path asks (absolute)
# =============================================================================
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

try {
    $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $fixtureDir "config.normal.json"
    $payload = (@{
        tool_name       = "Write"
        tool_input      = @{ file_path = "C:\Windows\evil.dll"; content = "x" }
        hook_event_name = "preToolUse"
        timestamp       = "1790000000000"
    } | ConvertTo-Json -Compress -Depth 5)
    $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
    $exitCode = $LASTEXITCODE
    Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

    $out = $stdout | ConvertFrom-Json -ErrorAction Stop
    $decision = $out.hookSpecificOutput.permissionDecision
    # v2 KEY: even in normal mode, a gated tool writing to a SYSTEM path asks.
    $ok = ($decision -eq "ask") -and ($exitCode -eq 0)
    Record-Result -Ok $ok -Name "ToolGate-Fullpipe-NormalSystemAsks" -Detail "normal mode: Write C:\Windows\evil.dll -> decision=$decision exit=$exitCode (expected ask+0; system_paths is absolute)"
}
catch {
    Record-Result -Ok $false -Name "ToolGate-Fullpipe-NormalSystemAsks" -Detail "threw: $($_.Exception.Message) | stdout: $stdout"
}

# =============================================================================
# FULLPIPE 2: ToolGate-Fullpipe-StrictClassifies - Write system path -> ask
# =============================================================================
try {
    $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $fixtureDir "config.strict.json"
    $payload = (@{
        tool_name       = "Write"
        tool_input      = @{ file_path = "C:\Windows\evil.dll"; content = "x" }
        hook_event_name = "preToolUse"
        timestamp       = "1790000000000"
    } | ConvertTo-Json -Compress -Depth 5)
    $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
    $exitCode = $LASTEXITCODE
    Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

    $out = $stdout | ConvertFrom-Json -ErrorAction Stop
    $decision = $out.hookSpecificOutput.permissionDecision
    $ok = ($decision -eq "ask") -and ($exitCode -eq 0)
    Record-Result -Ok $ok -Name "ToolGate-Fullpipe-StrictClassifies" -Detail "strict mode: Write C:\Windows\evil.dll -> decision=$decision exit=$exitCode (expected ask+0 via path policy)"
}
catch {
    Record-Result -Ok $false -Name "ToolGate-Fullpipe-StrictClassifies" -Detail "threw: $($_.Exception.Message) | stdout: $stdout"
}

# =============================================================================
# FULLPIPE 3: ToolGate-Fullpipe-StrictAllows - Write editable path -> allow
# =============================================================================
try {
    $env:PRETOOLHOOK_CONFIG_PATH = Join-Path $fixtureDir "config.strict.json"
    $payload = (@{
        tool_name       = "Write"
        tool_input      = @{ file_path = "C:\temp\notes.txt"; content = "x" }
        hook_event_name = "preToolUse"
        timestamp       = "1790000000000"
    } | ConvertTo-Json -Compress -Depth 5)
    $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
    $exitCode = $LASTEXITCODE
    Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

    $out = $stdout | ConvertFrom-Json -ErrorAction Stop
    $decision = $out.hookSpecificOutput.permissionDecision
    $ok = ($decision -eq "allow") -and ($exitCode -eq 0)
    Record-Result -Ok $ok -Name "ToolGate-Fullpipe-StrictAllows" -Detail "strict mode: Write C:\temp\notes.txt -> decision=$decision exit=$exitCode (expected allow+0 via path policy - classified, not skipped)"
}
catch {
    Record-Result -Ok $false -Name "ToolGate-Fullpipe-StrictAllows" -Detail "threw: $($_.Exception.Message) | stdout: $stdout"
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "Total: $($script:total)  Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) {
    Write-Host "Failed checks:"
    $script:failures | ForEach-Object { Write-Host "  - $($_.Name)" }
    exit 1
}
exit 0
