# Classifier.ps1 - Top-Level Classification Pipeline Orchestrator
#
# Purpose:    Implements the sequential gate pipeline (steps 0-4 from the
#             architecture design spec section 1.2). Dot-sources all dependent
#             modules and exports the main Invoke-Classify function plus the
#             helper filter functions Test-ToolNameFilter and Test-TrustedUntrusted.
#
# Input:      $RawInput (PSCustomObject), $IDE (string), $Config (PSCustomObject)
# Output:     Result object with keys: Decision, Reason, ExitCode, IDE, ToolName,
#             Command, SubResults, IsSkipped, IsUnknown
#
# Exported functions:
#   - Invoke-Classify         Main entry - runs the full pipeline
#   - Test-ToolNameFilter     Returns "skip" | "classify" | "unknown" for tool_name
#   - Test-TrustedUntrusted   Runs steps 2-3 (untrusted/trusted pattern checks)

# =============================================================================
# Dot-source dependencies
# =============================================================================
. "$PSScriptRoot\ConfigLoader.ps1"
. "$PSScriptRoot\Parser.ps1"
. "$PSScriptRoot\Resolver.ps1"
. "$PSScriptRoot\HookAdapter.ps1"
. "$PSScriptRoot\Logger.ps1"

# =============================================================================
# Test-ToolNameFilter
#
# STEP 0 of the classification pipeline. Determines whether the tool name
# should be skipped (ignored), classified (intercepted), or is unknown.
#
# Handles legacy config key typos:
#   - "ingore_tool_name" is normalized to "ignore_tool_name"
#   - "intecept_tool_name" is normalized to "intercept_tool_name"
# =============================================================================

function Test-ToolNameFilter {
    param(
        [string]$ToolName,
        [PSCustomObject]$Config
    )

    # -- Check ignore list (handle both "ignore_tool_name" and typo "ingore_tool_name") --
    $ignoreList = $null
    if ($Config.ignore_tool_name) {
        $ignoreList = $Config.ignore_tool_name
    }
    elseif ($Config.ingore_tool_name) {
        $ignoreList = $Config.ingore_tool_name
    }

    if ($ignoreList -and $ToolName -in $ignoreList) {
        return "skip"
    }

    # -- Check intercept list (handle both "intercept_tool_name" and typo "intecept_tool_name") --
    $interceptList = $null
    if ($Config.intercept_tool_name) {
        $interceptList = $Config.intercept_tool_name
    }
    elseif ($Config.intecept_tool_name) {
        $interceptList = $Config.intecept_tool_name
    }

    if ($interceptList -and $ToolName -in $interceptList) {
        return "classify"
    }

    # -- Neither list matched --
    return "unknown"
}

# =============================================================================
# Test-TrustedUntrusted
#
# STEPS 2-3 of the classification pipeline.
#
# STEP 2: Check untrusted_pattern FIRST. If any compiled regex matches the
#         raw command, return an ask result immediately.
# STEP 3: Check trusted_pattern SECOND. If any compiled regex matches the
#         raw command, return an allow result immediately.
#
# Returns a PSCustomObject with Decision, Reason, ExitCode on match,
# or $null if no pattern matched (continue to full classification).
# =============================================================================

function Test-TrustedUntrusted {
    param(
        [string]$Command,
        [PSCustomObject]$Config
    )

    # -------------------------------------------------
    # STEP 2: Check untrusted_pattern FIRST (most restrictive gate)
    # -------------------------------------------------
    if ($Config._compiled.untrusted) {
        foreach ($regex in $Config._compiled.untrusted) {
            if ($regex.IsMatch($Command)) {
                $patternText = $regex.ToString()
                return [PSCustomObject]@{
                    Decision = "ask"
                    Reason   = "matched untrusted pattern: $patternText"
                    ExitCode = 0
                }
            }
        }
    }

    # -------------------------------------------------
    # STEP 3: Check trusted_pattern SECOND
    # -------------------------------------------------
    if ($Config._compiled.trusted) {
        foreach ($regex in $Config._compiled.trusted) {
            if ($regex.IsMatch($Command)) {
                $patternText = $regex.ToString()
                return [PSCustomObject]@{
                    Decision = "allow"
                    Reason   = "matched trusted pattern: $patternText"
                    ExitCode = 0
                }
            }
        }
    }

    # No match - continue to full classification
    return $null
}

# =============================================================================
# Invoke-Classify (THE MAIN FUNCTION)
#
# Runs the full classification pipeline:
#   STEP 0: Tool name filtering
#   STEP 1: Extract command from input
#   STEPS 2-3: Trusted/untrusted gate checks
#   STEP 4: Classification engine (domain detection, split, nested lookup,
#           per-sub-command classification, aggregation)
#
# Every return path produces a consistent result object with ALL standard fields.
# =============================================================================

# =============================================================================
# Repair-ResultProperties (helper)
#
# Validates that a classification result object has all 7 required properties:
# Decision, Reason, ExitCode, IDE, ToolName, Command, SubResults.
# If any are missing, they are added with safe defaults.
# Also ensures IsSkipped and IsUnknown are present for downstream consumers.
# =============================================================================

function Repair-ResultProperties {
    param([PSCustomObject]$Result)

    $defaults = @{
        Decision   = "ask"
        Reason     = "unexpected error: missing result properties"
        ExitCode   = 2
        IDE        = "ClaudeCode"
        ToolName   = "unknown"
        Command    = ""
        SubResults = @()
        IsSkipped  = $false
        IsUnknown  = $false
    }

    foreach ($prop in $defaults.Keys) {
        if (-not (Get-Member -InputObject $Result -Name $prop -MemberType NoteProperty)) {
            $Result | Add-Member -MemberType NoteProperty -Name $prop -Value $defaults[$prop] -Force
        }
    }

    return $Result
}

function Invoke-Classify {
    param(
        [PSCustomObject]$RawInput,
        [string]$IDE,
        [PSCustomObject]$Config
    )

    # =========================================================================
    # Edge case: null RawInput
    # =========================================================================
    if ($null -eq $RawInput) {
        $safeIDE = if ([string]::IsNullOrWhiteSpace($IDE)) { "ClaudeCode" } else { $IDE }
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "ask"
            Reason      = "null input"
            ExitCode    = 2
            IDE         = $safeIDE
            ToolName    = "unknown"
            Command     = ""
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # =========================================================================
    # Edge case: null Config
    # =========================================================================
    if ($null -eq $Config) {
        $safeIDE = if ([string]::IsNullOrWhiteSpace($IDE)) { "ClaudeCode" } else { $IDE }
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "ask"
            Reason      = "no configuration loaded"
            ExitCode    = 2
            IDE         = $safeIDE
            ToolName    = "unknown"
            Command     = ""
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # =========================================================================
    # Edge case: null/empty IDE → default to "ClaudeCode"
    # =========================================================================
    if ([string]::IsNullOrWhiteSpace($IDE)) {
        $IDE = "ClaudeCode"
    }

    # =========================================================================
    # STEP 0: Tool name filtering
    # =========================================================================
    $toolName = $RawInput.tool_name
    if (-not $toolName) {
        $toolName = "unknown"
    }

    $filterResult = Test-ToolNameFilter -ToolName $toolName -Config $Config

    if ($filterResult -eq "skip") {
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "allow"
            Reason      = "ignored tool: $toolName"
            ExitCode    = 0
            IDE         = $IDE
            ToolName    = $toolName
            Command     = ""
            SubResults  = @()
            IsSkipped   = $true
            IsUnknown   = $false
        }))
    }

    if ($filterResult -eq "unknown") {
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "ask"
            Reason      = "unknown tool: $toolName - not in intercept or ignore list"
            ExitCode    = 2
            IDE         = $IDE
            ToolName    = $toolName
            Command     = ""
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $true
        }))
    }

    # =========================================================================
    # STEP 1.5: File-tool path-branch — write targets decided by path policy
    # (system_paths / editable_paths / CWD / strictness), not the command DB.
    # =========================================================================
    $pathMapping = $null
    if (Get-Member -InputObject $Config -Name 'path_tool_mapping' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $pathMapping = $Config.path_tool_mapping
    }
    if ($pathMapping -and ($pathMapping.PSObject.Properties.Name -contains $toolName)) {
        $fieldPath = $pathMapping.$toolName
        # Extract ALL target paths. A mapping segment may end with [*] to
        # enumerate a JSON array (multi_replace_string_in_file ->
        # tool_input.replacements[*].filePath); scalar dot-paths yield one path.
        $writePaths = @(Get-InputFieldValues -RawInput $RawInput -FieldPath $fieldPath)
        if ($writePaths.Count -eq 0) {
            return (Repair-ResultProperties ([PSCustomObject]@{
                Decision    = "ask"
                Reason      = "file-tool path not extractable ($toolName)"
                ExitCode    = 2
                IDE         = $IDE
                ToolName    = $toolName
                Command     = ""
                SubResults  = @()
                IsSkipped   = $false
                IsUnknown   = $false
            }))
        }
        # Worst-case-wins: resolve every path; any ask => ask (same aggregation
        # rule as chained commands, STEP 4f). The reason joins the deciding
        # policy reasons. ExitCode is ALWAYS 0 here: a decision was produced, so
        # the IDE parses the JSON verdict. Exit 2 hard-blocks instead of
        # prompting and is reserved for fatal failures in Hook.ps1.
        $decision     = "allow"
        $blockReasons = [System.Collections.Generic.List[string]]::new()
        $allowReasons = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $writePaths) {
            $policy = Resolve-PathPolicy -Path $p -Config $Config -Verb 'file write to'
            if ($policy.Decision -eq "ask") {
                $decision = "ask"
                $blockReasons.Add($policy.Reason)
            }
            else {
                $allowReasons.Add($policy.Reason)
            }
        }
        $reason = if ($decision -eq "ask") { $blockReasons -join "; " } else { $allowReasons -join "; " }
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = $decision
            Reason      = $reason
            ExitCode    = 0
            IDE         = $IDE
            ToolName    = $toolName
            Command     = ($writePaths -join "; ")
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # =========================================================================
    # STEP 1: Extract command from input
    # =========================================================================
    $command = Get-CommandFromInput -RawInput $RawInput -Config $Config

    if (-not $command -or [string]::IsNullOrWhiteSpace($command)) {
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "ask"
            Reason      = "could not extract command from input"
            ExitCode    = 2
            IDE         = $IDE
            ToolName    = $toolName
            Command     = ""
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # =========================================================================
    # STEPS 2-3: Trusted/untrusted gate checks
    # =========================================================================
    $gateResult = Test-TrustedUntrusted -Command $command -Config $Config

    if ($gateResult) {
        # Add the standard result fields on top of the gate result
        $gateResult | Add-Member -MemberType NoteProperty -Name 'IDE'        -Value $IDE -Force
        $gateResult | Add-Member -MemberType NoteProperty -Name 'ToolName'   -Value $toolName -Force
        $gateResult | Add-Member -MemberType NoteProperty -Name 'SubResults' -Value @() -Force
        $gateResult | Add-Member -MemberType NoteProperty -Name 'Command'    -Value $command -Force
        $gateResult | Add-Member -MemberType NoteProperty -Name 'IsSkipped'  -Value $false -Force
        $gateResult | Add-Member -MemberType NoteProperty -Name 'IsUnknown'  -Value $false -Force
        return (Repair-ResultProperties $gateResult)
    }

    # =========================================================================
    # STEP 4: Classification engine
    # =========================================================================

    # -- 4a: Domain detection (content-based) --
    $domain = Get-CommandDomain -Command $command

    # -- 4b: Split into sub-commands --
    $subCommands = @(Split-Commands -Command $command -Domain $domain)

    # -- 4b-2: PowerShell AST extraction (preferred when available) --
    # When the domain is powershell, use the AST parser to extract actual
    # cmdlet invocations while skipping variable assignments, loop structures,
    # and flow-control scaffolding.  If AST parsing fails, fall back to the
    # regex-based Split-Commands results (already in $subCommands).
    $astCommands = @()
    $safeExpressions = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
        # Zero cmdlet invocations but a successful parse: the line may be pure
        # safe expressions (assignments, hashtables, .NET reads). Certify it so
        # we don't fall back to regex splitting.
        if ($astCommands.Count -eq 0) {
            $safeExpressions = @(Get-PowerShellSafeExpressions -Command $command -Config $Config)
        }
    }

    # -- 4c: Find nested commands (pwsh -Command, ssh, docker exec, kubectl exec) --
    $nestedCommands = @(Find-NestedCommands -Command $command -ParentDomain $domain)

    # -- 4c-2: Extract subshell commands $(command) --
    $subshellCommands = @(Split-SubshellCommands -Command $command)

    # -- 4c-3: Check redirection targets --
    $redirectionResult = Test-RedirectionTarget -Command $command -Config $Config

    # Combine all commands to classify.
    # Prefer AST-extracted commands for PowerShell; fall back to regex split.
    if ($astCommands.Count -gt 0) {
        $allCommands = $astCommands
    }
    elseif ($safeExpressions.Count -gt 0) {
        $allCommands = $safeExpressions
    }
    elseif ($nestedCommands.Count -gt 0) {
        $parentTexts = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($nc in $nestedCommands) {
            if ($nc.ParentCommand) {
                [void]$parentTexts.Add($nc.ParentCommand)
            }
        }
        $filteredSubCommands = @($subCommands | Where-Object {
            -not $parentTexts.Contains($_.CommandText)
        })
        $allCommands = $filteredSubCommands + $nestedCommands + $subshellCommands
    }
    else {
        $allCommands = $subCommands + $nestedCommands + $subshellCommands
    }

    # -- 4d: Edge case - if no commands were extracted, classify raw command directly --
    if ($allCommands.Count -eq 0) {
        $directResult = Resolve-Command -Command $command -Domain $domain -Config $Config

        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = $directResult.Decision
            Reason      = $directResult.Reason
            # Always 0: a decision was produced (see STEP 1.5 note); exit 2 would
            # hard-block instead of prompting.
            ExitCode    = 0
            IDE         = $IDE
            ToolName    = $toolName
            Command     = $command
            SubResults  = @($directResult)
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # -- 4e: Classify each sub-command --
    $subResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $blockingCommands = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sc in $allCommands) {
        $r = Resolve-Command -Command $sc.CommandText -Domain $sc.Domain -Config $Config
        $subResults.Add($r)

        if ($r.Decision -eq "ask") {
            $blockingCommands.Add($r)
        }
    }

    # -- 4e-2: Integrate redirection target classification --
    if ($redirectionResult.HasRedirection) {
        $redirSubResult = [PSCustomObject]@{
            Command        = $command
            Decision       = $redirectionResult.Decision
            Reason         = $redirectionResult.Reason
            MatchedPattern = "redirection-target"
            Risk           = $redirectionResult.Risk
        }
        $subResults.Add($redirSubResult)

        if ($redirectionResult.Decision -eq "ask") {
            $blockingCommands.Add($redirSubResult)
        }
    }

    # =========================================================================
    # STEP 4f: Aggregate
    # =========================================================================

    if ($blockingCommands.Count -gt 0) {
        # -------------------------------------------------
        # AST-as-arbiter gate: only when EVERY blocker is the unknown-command
        # fallback. Known modifying matches and redirection blocks (both have
        # a MatchedPattern) bypass arbitration entirely.
        # -------------------------------------------------
        $knownBlockers = @($blockingCommands | Where-Object { $_.MatchedPattern })
        if ($knownBlockers.Count -eq 0) {
            $arbiterResult = Invoke-PowerShellArbitration -Command $command -Config $Config
            if ($arbiterResult.Conclusive) {
                return (Repair-ResultProperties ([PSCustomObject]@{
                    Decision    = "allow"
                    Reason      = "read-only (PowerShell AST arbitration)"
                    ExitCode    = 0
                    IDE         = $IDE
                    ToolName    = $toolName
                    Command     = $command
                    SubResults  = $subResults.ToArray()
                    IsSkipped   = $false
                    IsUnknown   = $false
                }))
            }
        }

        # Build reason string listing ALL blocking commands
        $blockingReasons = [System.Collections.Generic.List[string]]::new()
        foreach ($bc in $blockingCommands) {
            if ($bc.MatchedPattern -and $bc.Risk) {
                $blockingReasons.Add("$($bc.MatchedPattern) ($($bc.Risk))")
            }
            elseif ($bc.MatchedPattern) {
                $blockingReasons.Add($bc.MatchedPattern)
            }
            else {
                $blockingReasons.Add($bc.Reason)
            }
        }
        $reason = ($blockingReasons -join ", ")

        # Add pipeline context with richer description
        # Collect pipeline segments from Split-Commands results
        $pipelineParts = [System.Collections.Generic.List[string]]::new()
        foreach ($sc in $subCommands) {
            if ($sc.IsPipeline) {
                $pipelineParts.Add($sc.CommandText)
            }
        }

        # Fallback: if no pipeline parts from sub-commands, check raw command
        # for pipe characters (handles linux/dos domain pipelines)
        if ($pipelineParts.Count -eq 0 -and $command -match '\|') {
            $rawParts = @($command -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($rawParts.Count -gt 1) {
                foreach ($rp in $rawParts) {
                    $pipelineParts.Add($rp)
                }
            }
        }

        if ($pipelineParts.Count -gt 1) {
            # Build a rich pipeline chain that includes the modifying command
            $pipelineChain = $pipelineParts -join " -> "
            $reason += ". Pipeline: $pipelineChain"
        }

        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = "ask"
            Reason      = $reason
            ExitCode    = 0
            IDE         = $IDE
            ToolName    = $toolName
            Command     = $command
            SubResults  = $subResults.ToArray()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }

    # All commands are read-only - allow
    return (Repair-ResultProperties ([PSCustomObject]@{
        Decision    = "allow"
        Reason      = "read-only"
        ExitCode    = 0
        IDE         = $IDE
        ToolName    = $toolName
        Command     = $command
        SubResults  = $subResults.ToArray()
        IsSkipped   = $false
        IsUnknown   = $false
    }))
}

# =============================================================================
# Invoke-PowerShellArbitration  (AST-as-arbiter)
#
# Activated ONLY when the primary pipeline's final decision is ask AND every
# blocking sub-result is the unknown-command fallback (MatchedPattern = null).
# Re-parses the whole original line with the PowerShell AST and returns
# CONCLUSIVE-ALLOW only when every top-level statement is fully accounted for:
#   - every CommandAst resolves to a KNOWN allow (directly, or as a wrapper
#     whose extracted inner commands all allow), and
#   - every remaining node passes Test-SafeAst with those allowed commands.
# Any gap => NOT conclusive => caller keeps the original ask unchanged.
# =============================================================================

function Invoke-PowerShellArbitration {
    param(
        [string]$Command,
        [PSCustomObject]$Config
    )

    $result = [PSCustomObject]@{ Conclusive = $false }

    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $result }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $result }
    if ($errors -and $errors.Count -gt 0) { return $result }
    if (-not $ast -or -not $ast.EndBlock) { return $result }
    if ($ast.BeginBlock -and $ast.BeginBlock.Statements.Count -gt 0) { return $result }
    if ($ast.ProcessBlock -and $ast.ProcessBlock.Statements.Count -gt 0) { return $result }

    $statements = $ast.EndBlock.Statements
    if ($statements.Count -eq 0) { return $result }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Pass 1: every embedded command must resolve ALLOW.
    foreach ($stmt in $statements) {
        $cmdAsts = $stmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmdAsts) {
            $verdict = Resolve-AsArbiter -CommandAst $c -Config $Config -Depth 0
            if ($verdict -ne 'ALLOW') { return $result }
            [void]$allowed.Add($c.Extent.Text.Trim())
        }
    }

    # Pass 2: every statement must certify as a safe expression (commands in
    # $allowed are treated as pre-approved leaves).
    foreach ($stmt in $statements) {
        if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $allowed -Config $Config)) { return $result }
    }

    $result.Conclusive = $true
    return $result
}

function Resolve-AsArbiter {
    param(
        $CommandAst,
        [PSCustomObject]$Config,
        [int]$Depth
    )

    if ($Depth -gt 5) { return 'NO' }

    # Call-operator scriptblock: recurse into the scriptblock body.
    if (($CommandAst.InvocationOperator -eq 'Ampersand' -or $CommandAst.InvocationOperator -eq 'Dot') -and
        $CommandAst.CommandElements.Count -eq 1 -and
        $CommandAst.CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $sb = $CommandAst.CommandElements[0].ScriptBlock
        if (-not $sb -or -not $sb.EndBlock) { return 'NO' }
        $innerAllowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($istmt in $sb.EndBlock.Statements) {
            $icmds = $istmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($ic in $icmds) {
                if ((Resolve-AsArbiter -CommandAst $ic -Config $Config -Depth ($Depth + 1)) -ne 'ALLOW') { return 'NO' }
                [void]$innerAllowed.Add($ic.Extent.Text.Trim())
            }
        }
        foreach ($istmt in $sb.EndBlock.Statements) {
            if (-not (Test-SafeAst -Ast $istmt -AllowedCommands $innerAllowed -Config $Config)) { return 'NO' }
        }
        return 'ALLOW'
    }

    $text = $CommandAst.Extent.Text.Trim()
    if (-not $text) { return 'NO' }
    $dom = Get-CommandDomain -Command $text

    # Wrapper / nested extraction FIRST: if this command wraps inner commands
    # (pwsh -Command, ssh, bash -c, docker exec, ...), the inner commands are
    # what matters — the wrapper is explained by its children (mirrors the
    # existing parent-filter semantics). The wrapper's own resolution is NOT
    # sufficient: "pwsh" is read_only precisely because "inner commands are
    # classified separately" — so we must classify them here.
    # NOTE: use the regex-based Find-NestedCommands only — it has the full
    # value-taking-flag table (e.g., ssh -W/-i/-o consume the next token).
    # The AST wrapper helper skips flags but not their values, which would
    # misread "ssh -W internal:80 user@bastion" as having a remote command.
    $nested = @(Find-NestedCommands -Command $text -ParentDomain $dom)
    if ($nested.Count -gt 0) {
        foreach ($n in $nested) {
            $nr = Resolve-Command -Command $n.CommandText -Domain $n.Domain -Config $Config
            if ($nr.Decision -eq 'allow') { continue }
            # Try finer decomposition of the nested text.
            $leaves = @(Split-Commands -Command $n.CommandText -Domain $n.Domain)
            $leafOk = $true
            foreach ($leaf in $leaves) {
                $lr = Resolve-Command -Command $leaf.CommandText -Domain $leaf.Domain -Config $Config
                if ($lr.Decision -ne 'allow') { $leafOk = $false; break }
            }
            if (-not $leafOk) { return 'NO' }
        }
        return 'ALLOW'
    }

    # Not a wrapper: plain resolution must be allow.
    $r = Resolve-Command -Command $text -Domain $dom -Config $Config
    if ($r.Decision -eq 'allow') { return 'ALLOW' }
    return 'NO'
}
