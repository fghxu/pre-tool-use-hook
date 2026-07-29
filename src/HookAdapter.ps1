# HookAdapter.ps1 — IDE detection, I/O formatting, output shaping
# Dot-sourced by Hook.ps1

function Detect-IDE {
    param([PSCustomObject]$InputObject)

    # Edge case: null input object → default to "ClaudeCode"
    if ($null -eq $InputObject) {
        [Console]::Error.WriteLine("HookAdapter: Warning: Detect-IDE received null InputObject, defaulting to ClaudeCode")
        return "ClaudeCode"
    }

    # Four signals, each votes ClaudeCode or Copilot:
    #
    # Signal 1: hook_event_name field
    #   "PreToolUse" (PascalCase P,T,U) -> ClaudeCode
    #   "preToolUse" (camelCase p,t,U) -> Copilot
    #
    # Signal 2: tool_use_id field
    #   Present and non-null -> ClaudeCode
    #   Absent or null -> Copilot
    #
    # Signal 3: timestamp format
    #   Matches ISO 8601 with ms: '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z?$' -> ClaudeCode
    #   Matches Unix epoch (10-13 digits): '^\d{10,13}$' -> Copilot
    #
    # Signal 4: transcript_path (decisive when present — the KEY differentiator)
    #   Contains "GitHub.copilot-chat" -> Copilot (VS Code Copilot)
    #   Contains ".claude" -> ClaudeCode
    #
    # Signal 4 is decisive because VS Code Copilot shares Claude Code's protocol
    # (PascalCase hook_event_name, ISO timestamp, tool_use_id). The transcript_path
    # is the only field that reliably identifies the IDE.
    #
    # Majority vote wins for signals 1-3. If signal 4 fires, it may override.
    # Default tie goes to "ClaudeCode".

    # Signal 0: tool_use_id contains "__vscode-" → VS Code Copilot (decisive)
    # VS Code Copilot shares Claude Code's protocol (PascalCase, ISO timestamp,
    # tool_use_id present) but its tool_use_id always ends with __vscode-<uuid>.
    # This must fire BEFORE the Codex signals to avoid misdetection.
    if ($InputObject.PSObject.Properties.Name -contains "tool_use_id" -and
        $InputObject.tool_use_id -match '__vscode-') {
        return "Copilot"
    }

    # Signal 5: turn_id field — unique to Codex CLI (decisive)
    if ($InputObject.PSObject.Properties.Name -contains "turn_id" -and $InputObject.turn_id) {
        return "Codex"
    }

    # Signal 6: model field — unique to Codex CLI (decisive)
    if ($InputObject.PSObject.Properties.Name -contains "model" -and $InputObject.model) {
        return "Codex"
    }

    $signals = @{ Claude = 0; Copilot = 0 }

    # Signal 1: hook_event_name
    if ($InputObject.hook_event_name) {
        if ($InputObject.hook_event_name -ceq "PreToolUse") {
            $signals.Claude++
        }
        elseif ($InputObject.hook_event_name -ceq "preToolUse") {
            $signals.Copilot++
        }
    }

    # Signal 2: tool_use_id presence
    if ($InputObject.PSObject.Properties.Name -contains "tool_use_id" -and $InputObject.tool_use_id) {
        $signals.Claude++
    }
    else {
        $signals.Copilot++
    }

    # Signal 3: timestamp format
    $ts = $InputObject.timestamp
    if ($ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z?$') {
        $signals.Claude++
    }
    elseif ($ts -match '^\d{10,13}$') {
        $signals.Copilot++
    }

    # Signal 4: transcript_path — decisive when present
    # VS Code Copilot sets transcript_path to ...\GitHub.copilot-chat\transcripts\...
    # Claude Code sets it to ...\.claude\projects\...
    if ($InputObject.transcript_path) {
        if ($InputObject.transcript_path -match 'GitHub\.copilot-chat') {
            return "Copilot"
        }
        elseif ($InputObject.transcript_path -match '\.claude') {
            return "ClaudeCode"
        }
    }

    # Fallback: majority vote of signals 1-3 (used when transcript_path is absent)
    # Majority vote; tie goes to ClaudeCode
    if ($signals.Claude -ge $signals.Copilot) {
        return "ClaudeCode"
    }
    else {
        return "Copilot"
    }
}

function Get-InputFieldValue {
    <# Traverse a dot-path (e.g. 'tool_input.file_path') on the raw input object.
       Returns the trimmed string value, or $null if any segment is missing/empty. #>
    param([PSCustomObject]$RawInput, [string]$FieldPath)
    if (-not $FieldPath) { return $null }
    $current = $RawInput
    foreach ($part in ($FieldPath -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current.PSObject.Properties.Name -contains $part) {
            $current = $current.$part
        }
        else { return $null }
    }
    if ($current -is [string] -and $current.Trim().Length -gt 0) { return $current.Trim() }
    return $null
}

function Get-InputFieldValues {
    <# Like Get-InputFieldValue, but a mapping segment may end with [*] to
       enumerate a JSON array and collect a leaf from each element. Example:
       'tool_input.replacements[*].filePath' yields one filePath per replacement.
       Scalar dot-paths (no [*]) return a single-element array. Missing segments
       or a non-array at [*] collect nothing (caller treats empty as fail-safe). #>
    param([PSCustomObject]$RawInput, [string]$FieldPath)
    if ([string]::IsNullOrWhiteSpace($FieldPath) -or $null -eq $RawInput) { return }
    $collected = [System.Collections.Generic.List[string]]::new()
    $segments = @($FieldPath -split '\.')
    [void](Resolve-FieldPathLeaves -Node $RawInput -Index 0 -Segments $segments -Collected $collected)
    foreach ($s in $collected) { $s }
}

function Resolve-FieldPathLeaves {
    <# Recursive worker for Get-InputFieldValues. Walks $Segments from $Index;
       appends each non-empty string leaf to $Collected. A `name[*]` segment
       enumerates an array property (any other shape collects nothing). #>
    param($Node, [int]$Index, [string[]]$Segments, $Collected)
    if ($null -eq $Node) { return }
    if ($Index -ge $Segments.Count) { return }
    $seg = $Segments[$Index]
    if ($seg -match '^([^\[\]]+)\[\*\]$') {
        $name = $Matches[1]
        if (-not ($Node.PSObject.Properties.Name -contains $name)) { return }
        $child = $Node.$name
        if (-not ($child -is [System.Collections.IList])) { return }
        foreach ($el in $child) {
            Resolve-FieldPathLeaves -Node $el -Index ($Index + 1) -Segments $Segments -Collected $Collected
        }
        return
    }
    if (-not ($Node.PSObject.Properties.Name -contains $seg)) { return }
    if ($Index -eq $Segments.Count - 1) {
        $leaf = $Node.$seg
        if ($leaf -is [string] -and $leaf.Trim().Length -gt 0) { $Collected.Add($leaf.Trim()) }
        return
    }
    Resolve-FieldPathLeaves -Node $Node.$seg -Index ($Index + 1) -Segments $Segments -Collected $Collected
}

function Get-CommandFromInput {
    param([PSCustomObject]$RawInput, [PSCustomObject]$Config)

    # Edge case: null RawInput → return null immediately
    if ($null -eq $RawInput) {
        return $null
    }

    $toolName = $RawInput.tool_name
    $mapping = $Config.tool_name_mapping

    # Edge case: null/empty tool_name_mapping → skip mapping lookup
    $mappingKeys = @()
    if ($mapping) {
        try {
            $mappingKeys = @($mapping.PSObject.Properties.Name)
        }
        catch {
            # If we can't inspect mapping properties, skip mapping lookup
        }
    }

    # Look up tool_name in config.tool_name_mapping (only if mapping has keys)
    if ($mappingKeys.Count -gt 0 -and $toolName -and $mappingKeys -contains $toolName) {
        $fieldPath = $mapping.$toolName

        # If fieldPath is null/empty, skip mapping and fall through to heuristic
        if ($fieldPath) {
            $mapped = Get-InputFieldValue -RawInput $RawInput -FieldPath $fieldPath
            if ($mapped) { return $mapped }
            # Object at path with .command sub-field (VS Code Copilot pattern)
            $pathParts = $fieldPath -split '\.'
            $current = $RawInput
            foreach ($part in $pathParts) {
                if ($null -eq $current) { break }
                if ($current.PSObject.Properties.Name -contains $part) { $current = $current.$part } else { $current = $null; break }
            }
            if ($null -ne $current -and $current -isnot [string] -and ($current.PSObject.Properties.Name -contains 'command') -and $current.command -is [string]) {
                $trimmed = $current.command.Trim()
                if ($trimmed.Length -gt 0) { return $trimmed }
            }
        }
        # Fall through to heuristic — mapping path didn't yield a usable string
    }

    # Heuristic: walk the RawInput for any string field that looks like a command
    # (contains shell operators | ; &&, known command prefixes from config)
    $commandPattern = '[|;&]|&&|\|\|'
    $knownPrefixes = if ($Config.known_command_prefixes) {
        @($Config.known_command_prefixes)
    } else {
        # Minimal fallback if config key is missing
        @('docker', 'kubectl', 'aws', 'npm', 'git', 'terraform', 'helm', 'pwsh', 'powershell', 'cmd', 'bash', 'sh', 'curl', 'dir', 'ls', 'cat', 'ping', 'ps', 'type')
    }

    # Helper function to recursively walk an object and find command-like strings
    function _WalkForCommand {
        param($obj, $depth = 0)

        if ($depth -gt 10) { return $null }
        if ($null -eq $obj) { return $null }

        if ($obj -is [string]) {
            $trimmed = $obj.Trim()
            if ($trimmed.Length -eq 0) { return $null }

            # Check for shell operators
            if ($trimmed -match $commandPattern) {
                return $trimmed
            }

            # Check for known command prefixes
            foreach ($prefix in $knownPrefixes) {
                if ($trimmed -match "^\s*${prefix}\s") {
                    return $trimmed
                }
            }

            return $null
        }

        if ($obj -is [PSCustomObject] -or $obj -is [hashtable]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $result = _WalkForCommand -obj $prop.Value -depth ($depth + 1)
                if ($result) { return $result }
            }
        }

        if ($obj -is [array]) {
            foreach ($item in $obj) {
                $result = _WalkForCommand -obj $item -depth ($depth + 1)
                if ($result) { return $result }
            }
        }

        return $null
    }

    return _WalkForCommand -obj $RawInput
}

function Format-Output {
    param([PSCustomObject]$ClassifyResult, [string]$IDE)

    # Both Claude Code and VS Code Copilot (built on Claude Code) expect the
    # hookSpecificOutput wrapper format.
    #   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
    #       "permissionDecision": "<allow|ask>",
    #       "permissionDecisionReason": "<reason>" } }
    #
    # Return PSCustomObject (NOT JSON string — caller will ConvertTo-Json)

    # Map internal "ask" to "deny" for Codex (Codex parses "ask" but errors on it)
    $decision = $ClassifyResult.Decision
    if ($IDE -eq 'Codex' -and $decision -eq 'ask') {
        $decision = 'deny'
    }

    return [PSCustomObject]@{
        hookSpecificOutput = [PSCustomObject]@{
            hookEventName            = "PreToolUse"
            permissionDecision       = $decision
            permissionDecisionReason = $ClassifyResult.Reason
        }
    }
}
