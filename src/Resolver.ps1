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
    # Safe-expression synthetic marker from Parser.ps1
    # -------------------------------------------------
    if ($Command -eq '(safe expression)') {
        return New-ResolutionResult -Decision "allow" -Reason "safe expression" -MatchedPattern $null -Risk "none"
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
    # Step 0b: Variable assignment strip (domain-agnostic)
    #   "$computers = Get-Content ..." → "Get-Content ..."
    #   "$creds = aws sts get-caller-identity" → "aws sts get-caller-identity"
    #   After stripping, re-detect domain and recurse.
    # -------------------------------------------------
    if ($Command -match '^\s*\$[\w:]+\s*=\s*') {
        $strippedCmd = $Command -replace '^\s*\$[\w:]+\s*=\s*', ''
        if ($strippedCmd -and $strippedCmd -ne $Command) {
            $redetectedDomain = Get-CommandDomain -Command $strippedCmd
            return Resolve-Command -Command $strippedCmd -Domain $redetectedDomain -Config $Config
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
                return Resolve-Command -Command $remainingCommand -Domain $redetectedDomain -Config $Config
            }
        }
    }

    # -------------------------------------------------
    # Step 0d: Git global option stripping
    #   "git -C /opt/repo status" → "git status"
    #   "git -c user.name=foo -C /path log" → "git log"
    #   Strips -C, -c, --git-dir, --work-tree, --namespace, --exec-path
    #   Handles quoted paths: git -C "C:\Program Files\repo" status
    # -------------------------------------------------
    if ($domainLower -eq 'git' -and $Command -match '^\s*git\s') {
        $stripped = $Command
        # Quoted or unquoted value: "path with spaces", 'path', unquoted
        $val = '("[^"]*"|''[^'']*''|\S+)'
        do {
            $prev = $stripped
            $stripped = $stripped -replace "^\s*git\s+-C\s+$val\s+", 'git '
            $stripped = $stripped -replace "^\s*git\s+-c\s+$val\s+", 'git '
            $stripped = $stripped -replace "^\s*git\s+--(git-dir|work-tree|namespace|exec-path)=?$val\s+", 'git '
        } while ($stripped -ne $prev)
        if ($stripped -ne $Command) {
            return Resolve-Command -Command $stripped.Trim() -Domain $Domain -Config $Config
        }
    }

    # -------------------------------------------------
    # Step 0e: AWS flag stripping (normal mode)
    #   In "normal" mode, strip --flags from AWS CLI commands so only
    #   the service + verb determine classification.
    #   "aws --profile prod ec2 --region us-east-1 describe-instances --filters ..."
    #     → "aws ec2 describe-instances"
    #   In "strict" mode, current behavior is preserved (unknown flags → ask).
    # -------------------------------------------------
    if ($domainLower -eq 'aws_cli' -and $Config.modifying_strictness -eq 'normal' -and $Command -match '^aws\s') {
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
                elseif (($i + 1) -lt $awsTokens.Count -and -not $awsTokens[$i + 1].StartsWith('-')) {
                    # --flag value, skip both the flag and its value
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
        if ($awsNormalized -ne $Command.Trim()) {
            return Resolve-Command -Command $awsNormalized -Domain $Domain -Config $Config
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

    # Extract first token (handling quoted paths with spaces)
    $firstToken = $null
    $rest = ''
    if ($trimmedForPath -match '^"([^"]+)"\s*(.*)$') {
        $firstToken = $matches[1]
        $rest = $matches[2]
    }
    else {
        if ($trimmedForPath -match '^(\S+)\s*(.*)$') {
            $firstToken = $matches[1]
            $rest = $matches[2]
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
            return Resolve-Command -Command $newCmd -Domain $redetectedDomain -Config $Config
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
                $pResult = Evaluate-ParameterRules -Entry $entry -ParamMap $paramMap -Config $Config -Command $Command -DisplayName $firstToken
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

function Evaluate-ParameterRules {
    param(
        $Entry,
        $ParamMap,
        $Config,
        [string]$Command,
        [string]$DisplayName
    )

    # 1. modifying rules first (fail-safe: any modifying match => ask)
    foreach ($rule in $Entry.rules) {
        if ($rule.decision -eq 'modifying' -and (Test-ParamRule $rule $ParamMap)) {
            $risk = 'unknown'
            if (Get-Member -InputObject $rule -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $risk = $rule.risk }
            return [PSCustomObject]@{
                Command = $Command; Decision = 'ask'
                Reason = "$DisplayName (parameter rule: modifying)"; MatchedPattern = $DisplayName; Risk = $risk
            }
        }
    }
    # 2. read-only rules
    foreach ($rule in $Entry.rules) {
        if ($rule.decision -eq 'read-only' -and (Test-ParamRule $rule $ParamMap)) {
            return [PSCustomObject]@{
                Command = $Command; Decision = 'allow'
                Reason = "$DisplayName (parameter rule: read-only)"; MatchedPattern = $DisplayName; Risk = 'none'
            }
        }
    }
    # 3. no rule matched
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
    if ($unrecognized -and $Config.modifying_strictness -ne 'loose') {
        return [PSCustomObject]@{
            Command = $Command; Decision = 'ask'
            Reason = "$DisplayName (unrecognized parameter value)"; MatchedPattern = $DisplayName; Risk = 'unknown'
        }
    }
    # default (absent param, OR unrecognized in loose mode)
    if ($Entry.default -eq 'modifying') {
        $dr = 'unknown'
        if (Get-Member -InputObject $Entry -Name 'default_risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $dr = $Entry.default_risk }
        return [PSCustomObject]@{
            Command = $Command; Decision = 'ask'
            Reason = "$DisplayName (parameter rule: default modifying)"; MatchedPattern = $DisplayName; Risk = $dr
        }
    }
    return [PSCustomObject]@{
        Command = $Command; Decision = 'allow'
        Reason = "$DisplayName (parameter rule: default read-only)"; MatchedPattern = $DisplayName; Risk = 'none'
    }
}
