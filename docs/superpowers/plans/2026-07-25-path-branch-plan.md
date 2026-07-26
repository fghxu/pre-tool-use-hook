# Path-Branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** File-tool writes (Write/Edit/Copilot file tools) are decided by `system_paths`/`editable_paths`/CWD/strictness via a shared `Resolve-PathPolicy` — retiring the parallel trusted/untrusted path regexes.

**Architecture:** Spec: `docs/superpowers/specs/2026-07-25-path-branch-design.md`. Extract the existing redirect decision ladder (`Test-EditableOrCwd` + `Test-RedirectionTarget` steps 4a–4d, src/Parser.ps1) into a shared canonicalize+decide function; call it from (a) the redirect analysis (byte-identical behavior) and (b) a new Classifier path-branch gated by `path_tool_mapping`. TDD: migrate the 60 trustedpattern cases to new expectations first (RED), implement (GREEN), full 9-suite differential.

**Tech Stack:** PowerShell hook (`src/Hook.ps1` → ConfigLoader/Parser/HookAdapter/Classifier), `config.json`, TestRunner XML suites.

**Key facts an implementer needs:**
- `TestRunner.ps1` already supports `-Cwd` (pins `$config._cwd`/`_cwdNorm`) and per-case `<tool-name>`/`<tool-input-json>`.
- `Test-EditableOrCwd` (src/Parser.ps1:1037) already canonicalizes (relative→CWD anchor, GetFullPath `..` collapse, separator unify, case-fold, `~` handling) and returns 'under current directory' / 'editable path' / $null.
- Redirect ladder (src/Parser.ps1:1205-1245 `>` and 1155-1184 `>>`): discard → temp → system → EditableOrCwd → loose → normal(-no-editable) → ask.
- `Invoke-Classify` (src/Classifier.ps1): tool gate (~233) → extraction `Get-CommandFromInput` (~266) → trusted gate `Test-TrustedUntrusted` (~285) → classification engine.
- Dot-path traversal of mapped fields is inline in `Get-CommandFromInput` (src/HookAdapter.ps1:136-155).
- Reason strings for redirects must stay byte-identical (fullpipe may assert reasons) — `Resolve-PathPolicy` takes a reason-verb parameter.
- Decisions map: allow → exit 0, ask → exit 2. `modifying_strictness` ∈ normal/strict/loose.
- Deviation from spec §3.4: `edit_files`/`apply_patch` are NOT added to `path_tool_mapping` (payload shapes unverified). They stay intercepted and keep prompting via the existing extraction path (fail-safe). Capturing their real payload shapes is follow-up work, noted in PROGRESS.md.

---

### Task 1: Baseline

**Files:** none

- [ ] **Step 1: Run all 9 suites and confirm baseline**

From repo root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.var-assignment.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.fullpath.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-normal.xml" -Strictness normal
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-strict.xml" -Strictness strict
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.new-samples.xml"
pwsh -NoProfile -File "test/FullPipeTestRunner.ps1"
```

Expected: 487/487 · 94/94 · 63/64 · 20/20 · 20/25 · 24/25 · 61/66 · 14/14 · 19/19 (fullpipe **must** run under `pwsh`, not `powershell.exe`). Any deviation: STOP and reconcile before continuing.

---

### Task 2: Migrate trustedpattern suite to the new policy (RED)

**Files:**
- Modify: `test/test-cases.trustedpattern.xml`

- [ ] **Step 1: Add suite-header comment documenting the CWD pin**

Replace the comment block immediately before `<category-group name="TP-Write-Windows">` with:

```xml
  <!-- =================================================================== -->
  <!-- Path-Branch Policy (2026-07-25)                                      -->
  <!-- File-tool writes decided by system_paths / editable_paths / CWD /    -->
  <!-- strictness via Resolve-PathPolicy (spec 2026-07-25-path-branch-      -->
  <!-- design.md).                                                          -->
  <!--                                                                      -->
  <!-- CWD-dependent cases assume:  -Cwd C:\git\repo                        -->
  <!-- Run:  src/TestRunner.ps1 -XmlPath test/test-cases.trustedpattern.xml -->
  <!--       -Cwd C:\git\repo                                               -->
  <!-- =================================================================== -->
```

- [ ] **Step 2: Update the flipped cases (10 edits)**

Apply these exact replacements to existing cases (keep `category` and `<tool-name>`/payloads unchanged unless shown):

1. Case "Write C:\temp\evil.exe" — change expected `ask`→`allow`, reason to `"location-only: editable root, no exe guard on writes"`, description to `Write C:\temp\evil.exe — D4: editable root allows; execution guarded command-side`
2. Case "Write /usr/bin/evil" — reason to `"fixed: system_paths /usr asks"`, description to `Write /usr/bin/evil — system_paths /usr now asks (residual fixed)`
3. Case "Write /home/user/notes.txt" — change expected `allow`→`ask`, reason to `"fixed: default-ask for unlisted paths"`, description to `Write /home/user/notes.txt — default-ask (residual fixed)`
4. Case "Write C:\Windows\..\temp\ok.txt" — change expected `ask`→`allow`, reason to `"canonicalized: resolves to C:\temp (editable)"`, description to `Write C:\Windows\..\temp\ok.txt — canonicalizes to C:\temp\ok.txt (editable) allows`
5. Case "Write C:\git\my repo\space file.txt" — change payload to `{"file_path":"C:\\git\\repo\\space file.txt"}`, reason to `"spaces in path under CWD"`, description to `Write C:\git\repo\space file.txt — spaces under CWD allow`
6. Case "Write notes.txt (relative)" — reason to `"fixed: relative resolved against CWD"`, description to `Write notes.txt (relative) — anchored to CWD; under-CWD allows`
7. Case "Write \\?\C:\Windows\x" — change expected `allow`→`ask`, reason to `"fixed: extended prefix canonicalized then system_paths"`, description to `Write \\?\C:\Windows\x — prefix stripped, C:\Windows system path asks (residual fixed)`
8. Case "Write C:\Windows\notepad.exe" — reason to `"system_paths: exe write into system dir asks"`, description to `Write C:\Windows\notepad.exe — system_paths asks (path-branch, not exe pattern)`
9. Case "Write C:\git\repo\file.md" — reason to `"CWD rule: under current directory"`, description unchanged
10. All remaining `C:\git\repo\…` allow cases (Edit, MultiEdit, NotebookEdit, create_file, replace_string_in_file, edit_notebook_file) — reason text updated from `trusted: C:\git root` to `CWD rule: under current directory` (description unchanged). This is a reason-string-only edit for: Edit C:\git\repo\code.md, MultiEdit C:\git\repo\code.md, NotebookEdit C:\git\repo\nb.ipynb, create_file C:\git\repo\new.md, replace_string_in_file C:\git\repo\x.md, edit_notebook_file C:\git\repo\nb.ipynb.

- [ ] **Step 3: Append 6 new cases (before `</commands>`)**

```xml
  <category-group name="TP-PathBranch">
    <test-case expected="ask" reason="D5: other project outside CWD asks" category="TP-PathBranch">
      <description>Write C:\git\other-project\x.md — not under CWD, not editable; default-ask</description>
      <tool-name>Write</tool-name>
      <tool-input-json>{"file_path":"C:\\git\\other-project\\x.md"}</tool-input-json>
    </test-case>
    <test-case expected="ask" reason="D5: other project via Edit asks" category="TP-PathBranch">
      <description>Edit C:\git\other-project\x.md — other project asks</description>
      <tool-name>Edit</tool-name>
      <tool-input-json>{"file_path":"C:\\git\\other-project\\x.md","old_string":"a","new_string":"b"}</tool-input-json>
    </test-case>
    <test-case expected="allow" reason="canonicalize: forward slashes under CWD" category="TP-PathBranch">
      <description>Write C:/git/repo/fwd.txt — slash-unified, under CWD allows</description>
      <tool-name>Write</tool-name>
      <tool-input-json>{"file_path":"C:/git/repo/fwd.txt"}</tool-input-json>
    </test-case>
    <test-case expected="ask" reason="canonicalize: .. escapes CWD to other project" category="TP-PathBranch">
      <description>Write C:\git\repo\..\other-project\x.md — canonicalizes outside CWD; asks</description>
      <tool-name>Write</tool-name>
      <tool-input-json>{"file_path":"C:\\git\\repo\\..\\other-project\\x.md"}</tool-input-json>
    </test-case>
    <test-case expected="allow" reason="create_new_workspace under CWD" category="TP-PathBranch">
      <description>create_new_workspace C:\git\repo\ws — workspacePath mapping, under CWD</description>
      <tool-name>create_new_workspace</tool-name>
      <tool-input-json>{"workspacePath":"C:\\git\\repo\\ws"}</tool-input-json>
    </test-case>
    <test-case expected="allow" reason="redirect under CWD allows (shared function)" category="TP-PathBranch">
      <description>Bash echo hi > C:\git\repo\out.txt — redirect uses same Resolve-PathPolicy ladder</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[echo hi > C:\git\repo\out.txt]]></copilot-command>
    </test-case>
  </category-group>
```

- [ ] **Step 4: RED run**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml" -Cwd "C:\git\repo"`
Expected: failures among the flipped cases (the old pattern-based engine can't know the CWD rule or canonicalization). Record which fail — they must be *only* cases 1-7 of Step 2 plus possibly the new Step-3 cases (e.g. `C:\git\other-project` currently allows via the trusted git-root pattern → will fail expecting ask). The 5 legacy docker-comfyui fails persist as usual.

---

### Task 3: ConfigLoader — `path_tool_mapping`

**Files:**
- Modify: `src/ConfigLoader.ps1` (after the `tool_name_mapping` normalization, ~line 120)

- [ ] **Step 1: Add loading + validation**

Insert after the tool_name_mapping handling:

```powershell
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
```

- [ ] **Step 2: Sanity — config still loads**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml" | Select-String '^Passed:'`
Expected: `Passed:   94 (100%)` (loader change is inert — config.json has no `path_tool_mapping` yet).

---

### Task 4: `Resolve-PathPolicy` + redirect refactor (Parser.ps1)

**Files:**
- Modify: `src/Parser.ps1` (after `Test-EditableOrCwd`, line 1089)

- [ ] **Step 1: Add canonicalization helper with `\\?\` strip**

Insert after `Test-EditableOrCwd` (line 1089):

```powershell
function ConvertTo-CanonicalWritePath {
    <#
    Canonicalize a write-target path: strip \\?\ extended-length prefix, anchor
    relative paths to CWD, collapse .. via GetFullPath, unify separators.
    Mirrors Test-EditableOrCwd's resolution (including ~ home handling).
    #>
    param(
        [string]$TargetPath,
        $Config
    )
    if (-not $TargetPath) { return $null }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $resolved = $TargetPath.Trim()
    # Strip \\?\ extended-length prefix (\\?\C:\x -> C:\x)
    if ($resolved.StartsWith('\\?\')) { $resolved = $resolved.Substring(4) }
    $isHome = $resolved.StartsWith('~')
    if (-not $isHome -and $resolved -notmatch '^[A-Za-z]:[\\/]' -and $resolved -notmatch '^[\\/]') {
        $resolved = "$($Config._cwd)$resolved"
    }
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
    return $resolved
}

function Resolve-PathPolicy {
    <#
    Decision ladder for a write-target path (redirect target or file-tool path).
    Order mirrors Test-RedirectionTarget 4b-4d exactly so redirect behavior is
    byte-identical: temp -> system -> CWD/editable -> loose -> normal -> ask.
    Returns PSCustomObject @{ Decision; Risk; Reason; Target }
    $Verb prefixes the reason string ('output redirect to' / 'append redirect to' / 'file write to').
    #>
    param(
        [string]$Path,
        $Config,
        [string]$Verb = 'file write to'
    )
    $resolved = ConvertTo-CanonicalWritePath -TargetPath $Path -Config $Config
    if (-not $resolved) {
        return [PSCustomObject]@{ Decision = 'ask'; Risk = 'medium'; Reason = "$Verb (no target) (modifying)"; Target = 'unknown' }
    }
    $targetPath = $resolved

    # -- temp paths (low risk) --
    if ($targetPath -match '^/tmp/|^/var/tmp/|^%TEMP%|^%TMP%|^\$env:TEMP|^\$env:TMP') {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $targetPath (temp path) (low risk)"; Target = $targetPath }
    }
    # -- system paths (high risk) --
    if ($Config -and $targetPath -match $Config._systemPathRegex) {
        return [PSCustomObject]@{ Decision = 'ask'; Risk = 'high'; Reason = "$Verb $targetPath (system path) (high risk)"; Target = $targetPath }
    }
    # -- CWD / editable_paths --
    $writableReason = Test-EditableOrCwd -TargetPath $targetPath -Config $Config
    if ($writableReason) {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $targetPath ($writableReason)"; Target = $targetPath }
    }
    # -- strictness fallbacks --
    if ($Config -and $Config.modifying_strictness -eq 'loose') {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $targetPath (allowed in loose mode)"; Target = $targetPath }
    }
    if ($Config -and $Config.modifying_strictness -eq 'normal' -and -not $Config._editablePathsEnabled) {
        return [PSCustomObject]@{ Decision = 'allow'; Risk = 'low'; Reason = "$Verb $targetPath (allowed in normal mode)"; Target = $targetPath }
    }
    return [PSCustomObject]@{ Decision = 'ask'; Risk = 'medium'; Reason = "$Verb $targetPath (modifying)"; Target = $targetPath }
}
```

- [ ] **Step 2: Refactor `Test-RedirectionTarget` to call it (byte-identical reasons)**

In the `>>` block (Parser.ps1:1155-1184) replace the 4b/4c/4d chain (temp/system/EditableOrCwd/loose/normal/else) with:

```powershell
            $policy = Resolve-PathPolicy -Path $targetPath -Config $Config -Verb 'append redirect to'
            $result.Target = $policy.Target
            $result.Risk = $policy.Risk
            $result.Decision = $policy.Decision
            $result.Reason = $policy.Reason
```

In the `>` block (Parser.ps1:1211-1246) replace the 4b/4c/4d chain with:

```powershell
            $policy = Resolve-PathPolicy -Path $targetPath -Config $Config -Verb 'output redirect to'
            $result.Target = $policy.Target
            $result.Risk = $policy.Risk
            $result.Decision = $policy.Decision
            $result.Reason = $policy.Reason
```

**Reason-string check:** the old strings were `append redirect to X (editable path)`, `output redirect to X (allowed in loose mode)` etc. The ladder above reproduces them exactly, except old temp reason was `redirect to temp path (X) (low risk)` → new is `output redirect to X (temp path) (low risk)`. To keep byte-identical reasons, in the temp branch of `Resolve-PathPolicy` use reason format `"$Verb $targetPath (temp path) (low risk)"` and verify fullpipe stays green in Step 3 — if any reason assertion fails, adjust the temp branch format to match the old strings per verb.

- [ ] **Step 3: Verify redirect behavior byte-identical**

Run:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-normal.xml" -Strictness normal
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-strict.xml" -Strictness strict
pwsh -NoProfile -File "test/FullPipeTestRunner.ps1"
```
Expected: 20/25 (same 5 pre-existing fails) · 24/25 (same 1) · 19/19. Also run test-cases.xml + adhoc: 487/487, 94/94. Any new failure: the refactor leaked a difference — fix before continuing.

- [ ] **Step 4: Commit**

```powershell
git add src/Parser.ps1 src/ConfigLoader.ps1
git commit -m "refactor: extract Resolve-PathPolicy from redirect ladder (byte-identical)"
```

---

### Task 5: Classifier path-branch

**Files:**
- Modify: `src/HookAdapter.ps1` (extract field helper), `src/Classifier.ps1` (insert branch)

- [ ] **Step 1: Extract dot-path helper in HookAdapter.ps1**

Add before `Get-CommandFromInput`:

```powershell
function Get-InputFieldValue {
    <# Traverse a dot-path (e.g. 'tool_input.file_path') on the raw input object.
       Returns the string value, or $null if any segment is missing. #>
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
```

Then simplify `Get-CommandFromInput`'s mapping branch (HookAdapter.ps1:135-170) to use it:

```powershell
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
```

- [ ] **Step 2: Insert the path-branch in Invoke-Classify**

In `src/Classifier.ps1`, immediately after the tool-gate block (after line 261, before `STEP 1: Extract command from input`), insert:

```powershell
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
        $writePath = Get-InputFieldValue -RawInput $RawInput -FieldPath $fieldPath
        if (-not $writePath) {
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
        $policy = Resolve-PathPolicy -Path $writePath -Config $Config -Verb 'file write to'
        return (Repair-ResultProperties ([PSCustomObject]@{
            Decision    = $policy.Decision
            Reason      = $policy.Reason
            ExitCode    = if ($policy.Decision -eq "allow") { 0 } else { 2 }
            IDE         = $IDE
            ToolName    = $toolName
            Command     = $writePath
            SubResults  = @()
            IsSkipped   = $false
            IsUnknown   = $false
        }))
    }
```

Note: `Resolve-PathPolicy` lives in Parser.ps1, which is dot-loaded before Classifier.ps1 in both Hook.ps1 and TestRunner.ps1 — no new dependency.

- [ ] **Step 3: Smoke — branch is inert without config**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml" | Select-String '^Passed:'`
Expected: 94/94 (config.json has no `path_tool_mapping` yet → branch skipped). Also fullpipe 19/19.

---

### Task 6: config.json — mapping move + pattern retirement

**Files:**
- Modify: `config.json`

- [ ] **Step 1: Move the 11 path entries out of `tool_name_mapping` into new `path_tool_mapping`**

Replace the current `tool_name_mapping` block with:

```json
  "tool_name_mapping": {
    "run_in_terminal": "tool_input.command",
    "send_to_terminal": "tool_input.command",
    "Bash": "tool_input.command",
	"PowerShell": "tool_input.command"
  },

  "path_tool_mapping": {
	"Write": "tool_input.file_path",
	"Edit": "tool_input.file_path",
	"MultiEdit": "tool_input.file_path",
	"NotebookEdit": "tool_input.notebook_path",
	"create_file": "tool_input.filePath",
	"replace_string_in_file": "tool_input.filePath",
	"multi_replace_string_in_file": "tool_input.filePath",
	"insert_edit_into_file": "tool_input.filePath",
	"edit_notebook_file": "tool_input.filePath",
	"create_new_jupyter_notebook": "tool_input.filePath",
	"create_directory": "tool_input.dirPath",
	"create_new_workspace": "tool_input.workspacePath"
  },
```

- [ ] **Step 2: Retire path entries from trusted/untrusted**

Replace `trusted_pattern` with:

```json
  "trusted_pattern": [
	"^trusted_stuff\\s+$"
  ],
```

Replace `untrusted_pattern` with:

```json
  "untrusted_pattern": [
	  "^untrusted_stuff.*$",
	  "^untrusted_stuff\\s+$",
	  "^[A-Za-z]:[/\\\\](?!.*(?i:System32|Program Files)).*(?i:\\.(exe|bat|cmd|com|msi|scr))\\b.*$"
  ],
```

(Keeps: legacy scaffolding + the command-side exe asker. Removes: temp/git roots, catch-all, both traversal guards, both linux system-dir patterns.)

- [ ] **Step 3: GREEN run**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml" -Cwd "C:\git\repo"`
Expected: **67/72** (66 policy cases + 6 legacy docker, of which 5 docker fail pre-existing). Any other failure: diagnose against the §3.5 behavior table in the spec — fix code/config, not the test, unless the test contradicts the spec.

---

### Task 7: Full differential

**Files:** none

- [ ] **Step 1: Run all 9 suites**

All commands from Task 1, **except** trustedpattern now runs with `-Cwd "C:\git\repo"`.
Expected: test-cases 487/487 · adhoc 94/94 · var-assignment 63/64 · fullpath 20/20 · redirect-normal 20/25 · redirect-strict 24/25 · trustedpattern 67/72 · new-samples 14/14 · fullpipe 19/19. Everything except trustedpattern must be **byte-identical** to baseline.

- [ ] **Step 2: Commit**

```powershell
git add config.json src/Classifier.ps1 src/HookAdapter.ps1 test/test-cases.trustedpattern.xml
git commit -m "feat: path-branch — file-tool writes observe system_paths/editable_paths/CWD"
```

---

### Task 8: Docs

**Files:**
- Modify: `docs/config-json-guide.md`, `docs/trusted-untrusted-patterns.md`

- [ ] **Step 1: config-json-guide.md**

In section 5 (`trusted_pattern`/`untrusted_pattern`): state they now gate **command text only** (command shortcuts); path policy for file tools lives in `path_tool_mapping` + `system_paths`/`editable_paths`/CWD. In section 7 (`tool_name_mapping`): note path tools moved to `path_tool_mapping`. Add a short `path_tool_mapping` section: mapped string is canonicalized then decided by `Resolve-PathPolicy` ladder (temp → system → CWD → editable → loose/normal → default ask); extraction failure → ask; `edit_files`/`apply_patch` deliberately unmapped pending payload verification.

- [ ] **Step 2: trusted-untrusted-patterns.md**

Rewrite sections 3–5: the path patterns are retired (history: see `docs/superpowers/specs/2026-07-25-path-branch-design.md`); the doc keeps the gate semantics (whole-string, pre-chunking, anchoring rules) but the entry tables now list only the legacy scaffolding + the command-side exe pattern. Replace the "add a writable root" sample with: add the root to `editable_paths` (one place, honored by redirects AND file tools); residual-holes table becomes the "fixed by path-branch" table.

- [ ] **Step 3: Commit**

```powershell
git add docs/config-json-guide.md docs/trusted-untrusted-patterns.md
git commit -m "docs: unify path policy docs for path-branch"
```

---

### Task 9: Close out

- [ ] **Step 1: Update PROGRESS.md**

Mark path-branch complete (commits, suite results). Note follow-ups: `edit_files`/`apply_patch` payload-shape capture; guidance.md R7 list review (powershell.exe -File etc. unaffected).

- [ ] **Step 2: Commit PROGRESS.md**

```powershell
git add PROGRESS.md
git commit -m "docs: progress — path-branch complete"
```

---

## Self-Review Notes

- **Spec coverage:** D1 (default-ask) → Task 4 ladder final branch + Task 2 flips. D2 (shared function) → Task 4. D3 (retirement) → Task 6 Step 2. D4 (location-only) → Task 2 Step 2 case 1 + no exe logic in `Resolve-PathPolicy`. D5 (CWD rule, other projects ask) → ladder step 5 + Task 2 Step 3 cases 1-2. D6 (strictness preserved) → ladder steps 6-8 reuse existing fallbacks; redirect suites byte-identical (Task 4 Step 3, Task 7). §3.3 extraction-failure→ask → Task 5 Step 2. §3.5 table → Task 2 expectations. §3.6 tests → Tasks 2, 7. Docs (§6.4) → Task 8.
- **Deviation (documented):** spec §3.4 `edit_files`/`apply_patch` path-list iteration deferred — payload shapes unverified; tools remain intercepted and prompt (fail-safe). Noted in plan header and Task 9 PROGRESS follow-ups.
- **Type consistency:** `Resolve-PathPolicy` returns `@{Decision;Risk;Reason;Target}` everywhere used; `ConvertTo-CanonicalWritePath` returns string/$null; `Get-InputFieldValue` returns string/$null — used identically in Tasks 4-5.
