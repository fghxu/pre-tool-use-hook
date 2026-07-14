# Update — June 17, 2026: Full-Path Command Stripping

## Problem

AI coding assistants sometimes generate commands with full filesystem paths to executables instead of bare program names:

- **Windows**: `C:\Windows\System32\findstr.exe foo`, `"C:\Program Files\Git\bin\git.exe" pull origin main`
- **Linux**: `/usr/bin/grep pattern file.txt`, `/opt/custom/bin/tool status`

These commands fall through to `unknown command` and require manual approval, even when the underlying program (e.g., `findstr`, `grep`, `git`) has a known classification. This creates unnecessary approval fatigue.

The same pattern occurs inside **SSH** and **PowerShell remoting** wrappers:

- `ssh user@host "/usr/bin/grep pattern file.txt"`
- `ssh user@host "C:\Windows\System32\findstr.exe foo"`
- `Invoke-Command -ScriptBlock { & "C:\Program Files\tool.exe" }`
- `pwsh -Command "/bin/systemctl status nginx"`

## Root Cause

The classification pipeline (`Resolver.ps1`) matches commands by their **first token** against known prefixes (e.g., `git`, `docker`, `grep`). When the first token is a full path like `C:\Windows\System32\findstr.exe` or `/usr/bin/grep`, the prefix lookup fails and the command falls through to the `unknown command` fallback.

## Solution

Add a new **Step 0f: Full-path stripping** in `Resolver.ps1`, placed after the existing strip steps (sudo, git flags, AWS flags) but before pattern matching. The step detects full-path invocations, strips the directory prefix, and recurses with the bare program name.

### Pattern Detection

**Windows full path** — starts with a drive letter + colon + backslash, or a quoted path matching the same:
- `C:\path\to\program.exe args` → `program.exe args`
- `"C:\path with spaces\program.exe" args` → `program.exe args`
- `D:\tools\script.ps1 -flag value` → `script.ps1 -flag value`

Regex: `^"?[A-Za-z]:\\(?:[^\\/:*?"<>|]+\\)*[^\\/:*?"<>|]+\.(exe|com|bat|cmd|ps1)"?\s`

**Linux full path** — starts with `/` followed by directory components:
- `/usr/bin/grep pattern` → `grep pattern`
- `/opt/custom/tool status` → `tool status`

Regex: `^/(?:[^/\s]+/)+[^/\s]+`

### Extension Handling (Windows)

On Windows, executables have extensions (`.exe`, `.com`, `.bat`, `.cmd`, `.ps1`). After extracting the basename:
- **Known extensions** (`.exe`, `.com`): strip the extension — `findstr.exe` → `findstr`
- **Script extensions** (`.bat`, `.cmd`, `.ps1`): keep the extension — `deploy.ps1` → `deploy.ps1`

### Domain Re-detection

After stripping, the domain is re-detected from the bare command via `Get-CommandDomain`. This ensures `"C:\Program Files\Git\bin\git.exe" pull` correctly routes to the `Git` domain, not `DOS_CMD`.

### SSH / PowerShell Remoting

The existing nested-command extraction in `Parser.ps1` (`Find-NestedCommands`, `Get-PowerShellCommands`) already extracts inner commands from wrappers. Once the inner command is extracted, the full-path stripping step in `Resolver.ps1` handles the path normalization. No changes needed to the extraction layer.

## Test Cases

20 new test cases in `test/test-cases.adhoc.xml` covering:

| Group | Cases | Windows | Linux | Read-Only | Modifying |
|-------|-------|---------|-------|-----------|-----------|
| Windows full path (local) | 6 | ✓ | — | 3 | 3 |
| Linux full path (local) | 4 | — | ✓ | 2 | 2 |
| SSH + full path | 4 | 2 | 2 | 2 | 2 |
| PowerShell remoting + full path | 4 | 2 | 2 | 2 | 2 |
| Mixed / edge cases | 2 | ✓ | ✓ | 0 | 2 |

**Expected results:**
- `C:\Windows\System32\findstr.exe foo` → allow (findstr is read-only DOS command)
- `/usr/bin/grep pattern file.txt` → allow (grep is read-only Linux command)
- `"C:\Program Files\Git\bin\git.exe" push origin main` → ask (git push is modifying)
- `/bin/rm -rf /tmp/test` → ask (rm is modifying)
- `ssh user@host "/usr/bin/grep pattern"` → allow (inner grep read-only)
- `Invoke-Command -ScriptBlock { & "C:\tools\deploy.ps1" }` → ask (unknown ps1 script)

## Implementation Notes

- New step in `Resolver.ps1`: Step 0f, inserted after Step 0e (AWS flag stripping)
- Step applies to ALL domains (domain-agnostic, similar to variable assignment stripping)
- After stripping, domain is re-detected and `Resolve-Command` is called recursively
- If stripping produces the same command (no full path detected), the step is a no-op
- Handles both quoted (`"C:\Program Files\tool.exe"`) and unquoted (`C:\tools\tool.exe`) paths

## Files Changed

| File | Change |
|------|--------|
| `src/Resolver.ps1` | New Step 0f: full-path detection and stripping with domain re-detection |
| `test/test-cases.adhoc.xml` | Replaced SSH-Git and DOS-Git groups with full-path SSH and DOS cases (12), plus PS remoting full-path cases (8) |
| `test/test-cases.fullpath.xml` | New: 20 full-path test cases covering Windows, Linux, SSH, and PS remoting |

## Test Results (Post-Implementation)

| Suite | Cases | Result |
|-------|-------|--------|
| Classification regression (`test-cases.xml`) | 479 | 479/479 |
| Full-path (`test-cases.fullpath.xml`) | 20 | 20/20 |
| Adhoc quick suite (`test-cases.adhoc.xml`) | 20 | 20/20 |
| Codex unit (`test-cases.codex.ps1`) | 17 | 17/17 |
| Full-pipe IDE (`FullPipeTestRunner.ps1`) | 19 | 19/19 |
| **Total** | **555** | **555/555** |
