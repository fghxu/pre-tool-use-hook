# =============================================================================
# Run-LlmCallTests.ps1 - tests for the REAL LLM-calling code path
# =============================================================================
#
# WHY THIS SUITE EXISTS
#   The main llm-review suite (../Run-Tests.ps1) injects fake LLM verdicts via
#   PRETOOLHOOK_LLMREVIEW_MOCK, so it never exercises the HTTP code in
#   Get-LlmReviewVerdict (src/LlmReview.ps1). THIS suite closes that gap:
#   every case runs the REAL Invoke-RestMethod call against a LOCAL mock LLM
#   server (Mock-LlmServer.ps1 - a real socket on 127.0.0.1). Still zero quota:
#   no packet ever leaves the machine.
#
#   The single most important assertion in most cases is expect-hit="1":
#   the mock server RECORDED the request - direct proof that the code (and in
#   the fullpipe case, the spawned hook process) really CALLS the LLM.
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1
#       # or just one file:
#       pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1 -XmlPath test/config/llm-review/http/test-llm-call-core.xml
#   Exit 0 = all green (25 checks: 5 core + 20 matrix). Exit 1 = failures.
#
# HOW TO READ THE OUTPUT
#   Same convention as the parent suite: silence = passing; failures print as
#   FAIL [<name>] + one detail line; summary at the end.
#
# SAFETY GUARANTEE
#   The runner REMOVES $env:PRETOOLHOOK_LLMREVIEW_MOCK at startup (and again at
#   the end). If that variable were set, Get-LlmReviewVerdict would
#   short-circuit BEFORE the HTTP call and every expect-hit assertion would
#   fail - so a leftover mock can never produce a false green here.
#
# PER-CASE XML ATTRIBUTES
#   name              unique check name (printed on failure)
#   server            canned server behavior (default 'true'):
#                       true | false | garbage | upper-true | spaced-false |
#                       json-verdict | ramble-true | http500 | slow3000 | dead
#                     ('dead' = nothing listens on the port; drives the
#                      connection-refused -> 'down' path)
#   mode              direct (default: call Get-LlmReviewVerdict in-process) |
#                     fullpipe (spawn the real src/Hook.ps1 child process)
#   expect-verdict    modifying|read-only|unusable|down (direct mode)
#   expect-recovered  true|false (optional; parser 'last-line rescue' flag)
#   expect-hit        1 (default) = server must have recorded a request;
#                     0 = no request may arrive
#   expect-decision   allow|ask (fullpipe mode: permissionDecision on stdout)
#   reason-contains   substring asserted on the reason (fullpipe mode)
#   timeout-ms        LLM wait budget for this case (default 5000)
#   api-key           value for the block's ApiKey (default empty)
#   check             semicolon-separated request assertions (optional):
#                       method-post      - HTTP method was POST
#                       path-completions - URL path was /v1/chat/completions
#                       ct-json          - Content-Type was application/json
#                       model            - body.model == configured model
#                       sys-role         - messages[0] is the system prompt (>100 chars)
#                       user-role        - messages[1].role == 'user'
#                       cmdblock-tags    - user content has <command_block> wrapper
#                       cmd-text         - user content carries the exact command
#                       temp-0           - body.temperature == 0
#                       maxtok-16        - body.max_tokens == 16
#                       seed-0           - body.seed == 0
#                       auth-present     - Authorization: Bearer <api-key> arrived
#                       auth-absent      - no Authorization header arrived
#                       truncated8000   - the 9000-char {{X9000}} command is
#                       truncated to exactly 8000 'x' chars by the payload guard
#                       (the attributed suffix adds ~80 chars to the user content,
#                       so this asserts the truncation, not a fixed total)
#   command           via <copilot-command> child (default 'Get-Date');
#                     the token {{X9000}} expands to 9000 'x' characters
#                     (drives the payload-truncation case)
# =============================================================================

param(
    # Optional: run a single XML file instead of both.
    [string]$XmlPath = ""
)

# A broken runner must not masquerade as green.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths. This file lives in test/config/llm-review/http; src/ is four levels up.
# ---------------------------------------------------------------------------
$httpDir    = $PSScriptRoot
$fixtureDir = Split-Path $httpDir -Parent                       # test/config/llm-review
$srcDir     = Join-Path $httpDir "..\..\..\..\src"              # repo src/
$hookPath   = Join-Path $srcDir "Hook.ps1"

# ---------------------------------------------------------------------------
# CRITICAL SAFETY: disarm the verdict mock. This suite exists to prove the REAL
# HTTP path; a leftover mock would silently bypass it (and every expect-hit
# assertion would then fail - but we refuse to run under a lie at all).
# ---------------------------------------------------------------------------
Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue
Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue

# Dot-source the feature under test (Get-LlmReviewVerdict) and the mock server.
. (Join-Path $srcDir "LlmReview.ps1")
. (Join-Path $httpDir "Mock-LlmServer.ps1")

# Child-process engine for the fullpipe case (same family as this process).
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

# ---------------------------------------------------------------------------
# Collect the test-case XML files: both shipped files by default, or -XmlPath.
# ---------------------------------------------------------------------------
$xmlFiles = @()
if ($XmlPath) {
    $xmlFiles += $XmlPath
}
else {
    $xmlFiles += Join-Path $httpDir "test-llm-call-core.xml"
    $xmlFiles += Join-Path $httpDir "test-llm-call-matrix.xml"
}

$testCases = @()
foreach ($f in $xmlFiles) {
    [xml]$xml = Get-Content $f -Encoding UTF8
    $testCases += @($xml.commands.'category-group'.'test-case')
}

# Counters + failure list (same reporting shape as the parent suite).
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
# Get-CannedResponse - maps the case's server="" token to the exact response
# the mock server will return (status code + body + optional delay).
# The bodies mimic the OpenAI chat-completions shape the real gateway sends:
#   { "choices": [ { "message": { "content": "<raw model text>" } } ] }
# ---------------------------------------------------------------------------
function Get-CannedResponse {
    param([string]$Token)
    # Helper: wrap raw model text into the OpenAI response envelope.
    function Envelope([string]$content) {
        return (@{ choices = @(@{ message = @{ content = $content } }) } | ConvertTo-Json -Depth 6 -Compress)
    }
    switch ($Token) {
        'true'         { return @{ Status = 200; Body = (Envelope 'true');  DelayMs = 0 } }
        'false'        { return @{ Status = 200; Body = (Envelope 'false'); DelayMs = 0 } }
        'garbage'      { return @{ Status = 200; Body = (Envelope 'Let me think about this command. It lists files, but I am not sure.'); DelayMs = 0 } }
        'upper-true'   { return @{ Status = 200; Body = (Envelope 'TRUE');  DelayMs = 0 } }
        'spaced-false' { return @{ Status = 200; Body = (Envelope "  false`n"); DelayMs = 0 } }
        'json-verdict' { return @{ Status = 200; Body = (Envelope '{"verdict":"read-only"}'); DelayMs = 0 } }
        'ramble-true'  { return @{ Status = 200; Body = (Envelope "reasoning about the command`ntrue"); DelayMs = 0 } }
        'http500'      { return @{ Status = 500; Body = '{"error":{"message":"boom"}}'; DelayMs = 0 } }
        'slow3000'     { return @{ Status = 200; Body = (Envelope 'true');  DelayMs = 3000 } }
        default        { throw "Get-CannedResponse: unknown server token '$Token'" }
    }
}

# ---------------------------------------------------------------------------
# Invoke-RequestChecks - evaluates the case's check="" tokens against what the
# mock server captured. Returns @($ok, $whyFailed).
# ---------------------------------------------------------------------------
function Invoke-RequestChecks {
    param(
        [string]$CheckSpec,     # semicolon-separated token list
        $State,                 # mock server State (request captures)
        [string]$Command,       # the command sent (post-expansion)
        [string]$Model,         # configured model name
        [string]$ApiKey         # configured api key ('' = none)
    )
    if (-not $CheckSpec) { return @($true, '') }
    if ($State.RequestCount -lt 1) { return @($false, "no request captured (expected one for checks '$CheckSpec')") }

    # Parse the captured request body once (it is the JSON the hook POSTed).
    $bodyObj = $null
    try { $bodyObj = $State.LastBody | ConvertFrom-Json -ErrorAction Stop } catch { }

    foreach ($token in ($CheckSpec -split ';')) {
        $t = $token.Trim()
        $ok = $true; $why = ''
        switch ($t) {
            'method-post'      { $ok = ($State.LastMethod -eq 'POST');                                     $why = "method=$($State.LastMethod)" }
            'path-completions' { $ok = ($State.LastPath -eq '/v1/chat/completions');                       $why = "path=$($State.LastPath)" }
            'ct-json'          { $ok = ($State.LastContentType -match 'application/json');                 $why = "content-type=$($State.LastContentType)" }
            'model'            { $ok = ($bodyObj -and $bodyObj.model -eq $Model);                          $why = "body.model=$($bodyObj.model)" }
            'sys-role'         { $ok = ($bodyObj -and $bodyObj.messages[0].role -eq 'system' -and $bodyObj.messages[0].content.Length -gt 100); $why = "messages[0].role=$($bodyObj.messages[0].role) len=$(($bodyObj.messages[0].content).Length)" }
            'user-role'        { $ok = ($bodyObj -and $bodyObj.messages[1].role -eq 'user');               $why = "messages[1].role=$($bodyObj.messages[1].role)" }
            'cmdblock-tags'    { $c = $bodyObj.messages[1].content; $ok = ($bodyObj -and $c.Contains('<command_block>') -and $c.Contains('</command_block>')); $why = "user content missing <command_block> wrapper" }
            'cmd-text'         { $ok = ($bodyObj -and ($bodyObj.messages[1].content).Contains($Command));  $why = "user content does not carry the command" }
            'temp-0'           { $ok = ($bodyObj -and [double]$bodyObj.temperature -eq 0.0);               $why = "temperature=$($bodyObj.temperature)" }
            'maxtok-16'        { $ok = ($bodyObj -and [int]$bodyObj.max_tokens -eq 16);                    $why = "max_tokens=$($bodyObj.max_tokens)" }
            'seed-0'           { $ok = ($bodyObj -and [int]$bodyObj.seed -eq 0);                           $why = "seed=$($bodyObj.seed)" }
            'auth-present'     { $ok = ($State.LastAuth -eq "Bearer $ApiKey");                             $why = "Authorization=$($State.LastAuth)" }
            'auth-absent'      { $ok = [string]::IsNullOrEmpty($State.LastAuth);                           $why = "Authorization=$($State.LastAuth)" }
            'truncated-8000'   { $len = ($bodyObj.messages[1].content).Length; $xc = ([regex]::Matches([string]$bodyObj.messages[1].content, 'x')).Count; $ok = ($bodyObj -and $xc -eq 8000 -and $len -lt 9000); $why = "user content length=$len x-count=$xc (want the 9000-char command truncated to 8000)" }
            'subcmds-tags'   { $c = $bodyObj.messages[1].content; $ok = ($bodyObj -and $c.Contains('<sub_commands>') -and $c.Contains('</sub_commands>') -and $c.Contains('1. ')); $why = "user content missing numbered <sub_commands> block" }
            'nosubcmds-tags' { $c = $bodyObj.messages[1].content; $ok = ($bodyObj -and -not $c.Contains('<sub_commands>')); $why = "user content unexpectedly contains <sub_commands>" }
            default            { $ok = $false;                                                             $why = "unknown check token '$t'" }
        }
        if (-not $ok) { return @($false, "check '$t' failed: $why") }
    }
    return @($true, '')
}

# ---------------------------------------------------------------------------
# New-DeadPort - returns a 127.0.0.1 port with NOTHING listening on it
# (for the connection-refused -> 'down' case).
# ---------------------------------------------------------------------------
function New-DeadPort {
    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $p = $tcp.LocalEndpoint.Port
    $tcp.Stop()
    return $p
}

# =============================================================================
# MAIN: one shared mock server for every non-'dead' case (state is reset per
# case). Server lifetime = the whole run; stopped in the finally block.
# =============================================================================
$server = New-MockLlmServer

try {
    foreach ($tc in $testCases) {
        $name = $tc.name

        # ----- Read case attributes (with defaults) -----
        $serverToken     = if ($tc.HasAttribute('server'))           { $tc.GetAttribute('server') }           else { 'true' }
        $mode            = if ($tc.HasAttribute('mode'))             { $tc.GetAttribute('mode') }             else { 'direct' }
        $expectVerdict   = if ($tc.HasAttribute('expect-verdict'))   { $tc.GetAttribute('expect-verdict') }   else { '' }
        $expectRecovered = if ($tc.HasAttribute('expect-recovered')) { [bool]::Parse($tc.GetAttribute('expect-recovered')) } else { $null }
        $expectHit       = if ($tc.HasAttribute('expect-hit'))       { [int]$tc.GetAttribute('expect-hit') }  else { 1 }
        $expectDecision  = if ($tc.HasAttribute('expect-decision'))  { $tc.GetAttribute('expect-decision') }  else { '' }
        $reasonContains  = if ($tc.HasAttribute('reason-contains'))  { $tc.GetAttribute('reason-contains') }  else { $null }
        $timeoutMs       = if ($tc.HasAttribute('timeout-ms'))       { [int]$tc.GetAttribute('timeout-ms') }  else { 5000 }
        $apiKey          = if ($tc.HasAttribute('api-key'))          { $tc.GetAttribute('api-key') }          else { '' }
        $checkSpec       = if ($tc.HasAttribute('check'))            { $tc.GetAttribute('check') }            else { '' }
        $attrVerdicts    = if ($tc.HasAttribute('attributed'))       { [bool]::Parse($tc.GetAttribute('attributed')) } else { $true }
        $subCmds         = @()
        if ($tc.HasAttribute('subcommands')) { $subCmds = @($tc.GetAttribute('subcommands') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

        # ----- Resolve the command text (CDATA child; {{X9000}} expansion) -----
        $cmdNode = $tc.'copilot-command'
        if ($null -eq $cmdNode) { $command = 'Get-Date' }
        elseif ($cmdNode -is [System.Xml.XmlElement]) { $command = $cmdNode.InnerText } else { $command = "$cmdNode" }
        $command = $command.Trim()
        if ($command -eq '{{X9000}}') { $command = 'x' * 9000 }

        # ----- Point the case at the mock server (or at a dead port) -----
        $baseUri = $server.BaseUri
        if ($serverToken -eq 'dead') { $baseUri = "http://127.0.0.1:$(New-DeadPort)" }
        else {
            # Reset the shared server: zero captures, program the next response.
            $canned = Get-CannedResponse -Token $serverToken
            $server.State.Status       = $canned.Status
            $server.State.Body         = $canned.Body
            $server.State.DelayMs      = $canned.DelayMs
            $server.State.RequestCount = 0
            $server.State.LastMethod   = ''
            $server.State.LastPath     = ''
            $server.State.LastBody     = ''
            $server.State.LastAuth     = $null
        }

        # ----- Build the compiled-block object the unit under test consumes -----
        $llmCfg = [PSCustomObject]@{
            Enabled               = $true
            Level                 = 'all'
            BaseUri               = $baseUri
            Model                 = 'glm-5.2'
            ApiKey                = $apiKey
            TimeoutMs             = $timeoutMs
            Temperature           = 0.0
            LlmResponseMaxTokens  = 16
            ComplexMinSubcommands = 2
            AttributedVerdicts    = $attrVerdicts
            JsonMode              = $false
            RemoteIndicators      = @()
        }

        # ==================================================================
        # MODE: fullpipe - spawn the REAL hook process against the mock server
        # The generated config has enabled:true and level:all, so even a single
        # read-only command is in scope: the hook MUST emit an HTTP call, and
        # the mock server MUST record it (expect-hit).
        # ==================================================================
        if ($mode -eq 'fullpipe') {
            # Clone the parent fixture config with base_uri -> mock, level -> all.
            $cfgObj = Get-Content (Join-Path $fixtureDir 'config.json') -Raw | ConvertFrom-Json
            $cfgObj.llm_second_opinion.base_uri = $baseUri
            $cfgObj.llm_second_opinion.level    = 'all'
            $tmpCfg = 'c:\temp\llm-call-test-config.json'
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
                $detail = "expected $expectDecision+exit0 got $decision+exit$exitCode | reason: $reason"
                if ($ok -and $reasonContains) {
                    $ok = $reason.Contains($reasonContains)
                    if (-not $ok) { $detail += " | reason missing '$reasonContains'" }
                }
                # THE headline assertion: the spawned hook really hit the LLM endpoint.
                if ($ok -and $serverToken -ne 'dead') {
                    $ok = ($server.State.RequestCount -eq $expectHit)
                    if (-not $ok) { $detail += " | server hits expected $expectHit got $($server.State.RequestCount)" }
                }
                Record-Result -Ok $ok -Name $name -Detail $detail
            }
            catch {
                Record-Result -Ok $false -Name $name -Detail "stdout not JSON: $stdout"
            }
            continue
        }

        # ==================================================================
        # MODE: direct (default) - call Get-LlmReviewVerdict in-process
        # ==================================================================
        $verdict = $null
        try {
            $verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg -SubCommands $subCmds
        }
        catch {
            Record-Result -Ok $false -Name $name -Detail "threw: $($_.Exception.Message)"
            continue
        }

        # Assertion chain: verdict -> recovered -> server hit -> request checks.
        $ok = ($verdict.Verdict -eq $expectVerdict)
        $detail = "verdict expected $expectVerdict got $($verdict.Verdict) (raw='$($verdict.Raw)' error='$($verdict.Error)')"

        if ($ok -and $null -ne $expectRecovered) {
            $ok = ($verdict.Recovered -eq $expectRecovered)
            if (-not $ok) { $detail += " | recovered expected $expectRecovered got $($verdict.Recovered)" }
        }
        if ($ok -and $serverToken -ne 'dead') {
            $ok = ($server.State.RequestCount -eq $expectHit)
            if (-not $ok) { $detail += " | server hits expected $expectHit got $($server.State.RequestCount)" }
        }
        if ($ok -and $checkSpec) {
            $cr = Invoke-RequestChecks -CheckSpec $checkSpec -State $server.State -Command $command -Model $llmCfg.Model -ApiKey $apiKey
            $ok = $cr[0]
            if (-not $ok) { $detail += " | $($cr[1])" }
        }
        Record-Result -Ok $ok -Name $name -Detail $detail
    }
}
finally {
    # Always stop the mock server, even if a case blew up.
    Stop-MockLlmServer -Server $server
    Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue
    Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
}

# =============================================================================
# SUMMARY (same convention as the parent suite)
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "LLM-Call (HTTP) Test Run Complete"
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
if ($failures.Count -gt 0) {
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $($f.Name)" -ForegroundColor Red }
}
Write-Host "========================================"
if ($failed -gt 0) { exit 1 } else { exit 0 }
