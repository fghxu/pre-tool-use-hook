<#
.SYNOPSIS
    Pattern matching engine — classifies a single sub-command against config.json.

.DESCRIPTION
    Resolver.ps1 provides Resolve-Command, which takes a sub-command string, its
    detected domain, and the pre-compiled Config object (from ConfigLoader.ps1).
    It matches the command against explicit read_only/modifying regex patterns first,
    then falls back to verb-based classification (PowerShell) or prefix-based
    classification (AWS CLI), and finally returns an allow/ask decision.

    Match order per domain:
      1. Explicit "read_only" entries (compiled regex)
      1a.5. Explicit "strictness_gated" entries (allow in normal/loose, ask in strict
            per Get-EffectiveStrictness)
      2. Explicit "modifying" entries (compiled regex)
      3. Verb-based classification (PowerShell / AWS domains only)
      4. Fallback: ask with reason "unknown command" (or "static method not on
         allowlist: [Type]::Method (...)" when the command is an unallowlisted
         static .NET method call)
#>

# Step 0g-delete (R2, 2026-09-18): canonical list of deletion commands. A
# sub-command whose first token (basename, extension stripped, case-insensitive)
# is in this set enters the path-aware deletion branch: if EVERY extracted target
# canonicalizes under an editable path / CWD / temp form it is allowed (tier
# editable_delete); system/foreign/unresolvable targets still ask. Domain-agnostic
# — 'rm' (Linux) and 'Remove-Item' (PowerShell) both enter the branch. Single
# obvious place to extend (same pattern as $script:LlmGuardWriterCommands).
$script:PathPolicyDeleters = @(
    'remove-item', 'rm', 'del', 'ri', 'erase', 'rd', 'rmdir', 'unlink', 'clear-content'
)

function Get-EffectiveStrictness {
    <#
    .SYNOPSIS
        Resolve the effective modifying_strictness for a command domain.
    .DESCRIPTION
        Guard rule: a global 'strict' or 'loose' (global_modifying_strictness)
        forces ALL domains. Only when the global value is 'normal' does a domain's
        own modifying_strictness apply; domains without one inherit 'normal'.
        Used by the strictness_gated tier, AWS flag-stripping, and
        parameter_commands unrecognized-value handling.
        Path policy (Parser.ps1) intentionally stays on the global value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        # Optional parameter_commands entry carrying its own modifying_strictness.
        # Consulted AFTER the global guard and BEFORE the domain value (2026-09-16
        # subcommand framework). Existing callers pass nothing -> unchanged behavior.
        $Entry = $null
    )

    if ($Config.global_modifying_strictness -ne 'normal') { return $Config.global_modifying_strictness }

    if ($Entry -and (Get-Member -InputObject $Entry -Name 'modifying_strictness' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        return $Entry.modifying_strictness
    }

    foreach ($key in $Config.commands.PSObject.Properties.Name) {
        if ($key.ToLowerInvariant() -eq $Domain.ToLowerInvariant()) {
            $dom = $Config.commands.$key
            if (Get-Member -InputObject $dom -Name 'modifying_strictness' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                return $dom.modifying_strictness
            }
            break
        }
    }
    return 'normal'
}

function Resolve-Command {
    <#
    .SYNOPSIS
        Classify a single sub-command against config.json patterns.

    .DESCRIPTION
        Takes a command string, its detected domain, and the pre-loaded/pre-compiled
        Config object. Checks explicit read_only and modifying pattern entries first
        (first match wins), then performs verb-based or prefix-based classification
        for PowerShell and AWS CLI domains, and finally returns an allow/ask decision.

    .PARAMETER Command
        The sub-command string to classify (e.g., "Get-Process -Name pwsh",
        "aws s3 ls my-bucket", "kubectl get pods").

    .PARAMETER Domain
        The detected domain tag for this command. Case-insensitive. Expected values:
        "powershell", "aws", "linux", "dos", "docker", "kubernetes", "terraform".

    .PARAMETER Config
        The pre-loaded PSCustomObject from Load-Config. Must contain the
        validated "commands" section with compiled `_compiledPatterns` on each
        pattern entry.

    .OUTPUTS
        PSCustomObject with keys:
        - Command   (string)  : The original sub-command string.
        - Decision  (string)  : "allow" or "ask".
        - Reason    (string)  : Human-readable explanation.
        - MatchedPattern (string|null) : Name of the matched entry, or $null.
        - Risk      (string)  : "none", "low", "medium", "high", or "unknown".

    .EXAMPLE
        $result = Resolve-Command -Command "Get-Process" -Domain "powershell" -Config $config
        # Returns: allow, reason "Get-Process (read-only verb: Get-*)"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        # R2 (2026-09-18): true when this sub-command executes on a REMOTE host
        # (ssh / docker exec / kubectl exec). Local path policy (editable_paths /
        # CWD / temp) must NOT auto-allow deletions that run remotely — the target
        # is not on this machine. Step 0g-delete skips remote sub-commands so they
        # fall through to the existing tiers (pre-change ask behavior preserved).
        [bool]$IsRemote = $false
    )

    # -------------------------------------------------
    # Helper: build the standard return object
    # -------------------------------------------------
    function New-ResolutionResult {
        param([string]$Decision, [string]$Reason, [string]$MatchedPattern, [string]$Risk, [string]$Tier = '')
        return [PSCustomObject]@{
            Command        = $Command
            Decision       = $Decision
            Reason         = $Reason
            MatchedPattern = $MatchedPattern
            Risk           = $Risk
            Tier           = $Tier
        }
    }

    # -------------------------------------------------
    # Safe-expression synthetic marker from Parser.ps1
    # -------------------------------------------------
    if ($Command -eq '(safe expression)') {
        return New-ResolutionResult -Decision "allow" -Reason "safe expression" -MatchedPattern $null -Risk "none" -Tier "safe_expr"
    }

    # -------------------------------------------------
    # Step 0: Normalize domain name to lowercase, then case-insensitive lookup
    # -------------------------------------------------
    $domainLower = $Domain.ToLowerInvariant()
    $domainKey = $null
    foreach ($key in $Config.commands.PSObject.Properties.Name) {
        if ($key.ToLowerInvariant() -eq $domainLower) {
            $domainKey = $key
            break
        }
    }

    if (-not $domainKey) {
        return New-ResolutionResult -Decision "ask" -Reason "unknown domain: $Domain" -MatchedPattern $null -Risk "unknown" -Tier "unknown_domain"
    }

    $domainConfig = $Config.commands.$domainKey

    # -------------------------------------------------
    # Step 0b: Variable assignment strip (domain-agnostic)
    #   "$computers = Get-Content ..." → "Get-Content ..."
    #   "$creds = aws sts get-caller-identity" → "aws sts get-caller-identity"
    #   After stripping, re-detect domain and recurse.
    # -------------------------------------------------
    if ($Command -match '^\s*\$[\w:]+\s*=\s*') {
        $strippedCmd = $Command -replace '^\s*\$[\w:]+\s*=\s*', ''
        if ($strippedCmd -and $strippedCmd -ne $Command) {
            $redetectedDomain = Get-CommandDomain -Command $strippedCmd
            return Resolve-Command -Command $strippedCmd -Domain $redetectedDomain -Config $Config -IsRemote $IsRemote
        }
    }

    # -------------------------------------------------
    # Step 0c: Linux/DOS sudo prefix stripping
    #   "sudo cat /opt/a.txt" → "cat /opt/a.txt"
    #   "sudo -u root cat /opt/a.txt" → "cat /opt/a.txt"
    # -------------------------------------------------
    if ($domainLower -in @('linux', 'dos_cmd') -and $Command -match '^\s*sudo\s') {
        $stripped = $Command -replace '^\s*sudo\s+', ''
        $tokens = @($stripped -split '\s+')
        $startIdx = 0
        $valueFlags = @('-u', '-g', '-p', '-c', '-h',
                        '--user', '--group', '--prompt', '--chdir',
                        '--host', '--close-from', '--login-class', '--other-user')
        while ($startIdx -lt $tokens.Count -and $tokens[$startIdx].StartsWith('-')) {
            $flag = $tokens[$startIdx]
            $startIdx++
            if ($valueFlags -contains $flag -and $startIdx -lt $tokens.Count) {
                $startIdx++
            }
        }
        if ($startIdx -lt $tokens.Count -and $tokens[$startIdx] -eq '--') {
            $startIdx++
        }
        if ($startIdx -lt $tokens.Count) {
            $remainingCommand = ($tokens[$startIdx..($tokens.Count - 1)] -join ' ').Trim()
            if ($remainingCommand) {
                $redetectedDomain = Get-CommandDomain -Command $remainingCommand
                return Resolve-Command -Command $remainingCommand -Domain $redetectedDomain -Config $Config -IsRemote $IsRemote
            }
        }
    }

    # NOTE: the former "Step 0d: Git global option stripping" block was REMOVED
    # (2026-09-16 parameter_commands rework). git no longer routes to a 'git'
    # domain, so it classifies via Linux.parameter_commands.git (Step 7), whose
    # subcommand walker consumes global_value_flags (-C/-c/--git-dir/...) directly.

    # -------------------------------------------------
    # Step 0e: AWS flag stripping (normal mode)
    #   In "normal" mode, strip --flags from AWS CLI commands so only
    #   the service + verb determine classification.
    #   "aws --profile prod ec2 --region us-east-1 describe-instances --filters ..."
    #     → "aws ec2 describe-instances"
    #   In "strict" mode, current behavior is preserved (unknown flags → ask).
    # -------------------------------------------------
    if ($domainLower -eq 'aws_cli' -and (Get-EffectiveStrictness -Config $Config -Domain $domainKey) -eq 'normal' -and $Command -match '^aws\s') {
        $awsTokens = @($Command.Trim() -split '\s+')
        $awsFiltered = [System.Collections.Generic.List[string]]::new()
        $i = 0
        while ($i -lt $awsTokens.Count) {
            $tok = $awsTokens[$i]
            if ($tok.StartsWith('--') -and $tok -ne '--') {
                # --flag: strip it (and its value if not embedded with =)
                if ($tok -match '=') {
                    # --flag=value, value is embedded, skip this token
                    $i++
                }
                elseif (($i + 1) -lt $awsTokens.Count -and -not $awsTokens[$i + 1].StartsWith('-') -and -not $awsTokens[$i + 1].StartsWith('(')) {
                    # --flag value, skip both the flag and its value.
                    # A value starting with '(' is a PowerShell subexpression
                    # (e.g. --request-id (aws ... ).Prop), NOT a flag value -
                    # consuming it mangles the command and hides the inner
                    # command from classification (2026-08-02 hole).
                    $i += 2
                }
                else {
                    # boolean --flag, skip this token
                    $i++
                }
            }
            else {
                $awsFiltered.Add($tok)
                $i++
            }
        }
        $awsNormalized = ($awsFiltered -join ' ').Trim()
        # Guard: stripping must leave at least a service + operation (2+ tokens).
        # If it would leave bare "aws" (e.g., "aws --version"), keep the original
        # command so explicit read_only entries like "aws --version" can match.
        if ($awsNormalized -ne $Command.Trim() -and ($awsNormalized -split '\s+').Count -ge 2) {
            return Resolve-Command -Command $awsNormalized -Domain $Domain -Config $Config -IsRemote $IsRemote
        }
    }

    # -------------------------------------------------
    # Step 0f: Full-path stripping (domain-agnostic)
    #   "C:\Program Files\Git\bin\git.exe" status → "git status"
    #   "/usr/bin/grep pattern file" → "grep pattern file"
    #   Strips directory prefix, strips .exe/.com extensions,
    #   re-detects domain, and recurses.
    # -------------------------------------------------
    $trimmedForPath = $Command.Trim()

    # Strip PowerShell call operator & (e.g., & "C:\tools\tool.exe" args)
    $trimmedForPath = $trimmedForPath -replace '^\s*&\s+', ''

    # Strip PowerShell dot-source operator . (e.g., . 'C:\scripts\helper.ps1' args)
    # The dot-source operator runs a script in the current scope; it is not a
    # command itself — the script path is the real program token.
    $trimmedForPath = $trimmedForPath -replace '^\s*\.\s+', ''

    # Extract first token (handling quoted paths with spaces, both " and ')
    $firstToken = $null
    $rest = ''
    if ($trimmedForPath -match '^"([^"]+)"\s*(.*)$') {
        $firstToken = $matches[1]
        $rest = $matches[2]
    }
    elseif ($trimmedForPath -match "^'([^']+)'\s*(.*)`$") {
        $firstToken = $matches[1]
        $rest = $matches[2]
    }
    else {
        if ($trimmedForPath -match '^(\S+)\s*(.*)$') {
            $firstToken = $matches[1]
            $rest = $matches[2]
        }
    }

    # -------------------------------------------------
    # Step 0f-trust: Trusted-program allowlist (Option B, post-decomposition)
    #   If the program token ($firstToken, in its ORIGINAL form before the
    #   full-path recursion below) matches a trusted_programs entry, allow THIS
    #   sub-command unless a modifying command appears among its arguments.
    #   Placed before the recursion (:298) so full-path program tokens are
    #   matchable, and before the read_only/modifying tiers so a trusted program
    #   is not reported as unknown. The Classifier's worst-case-wins aggregation
    #   still forces 'ask' when a modifying SIBLING statement is present, so this
    #   only decides the trusted invocation itself.
    # -------------------------------------------------
    if ($firstToken) {
        $trustedProg = Test-TrustedProgram -Token $firstToken -Config $Config
        if ($trustedProg) {
            # R1: a regex hit is returned as 'regex:<pattern>'. Report the
            # pattern (not the 'regex:' marker) in the human-facing reason.
            $isRegexTrust = $trustedProg.StartsWith('regex:')
            $trustDisplay = if ($isRegexTrust) { $trustedProg.Substring(6) } else { $trustedProg }
            $modToken = Test-StatementContainsModifying -ArgsText $rest -Config $Config
            if ($modToken) {
                return New-ResolutionResult -Decision "ask" `
                    -Reason "trusted program '$trustDisplay' invoked with modifying arg '$modToken'" `
                    -MatchedPattern $trustedProg -Risk "unknown" -Tier "trusted_program"
            }
            $trustReason = if ($isRegexTrust) { "trusted program (regex): $trustDisplay" } else { "trusted program: $trustDisplay" }
            return New-ResolutionResult -Decision "allow" `
                -Reason $trustReason -MatchedPattern "trusted-program:$trustedProg" -Risk "none" -Tier "trusted_program"
        }
    }

    $isFullPath = $false
    $programName = $null

    # Windows full path: starts with drive letter + colon + backslash
    if ($firstToken -and $firstToken -match '^[A-Za-z]:\\') {
        $isFullPath = $true
        $basename = $firstToken -replace '^.*\\', ''
        # Strip .exe and .com extensions (keep .bat/.cmd/.ps1 — they are scripts)
        if ($basename -match '^(.+)\.(exe|com)$') {
            $programName = $matches[1]
        }
        else {
            $programName = $basename
        }
    }
    # Linux full path: starts with /, has at least one directory separator
    elseif ($firstToken -and $firstToken -match '^/(?:[^/\s]+/)+[^/\s]+$') {
        $isFullPath = $true
        $programName = $firstToken -replace '^.*/', ''
    }

    if ($isFullPath -and $programName) {
        $newCmd = if ($rest) { "$programName $rest" } else { $programName }
        if ($newCmd -ne $Command.Trim()) {
            $redetectedDomain = Get-CommandDomain -Command $newCmd
            return Resolve-Command -Command $newCmd -Domain $redetectedDomain -Config $Config -IsRemote $IsRemote
        }
    }

    # -------------------------------------------------
    # Step 0g-delete: path-aware deletion classification (R2, 2026-09-18)
    #   If the program token is a known deleter, extract its filesystem targets
    #   and decide by the path-policy ladder (system -> fail-closed -> editable/
    #   CWD/temp allow -> foreign ask). Placed AFTER full-path recursion so
    #   'c:\tools\rm.exe x' normalizes to 'rm x' first, and BEFORE the pattern
    #   tiers so a modifying DB entry never fires when the path policy already
    #   decided. Mirrors how redirects bypass command tiers via a dedicated
    #   path check. If NO target can be extracted the branch does NOT decide —
    #   the command falls through to the existing tiers (today's behavior).
    # -------------------------------------------------
    if ($firstToken -and -not $IsRemote) {
        # R2: local deletions only. A remote sub-command (ssh / docker exec /
        # kubectl exec) deletes on ANOTHER host, so this machine's editable_paths /
        # CWD / temp policy must not auto-allow it — skip the carve-out and let the
        # existing tiers decide (pre-change ask behavior preserved).
        # Preserve the ORIGINAL casing of the program token for MatchedPattern: the
        # Classifier's top-level reason is built as "<MatchedPattern> (<Risk>)", so
        # 'Remove-Item' must keep its capital to read naturally and to match the
        # pre-change modifying-tier convention (the config entry name). A lowercased
        # copy drives only the $script:PathPolicyDeleters membership test.
        $delName = $firstToken.Trim()
        try { $delName = [System.IO.Path]::GetFileNameWithoutExtension($delName) } catch { }
        $delNameLower = $delName.ToLowerInvariant()
        if ($script:PathPolicyDeleters -contains $delNameLower) {
            # --- Target extraction (quote-aware tokenizer, shared from Parser.ps1) ---
            $argTokens = @(Split-GuardTokens $rest)
            $pathParams  = @('path', 'literalpath', 'lp', 'p')
            $nonTargets  = @('filter', 'include', 'exclude')
            $targets = @()
            $i = 0
            while ($i -lt $argTokens.Count) {
                $t = $argTokens[$i]
                if (-not $t) { $i++; continue }
                # Path-bearing parameter: its VALUE (next token, or :value same-token) is a target.
                if ($t.StartsWith('-') -and $t.Length -gt 1) {
                    $pname = $t.Substring(1).ToLowerInvariant()
                    if ($pathParams -contains $pname) {
                        if ($t.Contains(':')) {
                            $val = $t.Substring($t.IndexOf(':') + 1)
                            if ($val) { $targets += $val }
                        } elseif (($i + 1) -lt $argTokens.Count) {
                            $targets += $argTokens[$i + 1]; $i++
                        }
                    }
                    # Non-target params (-Filter/-Include/-Exclude): skip their value too.
                    elseif ($nonTargets -contains $pname) {
                        if (-not $t.Contains(':') -and (($i + 1) -lt $argTokens.Count)) { $i++ }
                    }
                    # Other flags (-Recurse, -Force, ...): ignored data.
                }
                else {
                    # Bare token: a target only if it carries a path signal.
                    if ($t -match '^[A-Za-z]:[\\/]' -or $t.Contains('\') -or $t.Contains('/') -or $t.StartsWith('~') -or $t -match '\.[A-Za-z0-9]+$') {
                        $targets += $t
                    }
                }
                $i++
            }
            # Split comma lists into separate targets.
            $splitTargets = @()
            foreach ($tg in $targets) {
                foreach ($part in ($tg -split ',')) {
                    $p = $part.Trim()
                    if ($p) { $splitTargets += $p }
                }
            }
            # R2: drop PowerShell PROVIDER paths (HKLM:\, HKCU:\, env:, function:,
            # registry:, cert:, ...) — they are NOT filesystem locations, so the
            # editable/CWD/temp policy must not govern them. A provider path has a
            # word+colon prefix that is NOT a drive letter (single letter + \ or /).
            $fsTargets = @()
            foreach ($tg in $splitTargets) {
                if ($tg -match '^[A-Za-z][A-Za-z0-9_]*:' -and $tg -notmatch '^[A-Za-z]:[\\/]') { continue }
                $fsTargets += $tg
            }
            $targets = $fsTargets

            # No target extracted -> do NOT decide; fall through to existing tiers.
            if ($targets.Count -gt 0) {
            # --- Decision ladder (order matters: system before editable = INV-3 structural) ---
            $canonicals = @()
            foreach ($tg in $targets) {
                $c = ConvertTo-CanonicalWritePath -TargetPath $tg -Config $Config
                if (-not $c) { $canonicals += $null } else { $canonicals += $c }
            }

            # Row 1: any canonical matches a system path -> ask/high/modifying.
            foreach ($c in $canonicals) {
                if ($c -and $Config._systemPathRegex -and ($c -match $Config._systemPathRegex)) {
                    return New-ResolutionResult -Decision "ask" `
                        -Reason "delete of system path: $c (high risk)" `
                        -MatchedPattern $delName -Risk "high" -Tier "modifying"
                }
            }

            # Row 2: drive root / bare UNC root / canonicalization failure / variable-only -> ask/high/modifying.
            foreach ($tg in $targets) {
                if ($tg -match '^\$' -or $tg -match '^%') {
                    return New-ResolutionResult -Decision "ask" `
                        -Reason "delete of unresolvable target: $tg (high risk)" `
                        -MatchedPattern $delName -Risk "high" -Tier "modifying"
                }
            }
            foreach ($c in $canonicals) {
                if (-not $c) {
                    return New-ResolutionResult -Decision "ask" `
                        -Reason "delete of unresolvable target (canonicalization failed) (high risk)" `
                        -MatchedPattern $delName -Risk "high" -Tier "modifying"
                }
                if ($c -match '^[A-Za-z]:\\?$') {
                    return New-ResolutionResult -Decision "ask" `
                        -Reason "delete of drive root: $c (high risk)" `
                        -MatchedPattern $delName -Risk "high" -Tier "modifying"
                }
                if ($c -match '^\\\\[^\\]+\\?$') {
                    return New-ResolutionResult -Decision "ask" `
                        -Reason "delete of UNC root: $c (high risk)" `
                        -MatchedPattern $delName -Risk "high" -Tier "modifying"
                }
            }

            # Row 3: EVERY target passes editable/CWD or the temp-form check -> allow/low/editable_delete.
            $allSafe = $true
            foreach ($tg in $targets) {
                $isTemp = [bool]($tg -match '^/tmp/|^/var/tmp/|^%TEMP%|^%TMP%|^\$env:TEMP|^\$env:TMP')
                $writableReason = Test-EditableOrCwd -TargetPath $tg -Config $Config
                if (-not $isTemp -and -not $writableReason) { $allSafe = $false; break }
            }
            if ($allSafe) {
                # Reason reflects the first target's classification (editable vs CWD).
                $firstReason = Test-EditableOrCwd -TargetPath $targets[0] -Config $Config
                $isFirstTemp = [bool]($targets[0] -match '^/tmp/|^/var/tmp/|^%TEMP%|^%TMP%|^\$env:TEMP|^\$env:TMP')
                if ($firstReason -eq 'under current directory') {
                    $delReason = "delete under current directory: $($canonicals[0])"
                } elseif ($isFirstTemp) {
                    $delReason = "delete under temp path: $($targets[0])"
                } else {
                    $delReason = "delete under editable path: $($canonicals[0])"
                }
                return New-ResolutionResult -Decision "allow" `
                    -Reason $delReason `
                    -MatchedPattern $delName -Risk "low" -Tier "editable_delete"
            }

            # Row 4: otherwise (foreign non-system target, or mixed sets) -> ask/high/modifying.
            return New-ResolutionResult -Decision "ask" `
                -Reason "delete of non-editable path: $($canonicals[0]) (high risk)" `
                -MatchedPattern $delName -Risk "high" -Tier "modifying"
            }  # end if ($targets.Count -gt 0) — no target => fall through to existing tiers
        }
    }

    # -------------------------------------------------
    # Step 7: parameter_commands (value/presence-aware classification)
    #   If this command (by name or alias) has a parameter_commands entry, classify
    #   it SOLELY from its parameter rules: modifying rules -> read-only rules ->
    #   no-match resolution (absent param => default; present-but-unrecognized
    #   value => ask in strict/normal, default in loose). On parse/tokenize
    #   failure, SKIP this step (fail-safe).
    #
    #   Looked up first in the detected domain's _parameterCommandLookup. As a
    #   cross-domain fallback, PowerShell cmdlet ALIASES (irm, iwr) that are NOT
    #   Verb-Noun may misdetect as linux/dos — so if the detected domain misses,
    #   also try the PowerShell domain's lookup and, on a hit, use the AST parser.
    # -------------------------------------------------
    $paramLookup = $null
    if (Get-Member -InputObject $domainConfig -Name '_parameterCommandLookup' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $paramLookup = $domainConfig._parameterCommandLookup
    }
    # Resolve the PowerShell domain's lookup once (for the alias fallback).
    $psLookup = $null
    if ($domainLower -ne 'powershell') {
        foreach ($pk in $Config.commands.PSObject.Properties.Name) {
            if ($pk.ToLowerInvariant() -eq 'powershell') {
                $psDom = $Config.commands.$pk
                if (Get-Member -InputObject $psDom -Name '_parameterCommandLookup' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                    $psLookup = $psDom._parameterCommandLookup
                }
                break
            }
        }
    }

    $firstToken = ($Command.Trim() -split '\s+')[0]
    if ($firstToken) {
        $ftLower = $firstToken.ToLowerInvariant()
        # strip trailing .exe/.com so bare-basename windows binaries (curl.exe python.exe)
        # matches parameter_commands entries keyed by their POSIX name.  Mirrors the 
        # full-path stripping in step 6 for the no-directory case.
        $ftLower =$firstToken.ToLowerInvariant() -replace '\.(exe|com)$', ''
        $entry = $null
        $asPowerShell = $false
        if ($paramLookup -and $paramLookup.ContainsKey($ftLower)) {
            $entry = $paramLookup[$ftLower]
        }
        elseif ($psLookup -and $psLookup.ContainsKey($ftLower)) {
            $entry = $psLookup[$ftLower]
            $asPowerShell = $true
        }

        if ($entry) {
            if ($domainLower -eq 'powershell' -or $asPowerShell) {
                $paramMap = Get-PowerShellParameterMap -Command $Command -FirstToken $firstToken
            }
            else {
                $paramMap = Get-ShellParameterMap -Command $Command -Entry $entry
            }
            # A $null map means the AST parse failed -> skip (fall through).
            # An empty map (no flags) is valid -> evaluate -> default.
            if ($null -ne $paramMap) {
                $owningDomain = if ($asPowerShell) { 'PowerShell' } else { $domainKey }
                $pResult = Evaluate-ParameterRules -Entry $entry -ParamMap $paramMap -Config $Config -Command $Command -DisplayName $firstToken -Domain $owningDomain
                if ($pResult) { return $pResult }
            }
        }
    }

    # -------------------------------------------------
    # Step 1a: Check explicit read_only entries
    # -------------------------------------------------
    $hasReadOnly = Get-Member -InputObject $domainConfig -Name 'read_only' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasReadOnly) {
        foreach ($entry in $domainConfig.read_only) {
            if (Get-Member -InputObject $entry -Name '_compiledPatterns' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                foreach ($regex in $entry._compiledPatterns) {
                    if ($regex.IsMatch($Command)) {
                        return New-ResolutionResult -Decision "allow" -Reason "$($entry.name) (read-only)" -MatchedPattern $entry.name -Risk "none" -Tier "read_only"
                    }
                }
            }
        }
    }

    # -------------------------------------------------
    # Step 1a.5: Check strictness_gated entries
    #   Middle tier: allow in normal/loose, ask when the EFFECTIVE
    #   strictness for this domain is strict (Get-EffectiveStrictness).
    # -------------------------------------------------
    $hasGated = Get-Member -InputObject $domainConfig -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasGated) {
        foreach ($entry in $domainConfig.strictness_gated) {
            if (Get-Member -InputObject $entry -Name '_compiledPatterns' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                foreach ($regex in $entry._compiledPatterns) {
                    if ($regex.IsMatch($Command)) {
                        $effective = Get-EffectiveStrictness -Config $Config -Domain $domainKey
                        if ($effective -eq 'strict') {
                            $risk = "unknown"
                            if (Get-Member -InputObject $entry -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                                $risk = $entry.risk
                            }
                            return New-ResolutionResult -Decision "ask" -Reason "$($entry.name)" -MatchedPattern $entry.name -Risk $risk -Tier "strictness_gated"
                        }
                        return New-ResolutionResult -Decision "allow" -Reason "$($entry.name) (strictness-gated)" -MatchedPattern $entry.name -Risk "none" -Tier "strictness_gated"
                    }
                }
            }
        }
    }

    # -------------------------------------------------
    # Step 1b: Check explicit modifying entries
    # -------------------------------------------------
    $hasModifying = Get-Member -InputObject $domainConfig -Name 'modifying' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasModifying) {
        foreach ($entry in $domainConfig.modifying) {
            if (Get-Member -InputObject $entry -Name '_compiledPatterns' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                foreach ($regex in $entry._compiledPatterns) {
                    if ($regex.IsMatch($Command)) {
                        $risk = "unknown"
                        if (Get-Member -InputObject $entry -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                            $risk = $entry.risk
                        }
                        return New-ResolutionResult -Decision "ask" -Reason "$($entry.name)" -MatchedPattern $entry.name -Risk $risk -Tier "modifying"
                    }
                }
            }
        }
    }

    # -------------------------------------------------
    # Step 2: Verb-based classification — PowerShell domain
    # -------------------------------------------------
    if ($domainLower -eq "powershell") {
        # Extract the cmdlet name (first word of command)
        $cmdlet = ($Command -split '\s+')[0]

        # PowerShell verb lists. read_only_verbs is a flat array. Some entries
        # have trailing "*" (prefix patterns like "Get-*"), some are exact
        # two-word cmdlet names ("Out-GridView", "Write-Host").
        # modifying_verbs is an object keyed by risk tier: high/medium/low,
        # each containing arrays of verb patterns.
        #
        # We build two representations:
        #   1. Exact cmdlet names (two-word check)
        #   2. Verb prefix -> (decision, risk) map (single-word check)

        # -- Build read-only lookup structures --
        $roExact = @{}      # cmdlet name -> $true
        $roPrefix = @{}     # verb prefix (e.g., "Get-") -> $true
        $hasReadOnlyVerbs = Get-Member -InputObject $domainConfig -Name 'read_only_verbs' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($hasReadOnlyVerbs) {
            foreach ($verbEntry in $domainConfig.read_only_verbs) {
                $verbEntry = $verbEntry.ToString()
                if ($verbEntry.EndsWith('*')) {
                    $roPrefix[$verbEntry.TrimEnd('*')] = $true
                }
                else {
                    $roExact[$verbEntry] = $true
                }
            }
        }

        # -- Build modifying lookup structures --
        $modExact = @{}     # cmdlet name -> risk
        $modPrefix = @{}    # verb prefix -> risk
        $hasModifyingVerbs = Get-Member -InputObject $domainConfig -Name 'modifying_verbs' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($hasModifyingVerbs) {
            foreach ($riskTier in $domainConfig.modifying_verbs.PSObject.Properties) {
                $riskLabel = $riskTier.Name
                foreach ($verbEntry in $riskTier.Value) {
                    $verbEntry = $verbEntry.ToString()
                    if ($verbEntry.EndsWith('*')) {
                        $modPrefix[$verbEntry.TrimEnd('*')] = $riskLabel
                    }
                    else {
                        $modExact[$verbEntry] = $riskLabel
                    }
                }
            }
        }

        # -- Two-word check (exact cmdlet name match) --
        if ($roExact.ContainsKey($cmdlet)) {
            return New-ResolutionResult -Decision "allow" -Reason "$cmdlet (read-only verb)" -MatchedPattern $cmdlet -Risk "none" -Tier "read_only"
        }
        if ($modExact.ContainsKey($cmdlet)) {
            $risk = $modExact[$cmdlet]
            return New-ResolutionResult -Decision "ask" -Reason "$cmdlet (modifying verb)" -MatchedPattern $cmdlet -Risk $risk -Tier "modifying"
        }

        # -- Single-word verb prefix check --
        # For Verb-Noun cmdlets, extract "Verb-" prefix
        if ($cmdlet -match '^(\w+)-') {
            $verbPrefix = $matches[1] + "-"
        }
        else {
            $verbPrefix = $cmdlet + "-"
        }

        if ($roPrefix.ContainsKey($verbPrefix)) {
            return New-ResolutionResult -Decision "allow" -Reason "$cmdlet (read-only verb: $verbPrefix)" -MatchedPattern $verbPrefix -Risk "none" -Tier "read_only"
        }
        if ($modPrefix.ContainsKey($verbPrefix)) {
            $risk = $modPrefix[$verbPrefix]
            return New-ResolutionResult -Decision "ask" -Reason "$cmdlet (modifying verb: $verbPrefix)" -MatchedPattern $verbPrefix -Risk $risk -Tier "modifying"
        }

        # Verb-Noun shape but no verb tier claimed it: the cmdlet presented
        # like a real PowerShell command, but its verb is unregistered. Fail
        # closed with a precise reason (mirrors the AWS unregistered-verb
        # fallback) instead of the generic "unknown command". MatchedPattern/
        # Tier stay empty - identical downstream treatment.
        if ($cmdlet -match '^[A-Za-z][\w]*-') {
            return New-ResolutionResult -Decision "ask" -Reason "$cmdlet (unregistered PowerShell verb: $verbPrefix - fail-closed)" -MatchedPattern "" -Risk "medium" -Tier "unregistered_verb"
        }
    }

    # -------------------------------------------------
    # Step 2: Verb-based classification — AWS CLI domain
    # -------------------------------------------------
    if ($domainLower -eq "aws_cli") {
        # Extract: aws <service> <verb-*> (or more sub-verbs)
        if ($Command -match '^aws\s+(\S+)\s+(\S+)') {
            $service = $matches[1]
            $verb = $matches[2]

            # AWS uses read_only_prefixes and modifying_prefixes in the config
            # (the original spec names may differ from the JSON keys)

            # -- Build read-only prefix lookup --
            $roPrefixLookup = @{}  # prefix -> $true
            $hasReadOnlyVerbs = Get-Member -InputObject $domainConfig -Name 'read_only_verbs' -MemberType NoteProperty -ErrorAction SilentlyContinue
            $hasReadOnlyPrefixes = Get-Member -InputObject $domainConfig -Name 'read_only_prefixes' -MemberType NoteProperty -ErrorAction SilentlyContinue

            if ($hasReadOnlyPrefixes) {
                foreach ($prefix in $domainConfig.read_only_prefixes) {
                    $roPrefixLookup[$prefix.ToString()] = $true
                }
            }
            elseif ($hasReadOnlyVerbs) {
                foreach ($prefix in $domainConfig.read_only_verbs) {
                    $roPrefixLookup[$prefix.ToString()] = $true
                }
            }

            # -- Build modifying prefix lookup --
            $modPrefixLookup = @{}  # prefix -> risk
            $hasModifyingVerbs = Get-Member -InputObject $domainConfig -Name 'modifying_verbs' -MemberType NoteProperty -ErrorAction SilentlyContinue
            $hasModifyingPrefixes = Get-Member -InputObject $domainConfig -Name 'modifying_prefixes' -MemberType NoteProperty -ErrorAction SilentlyContinue

            if ($hasModifyingPrefixes) {
                foreach ($riskTier in $domainConfig.modifying_prefixes.PSObject.Properties) {
                    $riskLabel = $riskTier.Name
                    foreach ($prefix in $riskTier.Value) {
                        $modPrefixLookup[$prefix.ToString()] = $riskLabel
                    }
                }
            }
            elseif ($hasModifyingVerbs) {
                foreach ($riskTier in $domainConfig.modifying_verbs.PSObject.Properties) {
                    $riskLabel = $riskTier.Name
                    foreach ($prefix in $riskTier.Value) {
                        $modPrefixLookup[$prefix.ToString()] = $riskLabel
                    }
                }
            }

            # Check read-only prefixes
            foreach ($readPrefix in $roPrefixLookup.Keys) {
                if ($verb -like "$readPrefix*") {
                    return New-ResolutionResult -Decision "allow" -Reason "aws $service $verb (read-only verb: $readPrefix)" -MatchedPattern $readPrefix -Risk "none" -Tier "read_only"
                }
            }

            # Check modifying prefixes
            foreach ($modPrefix in $modPrefixLookup.Keys) {
                if ($verb -like "$modPrefix*") {
                    $risk = $modPrefixLookup[$modPrefix]
                    return New-ResolutionResult -Decision "ask" -Reason "aws $service $verb (modifying verb: $modPrefix)" -MatchedPattern $modPrefix -Risk $risk -Tier "modifying"
                }
            }

            # Parsed service+verb but no prefix matched: this IS an aws command
            # whose verb is simply unregistered. Fail closed (ask) but say so
            # precisely - the generic "unknown command" fallback hides that the
            # engine recognized the service and verb (2026-08-02 user report:
            # "aws sso-admin provision-permission-set" said 'unknown command').
            # MatchedPattern/Tier stay empty so downstream (arbiter gate, LLM
            # merge) treats it exactly like the generic unknown fallback.
            return New-ResolutionResult -Decision "ask" -Reason "aws $service $verb (unregistered AWS verb - fail-closed)" -MatchedPattern "" -Risk "medium" -Tier "unregistered_verb"
        }
    }

    # -------------------------------------------------
    # Step 2.5: Shell flow-control keywords and safe constructs
    #   (Linux/DOS domains only). Recognizes shell keywords, comments,
    #   variable assignments, case patterns, and function definitions.
    # -------------------------------------------------
    $shellFlowKeywords = @(
        'for', 'while', 'until', 'if', 'case', 'select',
        'do', 'done', 'then', 'else', 'elif', 'fi', 'esac',
        'function', 'foreach', 'in'
    )
    $shellSafeKeywords = @('break', 'return', 'local', 'declare', 'readonly', 'continue', 'exit')

    if ($domainLower -in @('linux', 'dos_cmd')) {
        $firstWord = ($Command.Trim() -split '\s+')[0]

        # 2.5a: Comment lines are always safe
        if ($firstWord.StartsWith('#')) {
            return New-ResolutionResult -Decision "allow" -Reason "shell comment" -MatchedPattern '#' -Risk "none"
        }

        # 2.5b: Case pattern arms (e.g., *"error"*), "pattern"), *) etc.)
        if ($firstWord -match '^(\*|"|\()') {
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord (case pattern arm)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5c: Shell flow-control keywords
        if ($firstWord -in $shellFlowKeywords) {
            # For 'do', check if a modifier command follows
            if ($firstWord -eq 'do') {
                $afterDo = $Command.Trim() -replace '^do\s+', ''
                if ($afterDo -and $afterDo -ne $Command.Trim() -and $afterDo -ne 'do') {
                    # Recurse: re-classify the command after 'do'
                    $innerResult = Resolve-Command -Command $afterDo -Domain $Domain -Config $Config
                    if ($innerResult.Decision -eq 'ask') {
                        return New-ResolutionResult -Decision "ask" -Reason "$($innerResult.Reason) (inside do block)" -MatchedPattern $innerResult.MatchedPattern -Risk $innerResult.Risk
                    }
                    return New-ResolutionResult -Decision "allow" -Reason "$firstWord/$($innerResult.Reason) (shell keyword with safe body)" -MatchedPattern $firstWord -Risk "none"
                }
            }
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord (shell flow-control keyword)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5d: Shell safe builtins
        if ($firstWord -in $shellSafeKeywords) {
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord (shell builtin)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5e: Function definition header: func_name() { or function name {
        if ($firstWord -match '^\w+\(\)' -or ($Command.Trim() -match '^function\s+\w+\s*\{')) {
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord (function definition)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5f: Closing braces / standalone braces (function body delimiters)
        if ($firstWord -eq '}') {
            return New-ResolutionResult -Decision "allow" -Reason "closing brace (function end)" -MatchedPattern '}' -Risk "none"
        }

        # 2.5g: Linux variable assignment stripping: VAR=value, VAR="...", VAR=$(...)
        if ($firstWord -match '^[A-Za-z_]\w*=') {
            $stripped = $Command.Trim() -replace '^[A-Za-z_]\w*=(("[^"]*"|''[^'']*''|\$\([^)]*\)|\S*)\s*)+', ''
            if (-not $stripped) {
                return New-ResolutionResult -Decision "allow" -Reason "$firstWord (variable assignment)" -MatchedPattern $firstWord -Risk "none"
            }
            # Re-classify the command after variable assignment
            $innerResult = Resolve-Command -Command $stripped -Domain $Domain -Config $Config
            if ($innerResult.Decision -eq 'ask') {
                return New-ResolutionResult -Decision "ask" -Reason "$($innerResult.Reason) (after var assignment)" -MatchedPattern $innerResult.MatchedPattern -Risk $innerResult.Risk
            }
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord $($innerResult.Reason) (after var assignment)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5h: Standalone heredoc delimiters / markers (single bare word, no args).
        # Keeps allowing whitespace-free tokens ($true, $i++, }, EOF, ...).
        # Excludes .NET/method invocations — anything with parens or '::' such as
        # [Type]::Method(...), $var.Method(), $proc.Kill() — which must fall
        # through to normal classification.
        $bareToken = $Command.Trim()
        if ($bareToken -notmatch '\s' -and $bareToken -notmatch '[()]' -and $bareToken -notmatch '::' -and $bareToken -notmatch '\.') {
            return New-ResolutionResult -Decision "allow" -Reason "$firstWord (heredoc delimiter or marker)" -MatchedPattern $firstWord -Risk "none"
        }

        # 2.5i: User-defined shell function calls — when the first word looks
        # like a conventional function name with snake_case convention and the
        # remaining arguments start with a path, number, or flag (not a
        # command), assume it's a user-defined function call.
        # Underscore is the key differentiator: standard system commands (touch,
        # find, move, mklink, cipher, etc.) never use underscores, but user-defined
        # functions almost always use snake_case.
        if ($firstWord -match '^[a-z][a-z0-9_]*_[a-z0-9_]+$') {
            $funcArgs = ($Command.Trim() -replace "^$firstWord\s*", '')
            if (-not $funcArgs) {
                return New-ResolutionResult -Decision "allow" -Reason "$firstWord (user function call, no args)" -MatchedPattern $firstWord -Risk "none"
            }
            $firstArg = ($funcArgs.Trim() -split '\s+')[0]
            if ($firstArg -match '^[/~.]' -or $firstArg -match '^\d+$' -or $firstArg -match '^-') {
                return New-ResolutionResult -Decision "allow" -Reason "$firstWord (user function call)" -MatchedPattern $firstWord -Risk "none"
            }
        }
    }

    # Also check for variable-assignment-like patterns in PowerShell that
    # still contain multi-line constructs starting with flow-control keywords
    if ($domainLower -eq 'powershell') {
        # Strip leading variable assignments ($var = ..., [type]$var = ...)
        $stripped = $Command.Trim() -replace '^\s*(\[.+\]\s+)?(\$\w[\w:]*)\s*=\s*', ''
        if ($stripped -ne $Command.Trim()) {
            # Extract first real command word after stripping
            $firstWord = ($stripped.Trim() -split '\s+')[0]
            # Skip past array initializer @(...) and keyword foreach
            if ($firstWord -match '^@\(') {
                # Array init followed by foreach -- find the foreach keyword
                if ($stripped -match 'foreach\s*\(') {
                    # Extract command after foreach block's opening brace
                    $stripped = $stripped -replace '^.*?foreach\s*\([^)]*\)\s*\{\s*', ''
                }
            }
            elseif ($firstWord -in @('foreach', 'for', 'while', 'if', 'do', 'switch', 'try')) {
                # PowerShell flow-control keyword -- strip to first cmdlet inside block
                if ($firstWord -in @('foreach', 'for', 'while', 'if', 'switch')) {
                    $stripped = $stripped -replace '^.*?\{\s*', ''
                }
                elseif ($firstWord -eq 'do') {
                    $stripped = $stripped -replace '^do\s*\{\s*', ''
                }
                elseif ($firstWord -eq 'try') {
                    $stripped = $stripped -replace '^try\s*\{\s*', ''
                }
            }
            # Re-extract first word and try verb-based classification on it
            $firstWord = ($stripped.Trim() -split '\s+')[0]
            if ($firstWord -match '^(\w+)-') {
                $verbPrefix = $matches[1] + "-"
                if ($roPrefix.ContainsKey($verbPrefix)) {
                    return New-ResolutionResult -Decision "allow" -Reason "$firstWord (read-only verb: $verbPrefix, reached via stripping)" -MatchedPattern $verbPrefix -Risk "none"
                }
                if ($modPrefix.ContainsKey($verbPrefix)) {
                    $risk = $modPrefix[$verbPrefix]
                    return New-ResolutionResult -Decision "ask" -Reason "$firstWord (modifying verb: $verbPrefix, reached via stripping)" -MatchedPattern $verbPrefix -Risk $risk
                }
            }
        }
    }

    # -------------------------------------------------
    # Step 3: Fallback — no pattern matched
    # -------------------------------------------------
    # If the unknown command is a STATIC .NET method call ([Type]::Method(...)),
    # say so precisely and point at the allowlist rather than the generic
    # 'unknown command'. These reach the fallback when a static call leads a
    # ;-chain or stands alone -> detected as linux -> regex-split -> unknown.
    if ($Command -match '^\s*\[([^\]]+)\]\s*::\s*([A-Za-z_]\w*)\s*\(') {
        $staticType = $Matches[1].Trim()
        $staticMethod = $Matches[2]
        return New-ResolutionResult -Decision "ask" `
            -Reason "static method not on allowlist: [$staticType]::$staticMethod (see safe_expressions.dotnet_static_method_allowlist)" `
            -MatchedPattern $null -Risk "unknown" -Tier "unregistered_static"
    }

    # Known first-token tool (docker/kubectl/terraform) whose subcommand is not
    # in the config lists: name the tool AND the subcommand instead of the
    # generic wording. Up to 3 leading global flags are skipped when locating
    # the subcommand (e.g. terraform -chdir=x frobnicate). Decision/tier
    # unchanged: fail-closed ask, empty tier (mirrors the AWS fallback).
    # NOTE: 'git' was trimmed from this list (2026-09-16 rework) — git now
    # classifies via Linux.parameter_commands.git and produces its own
    # equivalent unregistered-subcommand message in Evaluate-ParameterRules.
    if ($domainLower -in @('docker', 'kubernetes', 'terraform') -and
        $Command -match '^\s*([a-zA-Z][\w-]*)\s+(?:-\S+\s+){0,3}([^\s-][\w-]*)') {
        $toolName = $Matches[1]
        $subName = $Matches[2]
        return New-ResolutionResult -Decision "ask" -Reason "$toolName subcommand '$subName' not registered (fail-closed)" -MatchedPattern "" -Risk "unknown" -Tier "unregistered"
    }
    $truncatedCommand = $Command.Substring(0, [Math]::Min(80, $Command.Length))
    return New-ResolutionResult -Decision "ask" -Reason "unknown command: $truncatedCommand" -MatchedPattern $null -Risk "unknown" -Tier "unclassified"
}

# =============================================================================
# Trusted-program helpers (Step 0f-trust)
#
# Test-TrustedProgram: does a program token match a trusted_programs entry?
# Test-StatementContainsModifying: does an argument string contain a modifying
# command? Together they implement Option B: a trusted program is allowed only
# if no modifying command appears in its statement (including its arguments).
# =============================================================================

function Test-TrustedProgram {
    <#
    .SYNOPSIS
        Returns the matched trusted_programs entry (normalized) if $Token matches,
        else $null.

    .DESCRIPTION
        Entries are read pre-normalized (lowercased, '/' -> '\') from
        $Config._compiled.trustedPrograms. Matching rules:
          - Entry containing '\' (a path): token EQUALS the entry, OR token ENDS
            WITH the entry preceded by a '\' (path-suffix). Covers full paths
            ('c:\temp\abc.ps1') and partial paths ('subdir\abc.ps1').
          - Bare entry (no '\'): the token's BASENAME (text after the last '\')
            equals the entry. Covers bare names ('abc.ps1').
        Case-insensitive; '/' and '\' are equivalent.

        R1 (2026-09-18): AFTER all literal entries miss, the regex entries from
        $Config._compiled.trustedProgramRegexes are tried in order against the
        normalized token with unanchored -match (substring semantics, like
        trusted_pattern). A match returns 'regex:<pattern>' so the caller can
        distinguish a regex hit from a literal one. Absent/empty key = no regex
        pass (byte-identical behavior to before R1).
    #>
    param([string]$Token, [PSCustomObject]$Config)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $entries = @()
    if ($Config._compiled -and
        (Get-Member -InputObject $Config._compiled -Name 'trustedPrograms' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $entries = @($Config._compiled.trustedPrograms)
    }

    $tok = $Token.ToLowerInvariant() -replace '/', '\'
    $basename = if ($tok.Contains('\')) { $tok -replace '^.*\\', '' } else { $tok }

    foreach ($e in $entries) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        if ($e.Contains('\')) {
            if ($tok -eq $e) { return $e }
            $eLen = $e.Length
            if ($tok.Length -gt $eLen -and $tok.EndsWith($e) -and $tok[$tok.Length - $eLen - 1] -eq '\') {
                return $e
            }
        }
        else {
            if ($basename -eq $e) { return $e }
        }
    }

    # R1 regex pass: literals exhausted. Unanchored, case-insensitive (the
    # token is already lowercased; the compiled regexes are IgnoreCase).
    $regexEntries = @()
    if ($Config._compiled -and
        (Get-Member -InputObject $Config._compiled -Name 'trustedProgramRegexes' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $regexEntries = @($Config._compiled.trustedProgramRegexes)
    }
    foreach ($re in $regexEntries) {
        if ($null -eq $re) { continue }
        if ($tok -match $re) { return "regex:$($re.ToString())" }
    }
    return $null
}

function Test-StatementContainsModifying {
    <#
    .SYNOPSIS
        Returns the first modifying token found in $ArgsText, else $null.

    .DESCRIPTION
        Tokenizes $ArgsText on whitespace and probes each suffix
        (tokens[i..end]) via Resolve-Command, re-detecting the domain per
        suffix (so a modifying PowerShell cmdlet inside a linux-detected
        invocation is still caught). A suffix is "modifying" iff Resolve-Command
        returns Decision='ask' WITH a non-null MatchedPattern — that signal
        covers modifying patterns/verbs/prefixes and parameter_commands
        modifying rules, plus strictness_gated-in-strict. UNKNOWN results
        (MatchedPattern=$null) are deliberately ignored so benign arguments
        (arbitrary paths, unrecognized tokens) do not over-block.

        Probes run full Resolve-Command (the trusted-program check inside it is
        a cheap no-match for non-trusted tokens, and a trusted program in the
        args correctly returns 'allow', not 'ask'). Termination is guaranteed:
        each suffix is strictly shorter than its parent.
    #>
    param([string]$ArgsText, [PSCustomObject]$Config)

    if ([string]::IsNullOrWhiteSpace($ArgsText)) { return $null }

    $tokens = @($ArgsText.Trim() -split '\s+')
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $suffix = (($tokens[$i..($tokens.Count - 1)]) -join ' ').Trim()
        if (-not $suffix) { continue }
        $dom = Get-CommandDomain -Command $suffix
        $r = Resolve-Command -Command $suffix -Domain $dom -Config $Config
        # "Modifying" iff ask AND a real (non-empty) MatchedPattern. The unknown
        # fallback carries Decision='ask' with an empty MatchedPattern; an empty
        # string is NOT $null, so IsNullOrWhiteSpace (not `$null -ne`) is required
        # to avoid treating benign unknown args as modifying.
        if ($r -and $r.Decision -eq 'ask' -and -not [string]::IsNullOrWhiteSpace($r.MatchedPattern)) {
            return $tokens[$i]
        }
    }
    return $null
}

# =============================================================================
# Parameter-commands helpers (Step 7)
#
# Build a {paramNameLower -> value} map for a command, then evaluate the
# command's parameter_rules. PowerShell uses the AST (position-independent,
# quote-safe); Linux/DOS use a quote-aware tokenizer. Both produce the same
# map shape so Evaluate-ParameterRules is shared.
# =============================================================================

function Get-AstLeafValue {
    param($Ast)
    if ($null -eq $Ast) { return $null }
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Ast.Value }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $Ast.Value }
    return $Ast.Extent.Text
}

function Get-PowerShellParameterMap {
    param(
        [string]$Command,
        [string]$FirstToken
    )
    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $null }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $null }
    if ($errors -and $errors.Count -gt 0) { return $null }
    if (-not $ast) { return $null }

    $commandAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    $targetCmd = $null
    $ftLower = $FirstToken.ToLowerInvariant()
    foreach ($c in $commandAsts) {
        if ($c.CommandElements.Count -gt 0) {
            if ($c.CommandElements[0].Extent.Text.ToLowerInvariant() -eq $ftLower) { $targetCmd = $c; break }
        }
    }
    if (-not $targetCmd) { return $null }

    $map = @{}
    $elements = $targetCmd.CommandElements
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $el = $elements[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pName = $el.ParameterName.ToLowerInvariant()
            $val = $null
            if ($el.Argument) {
                # -Method:Post  (colon form binds the argument directly)
                $val = Get-AstLeafValue -Ast $el.Argument
            }
            elseif (($i + 1) -lt $elements.Count) {
                $nextEl = $elements[$i + 1]
                if (-not ($nextEl -is [System.Management.Automation.Language.CommandParameterAst])) {
                    # -Method Post  (value is the next element)
                    $val = Get-AstLeafValue -Ast $nextEl
                    $i++
                }
            }
            $map[$pName] = $val
        }
    }
    return $map
}

function Get-ShellTokens {
    # Quote-aware tokenizer; surrounding quotes are stripped from values.
    param([string]$Text)
    $tokens = New-Object System.Collections.Generic.List[string]
    if (-not $Text) { return $tokens.ToArray() }
    $cur = ''
    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
        if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
        if ((-not $inSingle -and -not $inDouble) -and $ch -eq ' ') {
            if ($cur.Length -gt 0) { $tokens.Add($cur); $cur = '' }
            continue
        }
        $cur += $ch
    }
    if ($cur.Length -gt 0) { $tokens.Add($cur) }
    return $tokens.ToArray()
}

function Get-ShellParameterMap {
    param(
        [string]$Command,
        $Entry
    )
    # Value-taking flag names (lowercased) come from the entry's 'values' rules.
    $valueTaking = @{}
    foreach ($rule in $Entry.rules) {
        if ($rule.match -eq 'values') {
            $names = @($rule.param)
            if ($names -is [string]) { $names = @($names) }
            foreach ($n in $names) { $valueTaking[$n.ToLowerInvariant()] = $true }
        }
    }

    $tokens = Get-ShellTokens -Text $Command
    $map = @{}
    if ($tokens.Count -lt 2) { return $map }   # only program token (or none)

    # --- Subcommand / positionals capture (2026-09-16 subcommand framework) ---
    # Opt-in: runs ONLY for entries that declare at least one 'subcommand' rule,
    # so curl/python (flag-only entries) keep byte-identical behavior. This is a
    # SEPARATE walk that precedes the flag-map loop below (which is unchanged).
    #   - dash-tokens (-x / --x) are skipped as flags;
    #   - a dash-token in global_value_flags ALSO consumes its next token (the
    #     value) unconditionally — this is what makes `git -C /path status` work;
    #   - the first non-dash token is the subcommand, and ALL remaining positional
    #     tokens are collected into the reserved '_positionals' list.
    # Exact-token equality (case-insensitive): --git-dir=C:\x does NOT equal
    # --git-dir, so =-attached values are boolean and their glued value can never
    # be mistaken for a subcommand. Undeclared flags are boolean (no value eaten).
    $hasSubcommandRules = $false
    foreach ($rule in $Entry.rules) {
        if (Get-Member -InputObject $rule -Name 'subcommand' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $hasSubcommandRules = $true; break
        }
    }
    if ($hasSubcommandRules) {
        $gvf = @{}
        if ((Get-Member -InputObject $Entry -Name 'global_value_flags' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $Entry.global_value_flags) {
            foreach ($g in $Entry.global_value_flags) { $gvf["$g".ToLowerInvariant()] = $true }
        }
        $positionals = New-Object System.Collections.Generic.List[string]
        $sawFlag = $false
        for ($i = 1; $i -lt $tokens.Count; $i++) {
            $tok = $tokens[$i]
            if ($tok.StartsWith('-')) {
                $sawFlag = $true
                if ($gvf.ContainsKey($tok.ToLowerInvariant()) -and ($i + 1) -lt $tokens.Count) {
                    $i++   # consume the value token of a declared global value-flag
                }
                continue
            }
            $positionals.Add($tok)   # subcommand (first) + all later positionals
        }
        $map['_positionals'] = @($positionals.ToArray())
        # Distinguishes truly-bare (no flags, no subcommand => usage/allow) from
        # flags-without-subcommand (e.g. `git --online -3` => fail-closed ask).
        $map['_hadFlags'] = $sawFlag
    }

    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        $lower = $tok.ToLowerInvariant()

        if ($lower -match '^--') {
            # long flag: --name=value | --name value | --name (boolean)
            if ($lower -match '^(--[^=]+)=(.*)$') {
                $map[$matches[1].ToLowerInvariant()] = $matches[2]
            }
            else {
                $name = $lower
                if ($valueTaking.ContainsKey($name) -and ($i + 1) -lt $tokens.Count -and -not ($tokens[$i + 1] -match '^[-/]')) {
                    $map[$name] = $tokens[$i + 1]; $i++
                }
                else { $map[$name] = $null }
            }
        }
        elseif ($lower -match '^/[^/]') {
            # DOS-style: /name:value | /name value | /name (boolean)
            if ($lower -match '^(/[^=:]+)[:=](.*)$') {
                $map[$matches[1].ToLowerInvariant()] = $matches[2]
            }
            else {
                $name = $lower
                if ($valueTaking.ContainsKey($name) -and ($i + 1) -lt $tokens.Count -and -not ($tokens[$i + 1] -match '^[-/]')) {
                    $map[$name] = $tokens[$i + 1]; $i++
                }
                else { $map[$name] = $null }
            }
        }
        elseif ($lower -match '^-[^-]') {
            # short flag or cluster: -x, -xVALUE, -x value, -x=value, -abc
            $rest = $tok.Substring(1)
            for ($j = 0; $j -lt $rest.Length; $j++) {
                $shortLower = ('-' + $rest[$j]).ToLowerInvariant()
                if ($valueTaking.ContainsKey($shortLower)) {
                    $remainder = $rest.Substring($j + 1)
                    if ($remainder -match '^=(.*)$') { $remainder = $matches[1] }
                    if ($remainder.Length -gt 0) {
                        $map[$shortLower] = $remainder
                    }
                    elseif (($i + 1) -lt $tokens.Count -and -not ($tokens[$i + 1] -match '^[-/]')) {
                        $map[$shortLower] = $tokens[$i + 1]; $i++
                    }
                    else { $map[$shortLower] = $null }
                    break   # remainder of cluster consumed as this flag's value
                }
                else {
                    $map[$shortLower] = $null   # boolean short flag; keep scanning cluster
                }
            }
        }
        # else: positional argument -> ignored
    }
    return $map
}

function Test-ParamRule {
    param($Rule, $ParamMap)
    $names = @($Rule.param)
    if ($names -is [string]) { $names = @($names) }
    foreach ($nm in $names) {
        $key = $nm.ToLowerInvariant()
        if ($ParamMap.ContainsKey($key)) {
            if ($Rule.match -eq 'present') { return $true }
            $val = $ParamMap[$key]
            if ($null -ne $val) {
                $valLower = "$val".ToLowerInvariant()
                foreach ($v in $Rule.values) {
                    if ("$v".ToLowerInvariant() -eq $valLower) { return $true }
                }
            }
        }
    }
    return $false
}

function Test-RuleMatch {
    # Unified rule matcher for parameter_commands rules (2026-09-16 subcommand
    # framework). A rule matches when BOTH of its present conditions hold:
    #   - if it has a 'subcommand' list: the positional sequence (_positionals)
    #     STARTS WITH one of the phrases (case-insensitive, multi-word OK); AND
    #   - if it has a 'param' list: Test-ParamRule passes (present / values).
    # A rule with neither subcommand nor param never matches. Flag-only rules
    # (no subcommand) reduce to the legacy Test-ParamRule behavior.
    param($Rule, $ParamMap)
    $hasSub = Get-Member -InputObject $Rule -Name 'subcommand' -MemberType NoteProperty -ErrorAction SilentlyContinue
    $hasParam = Get-Member -InputObject $Rule -Name 'param' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if (-not $hasSub -and -not $hasParam) { return $false }

    if ($hasSub) {
        $pos = @()
        if ($ParamMap.ContainsKey('_positionals')) { $pos = @($ParamMap['_positionals']) }
        $phrases = @($Rule.subcommand)
        if ($phrases -is [string]) { $phrases = @($phrases) }
        $matched = $false
        foreach ($phrase in $phrases) {
            $words = @("$phrase".Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
            if ($words.Count -eq 0 -or $pos.Count -lt $words.Count) { continue }
            $ok = $true
            for ($w = 0; $w -lt $words.Count; $w++) {
                if ($pos[$w].ToLowerInvariant() -ne $words[$w]) { $ok = $false; break }
            }
            if ($ok) { $matched = $true; break }
        }
        if (-not $matched) { return $false }
    }

    if ($hasParam) {
        if (-not (Test-ParamRule $Rule $ParamMap)) { return $false }
    }
    return $true
}

function Evaluate-ParameterRules {
    param(
        $Entry,
        $ParamMap,
        $Config,
        [string]$Command,
        [string]$DisplayName,
        [string]$Domain
    )

    # Does this entry declare any subcommand rule? Drives the usage/unregistered
    # fallback (section 5.4). Flag-only entries (curl/python) keep the legacy path.
    $hasSubcommandRules = $false
    foreach ($rule in $Entry.rules) {
        if (Get-Member -InputObject $rule -Name 'subcommand' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $hasSubcommandRules = $true; break
        }
    }

    # Effective strictness for gated rules: global forces -> entry -> domain.
    $effectiveStrict = Get-EffectiveStrictness -Config $Config -Domain $Domain -Entry $Entry

    # 1. Modifying rules (compound + subcommand + flag-only), config order.
    foreach ($rule in $Entry.rules) {
        if ($rule.decision -eq 'modifying' -and (Test-RuleMatch $rule $ParamMap)) {
            $risk = 'unknown'
            if (Get-Member -InputObject $rule -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $risk = $rule.risk }
            return [PSCustomObject]@{
                Command = $Command; Decision = 'ask'
                Reason = "$DisplayName (parameter rule: modifying)"; MatchedPattern = $DisplayName; Risk = $risk; Tier = 'modifying'
            }
        }
    }

    # 2. Strictness_gated rules: allow in normal/loose, ask when effective strict.
    foreach ($rule in $Entry.rules) {
        if ($rule.decision -eq 'strictness_gated' -and (Test-RuleMatch $rule $ParamMap)) {
            $risk = 'unknown'
            if (Get-Member -InputObject $rule -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $risk = $rule.risk }
            if ($effectiveStrict -eq 'strict') {
                return [PSCustomObject]@{
                    Command = $Command; Decision = 'ask'
                    Reason = "$DisplayName (parameter rule: strictness-gated, strict mode)"; MatchedPattern = $DisplayName; Risk = $risk; Tier = 'strictness_gated'
                }
            }
            return [PSCustomObject]@{
                Command = $Command; Decision = 'allow'
                Reason = "$DisplayName (parameter rule: strictness-gated)"; MatchedPattern = $DisplayName; Risk = 'none'; Tier = 'strictness_gated'
            }
        }
    }

    # 3. Read-only rules (compound + subcommand + flag-only).
    foreach ($rule in $Entry.rules) {
        if ($rule.decision -eq 'read-only' -and (Test-RuleMatch $rule $ParamMap)) {
            # Tier: read_only for subcommand/compound matches, param_rule for flag-only.
            $tier = 'param_rule'
            if (Get-Member -InputObject $rule -Name 'subcommand' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $tier = 'read_only' }
            return [PSCustomObject]@{
                Command = $Command; Decision = 'allow'
                Reason = "$DisplayName (parameter rule: read-only)"; MatchedPattern = $DisplayName; Risk = 'none'; Tier = $tier
            }
        }
    }

    # 4. No rule matched.
    if ($hasSubcommandRules) {
        $pos = @()
        if ($ParamMap.ContainsKey('_positionals')) { $pos = @($ParamMap['_positionals']) }
        if ($pos.Count -eq 0) {
            $hadFlags = $false
            if ($ParamMap.ContainsKey('_hadFlags')) { $hadFlags = [bool]$ParamMap['_hadFlags'] }
            if (-not $hadFlags) {
                # Truly bare (no flags, no subcommand) => usage/help semantics => allow.
                return [PSCustomObject]@{
                    Command = $Command; Decision = 'allow'
                    Reason = "$DisplayName (no subcommand: usage)"; MatchedPattern = $DisplayName; Risk = 'none'; Tier = 'read_only'
                }
            }
            # Flags present but no recognized subcommand and no rule matched =>
            # cannot positively classify as safe (e.g. `git --online -3` is an
            # invalid command) => fail closed.
            return [PSCustomObject]@{
                Command = $Command; Decision = 'ask'
                Reason = "$DisplayName invoked with flags but no recognized subcommand (fail-closed)"; MatchedPattern = ""; Risk = 'unknown'; Tier = 'unregistered'
            }
        }
        # Positional seen but no rule matched => unregistered, fail-closed ask.
        return [PSCustomObject]@{
            Command = $Command; Decision = 'ask'
            Reason = "$DisplayName subcommand '$($pos[0])' not registered (fail-closed)"; MatchedPattern = ""; Risk = 'unknown'; Tier = 'unregistered'
        }
    }

    # Flag-only entries (no subcommand rules): preserve the legacy behavior.
    $unrecognized = $false
    foreach ($rule in $Entry.rules) {
        if ($rule.match -eq 'values') {
            $names = @($rule.param)
            if ($names -is [string]) { $names = @($names) }
            foreach ($nm in $names) {
                if ($ParamMap.ContainsKey($nm.ToLowerInvariant())) { $unrecognized = $true; break }
            }
        }
        if ($unrecognized) { break }
    }
    if ($unrecognized -and (Get-EffectiveStrictness -Config $Config -Domain $Domain) -ne 'loose') {
        return [PSCustomObject]@{
            Command = $Command; Decision = 'ask'
            Reason = "$DisplayName (unrecognized parameter value)"; MatchedPattern = $DisplayName; Risk = 'unknown'; Tier = 'param_rule'
        }
    }
    # default (absent param, OR unrecognized in loose mode)
    if ($Entry.default -eq 'modifying') {
        $dr = 'unknown'
        if (Get-Member -InputObject $Entry -Name 'default_risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $dr = $Entry.default_risk }
        return [PSCustomObject]@{
            Command = $Command; Decision = 'ask'
            Reason = "$DisplayName (parameter rule: default modifying)"; MatchedPattern = $DisplayName; Risk = $dr; Tier = 'modifying'
        }
    }
    return [PSCustomObject]@{
        Command = $Command; Decision = 'allow'
        Reason = "$DisplayName (parameter rule: default read-only)"; MatchedPattern = $DisplayName; Risk = 'none'; Tier = 'param_rule'
    }
}
