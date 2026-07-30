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

    # Compile patterns for each domain's read_only and modifying entries
    $commandKeys = $config.commands.PSObject.Properties.Name
    foreach ($domainKey in $commandKeys) {
        $domain = $config.commands.$domainKey

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
                        $compiledPatterns += [regex]::new($anchoredPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
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
                        $compiledPatterns += [regex]::new($anchoredPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
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
                        $compiledPatterns += [regex]::new($anchoredPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
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
