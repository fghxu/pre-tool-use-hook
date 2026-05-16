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
      2. Explicit "modifying" entries (compiled regex)
      3. Verb-based classification (PowerShell / AWS domains only)
      4. Fallback: ask with reason "unknown command"
#>

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
        [PSCustomObject]$Config
    )

    # -------------------------------------------------
    # Helper: build the standard return object
    # -------------------------------------------------
    function New-ResolutionResult {
        param([string]$Decision, [string]$Reason, [string]$MatchedPattern, [string]$Risk)
        return [PSCustomObject]@{
            Command        = $Command
            Decision       = $Decision
            Reason         = $Reason
            MatchedPattern = $MatchedPattern
            Risk           = $Risk
        }
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
        return New-ResolutionResult -Decision "ask" -Reason "unknown domain: $Domain" -MatchedPattern $null -Risk "unknown"
    }

    $domainConfig = $Config.commands.$domainKey

    # -------------------------------------------------
    # Step 0b: PowerShell variable assignment — strip "$var = " prefix
    #   e.g., "$computers = Get-Content ..." → "Get-Content ..."
    # -------------------------------------------------
    if ($domainLower -eq "powershell" -and $Command -match '^\s*\$[\w:]+\s*=\s*') {
        $Command = $Command -replace '^\s*\$[\w:]+\s*=\s*', ''
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
                        return New-ResolutionResult -Decision "allow" -Reason "$($entry.name) (read-only)" -MatchedPattern $entry.name -Risk "none"
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
                        return New-ResolutionResult -Decision "ask" -Reason "$($entry.name)" -MatchedPattern $entry.name -Risk $risk
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
            return New-ResolutionResult -Decision "allow" -Reason "$cmdlet (read-only verb)" -MatchedPattern $cmdlet -Risk "none"
        }
        if ($modExact.ContainsKey($cmdlet)) {
            $risk = $modExact[$cmdlet]
            return New-ResolutionResult -Decision "ask" -Reason "$cmdlet (modifying verb)" -MatchedPattern $cmdlet -Risk $risk
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
            return New-ResolutionResult -Decision "allow" -Reason "$cmdlet (read-only verb: $verbPrefix)" -MatchedPattern $verbPrefix -Risk "none"
        }
        if ($modPrefix.ContainsKey($verbPrefix)) {
            $risk = $modPrefix[$verbPrefix]
            return New-ResolutionResult -Decision "ask" -Reason "$cmdlet (modifying verb: $verbPrefix)" -MatchedPattern $verbPrefix -Risk $risk
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
                    return New-ResolutionResult -Decision "allow" -Reason "aws $service $verb (read-only verb: $readPrefix)" -MatchedPattern $readPrefix -Risk "none"
                }
            }

            # Check modifying prefixes
            foreach ($modPrefix in $modPrefixLookup.Keys) {
                if ($verb -like "$modPrefix*") {
                    $risk = $modPrefixLookup[$modPrefix]
                    return New-ResolutionResult -Decision "ask" -Reason "aws $service $verb (modifying verb: $modPrefix)" -MatchedPattern $modPrefix -Risk $risk
                }
            }
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

        # 2.5h: Standalone heredoc delimiters / markers (single bare word, no args)
        if ($Command.Trim() -notmatch '\s') {
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
    $truncatedCommand = $Command.Substring(0, [Math]::Min(80, $Command.Length))
    return New-ResolutionResult -Decision "ask" -Reason "unknown command: $truncatedCommand" -MatchedPattern $null -Risk "unknown"
}
