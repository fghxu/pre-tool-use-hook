# =============================================================================
# Run-LlmLiveTests.ps1 - LIVE end-to-end test against the REAL LLM gateway
# =============================================================================
#
# WHAT THIS IS
#   A small, OPT-IN end-to-end suite that calls the REAL LLM gateway (default:
#   glm-5.2 @ http://127.0.0.1:3030) through the production code path
#   (Get-LlmReviewVerdict in src/LlmReview.ps1) and, for one case, through the
#   real spawned Hook.ps1. It complements the mock-server suite
#   (Run-LlmCallTests.ps1): the mock proves OUR code; this proves the code
#   against the REAL model (request shape accepted, answers parseable,
#   verdicts sensible).
#
# COST / SAFETY
#   - COSTS QUOTA: ~2k tokens per run of the 7-case smoke file (test-llm-live.xml);
#     ~8-12k for the 25-case matrix (-XmlPath .../test-llm-live-large.xml).
#   - Commands are only CLASSIFIED by the LLM as text - NEVER executed.
#   - OPT-IN: nothing runs this except you, deliberately.
#   - The 25-case matrix file reuses the mock matrix's most model-interesting
#     commands TRUTH-KEYED (not mock-keyed) - it measures the MODEL (which
#     sub-commands it flags), while the offline suites pin OUR code.
#
# HOW TO RUN
#   From the repo root (gateway must be up):
#       pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1
#   Against a different gateway/model:
#       pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1 -BaseUri http://host:port -Model some-model
#   A/B probe of the output-contract levers (2026-08-03; both GLM-5.2 and
#   deepseek-v4-flash were answering with analysis prose -> unusable):
#       ... -JsonMode        - hardened prompt + response_format json_object (attributed cases)
#       ... -LegacyPrompt    - the PRE-hardening V2 prompt (control)
#   Run the same file three ways and compare clean-verdict counts.
#
# HOW TO READ THE OUTPUT
#   Unlike the offline suites, EVERY case prints a LIVE line as it completes:
#       LIVE [Live-ReadOnly-Local] verdict=read-only latency=4820ms raw='false' - OK
#   Attributed cases also show the parsed index list: indices=[2].
#   ...so you can watch what the model actually answered. Failures also print
#   as FAIL [<name>] + detail, and the summary lists them.
#   Exit 0 = all 7 green. Exit 1 = a case failed OR the gateway is unreachable
#   (you asked for a live test; nothing ran is a failure, not a skip).
#
# CASE ATTRIBUTES (direct mode)
#   expect-verdict   read-only|modifying|unusable|down (required)
#   subcommands      semicolon-separated numbered list; when present the case
#                    runs ATTRIBUTED (V2 prompt + <sub_commands> block) and the
#                    list is passed to Get-LlmReviewVerdict -SubCommands.
#                    When absent the case stays phase-I (V1 binary prompt).
#   expect-indices   comma-separated indices the verdict MUST carry ("2",
#                    "1,2"); "" means an explicitly EMPTY list (model answered
#                    {"modifying":[]}). Absent = indices not asserted.
#
# RETRY POLICY (principled)
#   Each case retries ONCE only on transient outcomes ('down' or 'unusable' -
#   infrastructure/parse flake). A WRONG VERDICT is never retried: that is the
#   model-quality signal you want to see.
# =============================================================================

param(
    [string]$BaseUri   = 'http://127.0.0.1:3030',
    [string]$Model     = 'deepseek-v4-flash',
    [int]$TimeoutMs    = 30000,   # live models under load can be slow; generous budget
    [string]$XmlPath   = "",
    [switch]$JsonMode,            # A/B probe: constrain responses to JSON (attributed calls only)
    [switch]$LegacyPrompt         # A/B probe: use the PRE-hardening V2 prompt (no negative example / first-char rule)
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths. This file lives in test/config/llm-review/http; src/ is four levels up.
# ---------------------------------------------------------------------------
$httpDir    = $PSScriptRoot
$fixtureDir = Split-Path $httpDir -Parent
$srcDir     = Join-Path $httpDir "..\..\..\..\src"
$hookPath   = Join-Path $srcDir "Hook.ps1"

# ---------------------------------------------------------------------------
# CRITICAL: disarm the offline mock - this suite exists to hit the REAL thing.
# ---------------------------------------------------------------------------
Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue
Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

# Dot-source the production verdict client under test.
. (Join-Path $srcDir "LlmReview.ps1")

# A/B probe switch: swap the module's V2 prompt to the PRE-hardening version
# (no negative example / first-character rule). The shipped hardened prompt is
# the default. Direct-mode cases use whichever is active; the fullpipe child
# re-dot-sources the module so it always uses the shipped prompt.
if ($LegacyPrompt) {
    $script:LlmSystemPromptV2 = ($script:LlmSystemPromptV2 -split 'NEGATIVE EXAMPLE')[0].TrimEnd()
    Write-Host "A/B: using the PRE-hardening (plain) V2 prompt." -ForegroundColor Yellow
}

# Child-process engine for the fullpipe case (same family as this process).
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } { 'powershell' }

# ---------------------------------------------------------------------------
# PRE-FLIGHT: is the gateway even up? Probe GET {BaseUri}/v1/models (cheap,
# no quota). If unreachable: loud message + exit 1 (an opt-in live test that
# cannot run is a failure, not a silent skip).
# ---------------------------------------------------------------------------
Write-Host "Probing live gateway at $BaseUri (model: $Model) ..."
try {
    $null = Invoke-RestMethod -Uri "$BaseUri/v1/models" -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host "Gateway is UP. Running live cases (this spends a small amount of quota)."
}
catch {
    Write-Host ""
    Write-Host "LIVE GATEWAY UNREACHABLE at $BaseUri - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Start the gateway (or pass -BaseUri to point elsewhere) and re-run. NO TESTS RAN." -ForegroundColor Red
    exit 1
}
Write-Host ""

# ---------------------------------------------------------------------------
# Load the cases.
# ---------------------------------------------------------------------------
$xmlFile = if ($XmlPath) { $XmlPath } else { Join-Path $httpDir "test-llm-live.xml" }
[xml]$xml = Get-Content $xmlFile -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# Counters + failure list (same reporting shape as the other suites).
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

# ---------------------------------------------------------------------------
# The compiled-block shape Get-LlmReviewVerdict consumes, pointed at the LIVE
# gateway. Level/RemoteIndicators are unused by the direct call but kept in
# shape for fidelity.
# ---------------------------------------------------------------------------
$llmCfg = [PSCustomObject]@{
    Enabled               = $true
    Level                 = 'all'
    BaseUri               = $BaseUri
    Model                 = $Model
    ApiKey                = ''
    TimeoutMs             = $TimeoutMs
    Temperature           = 0.0
    LlmResponseMaxTokens  = 16
    ComplexMinSubcommands = 2
    RemoteIndicators      = @()
    # Attributed verdicts are PER-CASE here: a case with a subcommands attr
    # flips this to $true for that call (set in the loop below). Default off
    # keeps the 5 phase-I cases on the V1 binary prompt byte-identically.
    AttributedVerdicts    = $false
    # JSON mode off by default; -JsonMode switch turns it on for the run (the
    # A/B probe exercises both). Only takes effect on attributed calls.
    JsonMode              = $JsonMode
}

# =============================================================================
# MAIN LOOP
# =============================================================================
foreach ($tc in $testCases) {
    $name = $tc.name
    $mode = if ($tc.HasAttribute('mode')) { $tc.GetAttribute('mode') } else { 'direct' }

    # Command text (CDATA child).
    $cmdNode = $tc.'copilot-command'
    if ($cmdNode -is [System.Xml.XmlElement]) { $command = $cmdNode.InnerText } else { $command = "$cmdNode" }
    $command = $command.Trim()

    # ==================================================================
    # MODE: fullpipe - spawn the REAL hook process against the live gateway
    # Config: the parent fixture config with base_uri/model -> live, level=all
    # (so even a single command is in scope), written to c:\temp.
    # ==================================================================
    if ($mode -eq 'fullpipe') {
        $expectDecision = $tc.GetAttribute('expect-decision')

        $cfgObj = Get-Content (Join-Path $fixtureDir 'config.json') -Raw | ConvertFrom-Json
        $cfgObj.llm_second_opinion.base_uri   = $BaseUri
        $cfgObj.llm_second_opinion.model      = $Model
        $cfgObj.llm_second_opinion.level      = 'all'
        $cfgObj.llm_second_opinion.timeout_ms = $TimeoutMs
        $tmpCfg = 'c:\temp\llm-live-test-config.json'
        ($cfgObj | ConvertTo-Json -Depth 20) | Set-Content $tmpCfg -Encoding UTF8

        $payload = (@{
            tool_name       = 'run_in_terminal'
            tool_input      = @{ command = $command }
            hook_event_name = 'preToolUse'
            timestamp       = '1790000000000'
        } | ConvertTo-Json -Compress -Depth 5)

        $env:PRETOOLHOOK_CONFIG_PATH = $tmpCfg
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

        try {
            $out = $stdout | ConvertFrom-Json -ErrorAction Stop
            $decision = $out.hookSpecificOutput.permissionDecision
            $reason   = "$($out.hookSpecificOutput.permissionDecisionReason)"
            $ok = ($decision -eq $expectDecision) -and ($exitCode -eq 0)
            Write-Host "LIVE [$name] decision=$decision exit=$exitCode reason='$reason'$(if ($ok) {' - OK'} else {' - WRONG'})"
            Record-Result -Ok $ok -Name $name -Detail "cmd: $command | expected $expectDecision+exit0 got $decision+exit$exitCode | reason: $reason"
        }
        catch {
            Record-Result -Ok $false -Name $name -Detail "cmd: $command | stdout not JSON: $stdout"
        }
        continue
    }

    # ==================================================================
    # MODE: direct (default) - call the production verdict client
    # Retry ONCE on transient outcomes (down / unusable); never on a wrong
    # verdict - that is the signal.
    # ==================================================================
    $expectVerdict = $tc.GetAttribute('expect-verdict')

    # Attributed mode is opt-in per case via the subcommands attr: the list is
    # numbered in the prompt and the parser validates indices against it.
    $subCmds = @()
    if ($tc.HasAttribute('subcommands')) {
        $subCmds = @($tc.GetAttribute('subcommands') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $llmCfg.AttributedVerdicts = ($subCmds.Count -gt 0)

    $verdict = $null
    $attempts = 0
    foreach ($attempt in 1..2) {
        $attempts = $attempt
        try {
            $verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg -SubCommands $subCmds
        }
        catch {
            $verdict = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $_.Exception.Message; Indices = $null }
        }
        # Retry only on transient outcomes.
        if ($verdict.Verdict -ne 'down' -and $verdict.Verdict -ne 'unusable') { break }
        if ($attempt -eq 1) { Write-Host "LIVE [$name] transient ($($verdict.Verdict)) - retrying once ..." }
    }

    $ok = ($verdict.Verdict -eq $expectVerdict)
    $detail = "cmd: $command | expected $expectVerdict got $($verdict.Verdict) after $attempts attempt(s) | raw='$($verdict.Raw)' error='$($verdict.Error)'"

    # Optional index assertion (attributed cases): exact set match, or an
    # explicitly empty list when expect-indices="". A $null Indices (bare
    # true/false fallback) only satisfies an ABSENT expect-indices attr.
    if ($tc.HasAttribute('expect-indices')) {
        $wantRaw = $tc.GetAttribute('expect-indices').Trim()
        $haveIdx = $verdict.Indices
        $haveStr = if ($null -ne $haveIdx) { "[$(@($haveIdx) -join ',')]" } else { '<null>' }
        $detail += " indices=$haveStr"
        if ($wantRaw -eq '') {
            $idxOk = ($null -ne $haveIdx -and @($haveIdx).Count -eq 0)
        }
        else {
            $wantStr = (@($wantRaw -split ',' | ForEach-Object { [int]$_.Trim() }) | Sort-Object) -join ','
            $haveSorted = if ($null -ne $haveIdx) { (@($haveIdx) | Sort-Object) -join ',' } else { '<null>' }
            $idxOk = ($haveSorted -eq $wantStr)
        }
        if (-not $idxOk) { $ok = $false; $detail += " (wanted indices [$wantRaw])" }
    }

    $idxPrint = if ($null -ne $verdict.Indices) { " indices=[$(@($verdict.Indices) -join ',')]" } else { '' }
    Write-Host "LIVE [$name] verdict=$($verdict.Verdict)$idxPrint latency=$($verdict.LatencyMs)ms raw='$($verdict.Raw)'$(if ($verdict.Recovered) {' (recovered)'})$(if ($ok) {' - OK'} else { " - WRONG (wanted $expectVerdict)" })"
    Record-Result -Ok $ok -Name $name -Detail $detail
}

Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "LLM-LIVE Test Run Complete (gateway: $BaseUri, model: $Model)"
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
if ($failures.Count -gt 0) {
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $($f.Name)" -ForegroundColor Red }
    Write-Host ""
    Write-Host "NOTE: a wrong verdict here is model behavior, not hook-code breakage." -ForegroundColor Yellow
    Write-Host "      The offline suites (Run-Tests.ps1, http/Run-LlmCallTests.ps1) pin the code."
}
Write-Host "========================================"
if ($failed -gt 0) { exit 1 } else { exit 0 }
