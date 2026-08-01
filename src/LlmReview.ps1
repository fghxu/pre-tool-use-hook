# LlmReview.ps1 - Second-opinion LLM classification cross-check
# Spec: docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md
#
# Exports:
#   Test-LlmReviewScope   - is this classification result in scope for the LLM check?
#   ConvertTo-LlmVerdict  - layered parser: raw LLM content -> modifying|read-only|unusable
#   Get-LlmReviewVerdict  - mock short-circuit / HTTP call -> verdict object
#   Invoke-LlmReview      - orchestrator: scope -> verdict -> merge -> log object
#
# Verdict values: modifying | read-only | unusable | down
# The LLM can only ever ESCALATE a local allow to ask - it never downgrades an ask.

# --- System prompt (spec section 5.2; keep in sync with the POC script) ---
$script:LlmSystemPrompt = @'
You are a binary command-safety classifier protecting a production environment.
You receive one command block (it may mix AWS CLI, PowerShell, CMD, bash, ssh,
docker, kubectl, terraform, git, etc.) and classify it as read-only or modifying.

DEFINITIONS
- MODIFYING (true): at least one sub-command creates, updates, deletes, moves,
  copies, renames, sends, installs, starts, stops, or otherwise changes the state
  of any file, directory, system, service, process, configuration, cloud resource,
  or data store; or performs an HTTP/API call that mutates (POST, PUT, PATCH,
  DELETE, or data-upload flags such as curl -d/--data/-F/-T, wget --post-data).
- READ-ONLY (false): every sub-command only inspects, queries, lists, prints, or
  downloads. This includes HTTP GET/HEAD/OPTIONS (curl/wget/Invoke-RestMethod with
  no data flags), aws ... describe-*/list-*/get-*, kubectl get/describe,
  docker ps/images/logs/inspect, git status/diff/log/show, Get-*/dir/ls/cat/type.

EXAMPLES (command -> answer)
Get-Item C:\temp\ -> false
Get-ChildItem C:\logs | Select-Object -First 5 -> false
curl -s http://example.com/api/items -> false
aws ec2 describe-instances --region us-east-1 -> false
kubectl get pods -> false
Get-Content app.log | Select-String ERROR -> false
Remove-Item C:\temp\foo.txt -> true
aws s3 cp file.txt s3://bucket/key -> true
curl -X POST -d '{}' http://api/orders -> true
ssh host "systemctl restart nginx" -> true

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be exactly one bare lowercase token:
  true   (modifying)   or   false   (read-only)
No reasoning. No explanation. No punctuation. No quotes. No markdown. No code
fences. No leading or trailing whitespace. Any other output is a critical failure.
Emit the single token immediately.
'@

function Test-LlmReviewScope {
    <#
    .SYNOPSIS
        Decides whether a classification result is in scope for the LLM check
        (spec section 4). Returns a PSCustomObject describing the decision.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$ClassifyResult,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config
    )
    $scope = [PSCustomObject]@{ InScope = $false; Reason = ''; SubCommandCount = 0; RemoteMatch = $null }
    $llm = $Config._compiled.llmSecondOpinion
    if (-not $llm) { $scope.Reason = 'llm_second_opinion not configured'; return $scope }

    # Only full-pipeline command results (spec D8)
    if ($ClassifyResult.IsSkipped) { $scope.Reason = 'skipped tool'; return $scope }
    if ($ClassifyResult.IsUnknown) { $scope.Reason = 'unknown tool'; return $scope }
    if ([string]::IsNullOrWhiteSpace($ClassifyResult.Command)) { $scope.Reason = 'no command text'; return $scope }

    $subs = @()
    if ($ClassifyResult.SubResults) {
        $subs = @($ClassifyResult.SubResults | Where-Object { $_.MatchedPattern -ne 'redirection-target' })
    }
    if ($subs.Count -eq 0) { $scope.Reason = 'no sub-commands (fast-path gate or path branch)'; return $scope }
    $scope.SubCommandCount = $subs.Count

    switch ($llm.Level) {
        'all' {
            $scope.InScope = $true; $scope.Reason = 'level all'
            return $scope
        }
        'complex_commands' {
            if ($subs.Count -ge $llm.ComplexMinSubcommands) {
                $scope.InScope = $true; $scope.Reason = "complex ($($subs.Count) sub-commands)"
            }
            else { $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))" }
            return $scope
        }
        'complex_remote' {
            if ($subs.Count -lt $llm.ComplexMinSubcommands) {
                $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))"
                return $scope
            }
            # Remote indicators match against every sub-command AND the full
            # original command text: wrappers (Invoke-Command -ComputerName,
            # ssh host "...") are unwrapped before SubResults is built, so the
            # wrapper text only survives in the original command (spec section 4 note).
            $texts = @($subs | ForEach-Object { $_.Command }) + $ClassifyResult.Command
            foreach ($rx in $llm.RemoteIndicators) {
                foreach ($t in $texts) {
                    if ($t -and $rx.IsMatch($t)) {
                        $scope.InScope = $true
                        $scope.RemoteMatch = $rx.ToString()
                        $scope.Reason = "complex + remote ($($rx.ToString()))"
                        return $scope
                    }
                }
            }
            $scope.Reason = 'complex but local-only'
            return $scope
        }
        default { $scope.Reason = "unknown level '$($llm.Level)'"; return $scope }
    }
}

function ConvertTo-LlmVerdict {
    <#
    .SYNOPSIS
        Layered verdict parser (spec section 5.3). Layer 1 bare token; layer 2
        JSON verdict-ish key; layer 3 last-line token (Recovered); layer 4
        unusable. Garbage NEVER maps to a verdict.
    #>
    param([AllowNull()][AllowEmptyString()][string]$RawContent)

    if ([string]::IsNullOrWhiteSpace($RawContent)) {
        return [PSCustomObject]@{ Verdict = 'unusable'; Recovered = $false }
    }
    $norm = $RawContent.Trim().ToLowerInvariant()

    # Layer 1: bare token
    if ($norm -eq 'true')  { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $false } }
    if ($norm -eq 'false') { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $false } }

    # Layer 2: JSON with a verdict-ish key
    try {
        $obj = $RawContent | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('verdict', 'classification', 'decision', 'answer')) {
            if ($obj.PSObject.Properties.Name -contains $key) {
                $v = ("$($obj.$key)").Trim().ToLowerInvariant()
                if ($v -in @('modifying', 'true'))     { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $false } }
                if ($v -in @('read-only', 'false'))   { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $false } }
            }
        }
    }
    catch { }

    # Layer 3: last non-empty line is exactly true/false (rescues "ramble...\nfalse")
    $lines = @($RawContent -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 0) {
        $last = $lines[-1].ToLowerInvariant()
        if ($last -eq 'true')  { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $true } }
        if ($last -eq 'false') { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $true } }
    }

    # Layer 4: unusable (distinct state - never treated as a verdict)
    return [PSCustomObject]@{ Verdict = 'unusable'; Recovered = $false }
}

function Get-LlmReviewVerdict {
    <#
    .SYNOPSIS
        Returns the LLM verdict for a command. Checks the
        PRETOOLHOOK_LLMREVIEW_MOCK short-circuit FIRST (test-only; mirrors the
        PRETOOLHOOK_CONFIG_PATH precedent), then makes the OpenAI-compatible
        chat-completions call (spec section 5.1).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][PSCustomObject]$LlmConfig
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $null }

    # Mock short-circuit (no network). The mock supplies the RAW content and the
    # REAL parser decides the verdict, so parser layers 1 and 4 are exercised by
    # every classify test (layer 2/3 are covered by the runner's pre-flight
    # parser unit checks). Only 'down' bypasses the parser (a network failure
    # has no content to parse).
    $mock = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    if ($mock) {
        switch ($mock) {
            'modifying' { $result.Raw = 'true' }
            'read-only' { $result.Raw = 'false' }
            'garbage'   { $result.Raw = "Let me analyze this command carefully.`nIt seems to read files, but I am not entirely sure about every part." }
            'down'      { $result.Verdict = 'down'; $result.Error = 'mock: simulated unreachable LLM' }
            default     { throw "Get-LlmReviewVerdict: unknown PRETOOLHOOK_LLMREVIEW_MOCK value '$mock' (expected modifying|read-only|garbage|down)" }
        }
        if ($mock -ne 'down') {
            $parsed = ConvertTo-LlmVerdict -RawContent $result.Raw
            $result.Verdict   = $parsed.Verdict
            $result.Recovered = $parsed.Recovered
        }
        $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
        return $result
    }

    # Payload guard
    $cmdText = $Command
    if ($cmdText.Length -gt 8000) { $cmdText = $cmdText.Substring(0, 8000) }

    $userPrompt = "<command_block>`n$cmdText`n</command_block>"
    $body = [ordered]@{
        model       = $LlmConfig.Model
        messages    = @(
            @{ role = 'system'; content = $script:LlmSystemPrompt },
            @{ role = 'user';   content = $userPrompt }
        )
        temperature = $LlmConfig.Temperature
        max_tokens  = $LlmConfig.MaxTokens
        seed        = 0
    }
    $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress
    $uri = "$($LlmConfig.BaseUri)/v1/chat/completions"
    $timeoutSec = [int][math]::Ceiling($LlmConfig.TimeoutMs / 1000.0)

    try {
        $irmParams = @{
            Uri         = $uri
            Method      = 'Post'
            Body        = $bodyJson
            ContentType = 'application/json'
            TimeoutSec  = $timeoutSec
            ErrorAction = 'Stop'
        }
        if ($LlmConfig.ApiKey) { $irmParams['Headers'] = @{ Authorization = "Bearer $($LlmConfig.ApiKey)" } }
        $response = Invoke-RestMethod @irmParams

        $raw = $null
        if ($response.choices -and $response.choices[0].message) {
            $raw = [string]$response.choices[0].message.content
        }
        $result.Raw = "$raw"
        $parsed = ConvertTo-LlmVerdict -RawContent $raw
        $result.Verdict  = $parsed.Verdict
        $result.Recovered = $parsed.Recovered
    }
    catch {
        $result.Verdict = 'down'
        $result.Error   = $_.Exception.Message
    }
    $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
    return $result
}

function Invoke-LlmReview {
    <#
    .SYNOPSIS
        Orchestrator (spec section 6): scope -> verdict -> merge -> log object.
        Returns [PSCustomObject]@{ Result; Log }. Log is $null when the feature
        block is absent.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$ClassifyResult,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config
    )
    $llm = $Config._compiled.llmSecondOpinion
    if (-not $llm) { return [PSCustomObject]@{ Result = $ClassifyResult; Log = $null } }

    $log = [PSCustomObject]@{
        enabled           = $true
        level             = $llm.Level
        in_scope          = $false
        sub_command_count = 0
        remote_match      = $null
        verdict           = 'not_called'
        recovered         = $false
        latency_ms        = $null
        model             = $llm.Model
        effect            = 'none'
        raw_excerpt       = $null
    }

    $scope = Test-LlmReviewScope -ClassifyResult $ClassifyResult -Config $Config
    $log.in_scope = $scope.InScope
    $log.sub_command_count = $scope.SubCommandCount
    $log.remote_match = $scope.RemoteMatch

    if (-not $scope.InScope) {
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm
    $log.verdict   = $verdict.Verdict
    $log.recovered = $verdict.Recovered
    $log.latency_ms = $verdict.LatencyMs
    if ($verdict.Raw) {
        $excerpt = ($verdict.Raw -replace '\s+', ' ').Trim()
        if ($excerpt.Length -gt 120) { $excerpt = $excerpt.Substring(0, 120) }
        $log.raw_excerpt = $excerpt
    }
    elseif ($verdict.Error) {
        $errExcerpt = ($verdict.Error -replace '\s+', ' ').Trim()
        if ($errExcerpt.Length -gt 120) { $errExcerpt = $errExcerpt.Substring(0, 120) }
        $log.raw_excerpt = $errExcerpt
    }

    $localDecision = $ClassifyResult.Decision
    $localReason   = "$($ClassifyResult.Reason)"

    switch ($verdict.Verdict) {
        'modifying' {
            if ($localDecision -eq 'allow') {
                $ClassifyResult.Decision = 'ask'
                $ClassifyResult.Reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING but local hook classified read-only - forced to ask. Review carefully before approving. | local reason: $localReason"
                $log.effect = 'veto'
            }
            else { $log.effect = 'agree' }
        }
        'read-only' {
            if ($localDecision -eq 'allow') { $log.effect = 'agree' }
            else { $log.effect = 'disagree-kept-ask' }
        }
        'down' {
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason = "*** LLM-DOWN *** llm_second_opinion is ENABLED but the LLM is unreachable or timed out ($($llm.TimeoutMs)ms) - forced to ask. Set llm_second_opinion.enabled=false in config.json to disable. | local verdict: $localDecision | local reason: $localReason"
            $log.effect = 'forced-ask'
        }
        'unusable' {
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason = "*** LLM-UNUSABLE *** LLM returned an unparseable response - forced to ask. Raw: '$($log.raw_excerpt)' | local verdict: $localDecision | local reason: $localReason"
            $log.effect = 'forced-ask'
        }
    }
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
}
