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
    # script_drilldown llm_scope (2026-09-20, spec 8.5): 'exclude' drops every
    # script-origin entry from BOTH the count and the sent list, so the LLM never
    # sees expanded-script statements. 'count' (default) keeps them. No-op without
    # the OriginScript property (feature OFF / non-drilldown commands).
    $llmScope = 'count'
    if ($llm.PSObject.Properties['LlmScope']) { $llmScope = "$($llm.LlmScope)" }
    if ($llmScope -eq 'exclude') {
        $subs = @($subs | Where-Object { -not ($_.PSObject.Properties['OriginScript']) })
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

    # Primary pass: quote-aware (tracks double-quoted strings + backslash
    # escapes). Correct for well-formed prose where quotes are balanced.
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

    # Fallback pass (2026-09-15): if the quote-aware scan found NOTHING, a stray
    # double-quote in the prose (e.g. 'rg "stage' — a " inside single-quoted
    # text) desynced it into permanent "inside string" mode and hid a valid
    # {"modifying":[...]} glued to the end -> unusable -> fail-closed ask even
    # though local AND LLM both said read-only (2026-09-15 14:00:24 log). Re-scan
    # IGNORING quotes entirely (pure balanced-brace counting). Candidates may
    # include prose fragments, but Layer 3.5a still validates each with
    # ConvertFrom-Json + schema check, so garbage is rejected — the scanner only
    # proposes, the JSON parser disposes. Conservative: fires ONLY when the
    # primary scan found zero objects (never overrides a successful quote-aware
    # extraction).
    if ($objs.Count -eq 0) {
        $depth = 0; $start = -1
        for ($i = 0; $i -lt $Text.Length; $i++) {
            $c = $Text[$i]
            if ($c -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
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

# =============================================================================
# llm_third_opinion pair support (2026-09-30 design 4.1-4.5).
# Spec: docs/superpowers/specs/2026-09-30-llm-third-opinion-spec.md
# Design: docs/superpowers/specs/2026-09-30-llm-third-opinion-design.md
# =============================================================================

function New-LlmRequestBody {
    <#
    .SYNOPSIS
        Builds ONE OpenAI chat-completions request payload (design 4.1 -
        extracted VERBATIM from Get-LlmReviewVerdict so the pair path reuses
        it byte-for-byte). Two-parameter form enforces the D2 identical-prompt
        contract structurally: $Llm1Config supplies ALL prompt/sampling
        parameters (Temperature, LlmResponseMaxTokens, AttributedVerdicts,
        JsonMode, TimeoutMs -> default TimeoutSec); $EndpointConfig supplies
        ONLY transport identity (BaseUri, Model, ApiKey).
        Returns @{ Uri; BodyJson; TimeoutSec; ApiKey }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][PSCustomObject]$Llm1Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$EndpointConfig,
        [string[]]$SubCommands = @()
    )
    # Payload guard
    $cmdText = $Command
    if ($cmdText.Length -gt 8000) { $cmdText = $cmdText.Substring(0, 8000) }

    # User message: raw block, plus the numbered sub-command list in V2 mode
    $userPrompt = "<command_block>`n$cmdText`n</command_block>"
    $sysPrompt = $script:LlmSystemPrompt
    $attributed = $false
    if ($Llm1Config.AttributedVerdicts) {
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
        model       = $EndpointConfig.Model
        messages    = @(
            @{ role = 'system'; content = $sysPrompt },
            @{ role = 'user';   content = $userPrompt }
        )
        temperature = $Llm1Config.Temperature
        max_tokens  = $Llm1Config.LlmResponseMaxTokens
        seed        = 0
    }
    # JSON mode (config json_mode, default off): constrain the response to be
    # valid JSON at the API level (response_format: json_object). Attributed
    # calls only - the V1 contract is a bare token, which is not JSON. This is
    # the hard fix for reasoning-leaning models that ignore the output
    # contract and answer with analysis prose (observed 2026-08-03 on BOTH
    # GLM-5.2 and deepseek-v4-flash -> unusable -> fail-closed ask).
    if ($attributed -and $Llm1Config.PSObject.Properties['JsonMode'] -and $Llm1Config.JsonMode) {
        $body['response_format'] = @{ type = 'json_object' }
    }
    $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress
    $timeoutSec = [int][math]::Ceiling($Llm1Config.TimeoutMs / 1000.0)
    return @{
        Uri        = "$($EndpointConfig.BaseUri)/v1/chat/completions"
        BodyJson   = $bodyJson
        TimeoutSec = $timeoutSec
        ApiKey     = "$($EndpointConfig.ApiKey)"
    }
}

function Get-LlmMockResult {
    <#
    .SYNOPSIS
        Mock short-circuit grammar (design 4.2 - extracted VERBATIM from
        Get-LlmReviewVerdict, shared by both pair sides). $MockToken is the raw
        env var value; $VarName names the var in the throw message (LLM1's
        message stays byte-identical). Returns @{ Mocked=$true; Raw=<string> }
        or @{ Mocked=$true; IsDown=$true; Error='mock: simulated unreachable LLM' }.
        Grammar: 'modifying'|'read-only'|'garbage'|'down'|'idx:1,2'. Unknown
        value -> throw.
    #>
    param([string]$MockToken, [int]$SubCommandCount, [string]$VarName)
    if ($MockToken -like 'idx:*') {
        $list = $MockToken.Substring(4)
        if ($list.Trim() -eq '') { return @{ Mocked = $true; Raw = '{"modifying":[]}' } }
        $items = @($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        return @{ Mocked = $true; Raw = '{"modifying":[' + ($items -join ',') + ']}' }
    }
    switch ($MockToken) {
        'modifying' { return @{ Mocked = $true; Raw = 'true' } }
        'read-only' { return @{ Mocked = $true; Raw = 'false' } }
        'garbage'   { return @{ Mocked = $true; Raw = "Let me analyze this command carefully.`nIt seems to read files, but I am not entirely sure about every part." } }
        'down'      { return @{ Mocked = $true; IsDown = $true; Error = 'mock: simulated unreachable LLM' } }
        default     { throw "Get-LlmReviewVerdict: unknown $VarName value '$MockToken' (expected modifying|read-only|garbage|down|idx:...)" }
    }
}

function New-MockVerdict {
    <#
    .SYNOPSIS
        Pair-mode mock verdict (design 4.5): wraps Get-LlmMockResult +
        ConvertTo-LlmVerdict into the same result shape Get-LlmReviewVerdict
        returns (Verdict/Raw/LatencyMs/Recovered/Error/Indices/Mocked), with
        LatencyMs fixed at 0.
    #>
    param([string]$Token, [int]$SubCount, [string]$VarName)
    $m = Get-LlmMockResult -MockToken $Token -SubCommandCount $SubCount -VarName $VarName
    $v = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $null; Indices = $null; Mocked = $true }
    if ($m.IsDown) {
        $v.Error = $m.Error
    }
    else {
        $v.Raw = $m.Raw
        $parsed = ConvertTo-LlmVerdict -RawContent $v.Raw -SubCommandCount $SubCount
        $v.Verdict   = $parsed.Verdict
        $v.Recovered = $parsed.Recovered
        $v.Indices   = $parsed.Indices
    }
    return $v
}

function Start-LlmHttpCall {
    <#
    .SYNOPSIS
        Kicks off ONE Invoke-RestMethod inside its own [powershell] runspace
        (design 4.3 - the parallel mechanism, D10). $Payload comes from
        New-LlmRequestBody (built on the MAIN thread - the worker script must
        never reference $script: state). The worker always returns one JSON
        string envelope {"raw":...,"error":...} so the contract is host-proof
        and the error text stays byte-identical to the sync path's IRM
        exception. [powershell]::Create() works identically on Windows
        PowerShell 5.1 and pwsh 7 (why -Parallel/ThreadJob were rejected).
        Returns @{ Ps; Handle; Sw }.
    #>
    param([hashtable]$Payload)
    $workerScript = @'
param([string]$Uri, [string]$BodyJson, [int]$TimeoutSec, [string]$ApiKey)
try {
    $irmParams = @{ Uri = $Uri; Method = 'Post'; Body = $BodyJson; ContentType = 'application/json'; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($ApiKey) { $irmParams['Headers'] = @{ Authorization = "Bearer $ApiKey" } }
    $response = Invoke-RestMethod @irmParams
    $raw = ''
    if ($response.choices -and $response.choices[0].message) { $raw = [string]$response.choices[0].message.content }
    return @{ raw = $raw; error = $null } | ConvertTo-Json -Compress
}
catch {
    return @{ raw = ''; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
'@
    $ps = [powershell]::Create()
    $null = $ps.AddScript($workerScript)
    $null = $ps.AddArgument($Payload.Uri); $null = $ps.AddArgument($Payload.BodyJson)
    $null = $ps.AddArgument($Payload.TimeoutSec); $null = $ps.AddArgument($Payload.ApiKey)
    return @{ Ps = $ps; Handle = $ps.BeginInvoke(); Sw = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Complete-LlmHttpCall {
    <#
    .SYNOPSIS
        Blocks until THAT call finishes (IRM's own TimeoutSec bounds the wait -
        the main thread adds no timeout of its own; EndInvoke order LLM1 then
        LLM2 makes the total wait max(t1,t2), bounded by LLM1's budget, D11),
        parses the worker's JSON envelope, disposes the runspace.
        Returns @{ Raw; Error }.
    #>
    param([hashtable]$Call)
    $raw = ''; $err = $null
    try {
        $out = @($Call.Ps.EndInvoke($Call.Handle))
        if ($out.Count -gt 0) {
            try { $env2 = $out[0] | ConvertFrom-Json } catch { $env2 = $null }
            if ($env2 -and $env2.PSObject.Properties['error'] -and $env2.error) { $err = "$($env2.error)" }
            elseif ($env2 -and $env2.PSObject.Properties['raw']) { $raw = "$($env2.raw)" }
            else { $raw = "$($out[0])" }
        }
    }
    catch { $err = $_.Exception.Message }
    finally { $Call.Ps.Dispose() }
    # Belt-and-braces: a pipeline error that did not throw at EndInvoke
    if (-not $err -and $Call.Ps.Streams.Error -and $Call.Ps.Streams.Error.Count -gt 0) {
        $err = "$($Call.Ps.Streams.Error[0].Exception.Message)"
    }
    return @{ Raw = $raw; Error = $err }
}

function Test-LlmVerdictsAgree {
    <#
    .SYNOPSIS
        Pair comparison (design 4.4, D4/D5). Returns $true / $false / $null
        ($null = not comparable: either side down|unusable). Equality =
        verdict token equal AND index SET equal (order-insensitive, deduped).
        V1 mode: both Indices $null => equal. One-sided indices => NOT equal
        (fail-closed: a lower-fidelity recovered answer must not count as
        agreement - pinned by LT3-20).
    #>
    param($A, $B)
    if ($A.Verdict -in @('down', 'unusable') -or $B.Verdict -in @('down', 'unusable')) { return $null }
    if ("$($A.Verdict)" -ne "$($B.Verdict)") { return $false }
    $ai = $null; $bi = $null
    if ($null -ne $A.Indices) { $ai = @($A.Indices | Sort-Object -Unique) }
    if ($null -ne $B.Indices) { $bi = @($B.Indices | Sort-Object -Unique) }
    if (($null -eq $ai) -xor ($null -eq $bi)) { return $false }
    if ($null -ne $ai) {
        if ($ai.Count -ne $bi.Count) { return $false }
        for ($i = 0; $i -lt $ai.Count; $i++) { if ("$($ai[$i])" -ne "$($bi[$i])") { return $false } }
    }
    return $true
}

function Get-LlmVerdictSummary {
    <#
    .SYNOPSIS
        Human summary of a parsed verdict (design 4.4): "read-only" or
        "modifying indices=[1,2,4]" (indices sorted-unique, joined by ',').
    #>
    param($V)
    $s = "$($V.Verdict)"
    if ("$($V.Verdict)" -eq 'modifying' -and $null -ne $V.Indices -and @($V.Indices).Count -gt 0) {
        $s += " indices=[$(@($V.Indices | Sort-Object -Unique) -join ',')]"
    }
    return $s
}

function Get-Llm2FyiSummary {
    <#
    .SYNOPSIS
        D8 FYI summary: Get-LlmVerdictSummary with the verdict token
        uppercased (e.g. 'MODIFYING indices=[2]', 'READ-ONLY').
    #>
    param($V)
    $tok = "$($V.Verdict)".ToUpperInvariant()
    if ("$($V.Verdict)" -eq 'modifying' -and $null -ne $V.Indices -and @($V.Indices).Count -gt 0) {
        $tok += " indices=[$(@($V.Indices | Sort-Object -Unique) -join ',')]"
    }
    return $tok
}

function New-Llm2SubLog {
    <#
    .SYNOPSIS
        Factory for the llm2 sub-object embedded in the LLM log object
        (design 4.5). Field set mirrors LLM1's log fields; compare defaults to
        'out-of-scope' and every exit path stamps its final value
        (agree|disagree|llm1-down|llm2-down|out-of-scope|
        skipped-trusted-editable|skipped-primary-disabled).
    #>
    param([string]$Model, $EffectiveTimeoutMs, [string]$Compare = 'out-of-scope')
    return [PSCustomObject]@{
        model                = $Model
        effective_timeout_ms = $EffectiveTimeoutMs
        verdict              = $null
        indices              = $null
        latency_ms           = $null
        recovered            = $false
        mocked               = $false
        error                = $null
        raw_excerpt          = $null
        raw_full             = $null
        compare              = $Compare
    }
}

function New-Llm2SkipLog {
    <#
    .SYNOPSIS
        D3 skip log (design 6): llm_third_opinion is enabled but
        llm_second_opinion is disabled/absent - the pair cannot fire without
        its primary. NO LLM calls happen; this log object makes the skip
        records-visible (D13) and renders the dedicated .log line.
    #>
    param([Parameter(Mandatory = $true)][PSCustomObject]$Config)
    $l2 = $Config._compiled.llmThirdOpinion
    return [PSCustomObject]@{
        enabled           = $true
        level             = $null
        in_scope          = $false
        scope_reason      = 'llm_third_opinion enabled but llm_second_opinion disabled - LLM2 skipped'
        sub_command_count = 0
        verdict           = 'not_called'
        effect            = 'skipped-primary-disabled'
        model             = $l2.Model
        latency_ms        = $null
        mocked            = $false
        llm2              = [PSCustomObject]@{
            model                = $l2.Model
            effective_timeout_ms = $l2.EffectiveTimeoutMs
            compare              = 'skipped-primary-disabled'
        }
    }
}

function Get-LlmRunspaceVerdict {
    <#
    .SYNOPSIS
        Wraps a completed runspace HTTP result into the verdict shape
        (design 4.5 wrap): an Error from the worker means Verdict='down'
        (mirrors the sync path's catch); otherwise the layered parser decides.
    #>
    param([hashtable]$R, [System.Diagnostics.Stopwatch]$Sw, [int]$SubCount)
    $v = [PSCustomObject]@{ Verdict = 'down'; Raw = "$($R.Raw)"; LatencyMs = $Sw.ElapsedMilliseconds; Recovered = $false; Error = $null; Indices = $null; Mocked = $false }
    if ($R.Error) {
        $v.Error = $R.Error
    }
    else {
        $parsed = ConvertTo-LlmVerdict -RawContent $R.Raw -SubCommandCount $SubCount
        $v.Verdict   = $parsed.Verdict
        $v.Recovered = $parsed.Recovered
        $v.Indices   = $parsed.Indices
    }
    return $v
}

function Get-LlmDisagreeReason {
    <#
    .SYNOPSIS
        Builds the *** LLM-DISAGREE *** ask reason (design 4.5, D5/D16):
        banner naming both models + their summaries, plus the contested part
        ONLY when the tokens are equal (both 'modifying'): the symmetric-
        difference index set, naming the FIRST contested index that actually
        maps to a sub-command (index 0 is the "unlisted danger" sentinel with
        NO SubCommands entry - PS negative indexing on SubCommands[0-1] would
        silently grab the LAST sub-command; pinned by LT3-27).
    #>
    param($Verdict1, $Verdict2, [string]$Model1, [string]$Model2, $SubCommands)
    $reason = "*** LLM-DISAGREE *** second-opinion LLMs disagree: LLM1 ($Model1) -> $(Get-LlmVerdictSummary $Verdict1) | LLM2 ($Model2) -> $(Get-LlmVerdictSummary $Verdict2) - forced to ask. Review carefully before approving."
    if ("$($Verdict1.Verdict)" -eq "$($Verdict2.Verdict)" -and $null -ne $Verdict1.Indices -and $null -ne $Verdict2.Indices) {
        $setA = @($Verdict1.Indices | Sort-Object -Unique); $setB = @($Verdict2.Indices | Sort-Object -Unique)
        $diff = @(($setA + $setB) | Sort-Object -Unique | Where-Object { ($setA -notcontains $_) -or ($setB -notcontains $_) })
        if ($diff.Count -gt 0) {
            $subCount = @($SubCommands).Count
            # Scalar (NOT @()) so "no valid index" is genuinely $null.
            $firstIdx = $diff | Where-Object { $_ -ge 1 -and $_ -le $subCount } | Select-Object -First 1
            if ($null -ne $firstIdx) {
                $ft = "$($SubCommands[$firstIdx - 1].Command)"
                if ($ft.Length -gt 120) { $ft = $ft.Substring(0, 120) }
                $reason += " | contested: [$($diff -join ',')] '$ft'"
            }
            # A diff of {0} ONLY (e.g. [0,1] vs [1]) renders NO contested part
            # at all - nothing valid to name (LT3-27 pins this).
        }
    }
    return $reason
}

function Get-LlmBlindspotPairNote {
    <#
    .SYNOPSIS
        D9 blindspot pair note (design 4.5 step 6): the blindspot decision
        NEVER changes; the pair only appends an FYI fragment to the reason.
        agree -> ' | LLM2 agrees'; disagree -> ' | LLM2 DISAGREES: <sum1> vs
        <sum2>'; llm2 failed (agree $null) -> nothing.
    #>
    param($Agree, $Verdict1, $Verdict2)
    if ($Agree -eq $true) { return " | LLM2 agrees" }
    if ($Agree -eq $false) { return " | LLM2 DISAGREES: $(Get-LlmVerdictSummary $Verdict1) vs $(Get-LlmVerdictSummary $Verdict2)" }
    return ''
}

function Get-LlmPairCompareState {
    <#
    .SYNOPSIS
        Maps the tri-state comparison result to the llm2.compare value when
        the pair falls through WITHOUT the disagree early return (design 4.5):
        $true -> 'agree'; $false -> 'disagree' (blindspot-only path - every
        non-blindspot disagreement returned above); $null -> 'llm1-down' when
        LLM1 itself failed (its failure drives the decision; LLM2's state
        stays visible in llm2.verdict/error) else 'llm2-down'.
    #>
    param($Agree, $Verdict1)
    if ($Agree -eq $true) { return 'agree' }
    if ($Agree -eq $false) { return 'disagree' }
    if ($Verdict1.Verdict -in @('down', 'unusable')) { return 'llm1-down' }
    return 'llm2-down'
}

function Get-Llm2SubLogFromVerdict {
    <#
    .SYNOPSIS
        Stamps an llm2 sub-log from a completed LLM2 verdict (design 4.5):
        same excerpting rules as LLM1 (ws-collapsed, raw_display_limit cap).
    #>
    param($Verdict2, [PSCustomObject]$SubLog, [int]$DisplayLimit)
    $SubLog.verdict     = $Verdict2.Verdict
    $SubLog.indices     = $Verdict2.Indices
    $SubLog.latency_ms  = $Verdict2.LatencyMs
    $SubLog.recovered   = $Verdict2.Recovered
    $SubLog.mocked      = $Verdict2.Mocked
    if ($Verdict2.Error) { $SubLog.error = $Verdict2.Error }
    if ($Verdict2.Raw) {
        $excerpt = ($Verdict2.Raw -replace '\s+', ' ').Trim()
        if ($excerpt.Length -gt $DisplayLimit) { $excerpt = $excerpt.Substring(0, $DisplayLimit) }
        $SubLog.raw_excerpt = $excerpt
        $SubLog.raw_full = "$($Verdict2.Raw)"
    }
    elseif ($Verdict2.Error) {
        $errExcerpt = ($Verdict2.Error -replace '\s+', ' ').Trim()
        if ($errExcerpt.Length -gt $DisplayLimit) { $errExcerpt = $errExcerpt.Substring(0, $DisplayLimit) }
        $SubLog.raw_excerpt = $errExcerpt
    }
    return $SubLog
}

function Get-LlmPairVerdicts {
    <#
    .SYNOPSIS
        Pair verdict acquisition (design 4.5 step 4). Per-SIDE mock gate
        (v3 borrow): each side is independently mock-or-HTTP; runspaces are
        started ONLY for the HTTP sides, both BEFORE either completes
        (parallelism preserved, wall-clock ~ max(t1,t2)). MOCK2 unset falls
        back to MOCK (identical raw -> agree - the regression baseline, D12).
        MOCK2 set while MOCK unset is legal: LLM1 does a REAL HTTP call while
        LLM2 is mocked (pinned by LT3-22). LLM2's TimeoutSec is the D11 clamp
        (EffectiveTimeoutMs). Returns @{ Verdict1; Verdict2 }.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Llm1,
        [Parameter(Mandatory = $true)][PSCustomObject]$Llm2,
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$SubCommands = @()
    )
    $subCount = @($SubCommands).Count
    $mock1 = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    $mock2 = if ($env:PRETOOLHOOK_LLMREVIEW_MOCK2) { $env:PRETOOLHOOK_LLMREVIEW_MOCK2 } else { $mock1 }

    $ep2 = [PSCustomObject]@{ BaseUri = $Llm2.BaseUri; Model = $Llm2.Model; ApiKey = $Llm2.ApiKey }
    $p1 = $null; $p2 = $null
    if (-not $mock1) { $p1 = New-LlmRequestBody -Command $Command -Llm1Config $Llm1 -EndpointConfig $Llm1 -SubCommands $SubCommands }
    if (-not $mock2) {
        $p2 = New-LlmRequestBody -Command $Command -Llm1Config $Llm1 -EndpointConfig $ep2 -SubCommands $SubCommands
        $p2.TimeoutSec = [int][math]::Ceiling($Llm2.EffectiveTimeoutMs / 1000.0)   # D11 clamp
    }
    $c1 = if ($p1) { Start-LlmHttpCall -Payload $p1 } else { $null }
    $c2 = if ($p2) { Start-LlmHttpCall -Payload $p2 } else { $null }

    if ($mock1) { $verdict1 = New-MockVerdict -Token $mock1 -SubCount $subCount -VarName 'PRETOOLHOOK_LLMREVIEW_MOCK' }
    else {
        $r1 = Complete-LlmHttpCall -Call $c1; $c1.Sw.Stop()
        $verdict1 = Get-LlmRunspaceVerdict -R $r1 -Sw $c1.Sw -SubCount $subCount
    }
    if ($mock2) { $verdict2 = New-MockVerdict -Token $mock2 -SubCount $subCount -VarName 'PRETOOLHOOK_LLMREVIEW_MOCK2' }
    else {
        $r2 = Complete-LlmHttpCall -Call $c2; $c2.Sw.Stop()
        $verdict2 = Get-LlmRunspaceVerdict -R $r2 -Sw $c2.Sw -SubCount $subCount
    }
    return [PSCustomObject]@{ Verdict1 = $verdict1; Verdict2 = $verdict2 }
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
    # 2026-09-30 pair design 4.2: the grammar moved VERBATIM into the shared
    # Get-LlmMockResult helper (both pair sides use it); the VarName passed
    # here is the same env var name as before, so LLM1's throw message stays
    # byte-identical.
    $mock = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    if ($mock) {
        $result.Mocked = $true
        $m = Get-LlmMockResult -MockToken $mock -SubCommandCount $subCount -VarName 'PRETOOLHOOK_LLMREVIEW_MOCK'
        if ($m.IsDown) {
            $result.Verdict = 'down'; $result.Error = $m.Error
        }
        else {
            $result.Raw = $m.Raw
            $parsed = ConvertTo-LlmVerdict -RawContent $result.Raw -SubCommandCount $subCount
            $result.Verdict   = $parsed.Verdict
            $result.Recovered = $parsed.Recovered
            $result.Indices   = $parsed.Indices
        }
        $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
        return $result
    }

    # 2026-09-30 pair design 4.1: request building extracted VERBATIM into
    # New-LlmRequestBody (two-parameter form; here LLM1 supplies BOTH
    # prompt/sampling and transport - byte-identical payload to before).
    $payload = New-LlmRequestBody -Command $Command -Llm1Config $LlmConfig -EndpointConfig $LlmConfig -SubCommands $SubCommands
    try {
        $irmParams = @{
            Uri         = $payload.Uri
            Method      = 'Post'
            Body        = $payload.BodyJson
            ContentType = 'application/json'
            TimeoutSec  = $payload.TimeoutSec
            ErrorAction = 'Stop'
        }
        if ($payload.ApiKey) { $irmParams['Headers'] = @{ Authorization = "Bearer $($payload.ApiKey)" } }
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

# NOTE (2026-09-18, R2): Split-GuardTokens was relocated to Parser.ps1 so that
# Resolver.ps1's Step 0g-delete can use it under the TestRunner load graph
# (TestRunner dot-sources Parser but NOT LlmReview). It is defined there and
# loaded before this file in every entry path, so the calls below still resolve.

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

    # llm_third_opinion pair (design 4.5 step 1): armed when the third block
    # exists AND is enabled. LLM2 fires iff LLM1 fires and is in scope (D1);
    # when not armed every path below is byte-identical to before the feature.
    $llm2 = $Config._compiled.llmThirdOpinion
    $pairArmed = ($null -ne $llm2 -and $llm2.Enabled)

    # ----------------------------------------------------------------
    # R2 (2026-09-18, spec 4.6 / OQ-1): SKIP the LLM call entirely when EVERY
    # in-scope sub-command tier is in {trusted_program, editable_path,
    # editable_delete}. Those tiers are locally authoritative AND unconditionally
    # veto-suppressed (spec 4.4), so the LLM's answer cannot change the decision
    # either way — the call is pure latency plus an LLM-DOWN failure mode. Skipping
    # makes fully trusted/editable blocks immune to gateway outages. The list is the
    # SAME one the LLM would receive (post scope-filtering, redirection-target
    # entries already excluded). Empty list -> no skip (out of scope anyway).
    # check_blindspot blocks are NOT skipped: their trigger tiers (unclassified,
    # unregistered_*, unknown_domain) are by construction absent from an all-
    # trusted/editable block, so this cannot suppress a blindspot consult.
    # ----------------------------------------------------------------
    if ($scope.InScope -and -not $isCheckBlindspot -and $scope.SubCommands.Count -gt 0) {
        $skipTiers = @('trusted_program', 'editable_path', 'editable_delete')
        $allTrustedEditable = $true
        foreach ($sub in $scope.SubCommands) {
            if ("$($sub.Tier)" -notin $skipTiers) { $allTrustedEditable = $false; break }
        }
        if ($allTrustedEditable) {
            $log.effect = 'llm-skipped-trusted-editable'
            # D14: the pair is skipped too (LLM2 fires iff LLM1 fires) and the
            # skip is SELF-DOCUMENTED in records - NOT encoded by llm2 absence.
            if ($pairArmed) {
                $log | Add-Member -MemberType NoteProperty -Name 'llm2' -Force -Value (
                    New-Llm2SubLog -Model $llm2.Model -EffectiveTimeoutMs $llm2.EffectiveTimeoutMs -Compare 'skipped-trusted-editable')
            }
            return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
        }
    }

    # Numbered list for the prompt AND the index lookup (spec P2: same list).
    # script_drilldown DisplayText (2026-09-20, spec 8.5): render the
    # '<script:basename> <stmt>' form when present so the LLM prompt + $log.sent
    # carry the origin prefix; fall back to Command for non-drilldown entries.
    $subTexts = @($scope.SubCommands | ForEach-Object {
        if ($_.PSObject.Properties['DisplayText']) { "$($_.DisplayText)" } else { "$($_.Command)" }
    })
    $log.sent  = $subTexts
    $log.tiers = @($scope.SubCommands | ForEach-Object { "$($_.Tier)" })
    $log.local_decision = $ClassifyResult.Decision
    $log.local_reason   = "$($ClassifyResult.Reason)"

    if (-not $scope.InScope) {
        # D13: with the pair armed, out-of-scope still stamps the llm2 sub-log
        # (compare='out-of-scope') so the state is records-visible.
        # (check_blindspot consults ARE in scope - the scope function marks
        # them - so they continue past this gate to the pair.)
        if ($pairArmed) {
            $log | Add-Member -MemberType NoteProperty -Name 'llm2' -Force -Value (
                New-Llm2SubLog -Model $llm2.Model -EffectiveTimeoutMs $llm2.EffectiveTimeoutMs -Compare 'out-of-scope')
        }
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    # ----------------------------------------------------------------
    # Verdict acquisition (design 4.5 step 4). Not armed: today's SYNCHRONOUS
    # LLM1 path, byte-identical. Armed: parallel PAIR - identical prompt +
    # sampling for both endpoints (D2), transport per endpoint, LLM2's
    # timeout clamped (D11).
    # ----------------------------------------------------------------
    if (-not $pairArmed) {
        $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm -SubCommands $subTexts
        $verdict2 = $null
    }
    else {
        $pair = Get-LlmPairVerdicts -Llm1 $llm -Llm2 $llm2 -Command $ClassifyResult.Command -SubCommands $subTexts
        $verdict = $pair.Verdict1
        $verdict2 = $pair.Verdict2
    }
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
    # Pair stamping + comparison (design 4.5 step 4, D4/D5). COMPARE on the
    # RAW parsed verdicts, BEFORE any policy suppression (D5): a disagreement
    # is an unconditional forced ask even when the contested index sits in
    # trusted/editable territory (pinned by LT3-19).
    # ----------------------------------------------------------------
    $agree = $null
    if ($pairArmed) {
        $log | Add-Member -MemberType NoteProperty -Name 'llm2' -Force -Value (
            Get-Llm2SubLogFromVerdict -Verdict2 $verdict2 -SubLog (New-Llm2SubLog -Model $llm2.Model -EffectiveTimeoutMs $llm2.EffectiveTimeoutMs) -DisplayLimit $log.raw_display_limit)
        # Tri-state: $true/$false/$null ($null = not comparable, either side
        # down|unusable). Explicit $null -ne guard makes the tri-state intent
        # refactor-proof (style, per design 10.2 - $null -eq $false is $false
        # on both hosts, verified by debug/_probe_tristate_guard.ps1).
        $agree = Test-LlmVerdictsAgree -A $verdict -B $verdict2
        # D9 GUARD: the disagree early-return must NOT fire on check_blindspot
        # consults - rewriting the reason would destroy the *** CHECK_BLINDSPOT
        # *** headline and violate D9 (FYI only; effect stays
        # check-blindspot-ask). Blindspot disagreements fall through; the
        # blindspot branch renders the 'LLM2 DISAGREES' FYI. Pinned by LT3-12.
        if ($null -ne $agree -and -not $agree -and -not $isCheckBlindspot) {
            $log.llm2.compare = 'disagree'
            $log.effect       = 'llm2-disagree'
            $reason = Get-LlmDisagreeReason -Verdict1 $verdict -Verdict2 $verdict2 -Model1 $llm.Model -Model2 $llm2.Model -SubCommands $scope.SubCommands
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason   = "$reason | local reason: $localReason"
            return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
        }
        # agree / not-comparable / blindspot-disagree -> fall through to
        # today's flow with the compare state stamped.
        $log.llm2.compare = Get-LlmPairCompareState -Agree $agree -Verdict1 $verdict
    }

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
        # D9 pair note (design 4.5 step 6): agree -> ' | LLM2 agrees';
        # disagree -> ' | LLM2 DISAGREES: <sum1> vs <sum2>'; LLM2 failed ->
        # nothing extra (the headline already says which LLM state). The
        # decision NEVER changes; effect stays check-blindspot-ask.
        if ($pairArmed) {
            $ClassifyResult.Reason += (Get-LlmBlindspotPairNote -Agree $agree -Verdict1 $verdict -Verdict2 $verdict2)
        }
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
                # strict_gate_override_llm (2026-09-16, default false): when true, a
                # local strictness_gated decision UNCONDITIONALLY overpowers an online
                # LLM veto (trusted_program-style; path guard bypassed). When false/
                # absent, today's reconciliation stands (the path guard decides).
                $gateOverride = ($Config._compiled.llmSecondOpinion -and
                    $Config._compiled.llmSecondOpinion.StrictGateOverrideLlm)
                foreach ($ix in $verdict.Indices) {
                    if ($ix -eq 0) { $vetoIdx += 0; continue }   # unlisted danger: never suppressible (P3)
                    $sub = $scope.SubCommands[$ix - 1]
                    $isGated = ($sub -and $sub.Tier -eq 'strictness_gated')
                    # Option B: a trusted_program sub-command is UNCONDITIONALLY
                    # suppressible. The user explicitly whitelisted this program in
                    # trusted_programs, and the local engine already validated it via
                    # Test-StatementContainsModifying (no embedded modifying command)
                    # before stamping the tier. That explicit trust overrides a remote
                    # LLM veto - no path guard is applied (the trust IS the safety
                    # decision; gating it would contradict the whitelist).
                    $isTrusted = ($sub -and $sub.Tier -eq 'trusted_program')
                    # R2 (2026-09-18, spec 4.4): a path-policy allow tier (editable_path
                    # from a redirect to an editable/CWD/temp target, or editable_delete
                    # from Step 0g-delete) is UNCONDITIONALLY suppressible — the user's
                    # editable_paths are trusted territory and the local engine already
                    # validated every target via the path-policy ladder. INV-2: this
                    # authority trumps a remote LLM veto.
                    $isPathPolicyAllow = ($sub -and $sub.Tier -in @('editable_path', 'editable_delete'))
                    if ($isTrusted) {
                        $suppIdx += $ix
                    }
                    elseif ($isPathPolicyAllow -and -not (Test-CommandTargetsSystemPaths -Command $sub.Command -Config $Config)) {
                        # Belt-and-braces INV-3 guard: by construction the ladder can
                        # never produce an allow tier for a system target, so this only
                        # defends against future regressions. If ANY literal path token in
                        # the sub-command text canonicalizes to a system path, DENY the
                        # suppression (veto stands) and record why.
                        $suppIdx += $ix
                    }
                    elseif ($isGated -and $gateOverride) {
                        # Switch on: local gated decision overpowers the LLM, exactly
                        # like trusted_program (path guard bypassed).
                        $suppIdx += $ix
                    }
                    elseif ($isGated -and (Test-GatedInvocationSafe -Command $sub.Command -Config $Config)) {
                        $suppIdx += $ix
                    }
                    else {
                        $vetoIdx += $ix
                        # A gated flag the stage-2 guard REFUSED to suppress
                        # (protected-path target / unproven variable) - recorded
                        # so the reconciliation log can say WHY.
                        if ($isGated) { $pgDenied += $ix }
                        # R2: a path-policy tier the INV-3 system guard REFUSED to
                        # suppress (a system path appears in the command text).
                        if ($isPathPolicyAllow) { $pgDenied += $ix }
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
            # D8 (design 4.5 step 5): with the pair armed and LLM2 holding a
            # REAL verdict, append the non-authoritative FYI. If LLM2 also
            # failed, append nothing (both errors are already in the log).
            if ($pairArmed -and $verdict2.Verdict -in @('read-only', 'modifying')) {
                $ClassifyResult.Reason += " | LLM2 second-opinion (no authority, FYI): $(Get-Llm2FyiSummary $verdict2)"
            }
            $log.effect = 'forced-ask'
        }
        'unusable' {
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason = "*** LLM-UNUSABLE *** LLM returned an unparseable response - forced to ask. Raw: '$($log.raw_excerpt)' | local verdict: $localDecision | local reason: $localReason"
            if ($pairArmed -and $verdict2.Verdict -in @('read-only', 'modifying')) {
                $ClassifyResult.Reason += " | LLM2 second-opinion (no authority, FYI): $(Get-Llm2FyiSummary $verdict2)"
            }
            $log.effect = 'forced-ask'
        }
    }
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
}
