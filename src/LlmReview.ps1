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

VARIABLE STATE
- Assigning, updating, or removing ordinary in-memory shell/session variables
  is READ-ONLY. This includes local variables, remote-session variables, and
  variables that happen to contain credentials or secrets. The variable
  mutation itself does NOT make the command modifying — but you MUST still
  classify independently every command used to compute, transmit, or consume
  the variable's value (e.g. the Invoke-RestMethod on the right-hand side).
- This exception applies ONLY to plain variable operations: $x = ..., ${var} =,
  Set-Variable, Remove-Variable, New-Variable, and $env:VAR = for process-scoped
  environment variables. It does NOT extend to:
  - object property setters ($obj.Prop = "value")
  - registry or PSProvider writes (Set-ItemProperty, reg add)
  - shell profile files (.bashrc writes, $PROFILE modification)
  - any other persistent state that uses assignment-like syntax
- Process-scoped environment-variable changes ($env:TEMP = "C:\tmp") are
  ephemeral (lost when the process exits) and also READ-ONLY for classification.
- Persistent user/machine/system environment-variable changes are MODIFYING:
  setx, reg add ... Environment, [Environment]::SetEnvironmentVariable(...)
  with a User or Machine target.

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
$x = "hello" -> false
$cred = Get-Credential -> false
$result = Invoke-RestMethod -Method Get -Uri https://api/items -> false
$env:TEMP = "C:\tmp" -> false
$obj.Property = "new value" -> true
setx PATH "C:\tools" -> true
[Environment]::SetEnvironmentVariable("PATH", "C:\tools", "User") -> true
reg add HKCU\Environment /v FOO /d bar -> true

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be exactly one bare lowercase token:
  true   (modifying)   or   false   (read-only)
No reasoning. No explanation. No punctuation. No quotes. No markdown. No code
fences. No leading or trailing whitespace. Any other output is a critical failure.
Emit the single token immediately.
'@

# --- V2 system prompt (attributed verdicts; used when AttributedVerdicts is on) ---
# Hardened 2026-08-03 after BOTH GLM-5.2 and deepseek-v4-flash ignored the
# output contract on simple commands and answered with analysis prose
# (-> unusable -> fail-closed ask). Three changes that measurably help small
# reasoning-leaning models: the OUTPUT CONTRACT block sits LAST (recency); a
# first-character rule ('{' only); one negative example showing prose rejected.
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

VARIABLE STATE
- Assigning, updating, or removing ordinary in-memory shell/session variables
  is READ-ONLY. This includes local variables, remote-session variables, and
  variables that happen to contain credentials or secrets. The variable
  mutation itself does NOT make the command modifying — but you MUST still
  classify independently every command used to compute, transmit, or consume
  the variable's value (e.g. the Invoke-RestMethod on the right-hand side).
- This exception applies ONLY to plain variable operations: $x = ..., ${var} =,
  Set-Variable, Remove-Variable, New-Variable, and $env:VAR = for process-scoped
  environment variables. It does NOT extend to:
  - object property setters ($obj.Prop = "value")
  - registry or PSProvider writes (Set-ItemProperty, reg add)
  - shell profile files (.bashrc writes, $PROFILE modification)
  - any other persistent state that uses assignment-like syntax
- Process-scoped environment-variable changes ($env:TEMP = "C:\tmp") are
  ephemeral (lost when the process exits) and also READ-ONLY for classification.
- Persistent user/machine/system environment-variable changes are MODIFYING:
  setx, reg add ... Environment, [Environment]::SetEnvironmentVariable(...)
  with a User or Machine target.

EXAMPLES
# Variable assignment (read-only — RHS commands classify independently)
block: $x = "hello"
sub_commands: 1. $x = "hello"
answer: {"modifying":[]}

block: $cred = Get-Credential
sub_commands: 1. $cred = Get-Credential
answer: {"modifying":[]}

block: $env:TEMP = "C:\tmp"
sub_commands: 1. $env:TEMP = "C:\tmp"
answer: {"modifying":[]}

# Persistent environment changes (modifying)
block: setx PATH "C:\tools"
sub_commands: 1. setx PATH "C:\tools"
answer: {"modifying":[1]}

block: [Environment]::SetEnvironmentVariable("PATH", "C:\tools", "User")
sub_commands: 1. [Environment]::SetEnvironmentVariable(...)
answer: {"modifying":[1]}

# Object property setters / registry writes (modifying)
block: $obj.Prop = "new value"
sub_commands: 1. $obj.Prop = "new value"
answer: {"modifying":[1]}

block: reg add HKCU\Environment /v FOO /d bar
sub_commands: 1. reg add HKCU\Environment /v FOO /d bar
answer: {"modifying":[1]}

NEGATIVE EXAMPLE - this is WRONG, never do this:
question: aws s3 ls && aws s3 cp f s3://b/k
bad answer:  "Let me analyze these sub-commands. aws s3 ls lists buckets which is read-only, but aws s3 cp uploads a file so it is modifying."
good answer: {"modifying":[2]}
Do NOT explain, reason, or narrate. The bad answer is a critical failure.

OUTPUT CONTRACT - CRITICAL (read this last)
Your ENTIRE response must be ONE JSON object and NOTHING else:
  {"modifying": []}        - every numbered sub-command is read-only
  {"modifying": [2]}       - sub-command 2 is modifying
  {"modifying": [1, 2]}    - several are modifying
Use index 0 for anything modifying that is NOT in the numbered list
(for example a redirect target or an unlisted nested command).
- The FIRST character of your response MUST be '{'. It must not be a letter,
  a space, a quote, or any markdown.
- No reasoning. No explanation. No prose. No markdown. No code fences.
- Output the JSON object immediately.
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
    $scope = [PSCustomObject]@{ InScope = $false; Reason = ''; SubCommandCount = 0; RemoteMatch = $null; SubCommands = @(); CheckBlindspotTier = $null }
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
                return $scope
            }
            $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))"
            break
        }
        'complex_remote' {
            if ($subs.Count -lt $llm.ComplexMinSubcommands) {
                $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))"
                break
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
            break
        }
        default { $scope.Reason = "unknown level '$($llm.Level)'"; return $scope }
    }

    # ----------------------------------------------------------------
    # check_blindspot (out-of-scope rescue): if the normal scope gate said
    # out-of-scope AND check_blindspot is enabled AND any sub-command's Tier
    # is in the check_blindspot tier list, the LLM IS consulted (InScope=$true).
    # CHECK_BLINDSPOT NEVER CHANGES THE DECISION (local ask stays ask); the LLM
    # verdict only enriches the reason text the human sees at approval.
    # The first matching unknown tier is recorded for the reason wording.
    # ----------------------------------------------------------------
    if ($llm.PSObject.Properties['CheckBlindspot'] -and $llm.CheckBlindspot -and $llm.CheckBlindspot.Enabled) {
        $tierSet = @{}
        foreach ($t in $llm.CheckBlindspot.Tiers) { $tierSet["$t"] = $true }
        foreach ($sub in $subs) {
            $tier = "$($sub.Tier)"
            if ($tierSet.ContainsKey($tier)) {
                $scope.InScope = $true
                $scope.CheckBlindspotTier = $tier
                $scope.Reason = "check_blindspot: local $tier"
                return $scope
            }
        }
    }

    return $scope
}

# =============================================================================
# ConvertFrom-BalancedJsonObject - step 5B of the LLM JSON-repair pipeline.
# Character-scanning extractor that returns ALL top-level balanced {...}
# substrings in document order. Deliberately NOT regex: JSON can contain
# nested objects, arrays, and braces/quotes inside strings, so a brace-counting
# scanner that tracks string state and backslash escapes is required. Used by
# ConvertTo-LlmVerdict Layer 3.5 to recover the schema-valid JSON object a
# chatty model glued to analysis prose (observed on glm-5.2 and
# deepseek-v4-flash; both ignore the output contract under load).
# =============================================================================
function ConvertFrom-BalancedJsonObject {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $objs = New-Object System.Collections.Generic.List[string]
    $depth = 0; $inStr = $false; $escape = $false; $start = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $inStr = $false }
        }
        else {
            if ($c -eq '"') { $inStr = $true }
            elseif ($c -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
            elseif ($c -eq '}') {
                if ($depth -gt 0) {
                    $depth--
                    if ($depth -eq 0 -and $start -ge 0) {
                        $objs.Add($Text.Substring($start, $i - $start + 1)); $start = -1
                    }
                }
            }
        }
    }
    return ,$objs
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
        modifying JSON); 3.5 whole-response scan (chatty-model rescue, scans
        for the last schema-valid JSON object then the last bare token);
        4 unusable. Garbage NEVER maps to a verdict.
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

    # Layer 3.5: whole-response scan - chatty-model rescue (2026-08-04). Both
    # glm-5.2 and deepseek-v4-flash ignore the output contract under load and
    # glue the answer to analysis prose, often mid-line or mid-response, so
    # Layer 3's last-line rule cannot see it. The model almost always KNOWS the
    # answer; it just won't put it on a clean line. We scan the WHOLE response,
    # preferring the unambiguous JSON form and falling back to a bare token.
    # All returns here are flagged Recovered (we salvaged an embedded answer).
    #
    # 3.5a: last schema-valid {"modifying":[...]} object anywhere in the text.
    # ConvertFrom-BalancedJsonObject handles nested braces/strings/escapes (a
    # char scanner, NOT regex). Scanning last-to-first prefers the model's
    # final answer when it emits the JSON twice.
    $jsonObjs = ConvertFrom-BalancedJsonObject $RawContent
    for ($j = $jsonObjs.Count - 1; $j -ge 0; $j--) {
        $scanObj = $null
        try { $scanObj = $jsonObjs[$j] | ConvertFrom-Json -ErrorAction Stop } catch { }
        if ($scanObj -and ($scanObj.PSObject.Properties.Name -contains 'modifying')) {
            $idxs = Test-ModifyingArray $scanObj.modifying $SubCommandCount
            if ($null -ne $idxs) {
                if ($idxs.Count -eq 0) { return (New-Verdict 'read-only' $true @()) }
                return (New-Verdict 'modifying' $true $idxs)
            }
        }
    }
    # 3.5b: last bare true/false token anywhere in the response (V1 binary
    # contract only; handles prose-glued tokens like "...modifying.true" and
    # the doubled-token quirk "truetrue" / "falsefalse"). LastIndexOf picks the
    # model's final token; an ordinal case-insensitive search matches any case.
    $lt = $RawContent.LastIndexOf('true',  [System.StringComparison]::OrdinalIgnoreCase)
    $lf = $RawContent.LastIndexOf('false', [System.StringComparison]::OrdinalIgnoreCase)
    if ($lt -ge 0 -or $lf -ge 0) {
        if ($lt -gt $lf) { return (New-Verdict 'modifying' $true $null) }
        return (New-Verdict 'read-only' $true $null)
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
    $attributed = $false
    if ($LlmConfig.AttributedVerdicts) {
        $sysPrompt = $script:LlmSystemPromptV2
        $attributed = $true
        if ($SubCommands.Count -gt 0) {
            $numbered = @()
            for ($i = 0; $i -lt $SubCommands.Count; $i++) { $numbered += "{0}. {1}" -f ($i + 1), $SubCommands[$i] }
            $userPrompt += "`n<sub_commands>`n" + ($numbered -join "`n") + "`n</sub_commands>"
        }
        # First-character rule, repeated at the point of decision (recency):
        # a response starting with '{' cannot ramble into analysis prose.
        $userPrompt += "`nReply with the JSON object only. The first character of your response must be '{'."
    }

    $body = [ordered]@{
        model       = $LlmConfig.Model
        messages    = @(
            @{ role = 'system'; content = $sysPrompt },
            @{ role = 'user';   content = $userPrompt }
        )
        temperature = $LlmConfig.Temperature
        max_tokens  = $LlmConfig.LlmResponseMaxTokens
        seed        = 0
    }
    # JSON mode (config json_mode, default off): constrain the response to be
    # valid JSON at the API level (response_format: json_object). Attributed
    # calls only - the V1 contract is a bare token, which is not JSON. This is
    # the hard fix for reasoning-leaning models that ignore the output
    # contract and answer with analysis prose (observed 2026-08-03 on BOTH
    # GLM-5.2 and deepseek-v4-flash -> unusable -> fail-closed ask).
    if ($attributed -and $LlmConfig.PSObject.Properties['JsonMode'] -and $LlmConfig.JsonMode) {
        $body['response_format'] = @{ type = 'json_object' }
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

# =============================================================================
# Stage-2 path-guard tables (phase-III)
#
# Skip-list: commands whose arguments are DATA, never filesystem write targets
# (printf's format string, setx's registry value). Path-checking them would
# veto benign shapes - exactly the noise phase II exists to kill.
# =============================================================================
$script:LlmGuardSkipCommands = @('printf', 'setx')

# Writer name-list: commands that CAN take a filesystem path as a write target.
# Used ONLY for the fail-closed variable rule (see Test-GatedInvocationSafe).
$script:LlmGuardWriterCommands = @(
    'set-content', 'add-content', 'out-file', 'export-csv', 'export-clixml',
    'tee-object', 'new-item', 'copy-item', 'move-item', 'rename-item',
    'sc', 'ac', 'cp', 'copy', 'cpi', 'mv', 'move', 'mi', 'ren', 'rename', 'rni',
    'ni', 'md', 'mkdir', 'ln', 'unzip'
)

# Split-GuardTokens: quote-aware whitespace tokenizer. Quoted spans keep their
# content whole (quotes stripped), so "C:\Windows\my file.txt" survives as one
# token and cannot smuggle a protected path past the path-shape scan.
# Unbalanced quotes keep the remainder as one token (fail-safe direction).
function Split-GuardTokens {
    param([string]$Command)
    $tokens = @()
    $cur = ''
    $inS = $false; $inD = $false
    foreach ($ch in $Command.ToCharArray()) {
        if ($inS) { if ($ch -eq "'") { $inS = $false } else { $cur += $ch }; continue }
        if ($inD) { if ($ch -eq '"') { $inD = $false } else { $cur += $ch }; continue }
        if ($ch -eq "'") { $inS = $true; continue }
        if ($ch -eq '"') { $inD = $true; continue }
        if ($ch -match '\s') { if ($cur) { $tokens += $cur; $cur = '' }; continue }
        $cur += $ch
    }
    if ($cur) { $tokens += $cur }
    return $tokens
}

function Test-GatedInvocationSafe {
    <#
    .SYNOPSIS
        Stage-2 guard (phase-III): decides whether a strictness_gated
        invocation is safe to suppress. Generic token scan, no positional
        table (interleaved flags make positions unreliable):
          1. skip-list commands (args are data) are always safe;
          2. every path-shaped token (drive-absolute / UNC / POSIX-absolute)
             goes through Resolve-PathPolicy - any 'ask' denies suppression;
          3. fail-closed variable rule: a KNOWN WRITER with NO literal path
             token but an unresolved $var/%VAR% argument (temp forms
             %TEMP%/%TMP%/$env:TEMP/$env:TMP excepted) cannot prove its
             target safe (H5 class: %SystemRoot% unexpanded canonicalizes as
             CWD-relative) - deny;
          4. anything else (git/terraform/no-path commands) is safe, exactly
             like stage 1.
        Accepted residuals (documented in the phase-III spec): source-vs-
        destination is not distinguished (Copy-Item FROM a system dir vetoes);
        a writer with a literal SAFE path plus a variable TARGET slips (rule 3
        only fires when no literal path token exists).
    #>
    param([string]$Command, [PSCustomObject]$Config)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $tokens = @(Split-GuardTokens $Command)
    if ($tokens.Count -eq 0) { return $false }

    $name = $tokens[0].Trim().ToLowerInvariant()
    try { $name = [System.IO.Path]::GetFileNameWithoutExtension($name) } catch { }
    if ($script:LlmGuardSkipCommands -contains $name) { return $true }
    $isWriter = $script:LlmGuardWriterCommands -contains $name

    $hasVar = $false
    $hasLiteralPath = $false
    foreach ($t in ($tokens | Select-Object -Skip 1)) {
        if (-not $t) { continue }
        if (($t.Contains('$') -or $t.Contains('%')) -and
            ($t -notmatch '^(?i)(\$env:(TEMP|TMP)\b|%TEMP%|%TMP%)')) { $hasVar = $true }
        if ($t -match '^([A-Za-z]:[\\/]|\\\\|/)') {
            $hasLiteralPath = $true
            $policy = Resolve-PathPolicy -Path $t -Config $Config
            if ($policy.Decision -eq 'ask') { return $false }
        }
    }
    if ($isWriter -and $hasVar -and -not $hasLiteralPath) { return $false }
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
        scope_reason      = ''
        sub_command_count = 0
        remote_match      = $null
        verdict           = 'not_called'
        recovered         = $false
        latency_ms        = $null
        model             = $llm.Model
        effect            = 'none'
        raw_excerpt       = $null
        raw_full          = $null
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
        path_guard_denied = @()
        check_blindspot_triggered = $false
        raw_display_limit = $llm.LlmResponseMaxTokens * 4
    }

    $scope = Test-LlmReviewScope -ClassifyResult $ClassifyResult -Config $Config
    $log.in_scope = $scope.InScope
    $log.scope_reason = $scope.Reason
    $log.sub_command_count = $scope.SubCommandCount
    $log.remote_match = $scope.RemoteMatch
    # check_blindspot fires when the scope reason starts with "check_blindspot:".
    $log.check_blindspot_triggered = ($scope.CheckBlindspotTier -ne $null)
    $isCheckBlindspot = $log.check_blindspot_triggered

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
        if ($excerpt.Length -gt $log.raw_display_limit) { $excerpt = $excerpt.Substring(0, $log.raw_display_limit) }
        $log.raw_excerpt = $excerpt
        $log.raw_full = "$($verdict.Raw)"
    }
    elseif ($verdict.Error) {
        $errExcerpt = ($verdict.Error -replace '\s+', ' ').Trim()
        if ($errExcerpt.Length -gt $log.raw_display_limit) { $errExcerpt = $errExcerpt.Substring(0, $log.raw_display_limit) }
        $log.raw_excerpt = $errExcerpt
    }

    $localDecision = $ClassifyResult.Decision
    $localReason   = "$($ClassifyResult.Reason)"

    # ----------------------------------------------------------------
    # CHECK_BLINDSPOT merge (out-of-scope rescue). When check_blindspot triggered,
    # the normal merge rules DO NOT apply: the decision is ALWAYS the
    # local decision (never downgraded, never upgraded by LLM). The LLM
    # verdict is only used to ENRICH the reason text the human sees at
    # approval time. Failure modes (down/unusable) note the LLM was
    # attempted but unavailable. The reason shows BOTH the local tier
    # for each sub-command AND the LLM's per-sub-command verdict so the
    # human can reason faster without re-reading the raw command.
    # ----------------------------------------------------------------
    if ($isCheckBlindspot) {
        $tierLabel = "$($scope.CheckBlindspotTier)"
        # Build the local-tiers summary: "[1]=unclassified [2]=read_only".
        $tierParts = @()
        for ($i = 0; $i -lt $scope.SubCommands.Count; $i++) {
            $t = "$($scope.SubCommands[$i].Tier)"
            if (-not $t) { $t = 'unlabeled' }
            $tierParts += "[$($i + 1)]=$t"
        }
        $tierSummary = $tierParts -join ' '

        # Build the LLM per-sub-command verdict summary from $verdict.Indices.
        # flaggedIdx is the set the LLM said is modifying; the rest are read-only.
        $flaggedSet = @{}
        if ($null -ne $verdict.Indices) { foreach ($ix in $verdict.Indices) { $flaggedSet[" $ix "] = $true } }
        $llmParts = @()
        for ($i = 0; $i -lt $scope.SubCommands.Count; $i++) {
            $tag = if ($flaggedSet.ContainsKey(" $($i + 1) ")) { 'MODIFYING' } else { 'read-only' }
            $llmParts += "[$($i + 1)]=$tag"
        }
        $llmSummary = $llmParts -join ' '

        switch ($verdict.Verdict) {
            'read-only' {
                $llmHeadline = "LLM second-opinion: READ-ONLY (all sub-commands)"
            }
            'modifying' {
                $llmHeadline = "LLM second-opinion: MODIFYING ($llmSummary)"
            }
            'down' {
                $llmHeadline = "*** LLM-DOWN *** check_blindspot consulted the LLM but it was unreachable/timed out ($($llm.TimeoutMs)ms)"
            }
            'unusable' {
                $llmHeadline = "*** LLM-UNUSABLE *** check_blindspot consulted the LLM but its response was unparseable. Raw: '$($log.raw_excerpt)'"
            }
            default { $llmHeadline = "LLM second-opinion: ($($verdict.Verdict))" }
        }

        # CHECK_BLINDSPOT NEVER CHANGES THE DECISION. Local ask stays ask; the
        # reason is rewritten to lead with the check_blindspot headline so the
        # human sees the LLM hint at a glance.
        $ClassifyResult.Decision = 'ask'
        $ClassifyResult.Reason = "*** CHECK_BLINDSPOT *** check_blindspot: local $tierLabel (local tiers: $tierSummary) | $llmHeadline | local reason: $localReason"
        $log.effect = if ($verdict.Verdict -in @('down', 'unusable')) { 'forced-ask' } else { 'check-blindspot-ask' }
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

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
                $pgDenied = @()
                foreach ($ix in $verdict.Indices) {
                    if ($ix -eq 0) { $vetoIdx += 0; continue }   # unlisted danger: never suppressible (P3)
                    $sub = $scope.SubCommands[$ix - 1]
                    $isGated = ($sub -and $sub.Tier -eq 'strictness_gated')
                    if ($isGated -and (Test-GatedInvocationSafe -Command $sub.Command -Config $Config)) {
                        $suppIdx += $ix
                    }
                    else {
                        $vetoIdx += $ix
                        # A gated flag the stage-2 guard REFUSED to suppress
                        # (protected-path target / unproven variable) - recorded
                        # so the reconciliation log can say WHY.
                        if ($isGated) { $pgDenied += $ix }
                    }
                }
                $log.suppressed = @($suppIdx)
                $log.path_guard_denied = @($pgDenied)
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
