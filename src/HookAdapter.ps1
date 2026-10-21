# HookAdapter.ps1 ? IDE detection, I/O formatting, output shaping
# Dot-sourced by Hook.ps1

function Detect-IDE {
    param([PSCustomObject]$InputObject)

    # Edge case: null input object ? default to "ClaudeCode"
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
    # Signal 4: transcript_path (decisive when present ? the KEY differentiator)
    #   Contains "GitHub.copilot-chat" -> Copilot (VS Code Copilot)
    #   Contains ".claude" -> ClaudeCode
    #
    # Signal 4 is decisive because VS Code Copilot shares Claude Code's protocol
    # (PascalCase hook_event_name, ISO timestamp, tool_use_id). The transcript_path
    # is the only field that reliably identifies the IDE.
    #
    # Signal 7: "timestamp" present while "tool_use_id" is ABSENT (decisive)
    #   -> Copilot. Needed because VS Code 1.141.x stopped sending BOTH
    #   tool_use_id and transcript_path, which left signals 0b/4 dead and made
    #   every VS Code payload fall through to the 1-1 majority tie (-> ClaudeCode).
    #   Census of 17104 recorded payloads (c:\temp\logs\prehook):
    #     Claude Code CLI: "timestamp" NEVER present (0/8236),
    #                      "tool_use_id" ALWAYS present (8236/8236)
    #     VS Code Copilot: "timestamp" ALWAYS present, "tool_use_id" absent (1.141+)
    #   So the pair is a clean inverse. Codex (turn_id) and DSH (dsh) also carry a
    #   timestamp, but both also carry tool_use_id AND are caught by their own
    #   decisive signals before this point.
    #
    # Majority vote wins for signals 1-3. If signal 4 or 7 fires, it may override.
    # Default tie goes to "ClaudeCode".

    # Signal 0: dsh field ? unique to the DeepSeek Harness bridge (decisive)
    # The dsh-plugin-pretoolhook bridge wraps every intercepted tool call in a
    # Claude Code PreToolUse-shaped payload and stamps it with a `dsh` object
    # whose `harness` is exactly "DeepSeek Harness". No other IDE sends this
    # field, so its presence is decisive and must fire before every other
    # signal (the payload also carries tool_use_id + ISO timestamp, which would
    # otherwise vote ClaudeCode).
    if ($InputObject.PSObject.Properties.Name -contains "dsh" -and $null -ne $InputObject.dsh) {
        $dshHarness = $InputObject.dsh.harness
        if ($dshHarness -ceq "DeepSeek Harness") {
            return "DSH"
        }
    }

    # Signal 0b: tool_use_id contains "__vscode-" ? VS Code Copilot (decisive)
    # VS Code Copilot shares Claude Code's protocol (PascalCase, ISO timestamp,
    # tool_use_id present) but its tool_use_id always ends with __vscode-<uuid>.
    # This must fire BEFORE the Codex signals to avoid misdetection.
    if ($InputObject.PSObject.Properties.Name -contains "tool_use_id" -and
        $InputObject.tool_use_id -match '__vscode-') {
        return "Copilot"
    }

    # Signal 5: turn_id field ? unique to Codex CLI (decisive)
    if ($InputObject.PSObject.Properties.Name -contains "turn_id" -and $InputObject.turn_id) {
        return "Codex"
    }

    # Signal 6: model field ? unique to Codex CLI (decisive)
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

    # Signal 4: transcript_path ? decisive when present
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

    # Signal 7: "timestamp" present AND "tool_use_id" absent -> Copilot (decisive)
    # VS Code 1.141.x dropped both tool_use_id and transcript_path, so signals
    # 0b and 4 are dead for it and the signals 1-3 vote lands 1-1 (-> ClaudeCode).
    # Claude Code CLI never sends "timestamp" and always sends "tool_use_id", so
    # this pair cleanly separates the two. Checked by property PRESENCE (not
    # truthiness) because ConvertFrom-Json turns an ISO timestamp into a
    # System.DateTime and an epoch 0 would be falsy.
    $hasTimestamp = $InputObject.PSObject.Properties.Name -contains "timestamp"
    $hasToolUseId = ($InputObject.PSObject.Properties.Name -contains "tool_use_id") -and
                    -not [string]::IsNullOrWhiteSpace([string]$InputObject.tool_use_id)
    if ($hasTimestamp -and -not $hasToolUseId) {
        return "Copilot"
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

    # Edge case: null RawInput ? return null immediately
    if ($null -eq $RawInput) {
        return $null
    }

    $toolName = $RawInput.tool_name
    $mapping = $Config.tool_name_mapping

    # Edge case: null/empty tool_name_mapping ? skip mapping lookup
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
        # Fall through to heuristic ? mapping path didn't yield a usable string
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
    # The DeepSeek Harness bridge (dsh-plugin-pretoolhook) consumes the SAME
    # wrapper: it parses permissionDecision (allow|ask|deny) and the reason and
    # maps them onto DSH's tools/pre-execute decision. DSH supports ask natively
    # (the approval seam routes it to the user), so ask stays ask ? only Codex
    # maps ask?deny.
    #
    # Return PSCustomObject (NOT JSON string ? caller will ConvertTo-Json)

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

# -----------------------------------------------------------------------------
# VS Code multi-root workspace folders (the "workspace_roots" feature)
#
# VS Code hands the hook a single cwd, but one window can open several folders.
# The folders of the workspace the cwd belongs to are treated exactly like the
# cwd by the path policy. No other IDE has this concept, so every entry point
# below is gated on $IDE -eq 'Copilot'.
# -----------------------------------------------------------------------------

function ConvertFrom-VsCodeUri {
    <#
    Converts a VS Code path string into a plain filesystem path:
      file:///c%3A/git/cc/kimi -> c:\git\cc\kimi
      file://server/share/x    -> \\server\share\x
    A value without the file: scheme is passed through as a plain path.
    Separators are unified and no trailing separator is added. Returns $null
    for empty input.
    #>
    param([string]$Uri)

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $null }
    $sep  = [System.IO.Path]::DirectorySeparatorChar
    $text = $Uri.Trim()

    if ($text -notmatch '^(?i)file:') {
        return ($text -replace '[/\\]', $sep)
    }

    $rest = $text.Substring(5)
    $rest = $rest -replace '^//', ''
    try { $rest = [System.Uri]::UnescapeDataString($rest) } catch { }
    $rest = $rest -replace '[/\\]', $sep

    $esc = [regex]::Escape($sep)
    if ($rest -match ('^' + $esc + '([A-Za-z]):(?:' + $esc + ')?(.*)$')) {
        $drive = $Matches[1]
        $tail  = $Matches[2]
        if ($tail) { return ($drive + ':' + $sep + $tail) }
        return ($drive + ':' + $sep)
    }
    if ($rest.StartsWith($sep)) { return $rest }
    if (-not $rest) { return $null }
    # file://server/share/x -> \\server\share\x
    return ($sep + $sep + $rest)
}

function Get-VsCodeStorageEntryRoots {
    <#
    Reads ONE workspaceStorage entry and returns the folders it declares.
    workspace.json holds either {"folder": <uri>} (single-folder window) or
    {"workspace": <uri of a .code-workspace file>} (multi-root window). The
    .code-workspace "folders" entries may be plain paths, file URIs, or objects
    with a path/uri property; relative paths resolve against the workspace file.
    Returns @() for empty/corrupt entries.
    #>
    param([string]$EntryDir)

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $none = @()
    $roots = New-Object System.Collections.ArrayList

    $metaFile = [System.IO.Path]::Combine($EntryDir, 'workspace.json')
    if (-not [System.IO.File]::Exists($metaFile)) { return $none }

    $meta = $null
    try { $meta = ([System.IO.File]::ReadAllText($metaFile) | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $none }
    if ($null -eq $meta) { return $none }

    # PSObject.Properties lookups instead of Get-Member: this runs once per
    # workspaceStorage entry on every hook call, and Get-Member is ~100x slower.
    $props = $meta.PSObject.Properties
    if ($props['folder']) {
        $folder = $props['folder'].Value
        if ($folder -isnot [string] -or -not $folder) { return $none }
        $p = ConvertFrom-VsCodeUri -Uri $folder
        if (-not $p) { return $none }
        $null = $roots.Add($p)
        return @($roots)
    }

    if (-not $props['workspace']) { return $none }
    $wsUri = $props['workspace'].Value
    if ($wsUri -isnot [string] -or -not $wsUri) { return $none }

    $wsFile = ConvertFrom-VsCodeUri -Uri $wsUri
    if (-not $wsFile -or -not [System.IO.File]::Exists($wsFile)) { return $none }

    $doc = $null
    try { $doc = ([System.IO.File]::ReadAllText($wsFile) | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $none }
    if ($null -eq $doc) { return $none }
    $folders = $doc.PSObject.Properties['folders']
    if (-not $folders) { return $none }

    $wsDir = [System.IO.Path]::GetDirectoryName($wsFile)
    foreach ($f in @($folders.Value)) {
        if ($null -eq $f) { continue }
        $raw = $null
        if ($f -is [string]) {
            $raw = $f
        }
        else {
            $fp = $f.PSObject.Properties
            if ($fp['uri']) { $raw = $fp['uri'].Value }
            elseif ($fp['path']) { $raw = $fp['path'].Value }
        }
        if ($raw -isnot [string] -or [string]::IsNullOrWhiteSpace($raw)) { continue }

        $p = ConvertFrom-VsCodeUri -Uri $raw
        if (-not $p) { continue }
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = [System.IO.Path]::Combine($wsDir, $p) }
        try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
        $null = $roots.Add(($p -replace '[/\\]', $sep))
    }
    return @($roots)
}

function Get-VsCodeWorkspaceRoots {
    <#
    Returns the folders of the VS Code workspace that CONTAINS $AnchorPath (or
    the current location). Entries are scanned newest-first and the first
    workspace that contains the anchor wins; unrelated workspaces are never
    adopted, so an untracked folder yields @().
    #>
    param(
        [string]$AnchorPath,
        [string[]]$StorageRoots
    )

    $sep = [System.IO.Path]::DirectorySeparatorChar

    if (-not $StorageRoots -or @($StorageRoots).Count -eq 0) {
        $StorageRoots = @()
        if ($env:APPDATA) {
            $StorageRoots += (Join-Path $env:APPDATA 'Code\User\workspaceStorage')
            $StorageRoots += (Join-Path $env:APPDATA 'Code - Insiders\User\workspaceStorage')
        }
    }

    $anchor = $AnchorPath
    if (-not $anchor) { $anchor = (Get-Location).Path }
    try { $anchor = [System.IO.Path]::GetFullPath($anchor) } catch { }
    $anchor = $anchor -replace '[/\\]', $sep
    if (-not $anchor.EndsWith($sep)) { $anchor += $sep }
    $anchorNorm = $anchor.ToLowerInvariant()

    # Recency keys are built as fixed-width-ticks + path strings so a plain
    # [Array]::Sort (ordinal) orders them newest-first. DirectoryInfo is used
    # because its LastWriteTimeUtc comes free with the enumeration buffer, and
    # GetFiles('workspace.json') replaces a File.Exists + GetLastWriteTimeUtc
    # pair - together they remove ~3 syscalls per entry, which is the bulk of
    # the per-call cost on a machine with ~80 stored workspaces.
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($store in @($StorageRoots)) {
        if (-not $store) { continue }
        $children = $null
        try { $children = (New-Object System.IO.DirectoryInfo($store)).GetDirectories() }
        catch { continue }
        foreach ($child in $children) {
            # A window's recency is the newer of its folder and its
            # workspace.json (rewriting that file may not bump the folder).
            $stamp = $child.LastWriteTimeUtc
            $metaFile = $null
            try { $metaFile = $child.GetFiles('workspace.json') } catch { $metaFile = $null }
            if ($metaFile -and $metaFile.Length -gt 0) {
                $mt = $metaFile[0].LastWriteTimeUtc
                if ($mt -gt $stamp) { $stamp = $mt }
            }
            $keys.Add($stamp.Ticks.ToString('D19') + '|' + $child.FullName)
        }
    }
    if ($keys.Count -eq 0) { return @() }

    $ordered = $keys.ToArray()
    [System.Array]::Sort($ordered, [System.StringComparer]::Ordinal)

    # Newest first: the window we are running in is almost always at the top, so
    # the scan normally stops after one or two entries.
    for ($i = $ordered.Length - 1; $i -ge 0; $i--) {
        $roots = @(Get-VsCodeStorageEntryRoots -EntryDir $ordered[$i].Substring(20))
        if ($roots.Count -eq 0) { continue }
        foreach ($r in $roots) {
            if (-not $r) { continue }
            $rn = $r -replace '[/\\]', $sep
            if (-not $rn.EndsWith($sep)) { $rn += $sep }
            if ($anchorNorm.StartsWith($rn.ToLowerInvariant())) { return $roots }
        }
    }
    return @()
}

function Add-WorkspaceRoots {
    <#
    Fills in $Config._workspaceRoots / _workspaceRootsNorm: the extra folders
    that must be treated exactly like the cwd. Sources are the explicit
    workspace_roots.paths list plus VS Code auto-discovery of the folders of the
    workspace the cwd belongs to (workspace_roots.discover, default ["vscode"]).
    Everything is opt-in (workspace_roots.enabled) and VS Code only. Returns the
    normalized roots that were adopted.
    #>
    param(
        $Config,
        [string]$IDE,
        [string[]]$ExtraRoots,
        [string[]]$StorageRoots,
        [string]$AnchorPath
    )

    if (-not $Config) { return @() }

    if ($IDE -ne 'Copilot') { return @() }

    $props = $Config.PSObject.Properties
    $block = $null
    if ($props['workspace_roots']) { $block = $props['workspace_roots'].Value }
    if (-not $block) { return @() }

    $blockProps = $block.PSObject.Properties
    $enabled = $false
    if ($blockProps['enabled']) { $enabled = [bool]$blockProps['enabled'].Value }
    if (-not $enabled) { return @() }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $cwd = $null
    if ($props['_cwd']) { $cwd = $props['_cwd'].Value }
    $anchor = $AnchorPath
    if (-not $anchor) { $anchor = $cwd }

    $candidates = New-Object System.Collections.ArrayList
    if ($blockProps['paths']) {
        foreach ($p in @($blockProps['paths'].Value)) { $null = $candidates.Add($p) }
    }
    foreach ($p in @($ExtraRoots)) {
        if ($p) { $null = $candidates.Add($p) }
    }

    $discover = @('vscode')
    if ($blockProps['discover']) { $discover = @($blockProps['discover'].Value) }
    foreach ($src in @($discover)) {
        if ($src -isnot [string]) { continue }
        if ($src -match '^(?i)vscode$') {
            foreach ($r in @(Get-VsCodeWorkspaceRoots -AnchorPath $anchor -StorageRoots $StorageRoots)) {
                $null = $candidates.Add($r)
            }
        }
    }

    $roots = New-Object System.Collections.ArrayList
    $seen  = New-Object System.Collections.ArrayList
    foreach ($c in @($candidates)) {
        if ($c -isnot [string] -or [string]::IsNullOrWhiteSpace($c)) { continue }

        $p = ConvertFrom-VsCodeUri -Uri $c
        if (-not $p) { continue }
        if (-not [System.IO.Path]::IsPathRooted($p)) {
            if (-not $cwd) { continue }
            $p = Join-Path $cwd $p
        }
        try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
        $p = $p -replace '[/\\]', $sep
        if (-not $p.EndsWith($sep)) { $p += $sep }

        $norm = $p.ToLowerInvariant()
        if ($seen -contains $norm) { continue }
        $null = $seen.Add($norm)
        $null = $roots.Add($p)
    }

    $Config | Add-Member -MemberType NoteProperty -Name '_workspaceRoots' -Value @($roots) -Force
    $Config | Add-Member -MemberType NoteProperty -Name '_workspaceRootsNorm' -Value @($seen) -Force
    return @($roots)
}
