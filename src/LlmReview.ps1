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

    # (Task 4 adds the verdict call + merge matrix here.)
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
}
