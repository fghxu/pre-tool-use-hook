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
            # Split on "." and traverse the object tree
            $pathParts = $fieldPath -split '\.'
            $current = $RawInput
            $valid = $true

            foreach ($part in $pathParts) {
                if ($null -eq $current) {
                    # Edge case: hit null mid-traversal
                    $valid = $false
                    break
                }

                if ($current.PSObject.Properties.Name -contains $part) {
                    $current = $current.$part
                }
                else {
                    $valid = $false
                    break
                }
            }

            if ($valid -and $null -ne $current) {
                # Traversal succeeded — check if result is a usable string
                if ($current -is [string] -and $current.Trim().Length -gt 0) {
                    return $current
                }

                # Result is an object — try .command sub-field (VS Code Copilot pattern)
                if ($current.PSObject.Properties.Name -contains 'command' -and $current.command -is [string]) {
                    $trimmed = $current.command.Trim()
                    if ($trimmed.Length -gt 0) {
                        return $trimmed
                    }
                }
            }
        }
        # Fall through to heuristic — mapping path didn't yield a usable string
    }

    # Heuristic: walk the RawInput for any string field that looks like a command
    # (contains shell operators | ; &&, known command prefixes like docker/kubectl/aws/npm/git)
    $commandPattern = '[|;&]|&&|\|\|'
    $knownPrefixes = @('docker', 'kubectl', 'aws', 'npm', 'git', 'terraform', 'helm', 'gh', 'az', 'gcloud', 'python', 'node', 'ruby', 'go', 'cargo', 'dotnet', 'pwsh', 'powershell', 'cmd', 'bash', 'sh', 'curl', 'wget')

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

    return [PSCustomObject]@{
        hookSpecificOutput = [PSCustomObject]@{
            hookEventName            = "PreToolUse"
            permissionDecision       = $ClassifyResult.Decision
            permissionDecisionReason = $ClassifyResult.Reason
        }
    }
}
