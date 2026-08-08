<#
.SYNOPSIS
    Loads, validates, and pre-compiles the config.json configuration file.

.DESCRIPTION
    ConfigLoader.ps1 provides two functions:
    - Load-Config: Main entry point that reads the JSON config file, validates it,
      pre-compiles all regex patterns, and returns the validated config object.
    - Test-ConfigSchema: Validates the structure of the parsed config object,
      normalizes misspelled keys, and verifies all regex patterns compile.

    The config.json file may contain legacy typos (intecept_tool_name,
    ingore_tool_name) which are normalized to the correct spellings in the output.
#>

function Test-ConfigSchema {
    <#
    .SYNOPSIS
        Validates the structure and contents of a parsed configuration object.

    .DESCRIPTION
        Checks that all required keys are present, validates regex patterns compile,
        handles legacy typo keys by normalizing them, and ensures the commands
        section contains at least one domain with read_only or modifying entries.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    # Validate "version" exists and is a string
    if (-not (Get-Member -InputObject $Config -Name 'version' -MemberType NoteProperty)) {
        throw "Configuration validation failed: 'version' key is required"
    }
    if ($Config.version -isnot [string]) {
        throw "Configuration validation failed: 'version' must be a string"
    }

    # Validate "commands" exists and has at least one domain key
    if (-not (Get-Member -InputObject $Config -Name 'commands' -MemberType NoteProperty)) {
        throw "Configuration validation failed: 'commands' key is required"
    }
    if ($Config.commands -isnot [PSCustomObject] -and $Config.commands -isnot [hashtable]) {
        throw "Configuration validation failed: 'commands' must be an object with domain keys"
    }
    $commandKeys = $Config.commands.PSObject.Properties.Name
    if ($commandKeys.Count -eq 0) {
        throw "Configuration validation failed: 'commands' must have at least one domain key"
    }

    # Validate "trusted_pattern" exists and is an array
    if (-not (Get-Member -InputObject $Config -Name 'trusted_pattern' -MemberType NoteProperty)) {
        throw "Configuration validation failed: 'trusted_pattern' key is required"
    }
    if ($Config.trusted_pattern -isnot [array]) {
        throw "Configuration validation failed: 'trusted_pattern' must be an array"
    }

    # Validate "untrusted_pattern" exists and is an array
    if (-not (Get-Member -InputObject $Config -Name 'untrusted_pattern' -MemberType NoteProperty)) {
        throw "Configuration validation failed: 'untrusted_pattern' key is required"
    }
    if ($Config.untrusted_pattern -isnot [array]) {
        throw "Configuration validation failed: 'untrusted_pattern' must be an array"
    }

    # Validate optional "trusted_programs" (decomposed-level program allowlist).
    # Unlike trusted_pattern/untrusted_pattern this key is OPTIONAL; if absent it
    # is treated as an empty list. If present it must be an array of strings
    # (full path, partial path, or bare program name).
    $hasTrustedPrograms = Get-Member -InputObject $Config -Name 'trusted_programs' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasTrustedPrograms -and $Config.trusted_programs -isnot [array]) {
        throw "Configuration validation failed: 'trusted_programs' must be an array"
    }

    # Validate optional "llm_second_opinion" block (second-opinion LLM cross-check).
    # OPTIONAL: absent = feature off. When present it is validated even with
    # enabled=false so bad values surface at load time, not at first use.
    $hasLlm = Get-Member -InputObject $Config -Name 'llm_second_opinion' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasLlm) {
        $llm = $Config.llm_second_opinion
        if ($llm -isnot [PSCustomObject] -and $llm -isnot [hashtable]) {
            throw "Configuration validation failed: 'llm_second_opinion' must be an object"
        }
        if ((Get-Member -InputObject $llm -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.enabled -isnot [bool]) {
            throw "Configuration validation failed: 'llm_second_opinion.enabled' must be a boolean"
        }
        if ((Get-Member -InputObject $llm -Name 'attributed_verdicts' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.attributed_verdicts -isnot [bool]) {
            throw "Configuration validation failed: 'llm_second_opinion.attributed_verdicts' must be a boolean"
        }
        if ((Get-Member -InputObject $llm -Name 'json_mode' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.json_mode -isnot [bool]) {
            throw "Configuration validation failed: 'llm_second_opinion.json_mode' must be a boolean"
        }
        if ((Get-Member -InputObject $llm -Name 'level' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.level -notin @('all', 'complex_commands', 'complex_remote')) {
            throw "Configuration validation failed: 'llm_second_opinion.level' must be 'all', 'complex_commands', or 'complex_remote', got '$($llm.level)'"
        }
        $intFields = @('complex_min_subcommands', 'timeout_ms', 'max_tokens')
        foreach ($f in $intFields) {
            if (Get-Member -InputObject $llm -Name $f -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                $v = 0
                if (-not [int]::TryParse("$($llm.$f)", [ref]$v) -or $v -lt 1) {
                    throw "Configuration validation failed: 'llm_second_opinion.$f' must be an integer >= 1, got '$($llm.$f)'"
                }
            }
        }
        if (Get-Member -InputObject $llm -Name 'temperature' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $tv = 0.0
            if (-not [double]::TryParse("$($llm.temperature)", [ref]$tv) -or $tv -lt 0.0 -or $tv -gt 2.0) {
                throw "Configuration validation failed: 'llm_second_opinion.temperature' must be a number between 0.0 and 2.0, got '$($llm.temperature)'"
            }
        }
        if ((Get-Member -InputObject $llm -Name 'api_key' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $null -ne $llm.api_key -and $llm.api_key -isnot [string]) {
            throw "Configuration validation failed: 'llm_second_opinion.api_key' must be a string"
        }
        if (Get-Member -InputObject $llm -Name 'remote_indicators' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            if ($llm.remote_indicators -isnot [array]) {
                throw "Configuration validation failed: 'llm_second_opinion.remote_indicators' must be an array of regex strings"
            }
            foreach ($p in $llm.remote_indicators) {
                try { $null = [regex]::new($p.ToString()) }
                catch { throw "Invalid regex in llm_second_opinion.remote_indicators: $p" }
            }
        }
        # Validate optional "safetynet" sub-block (LLM second-opinion for
        # local-unknown tiers). OPTIONAL: absent = safetynet off. When present
        # it is validated even when the parent feature is disabled, so bad
        # values surface at load time. SAFETNET NEVER CHANGES THE DECISION -
        # it only enriches the reason text the human sees at approval time.
        if (Get-Member -InputObject $llm -Name 'safetynet' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $sn = $llm.safetynet
            if ($sn -isnot [PSCustomObject] -and $sn -isnot [hashtable]) {
                throw "Configuration validation failed: 'llm_second_opinion.safetynet' must be an object"
            }
            if ((Get-Member -InputObject $sn -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
                $sn.enabled -isnot [bool]) {
                throw "Configuration validation failed: 'llm_second_opinion.safetynet.enabled' must be a boolean"
            }
            if ((Get-Member -InputObject $sn -Name 'tiers' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
                $sn.tiers -isnot [array]) {
                throw "Configuration validation failed: 'llm_second_opinion.safetynet.tiers' must be an array of tier strings"
            }
        }
        # base_uri and model are required only when the feature is enabled
        if ($llm.enabled -eq $true) {
            if (-not (Get-Member -InputObject $llm -Name 'base_uri' -MemberType NoteProperty) -or [string]::IsNullOrWhiteSpace($llm.base_uri)) {
                throw "Configuration validation failed: 'llm_second_opinion.base_uri' is required when enabled is true"
            }
            if (-not (Get-Member -InputObject $llm -Name 'model' -MemberType NoteProperty) -or [string]::IsNullOrWhiteSpace($llm.model)) {
                throw "Configuration validation failed: 'llm_second_opinion.model' is required when enabled is true"
            }
        }
    }

    # Normalize intercept_tool_name (handle typo "intecept_tool_name")
    $hasIntercept = Get-Member -InputObject $Config -Name 'intercept_tool_name' -MemberType NoteProperty
    $hasInterceptTypo = Get-Member -InputObject $Config -Name 'intecept_tool_name' -MemberType NoteProperty
    if ($hasIntercept) {
        if ($Config.intercept_tool_name -isnot [array]) {
            throw "Configuration validation failed: 'intercept_tool_name' must be an array"
        }
    }
    elseif ($hasInterceptTypo) {
        if ($Config.intecept_tool_name -isnot [array]) {
            throw "Configuration validation failed: 'intecept_tool_name' must be an array"
        }
        # Normalize: copy typo value to correct key
        $Config | Add-Member -MemberType NoteProperty -Name 'intercept_tool_name' -Value $Config.intecept_tool_name -Force
    }
    else {
        throw "Configuration validation failed: 'intercept_tool_name' key is required"
    }

    # Normalize ignore_tool_name (handle typo "ingore_tool_name")
    $hasIgnore = Get-Member -InputObject $Config -Name 'ignore_tool_name' -MemberType NoteProperty
    $hasIgnoreTypo = Get-Member -InputObject $Config -Name 'ingore_tool_name' -MemberType NoteProperty
    if ($hasIgnore) {
        if ($Config.ignore_tool_name -isnot [array]) {
            throw "Configuration validation failed: 'ignore_tool_name' must be an array"
        }
    }
    elseif ($hasIgnoreTypo) {
        if ($Config.ingore_tool_name -isnot [array]) {
            throw "Configuration validation failed: 'ingore_tool_name' must be an array"
        }
        # Normalize: copy typo value to correct key
        $Config | Add-Member -MemberType NoteProperty -Name 'ignore_tool_name' -Value $Config.ingore_tool_name -Force
    }
    else {
        throw "Configuration validation failed: 'ignore_tool_name' key is required"
    }

    # Validate "tool_name_mapping" exists and is non-empty
    if (-not (Get-Member -InputObject $Config -Name 'tool_name_mapping' -MemberType NoteProperty)) {
        throw "Configuration validation failed: 'tool_name_mapping' key is required"
    }
    if ($Config.tool_name_mapping -isnot [PSCustomObject] -and $Config.tool_name_mapping -isnot [hashtable]) {
        throw "Configuration validation failed: 'tool_name_mapping' must be an object"
    }
    $mappingKeys = $Config.tool_name_mapping.PSObject.Properties.Name
    if ($mappingKeys.Count -eq 0) {
        throw "Configuration validation failed: 'tool_name_mapping' must be non-empty"
    }

    # Default path_tool_mapping if missing. Maps tool_name -> dot-path of the
    # payload field holding a FILE PATH (not a command). Tools listed here are
    # decided by Resolve-PathPolicy (system_paths/editable_paths/CWD/strictness)
    # instead of the command classifier.
    if (-not (Get-Member -InputObject $Config -Name 'path_tool_mapping' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'path_tool_mapping' -Value ([PSCustomObject]@{}) -Force
    }
    if ($Config.path_tool_mapping -isnot [PSCustomObject]) {
        throw "Configuration validation failed: 'path_tool_mapping' must be an object"
    }

    # Default log_file_path to empty string if missing
    if (-not (Get-Member -InputObject $Config -Name 'log_file_path' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'log_file_path' -Value '' -Force
    }

    # Reject the legacy global key (renamed to global_modifying_strictness 2026-07-28):
    # fail-closed rather than silently default a stale 'strict' config to 'normal' (fail-open).
    # NOTE: the per-domain commands.<domain>.modifying_strictness key is UNCHANGED.
    if (Get-Member -InputObject $Config -Name 'modifying_strictness' -MemberType NoteProperty) {
        throw "Configuration validation failed: the global 'modifying_strictness' key was renamed to 'global_modifying_strictness' - please rename it (per-domain commands.<domain>.modifying_strictness keeps its name)"
    }
    # Default global_modifying_strictness to "normal" if missing, validate value
    if (-not (Get-Member -InputObject $Config -Name 'global_modifying_strictness' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'global_modifying_strictness' -Value 'normal' -Force
    }
    else {
        if ($Config.global_modifying_strictness -notin @('normal', 'strict', 'loose')) {
            throw "Configuration validation failed: 'global_modifying_strictness' must be 'normal', 'strict', or 'loose', got '$($Config.global_modifying_strictness)'"
        }
    }

    # Default editable_paths if missing, compile into _editablePathRegex (string;
    # used with PowerShell's case-insensitive -match, like _systemPathRegex).
    # Structure mirrors system_paths {linux, windows}, BUT both sides are treated
    # as raw regex (unlike system_paths, linux is NOT escaped to a literal) so
    # users can use regex on linux paths too. _editablePathsEnabled is true only
    # when at least one pattern is declared (opt-in).
    if (-not (Get-Member -InputObject $Config -Name 'editable_paths' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'editable_paths' -Value ([PSCustomObject]@{linux=@();windows=@()}) -Force
    }
    $editablePatterns = @()
    if ($Config.editable_paths.linux) {
        foreach ($p in $Config.editable_paths.linux) { $editablePatterns += $p.ToString() }
    }
    if ($Config.editable_paths.windows) {
        foreach ($p in $Config.editable_paths.windows) { $editablePatterns += $p.ToString() }
    }
    $editableRegex = if ($editablePatterns.Count -gt 0) { '^(' + ($editablePatterns -join '|') + ')' } else { '^\b$' }
    $Config | Add-Member -MemberType NoteProperty -Name '_editablePathRegex' -Value $editableRegex -Force
    $Config | Add-Member -MemberType NoteProperty -Name '_editablePathsEnabled' -Value ([bool]($editablePatterns.Count -gt 0)) -Force
    try { $null = [regex]::new($editableRegex) } catch { throw "Invalid editable_paths regex: $editableRegex" }

    # Capture the current working directory. CWD (and everything under it) is
    # always editable, in every strictness mode. Stored with unified separators
    # and a trailing separator; _cwdNorm is the lowercased form for prefix
    # comparison.
    $script:_cwdSep = [System.IO.Path]::DirectorySeparatorChar
    $script:_cwdUnified = ((Get-Location).Path -replace '[/\\]', $script:_cwdSep)
    if (-not $script:_cwdUnified.EndsWith($script:_cwdSep)) { $script:_cwdUnified += $script:_cwdSep }
    $Config | Add-Member -MemberType NoteProperty -Name '_cwd' -Value $script:_cwdUnified -Force
    $Config | Add-Member -MemberType NoteProperty -Name '_cwdNorm' -Value $script:_cwdUnified.ToLowerInvariant() -Force

    # Default system_paths if missing, compile into _systemPathRegex
    if (-not (Get-Member -InputObject $Config -Name 'system_paths' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'system_paths' -Value ([PSCustomObject]@{linux=@();windows=@()}) -Force
    }
    $sysPaths = $Config.system_paths
    $linuxPatterns = @()
    if ($sysPaths.linux) {
        foreach ($p in $sysPaths.linux) { $linuxPatterns += [regex]::Escape($p.ToString()) }
    }
    $winPatterns = @()
    if ($sysPaths.windows) {
        foreach ($p in $sysPaths.windows) { $winPatterns += $p.ToString() }
    }
    $allPatterns = $linuxPatterns + $winPatterns
    $sysRegex = if ($allPatterns.Count -gt 0) { '^(' + ($allPatterns -join '|') + ')' } else { '^\b$' }
    $Config | Add-Member -MemberType NoteProperty -Name '_systemPathRegex' -Value $sysRegex -Force
    try { $null = [regex]::new($sysRegex) } catch { throw "Invalid system_paths regex: $sysRegex" }

    # safe_expressions: .NET method allowlist for the safe-expression certifier.
    # Optional; defaults to a built-in conservative list when absent.
    $defaultDotNetMethods = @(
        'readalltext','readalllines','readlines','openread',
        'substring','split','replace','tostring','toupper','tolower',
        'trim','trimstart','trimend','contains','startswith','endswith',
        'indexof','lastindexof','padleft','padright',
        'max','min','abs','round','floor','ceiling','sqrt','pow',
        'compare','equals','gethashcode','gettype'
    )
    $methodNames = $defaultDotNetMethods
    $hasSafeExprs = Get-Member -InputObject $Config -Name 'safe_expressions' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasSafeExprs -and $Config.safe_expressions -and
        (Get-Member -InputObject $Config.safe_expressions -Name 'dotnet_method_allowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
        $Config.safe_expressions.dotnet_method_allowlist) {
        $methodNames = @($Config.safe_expressions.dotnet_method_allowlist | ForEach-Object { "$_".ToLowerInvariant() })
    }
    $methodSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $methodNames) { [void]$methodSet.Add($m) }
    $Config | Add-Member -MemberType NoteProperty -Name '_dotnetMethodAllowlist' -Value $methodSet -Force

    # safe_expressions: type-qualified STATIC .NET method allowlist
    # ('TypeName::Method') for [Type]::Method(...) calls in expression position.
    # Optional; defaults to an EMPTY set (fail-closed) when absent — unlike
    # dotnet_method_allowlist above, there is no built-in default list.
    $staticSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hasStaticExprs = Get-Member -InputObject $Config -Name 'safe_expressions' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasStaticExprs -and $Config.safe_expressions -and
        (Get-Member -InputObject $Config.safe_expressions -Name 'dotnet_static_method_allowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
        $Config.safe_expressions.dotnet_static_method_allowlist) {
        if ($Config.safe_expressions.dotnet_static_method_allowlist -isnot [array]) {
            throw "Configuration validation failed: 'safe_expressions.dotnet_static_method_allowlist' must be an array"
        }
        foreach ($m in $Config.safe_expressions.dotnet_static_method_allowlist) {
            [void]$staticSet.Add(("$m").ToLowerInvariant())
        }
    }
    $Config | Add-Member -MemberType NoteProperty -Name '_dotnetStaticMethodAllowlist' -Value $staticSet -Force

    # Validate regex patterns in trusted_pattern compile successfully
    foreach ($pattern in $Config.trusted_pattern) {
        try {
            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        catch {
            throw "Invalid regex pattern in config: $pattern"
        }
    }

    # Validate regex patterns in untrusted_pattern compile successfully
    foreach ($pattern in $Config.untrusted_pattern) {
        try {
            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        catch {
            throw "Invalid regex pattern in config: $pattern"
        }
    }

    # Validate commands section: each domain must have read_only or modifying array
    foreach ($domainKey in $commandKeys) {
        $domain = $Config.commands.$domainKey
        $hasReadOnly = Get-Member -InputObject $domain -Name 'read_only' -MemberType NoteProperty
        $hasModifying = Get-Member -InputObject $domain -Name 'modifying' -MemberType NoteProperty

        if (-not $hasReadOnly -and -not $hasModifying) {
            throw "Configuration validation failed: domain '$domainKey' must have 'read_only' and/or 'modifying' entries"
        }

        # Validate read_only entry patterns compile
        if ($hasReadOnly) {
            foreach ($entry in $domain.read_only) {
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        try {
                            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
                        }
                        catch {
                            throw "Invalid regex pattern in config (domain '$domainKey', read_only entry '$($entry.name)'): $pattern"
                        }
                    }
                }
            }
        }

        # Validate modifying entry patterns compile
        if ($hasModifying) {
            foreach ($entry in $domain.modifying) {
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        try {
                            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
                        }
                        catch {
                            throw "Invalid regex pattern in config (domain '$domainKey', modifying entry '$($entry.name)'): $pattern"
                        }
                    }
                }
            }
        }

        # Validate optional per-domain modifying_strictness (guard: only consulted
        # when the global modifying_strictness is 'normal' — see Get-EffectiveStrictness)
        if (Get-Member -InputObject $domain -Name 'modifying_strictness' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            if ($domain.modifying_strictness -notin @('strict', 'normal', 'loose')) {
                throw "Configuration validation failed: domain '$domainKey' modifying_strictness must be 'strict', 'normal', or 'loose', got '$($domain.modifying_strictness)'"
            }
        }

        # Validate strictness_gated entry patterns compile (optional middle tier)
        $hasGated = Get-Member -InputObject $domain -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($hasGated) {
            foreach ($entry in $domain.strictness_gated) {
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        try {
                            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
                        }
                        catch {
                            throw "Invalid regex pattern in config (domain '$domainKey', strictness_gated entry '$($entry.name)'): $pattern"
                        }
                    }
                }
            }
        }

        # Validate parameter_commands (optional, per-domain)
        $hasParamCmds = Get-Member -InputObject $domain -Name 'parameter_commands' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($hasParamCmds) {
            foreach ($cmdName in $domain.parameter_commands.PSObject.Properties.Name) {
                $pEntry = $domain.parameter_commands.$cmdName
                if (-not (Get-Member -InputObject $pEntry -Name 'rules' -MemberType NoteProperty) -or -not $pEntry.rules) {
                    throw "Configuration validation failed: parameter_commands entry '$cmdName' (domain '$domainKey') must have a non-empty 'rules' array"
                }
                if (-not (Get-Member -InputObject $pEntry -Name 'default' -MemberType NoteProperty) -or $pEntry.default -notin @('read-only','modifying')) {
                    throw "Configuration validation failed: parameter_commands entry '$cmdName' (domain '$domainKey') must have 'default' of 'read-only' or 'modifying'"
                }
                foreach ($rule in $pEntry.rules) {
                    if (-not (Get-Member -InputObject $rule -Name 'param' -MemberType NoteProperty)) {
                        throw "Configuration validation failed: rule in '$cmdName' (domain '$domainKey') missing 'param'"
                    }
                    if (-not (Get-Member -InputObject $rule -Name 'match' -MemberType NoteProperty) -or $rule.match -notin @('present','values')) {
                        throw "Configuration validation failed: rule in '$cmdName' (domain '$domainKey') must have 'match' of 'present' or 'values'"
                    }
                    if ($rule.match -eq 'values') {
                        if (-not (Get-Member -InputObject $rule -Name 'values' -MemberType NoteProperty) -or -not $rule.values) {
                            throw "Configuration validation failed: values-rule in '$cmdName' (domain '$domainKey') must have a non-empty 'values' array"
                        }
                    }
                    if (-not (Get-Member -InputObject $rule -Name 'decision' -MemberType NoteProperty) -or $rule.decision -notin @('read-only','modifying')) {
                        throw "Configuration validation failed: rule in '$cmdName' (domain '$domainKey') must have 'decision' of 'read-only' or 'modifying'"
                    }
                }
            }
        }
    }
}

function Load-Config {
    <#
    .SYNOPSIS
        Loads, validates, and pre-compiles the config.json configuration file.

    .DESCRIPTION
        Loads the JSON configuration file at the specified path, validates its structure
        and contents via Test-ConfigSchema, pre-compiles all regex patterns for runtime
        performance, and returns the validated, compiled configuration object.

        Compiled patterns are stored under a top-level _compiled key:
        - _compiled.trusted: array of compiled [regex] from trusted_pattern
        - _compiled.untrusted: array of compiled [regex] from untrusted_pattern
        - Each domain entry in commands receives a _compiledPatterns array of [regex]
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # 1. Check file exists
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    # 2. Read file and parse JSON
    $jsonContent = $null
    try {
        $jsonContent = Get-Content -Path $Path -Raw -ErrorAction Stop
    }
    catch {
        throw "Configuration file not found: $Path"
    }

    $config = $null
    try {
        $config = $jsonContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON in configuration file: $($_.Exception.Message)"
    }

    # 3. Validate structure via Test-ConfigSchema
    Test-ConfigSchema -Config $config

    # 4. Pre-compile ALL regex patterns for performance

    # Create _compiled container on the config object
    $compiledContainer = [PSCustomObject]@{}
    $config | Add-Member -MemberType NoteProperty -Name '_compiled' -Value $compiledContainer -Force

    # Compile trusted_pattern (Singleline so . matches \n for multi-line commands)
    $compiledTrusted = @()
    foreach ($pattern in $config.trusted_pattern) {
        $compiledTrusted += [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'trusted' -Value $compiledTrusted -Force

    # Compile untrusted_pattern (Singleline so . matches \n for multi-line commands)
    $compiledUntrusted = @()
    foreach ($pattern in $config.untrusted_pattern) {
        $compiledUntrusted += [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Compiled)
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'untrusted' -Value $compiledUntrusted -Force

    # Compile trusted_programs (optional): normalized (lowercased, '/' -> '\')
    # program path/name specs stored as a plain string array for O(n) lookup by
    # Test-TrustedProgram. Empty array when the key is absent. These are NOT
    # regexes (unlike trusted/untrusted above) - they are path/name specs.
    $compiledTrustedPrograms = @()
    if (Get-Member -InputObject $config -Name 'trusted_programs' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        foreach ($p in $config.trusted_programs) {
            $compiledTrustedPrograms += ($p.ToString().ToLowerInvariant() -replace '/', '\')
        }
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'trustedPrograms' -Value $compiledTrustedPrograms -Force

    # Compile llm_second_opinion (optional): normalized runtime block.
    # $null when the block is absent (feature off; every consumer null-checks).
    $llmCompiled = $null
    if (Get-Member -InputObject $config -Name 'llm_second_opinion' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $llmRaw = $config.llm_second_opinion
        $defaultIndicators = @(
            '\baws\b', '\bkubectl\b', '\bhelm\b', '\bterraform\b',
            '\bssh\b', '\bscp\b', '\bsftp\b',
            '\bdocker\b', '\bcurl\b', '\bwget\b',
            '\bInvoke-RestMethod\b', '\birm\b',
            '\bInvoke-WebRequest\b', '\biwr\b',
            '\bEnter-PSSession\b', '\bNew-PSSession\b',
            'Invoke-Command.*-ComputerName'
        )
        $indicatorSrc = $defaultIndicators
        if ((Get-Member -InputObject $llmRaw -Name 'remote_indicators' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $llmRaw.remote_indicators) {
            $indicatorSrc = @($llmRaw.remote_indicators | ForEach-Object { $_.ToString() })
        }
        $indicatorRegexes = @()
        foreach ($p in $indicatorSrc) {
            $indicatorRegexes += [regex]::new($p, [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        # Pre-compute each field (PS 5.1-safe; hashtable values cannot hold if-statements)
        $llmEnabled = $false
        if (Get-Member -InputObject $llmRaw -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmEnabled = [bool]$llmRaw.enabled }
        $llmLevel = 'complex_remote'
        if (Get-Member -InputObject $llmRaw -Name 'level' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmLevel = "$($llmRaw.level)" }
        $llmBaseUri = ''
        if (Get-Member -InputObject $llmRaw -Name 'base_uri' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmBaseUri = "$($llmRaw.base_uri)" }
        $llmModel = ''
        if (Get-Member -InputObject $llmRaw -Name 'model' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmModel = "$($llmRaw.model)" }
        $llmApiKey = ''
        if (Get-Member -InputObject $llmRaw -Name 'api_key' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmApiKey = "$($llmRaw.api_key)" }
        $llmTimeoutMs = 12000
        if (Get-Member -InputObject $llmRaw -Name 'timeout_ms' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmTimeoutMs = [int]$llmRaw.timeout_ms }
        $llmTemperature = 0.0
        if (Get-Member -InputObject $llmRaw -Name 'temperature' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmTemperature = [double]$llmRaw.temperature }
        $llmMaxTokens = 16
        if (Get-Member -InputObject $llmRaw -Name 'max_tokens' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmMaxTokens = [int]$llmRaw.max_tokens }
        $llmMinSubs = 2
        if (Get-Member -InputObject $llmRaw -Name 'complex_min_subcommands' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmMinSubs = [int]$llmRaw.complex_min_subcommands }
        $llmAttributed = $true
        if (Get-Member -InputObject $llmRaw -Name 'attributed_verdicts' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmAttributed = [bool]$llmRaw.attributed_verdicts }
        $llmJsonMode = $false
        if (Get-Member -InputObject $llmRaw -Name 'json_mode' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmJsonMode = [bool]$llmRaw.json_mode }
        # safetynet sub-block (optional). Compiled into a sibling Safetynet
        # object the scope engine consults after the normal scope gate fails.
        # Default tiers = all local-unknown tiers. SAFETYNET NEVER CHANGES THE
        # DECISION; it only enriches the reason text.
        $snEnabled = $false
        $snTiers = @('unclassified', 'unregistered_verb', 'unregistered_static', 'unregistered', 'unknown_domain')
        if (Get-Member -InputObject $llmRaw -Name 'safetynet' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $snRaw = $llmRaw.safetynet
            if (Get-Member -InputObject $snRaw -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $snEnabled = [bool]$snRaw.enabled }
            if ((Get-Member -InputObject $snRaw -Name 'tiers' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $snRaw.tiers) {
                $snTiers = @($snRaw.tiers | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
            }
        }
        $snCompiled = [PSCustomObject]@{ Enabled = $snEnabled; Tiers = $snTiers }
        $llmCompiled = [PSCustomObject]@{
            Enabled               = $llmEnabled
            Level                 = $llmLevel
            BaseUri               = $llmBaseUri
            Model                 = $llmModel
            ApiKey                = $llmApiKey
            TimeoutMs             = $llmTimeoutMs
            Temperature           = $llmTemperature
            MaxTokens             = $llmMaxTokens
            ComplexMinSubcommands = $llmMinSubs
            AttributedVerdicts      = $llmAttributed
            JsonMode                = $llmJsonMode
            RemoteIndicators      = $indicatorRegexes
            Safetynet             = $snCompiled
        }
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'llmSecondOpinion' -Value $llmCompiled -Force

    # Compile patterns for each domain's read_only and modifying entries
    $commandKeys = $config.commands.PSObject.Properties.Name
    foreach ($domainKey in $commandKeys) {
        $domain = $config.commands.$domainKey

        # Regex options are DOMAIN-AWARE: PowerShell is a case-insensitive
        # language (cmdlet names 'format-table' == 'Format-Table'), so its
        # patterns compile case-insensitive. Linux/DOS/POSIX-style tools are
        # genuinely case-sensitive ('cat' != 'CAT'), so they keep the default
        # case-sensitive match to avoid false allows. (2026-08-03 user report:
        # lowercase 'convertfrom-json' missed the case-sensitive 'ConvertFrom-Json'
        # read_only pattern and fell through to 'unregistered PowerShell verb'.)
        $isPowerShell = ($domainKey -ieq 'PowerShell')
        $regexOptions = if ($isPowerShell) {
            [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        } else {
            [System.Text.RegularExpressions.RegexOptions]::Compiled
        }

        # Compile read_only entry patterns
        if (Get-Member -InputObject $domain -Name 'read_only' -MemberType NoteProperty) {
            foreach ($entry in $domain.read_only) {
                $compiledPatterns = @()
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        # Auto-anchor with ^ to prevent substring false positives
                        # e.g., "sc *" must not match "sc" inside "-Descending"
                        # Also convert glob-style * to regex .* (accept after first literal token)
                        $anchoredPattern = if ($pattern.StartsWith('^')) { $pattern } else { '^' + $pattern }
                        # Convert glob * to .* only when * follows a non-special character
                        # to avoid breaking patterns that already use proper regex like .*
                        $anchoredPattern = $anchoredPattern -replace '(?<![.*\\])\*(?!\?|\*|\{)', '.*'
                        $compiledPatterns += [regex]::new($anchoredPattern, $regexOptions)
                    }
                }
                $entry | Add-Member -MemberType NoteProperty -Name '_compiledPatterns' -Value $compiledPatterns -Force
            }
        }

        # Compile modifying entry patterns
        if (Get-Member -InputObject $domain -Name 'modifying' -MemberType NoteProperty) {
            foreach ($entry in $domain.modifying) {
                $compiledPatterns = @()
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        # Auto-anchor with ^ to prevent substring false positives
                        $anchoredPattern = if ($pattern.StartsWith('^')) { $pattern } else { '^' + $pattern }
                        # Convert glob * to .* only when * follows a non-special character
                        $anchoredPattern = $anchoredPattern -replace '(?<![.*\\])\*(?!\?|\*|\{)', '.*'
                        $compiledPatterns += [regex]::new($anchoredPattern, $regexOptions)
                    }
                }
                $entry | Add-Member -MemberType NoteProperty -Name '_compiledPatterns' -Value $compiledPatterns -Force
            }
        }

        # Compile strictness_gated entry patterns
        if (Get-Member -InputObject $domain -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            foreach ($entry in $domain.strictness_gated) {
                $compiledPatterns = @()
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        # Auto-anchor with ^ to prevent substring false positives
                        $anchoredPattern = if ($pattern.StartsWith('^')) { $pattern } else { '^' + $pattern }
                        # Convert glob * to .* only when * follows a non-special character
                        $anchoredPattern = $anchoredPattern -replace '(?<![.*\\])\*(?!\?|\*|\{)', '.*'
                        $compiledPatterns += [regex]::new($anchoredPattern, $regexOptions)
                    }
                }
                $entry | Add-Member -MemberType NoteProperty -Name '_compiledPatterns' -Value $compiledPatterns -Force
            }
        }

        # Build parameter_commands lookup: lowercased command-name + each alias -> entry
        if (Get-Member -InputObject $domain -Name 'parameter_commands' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $paramLookup = @{}
            foreach ($cmdName in $domain.parameter_commands.PSObject.Properties.Name) {
                $pEntry = $domain.parameter_commands.$cmdName
                $paramLookup[$cmdName.ToLowerInvariant()] = $pEntry
                if (Get-Member -InputObject $pEntry -Name 'aliases' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                    foreach ($alias in $pEntry.aliases) {
                        $paramLookup[$alias.ToString().ToLowerInvariant()] = $pEntry
                    }
                }
            }
            $domain | Add-Member -MemberType NoteProperty -Name '_parameterCommandLookup' -Value $paramLookup -Force
        }
    }

    # 5. Return the config object
    return $config
}
