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

    # Default log_file_path to empty string if missing
    if (-not (Get-Member -InputObject $Config -Name 'log_file_path' -MemberType NoteProperty)) {
        $Config | Add-Member -MemberType NoteProperty -Name 'log_file_path' -Value '' -Force
    }

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

    # Compile trusted_pattern
    $compiledTrusted = @()
    foreach ($pattern in $config.trusted_pattern) {
        $compiledTrusted += [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'trusted' -Value $compiledTrusted -Force

    # Compile untrusted_pattern
    $compiledUntrusted = @()
    foreach ($pattern in $config.untrusted_pattern) {
        $compiledUntrusted += [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'untrusted' -Value $compiledUntrusted -Force

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
    }

    # 5. Return the config object
    return $config
}
