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

# --- V2 system prompt (attributed verdicts; used when AttributedVerdicts is on) ---
$script:LlmSystemPromptV2 = @'
You are a binary command-safety classifier protecting a production environment.
You receive one command block (it may mix AWS CLI, PowerShell, CMD, bash, ssh,
docker, kubectl, terraform, git, etc.) plus a numbered list of its sub-commands,
and you report WHICH numbered sub-commands are modifying.

DEFINITIONS
- MODIFYING: creates, updates, deletes, moves, copies, renames, sends,
  installs, starts, stops, or otherwise changes the state of any file,
  directory, system, service, process, configuration, cloud resource, or data
  store; or performs an HTTP/API call that mutates (POST, PUT, PATCH, DELETE,
  or data-upload flags such as curl -d/--data/-F/-T, wget --post-data).
- READ-ONLY: only inspects, queries, lists, prints, or downloads. This
  includes HTTP GET/HEAD/OPTIONS (curl/wget/Invoke-RestMethod with no data
  flags), aws ... describe-*/list-*/get-*, kubectl get/describe,
  docker ps/images/logs/inspect, git status/diff/log/show, Get-*/dir/ls/cat/type.

EXAMPLES
block: aws s3 ls && aws s3 cp f s3://b/k
sub_commands: 1. aws s3 ls / 2. aws s3 cp f s3://b/k
answer: {"modifying":[2]}

block: Get-ChildItem C:\logs | Select-Object -First 5
sub_commands: 1. Get-ChildItem C:\logs / 2. Select-Object -First 5
answer: {"modifying":[]}

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be one JSON object, nothing else:
  {"modifying": []}        - every numbered sub-command is read-only
  {"modifying": [2]}       - sub-command 2 is modifying
  {"modifying": [1, 2]}    - several are modifying
Use index 0 for anything modifying that is NOT in the numbered list
(for example a redirect target or an unlisted nested command).
No reasoning. No explanation. No markdown. No code fences. Emit the JSON
object immediately.
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
    $scope = [PSCustomObject]@{ InScope = $false; Reason = ''; SubCommandCount = 0; RemoteMatch = $null; SubCommands = @() }
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
    $scope.SubCommands = $subs

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
        Layered verdict parser (phase-II spec section 4). Returns a
        PSCustomObject @{ Verdict; Recovered; Indices } where Indices is an
        int array for attributed JSON answers and $null when unattributed
        (bare token / phase-I JSON keys). Layers: 1 bare token; 2 JSON
        {"modifying":[...]} (strictly validated against -SubCommandCount) or
        phase-I verdict-ish JSON keys; 3 last-line rescue (bare token or the
        modifying JSON); 4 unusable. Garbage NEVER maps to a verdict.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$RawContent,
        [int]$SubCommandCount = 0
    )

    # Local helper: uniform result shape.
    function New-Verdict([string]$V, [bool]$R, $Idx) {
        return [PSCustomObject]@{ Verdict = $V; Recovered = $R; Indices = $Idx }
    }
    # Local helper: validate a parsed {"modifying": <value>} property.
    # Returns an int array (empty = read-only) or $null on any violation.
    function Test-ModifyingArray($M, [int]$Max) {
        if ($null -eq $M) { return @() }                      # {"modifying":null} ~ empty
        if ($M -isnot [System.Collections.IList]) { return $null }
        $list = @()
        foreach ($el in $M) {
            $n = 0
            if (-not [int]::TryParse("$el", [ref]$n)) { return $null }
            if ($n -lt 0 -or $n -gt $Max) { return $null }
            $list += $n
        }
        return ,$list
    }

    if ([string]::IsNullOrWhiteSpace($RawContent)) { return (New-Verdict 'unusable' $false $null) }
    $norm = $RawContent.Trim().ToLowerInvariant()

    # Layer 1: bare token (unattributed)
    if ($norm -eq 'true')  { return (New-Verdict 'modifying' $false $null) }
    if ($norm -eq 'false') { return (New-Verdict 'read-only' $false $null) }

    # Layer 2: JSON forms (whole response)
    $parsedObj = $null
    try { $parsedObj = $RawContent | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($parsedObj) {
        if ($parsedObj.PSObject.Properties.Name -contains 'modifying') {
            $idxs = Test-ModifyingArray $parsedObj.modifying $SubCommandCount
            if ($null -eq $idxs) { return (New-Verdict 'unusable' $false $null) }
            if ($idxs.Count -eq 0) { return (New-Verdict 'read-only' $false @()) }
            return (New-Verdict 'modifying' $false $idxs)
        }
        # Phase-I JSON verdict-ish keys (back-compat)
        foreach ($key in @('verdict', 'classification', 'decision', 'answer')) {
            if ($parsedObj.PSObject.Properties.Name -contains $key) {
                $v = ("$($parsedObj.$key)").Trim().ToLowerInvariant()
                if ($v -in @('modifying', 'true'))  { return (New-Verdict 'modifying' $false $null) }
                if ($v -in @('read-only', 'false')) { return (New-Verdict 'read-only' $false $null) }
            }
        }
    }

    # Layer 3: last non-empty line is a bare token or the modifying JSON (recovered)
    $lines = @($RawContent -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 0) {
        $last = $lines[-1]
        $lastNorm = $last.ToLowerInvariant()
        if ($lastNorm -eq 'true')  { return (New-Verdict 'modifying' $true $null) }
        if ($lastNorm -eq 'false') { return (New-Verdict 'read-only' $true $null) }
        if ($last.StartsWith('{')) {
            $lastObj = $null
            try { $lastObj = $last | ConvertFrom-Json -ErrorAction Stop } catch { }
            if ($lastObj -and ($lastObj.PSObject.Properties.Name -contains 'modifying')) {
                $idxs = Test-ModifyingArray $lastObj.modifying $SubCommandCount
                if ($null -ne $idxs) {
                    if ($idxs.Count -eq 0) { return (New-Verdict 'read-only' $true @()) }
                    return (New-Verdict 'modifying' $true $idxs)
                }
            }
        }
    }

    # Layer 4: unusable (distinct state - never treated as a verdict)
    return (New-Verdict 'unusable' $false $null)
}

function Get-LlmReviewVerdict {
    <#
    .SYNOPSIS
        Returns the LLM verdict for a command. Checks the
        PRETOOLHOOK_LLMREVIEW_MOCK short-circuit FIRST (test-only), then makes
        the OpenAI-compatible chat-completions call. When
        $LlmConfig.AttributedVerdicts is on, the V2 prompt is used and the
        numbered -SubCommands are appended as <sub_commands>; the parser
        returns Indices with the verdict. Result fields: Verdict, Raw,
        LatencyMs, Recovered, Error, Indices, Mocked.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][PSCustomObject]$LlmConfig,
        [string[]]$SubCommands = @()
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $null; Indices = $null; Mocked = $false }
    $subCount = $SubCommands.Count

    # Mock short-circuit (no network). The mock supplies the RAW content and the
    # REAL parser decides the verdict. 'idx:...' injects the attributed JSON
    # form; the 4 phase-I values inject bare/garbage/down as before.
    $mock = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    if ($mock) {
        $result.Mocked = $true
        if ($mock -like 'idx:*') {
            $list = $mock.Substring(4)
            if ($list.Trim() -eq '') { $result.Raw = '{"modifying":[]}' }
            else {
                $items = @($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                $result.Raw = '{"modifying":[' + ($items -join ',') + ']}'
            }
        }
        else {
            switch ($mock) {
                'modifying' { $result.Raw = 'true' }
                'read-only' { $result.Raw = 'false' }
                'garbage'   { $result.Raw = "Let me analyze this command carefully.`nIt seems to read files, but I am not entirely sure about every part." }
                'down'      { $result.Verdict = 'down'; $result.Error = 'mock: simulated unreachable LLM' }
                default     { throw "Get-LlmReviewVerdict: unknown PRETOOLHOOK_LLMREVIEW_MOCK value '$mock' (expected modifying|read-only|garbage|down|idx:...)" }
            }
        }
        if ($mock -ne 'down') {
            $parsed = ConvertTo-LlmVerdict -RawContent $result.Raw -SubCommandCount $subCount
            $result.Verdict   = $parsed.Verdict
            $result.Recovered = $parsed.Recovered
            $result.Indices   = $parsed.Indices
        }
        $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
        return $result
    }

    # Payload guard
    $cmdText = $Command
    if ($cmdText.Length -gt 8000) { $cmdText = $cmdText.Substring(0, 8000) }

    # User message: raw block, plus the numbered sub-command list in V2 mode
    $userPrompt = "<command_block>`n$cmdText`n</command_block>"
    $sysPrompt = $script:LlmSystemPrompt
    if ($LlmConfig.AttributedVerdicts) {
        $sysPrompt = $script:LlmSystemPromptV2
        if ($SubCommands.Count -gt 0) {
            $numbered = @()
            for ($i = 0; $i -lt $SubCommands.Count; $i++) { $numbered += "{0}. {1}" -f ($i + 1), $SubCommands[$i] }
            $userPrompt += "`n<sub_commands>`n" + ($numbered -join "`n") + "`n</sub_commands>"
        }
    }

    $body = [ordered]@{
        model       = $LlmConfig.Model
        messages    = @(
            @{ role = 'system'; content = $sysPrompt },
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
        $parsed = ConvertTo-LlmVerdict -RawContent $raw -SubCommandCount $subCount
        $result.Verdict   = $parsed.Verdict
        $result.Recovered = $parsed.Recovered
        $result.Indices   = $parsed.Indices
    }
    catch {
        $result.Verdict = 'down'
        $result.Error   = $_.Exception.Message
    }
    $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
    return $result
}

function Test-GatedInvocationSafe {
    <#
    .SYNOPSIS
        Stage-2 extension point (spec P4): decides whether a strictness_gated
        invocation is safe to suppress. Stage 1: always safe (tier-only
        suppression). Stage 2 will path-check writable gated cmdlets;
        unknown argument shapes must fail safe ($false = do not suppress).
    #>
    param([string]$Command, [PSCustomObject]$Config)
    return $true
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
        indices           = $null
        flagged           = @()
        suppressed        = @()
        error             = $null
        mocked            = $false
        sent              = @()
        tiers             = @()
        local_decision    = ''
        local_reason      = ''
        timeout_ms        = $llm.TimeoutMs
    }

    $scope = Test-LlmReviewScope -ClassifyResult $ClassifyResult -Config $Config
    $log.in_scope = $scope.InScope
    $log.sub_command_count = $scope.SubCommandCount
    $log.remote_match = $scope.RemoteMatch

    # Numbered list for the prompt AND the index lookup (spec P2: same list).
    $subTexts = @($scope.SubCommands | ForEach-Object { "$($_.Command)" })
    $log.sent  = $subTexts
    $log.tiers = @($scope.SubCommands | ForEach-Object { "$($_.Tier)" })
    $log.local_decision = $ClassifyResult.Decision
    $log.local_reason   = "$($ClassifyResult.Reason)"

    if (-not $scope.InScope) {
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm -SubCommands $subTexts
    $log.verdict   = $verdict.Verdict
    $log.recovered = $verdict.Recovered
    $log.latency_ms = $verdict.LatencyMs
    $log.indices = $verdict.Indices
    $log.mocked  = $verdict.Mocked
    if ($verdict.Error) { $log.error = $verdict.Error }
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
            if ($localDecision -ne 'allow') { $log.effect = 'agree' }
            elseif (-not $llm.AttributedVerdicts -or $null -eq $verdict.Indices) {
                # Phase-I path: unattributed -> full veto, nothing suppressible (spec P5)
                $ClassifyResult.Decision = 'ask'
                $ClassifyResult.Reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING but local hook classified read-only - forced to ask. Review carefully before approving. | local reason: $localReason"
                $log.effect = 'veto'
            }
            else {
                # Attributed merge (spec section 6): map each flagged index to its tier
                $log.flagged = @($verdict.Indices)
                $vetoIdx = @()
                $suppIdx = @()
                foreach ($ix in $verdict.Indices) {
                    if ($ix -eq 0) { $vetoIdx += 0; continue }   # unlisted danger: never suppressible (P3)
                    $sub = $scope.SubCommands[$ix - 1]
                    if ($sub -and $sub.Tier -eq 'strictness_gated' -and
                        (Test-GatedInvocationSafe -Command $sub.Command -Config $Config)) {
                        $suppIdx += $ix
                    }
                    else { $vetoIdx += $ix }
                }
                $log.suppressed = @($suppIdx)
                if ($vetoIdx.Count -eq 0) {
                    # Every flag was accepted policy (the flood-killer)
                    $log.effect = 'veto-suppressed-policy'
                }
                else {
                    $first = $vetoIdx[0]
                    if ($first -eq 0) {
                        $firstText = "(unlisted part of the block) [index 0]"
                    }
                    else {
                        $ft = "$($scope.SubCommands[$first - 1].Command)"
                        if ($ft.Length -gt 120) { $ft = $ft.Substring(0, 120) }
                        $firstText = "'$ft' [sub-command $first]"
                    }
                    $reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING: $firstText - forced to ask."
                    if ($suppIdx.Count -gt 0) {
                        $suppTexts = @()
                        foreach ($sx in $suppIdx) {
                            $st = "$($scope.SubCommands[$sx - 1].Command)"
                            if ($st.Length -gt 60) { $st = $st.Substring(0, 60) }
                            $suppTexts += "'$st' [$sx]"
                        }
                        $reason += " | suppressed as policy: " + ($suppTexts -join ', ')
                    }
                    $reason += " | local reason: $localReason"
                    $ClassifyResult.Decision = 'ask'
                    $ClassifyResult.Reason = $reason
                    $log.effect = 'veto'
                }
            }
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
