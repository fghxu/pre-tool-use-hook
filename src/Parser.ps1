# Parser.ps1 — AST Parsing + Command Extraction from Mixed Shells
#
# Purpose:    Detect domain, parse command string into individual sub-commands
# Input:      Raw command string (e.g., "Get-Process | ForEach-Object { taskkill /pid $_.Id }")
# Output:     Array of [PSCustomObject]@{ CommandText, Domain, IsPipeline, ParentCommand }
#
# Exported functions:
#   - Get-CommandDomain      Content-based domain detection (NO dependency on IDE hints)
#   - Split-Commands         Split command into sub-commands on ; && || and |
#   - Find-NestedCommands    Extract inner commands from wrapper commands
#   - Split-SubshellCommands Extract commands from $( ... ) subshell syntax
#   - Test-RedirectionTarget Detect and classify shell redirection operators
#   - Get-PowerShellCommands AST-based PowerShell command extraction (Task 8)

# =============================================================================
# Regex constants
# =============================================================================

$script:VerbNounRegex = [regex]::new('^[A-Z]\w+-[A-Z]\w+', 'Compiled')

$script:PowershellMarkerRegex = [regex]::new(
    '(_|PSItem|ForEach-Object|Where-Object)|(\$\(|@\(|\$\{)',
    'Compiled'
)

$script:KnownBinaryPrefixes = @(
    @{ Pattern = '^docker\b';             Domain = 'docker'     },
    @{ Pattern = '^kubectl\b';            Domain = 'kubernetes' },
    @{ Pattern = '^k\s+(get|describe|apply|delete)'; Domain = 'kubernetes' },
    @{ Pattern = '^helm\b';               Domain = 'kubernetes' },
    @{ Pattern = '^terraform\b';          Domain = 'terraform'  },
    @{ Pattern = '^aws\s';                Domain = 'aws_cli'    },
    @{ Pattern = '^git\b';                Domain = 'git'        },
    @{ Pattern = '^(pwsh|powershell)\b';  Domain = 'powershell' },
    @{ Pattern = '^cmd\s+/c';             Domain = 'dos'        }
)

$script:DosMarkerRegex = [regex]::new(
    '^(dir\s|del\s|type\s|copy\s|taskkill\b|tasklist\b|reg\s|sc\s|net\s|wmic\s|schtasks\b|ping\b|tree\b|findstr\b|ipconfig\b|netstat\b|nbtstat\b|tracert\b|pathping\b|nslookup\b|systeminfo\b|ver\b|hostname\b|arp\b|driverquery\b|icacls\b|where\b|wevtutil\b)',
    'Compiled'
)

# Split on ; or && or || that are NOT inside quotes
$script:SplitOperatorRegex = [regex]::new(
    ';(?=(?:[^'']*''[^'']*'')*[^'']*$)|;(?=(?:[^"]*"[^"]*")*[^"]*$)|' +
    '&&(?=(?:[^'']*''[^'']*'')*[^'']*$)|&&(?=(?:[^"]*"[^"]*")*[^"]*$)|' +
    '\|\|(?=(?:[^'']*''[^'']*'')*[^'']*$)|(?<!\|)\|\|(?!\|)(?=(?:[^"]*"[^"]*")*[^"]*$)',
    'Compiled'
)

# =============================================================================
# Get-CommandDomain
#
# Content-based domain detection. Determines the shell domain from the command
# text alone — no dependency on IDE-provided shell hints.
#
# Detection order (first match wins):
#   1. PowerShell markers (strongest signal): Verb-Noun, $_, ForEach-Object, etc.
#   2. Known binary prefixes: docker, kubectl, terraform, aws, pwsh, cmd /c
#   3. DOS/CMD markers: dir, del, type, copy, taskkill, reg, sc, net, etc.
#   4. Fallback → "linux"
# =============================================================================

function Get-CommandDomain {
    param(
        [string]$Command
    )

    $trimmed = $Command.Trim()

    if (-not $trimmed) {
        return 'linux'
    }

    # -------------------------------------------------
    # Step 0: PowerShell variable assignment strip
    #   "$creds = aws sts get-caller-identity" → "aws sts get-caller-identity"
    #   "$x = git status" → "git status"
    #   Strips the first $var = prefix, then re-detects domain from remainder.
    #   Safe against comparison operators (-eq, -ne, -lt) because they start
    #   with '-', not '$'.  Chained assignments ($a = $b = cmd) are handled
    #   by recursion.
    # -------------------------------------------------
    if ($trimmed -match '\$[\w:]+\s*=\s*') {
        $stripped = [regex]::Replace($trimmed, '\$[\w:]+\s*=\s*', '', 1)
        if ($stripped -and $stripped -ne $trimmed) {
            return Get-CommandDomain -Command $stripped
        }
    }

    # -------------------------------------------------
    # 1. PowerShell markers (strongest signal)
    # -------------------------------------------------

    # Check for Verb-Noun pattern (e.g., Get-ChildItem, Remove-Item)
    if ($script:VerbNounRegex.IsMatch($trimmed)) {
        return 'powershell'
    }

    # Check for $_, $PSItem, | ForEach-Object, | Where-Object, @(), ${}
    # NOTE: $( is deliberately excluded — it is valid in both Bash (command
    # substitution) and PowerShell (subexpression). Treating it as a
    # PowerShell-only marker causes false positives for awk '{print $(NF-3)}'
    # and heredocs containing $(hostname) / $(uptime -p).
    # NOTE: ${ is also excluded — bash uses ${var} for parameter expansion
    # which is NOT a PowerShell-only pattern. False positive example:
    # echo "Waiting... (${elapsed}s/${timeout}s)".
    if ($trimmed -match '\$_' -or
        $trimmed -match '\$PSItem\b' -or
        $trimmed -match '\|\s*ForEach-Object\b' -or
        $trimmed -match '\|\s*Where-Object\b' -or
        $trimmed -match '@\(') {
        return 'powershell'
    }

    # -------------------------------------------------
    # 2. Known binary prefixes (check first word or words after shell wrappers)
    # -------------------------------------------------

    foreach ($prefix in $script:KnownBinaryPrefixes) {
        if ($trimmed -match $prefix.Pattern) {
            return $prefix.Domain
        }
    }

    # -------------------------------------------------
    # 3. DOS/CMD markers
    # -------------------------------------------------

    if ($script:DosMarkerRegex.IsMatch($trimmed)) {
        return 'dos_cmd'
    }

    # -------------------------------------------------
    # 4. Fallback
    # -------------------------------------------------

    return 'linux'
}

# =============================================================================
# Split-Commands
#
# Splits a command string into individual sub-commands for separate
# classification. Handles the following operators:
#   - Semicolons (;)
#   - AND (&&)
#   - OR  (||)
#   - Pipeline (|)  — only when Domain is 'powershell'
#
# Splitting is careful NOT to split inside quoted strings.
#
# Each segment is returned as a [PSCustomObject] with:
#   - CommandText  : the trimmed segment string
#   - Domain       : detected domain of the segment
#   - IsPipeline   : $true if segment is part of a pipeline chain (|)
#   - ParentCommand: $null
# =============================================================================

function Split-Commands {
    param(
        [string]$Command,
        [string]$Domain
    )

    $segments = @()

    if (-not $Command.Trim()) {
        return $segments
    }

    # Step 1: Split on semicolons first (not inside quotes)
    $semiParts = Split-NotInQuotes -Text $Command -Delimiter ';'

    foreach ($part in $semiParts) {
        # Step 2: Split each semicolon-part on && (not inside quotes)
        $andParts = Split-OperatorNotInQuotes -Text $part -Operator '&&'

        foreach ($subPart in $andParts) {
            # Step 3: Split each &&-part on || (not inside quotes)
            $orParts = Split-OperatorNotInQuotes -Text $subPart -Operator '||'

            foreach ($segment in $orParts) {
                $trimmed = $segment.Trim()
                if (-not $trimmed) { continue }

                # --------------------------------------------
                # Step 3.5: Split on newlines for multi-line segments
                # (Linux/DOS domains only — PowerShell ScriptBlocks legitimately
                # span multiple lines and should not be split on newlines).
                # Shell keywords (if/then/for/while/do/done/fi/esac/etc.)
                # are frequently followed by newlines, and multi-line segments
                # can combine both read-only and modifying commands.
                # --------------------------------------------
                if ($Domain -in @('linux', 'dos_cmd')) {
                    $lineParts = $trimmed -split '\r?\n'

                    # Track whether we are inside a 'case ... in' block so
                    # that | inside case patterns is not mistaken for a
                    # pipeline operator.
                    $inCaseBlock = $false
                    # Track function definitions seen in this multi-line block
                    # so that calls to user-defined functions can be detected.
                    $userFunctions = [System.Collections.Generic.HashSet[string]]::new()

                    foreach ($linePart in $lineParts) {
                        $lineTrimmed = $linePart.Trim()
                        if (-not $lineTrimmed) { continue }

                        # --- Track shell scope ---
                        if ($lineTrimmed -match '^\s*case\s+.*\s+in\s*$') {
                            $inCaseBlock = $true
                        }
                        if ($lineTrimmed -eq 'esac') {
                            $inCaseBlock = $false
                        }
                        # Detect bash function definitions:  name() { ... }
                        if ($lineTrimmed -match '^(\w+)\s*\(\s*\)\s*\{') {
                            [void]$userFunctions.Add($matches[1])
                        }

                        # --- Extract actual command from case-arm lines ---
                        # Case arms look like:  pattern) command ;;  or
                        # pattern|pattern) command ;;  The | between patterns
                        # is NOT a pipeline operator.  We strip the pattern
                        # prefix and trailing terminator.
                        $effectiveLine = $lineTrimmed
                        if ($inCaseBlock -and $lineTrimmed -ne 'esac' -and
                            -not ($lineTrimmed -match '^\s*case\s+') ) {
                            # Strip ;; ;;& ;& terminators from the end
                            $effectiveLine = $effectiveLine -replace '\s*;;[;&]?\s*$', ''
                            # Find the ) that separates the pattern(s) from command
                            $parenIdx = $effectiveLine.LastIndexOf(')')
                            if ($parenIdx -gt 0) {
                                $effectiveLine = $effectiveLine.Substring($parenIdx + 1).Trim()
                            }
                        }

                        # --- Skip calls to user-defined functions ---
                        # When a function is defined earlier in the same
                        # multi-line block, we already classify each line of
                        # the function body individually.  The function call
                        # itself is just an invocation — skip it.
                        if ($userFunctions.Count -gt 0) {
                            $firstWord = ($effectiveLine -split '\s+')[0]
                            if ($userFunctions.Contains($firstWord)) {
                                continue
                            }
                        }

                        $segmentDomain = Get-CommandDomain -Command $effectiveLine

                        # --------------------------------------------
                        # Step 4 (inside newline split): Split on pipeline
                        # operator | for shell domains.  Skip this for
                        # case-arm lines because | is a pattern separator
                        # there, not a pipeline.
                        # --------------------------------------------
                        if ($segmentDomain -in @('powershell', 'linux', 'dos_cmd') -and
                            $effectiveLine -match '\|' -and
                            -not $inCaseBlock) {
                            $pipeParts = Split-NotInQuotes -Text $effectiveLine -Delimiter '|'
                            $isPipeChain = ($pipeParts.Count -gt 1)

                            foreach ($pipePart in $pipeParts) {
                                $pipeTrimmed = $pipePart.Trim()
                                if ($pipeTrimmed) {
                                    $pipeDomain = Get-CommandDomain -Command $pipeTrimmed
                                    $segments += [PSCustomObject]@{
                                        CommandText   = $pipeTrimmed
                                        Domain        = $pipeDomain
                                        IsPipeline    = $isPipeChain
                                        ParentCommand = $null
                                    }
                                }
                            }
                        }
                        else {
                            $segments += [PSCustomObject]@{
                                CommandText   = $effectiveLine
                                Domain        = $segmentDomain
                                IsPipeline    = $false
                                ParentCommand = $null
                            }
                        }
                    }
                }
                else {
                    # PowerShell and other domains: no newline splitting
                    $segmentDomain = Get-CommandDomain -Command $trimmed

                    # --------------------------------------------
                    # Step 4: Split on pipeline operator | for shell domains
                    # --------------------------------------------
                    if ($segmentDomain -in @('powershell', 'linux', 'dos_cmd') -and $trimmed -match '\|') {
                        $pipeParts = Split-NotInQuotes -Text $trimmed -Delimiter '|'
                        $isPipeChain = ($pipeParts.Count -gt 1)

                        foreach ($pipePart in $pipeParts) {
                            $pipeTrimmed = $pipePart.Trim()
                            if ($pipeTrimmed) {
                                $pipeDomain = Get-CommandDomain -Command $pipeTrimmed
                                $segments += [PSCustomObject]@{
                                    CommandText   = $pipeTrimmed
                                    Domain        = $pipeDomain
                                    IsPipeline    = $isPipeChain
                                    ParentCommand = $null
                                }
                            }
                        }
                    }
                    else {
                        $segments += [PSCustomObject]@{
                            CommandText   = $trimmed
                            Domain        = $segmentDomain
                            IsPipeline    = $false
                            ParentCommand = $null
                        }
                    }
                }
            }
        }
    }

    return $segments
}

# =============================================================================
# Split-NotInQuotes (helper)
#
# Splits text on a single-character delimiter, but NOT when that delimiter
# appears inside a quoted string (single or double quotes), inside
# curly braces {}, or inside parentheses (). This prevents splitting
# inside script blocks, hashtable expressions, for/if conditions, and
# other brace/paren-delimited constructs.
# =============================================================================

function Split-NotInQuotes {
    param(
        [string]$Text,
        [char]$Delimiter
    )

    $parts = @()
    $current = ''
    $inSingle = $false
    $inDouble = $false
    $braceDepth = 0
    $parenDepth = 0
    $i = 0

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ($ch -eq "'" -and -not $inDouble) {
            $inSingle = -not $inSingle
            $current += $ch
        }
        elseif ($ch -eq '"' -and -not $inSingle) {
            $inDouble = -not $inDouble
            $current += $ch
        }
        elseif (-not $inSingle -and -not $inDouble -and $ch -eq '{') {
            $braceDepth++
            $current += $ch
        }
        elseif (-not $inSingle -and -not $inDouble -and $ch -eq '}') {
            if ($braceDepth -gt 0) {
                $braceDepth--
            }
            $current += $ch
        }
        elseif (-not $inSingle -and -not $inDouble -and $ch -eq '(') {
            $parenDepth++
            $current += $ch
        }
        elseif (-not $inSingle -and -not $inDouble -and $ch -eq ')') {
            if ($parenDepth -gt 0) {
                $parenDepth--
            }
            $current += $ch
        }
        elseif ($ch -eq $Delimiter -and -not $inSingle -and -not $inDouble -and $braceDepth -eq 0 -and $parenDepth -eq 0) {
            # Bash case terminators ;; and ;& (and bash 4.0+ ;;&) should NOT
            # be treated as two separate semicolon delimiters.  When we see
            # the first ; followed by another ; or &, consume the pair as a
            # single token so that case-arm boundaries are not split.
            if ($Delimiter -eq ';' -and ($i + 1) -lt $Text.Length) {
                $nextCh = $Text[$i + 1]
                if ($nextCh -eq ';' -or $nextCh -eq '&') {
                    $current += $ch + $nextCh
                    $i += 2
                    continue
                }
            }
            $parts += $current
            $current = ''
        }
        else {
            $current += $ch
        }

        $i++
    }

    $parts += $current

    return $parts
}

# =============================================================================
# Split-OperatorNotInQuotes (helper)
#
# Splits text on a multi-character operator (e.g., && or ||), but NOT when
# that operator appears inside a quoted string (single or double quotes).
# =============================================================================

function Split-OperatorNotInQuotes {
    param(
        [string]$Text,
        [string]$Operator
    )

    $parts = @()
    $current = ''
    $inSingle = $false
    $inDouble = $false
    $i = 0
    $opLen = $Operator.Length

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ($ch -eq "'" -and -not $inDouble) {
            $inSingle = -not $inSingle
            $current += $ch
            $i++
        }
        elseif ($ch -eq '"' -and -not $inSingle) {
            $inDouble = -not $inDouble
            $current += $ch
            $i++
        }
        elseif (-not $inSingle -and -not $inDouble -and
                ($i + $opLen -le $Text.Length) -and
                ($Text.Substring($i, $opLen) -eq $Operator)) {
            $parts += $current
            $current = ''
            $i += $opLen
        }
        else {
            $current += $ch
            $i++
        }
    }

    $parts += $current

    return $parts
}

# =============================================================================
# Find-NestedCommands
#
# For commands that wrap other commands (pwsh -Command, ssh, docker exec,
# kubectl exec, bash -c, etc.), this function detects the wrapper and extracts
# the inner command from its quoted argument.
#
# Detected wrappers:
#   - pwsh -Command "<inner>"
#   - powershell -Command "<inner>"
#   - pwsh -ScriptBlock { <inner> }
#   - bash -c '<inner>'
#   - sh -c '<inner>'
#   - cmd /c "<inner>"
#   - ssh host '<inner>'
#   - docker exec <id> "<inner>"
#   - kubectl exec <pod> -- "<inner>"
#
# Returns an array of [PSCustomObject]@{
#     CommandText   = the extracted inner command
#     Domain        = domain of the inner command
#     IsPipeline    = $false
#     ParentCommand = the wrapper command text
# }
#
# Returns an empty array if no nested commands are found.
# =============================================================================

function Find-NestedCommands {
    param(
        [string]$Command,
        [string]$ParentDomain
    )

    $nested = @()
    $trimmed = $Command.Trim()

    # -------------------------------------------------
    # Detect wrapper patterns and extract quoted/supplied inner command
    # -------------------------------------------------

    # pwsh -Command "<inner>" or powershell -Command "<inner>"
    if ($trimmed -match '^(?:\.?\\)?pwsh(?:\.exe)?\s+-Command\s+["''](.+)["'']\s*$' -or
        $trimmed -match '^(?:\.?\\)?powershell(?:\.exe)?\s+-Command\s+["''](.+)["'']\s*$' -or
        $trimmed -match '^(?:\.?\\)?pwsh(?:\.exe)?\s+-c\s+["''](.+)["'']\s*$' -or
        $trimmed -match '^(?:\.?\\)?powershell(?:\.exe)?\s+-c\s+["''](.+)["'']\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = Get-CommandDomain -Command $innerCommand

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        # Recurse: the inner command may itself have splittable sub-commands
        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # pwsh -ScriptBlock { <inner> }
    if ($trimmed -match '(?s)^(?:\.?\\)?pwsh(?:\.exe)?\s+-ScriptBlock\s+\{(.+)\}\s*$' -or
        $trimmed -match '(?s)^(?:\.?\\)?powershell(?:\.exe)?\s+-ScriptBlock\s+\{(.+)\}\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = 'powershell'

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # bash -c '<inner>' or sh -c '<inner>'
    if ($trimmed -match '^(?:bash|sh)\s+-c\s+["''](.+)["'']\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = 'linux'

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # cmd /c "<inner>"
    if ($trimmed -match '^cmd\s+/c\s+["''](.+)["'']\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = 'dos'

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # ssh [options] host <remote command...>
    #
    # Handles all SSH option patterns:
    #   - ssh user@host "command"               (simple, no options)
    #   - ssh -l user host "command"            (-l flag with space-separated login name)
    #   - ssh -i keyfile user@host "command"    (-i flag with identity file)
    #   - ssh -p port user@host "command"       (-p flag with port)
    #   - ssh -o option=value user@host "cmd"   (-o flag with option string)
    #   - ssh -v -T user@host "command"         (boolean flags)
    #   - ssh user@host ls /home                (unquoted remote command)
    #
    # Flags that take a value argument: B,b,c,D,E,e,F,I,i,J,L,l,m,O,o,P,p,Q,R,S,W,w
    # Boolean flags (no argument): 4,6,A,a,C,f,G,g,K,k,M,N,n,q,s,T,t,V,v,X,x,Y,y
    if ($trimmed -match '^ssh\s') {

        # Tokenize the command respecting single/double quotes
        $sshTokens = [System.Collections.Generic.List[string]]::new()
        $currentToken = ''
        $inSingle = $false
        $inDouble = $false

        for ($tidx = 0; $tidx -lt $trimmed.Length; $tidx++) {
            $ch = $trimmed[$tidx]
            if ($ch -eq "'" -and -not $inDouble) {
                $inSingle = -not $inSingle
                $currentToken += $ch
            }
            elseif ($ch -eq '"' -and -not $inSingle) {
                $inDouble = -not $inDouble
                $currentToken += $ch
            }
            elseif (-not $inSingle -and -not $inDouble -and $ch -eq ' ') {
                if ($currentToken.Length -gt 0) {
                    $sshTokens.Add($currentToken)
                    $currentToken = ''
                }
            }
            else {
                $currentToken += $ch
            }
        }
        if ($currentToken.Length -gt 0) {
            $sshTokens.Add($currentToken)
        }

        # Need at minimum: ssh + host + inner-command
        if ($sshTokens.Count -ge 3) {
            # SSH flags that take a value argument (case-sensitive: -c takes val, -C is boolean)
            $flagTakesValue = [System.Collections.Generic.HashSet[string]]::new()
            @('B','b','c','D','E','e','F','I','i','J','L','l','m','O','o','P','p','Q','R','S','W','w') | ForEach-Object { [void]$flagTakesValue.Add($_) }

            $i = 1  # Start after 'ssh'
            $hostIndex = -1

            while ($i -lt $sshTokens.Count) {
                $tok = $sshTokens[$i]
                if ($tok.StartsWith('-') -and $tok -ne '-') {
                    # Extract the flag letter(s) without dashes
                    $flagChars = $tok -replace '^-+', ''

                    # Check if a value is embedded in the same token: -p2222, -oOption=val, -J[user@]host
                    # Pattern: single flag letter followed immediately by digit, =, :, or [
                    if ($flagChars -match '^([a-zA-Z])[=:_\[\d]') {
                        # Value is baked in — don't skip the next token
                        $i++
                        continue
                    }

                    # Multiple flag letters smashed together (e.g. -it, -vT, -AX)
                    # None of the multi-letter combos in SSH use value-taking flags,
                    # so skip the whole token.
                    if ($flagChars.Length -gt 1) {
                        $i++
                        continue
                    }

                    # Single flag letter — check if it takes a value
                    if ($flagTakesValue.Contains($flagChars)) {
                        # This flag takes a value spaced argument.
                        # Skip both the flag and the next token (its value).
                        $i += 2
                        continue
                    }

                    # Boolean flag — skip just this token
                    $i++
                    continue
                }
                else {
                    # First non-flag, non-flag-value token is the host
                    $hostIndex = $i
                    break
                }
            }

            if ($hostIndex -ge 0 -and ($hostIndex + 1) -lt $sshTokens.Count) {
                # Everything after the host is the remote command
                $remoteArgs = $sshTokens[($hostIndex + 1)..($sshTokens.Count - 1)]
                $innerCommand = ($remoteArgs -join ' ').Trim()

                # Strip outer quotes from the inner command if present
                if ($innerCommand -match '^"(.+)"$' -or $innerCommand -match "^'(.+)'$") {
                    $innerCommand = $Matches[1]
                }
                $innerCommand = $innerCommand.Trim()

                $innerDomain = Get-CommandDomain -Command $innerCommand

                $nested += [PSCustomObject]@{
                    CommandText   = $innerCommand
                    Domain        = $innerDomain
                    IsPipeline    = $false
                    ParentCommand = $trimmed
                }

                $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
                foreach ($seg in $splitInner) {
                    $seg.ParentCommand = $trimmed
                }
                $nested += $splitInner

                # Recurse: inner may itself be a wrapped command (e.g., ssh inside pwsh)
                $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
                foreach ($in in $innerNested) {
                    $in.ParentCommand = $trimmed
                    $nested += $in
                }

                return $nested
            }
        }
    }

    # docker exec <container> "<inner>" or docker exec -it <container> "<inner>"
    if ($trimmed -match '^docker\s+exec\s+(?:-it\s+|-i\s+|-t\s+)*\S+\s+(.+?)\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = Get-CommandDomain -Command $innerCommand

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # kubectl exec <pod> -- "<inner>" or kubectl exec -it <pod> -- "<inner>"
    if ($trimmed -match '^kubectl\s+exec\s+(?:-it\s+|--\s+)*(?:\S+\s+)?--\s+["''](.+)["'']\s*$') {

        $innerCommand = $Matches[1]
        $innerDomain = Get-CommandDomain -Command $innerCommand

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # Invoke-Command with any parameters + -ScriptBlock { <inner> }
    # (?s) enables singleline mode so . matches \n (ScriptBlocks span multiple lines)
    if ($trimmed -match '(?s)Invoke-Command\s+.*?-ScriptBlock\s+\{(.+)\}\s*$') {

        $innerCommand = $Matches[1].Trim()
        $innerDomain = 'powershell'

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        $splitInner = Split-Commands -Command $innerCommand -Domain $innerDomain
        foreach ($seg in $splitInner) {
            $seg.ParentCommand = $trimmed
        }
        $nested += $splitInner

        # Recurse: inner may itself be a wrapped command
        $innerNested = Find-NestedCommands -Command $innerCommand -ParentDomain $innerDomain
        foreach ($in in $innerNested) {
            $in.ParentCommand = $trimmed
            $nested += $in
        }

        return $nested
    }

    # xargs <command> — the command piped to xargs is executed as a nested command
    # e.g., "docker ps | xargs docker rm" → extract "docker rm"
    # e.g., "kubectl get pods | xargs kubectl delete pod" → extract "kubectl delete pod"
    if ($trimmed -match 'xargs\s+(.+)$') {
        $innerCommand = $Matches[1].Trim()
        $innerDomain = Get-CommandDomain -Command $innerCommand

        $nested += [PSCustomObject]@{
            CommandText   = $innerCommand
            Domain        = $innerDomain
            IsPipeline    = $false
            ParentCommand = $trimmed
        }

        return $nested
    }

    # No nested commands found
    return $nested
}

# =============================================================================
# Split-SubshellCommands
#
# Detects $(command) subshell patterns and extracts the inner commands for
# separate classification. Handles nested parentheses and quotes within the
# subshell expression.
#
# Algorithm:
#   1. Scan the command string character-by-character, tracking quote state
#   2. When $( is found outside quotes, find the matching closing paren
#      (accounting for nested parens and inner quotes)
#   3. Extract the inner text and classify its domain
#   4. Decompose the inner text further via Split-Commands and add all
#      resulting sub-commands to the output
#
# Edge cases:
#   - Empty/null input → return @()
#   - Unmatched parentheses → skip that $( block (treat as unparseable)
#   - $( inside quotes → ignored (not a subshell)
#   - Nested $( ... $( ... ) ... ) → inner text extracted recursively
#
# Returns: [PSCustomObject[]] each with: CommandText, Domain, IsPipeline, ParentCommand
# =============================================================================

function Split-SubshellCommands {
    param(
        [string]$Command
    )

    $results = New-Object System.Collections.ArrayList

    if (-not $Command -or [string]::IsNullOrWhiteSpace($Command)) {
        return $results.ToArray()
    }

    $i = 0
    $inSingle = $false
    $inDouble = $false

    while ($i -lt $Command.Length - 1) {
        $ch = $Command[$i]

        # --------------------------------------------
        # Track quote state — $( inside quotes is not a subshell
        # --------------------------------------------
        if ($ch -eq "'" -and -not $inDouble) {
            $inSingle = -not $inSingle
            $i++
            continue
        }
        if ($ch -eq '"' -and -not $inSingle) {
            $inDouble = -not $inDouble
            $i++
            continue
        }

        # --------------------------------------------
        # Detect $( sequence (outside quotes)
        # --------------------------------------------
        # $(...) inside double-quotes is still executed in bash/PowerShell.
        # Only skip inside SINGLE quotes (everything is literal there).
        if ((-not $inSingle) -and ($ch -eq '$') -and ($Command[$i + 1] -eq '(')) {
            # ------------------------------------------------------------
            # Distinguish $(( arithmetic expansion) from $( command substitution)
            # $((elapsed + 2)) is an arithmetic expression — no command to
            # classify.  We still need to skip past the whole construct.
            # ------------------------------------------------------------
            $isArithExp = $false
            $startPos = $i + 2  # position after $(
            if (($startPos) -lt $Command.Length -and $Command[$startPos] -eq '(') {
                $isArithExp = $true
                $startPos++  # skip the second (, now pointing inside $((...))
            }
            $depth = 1
            $j = $startPos
            $innerInSingle = $false
            $innerInDouble = $false

            while ($j -lt $Command.Length -and $depth -gt 0) {
                $ich = $Command[$j]

                if ($ich -eq "'" -and -not $innerInDouble) {
                    $innerInSingle = -not $innerInSingle
                }
                elseif ($ich -eq '"' -and -not $innerInSingle) {
                    $innerInDouble = -not $innerInDouble
                }
                elseif ($ich -eq '(' -and -not $innerInSingle -and -not $innerInDouble) {
                    $depth++
                }
                elseif ($ich -eq ')' -and -not $innerInSingle -and -not $innerInDouble) {
                    $depth--
                    if ($depth -eq 0) {
                        # Found matching closing paren — extract inner text
                        $innerText = $Command.Substring($startPos, $j - $startPos).Trim()

                        # Skip non-command expressions:
                        #   - $(( ... )) arithmetic expansions
                        #   - Variable property access: $_.Name, $events.Count
                        if ($innerText -and -not $isArithExp -and
                            ($innerText -notmatch '^\$[\w:]+\.[\w:.]+$')) {
                            $innerDomain = Get-CommandDomain -Command $innerText
                            $parentLabel = "`$($innerText)"

                            # Add the subshell expression itself
                            $null = $results.Add([PSCustomObject]@{
                                CommandText   = $innerText
                                Domain        = $innerDomain
                                IsPipeline    = $false
                                ParentCommand = $parentLabel
                            })

                            # Decompose inner text further into sub-commands
                            $splitResults = Split-Commands -Command $innerText -Domain $innerDomain
                            foreach ($sr in $splitResults) {
                                if ($sr.CommandText -ne $innerText) {
                                    $sr.ParentCommand = $parentLabel
                                    $null = $results.Add($sr)
                                }
                            }

                            # Recurse: the inner text may itself have nested $(...)
                            $nestedSubshells = Split-SubshellCommands -Command $innerText
                            foreach ($ns in $nestedSubshells) {
                                $null = $results.Add($ns)
                            }
                        }
                        break
                    }
                }
                $j++
            }

            # Advance past the closing paren (or end of string if unmatched)
            $i = [Math]::Min($j + 1, $Command.Length)
            continue
        }

        $i++
    }

    return $results.ToArray()
}

# =============================================================================
# Test-RedirectionTarget
#
# Detects shell redirection operators in a command string and classifies the
# risk of the redirection target. Redirection can turn an otherwise read-only
# command into a modifying one (e.g., `ls > /etc/config`).
#
# Detection rules (checked in order):
#   1. File descriptor redirects: 2>&1, 1>&2, 2>1, etc. → read-only (no I/O)
#   2. Append redirection >>  → ask (modifying, appends data)
#   3. Output redirection >   → depends on target path:
#      - /dev/null, NUL       → read-only (discard)
#      - /tmp/*, %TEMP%\*     → allow (temp, low risk)
#      - /etc/*, /var/*, C:\Windows\*, C:\Program Files\* → ask (system, high risk)
#      - Other paths          → ask (modifying)
#   4. Input redirection <    → read-only (reads from file)
#   5. Here-string <<         → read-only (inline data)
#
# Returns: [PSCustomObject]@{
#     HasRedirection = $bool
#     Target         = the target path or description
#     Risk           = "none" | "low" | "medium" | "high"
#     Decision       = "allow" | "ask"
#     Reason         = human-readable explanation
# }
# =============================================================================

function Test-EditableOrCwd {
    <#
    Returns a reason string if the target write-path is auto-writable — either
    under the current working directory (always editable, every strictness mode)
    or matching an editable_paths pattern — or $null otherwise. Used by
    Test-RedirectionTarget for '>' and '>>' targets.
    #>
    param(
        [string]$TargetPath,
        $Config
    )
    if (-not $TargetPath -or -not $Config) { return $null }
    if (-not (Get-Member -InputObject $Config -Name '_cwd' -MemberType NoteProperty -ErrorAction SilentlyContinue)) { return $null }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $resolved = $TargetPath.Trim()
    $isHome = $resolved.StartsWith('~')
    # If relative (no drive letter, no root separator, not a ~ home path), anchor to CWD.
    if (-not $isHome -and $resolved -notmatch '^[A-Za-z]:[\\/]' -and $resolved -notmatch '^[\\/]') {
        $resolved = "$($Config._cwd)$resolved"
    }
    # Canonicalize (collapse ..) and unify separators. Skip GetFullPath for home
    # paths (~): it would anchor them to the process CWD, falsely marking them
    # "under current directory". Home is never the project CWD.
    if ($isHome) {
        $resolved = ($resolved -replace '[/\\]', $sep)
    }
    else {
        try {
            $resolved = ([System.IO.Path]::GetFullPath($resolved) -replace '[/\\]', $sep)
        }
        catch {
            $resolved = ($resolved -replace '[/\\]', $sep)
        }
    }
    $resolvedLower = $resolved.ToLowerInvariant()

    # Under CWD? (always editable)
    if ($Config._cwdNorm -and $resolvedLower.StartsWith($Config._cwdNorm)) {
        return 'under current directory'
    }
    # Matches editable_paths?
    $editableEnabled = $false
    if (Get-Member -InputObject $Config -Name '_editablePathsEnabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $editableEnabled = [bool]$Config._editablePathsEnabled
    }
    if ($editableEnabled -and (Get-Member -InputObject $Config -Name '_editablePathRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        if ($resolved -match $Config._editablePathRegex) {
            return 'editable path'
        }
    }
    return $null
}

function Test-RedirectionTarget {
    param(
        [string]$Command,
        [PSCustomObject]$Config = $null
    )

    $result = [PSCustomObject]@{
        HasRedirection = $false
        Target         = ""
        Risk           = "none"
        Decision       = "allow"
        Reason         = ""
    }

    if (-not $Command -or [string]::IsNullOrWhiteSpace($Command)) {
        return $result
    }

    $trimmed = $Command.Trim()

    # =========================================================================
    # 1. File descriptor redirects: >&2, 2>&1, 1>&2, etc.
    #    These redirect stderr/stdout — no filesystem side effect.
    # =========================================================================
    if ($trimmed -match '(?:\d)?>\s*&\s*\d') {
        $result.HasRedirection = $true
        $result.Target = "file descriptor redirect"
        $result.Risk = "none"
        $result.Decision = "allow"
        $result.Reason = "file descriptor redirect (read-only)"
        return $result
    }

    # =========================================================================
    # 2. Here-string << operator — inline data, read-only
    # =========================================================================
    if ($trimmed -match '<<\s*') {
        $result.HasRedirection = $true
        $result.Target = "here-string"
        $result.Risk = "none"
        $result.Decision = "allow"
        $result.Reason = "here-string redirect (read-only)"
        return $result
    }

    # =========================================================================
    # 3. Append redirection >> — modifying in strict mode, allowed for non-system in normal mode
    # =========================================================================
    if ($trimmed -match '(?<![>])>>(?![>])') {
        $result.HasRedirection = $true

        $targetPath = ""
        if ($trimmed -match '(?<![>])>>\s*([^\s;|&]+)') { $targetPath = $matches[1] }

        # Temp/discard paths always allowed
        if ($targetPath -and $targetPath -match '^(/dev/null|NUL|/tmp/|/var/tmp/|%TEMP%|%TMP%|^\$env:TEMP|^\$env:TMP)') {
            $result.Target = $targetPath
            $result.Risk = "none"
            $result.Decision = "allow"
            $result.Reason = "append redirect to $targetPath (temp/discard)"
        }
        # System paths always ask (must win over editable/CWD)
        elseif ($Config -and $targetPath -and $targetPath -match $Config._systemPathRegex) {
            $result.Target = $targetPath
            $result.Risk = "high"
            $result.Decision = "ask"
            $result.Reason = "append redirect to $targetPath (system path)"
        }
        else {
            $writableReason = Test-EditableOrCwd -TargetPath $targetPath -Config $Config
            if ($writableReason) {
                $result.Target = $targetPath
                $result.Risk = "low"
                $result.Decision = "allow"
                $result.Reason = "append redirect to $targetPath ($writableReason)"
            }
            elseif ($Config -and $Config.modifying_strictness -eq 'loose') {
                $result.Target = $targetPath
                $result.Risk = "low"
                $result.Decision = "allow"
                $result.Reason = "append redirect to $targetPath (allowed in loose mode)"
            }
            elseif ($Config -and $Config.modifying_strictness -eq 'normal' -and -not $Config._editablePathsEnabled) {
                $result.Target = $targetPath
                $result.Risk = "low"
                $result.Decision = "allow"
                $result.Reason = "append redirect to $targetPath (allowed in normal mode)"
            }
            else {
                $result.Risk = "medium"
                $result.Decision = "ask"
                $result.Reason = if ($targetPath) { "append redirect to $targetPath (modifying)" } else { "append redirection (modifying)" }
                $result.Target = if ($targetPath) { $targetPath } else { "unknown" }
            }
        }
        return $result
    }

    # =========================================================================
    # 4. Output redirection > (single, not >>)
    #    Risk depends on target path.
    # =========================================================================
    if ($trimmed -match '(?<![>])>(?![>])') {
        $result.HasRedirection = $true

        # Extract the target path
        $targetPath = ""
        if ($trimmed -match '(?<![>])>\s*([^\s;|&]+)') {
            $targetPath = $matches[1]
        }

        if ($targetPath) {
            $result.Target = $targetPath

            # -- 4a. Discard targets --
            if ($targetPath -match '^(/dev/null|NUL)$') {
                $result.Risk = "none"
                $result.Decision = "allow"
                $result.Reason = "redirect to discard ($targetPath) (read-only)"
            }
            # -- 4b. Temp paths (low risk) --
            elseif ($targetPath -match '^/tmp/|^/var/tmp/|^%TEMP%|^%TMP%|^\$env:TEMP|^\$env:TMP') {
                $result.Risk = "low"
                $result.Decision = "allow"
                $result.Reason = "redirect to temp path ($targetPath) (low risk)"
            }
            # -- 4c. System paths (high risk) — from config.json system_paths --
            elseif ($Config -and $targetPath -match $Config._systemPathRegex) {
                $result.Risk = "high"
                $result.Decision = "ask"
                $result.Reason = "redirect to system path ($targetPath) (high risk)"
            }
            # -- 4d. Other paths — editable_paths/CWD, else strictness-governed --
            else {
                $writableReason = Test-EditableOrCwd -TargetPath $targetPath -Config $Config
                if ($writableReason) {
                    $result.Risk = "low"
                    $result.Decision = "allow"
                    $result.Reason = "output redirect to $targetPath ($writableReason)"
                }
                elseif ($Config -and $Config.modifying_strictness -eq 'loose') {
                    $result.Risk = "low"
                    $result.Decision = "allow"
                    $result.Reason = "output redirect to $targetPath (allowed in loose mode)"
                }
                elseif ($Config -and $Config.modifying_strictness -eq 'normal' -and -not $Config._editablePathsEnabled) {
                    $result.Risk = "low"
                    $result.Decision = "allow"
                    $result.Reason = "output redirect to $targetPath (allowed in normal mode)"
                }
                else {
                    $result.Risk = "medium"
                    $result.Decision = "ask"
                    $result.Reason = "output redirect to $targetPath (modifying)"
                }
            }
        }
        else {
            # Redirect without explicit target (unusual but possible)
            $result.Target = "unknown"
            $result.Risk = "medium"
            $result.Decision = "ask"
            $result.Reason = "output redirect (modifying)"
        }
        return $result
    }

    # =========================================================================
    # 5. Input redirection < — read-only (reads from file, no write)
    # =========================================================================
    if ($trimmed -match '(?<![<])<(?![<])') {
        $result.HasRedirection = $true
        $result.Risk = "none"
        $result.Decision = "allow"
        $result.Reason = "input redirection (read-only)"

        # Extract target for diagnostics
        if ($trimmed -match '(?<![<])<\s*([^\s;|&]+)') {
            $result.Target = $matches[1]
            $result.Reason = "input redirect from $($matches[1]) (read-only)"
        }
        return $result
    }

    # No redirection detected
    return $result
}

# =============================================================================
# Get-PowerShellCommands  (Task 8 — AST-based PowerShell Command Extraction)
#
# Uses the PowerShell AST parser (System.Management.Automation.Language) to
# decompose a PowerShell command string into individual sub-commands. This is
# more accurate than regex-based splitting because it understands PowerShell
# syntax natively — quotes, script blocks, nested expressions, etc.
#
# Walk order:
#   1. ParseInput() → ScriptBlockAst
#   2. Find all CommandAst nodes (direct command invocations)
#   3. Find all PipelineAst nodes to flag multi-element pipelines
#   4. Find all ScriptBlockAst nodes → recurse into EndBlock for inner commands
#   5. Find all StringConstantExpressionAst nodes → detect command-like strings
#   6. For known wrappers (pwsh, bash, ssh, docker exec, kubectl exec):
#      extract the inner command from arguments
#
# Returns: [PSCustomObject[]]  each with:
#   - CommandText   : the sub-command string
#   - Domain        : detected domain (powershell, linux, dos, docker, etc.)
#   - IsPipeline    : $true if command is in a multi-element pipeline
#   - ParentCommand : the wrapper command text, or $null
#
# Error handling:
#   - If AST parser not available (e.g., older PowerShell) → return @()
#   - If ParseInput reports $errors → return @() (caller falls back to regex)
# =============================================================================

function Get-PowerShellCommands {
    param(
        [string]$Command
    )

    # -------------------------------------------------
    # Guard: AST parser availability
    # -------------------------------------------------
    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) {
        return @()
    }

    $tokens = $null
    $errors = $null

    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch {
        return @()
    }

    # If the parser reported errors, bail out — caller falls back to regex
    if ($errors -and $errors.Count -gt 0) {
        return @()
    }

    if (-not $ast) {
        return @()
    }

    # Delegate to the recursive AST walker
    return Get-AstCommands -Ast $ast -ParentCommand $null
}

# =============================================================================
# Get-AstCommands  (recursive AST walker)
#
# Walks a PowerShell AST node tree and collects all command invocations.
#
# How it works:
#   - Uses Ast.FindAll({predicate}, $true) to recursively search the tree
#   - Processes four node types: CommandAst, PipelineAst, ScriptBlockAst,
#     StringConstantExpressionAst
#   - Deduplicates by command text (same text with same parent only added once)
#   - For wrapper commands, extracts inner commands via Get-AstWrapperInnerCommands
#   - Recursively processes inner ScriptBlock content
# =============================================================================

function Get-AstCommands {
    param(
        $Ast,
        [string]$ParentCommand
    )

    if (-not $Ast) {
        return @()
    }

    $results = New-Object System.Collections.ArrayList
    $seenKeys = @{}

    # =========================================================================
    # Inline helper — add a result unless we have already seen this key
    # =========================================================================
    function AddResult {
        param(
            $ResultsList,
            $SeenMap,
            [string]$CmdText,
            [string]$Domain,
            [bool]$IsPipeline,
            [string]$Parent
        )

        if (-not $CmdText) { return }
        $key = "$($CmdText.Trim())<<|>>$Parent"
        if (-not $SeenMap.ContainsKey($key)) {
            $SeenMap[$key] = $true
            $null = $ResultsList.Add([PSCustomObject]@{
                CommandText   = $CmdText.Trim()
                Domain        = $Domain
                IsPipeline    = $IsPipeline
                ParentCommand = $Parent
            })
        }
    }

    # =========================================================================
    # 1. Pipeline detection — find all PipelineAst nodes to build a set of
    #    CommandAst texts that belong to multi-element pipelines
    # =========================================================================
    $pipelineMembers = @{}
    $pipelines = $Ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.PipelineAst] },
        $true
    )
    foreach ($p in $pipelines) {
        if ($p.PipelineElements.Count -gt 1) {
            foreach ($elem in $p.PipelineElements) {
                if ($elem -is [System.Management.Automation.Language.CommandAst]) {
                    $pipelineMembers[$elem.Extent.Text] = $true
                }
            }
        }
    }

    # =========================================================================
    # 2. CommandAst — direct command invocations
    # =========================================================================
    $commandAsts = $Ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.CommandAst] },
        $true
    )
    foreach ($cmd in $commandAsts) {
        $commandText = $cmd.Extent.Text
        if (-not $commandText) { continue }

        $domain = Get-CommandDomain -Command $commandText
        $isPipeline = $pipelineMembers.ContainsKey($commandText)

        $commandElements = $cmd.CommandElements
        $commandName = ''
        if ($commandElements.Count -gt 0) {
            $commandName = $commandElements[0].Extent.Text
        }

        # --------------------------------------------
        # Call operator: & { <scriptblock> } or . { <scriptblock> }
        # The invocation itself is not a command to classify; the inner
        # commands are already found by the ScriptBlockAst recursion below.
        # --------------------------------------------
        if (($cmd.InvocationOperator -eq 'Ampersand' -or $cmd.InvocationOperator -eq 'Dot') -and
            $commandElements.Count -eq 1 -and
            $commandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            continue
        }

        # --------------------------------------------
        # Wrapper detection — if this is a known wrapper, extract inner commands
        # --------------------------------------------
        if ($commandName -and $commandElements.Count -ge 2) {
            $wrapperResults = Get-AstWrapperInnerCommands `
                -CommandAst $cmd `
                -CommandText $commandText `
                -CommandName $commandName

            foreach ($wr in $wrapperResults) {
                $innerCmd = $wr.CommandText
                $innerDom = $wr.Domain

                # Add the inner command itself
                AddResult -ResultsList $results -SeenMap $seenKeys `
                    -CmdText $innerCmd -Domain $innerDom `
                    -IsPipeline $false -Parent $commandText

                # Recurse into the inner command if it is PowerShell
                if ($innerDom -eq 'powershell') {
                    $innerAstCmds = Get-PowerShellCommands -Command $innerCmd
                    foreach ($iac in $innerAstCmds) {
                        if ($iac.CommandText -ne $innerCmd) {
                            AddResult -ResultsList $results -SeenMap $seenKeys `
                                -CmdText $iac.CommandText -Domain $iac.Domain `
                                -IsPipeline $iac.IsPipeline -Parent $innerCmd
                        }
                    }
                }
                else {
                    # Non-PowerShell domain: use Split-Commands for further decomposition
                    $splitInner = Split-Commands -Command $innerCmd -Domain $innerDom
                    foreach ($si in $splitInner) {
                        if ($si.CommandText -ne $innerCmd) {
                            AddResult -ResultsList $results -SeenMap $seenKeys `
                                -CmdText $si.CommandText -Domain $si.Domain `
                                -IsPipeline $si.IsPipeline -Parent $innerCmd
                        }
                    }
                }
            }
        }

        # Add the outer command itself
        AddResult -ResultsList $results -SeenMap $seenKeys `
            -CmdText $commandText -Domain $domain `
            -IsPipeline $isPipeline -Parent $ParentCommand
    }

    # =========================================================================
    # 3. ScriptBlockAst — recurse into EndBlock for inner commands
    #    Handles patterns like: Invoke-Command -ScriptBlock { Get-Service }
    # =========================================================================
    $scriptBlocks = $Ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.ScriptBlockAst] },
        $true
    )
    foreach ($sb in $scriptBlocks) {
        if ($sb.EndBlock) {
            $innerResults = Get-AstCommands -Ast $sb.EndBlock -ParentCommand $ParentCommand
            foreach ($ir in $innerResults) {
                AddResult -ResultsList $results -SeenMap $seenKeys `
                    -CmdText $ir.CommandText -Domain $ir.Domain `
                    -IsPipeline $ir.IsPipeline -Parent $ir.ParentCommand
            }
        }
    }

    # =========================================================================
    # 4. StringConstantExpressionAst — detect command-like string literals
    #    Handles patterns like: pwsh -Command "docker ps; kubectl get pods"
    # =========================================================================
    $stringAsts = $Ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] },
        $true
    )
    foreach ($str in $stringAsts) {
        $strValue = $str.Value
        # Heuristic: a string that contains command separators or looks like
        # an executable pipeline (starts with a known binary prefix) could be
        # a shell command.  Plain prose strings like "Deployment status:" or
        # paths like "C:\Program Files" are excluded.
        $isCommandLike = $false
        if ($strValue -and $strValue.Trim()) {
            $trimmedStr = $strValue.Trim()
            # Only treat a string constant as a command-like literal if it is a
            # top-level statement (its CommandExpressionAst parent is a direct
            # child of the pipeline or named block) AND has a separator/newline
            # AND a word pair; or if it starts with a known command prefix.
            # Strings that are cmdlet/operator arguments (e.g., -Pattern 'a|b',
            # -replace 'x|y') must NOT be extracted as standalone commands.
            $parentType = if ($str.Parent) { $str.Parent.GetType().Name } else { '' }
            $grandParentType = if ($str.Parent -and $str.Parent.Parent) { $str.Parent.Parent.GetType().Name } else { '' }
            $isTopLevel = ($parentType -eq 'CommandExpressionAst' -and $grandParentType -in @('PipelineAst', 'NamedBlockAst'))
            if ($isTopLevel -and ($trimmedStr -match '[;&|]' -or $trimmedStr -match "`n") -and ($trimmedStr -match '\S\s+\S')) {
                $isCommandLike = $true
            }
            elseif ($trimmedStr -match '^(aws|docker|kubectl|helm|terraform|git|npm|yarn|python|node|pwsh|powershell|bash|sh|cmd|ssh|scp|make|go|cargo|dotnet|java|perl|ruby|php)\s') {
                $isCommandLike = $true
            }
        }
        if ($isCommandLike) {
            $innerDomain = Get-CommandDomain -Command $strValue

            if ($innerDomain -eq 'powershell') {
                $innerAstCmds = Get-PowerShellCommands -Command $strValue
                foreach ($iac in $innerAstCmds) {
                    AddResult -ResultsList $results -SeenMap $seenKeys `
                        -CmdText $iac.CommandText -Domain $iac.Domain `
                        -IsPipeline $iac.IsPipeline -Parent $ParentCommand
                }
            }
            else {
                # Non-PowerShell string: add it, then also try Split-Commands
                # for finer decomposition (e.g., "docker ps; kubectl get pods")
                AddResult -ResultsList $results -SeenMap $seenKeys `
                    -CmdText $strValue -Domain $innerDomain `
                    -IsPipeline $false -Parent $ParentCommand

                $splitResults = Split-Commands -Command $strValue -Domain $innerDomain
                foreach ($sr in $splitResults) {
                    if ($sr.CommandText -ne $strValue) {
                        AddResult -ResultsList $results -SeenMap $seenKeys `
                            -CmdText $sr.CommandText -Domain $sr.Domain `
                            -IsPipeline $sr.IsPipeline -Parent $strValue
                    }
                }
            }
        }
    }

    return $results.ToArray()
}

# =============================================================================
# Get-AstWrapperInnerCommands
#
# Extracts the inner command text from known wrapper command AST nodes.
#
# Detected wrappers (AST-aware versions):
#   pwsh / powershell  →  -Command "<inner>", -c "<inner>", -ScriptBlock { ... }
#   bash / sh          →  -c '<inner>'
#   cmd                →  /c "<inner>", /k "<inner>"
#   ssh                →  ssh host <remote command...>
#   docker exec        →  docker exec [opts] <container> <command...>
#   kubectl exec       →  kubectl exec [opts] <pod> -- <command...>
#
# Returns: [PSCustomObject[]] with: CommandText, Domain, IsPipeline
# =============================================================================

function Get-AstWrapperInnerCommands {
    param(
        $CommandAst,
        [string]$CommandText,
        [string]$CommandName
    )

    $results = New-Object System.Collections.ArrayList
    $commandElements = $CommandAst.CommandElements
    if ($commandElements.Count -lt 2) {
        return $results.ToArray()
    }

    # Safety net: any CommandAst whose first element is a scriptblock literal
    # (e.g., "& { ... } arg1") is an invocation of that scriptblock — surface
    # the body as an inner PowerShell command.
    if ($commandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $sbExpr = $commandElements[0]
        if ($sbExpr.ScriptBlock -and $sbExpr.ScriptBlock.EndBlock) {
            $innerCommand = $sbExpr.ScriptBlock.EndBlock.Extent.Text
            if ($innerCommand) {
                $null = $results.Add([PSCustomObject]@{
                    CommandText = $innerCommand
                    Domain      = 'powershell'
                    IsPipeline  = $false
                })
            }
        }
        return $results.ToArray()
    }

    $elementCount = $commandElements.Count

    # =========================================================================
    # pwsh / powershell  —  -Command, -c, -ScriptBlock
    # =========================================================================
    if ($CommandName -match '^(pwsh|powershell)$') {
        for ($i = 1; $i -lt $elementCount; $i++) {
            $arg = $commandElements[$i]
            $argText = $arg.Extent.Text

            # -Command "inner"  or  -c "inner"
            if ($argText -match '^-(Command|c)$' -and ($i + 1) -lt $elementCount) {
                $nextArg = $commandElements[$i + 1]
                if ($nextArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $innerCommand = $nextArg.Value
                }
                elseif ($nextArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    $innerCommand = $nextArg.Extent.Text.Trim('"').Trim("'")
                }
                if ($innerCommand) {
                    $innerDomain = Get-CommandDomain -Command $innerCommand
                    $null = $results.Add([PSCustomObject]@{
                        CommandText = $innerCommand
                        Domain      = $innerDomain
                        IsPipeline  = $false
                    })
                }
                $i++   # skip the value element
            }
            # -ScriptBlock { ... }
            elseif ($argText -eq '-ScriptBlock' -and ($i + 1) -lt $elementCount) {
                $nextArg = $commandElements[$i + 1]
                if ($nextArg -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    if ($nextArg.ScriptBlock -and $nextArg.ScriptBlock.EndBlock) {
                        $sbContent = $nextArg.ScriptBlock.EndBlock.Extent.Text
                        if ($sbContent) {
                            $null = $results.Add([PSCustomObject]@{
                                CommandText = $sbContent
                                Domain      = 'powershell'
                                IsPipeline  = $false
                            })
                        }
                    }
                }
                $i++
            }
        }
        return $results.ToArray()
    }

    # =========================================================================
    # bash / sh  —  -c '<inner>'
    # =========================================================================
    if ($CommandName -match '^(bash|sh)$') {
        for ($i = 1; $i -lt $elementCount; $i++) {
            $argText = $commandElements[$i].Extent.Text
            if ($argText -eq '-c' -and ($i + 1) -lt $elementCount) {
                $nextArg = $commandElements[$i + 1]
                if ($nextArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $innerCommand = $nextArg.Value
                }
                elseif ($nextArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    $innerCommand = $nextArg.Extent.Text.Trim('"').Trim("'")
                }
                if ($innerCommand) {
                    $null = $results.Add([PSCustomObject]@{
                        CommandText = $innerCommand
                        Domain      = 'linux'
                        IsPipeline  = $false
                    })
                }
                $i++
            }
        }
        return $results.ToArray()
    }

    # =========================================================================
    # cmd  —  /c "<inner>"  or  /k "<inner>"
    # =========================================================================
    if ($CommandName -eq 'cmd') {
        for ($i = 1; $i -lt $elementCount; $i++) {
            $argText = $commandElements[$i].Extent.Text
            if ($argText -match '^/[ck]$' -and ($i + 1) -lt $elementCount) {
                $nextArg = $commandElements[$i + 1]
                if ($nextArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $innerCommand = $nextArg.Value
                }
                elseif ($nextArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    $innerCommand = $nextArg.Extent.Text.Trim('"').Trim("'")
                }
                if ($innerCommand) {
                    $null = $results.Add([PSCustomObject]@{
                        CommandText = $innerCommand
                        Domain      = 'dos'
                        IsPipeline  = $false
                    })
                }
                $i++
            }
        }
        return $results.ToArray()
    }

    # =========================================================================
    # ssh  —  ssh [options] host <remote command...>
    # =========================================================================
    if ($CommandName -eq 'ssh') {
        # Skip past flags that start with -
        $hostIndex = 1
        while ($hostIndex -lt $elementCount) {
            $argText = $commandElements[$hostIndex].Extent.Text
            if ($argText -notmatch '^-') { break }
            $hostIndex++
        }
        if ($hostIndex -ge $elementCount) {
            return $results.ToArray()
        }

        # The element at hostIndex is the host/user@host.
        # Everything after it is the remote command.
        if ($hostIndex + 1 -lt $elementCount) {
            $remoteArgs = @()
            for ($j = $hostIndex + 1; $j -lt $elementCount; $j++) {
                $elem = $commandElements[$j]
                if ($elem -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $remoteArgs += $elem.Value
                }
                else {
                    $remoteArgs += $elem.Extent.Text
                }
            }
            $remoteCommand = $remoteArgs -join ' '
            if ($remoteCommand) {
                $innerDomain = Get-CommandDomain -Command $remoteCommand
                $null = $results.Add([PSCustomObject]@{
                    CommandText = $remoteCommand
                    Domain      = $innerDomain
                    IsPipeline  = $false
                })
            }
        }
        return $results.ToArray()
    }

    # =========================================================================
    # docker exec  —  docker exec [opts] <container> <command...>
    # =========================================================================
    if ($CommandName -eq 'docker' -and $elementCount -ge 3) {
        $subCmd = $commandElements[1].Extent.Text
        if ($subCmd -eq 'exec') {
            # Skip flags/options starting with - (element 2 onward until we
            # find the container name)
            $containerIndex = 2
            while ($containerIndex -lt $elementCount) {
                $argText = $commandElements[$containerIndex].Extent.Text
                if ($argText -notmatch '^-') { break }
                # Also skip merged short flags like -it
                $containerIndex++
            }
            if ($containerIndex -ge $elementCount) {
                return $results.ToArray()
            }

            # Everything after the container is the inner command
            if ($containerIndex + 1 -lt $elementCount) {
                $innerArgs = @()
                for ($j = $containerIndex + 1; $j -lt $elementCount; $j++) {
                    $elem = $commandElements[$j]
                    if ($elem -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $innerArgs += $elem.Value
                    }
                    else {
                        $innerArgs += $elem.Extent.Text
                    }
                }
                $innerCommand = $innerArgs -join ' '
                if ($innerCommand) {
                    $innerDomain = Get-CommandDomain -Command $innerCommand
                    $null = $results.Add([PSCustomObject]@{
                        CommandText = $innerCommand
                        Domain      = $innerDomain
                        IsPipeline  = $false
                    })
                }
            }
        }
        return $results.ToArray()
    }

    # =========================================================================
    # kubectl exec  —  kubectl exec [opts] <pod> -- <command...>
    # =========================================================================
    if ($CommandName -eq 'kubectl' -and $elementCount -ge 3) {
        $subCmd = $commandElements[1].Extent.Text
        if ($subCmd -eq 'exec') {
            # Find the -- separator
            $dashDashIndex = -1
            for ($i = 2; $i -lt $elementCount; $i++) {
                if ($commandElements[$i].Extent.Text -eq '--') {
                    $dashDashIndex = $i
                    break
                }
            }
            if ($dashDashIndex -lt 0 -or ($dashDashIndex + 1) -ge $elementCount) {
                return $results.ToArray()
            }

            # Everything after -- is the remote command
            $remoteArgs = @()
            for ($j = $dashDashIndex + 1; $j -lt $elementCount; $j++) {
                $elem = $commandElements[$j]
                if ($elem -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $remoteArgs += $elem.Value
                }
                else {
                    $remoteArgs += $elem.Extent.Text
                }
            }
            $remoteCommand = $remoteArgs -join ' '
            if ($remoteCommand) {
                $innerDomain = Get-CommandDomain -Command $remoteCommand
                $null = $results.Add([PSCustomObject]@{
                    CommandText = $remoteCommand
                    Domain      = $innerDomain
                    IsPipeline  = $false
                })
            }
        }
        return $results.ToArray()
    }

    # No wrapper matched
    return $results.ToArray()
}

# =============================================================================
# Test-SafeAst
#
# Shared safe-expression certifier. Used by:
#   - Get-PowerShellSafeExpressions (primary path, zero-command lines)
#   - Invoke-PowerShellArbitration   (arbiter gate in Classifier.ps1)
#
# A node is SAFE when it provably has no side effects:
#   - no command invocations except those already resolved ALLOW
#     (their text is in $AllowedCommands)
#   - no .NET method calls outside the config allowlist
#     ($Config._dotnetMethodAllowlist)
#   - no property SETs (assignment LHS must be a variable / index / array)
#   - no redirections anywhere in the subtree
# Anything unrecognized is unsafe (fail closed).
# =============================================================================

function Test-SafeAst {
    param(
        $Ast,
        [System.Collections.Generic.HashSet[string]]$AllowedCommands,
        [PSCustomObject]$Config
    )

    if ($null -eq $Ast) { return $true }

    # Redirections anywhere in the subtree are never safe (they write files).
    if ($Ast -is [System.Management.Automation.Language.RedirectionAst]) { return $false }

    $typeName = $Ast.GetType().Name

    switch ($typeName) {
        'AssignmentStatementAst' {
            $lhs = $Ast.Left
            $lhsOk = ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) -or
                     ($lhs -is [System.Management.Automation.Language.IndexExpressionAst]) -or
                     ($lhs -is [System.Management.Automation.Language.ArrayLiteralAst])
            if (-not $lhsOk) { return $false }
            return (Test-SafeAst -Ast $Ast.Left -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Right -AllowedCommands $AllowedCommands -Config $Config)
        }
        'PipelineAst' {
            foreach ($elem in $Ast.PipelineElements) {
                if (-not (Test-SafeAst -Ast $elem -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'StatementBlockAst' {
            foreach ($stmt in $Ast.Statements) {
                if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'HashtableAst' {
            foreach ($kvp in $Ast.KeyValuePairs) {
                if (-not (Test-SafeAst -Ast $kvp.Item1 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
                if (-not (Test-SafeAst -Ast $kvp.Item2 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ArrayLiteralAst' {
            foreach ($elem in $Ast.Elements) {
                if (-not (Test-SafeAst -Ast $elem -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ParenExpressionAst'   { return Test-SafeAst -Ast $Ast.Pipeline -AllowedCommands $AllowedCommands -Config $Config }
        'ArrayExpressionAst'   { return Test-SafeAst -Ast $Ast.SubExpression -AllowedCommands $AllowedCommands -Config $Config }
        'SubExpressionAst'     { return Test-SafeAst -Ast $Ast.SubExpression -AllowedCommands $AllowedCommands -Config $Config }
        'StringConstantExpressionAst' { return $true }
        'ExpandableStringExpressionAst' {
            foreach ($nest in $Ast.NestedExpressions) {
                if (-not (Test-SafeAst -Ast $nest -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'VariableExpressionAst' { return $true }
        'ConstantExpressionAst' { return $true }
        'TypeExpressionAst'     { return $true }
        'MemberExpressionAst' {
            return Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config
        }
        'InvokeMemberExpressionAst' {
            $methodName = $null
            if ($Ast.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $methodName = $Ast.Member.Value
            }
            if (-not $methodName) { return $false }
            $allowSet = $null
            if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetMethodAllowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $allowSet = $Config._dotnetMethodAllowlist
            }
            if (-not $allowSet -or -not $allowSet.Contains($methodName)) { return $false }
            if (-not (Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            foreach ($arg in $Ast.Arguments) {
                if (-not (Test-SafeAst -Ast $arg -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'IndexExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Target -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Index -AllowedCommands $AllowedCommands -Config $Config)
        }
        'BinaryExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Left -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Right -AllowedCommands $AllowedCommands -Config $Config)
        }
        'UnaryExpressionAst' {
            return Test-SafeAst -Ast $Ast.Child -AllowedCommands $AllowedCommands -Config $Config
        }
        'CommandAst' {
            return ($null -ne $AllowedCommands) -and $AllowedCommands.Contains($Ast.Extent.Text.Trim())
        }
        'ScriptBlockAst' {
            $blocks = @($Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) | Where-Object { $_ }
            foreach ($b in $blocks) {
                if (-not (Test-SafeAst -Ast $b -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ScriptBlockExpressionAst' {
            return Test-SafeAst -Ast $Ast.ScriptBlock -AllowedCommands $AllowedCommands -Config $Config
        }
        default {
            return $false
        }
    }
}

# =============================================================================
# Get-PowerShellSafeExpressions
#
# When a powershell-domain command string contains no cmdlet invocations but
# only safe expressions, return one synthetic '(safe expression)' command per
# input so the classifier can allow it instead of falling back to regex
# splitting. Returns @() if ANY top-level statement is unsafe.
# =============================================================================

function Get-PowerShellSafeExpressions {
    param(
        [string]$Command,
        [PSCustomObject]$Config = $null
    )

    $results = @()
    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $results }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $results }
    if ($errors -and $errors.Count -gt 0) { return $results }
    if (-not $ast -or -not $ast.EndBlock) { return $results }

    $statements = $ast.EndBlock.Statements
    if ($statements.Count -eq 0) { return $results }

    $emptySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($stmt in $statements) {
        if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $emptySet -Config $Config)) {
            return @()   # any unsafe statement -> no fallback, regex path stays
        }
    }

    $results += [PSCustomObject]@{
        CommandText   = '(safe expression)'
        Domain        = 'powershell'
        IsPipeline    = $false
        ParentCommand = $null
    }
    return $results
}
