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

$script:VerbNounRegex = [regex]::new('^[A-Z]\w+-[A-Z]\w+', 'Compiled,IgnoreCase')

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
    # NOTE: git is intentionally NOT routed to a 'git' domain (2026-09-16
    # parameter_commands rework). It classifies via Linux.parameter_commands.git
    # (Step 7), so subcommands/flags may appear anywhere in the command line.
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
# Script drilldown (2026-09-20): registry, dispatcher, per-call state
#
# When the agent runs `pwsh -File <script>.ps1`, the hook opens the file,
# splits it into statements via the existing AST walker, and classifies each
# as if typed on the command line. Gated by $script:ScriptDrilldown (published
# by Load-Config; $null when the feature is OFF). See design doc
# docs/superpowers/specs/2026-09-20-script-drilldown-design.md.
# =============================================================================

# Registry of per-language script-runner matchers. Each matcher:
#   INPUT : the command/statement text, RAW (the matcher normalizes internally)
#   OUTPUT: $null (no invocation) or @{ Runner = 'powershell'; ScriptPath = '<as written>' }
# v1 ships ONE entry ('powershell'). Adding a language = a new registry entry +
# extending the implemented-runner set in ConfigLoader.ps1 (never a rework).
$script:ScriptRunnerMatchers = @(
    @{
        Runner = 'powershell'
        Match  = {
            param([string]$Text)
            # Normalize EXACTLY like Find-NestedCommands' head: strip a leading
            # call operator, rewrite a quoted full-path pwsh.exe/powershell.exe to
            # 'pwsh' so the anchored pattern matches. Idempotent with SITE B's own
            # pre-normalization; extends coverage to '& "C:\...\pwsh.exe" -File z'
            # statements inside scripts and to SITE A wrapper texts.
            $s = ($Text -replace '^\s*&\s+', '').Trim()
            if ($s -match '^[''"]([A-Za-z]:\\(?:.*\\)?(?:pwsh|powershell)(?:\.exe)?)[''"]') {
                $s = 'pwsh' + $s.Substring($Matches[0].Length)
            }
            # GUARD (mirrors hasFileBeforeCommand in Find-NestedCommands): when a
            # -Command/-c token PRECEDES -File, that '-File' belongs to the inner
            # command string, not to this runner -- refuse, or the (\S+) arm grabs a
            # garbage path. The caller falls through to normal -Command unwrapping.
            $f = [regex]::Match($s, '(?i)-File\b')
            if ($f.Success) {
                $c = [regex]::Match($s, '(?i)-(?:Command|c)\s+["'']')
                if ($c.Success -and $c.Index -lt $f.Index) { return $null }
            }
            # PRODUCTION regex verbatim (spec fact #3). Keep its existing
            # asymmetries -- do not "improve" them in this change.
            if ($s -match '(?i)^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))') {
                $p = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
                if ($p) { return @{ Runner = 'powershell'; ScriptPath = $p } }
            }
            return $null
        }
    }
)

# Per-tool-call visited set: canonicalized absolute path (lowercased) -> $true.
# Inserted ONLY at engine step 7 (CLAIM), after loop/cap/size pass. Reset at the
# top of STEP 4 in Invoke-Classify (one intercepted tool call = one fresh HT).
$script:DrilldownVisited = @{}

function Find-ScriptRunnerInvocation {
    param([string]$SegmentText)
    $gate = $script:ScriptDrilldown
    if (-not $gate) { return $null }
    foreach ($m in $script:ScriptRunnerMatchers) {
        if ($gate.Runners -notcontains $m.Runner) { continue }
        $hit = & $m.Match -Text $SegmentText
        if ($hit) { return $hit }
    }
    return $null
}

function Reset-ScriptDrilldownState {
    # Clear the per-tool-call visited set (cheap; called unconditionally at the
    # top of STEP 4 in Invoke-Classify). Also refreshes the gate's Cwd snapshot:
    # TestRunner -Cwd rewrites $config._cwd AFTER Load-Config returns, so the
    # engine must see the CURRENT _cwd, not the one captured at load time.
    $script:DrilldownVisited = @{}
    $gate = $script:ScriptDrilldown
    if ($gate -and $gate.Config) {
        $gate.Cwd = "$($gate.Config._cwd)"
    }
}

# Test-DrilldownInvocationText: is this text the BARE '.ps1' invocation shape that
# engine step 9b recurses on ('. .\y.ps1', '& .\y.ps1 -Flag', bare '.\y.ps1',
# or the collapsed 'scripts\z.ps1' of a nested 'pwsh -File z.ps1')? Shares step
# 9b's regex (literal paths only; '$' and quote chars excluded so variable paths
# stay fail-closed). Used by the AST walker's re-walk to recognize the collapsed
# -File representation of an invocation the engine already owns.
function Test-DrilldownInvocationText {
    param([string]$Text)
    if (-not $Text) { return $false }
    return [bool]($Text -match '^\s*([.&]\s*)?(?:"([^"]+\.ps1)"|''([^'']+\.ps1)''|([^\s$''"]+\.ps1))(\s|$)')
}

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
    #   "[xml]$cfg = Invoke-RestMethod ..." → "Invoke-RestMethod ..." (type-cast)
    #   Strips the first [type]$var = / $var = prefix, then re-detects domain
    #   from remainder. The LHS of an assignment is not a command; the RHS
    #   decides the domain (so "[int]$x = git status" routes to git, exactly
    #   like "$x = git status"). Safe against comparison operators (-eq, -ne,
    #   -lt) because they start with '-', not '$'. Chained assignments
    #   ($a = $b = cmd) are handled by recursion. The type-cast form is
    #   anchored at ^ and requires "$var =" immediately after the closing ],
    #   so a bash "[token]" (test builtin / [[ ... ]]) can never match;
    #   generic casts ([List[string]]$x) do not match and stay fail-closed.
    # -------------------------------------------------
    if ($trimmed -match '^\[[\w.]+\]\s*\$[\w:]+\s*=\s*') {
        $stripped = [regex]::Replace($trimmed, '^\[[\w.]+\]\s*\$[\w:]+\s*=\s*', '', 1)
        if ($stripped -and $stripped -ne $trimmed) {
            return Get-CommandDomain -Command $stripped
        }
    }
    if ($trimmed -match '\$[\w:]+\s*=\s*') {
        $stripped = [regex]::Replace($trimmed, '\$[\w:]+\s*=\s*', '', 1)
        if ($stripped -and $stripped -ne $trimmed) {
            return Get-CommandDomain -Command $stripped
        }
    }

    # -------------------------------------------------
    # 1. PowerShell markers (strongest signal)
    # -------------------------------------------------

    # Check for Verb-Noun pattern (e.g., Get-ChildItem, Remove-Item).
    # PowerShell cmdlet names are CASE-INSENSITIVE, so 'format-table' /
    # 'convertfrom-json' typed lowercase are still PowerShell. The regex uses
    # the ExplicitCapture + IgnoreCase options (case-insensitive) so lowercase
    # Verb-Noun cmdlets are not mis-routed to the linux domain (2026-08-03 user
    # report: 'format-table -autosize' / 'convertfrom-json' fell to linux and
    # resolved as generic 'unknown command').
    if ($script:VerbNounRegex.IsMatch($trimmed)) {
        return 'powershell'
    }

    # Check for $_, $PSItem, | ForEach-Object, | Where-Object, @(), ${}
    # NOTE: a stray $_ in a KNOWN BINARY command's arguments must NOT override
    # the leading binary (2026-08-03 user report: 'aws ... --arn $_' was
    # hijacked into the PowerShell domain, hiding the aws 'describe-' read-only
    # prefix). Known binaries (aws/git/docker/kubectl/terraform/helm) are
    # routed by their HEAD token first; $_ inside their args is just data.
    # NOTE: $( is deliberately excluded — it is valid in both Bash (command
    # substitution) and PowerShell (subexpression). Treating it as a
    # PowerShell-only marker causes false positives for awk '{print $(NF-3)}'
    # and heredocs containing $(hostname) / $(uptime -p).
    # NOTE: ${ is also excluded — bash uses ${var} for parameter expansion
    # which is NOT a PowerShell-only pattern. False positive example:
    # echo "Waiting... (${elapsed}s/${timeout}s)".
    $startsKnownBinary = $false
    foreach ($prefix in $script:KnownBinaryPrefixes) {
        if ($trimmed -match $prefix.Pattern) { $startsKnownBinary = $true; break }
    }
    if (-not $startsKnownBinary -and
        ($trimmed -match '\$_' -or
         $trimmed -match '\$PSItem\b' -or
         $trimmed -match '\|\s*ForEach-Object\b' -or
         $trimmed -match '\|\s*Where-Object\b' -or
         $trimmed -match '@\(')) {
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
                        # operator | for ALL domains (aws/git/docker/kubectl/
                        # terraform included - a pipe is a pipe regardless of
                        # the leading command; the splitter is quote+paren
                        # aware so pipes inside "( ... )" stay put). Skip
                        # case-arm lines: | is a pattern separator there.
                        # --------------------------------------------
                        if ($effectiveLine -match '\|' -and
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
                    # Step 4: Split on pipeline operator | for ALL domains
                    # (2026-08-02 hole: an aws_cli pipeline was classified as
                    # ONE segment; the splitter is quote+paren aware so pipes
                    # inside "( ... )" stay put).
                    # --------------------------------------------
                    if ($trimmed -match '\|') {
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

    # ---------------------------------------------------------------------
    # Step 5: paren-group extraction (non-PowerShell segments only).
    # PowerShell-style subexpressions like  --request-id (aws ... ).Property
    # hide whole commands inside flag arguments; regex domains never saw
    # inside the parens (2026-08-02 user-reported hole: a modifying
    # provision-permission-set inside an aws describe- call auto-allowed).
    # A group is extracted only when its content is command-shaped (maps to
    # a known domain, or contains a top-level operator) - data groups like
    # (status.phase=Running) stay put. PowerShell segments are covered by
    # the AST walk and are skipped here.
    # ---------------------------------------------------------------------
    $extra = @()
    foreach ($seg in $segments) {
        if ($seg.Domain -eq 'powershell') { continue }
        foreach ($g in @(Get-ParenGroupContents -Text $seg.CommandText)) {
            if (Test-ParenContentIsCommand -Inner $g) {
                $gt = $g.Trim()
                $extra += [PSCustomObject]@{
                    CommandText   = $gt
                    Domain        = (Get-CommandDomain -Command $gt)
                    IsPipeline    = $false
                    ParentCommand = $seg.CommandText
                }
                # One nested level: parens inside the extracted content.
                foreach ($g2 in @(Get-ParenGroupContents -Text $gt)) {
                    if (Test-ParenContentIsCommand -Inner $g2) {
                        $g2t = $g2.Trim()
                        $extra += [PSCustomObject]@{
                            CommandText   = $g2t
                            Domain        = (Get-CommandDomain -Command $g2t)
                            IsPipeline    = $false
                            ParentCommand = $gt
                        }
                    }
                }
            }
        }
    }
    if ($extra.Count -gt 0) { $segments += $extra }

    return $segments
}

# Get-ParenGroupContents: quote-aware scan returning the contents of every
# balanced TOP-LEVEL "( ... )" group in the text (without the parens).
# Unbalanced opens are discarded; nesting is handled by the caller recursing
# into extracted contents.
function Get-ParenGroupContents {
    param([string]$Text)
    $groups = @()
    $inS = $false; $inD = $false; $pd = 0; $start = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inS) { if ($ch -eq "'") { $inS = $false }; continue }
        if ($inD) { if ($ch -eq '"') { $inD = $false }; continue }
        if ($ch -eq "'") { $inS = $true; continue }
        if ($ch -eq '"') { $inD = $true; continue }
        if ($ch -eq '(') { if ($pd -eq 0) { $start = $i + 1 }; $pd++; continue }
        if ($ch -eq ')') {
            $pd--
            if ($pd -eq 0 -and $start -ge 0) {
                $groups += $Text.Substring($start, $i - $start)
                $start = -1
            }
            if ($pd -lt 0) { $pd = 0 }
        }
    }
    return ,$groups
}

# Test-ParenContentIsCommand: is a paren group's content command-shaped?
# Yes when it maps to a known (non-linux-fallback) domain, or when it has a
# top-level pipe/semicolon/&& /|| operator. Data groups (field selectors,
# filter values, bare words like "hello world") return false.
function Test-ParenContentIsCommand {
    param([string]$Inner)
    $t = $Inner.Trim()
    if (-not $t) { return $false }
    if ((Get-CommandDomain -Command $t) -ne 'linux') { return $true }
    if (@(Split-NotInQuotes -Text $t -Delimiter ';').Count -gt 1) { return $true }
    if (@(Split-NotInQuotes -Text $t -Delimiter '|').Count -gt 1) { return $true }
    if (@(Split-OperatorNotInQuotes -Text $t -Operator '&&').Count -gt 1) { return $true }
    if (@(Split-OperatorNotInQuotes -Text $t -Operator '||').Count -gt 1) { return $true }
    return $false
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
# Expand-ScriptFile  (script drilldown engine, 2026-09-20)
#
# THE expansion engine. Given a script path (as written in a -File invocation or
# a dot-source/&/bare statement) and the invoking text, it opens the file, splits
# it into statements via the existing AST walker, and returns parser-level entries
# for each statement -- classified downstream as if typed on the command line.
#
# Called ONLY from the two -File sites (SITE A Get-AstWrapperInnerCommands, SITE B
# Find-NestedCommands) for the outer invocation, and from itself (for nested
# invocations found inside expanded scripts).
#
# Return contract:
#   $null  -> DO NOT EXPAND. Feature OFF (gate $null) OR path TRUSTED (D9). The
#             calling SITE then emits today's path entry itself, so OFF and
#             trusted are indistinguishable to the sites (one code path, no drift).
#   array  -> parser-level entries. Kinds:
#     STATEMENT      OriginScript=<basename>, LineNumber=<int>, DisplayText=
#                    '<script:b> <stmt>'. NO SkipRewalk (plain statements stay
#                    re-walkable so nested wrappers inside scripts keep unwrapping).
#     NESTED-WRAPPER SkipRewalk=$true (a 'pwsh -File z' statement kept as an entry;
#                    re-walking it would re-enter the engine for z).
#     FAILURE        AtomicReason=<reason>, DrilldownMarker=$true, SkipRewalk=$true.
#                    SITE A additionally sets IsTerminal=$true.
#
# The ORDER of the checks below IS the spec (design doc 6.2): gate -> trust ->
# resolve -> exists -> loop -> cap -> size -> claim+read -> empty -> emit.
# =============================================================================

# Build a STATEMENT entry: a plain script statement, re-walkable (NO SkipRewalk),
# carrying origin metadata for the Classifier's reason formatting and the LLM
# scope filter. LineNumber 0 = unavailable (regex-fallback path) => the '(line N)'
# suffix is omitted downstream.
function New-DrilldownStatementEntry {
    param(
        [string]$Text,
        [string]$Domain,
        [bool]$IsPipeline,
        [string]$WrapperText,
        [int]$LineNumber,
        [string]$OriginScript
    )
    $e = [PSCustomObject]@{
        CommandText   = $Text
        Domain        = $Domain
        IsPipeline    = $IsPipeline
        ParentCommand = $WrapperText
        OriginScript  = $OriginScript
        DisplayText   = "<script:$OriginScript> $Text"
    }
    if ($LineNumber) { $e | Add-Member -NotePropertyName LineNumber -NotePropertyValue $LineNumber }
    return $e
}

# Build a NESTED-WRAPPER entry: a 'pwsh -File z' statement kept as an [N] line.
# SkipRewalk=$true prevents the walker from re-entering the engine for z (the
# engine already expanded it). Resolves read_only via the pwsh wrapper pattern.
function New-DrilldownNestedWrapperEntry {
    param([string]$Text, [string]$WrapperText)
    return [PSCustomObject]@{
        CommandText   = $Text
        Domain        = 'powershell'
        IsPipeline    = $false
        ParentCommand = $WrapperText
        SkipRewalk    = $true
    }
}

# Build a FAILURE entry: a pre-computed fail-closed reason (one of the six causes).
# AtomicReason is honored verbatim by STEP 4e; DrilldownMarker makes it a KNOWN
# blocker (MatchedPattern='script-drilldown' stamped in 4e) so the AST-arbiter gate
# stays closed. SkipRewalk=$true prevents engine re-entry on the invocation text.
function New-DrilldownFailureEntry {
    param([string]$Text, [string]$WrapperText, [string]$Reason)
    return [PSCustomObject]@{
        CommandText     = $Text
        Domain          = 'powershell'
        IsPipeline      = $false
        ParentCommand   = $WrapperText
        AtomicReason    = $Reason
        DrilldownMarker = $true
        SkipRewalk      = $true
    }
}

function Expand-ScriptFile {
    param(
        [string]$ScriptPath,     # path AS WRITTEN in the command/statement
        [string]$WrapperText     # the invoking text (wrapper line or statement), for ParentCommand
    )

    # -- 0. GATE (defensive; sites check first) --
    $gate = $script:ScriptDrilldown
    if (-not $gate) { return $null }

    # -- 1. TRUST (D9): trusted path is NEVER read; return $null so the site
    #      emits today's path entry (trusted_program allow). Same return as OFF.
    $hit = Test-TrustedProgram -Token $ScriptPath -Config $gate.Config
    if ($hit) { return $null }

    # -- 2. RESOLVE: anchor relative paths to $Config._cwd, unify separators,
    #      strip \\?\, collapse '..'. Do NOT use bare GetFullPath (it anchors to
    #      the PROCESS cwd and diverges under TestRunner -Cwd).
    $full = ConvertTo-CanonicalWritePath -TargetPath $ScriptPath -Config $gate.Config

    # -- 3. EXISTS: an unread file consumes no chain slot (NOT inserted into HT).
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return @(New-DrilldownFailureEntry -Text $ScriptPath -WrapperText $WrapperText `
            -Reason "script file not found: $ScriptPath (resolved to $full)")
    }

    # -- 4. LOOP: same hit covers true recursion a->b->a AND double invocation a;a.
    $key = (ConvertTo-CanonicalWritePath -TargetPath $full -Config $gate.Config).ToLowerInvariant()
    if ($script:DrilldownVisited.ContainsKey($key)) {
        return @(New-DrilldownFailureEntry -Text $ScriptPath -WrapperText $WrapperText `
            -Reason "recursive script invocation detected: $ScriptPath")
    }

    # -- 5. CAP: at most MaxChainedFiles file reads per decision (D11/D12).
    if ($script:DrilldownVisited.Count -ge $gate.MaxChainedFiles) {
        return @(New-DrilldownFailureEntry -Text $ScriptPath -WrapperText $WrapperText `
            -Reason "max chained files exceeded ($($gate.MaxChainedFiles)): $ScriptPath")
    }

    # -- 6. SIZE: refuse to read a file over the byte cap (fail-closed).
    $len = (Get-Item -LiteralPath $full).Length
    if ($len -gt $gate.MaxFileBytes) {
        return @(New-DrilldownFailureEntry -Text $ScriptPath -WrapperText $WrapperText `
            -Reason "script too large to inspect ($len > $($gate.MaxFileBytes)): $ScriptPath")
    }

    # -- 7. CLAIM + READ: insert into HT (after loop/cap/size pass), then read.
    #      ReadAllText (NOT Get-Content): BOM-sniffing + UTF-8 default, so a
    #      BOM-less UTF-8 script does not mojibake under powershell.exe 5.1.
    $script:DrilldownVisited[$key] = $true
    $content = [System.IO.File]::ReadAllText($full)
    # DrilldownEnabled=$false is LOAD-BEARING (spec 6.5): the engine's OWN content
    # walk must let the walker COLLAPSE any nested 'pwsh -File z' to the bare path
    # z WITHOUT expanding it. Step 9b is the single, intended expansion point for
    # those collapsed paths (RUL-1). If we left drilldown ON here, the walker's own
    # SITE A would expand z and claim its HT key first, so 9b's re-expansion hits
    # the loop-check and mints a spurious 'recursive' FAILURE (SD-Allow-NestedFile).
    $stmts = @(Get-PowerShellCommands -Command $content -DrilldownEnabled $false)   # existing walker (F3/F4)

    # -- 8. EMPTY / UNPARSABLE: zero commands -> recover the raw top-level
    #      statement texts; still zero -> fail-closed ask. Two distinct shapes:
    #      (a) AST PARSE SUCCEEDED but yielded no CommandAst — the content is
    #          pure expressions (comments, assignments, .NET static calls like
    #          [Foo]::Bar()). Split-Commands MANGLES this (it reads ':' inside
    #          interpolation and swallows comments into one fragment), so emit
    #          each raw statement text as a plain entry instead: 4e classifies
    #          it (unknown => RUL-3 'script x contains unknown command: ...').
    #      (b) AST PARSE FAILED — fall back to the regex splitter (legacy).
    #      Fallback statements carry NO LineNumber, so their reasons omit the
    #      '(line N)' suffix.
    if ($stmts.Count -eq 0) {
        $rawStmts = @()
        $astType8 = 'System.Management.Automation.Language.Parser' -as [type]
        if ($astType8) {
            $t8 = $null; $e8 = $null
            try { $ast8 = $astType8::ParseInput($content, [ref]$t8, [ref]$e8) } catch { $ast8 = $null }
            if ($ast8 -and (-not $e8 -or $e8.Count -eq 0) -and $ast8.EndBlock) {
                foreach ($st in $ast8.EndBlock.Statements) {
                    $txt = "$($st.Extent.Text)".Trim()
                    if ($txt) { $rawStmts += [PSCustomObject]@{ CommandText = $txt; Domain = 'powershell' } }
                }
            }
        }
        if ($rawStmts.Count -eq 0) {
            $stmts = @(Split-Commands -Command $content -Domain 'powershell')
        }
        else {
            $stmts = $rawStmts
        }
    }
    if ($stmts.Count -eq 0) {
        return @(New-DrilldownFailureEntry -Text $ScriptPath -WrapperText $WrapperText `
            -Reason "script contains no classifiable statements (fail-closed): $ScriptPath")
    }

    # -- 9. EMIT: per statement, recurse on invocation-shaped text, else emit a
    #      plain STATEMENT entry with origin metadata.
    $basename = [System.IO.Path]::GetFileName($ScriptPath)
    $out = @()
    # Local duplicate guard (2026-09-21 fix): the walker can hand us SEVERAL entries
    # for ONE invocation - e.g. for the statement `pwsh -Command "pwsh -File z.ps1"`
    # it emits both the wrapper text `pwsh -File z.ps1` (from the -Command unwrapping)
    # AND the bare path `z.ps1` (the F11 collapse produced by re-walking that text).
    # Without this guard the first entry expands z (claiming its HT key) and the second
    # hits the loop-check, minting a spurious 'recursive script invocation detected'
    # ask for a non-recursive script (SD-Allow-CommandWrapsFile). A target already
    # expanded from THIS file's statement list is therefore skipped: its statements are
    # already emitted, so nothing is lost (same rationale as 9b's replace-not-keep).
    # Cross-file recursion (a -> b -> a) is unaffected: b's statement list has its own
    # empty local set, so the HT check still catches it.
    $expandedHere = @{}
    foreach ($s in $stmts) {
        $text = "$($s.CommandText)"
        if (-not $text) { continue }
        # Line number from the AST walker (F4); 0 on the regex-fallback path,
        # which carries no LineNumber property => '(line N)' omitted downstream.
        # IsPipeline is pre-computed into a local: passing [bool]$s.IsPipeline
        # INLINE as a parameter argument hits a PS parsing quirk (binds a string);
        # a variable binds cleanly.
        $lineNum = 0
        if ($s.PSObject.Properties['LineNumber']) { $lineNum = [int]$s.LineNumber }
        $isPipe = $false
        if ($s.PSObject.Properties['IsPipeline']) { $isPipe = [bool]$s.IsPipeline }

        # a) FALLBACK-PATH RUNNER: only step-8 Split-Commands fallback statements
        #    can carry wrapper text (on the AST path the walker already collapsed
        #    every nested 'pwsh -File z' to the bare path, which 9b handles).
        $inv = Find-ScriptRunnerInvocation -SegmentText $text
        if ($inv) {
            $lk = $inv.ScriptPath
            $lkFull = ConvertTo-CanonicalWritePath -TargetPath $lk -Config $gate.Config
            if ($lkFull) { $lk = $lkFull.ToLowerInvariant() }
            if ($expandedHere.ContainsKey($lk)) { continue }
            $sub = Expand-ScriptFile -ScriptPath $inv.ScriptPath -WrapperText $text
            if (@($sub | Where-Object { $_.PSObject.Properties['OriginScript'] }).Count -gt 0) {
                $expandedHere[$lk] = $true
                # SUCCEEDED: emit a NESTED-WRAPPER entry (resolves read_only via the
                # pwsh pattern, a harmless [N] line) + all sub entries.
                $out += New-DrilldownNestedWrapperEntry -Text $text -WrapperText $WrapperText
                foreach ($se in $sub) { $out += $se }
            }
            else {
                # FAILED: emit a FAILURE entry = the statement text + sub's reason.
                # @() wrap is LOAD-BEARING on PS 5.1: a single-entry engine return
                # arrives as a bare PSCustomObject (not an array), and 5.1 has no
                # .Count on non-collections, so '$sub.Count -gt 0' is false there
                # (pwsh 7 added .Count to all objects, masking it). @() normalizes.
                $reason = ''
                if (@($sub).Count -gt 0 -and $sub[0].PSObject.Properties['AtomicReason']) {
                    $reason = "$($sub[0].AtomicReason)"
                }
                $out += New-DrilldownFailureEntry -Text $text -WrapperText $WrapperText -Reason $reason
            }
            continue
        }

        # b) INVOCATION-SHAPED (D13 + RUL-1/RUL-2): a literal .ps1 path as the FIRST
        #    token -- '. .\y.ps1', '& .\y.ps1 -Flag', bare '.\y.ps1 -Flag' (RUL-2),
        #    AND the bare 'scripts\z.ps1' a nested 'pwsh -File scripts\z.ps1' collapses
        #    to (F11/RUL-1). The unquoted arm excludes '$' and both quote chars so
        #    variable paths stay fail-closed. This is THE recursion rule for AST-walked
        #    statements. (PS single-quote string: each literal ' is written as ''.)
        if ($text -match '^\s*([.&]\s*)?(?:"([^"]+\.ps1)"|''([^'']+\.ps1)''|([^\s$''"]+\.ps1))(\s|$)') {
            $path = if ($Matches[2]) { $Matches[2] } elseif ($Matches[3]) { $Matches[3] } else { $Matches[4] }
            if ($path) {
                $lk2 = ConvertTo-CanonicalWritePath -TargetPath $path -Config $gate.Config
                if ($lk2) { $lk2 = $lk2.ToLowerInvariant() }
                if ($lk2 -and $expandedHere.ContainsKey($lk2)) { continue }
                $sub = Expand-ScriptFile -ScriptPath $path -WrapperText $text
                if ($null -eq $sub) {
                    # TRUSTED (or feature off mid-tree): KEEP the statement as a plain
                    # entry with Domain FORCED to 'powershell' (F12: the walker labels
                    # '. x.ps1'/bare paths 'linux', which would miss the Resolver's
                    # dot-strip + Test-TrustedProgram and wrongly ask). NO SkipRewalk.
                    $out += New-DrilldownStatementEntry -Text $text -Domain 'powershell' `
                        -IsPipeline $false -WrapperText $WrapperText -LineNumber $lineNum `
                        -OriginScript $basename
                }
                elseif (@($sub | Where-Object { $_.PSObject.Properties['OriginScript'] }).Count -gt 0) {
                    $expandedHere[$lk2] = $true
                    # SUCCEEDED: emit the sub entries ONLY (the invocation statement is
                    # REPLACED, not kept -- if kept it would resolve unknown and always
                    # ask; y's statements fully represent it).
                    foreach ($se in $sub) { $out += $se }
                }
                else {
                    # FAILED: emit a FAILURE entry = the statement text + sub's reason.
                    # @() wrap is LOAD-BEARING on PS 5.1 (see case-a above): a
                    # single-entry return has no .Count there, so the guard must
                    # normalize through @() or the reason is silently dropped.
                    $reason = ''
                    if (@($sub).Count -gt 0 -and $sub[0].PSObject.Properties['AtomicReason']) {
                        $reason = "$($sub[0].AtomicReason)"
                    }
                    $out += New-DrilldownFailureEntry -Text $text -WrapperText $WrapperText -Reason $reason
                }
                continue
            }
        }

        # c) PLAIN: emit a STATEMENT entry (NO SkipRewalk -- the engine's own walk
        #    already unwrapped any nested wrappers, so the re-walk is a harmless
        #    same-text skip + attribution; wrapper-shaped texts never reach here).
        $out += New-DrilldownStatementEntry -Text $text -Domain "$($s.Domain)" `
            -IsPipeline $isPipe -WrapperText $WrapperText `
            -LineNumber $lineNum -OriginScript $basename
    }
    return $out
}

# =============================================================================
# Find-NestedCommands
#
# For commands that wrap other commands (pwsh -Command, ssh, docker exec,
# kubectl exec, bash -c, etc.), this function detects the wrapper and extracts
# the inner command from its quoted argument.
#
# Detected wrappers:
#   - pwsh/powershell[.exe] [flags...] -Command "<inner>" / -c "<inner>"
#   - pwsh/powershell[.exe] [flags...] -ScriptBlock { <inner> }
#   - pwsh/powershell[.exe] [flags...] -File <path> (extracts script path for trusted_programs check)
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

    # Normalize: strip & call operator and resolve full-path pwsh.exe/powershell.exe
    # so patterns below can match regardless of invocation form:
    #   pwsh -File x.ps1           → pwsh -File x.ps1
    #   & 'C:\...\pwsh.exe' -File  → pwsh -File ...
    $trimmed = $trimmed -replace '^\s*&\s+', ''
    if ($trimmed -match '^[''"]([A-Za-z]:\\(?:.*\\)?(?:pwsh|powershell)(?:\.exe)?)[''"]') {
        $restAfterPath = $trimmed.Substring($Matches[0].Length)
        $trimmed = "pwsh$restAfterPath"
    }

    # -------------------------------------------------
    # Detect wrapper patterns and extract quoted/supplied inner command
    # -------------------------------------------------

    # pwsh/powershell[.exe] [flags...] -Command "<inner>" / -c "<inner>"
    # Flags between the binary and -Command (e.g. -ExecutionPolicy Bypass,
    # -NoProfile) are skipped via lazy .*? — Claude Code always emits them.
    # GUARD: skip this branch when -File precedes -Command. With -File <script>,
    # powershell passes everything after the script path to the SCRIPT as $args,
    # so a later -Command belongs to the script, not to powershell (otherwise
    # 'powershell -File trusted.ps1 -Command "Remove-Item x"' mis-extracts
    # Remove-Item as a modifying inner). Let it fall through to the -File branch.
    $hasFileBeforeCommand = $false
    $m = [regex]::Match($trimmed, '(?i)-File\b')
    if ($m.Success) {
        $cMatch = [regex]::Match($trimmed, '(?i)-(?:Command|c)\s+["'']')
        if ($cMatch.Success -and $m.Index -lt $cMatch.Index) { $hasFileBeforeCommand = $true }
    }
    if (-not $hasFileBeforeCommand -and $trimmed -match '^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-(?:Command|c)\s+["''](.+)["'']\s*$') {

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

    # pwsh/powershell[.exe] [flags...] -ScriptBlock { <inner> }
    if ($trimmed -match '(?s)^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-ScriptBlock\s+\{(.+)\}\s*$') {

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

    # pwsh/powershell[.exe] [flags...] -File <path>
    # Script file content is opaque, but the script PATH can be checked against
    # trusted_programs. Extract the path as a sub-command so the Resolver's
    # Step 0f-trust (Test-TrustedProgram) can match it. If the path is NOT in
    # trusted_programs, the Resolver treats it as unknown/unclassified → ask.
    # Handles quoted and unquoted paths.
    if ($trimmed -match '(?i)^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))') {
        $filePath = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
        if ($filePath) {
            # Script drilldown (2026-09-20): when the gate is armed, open the script
            # and emit its statements as-if-typed. The dispatcher makes the gate/runner
            # decision; we use the regex-extracted $filePath (SITE B's own path source).
            # $null (feature OFF or path TRUSTED) => today's path entry, byte-identical.
            # A successful expansion emits a wrapper entry + statements (all with
            # ParentCommand=$trimmed); the segment itself is dropped by the existing
            # parentTexts filter in COMBINE. A failure emits the engine's FAILURE entry
            # (CommandText=script path, ParentCommand=$trimmed).
            $inv = Find-ScriptRunnerInvocation -SegmentText $trimmed
            if ($inv) {
                $expanded = Expand-ScriptFile -ScriptPath $filePath -WrapperText $trimmed
                if ($null -ne $expanded) {
                    if (@($expanded | Where-Object { $_.PSObject.Properties['OriginScript'] }).Count -gt 0) {
                        # SUCCEEDED: wrapper entry [1] + statements [2..n]. The wrapper
                        # carries the full 'pwsh -File ...' text (resolves read_only via
                        # the pwsh pattern, a harmless [N] line). No IsTerminal here --
                        # that is SITE A's Get-AstCommands suppressOuter mechanism.
                        $nested += [PSCustomObject]@{
                            CommandText   = $trimmed
                            Domain        = 'powershell'
                            IsPipeline    = $false
                            ParentCommand = $trimmed
                        }
                        foreach ($e in $expanded) { $nested += $e }
                    }
                    else {
                        # FAILED: the engine's single FAILURE entry (ParentCommand is
                        # already $trimmed from WrapperText).
                        $nested += $expanded[0]
                    }
                    return $nested
                }
            }
            # OFF / trusted: today's path entry. Route as PowerShell domain — the path
            # is a PowerShell script, and the Resolver's full-path stripping +
            # Test-TrustedProgram will handle it.
            $nested += [PSCustomObject]@{
                CommandText   = $filePath
                Domain        = 'powershell'
                IsPipeline    = $false
                ParentCommand = $trimmed
            }
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

# Split-GuardTokens: quote-aware whitespace tokenizer. Quoted spans keep their
# content whole (quotes stripped), so "C:\Windows\my file.txt" survives as one
# token and cannot smuggle a protected path past the path-shape scan.
# Unbalanced quotes keep the remainder as one token (fail-safe direction).
# SHARED helper: relocated here from LlmReview.ps1 (2026-09-18, R2) so that
# Resolver.ps1's Step 0g-delete can use it under the TestRunner load graph
# (TestRunner dot-sources Parser but NOT LlmReview). LlmReview.ps1 keeps calling
# it; Parser loads before both in every entry path.
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

# Test-CommandTargetsSystemPaths: belt-and-braces INV-3 guard for the LLM
# attributed merge (R2, 2026-09-18). Returns $true if ANY literal absolute-path
# token in the command text canonicalizes to a system path. Takes COMMAND TEXT
# (not a path array — that is Test-SystemPathsOnly's job for tool payloads).
# Conservative by design: it scans EVERY path-like token (including flag values
# such as '-Exclude C:\Windows\*'), so it can only DENY suppression more often,
# never less. By construction Step 0g-delete rows 1/2 can never produce an allow
# tier for a system target, so this guard only defends against future regressions
# — cheap, and it makes INV-3 auditable in the merge (mirrors how the 2026-08-26
# tool-gate spec made system_paths absolute for tools).
function Test-CommandTargetsSystemPaths {
    param(
        [string]$Command,
        $Config
    )
    if (-not $Command -or -not $Config) { return $false }
    if (-not (Get-Member -InputObject $Config -Name '_systemPathRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) { return $false }
    $sysRe = $Config._systemPathRegex
    if (-not $sysRe) { return $false }

    $tokens = @(Split-GuardTokens $Command)
    foreach ($t in $tokens) {
        if (-not $t) { continue }
        # Only literal absolute-path tokens: drive letter (C:\ or C:/), POSIX root
        # (/), or UNC (\\). Skip flags, relative paths, variables, provider paths.
        if ($t -match '^[A-Za-z]:[\\/]' -or $t -match '^/' -or $t -match '^\\\\') {
            $c = ConvertTo-CanonicalWritePath -TargetPath $t -Config $Config
            if ($c -and ($c -match $sysRe)) { return $true }
        }
    }
    return $false
}

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

function ConvertTo-CanonicalWritePath {
    <#
    Canonicalize a write-target path: strip \\?\ extended-length prefix, anchor
    relative paths to CWD, collapse .. via GetFullPath (Windows-drive and
    relative paths only), unify separators. POSIX-absolute paths (starting
    with /) are separator-unified but NOT passed through GetFullPath (on a
    Windows host GetFullPath('/tmp/x') would wrongly become C:\tmp\x).
    ~ home paths: separators unified only (home is never the project CWD).
    #>
    param(
        [string]$TargetPath,
        $Config
    )
    if (-not $TargetPath) { return $null }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $resolved = $TargetPath.Trim()
    if (-not $resolved) { return $null }
    # Strip \\?\ extended-length prefix; \\?\UNC\server\share -> \\server\share
    if ($resolved.StartsWith('\\?\UNC\')) { $resolved = '\\' + $resolved.Substring(8) }
    elseif ($resolved.StartsWith('\\?\')) { $resolved = $resolved.Substring(4) }
    $isHome = $resolved.StartsWith('~')
    $isPosix = $resolved.StartsWith('/')
    if (-not $isHome -and -not $isPosix -and $resolved -notmatch '^[A-Za-z]:[\\/]' -and $resolved -notmatch '^[\\/]') {
        $resolved = "$($Config._cwd)$resolved"
    }
    if ($isHome -or $isPosix) {
        $resolved = ($resolved -replace '[/\\]', $(if ($isPosix) { '/' } else { $sep }))
    }
    else {
        try {
            $resolved = ([System.IO.Path]::GetFullPath($resolved) -replace '[/\\]', $sep)
        }
        catch {
            $resolved = ($resolved -replace '[/\\]', $sep)
        }
    }
    return $resolved
}

function Resolve-PathPolicy {
    <#
    Decision ladder for a write-target path (redirect target or file-tool path):
      temp(raw) -> system(canonical) -> CWD/editable(canonical) -> loose ->
      normal(editable not enabled) -> default ask.
    Redirect behavior is byte-identical to the old Test-RedirectionTarget 4b-4d
    ladder: same decisions, same reason strings (see $Verb note).
    Returns PSCustomObject @{ Decision; Risk; Reason; Target }
    #>
    param(
        [string]$Path,
        $Config,
        [string]$Verb = 'file write to'
    )
    if (-not $Path -or -not $Path.Trim()) {
        return [PSCustomObject]@{ Decision = 'ask'; Risk = 'medium'; Reason = "$Verb (no target) (modifying)"; Target = 'unknown' }
    }
    $raw = $Path.Trim()
    $resolved = ConvertTo-CanonicalWritePath -TargetPath $raw -Config $Config
    if (-not $resolved) {
        return [PSCustomObject]@{ Decision = 'ask'; Risk = 'medium'; Reason = "$Verb (no target) (modifying)"; Target = 'unknown' }
    }

    # -- temp paths (low risk) — checked on RAW to preserve /tmp, %TEMP%, $env:TEMP forms --
    if ($raw -match '^/tmp/|^/var/tmp/|^%TEMP%|^%TMP%|^\$env:TEMP|^\$env:TMP') {
        # Redirect byte-identity: keep the legacy verb-independent reason for redirects
        $isRedirect = $Verb -in @('append redirect to','output redirect to')
        $reason = if ($isRedirect) { "redirect to temp path ($raw) (low risk)" } else { "$Verb $resolved (temp path) (low risk)" }
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = $reason; Target = $resolved }
    }
    # -- system paths (high risk) — checked on CANONICAL (catches \\?\ and ..) --
    if ($Config -and $resolved -match $Config._systemPathRegex) {
        # Redirect byte-identity: keep the legacy verb-independent reason for redirects
        $isRedirect = $Verb -in @('append redirect to','output redirect to')
        $reason = if ($isRedirect) { "redirect to system path ($resolved) (high risk)" } else { "$Verb $resolved (system path) (high risk)" }
        return [PSCustomObject]@{ Decision = 'ask'; Risk = 'high'; Reason = $reason; Target = $resolved }
    }
    # -- CWD / editable_paths --
    $writableReason = Test-EditableOrCwd -TargetPath $resolved -Config $Config
    if ($writableReason) {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $resolved ($writableReason)"; Target = $resolved }
    }
    # -- strictness fallbacks --
    if ($Config -and $Config.global_modifying_strictness -eq 'loose') {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $resolved (allowed in loose mode)"; Target = $resolved }
    }
    if ($Config -and $Config.global_modifying_strictness -eq 'normal' -and -not $Config._editablePathsEnabled) {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $resolved (allowed in normal mode)"; Target = $resolved }
    }
    return [PSCustomObject]@{ Decision = 'ask'; Risk = 'medium'; Reason = "$Verb $resolved (modifying)"; Target = $resolved }
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

        $policy = Resolve-PathPolicy -Path $targetPath -Config $Config -Verb 'append redirect to'
        $result.Target = $policy.Target
        $result.Risk = $policy.Risk
        $result.Decision = $policy.Decision
        $result.Reason = $policy.Reason
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
            # -- 4b-4d. Temp/system/editable/strictness ladder (shared path policy) --
            else {
                $policy = Resolve-PathPolicy -Path $targetPath -Config $Config -Verb 'output redirect to'
                $result.Target = $policy.Target
                $result.Risk = $policy.Risk
                $result.Decision = $policy.Decision
                $result.Reason = $policy.Reason
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
        [string]$Command,
        [bool]$DrilldownEnabled = $true
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

    # Delegate to the recursive AST walker. $DrilldownEnabled gates the walker's
    # OWN script-drilldown expansion (SITE A/B): the engine's content walk passes
    # $false so a nested 'pwsh -File z' COLLAPSES to its bare path (F11) for the
    # engine's step 9b to expand — otherwise SITE A would double-expand it and
    # claim the HT key, making 9b's re-entry hit the loop-check spuriously.
    return Get-AstCommands -Ast $ast -ParentCommand $null -DrilldownEnabled $DrilldownEnabled
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
        [string]$ParentCommand,
        [bool]$DrilldownEnabled = $true
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
            [string]$Parent,
            [int]$LineNumber = 0,
            [string]$OriginScript = '',
            [string]$DisplayText = '',
            [string]$AtomicReason = '',
            [bool]$DrilldownMarker = $false
        )

        if (-not $CmdText) { return }
        $key = "$($CmdText.Trim())<<|>>$Parent"
        if (-not $SeenMap.ContainsKey($key)) {
            $SeenMap[$key] = $true
            $entry = [PSCustomObject]@{
                CommandText   = $CmdText.Trim()
                Domain        = $Domain
                IsPipeline    = $IsPipeline
                ParentCommand = $Parent
            }
            # Additive origin metadata (script drilldown, 2026-09-20): stored only
            # when present so every pre-existing entry stays byte-identical.
            if ($LineNumber) { $entry | Add-Member -NotePropertyName LineNumber -NotePropertyValue $LineNumber }
            if ($OriginScript) { $entry | Add-Member -NotePropertyName OriginScript -NotePropertyValue $OriginScript }
            # DisplayText (2026-09-20, spec 8.5): a STATEMENT entry re-added through
            # the wrapper loop must keep its '<script:basename> <stmt>' form so STEP 4e
            # copies it onto the SubResult and the LLM prompt + $log.sent show the origin.
            if ($DisplayText) { $entry | Add-Member -NotePropertyName DisplayText -NotePropertyValue $DisplayText }
            # Fail-closed reason (6.4): a drilldown FAILURE entry re-added through
            # the wrapper loop must keep its AtomicReason + DrilldownMarker, else
            # STEP 4e sees a plain unknown path and the 'script file not found' /
            # 'recursive script invocation' reasons are lost.
            if ($AtomicReason) { $entry | Add-Member -NotePropertyName AtomicReason -NotePropertyValue $AtomicReason }
            if ($DrilldownMarker) { $entry | Add-Member -NotePropertyName DrilldownMarker -NotePropertyValue $true }
            $null = $ResultsList.Add($entry)
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
        # $suppressOuter: when the wrapper yields a TERMINAL extraction (pwsh -File),
        # the extracted script path IS the command and the outer 'pwsh -File ...' text
        # is redundant. Suppressing it keeps a standalone trusted-script run at ONE
        # sub-command (below the LLM scope threshold) instead of two. Mirrors the
        # regex fallback, which already drops the wrapper when its text equals a
        # nested command's ParentCommand. Non-terminal wrappers (-Command/-ScriptBlock/
        # bash -c/...) leave this $false so their outer entry is preserved as before.
        $suppressOuter = $false
        if ($commandName -and $commandElements.Count -ge 2) {
            $wrapperResults = Get-AstWrapperInnerCommands `
                -CommandAst $cmd `
                -CommandText $commandText `
                -CommandName $commandName `
                -DrilldownEnabled $DrilldownEnabled

            foreach ($wr in $wrapperResults) {
                if ($wr.IsTerminal) { $suppressOuter = $true }
                $innerCmd = $wr.CommandText
                $innerDom = $wr.Domain
                # Additive origin metadata from the wrapper result (script drilldown,
                # 2026-09-20): a STATEMENT entry carries OriginScript/LineNumber; a
                # pseudo-wrapper / NESTED-WRAPPER / FAILURE entry carries SkipRewalk.
                # Absent on every pre-existing (non-drilldown) wrapper result.
                $wrLine = 0
                if ($wr.PSObject.Properties['LineNumber']) { $wrLine = [int]$wr.LineNumber }
                $wrOrigin = ''
                if ($wr.PSObject.Properties['OriginScript']) { $wrOrigin = "$($wr.OriginScript)" }
                $wrReason = ''
                if ($wr.PSObject.Properties['AtomicReason']) { $wrReason = "$($wr.AtomicReason)" }
                $wrMarker = [bool]($wr.PSObject.Properties['DrilldownMarker'])
                $wrDisplay = ''
                if ($wr.PSObject.Properties['DisplayText']) { $wrDisplay = "$($wr.DisplayText)" }

                # Add the inner command itself (preserving origin metadata so STEP 4e
                # can format script-origin reasons and the LLM scope filter sees it;
                # preserving DisplayText so the LLM prompt + $log.sent show the origin;
                # preserving AtomicReason/DrilldownMarker so a drilldown FAILURE entry
                # keeps its fail-closed reason through the AST path).
                AddResult -ResultsList $results -SeenMap $seenKeys `
                    -CmdText $innerCmd -Domain $innerDom `
                    -IsPipeline $false -Parent $commandText `
                    -LineNumber $wrLine -OriginScript $wrOrigin -DisplayText $wrDisplay `
                    -AtomicReason $wrReason -DrilldownMarker $wrMarker

                # Recurse into the inner command. SkipRewalk (script drilldown)
                # suppresses BOTH branches for engine entries: re-walking a
                # wrapper-shaped text (pseudo-wrapper / NESTED-WRAPPER / FAILURE)
                # would re-enter Expand-ScriptFile and mint spurious 'recursive'
                # entries via the HT loop-check. Plain STATEMENT entries keep the
                # re-walk (harmless same-text skip; lets nested wrappers inside a
                # script still unwrap).
                $skipRewalk = [bool]($wr.PSObject.Properties['SkipRewalk'])
                if (-not $skipRewalk) {
                    if ($innerDom -eq 'powershell') {
                        # -DrilldownEnabled is INHERITED (2026-09-21 fix): the engine's
                        # own content walk passes $false so re-walked texts collapse a
                        # nested 'pwsh -File z' to its bare path instead of EXPANDING it
                        # here. Expanding here would claim z's HT key inside the walker,
                        # and the engine's step 9b would then hit the loop-check and mint
                        # a spurious 'recursive script invocation detected' ask for a
                        # non-recursive script (SD-Allow-CommandWrapsFile).
                        $innerAstCmds = Get-PowerShellCommands -Command $innerCmd -DrilldownEnabled $DrilldownEnabled
                        foreach ($iac in $innerAstCmds) {
                            if ($iac.CommandText -ne $innerCmd) {
                                # Collapsed-invocation guard (2026-09-21 fix): when the
                                # SOURCE entry came from a script (OriginScript), a child
                                # that is itself a BARE '.ps1' invocation is the F11
                                # collapse of a '-File' whose '-Command' wrapper made the
                                # drilldown dispatcher refuse (design 5 GUARD) - i.e. the
                                # -Command branch of the SAME walk already extracted the
                                # inner invocation text, and the ENGINE (step 9a/9b)
                                # expanded or kept it. Re-adding the bare path here
                                # produces a duplicate, unexpandable entry that resolves
                                # unknown => spurious ask (SD-Allow-CommandWrapsFile).
                                if ($wrOrigin -and (Test-DrilldownInvocationText -Text "$($iac.CommandText)")) { continue }
                                # Origin attribution (8.2.3): when the SOURCE entry
                                # carries OriginScript, pass it onto the re-walk
                                # children so an inner command extracted from a script's
                                # wrapper statement keeps its script origin.
                                AddResult -ResultsList $results -SeenMap $seenKeys `
                                    -CmdText $iac.CommandText -Domain $iac.Domain `
                                    -IsPipeline $iac.IsPipeline -Parent $innerCmd `
                                    -OriginScript $wrOrigin
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
        }

        # Add the outer command itself (skipped for terminal -File wrappers, whose
        # extracted script path already represents the command — see $suppressOuter).
        if (-not $suppressOuter) {
            AddResult -ResultsList $results -SeenMap $seenKeys `
                -CmdText $commandText -Domain $domain `
                -IsPipeline $isPipeline -Parent $ParentCommand `
                -LineNumber $cmd.Extent.StartLineNumber
        }
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
        # Skip the ROOT scriptblock: when Get-AstCommands is entered with a
        # ScriptBlockAst (the normal ParseInput shape), FindAll returns that same
        # root node, and recursing into its EndBlock re-walks EVERY command already
        # processed by section 2 above. Pre-drilldown the duplicates were invisible
        # (identical dedup keys); with script drilldown the second walk re-enters
        # Expand-ScriptFile, hits the visited-HT loop-check, and mints a spurious
        # 'recursive' FAILURE entry whose key differs from the successful walk's.
        if ($sb -eq $Ast) { continue }
        if ($sb.EndBlock) {
            # -DrilldownEnabled is INHERITED (2026-09-21 fix): section 2's
            # FindAll(CommandAst, $true) already visits every command inside nested
            # scriptblocks, so this recursion only re-runs the wrapper machinery with
            # identical dedup keys. With drilldown ENABLED on both passes a nested
            # 'pwsh -File z' inside a function body would be EXPANDED twice: the second
            # attempt hits the HT loop-check and mints a spurious 'recursive script
            # invocation detected' ask for a non-recursive script
            # (SD-Allow-FuncBodyNestedFile). Inheriting the caller's flag keeps a
            # single expansion point (engine step 9b) for the engine's content walk.
            $innerResults = Get-AstCommands -Ast $sb.EndBlock -ParentCommand $ParentCommand -DrilldownEnabled $DrilldownEnabled
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
            elseif ($isTopLevel -and ($trimmedStr -match '^(aws|docker|kubectl|helm|terraform|git|npm|yarn|python|node|pwsh|powershell|bash|sh|cmd|ssh|scp|make|go|cargo|dotnet|java|perl|ruby|php)\s')) {
                # Known-prefix branch MUST also require $isTopLevel: otherwise a
                # string ARGUMENT that happens to start with a known binary
                # (e.g. powershell -File trusted.ps1 -Command "python somescript.py",
                # where the python string is a phantom script arg) is wrongly
                # extracted as a standalone command. Genuine 'pwsh -Command "docker run x"'
                # unwrapping is handled by Get-AstWrapperInnerCommands, not here.
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
        [string]$CommandName,
        [bool]$DrilldownEnabled = $true
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
    # pwsh / powershell  —  -Command, -c, -ScriptBlock, -File
    # =========================================================================
    if ($CommandName -match '^(pwsh|powershell)(\.exe)?$') {
        for ($i = 1; $i -lt $elementCount; $i++) {
            $arg = $commandElements[$i]
            $argText = $arg.Extent.Text

            # -File <path>  — TERMINAL. powershell.exe -File consumes the script
            # and passes everything AFTER it to the script as $args. So any later
            # -Command/-ConfigPath/-X belongs to the SCRIPT, not to powershell.exe,
            # and must NOT be unwrapped as powershell's own -Command (otherwise a
            # script arg like '-Command Remove-Item ...' is mis-extracted as a
            # modifying inner command). Extract the script path as the inner
            # command (routed to powershell domain so Test-TrustedProgram can match
            # it) and stop. Mirrors Find-NestedCommands' -File handling.
            if ($argText -match '^-(File|f)$' -and ($i + 1) -lt $elementCount) {
                $nextArg = $commandElements[$i + 1]
                if ($nextArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $filePath = $nextArg.Value
                }
                else {
                    $filePath = $nextArg.Extent.Text
                }
                if ($filePath) {
                    # Script drilldown (2026-09-20): when the gate is armed, open the
                    # script and emit its statements as-if-typed. The dispatcher makes
                    # the gate/runner decision; we OVERRIDE ScriptPath with the parsed
                    # element value (handles quoted-with-spaces paths the regex's (\S+)
                    # arm cannot). $null (feature OFF or path TRUSTED) => today's path
                    # entry, byte-identical. A successful expansion emits a pseudo-wrapper
                    # (IsTerminal, SkipRewalk) FIRST + the statements; a failure emits a
                    # single FAILURE entry (IsTerminal) so the outer is suppressed and the
                    # ask is one line.
                    # $DrilldownEnabled gates this: the engine's OWN content walk passes
                    # $false so a nested 'pwsh -File z' COLLAPSES to its bare path here
                    # (F11) instead of being expanded — the engine's step 9b is the single
                    # expansion point for statements it reads. Expanding here too would
                    # double-expand + claim the HT key, making 9b's re-entry hit the
                    # loop-check spuriously ('recursive' on a non-recursive chain).
                    if ($DrilldownEnabled) {
                    $inv = Find-ScriptRunnerInvocation -SegmentText $CommandText
                    if ($inv) {
                        $expanded = Expand-ScriptFile -ScriptPath $filePath -WrapperText $CommandText
                        if ($null -ne $expanded) {
                            if (@($expanded | Where-Object { $_.PSObject.Properties['OriginScript'] }).Count -gt 0) {
                                # SUCCEEDED: pseudo-wrapper [1] + statements [2..n]. The
                                # pseudo-wrapper carries the full 'pwsh -File ...' text so
                                # it renders as a harmless read_only [N] line; IsTerminal
                                # suppresses the real outer entry (existing mechanism).
                                $null = $results.Add([PSCustomObject]@{
                                    CommandText = $CommandText
                                    Domain      = 'powershell'
                                    IsPipeline  = $false
                                    IsTerminal  = $true
                                    SkipRewalk  = $true
                                })
                                foreach ($e in $expanded) { $null = $results.Add($e) }
                            }
                            else {
                                # FAILED: the engine returned a single FAILURE entry whose
                                # CommandText is the script PATH (6.4). Add IsTerminal so
                                # the outer 'pwsh -File ...' is suppressed (today's shape:
                                # one path entry, now carrying the fail-closed reason).
                                $failEntry = $expanded[0]
                                $failEntry | Add-Member -NotePropertyName IsTerminal -NotePropertyValue $true -Force
                                $null = $results.Add($failEntry)
                            }
                            return $results.ToArray()
                        }
                    }
                    }   # end if ($DrilldownEnabled)
                    # OFF / trusted: today's path entry. IsTerminal marks a -File
                    # extraction: the script path IS the command (powershell.exe -File
                    # consumes everything after it as $args). The caller uses this to
                    # suppress the outer 'pwsh -File ...' wrapper entry so a standalone
                    # trusted-script run counts as ONE sub-command (not two) and stays
                    # below the LLM scope threshold. Reached when drilldown is disabled
                    # (engine content walk), the gate is off, or the path is trusted.
                    $null = $results.Add([PSCustomObject]@{
                        CommandText = $filePath
                        Domain      = 'powershell'
                        IsPipeline  = $false
                        IsTerminal  = $true
                    })
                }
                return $results.ToArray()
            }

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

# F5 (2026-09-19): text-based static-deny probe for the two ASK-REASON sites
# (Classifier Layer-2 atomic path, Resolver Step-3 static fallback). Those sites
# have no AST/reflection - only the written type text and method name - so this
# checks the written key and the bare method name against the compiled deny
# structures. Mirrors the Test-SafeAst (2-pre) gate precedence (deny beats
# allow); used ONLY for reason wording - the decision is ask either way.
function Test-StaticDeniedByText {
    param($Config, [string]$TypeName, [string]$MethodName)
    if (-not $Config) { return $false }
    $writtenKey = "${TypeName}::${MethodName}"
    $denySet = $null
    if (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylist' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $denySet = $Config._dotnetStaticMethodDenylist
    }
    if ($denySet -and $denySet.Count -gt 0 -and
        ($denySet.Contains($writtenKey) -or $denySet.Contains($MethodName))) {
        return $true
    }
    if (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        foreach ($re in @($Config._dotnetStaticMethodDenylistRegex)) {
            if ($null -eq $re) { continue }
            if ($writtenKey -match $re -or $MethodName -match $re) { return $true }
        }
    }
    return $false
}

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
        {$_ -eq 'StatementBlockAst' -or $_ -eq 'NamedBlockAst'} {
            # A block of statements (body of a scriptblock / @(...) / named block).
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
        'ConvertExpressionAst' {
            # A cast is side-effect-free and the type literal is inert ([ref]$x,
            # [byte[]](1,2,3), [int]"5"); judge solely by the child expression.
            return Test-SafeAst -Ast $Ast.Child -AllowedCommands $AllowedCommands -Config $Config
        }
        'MemberExpressionAst' {
            return Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config
        }
        'InvokeMemberExpressionAst' {
            $methodName = $null
            if ($Ast.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $methodName = $Ast.Member.Value
            }
            if (-not $methodName) { return $false }

            $isStaticCall = ($Ast.Expression -is [System.Management.Automation.Language.TypeExpressionAst])

            # (1) Name-only allowlist — INSTANCE-STYLE calls ONLY. A name-only match
            # cannot distinguish $s.Replace (pure) from [System.IO.File]::Replace
            # (file overwrite) since both share the method name; so static calls on a
            # type literal must instead pass the type-qualified list in (2) below.
            $ok = $false
            if (-not $isStaticCall) {
                $allowSet = $null
                if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetMethodAllowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    $allowSet = $Config._dotnetMethodAllowlist
                }
                if ($allowSet -and $allowSet.Contains($methodName)) { $ok = $true }
                # R3 (2026-09-18): exact-set miss -> try the instance regex array
                # against the bare method name as written. Absent/empty key = no
                # regex pass (byte-identical behavior).
                if (-not $ok -and $Config -and
                    (Get-Member -InputObject $Config -Name '_dotnetMethodAllowlistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    foreach ($re in @($Config._dotnetMethodAllowlistRegex)) {
                        if ($null -eq $re) { continue }
                        if ($methodName -match $re) { $ok = $true; break }
                    }
                }
            }

            # (2) Type-qualified STATIC allowlist ([Type]::Method(...)) — checks the
            # entry against the type AS WRITTEN (e.g. regex::Matches) and against its
            # reflected full name (e.g. System.Text.RegularExpressions.Regex::Matches),
            # so either spelling matches one canonical config entry.
            if (-not $ok -and $isStaticCall) {
                $writtenKey = "$($Ast.Expression.TypeName.FullName)::$methodName"
                $refl = $null
                try { $refl = $Ast.Expression.TypeName.GetReflectionType() } catch { $refl = $null }

                # (2-pre) STATIC DENYLIST gate (2026-09-19): checked BEFORE any allow
                # path — deny always wins over exact AND regex allows. Exact entries
                # may be 'Type::Method' OR bare 'Method' (matches the method on ANY
                # type, closing the alias-spelling gap where a type cannot be
                # reflection-resolved and only the written key exists). Regexes are
                # matched against the written key, the reflected full-name key, and
                # the bare method name. Absent/empty keys = no gate (byte-identical
                # behavior to before this change).
                $denySet = $null
                if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    $denySet = $Config._dotnetStaticMethodDenylist
                }
                if ($denySet -and $denySet.Count -gt 0) {
                    if ($denySet.Contains($writtenKey) -or $denySet.Contains($methodName) -or
                        ($refl -and $denySet.Contains("$($refl.FullName)::$methodName"))) { return $false }
                }
                if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    foreach ($re in @($Config._dotnetStaticMethodDenylistRegex)) {
                        if ($null -eq $re) { continue }
                        if ($writtenKey -match $re -or $methodName -match $re -or
                            ($refl -and "$($refl.FullName)::$methodName" -match $re)) { return $false }
                    }
                }

                # (2a) Exact type-qualified set: written key, then reflected key.
                $staticSet = $null
                if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetStaticMethodAllowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    $staticSet = $Config._dotnetStaticMethodAllowlist
                }
                if ($staticSet -and $staticSet.Count -gt 0) {
                    if ($staticSet.Contains($writtenKey)) { $ok = $true }
                    if (-not $ok -and $refl -and $staticSet.Contains("$($refl.FullName)::$methodName")) { $ok = $true }
                }

                # (2b) R3 (2026-09-18): exact-set miss -> try the static regex
                # array against the written key, then the reflected full-name key.
                # Absent/empty key = no regex pass (byte-identical behavior).
                if (-not $ok -and $Config -and
                    (Get-Member -InputObject $Config -Name '_dotnetStaticMethodAllowlistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    foreach ($re in @($Config._dotnetStaticMethodAllowlistRegex)) {
                        if ($null -eq $re) { continue }
                        if ($writtenKey -match $re) { $ok = $true; break }
                        if ($refl -and "$($refl.FullName)::$methodName" -match $re) { $ok = $true; break }
                    }
                }
            }
            if (-not $ok) { return $false }

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
        'IfStatementAst' {
            foreach ($clause in $Ast.Clauses) {
                if (-not (Test-SafeAst -Ast $clause.Item1 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
                if (-not (Test-SafeAst -Ast $clause.Item2 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            if ($Ast.ElseClause -and -not (Test-SafeAst -Ast $Ast.ElseClause -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            return $true
        }
        'ForStatementAst' {
            foreach ($part in @($Ast.Initializer, $Ast.Condition, $Ast.Iterator, $Ast.Body)) {
                if ($null -ne $part -and -not (Test-SafeAst -Ast $part -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ForEachStatementAst' {
            foreach ($part in @($Ast.Variable, $Ast.Condition, $Ast.Body)) {
                if ($null -ne $part -and -not (Test-SafeAst -Ast $part -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        {$_ -eq 'WhileStatementAst' -or $_ -eq 'DoWhileStatementAst' -or $_ -eq 'DoUntilStatementAst'} {
            foreach ($part in @($Ast.Condition, $Ast.Body)) {
                if ($null -ne $part -and -not (Test-SafeAst -Ast $part -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'TryStatementAst' {
            if (-not (Test-SafeAst -Ast $Ast.Body -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            foreach ($catchClause in $Ast.CatchClauses) {
                if (-not (Test-SafeAst -Ast $catchClause.Body -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            if ($Ast.Finally -and -not (Test-SafeAst -Ast $Ast.Finally.Body -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            return $true
        }
        'SwitchStatementAst' {
            if (-not (Test-SafeAst -Ast $Ast.Condition -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            foreach ($clause in $Ast.Clauses) {
                if (-not (Test-SafeAst -Ast $clause.Item1 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
                if (-not (Test-SafeAst -Ast $clause.Item2 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            if ($Ast.Default -and -not (Test-SafeAst -Ast $Ast.Default -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            return $true
        }
        'TrapStatementAst' {
            return Test-SafeAst -Ast $Ast.Body -AllowedCommands $AllowedCommands -Config $Config
        }
        'CommandAst' {
            return ($null -ne $AllowedCommands) -and $AllowedCommands.Contains($Ast.Extent.Text.Trim())
        }
        'CommandExpressionAst' {
            # A bare expression in command position (e.g., 'x' as an assignment
            # RHS, or a hashtable/string as a pipeline element). Safe only when
            # it is not INVOKED (& or .) and carries no redirections.
            if ($Ast.InvocationOperator -eq 'Ampersand' -or $Ast.InvocationOperator -eq 'Dot') { return $false }
            if ($Ast.Redirections -and $Ast.Redirections.Count -gt 0) { return $false }
            return Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config
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
# Test-PowerShellParses
#
# Distinguishes "AST parse SUCCEEDED" from "parse FAILED". Needed because
# Get-PowerShellCommands / Get-PowerShellSafeExpressions both return @() for
# BOTH a syntax error AND a genuinely-zero-cmdlet expression — the two cases
# must diverge for the atomic-unknown classification (2026-09-17 Layer 2):
#   - parse OK + 0 cmdlets + 0 safe exprs => ONE coherent unsafe statement
#     (classify atomically, never regex-split into phantom fragments)
#   - parse FAILED                        => legacy regex fallback
# Returns $false when the parser type is unavailable (fail-closed: caller
# keeps the legacy path).
# =============================================================================

function Test-PowerShellParses {
    param([string]$Command)

    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $false }

    $tokens = $null
    $errors = $null
    try {
        $null = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $false }
    return ($null -eq $errors) -or ($errors.Count -eq 0)
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
