# Codex CLI Support — Design Spec

**Date:** 2026-06-15
**Status:** Approved — ready for implementation plan

---

## 1. Goal

Add full support for OpenAI Codex CLI as a peer IDE alongside Claude Code and GitHub Copilot. Codex CLI uses a hook protocol similar to Claude Code but with critical differences in output decision values and input fields.

## 2. Background: Codex vs Existing IDEs

Codex CLI hooks share Claude Code's protocol (PascalCase `PreToolUse` event name, `tool_use_id` present, ISO 8601 timestamps) but differ in three key areas:

| Aspect | Claude Code | Copilot | Codex CLI |
|--------|------------|---------|-----------|
| `turn_id` field | Absent | Absent | **Present** |
| `model` field | Absent | Absent | **Present** |
| Block decision value | `"ask"` | `"ask"` | **`"deny"`** |
| `"ask"` support | Yes | Yes | **No** (parsed but errors) |
| Config format | JSON (`settings.json`) | JSON | TOML (`config.toml`) or JSON (`hooks.json`) |
| Config location | `~/.claude/` or `.claude/` | `~/.copilot/` or `.github/hooks/` | `~/.codex/` or `.codex/` |

The `"ask"` decision is parsed by Codex but unsupported — sending it marks the hook as failed and the tool call proceeds anyway. We must map `ask` → `deny` for Codex.

## 3. Design

### 3.1 IDE Detection — `Detect-IDE` (HookAdapter.ps1)

New signals added **before** the existing vote to short-circuit Codex identification:

```
Signal 5: turn_id field present → "Codex"     (decisive, return immediately)
Signal 6: model field present  → "Codex"      (decisive, return immediately)
Signal 1: hook_event_name       → Pascal=ClaudeCode, camel=Copilot
Signal 2: tool_use_id           → present=ClaudeCode, absent=Copilot
Signal 3: timestamp format      → ISO=ClaudeCode, epoch=Copilot
Signal 4: transcript_path       → copilot-chat→Copilot, .claude→ClaudeCode
Fallback: majority vote signals 1-3, tie → ClaudeCode
```

Signals 5 and 6 are decisive — they fire first and return immediately without voting.

### 3.2 Output Format — `Format-Output` (HookAdapter.ps1)

Decision mapping per IDE. The internal pipeline continues to use `allow`/`ask`. Only the output boundary translates:

| IDE | Internal `allow` | Internal `ask` |
|-----|------------------|----------------|
| ClaudeCode | `"allow"` | `"ask"` |
| Copilot | `"allow"` | `"ask"` |
| Codex | `"allow"` | **`"deny"`** |

All IDEs use the `hookSpecificOutput` wrapper format (unchanged).

### 3.3 Logging — `Logger.ps1`

Add `codex` as a third IDE suffix:

| File pattern | IDE |
|-------------|-----|
| `YYYY-MM-DD.codex.records.jsonl` | Codex JSON input records |
| `YYYY-MM-DD.codex.log` | Codex classification log |

Change: expand the existing binary conditional (`Copilot`/`claude` fallback) to include `Codex`.

### 3.4 Exit Code Fix — `Classifier.ps1` + `Hook.ps1`

**Root cause:** The current code sets exit code `2` for both "classification says block" (valid) and "hook crashed" (error). Claude Code interprets any non-zero exit as a hook failure, ignores the JSON output, and lets the tool call proceed — defeating the hook's purpose.

**Fix:** Exit code reflects hook health, not classification decision.

In `Classifier.ps1`: all non-error `ask` returns change `ExitCode` from `2` to `0`. Genuine failures (null input, null config, unknown tool, can't extract command) keep `ExitCode = 2`.

In `Hook.ps1`: timeout override result also uses `ExitCode = 0` (valid safety decision). The exit at line 139 stays `exit $classifyResult.ExitCode`.

The JSON output (`permissionDecision`) is what drives IDE behavior. Exit code only signals whether the hook itself succeeded.

### 3.5 Configuration — `config.json`

**New entries to `intercept_tool_name`:** None needed. Codex's `Bash`, `apply_patch`, and `PowerShell` are already present. No new command-executing Codex tools identified.

**New entries to `ignore_tool_name`:**
- `Agent` — subagent dispatch, no command to classify
- `ScheduleWakeup` — loop timing, no command to classify

**Moved from `intercept_tool_name` to `ignore_tool_name`:**
- `ExitPlanMode` — plan control, no shell command
- `NotebookEdit` — file editing, no shell command
- `TaskStop` — task control, no shell command

These were incorrectly placed in intercept. They'd always hit the "could not extract command" fallback and return `ask`/`deny`, blocking legitimate operations.

**`tool_name_mapping`:** No changes. `"Bash": "tool_input.command"` is already correct for Codex.

### 3.6 Installation Documentation — `INSTALL.md`

New section: **"Installing for Codex CLI"** with two config format options and the hook command.

### 3.7 README.md Update

Add Codex to the Supported IDEs table.

## 4. Test Infrastructure

### 4.1 Unit Tests: `test/test-cases.codex.ps1`

Focused unit tests for the two Codex-specific functions in HookAdapter.ps1. Runs directly against the source, no process spawning.

**Detect-IDE (7 tests):**
- Codex via `turn_id`, via `model`, via both fields
- Claude Code via `.claude` transcript_path
- Copilot CLI via camelCase + Unix epoch
- VS Code Copilot via `copilot-chat` transcript_path
- Null input edge case

**Format-Output (7 tests):**
- Codex: allow→allow, ask→deny, deny→deny + reason preserved
- ClaudeCode: allow→allow, ask→ask
- Copilot: allow→allow, ask→ask

### 4.2 Full-Pipe Integration Tests: `test/FullPipeTestRunner.ps1` + `test/test-fullpipe.xml`

A generic, data-driven runner that spawns `Hook.ps1` as a child process, pipes JSON to stdin, captures stdout + stderr + exit code, and validates the complete output. IDE-agnostic — the runner itself has no IDE-specific logic.

**XML format:**
```xml
<commands>
  <category-group name="Codex-FullPipe" ide="Codex">
    <test-case expected-decision="deny" expected-exit="0" category="Codex-FullPipe">
      <description>Stop-Process maps ask→deny, exit 0</description>
      <hook-input><![CDATA[{...full JSON payload...}]]></hook-input>
    </test-case>
  </category-group>
  <category-group name="Copilot-FullPipe" ide="Copilot">
    <!-- ... -->
  </category-group>
  <category-group name="ClaudeCode-FullPipe" ide="ClaudeCode">
    <!-- ... -->
  </category-group>
</commands>
```

Single XML file (`test-fullpipe.xml`) with one `category-group` per IDE. Each test case includes the full stdin payload (with IDE-specific fields like `turn_id`, `model`, `timestamp` format) so detection is exercised end-to-end.

**Validates per test case:**
1. Exit code matches `expected-exit` (0 = hook succeeded, 2 = genuine error)
2. `permissionDecision` matches `expected-decision` (allow/ask/deny)
3. `permissionDecisionReason` contains the expected reason substring

**Coverage per IDE (~6-8 cases each, ~20 total):**
- Read-only command → allow, exit 0
- Modifying command → ask/deny, exit 0
- Trusted pattern → allow, exit 0
- Untrusted pattern → deny/ask, exit 0
- Unknown tool → ask/deny, exit 0
- Bad JSON → error, exit 2 (genuine failure)
- (Codex only) ask→deny mapping verified
- (Codex only) turn_id detection verified (implicit in the input payload)

**Extensibility:** Adding OpenCode or a future IDE requires only adding a new `<category-group>` with its payloads to `test-fullpipe.xml`. No runner changes.

## 5. Files Changed

| File | Change |
|------|--------|
| `src/HookAdapter.ps1` | Add Codex detection (signals 5+6), add Codex decision mapping in `Format-Output` |
| `src/Classifier.ps1` | Fix ExitCode: non-error ask returns 0 instead of 2 |
| `src/Hook.ps1` | Fix timeout override ExitCode: 0 instead of 2 |
| `src/Logger.ps1` | Add `codex` log suffix |
| `config.json` | Move ExitPlanMode/NotebookEdit/TaskStop to ignore; add Agent/ScheduleWakeup to ignore |
| `README.md` | Add Codex to supported IDEs table |
| `docs/INSTALL.md` | Add Codex CLI installation section |
| `test/test-cases.codex.ps1` | New — unit tests for Detect-IDE + Format-Output (14 tests) |
| `test/FullPipeTestRunner.ps1` | New — generic data-driven full-pipe test runner |
| `test/test-fullpipe.xml` | New — full-pipe integration test cases for all IDEs (~20 cases) |
