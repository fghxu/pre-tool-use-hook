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

# =============================================================================
# Get-ToolGatePaths (helper)
#
# Extracts candidate write-target paths for a gated/ignored tool:
#   1. path_tool_mapping exact dot-path (incl. [*] array form) via
#      Get-InputFieldValues.
#   2. Best-effort patch-TEXT scan for apply_patch / edit_files: absolute-path
#      tokens (Windows drive / POSIX-rooted) pulled out of the patch string.
# Returns an array of raw path strings (may be empty).
# =============================================================================

function Get-ToolGatePaths {
    param(
        [string]$ToolName,
        [PSCustomObject]$RawInput,
        [PSCustomObject]$Config
    )

    $paths = [System.Collections.Generic.List[string]]::new()

    # 1) exact mapping
    if (Get-Member -InputObject $Config -Name 'path_tool_mapping' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $ptm = $Config.path_tool_mapping
        if ($ptm -and ($ptm.PSObject.Properties.Name -contains $ToolName)) {
            foreach ($p in @(Get-InputFieldValues -RawInput $RawInput -FieldPath $ptm.$ToolName)) {
                if ($p) { $paths.Add([string]$p) }
            }
        }
    }

    # 2) best-effort patch-text scan (paths live in patch text, not a JSON field)
    if ($paths.Count -eq 0 -and $ToolName -in @('apply_patch', 'edit_files')) {
        $text = $null
        if ($RawInput -and $RawInput.tool_input) {
            foreach ($propName in @('patch','content','text','input')) {
                $v = $RawInput.tool_input.$propName
                if ($v -is [string] -and $v.Trim()) { $text = $v; break }
            }
            if (-not $text) {
                # any string field is fair game for a patch payload
                foreach ($prop in $RawInput.tool_input.PSObject.Properties) {
                    if ($prop.Value -is [string] -and $prop.Value -match '(?i)(\*\*\*|[A-Za-z]:[\\/]|^|\s)/?[A-Za-z0-9_.-]') { $text = [string]$prop.Value; break }
                }
            }
        }
        if ($text) {
            foreach ($m in [regex]::Matches($text, '[A-Za-z]:[\\/][^\s"''<>|]+')) { $paths.Add($m.Value) }
            foreach ($m in [regex]::Matches($text, '(?m)(?<=^|[\s"''])/(?:etc|var|usr|boot|sys|proc|opt|tmp|home)[^\s"''<>|]*')) { $paths.Add($m.Value) }
        }
    }

    return $paths.ToArray()
}

# =============================================================================
# Test-SystemPathsOnly (helper)
#
# The ABSOLUTE rule: any candidate path resolving into system_paths -> ask.
# Returns a result PSCustomObject (Decision=ask) on the first system path, or
# $null when no candidate is a system path.
# =============================================================================

function Test-SystemPathsOnly {
    param(
        [string[]]$Paths,
        [PSCustomObject]$Config,
        [string]$ToolName
    )
    foreach ($p in $Paths) {
        $resolved = ConvertTo-CanonicalWritePath -TargetPath ([string]$p) -Config $Config
        if ($resolved -and $Config._systemPathRegex -and ($resolved -match $Config._systemPathRegex)) {
            return [PSCustomObject]@{
                Decision = "ask"
                Reason   = "gated/ignored tool $ToolName targets system path: $resolved (system_paths is absolute - no tool may write here without approval)"
                ExitCode = 0
            }
        }
    }
    return $null
}

# =============================================================================
# Resolve-ToolGate
#
# Decides a tool in strictness_gated_tool_name. Effective mode = strict if
# EITHER global_modifying_strictness OR tool_name_modifying_strictness is
# strict, else the tool value (default normal). Global loose never loosens.
#
#   strict -> full path policy: system/foreign ask; editable+CWD allow;
#             unextractable path asks (fail-closed)
#   normal -> system_paths ask; all other paths allow; unextractable allows
#   loose  -> system_paths ask; all other paths allow; unextractable allows
#
# Returns a PSCustomObject @{ Action = 'skip' | 'ask' | 'allow'; Reason }
#   'skip'  -> allow, IsSkipped (gate passed, not classified further)
#   'allow' -> allow, NOT skipped (strict-mode editable/CWD allow)
#   'ask'   -> ask result
# =============================================================================

function Resolve-ToolGate {
    param(
        [string]$ToolName,
        [PSCustomObject]$RawInput,
        [PSCustomObject]$Config
    )

    $global = if ($Config.global_modifying_strictness) { $Config.global_modifying_strictness } else { 'normal' }
    $tool   = if ($Config.tool_name_modifying_strictness) { $Config.tool_name_modifying_strictness } else { 'normal' }
    $mode   = if ($global -eq 'strict' -or $tool -eq 'strict') { 'strict' } else { $tool }

    $paths = @(Get-ToolGatePaths -ToolName $ToolName -RawInput $RawInput -Config $Config)

    # ABSOLUTE: system_paths ask in every mode.
    $sysHit = Test-SystemPathsOnly -Paths $paths -Config $Config -ToolName $ToolName
    if ($sysHit) { return [PSCustomObject]@{ Action = 'ask'; Reason = $sysHit.Reason } }

    if ($paths.Count -eq 0) {
        if ($mode -eq 'strict') {
            return [PSCustomObject]@{ Action = 'ask'; Reason = "gated tool ${ToolName}: no write-target path extractable (strict mode fails closed)" }
        }
        return [PSCustomObject]@{ Action = 'skip'; Reason = "gated tool: $ToolName (no path; $mode mode)" }
    }

    if ($mode -eq 'strict') {
        # full path policy: editable/CWD allow; anything else (foreign) ask.
        foreach ($p in $paths) {
            $resolved = ConvertTo-CanonicalWritePath -TargetPath ([string]$p) -Config $Config
            $writable = $null
            if ($resolved) { $writable = Test-EditableOrCwd -TargetPath $resolved -Config $Config }
            if (-not $writable) {
                return [PSCustomObject]@{ Action = 'ask'; Reason = "gated tool $ToolName targets non-editable path (strict mode): $resolved" }
            }
        }
        return [PSCustomObject]@{ Action = 'allow'; Reason = "gated tool $ToolName (strict mode, editable/CWD target)" }
    }

    # normal/loose: non-system paths pass.
    return [PSCustomObject]@{ Action = 'skip'; Reason = "gated tool: $ToolName ($mode mode, non-system target)" }
}

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

    # -- Check strictness-gated list (strictness_gated_tool_name) --
    # v2 (2026-08-26): returns "gated" so Invoke-Classify can run the path-aware
    # gate (Resolve-ToolGate) with the raw payload. system_paths is absolute.
    if ($Config.strictness_gated_tool_name -and $ToolName -in $Config.strictness_gated_tool_name) {
        return "gated"
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

    # -- Ignored tool: skip, UNLESS a payload path resolves into system_paths --
    # -- (the ABSOLUTE rule applies to ignored tools too).                   --
    if ($filterResult -eq "skip") {
        $igPaths = @(Get-ToolGatePaths -ToolName $toolName -RawInput $RawInput -Config $Config)
        $igSys = Test-SystemPathsOnly -Paths $igPaths -Config $Config -ToolName $toolName
        if ($igSys) {
            return (Repair-ResultProperties ([PSCustomObject]@{
                Decision    = "ask"
                Reason      = $igSys.Reason
                ExitCode    = 0
                IDE         = $IDE
                ToolName    = $toolName
                Command     = ($igPaths -join "; ")
                SubResults  = @()
                IsSkipped   = $false
                IsUnknown   = $false
            }))
        }
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

    # -- Gated tool: path-aware gate (strictness_gated_tool_name). system_paths --
    # -- is absolute; effective mode from global + tool_name_modifying_strictness. --
    if ($filterResult -eq "gated") {
        $gate = Resolve-ToolGate -ToolName $toolName -RawInput $RawInput -Config $Config
        $gPaths = @(Get-ToolGatePaths -ToolName $toolName -RawInput $RawInput -Config $Config)
        # Gated tools are decided ENTIRELY by the gate (skip / ask / strict-allow);
        # they never fall through to the command tiers or the generic path branch.
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = $(if ($gate.Action -eq 'ask') { "ask" } else { "allow" })
            Reason      = $gate.Reason
            ExitCode    = 0
            IDE         = $IDE
            ToolName    = $toolName
            Command     = ($gPaths -join "; ")
            SubResults  = @()
            IsSkipped   = ($gate.Action -eq 'skip')
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
    # Run per sub-command SEGMENT, not on the full command string. The wrapper
    # patterns inside Find-NestedCommands are anchored (^pwsh..., ^ssh..., ...),
    # so calling it on a compound command ('cd x; pwsh -File y.ps1') never
    # matches — the string starts with 'cd'. That left the whole 'pwsh -File'
    # segment to the generic pwsh read_only pattern: a trusted script lost its
    # trusted_program tier (LLM could veto a trusted run) and an UNTRUSTED
    # script was allowed instead of asked (2026-09-17 production incident).
    # Per-segment, the anchored patterns match the wrapper segment itself. For
    # single-segment commands this is identical to the old full-string call.
    # Each nested entry's ParentCommand is the SEGMENT text, so the combination
    # step below suppresses exactly that segment (not the whole compound).
    $nestedCommands = @()
    foreach ($seg in $subCommands) {
        $nestedCommands += @(Find-NestedCommands -Command $seg.CommandText -ParentDomain $seg.Domain)
    }

    # -- 4c-2: Extract subshell commands $(command) --
    $subshellCommands = @(Split-SubshellCommands -Command $command)

    # -- 4c-3: Check redirection targets --
    $redirectionResult = Test-RedirectionTarget -Command $command -Config $Config

    # Combine all commands to classify.
    # Prefer AST-extracted commands for PowerShell; fall back to regex split.
    if ($astCommands.Count -gt 0) {
        # AST walker already decomposed all wrappers/scriptblocks natively
        # (Get-AstWrapperInnerCommands + ScriptBlockAst recursion). Appending
        # Find-NestedCommands results would add phantom "commands" from data
        # expressions like [pscustomobject]@{...} that the AST correctly
        # identified as non-commands (2026-09-15: production log showed
        # unclassified [pscustomobject] fragments forcing unnecessary ask).
        $allCommands = $astCommands + $subshellCommands
    }
    elseif ($safeExpressions.Count -gt 0) {
        $allCommands = $safeExpressions + $nestedCommands + $subshellCommands
    }
    # -- 4b-3: Atomic unknown (2026-09-17 Layer 2) --
    # Zero cmdlets AND zero safe expressions, but the AST parse SUCCEEDED:
    # the input is one coherent unsafe expression (unlisted .NET method call,
    # property set, unlisted static). Do NOT regex-split it — Split-Commands
    # misreads ':' inside string interpolation and manufactures phantom
    # sub-command fragments (incident 2026-09-17 MiobuildHeaders: 2 garbage
    # fragments instead of the one real statement). Classify the WHOLE
    # statement as ONE atomic unknown. Nested/subshell commands are still
    # extracted and unioned (edge case 2/3 in the design doc). Parse FAILURE
    # (e.g. a bash for-loop) falls through to the legacy regex path below.
    # NOTE: call Get-PowerShellCommands DIRECTLY here — do NOT rely on
    # $astCommands, which is only populated for powershell-domain inputs. For
    # every non-powershell command (git, curl, docker, while-loops...) it stays
    # @(), so "$astCommands.Count -eq 0" would be true for ALL of them and —
    # since most shell text parses as valid PowerShell syntax — this branch
    # would wrongly turn real commands into atomic unknowns. Parsing the text
    # directly yields the TRUE cmdlet count for any domain: a real command has
    # >=1 CommandAst and is excluded; only pure expressions (0 cmdlets) pass.
    elseif ((@(Get-PowerShellCommands -Command $command)).Count -eq 0 -and
            $safeExpressions.Count -eq 0 -and
            (Test-PowerShellParses -Command $command)) {
        # Unanchored: the static call may sit behind an assignment LHS
        # ($x = [Type]::Method(...)). Safe here because this branch only runs
        # with ZERO cmdlets, so no leading command can be misread as a type.
        # Truthfulness guard: only name it "not on allowlist" when the matched
        # Type::Method is genuinely absent from the static allowlist — an
        # allowlisted static inside a partially-unsafe expression would
        # otherwise get a misleading message (decision stays ask either way).
        $staticSet = $null
        if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetStaticMethodAllowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
            $staticSet = $Config._dotnetStaticMethodAllowlist
        }
        # R3 (2026-09-18): static regex array for the miss-then-regex fallback.
        $staticRegexes = @()
        if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetStaticMethodAllowlistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
            $staticRegexes = @($Config._dotnetStaticMethodAllowlistRegex)
        }
        $isUnlistedStatic = $false
        $isDeniedStatic = $false
        $atomType = $null
        $atomMethod = $null
        if ($command -match '\[([^\]]+)\]\s*::\s*([A-Za-z_]\w*)\s*\(') {
            # Capture $Matches into locals IMMEDIATELY: the allow-regex loop
            # below re-runs -match on $writtenKey and CLOBBERS $Matches (rows
            # without capture groups, e.g. the Class-C families, leave
            # $Matches[1] null -> method call on null crashed - caught by the
            # F5 red/green run 2026-09-19).
            $atomType = $Matches[1].Trim()
            $atomMethod = $Matches[2]
            $writtenKey = "$atomType::$atomMethod"
            $onExact = $staticSet -and $staticSet.Contains($writtenKey)
            # Regex fallback: an allowlisted-by-regex static is "on the allowlist"
            # for truthfulness purposes (avoids a misleading 'not on allowlist'
            # message). Decision stays ask either way.
            $onRegex = $false
            if (-not $onExact) {
                foreach ($re in $staticRegexes) {
                    if ($null -eq $re) { continue }
                    if ($writtenKey -match $re) { $onRegex = $true; break }
                }
            }
            $isUnlistedStatic = (-not $onExact) -and (-not $onRegex)
            # F5 (2026-09-19): a DENIED static outranks both wordings - name the
            # denylist so the ask reason says WHY (deny beats allow by design).
            # Decision stays ask either way; wording only.
            $isDeniedStatic = Test-StaticDeniedByText -Config $Config -TypeName $atomType -MethodName $atomMethod
        }
        if ($isDeniedStatic) {
            $atomicReason = "static method denied by denylist: [$atomType]::$atomMethod (see safe_expressions.dotnet_static_method_denylist)"
        }
        elseif ($isUnlistedStatic) {
            $atomicReason = "static method not on allowlist: [$atomType]::$atomMethod (see safe_expressions.dotnet_static_method_allowlist)"
        }
        else {
            $truncatedAtomic = $command.Substring(0, [Math]::Min(80, $command.Length))
            $atomicReason = "unsafe PowerShell expression (fail-closed): $truncatedAtomic"
        }
        # One synthetic entry carrying the pre-computed reason. It stays in
        # $allCommands (so count >= 1, no 4d early-return) and STEP 4e honors
        # its AtomicReason instead of re-resolving (Resolve-Command would emit
        # the generic 'unknown command' fallback). Nested/subshell commands are
        # still unioned so a wrapped modifying inner is not lost.
        $atomicEntry = [PSCustomObject]@{
            CommandText   = $command
            Domain        = 'powershell'
            IsPipeline    = $false
            ParentCommand = $null
            AtomicReason  = $atomicReason
        }
        $allCommands = @($atomicEntry) + $nestedCommands + $subshellCommands
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

    # R2 (2026-09-18): a sub-command that executes on a REMOTE host must not be
    # auto-allowed by this machine's editable_paths/CWD/temp policy. If the command
    # contains a remote wrapper, treat its sub-commands as remote so Resolve-Command's
    # Step 0g-delete skips them (pre-change ask behavior preserved). Remote wrappers:
    # ssh / docker exec / kubectl exec / Invoke-Command -ComputerName. Local wrappers
    # (pwsh -Command, bash -c, cmd /c, plain Invoke-Command) run on this machine and
    # are NOT remote. Command-level (not per-sub-command) because the AST path drops
    # ParentCommand; this is fail-closed — it can only over-ask a rare mixed local+
    # remote compound, never under-ask (a security hole).
    $remoteWrapperRe = '(?:\bssh\s|\bdocker\s+exec\b|\bkubectl\s+exec\b|\bInvoke-Command\s+.*?-ComputerName\b)'

    foreach ($sc in $allCommands) {
        $isRemote = [bool]($command -match $remoteWrapperRe)
        # Atomic-unknown marker (2026-09-17 Layer 2): the reason was computed
        # at the combination step for the WHOLE statement. Re-resolving would
        # emit the generic 'unknown command' fallback, so use it verbatim.
        if ($sc.PSObject.Properties['AtomicReason']) {
            $r = [PSCustomObject]@{
                Command        = $sc.CommandText
                Decision       = 'ask'
                Reason         = $sc.AtomicReason
                MatchedPattern = $null
                Risk           = 'unknown'
                Tier           = 'unclassified'
            }
        }
        else {
            $r = Resolve-Command -Command $sc.CommandText -Domain $sc.Domain -Config $Config -IsRemote $isRemote
        }

        # R2 tier stamp (§4.3, merge-relevant): if this segment is an allow with a
        # redirect whose target is editable/CWD/temp, stamp Tier='editable_path' so
        # the LLM merge can suppress vetoes on it (INV-2 for writes). Never overwrite
        # an existing MEANINGFUL tier (e.g. 'trusted_program', 'safe_expr'). A plain
        # 'read_only' tier is NOT meaningful here — a read-only cmdlet that also writes
        # to an editable/temp target via redirect IS path-policy-governed, so upgrade it
        # to 'editable_path' (this is what makes INV-2-for-writes work: the segment the
        # LLM's flagged index points at must carry the suppressible tier).
        $curTier = "$($r.Tier)"
        if ($r.Decision -eq 'allow' -and ($curTier -eq '' -or $curTier -eq 'read_only')) {
            $segRedir = Test-RedirectionTarget -Command $sc.CommandText -Config $Config
            if ($segRedir.HasRedirection -and $segRedir.Decision -eq 'allow') {
                $rr = "$($segRedir.Reason)"
                if ($rr -match 'temp path|under current directory|editable path') {
                    $r | Add-Member -MemberType NoteProperty -Name 'Tier' -Value 'editable_path' -Force
                }
            }
        }

        $subResults.Add($r)

        if ($r.Decision -eq "ask") {
            $blockingCommands.Add($r)
        }
    }

    # -- 4e-2: Integrate redirection target classification --
    if ($redirectionResult.HasRedirection) {
        # R2 tier stamp (§4.3, display/logging only): this entry is EXCLUDED from the
        # LLM's indexed list (scope filter drops MatchedPattern='redirection-target'),
        # so the stamp changes nothing in the merge — it makes logs, subresult-tier
        # assertions, and check_blindspot tier display truthful. ask -> modifying;
        # allow with a real path-write target (temp/CWD/editable) -> editable_path.
        $redirTier = ''
        if ($redirectionResult.Decision -eq 'ask') {
            $redirTier = 'modifying'
        } elseif ($redirectionResult.Decision -eq 'allow') {
            $rr = "$($redirectionResult.Reason)"
            if ($rr -match 'temp path|under current directory|editable path') {
                $redirTier = 'editable_path'
            }
        }
        $redirSubResult = [PSCustomObject]@{
            Command        = $command
            Decision       = $redirectionResult.Decision
            Reason         = $redirectionResult.Reason
            MatchedPattern = "redirection-target"
            Risk           = $redirectionResult.Risk
            Tier           = $redirTier
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
                # Tier stamp-back (G5 fix): arbitration just proved every
                # statement safe, but the SubResults emitted BEFORE it ran
                # still carry the unknown-command fallback's empty tier
                # (e.g. the Invoke-Command -ScriptBlock { ... } wrapper).
                # Stamp the arbiter-resolved tiers onto those entries so
                # downstream consumers (the LLM second-opinion merge) see the
                # truthful tier. Existing non-empty tiers are never touched;
                # empty stamps are skipped.
                if ($arbiterResult.TierMap) {
                    foreach ($sr in $subResults) {
                        if ($sr.MatchedPattern -eq 'redirection-target') { continue }
                        $hasTierProp = $null -ne $sr.PSObject.Properties['Tier']
                        if ($hasTierProp -and -not [string]::IsNullOrEmpty($sr.Tier)) { continue }
                        $key = "$($sr.Command)".Trim()
                        $stamped = $arbiterResult.TierMap[$key]
                        if ($stamped) {
                            if ($hasTierProp) { $sr.Tier = $stamped }
                            else { $sr | Add-Member -NotePropertyName Tier -NotePropertyValue $stamped }
                        }
                    }
                }
                # Tier upgrade (2026-09-17): Conclusive=true means Test-SafeAst
                # passed on EVERY statement — they are provably read-only. The
                # TierMap above only covers entries with a CommandAst node; pure
                # expressions (atomic unknowns, subshell fragments) have no map
                # entry and still carry the pre-arbitration 'unclassified' tier.
                # Upgrade those to 'read_only' so downstream consumers (LLM merge,
                # check_blindspot, log display) see the truthful tier. Only
                # 'unclassified' is touched — never strictness_gated, read_only,
                # safe_expr, or other meaningful tiers.
                foreach ($sr in $subResults) {
                    if ($sr.MatchedPattern -eq 'redirection-target') { continue }
                    if ($sr.Tier -eq 'unclassified') { $sr.Tier = 'read_only' }
                }
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
# On conclusive allow, TierMap carries the arbiter-resolved tier per command
# extent text (worst-tier-wins across a wrapper's inner commands) so the
# caller can stamp truthful tiers back onto the pre-arbitration sub-results.
# =============================================================================

function Invoke-PowerShellArbitration {
    param(
        [string]$Command,
        [PSCustomObject]$Config
    )

    $result = [PSCustomObject]@{ Conclusive = $false; TierMap = $null }

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
    $tierMap = @{}

    # Pass 1: every embedded command must resolve ALLOW (Resolve-AsArbiter
    # returns the resolved TIER on success, 'NO' on failure). Tiers are
    # collected per command-extent so the caller can stamp them back onto
    # the sub-results the pipeline emitted BEFORE arbitration ran (wrappers
    # like Invoke-Command -ScriptBlock { ... } are otherwise left with the
    # unknown-command fallback's empty tier).
    foreach ($stmt in $statements) {
        $cmdAsts = $stmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmdAsts) {
            $tier = Resolve-AsArbiter -CommandAst $c -Config $Config -Depth 0
            if ($tier -eq 'NO') { return $result }
            [void]$allowed.Add($c.Extent.Text.Trim())
            $key = $c.Extent.Text.Trim()
            if ($tierMap.ContainsKey($key)) { $tierMap[$key] = Merge-WorstTier $tierMap[$key] $tier }
            else { $tierMap[$key] = $tier }
        }
    }

    # Pass 2: every statement must certify as a safe expression (commands in
    # $allowed are treated as pre-approved leaves).
    foreach ($stmt in $statements) {
        if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $allowed -Config $Config)) { return $result }
    }

    $result.Conclusive = $true
    $result.TierMap = $tierMap
    return $result
}

# Merge-WorstTier: strictness_gated outranks read_only outranks '' — the
# tier of a wrapper is the tier of its most user-accepted-risky inner
# command (gated is the bucket the user already accepts at normal
# strictness, so a wrapper over gated + read-only inners stamps gated).
function Merge-WorstTier {
    param([string]$A, [string]$B)
    if (-not $A) { $A = '' }
    if (-not $B) { $B = '' }
    $rank = @{ 'strictness_gated' = 2; 'read_only' = 1; '' = 0 }
    $ra = 0; $rb = 0
    if ($rank.ContainsKey($A)) { $ra = $rank[$A] }
    if ($rank.ContainsKey($B)) { $rb = $rank[$B] }
    if ($rb -gt $ra) { return $B }
    return $A
}

function Resolve-AsArbiter {
    <#
    .SYNOPSIS
        Arbiter-side resolution of one CommandAst. Returns the resolved TIER
        string ('strictness_gated' / 'read_only' / '' when the allow carries
        no tier) on success, 'NO' when the command cannot be shown safe.
        For wrappers the tier is Merge-WorstTier over the inner commands.
    #>
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
        $worst = ''
        foreach ($istmt in $sb.EndBlock.Statements) {
            $icmds = $istmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($ic in $icmds) {
                $itier = Resolve-AsArbiter -CommandAst $ic -Config $Config -Depth ($Depth + 1)
                if ($itier -eq 'NO') { return 'NO' }
                $worst = Merge-WorstTier $worst $itier
                [void]$innerAllowed.Add($ic.Extent.Text.Trim())
            }
        }
        foreach ($istmt in $sb.EndBlock.Statements) {
            if (-not (Test-SafeAst -Ast $istmt -AllowedCommands $innerAllowed -Config $Config)) { return 'NO' }
        }
        return $worst
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
        $worst = ''
        foreach ($n in $nested) {
            $nr = Resolve-Command -Command $n.CommandText -Domain $n.Domain -Config $Config
            if ($nr.Decision -eq 'allow') { $worst = Merge-WorstTier $worst $nr.Tier; continue }
            # Try finer decomposition of the nested text.
            $leaves = @(Split-Commands -Command $n.CommandText -Domain $n.Domain)
            $leafOk = $true
            $leafWorst = ''
            foreach ($leaf in $leaves) {
                $lr = Resolve-Command -Command $leaf.CommandText -Domain $leaf.Domain -Config $Config
                if ($lr.Decision -ne 'allow') { $leafOk = $false; break }
                $leafWorst = Merge-WorstTier $leafWorst $lr.Tier
            }
            if (-not $leafOk) { return 'NO' }
            $worst = Merge-WorstTier $worst $leafWorst
        }
        return $worst
    }

    # Not a wrapper: plain resolution must be allow.
    $r = Resolve-Command -Command $text -Domain $dom -Config $Config
    if ($r.Decision -eq 'allow') { return "$($r.Tier)" }
    return 'NO'
}
