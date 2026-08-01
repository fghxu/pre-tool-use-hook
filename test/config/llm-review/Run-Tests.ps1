# Run-Tests.ps1 - llm_second_opinion fixture runner
# In-process classify+merge tests (mode=classify) plus end-to-end Hook.ps1
# process tests (mode=fullpipe). LLM verdicts are injected via
# PRETOOLHOOK_LLMREVIEW_MOCK - no network call ever happens.
#
# Per-case XML attributes:
#   expected         allow|ask (required) - final decision
#   category         group label (required)
#   reason           free text, shown on failure
#   level            all|complex_commands|complex_remote (default complex_remote)
#   min              complex_min_subcommands override (default 2)
#   enabled          true|false (default true)
#   mock             modifying|read-only|garbage|down (unset = env var cleared)
#   in-scope         true|false - asserted against Log.in_scope (optional)
#   verdict          asserted against Log.verdict (optional)
#   effect           asserted against Log.effect (optional)
#   reason-contains  substring asserted on the final Reason (optional)
#   mode             classify (default) | fullpipe (spawns src/Hook.ps1)
#
# Run from repo root:  pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1

$ErrorActionPreference = "Stop"
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"
$hookPath   = Join-Path $srcDir "Hook.ps1"
$configPath = Join-Path $fixtureDir "config.json"

# Dot-source engine modules
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "Classifier.ps1")

# TDD scaffold: auto-fail classify cases while LlmReview.ps1 does not exist
$LlmReviewLoaded = $false
if (Test-Path (Join-Path $srcDir "LlmReview.ps1")) {
    . (Join-Path $srcDir "LlmReview.ps1")
    $LlmReviewLoaded = $true
}

$config = Load-Config -Path $configPath

# TDD scaffold: until ConfigLoader compiles the block, stub it so the per-case
# override lines below have a non-null object to mutate (Enabled=$false there is
# irrelevant - every case sets Enabled/Level/ComplexMinSubcommands explicitly).
if (-not $config._compiled.llmSecondOpinion) {
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'llmSecondOpinion' -Force -Value (
        [PSCustomObject]@{
            Enabled               = $false
            Level                 = 'complex_remote'
            BaseUri               = 'http://127.0.0.1:3030'
            Model                 = 'glm-5.2'
            ApiKey                = ''
            TimeoutMs             = 12000
            Temperature           = 0.0
            MaxTokens             = 16
            ComplexMinSubcommands = 2
            RemoteIndicators      = @()
        })
}

# Child-process engine for fullpipe cases (same family as the current process)
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

[xml]$xml = Get-Content (Join-Path $fixtureDir "test-cases.xml") -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

$total = 0; $passed = 0; $failed = 0; $failures = @()

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

# ---- Pre-flight: bad-level config must be rejected fail-closed ----
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badlevel.json")
    Record-Result -Ok $false -Name "LlmConfig-BadLevel" -Detail "Load-Config did NOT throw for level='bogus'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_second_opinion\.level'
    Record-Result -Ok $ok -Name "LlmConfig-BadLevel" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# ---- Pre-flight: ConvertTo-LlmVerdict parser unit checks (spec 5.3 layers) ----
$parserCases = @(
    @{ Name = 'LlmParser-BareTrue';      Raw = 'true';                                 WantVerdict = 'modifying'; WantRecovered = $false },
    @{ Name = 'LlmParser-BareFalseCase'; Raw = "  FALSE`n";                            WantVerdict = 'read-only'; WantRecovered = $false },
    @{ Name = 'LlmParser-Json';          Raw = '{"verdict":"modifying"}';              WantVerdict = 'modifying'; WantRecovered = $false },
    @{ Name = 'LlmParser-LastLine';      Raw = "reasoning about the command`nfalse";   WantVerdict = 'read-only'; WantRecovered = $true },
    @{ Name = 'LlmParser-Garbage';       Raw = 'I think this is safe but I am unsure'; WantVerdict = 'unusable';  WantRecovered = $false },
    @{ Name = 'LlmParser-Empty';         Raw = '';                                     WantVerdict = 'unusable';  WantRecovered = $false }
)
foreach ($pc in $parserCases) {
    if (-not $LlmReviewLoaded) {
        Record-Result -Ok $false -Name $pc.Name -Detail "LlmReview.ps1 not loaded (TDD red phase)"
        continue
    }
    $got = ConvertTo-LlmVerdict -RawContent $pc.Raw
    $ok = ($got.Verdict -eq $pc.WantVerdict) -and ($got.Recovered -eq $pc.WantRecovered)
    Record-Result -Ok $ok -Name $pc.Name -Detail "raw='$($pc.Raw)' => verdict=$($got.Verdict) recovered=$($got.Recovered) (wanted $($pc.WantVerdict)/$($pc.WantRecovered))"
}

# ---- Per-case loop ----
foreach ($tc in $testCases) {
    $name = $tc.category
    $mode = if ($tc.HasAttribute('mode')) { $tc.GetAttribute('mode') } else { 'classify' }
    $reasonContains = if ($tc.HasAttribute('reason-contains')) { $tc.GetAttribute('reason-contains') } else { $null }

    # Resolve command text (handles CDATA)
    $cmdNode = $tc.'copilot-command'
    if ($cmdNode -is [System.Xml.XmlElement]) { $command = $cmdNode.InnerText } else { $command = "$cmdNode" }
    $command = $command.Trim()

    $toolName = "Bash"
    $toolNameNode = $tc.SelectSingleNode('tool-name')
    if ($toolNameNode -and $toolNameNode.InnerText.Trim()) { $toolName = $toolNameNode.InnerText.Trim() }

    # Mock env var
    if ($tc.HasAttribute('mock')) { $env:PRETOOLHOOK_LLMREVIEW_MOCK = $tc.GetAttribute('mock') }
    else { Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue }

    if ($mode -eq 'fullpipe') {
        # ---- End-to-end: spawn the real hook process ----
        $payload = (@{
            tool_name       = $toolName
            tool_input      = @{ command = $command }
            hook_event_name = 'preToolUse'
            timestamp       = '1790000000000'
        } | ConvertTo-Json -Compress -Depth 5)
        $env:PRETOOLHOOK_CONFIG_PATH = $configPath
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

        try {
            $out = $stdout | ConvertFrom-Json -ErrorAction Stop
            $decision = $out.hookSpecificOutput.permissionDecision
            $reason   = "$($out.hookSpecificOutput.permissionDecisionReason)"
            $ok = ($decision -eq $tc.expected) -and ($exitCode -eq 0)
            if ($ok -and $reasonContains) { $ok = $reason.Contains($reasonContains) }
            Record-Result -Ok $ok -Name $name -Detail "cmd: $command | expected $($tc.expected)+exit0 got $decision+exit$exitCode | reason: $reason"
        }
        catch {
            Record-Result -Ok $false -Name $name -Detail "cmd: $command | stdout not JSON: $stdout"
        }
        continue
    }

    # ---- In-process classify + merge ----
    # Per-case overrides on the compiled block (reset each case)
    $llmCfg = $config._compiled.llmSecondOpinion
    $llmCfg.Enabled               = if ($tc.HasAttribute('enabled')) { [bool]::Parse($tc.GetAttribute('enabled')) } else { $true }
    $llmCfg.Level                 = if ($tc.HasAttribute('level')) { $tc.GetAttribute('level') } else { 'complex_remote' }
    $llmCfg.ComplexMinSubcommands = if ($tc.HasAttribute('min')) { [int]$tc.GetAttribute('min') } else { 2 }

    $rawInput = [PSCustomObject]@{
        tool_name  = $toolName
        tool_input = [PSCustomObject]@{ command = $command }
    }

    $result = $null; $llmLog = $null
    try {
        $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        # Mirror the Hook.ps1 gate
        if ($llmCfg.Enabled) {
            if (-not $LlmReviewLoaded) { throw "LlmReview.ps1 not loaded (TDD red phase)" }
            $outcome = Invoke-LlmReview -ClassifyResult $result -Config $config
            $result = $outcome.Result
            $llmLog = $outcome.Log
        }
    }
    catch {
        $result = [PSCustomObject]@{ Decision = "error"; Reason = $_.Exception.Message }
    }
    Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

    $ok = ($result.Decision -eq $tc.expected)
    $detail = "cmd: $command | expected $($tc.expected) got $($result.Decision) | reason: $($result.Reason)"

    if ($ok -and $reasonContains) {
        $ok = ("$($result.Reason)").Contains($reasonContains)
        if (-not $ok) { $detail += " | reason missing '$reasonContains'" }
    }
    if ($ok -and $tc.HasAttribute('in-scope')) {
        $wantScope = [bool]::Parse($tc.GetAttribute('in-scope'))
        $gotScope = if ($llmLog) { [bool]$llmLog.in_scope } else { $false }
        $ok = ($gotScope -eq $wantScope)
        if (-not $ok) { $detail += " | in_scope expected $wantScope got $gotScope" }
    }
    if ($ok -and $tc.HasAttribute('verdict')) {
        $got = if ($llmLog) { "$($llmLog.verdict)" } else { '<null>' }
        $ok = ($got -eq $tc.GetAttribute('verdict'))
        if (-not $ok) { $detail += " | verdict expected $($tc.GetAttribute('verdict')) got $got" }
    }
    if ($ok -and $tc.HasAttribute('effect')) {
        $got = if ($llmLog) { "$($llmLog.effect)" } else { '<null>' }
        $ok = ($got -eq $tc.GetAttribute('effect'))
        if (-not $ok) { $detail += " | effect expected $($tc.GetAttribute('effect')) got $got" }
    }
    Record-Result -Ok $ok -Name $name -Detail $detail
}

Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================"
Write-Host "LLM-Review Fixture Run Complete"
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
if ($failures.Count -gt 0) {
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $($f.Name)" -ForegroundColor Red }
}
Write-Host "========================================"
if ($failed -gt 0) { exit 1 } else { exit 0 }
