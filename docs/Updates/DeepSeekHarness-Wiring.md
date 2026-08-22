# DeepSeek Harness Wiring — PreToolUse Hook Bridge

Date: 2026-08-XX · Status: implemented and verified in this repo + the local web profile

This hook now runs inside the **DeepSeek Harness (DSH)** — the same harness that
hosts this session — via a small Cordis plugin (`dsh-plugin-pretoolhook`) that
bridges DSH's tool scheduler onto the existing `Hook.ps1` classification
pipeline. Claude Code, Copilot (VS Code), and Codex CLI support are unchanged.

## How it fits together

```
model wants to run a tool (bash / pwsh / write / edit)
        │
        ▼
DSH tool scheduler — "tools/pre-execute" waterfall
        │  dsh-plugin-pretoolhook listener (prepend: true)
        │    • maps DSH tool name → hook tool name:
        │        bash  → Bash        (tool_input.command)
        │        pwsh  → PowerShell  (tool_input.command)
        │        write → Write       (tool_input.file_path)
        │        edit  → Edit        (tool_input.file_path)
        │    • builds a Claude Code PreToolUse-shaped payload stamped with a
        │      `dsh` field (the DeepSeek Harness request signature)
        │    • spawns  pwsh -File src\Hook.ps1  with the payload on stdin
        ▼
Hook.ps1 — full pipeline (tool filter → command/path branch → trusted/
untrusted → domain classification → LLM second opinion → ask notification)
        │  Detect-IDE sees  dsh.harness == "DeepSeek Harness"  → IDE = "DSH"
        ▼
hookSpecificOutput { permissionDecision: allow|ask|deny, reason }
        │
        ▼
bridge maps the decision onto DSH's seam:
   allow  → next()                    (continue the chain → runs)
   ask    → { kind: "ask",  reason }  (DSH approval UI prompts the user)
   deny   → { kind: "deny", reason }  (tool blocked; model sees the reason)
```

Any DSH tool **not** in the map is left to DSH's own permission/sandbox stack
(`next()`), and transport sub-dispatches (`exec.parent` set) are skipped.

## The DeepSeek Harness request signature

The bridge wraps every intercepted call in a Claude Code-shaped payload so the
existing classifier needs no changes, then stamps it with a `dsh` object:

```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "docker ps" },
  "tool_use_id": "call_xxx",
  "timestamp": "2026-08-15T12:00:00.123Z",
  "session_id": "session-…",
  "transcript_path": "…",              // only when DSH_SESSION_JSONL is set
  "dsh": {
    "harness": "DeepSeek Harness",
    "call_id": "call_xxx",
    "root_call_id": "call_xxx",
    "agent_id": "agent-…"
  }
}
```

`Detect-IDE` (HookAdapter.ps1) treats `dsh.harness == "DeepSeek Harness"` as a
**decisive** signal (checked before every other signal) and returns `"DSH"`.
No other IDE sends this field. Output/behavior for `DSH` matches Claude Code:
`ask` stays `ask` (DSH's approval seam prompts the user) — only Codex maps
`ask → deny`. Logging splits into `yyyy-MM-dd.dsh.records.jsonl` / `.dsh.log`.

## Files changed / added

| File | What |
|------|------|
| `src/HookAdapter.ps1` | `Detect-IDE` DSH signal (decisive); `Format-Output` doc for DSH |
| `src/Logger.ps1` | `dsh` per-IDE log suffix |
| `src/Hook.ps1` | header/step comments |
| `test/config/live/test-cases.dsh.ps1` | DSH unit tests (17) — detection, mapping, logging |
| `test/config/live/test-fullpipe.xml` | `DeepSeekHarness-FullPipe` group (8 cases) |
| `src/Run-AllTests.ps1` | registers the two new suites |
| `dsh-plugin/` | the Cordis bridge plugin (`index.js` + tests) |

## Plugin configuration

The plugin is a **bundle** package: `dsh-plugin/cordis.patch.yml` + a
`dsh.bundle.patch` declaration, so `dsh plugin --profile web add <pkg>`
auto-inserts the row (no manual patch row on a fresh install):

```yaml
- insert:
    - id: pretoolhook
      name: 'dsh-plugin-pretoolhook'
      config:
        enabled: true
        pwshPath: 'pwsh'
        timeoutMs: 45000
```

`hookPath` is intentionally left out of the patch — it resolves at runtime as
`config.hookPath` → `PRETOOLHOOK_HOOK_PATH` (env) → `<plugin>/../src/Hook.ps1`.

Optional config keys (see `dsh-plugin/index.js`):

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | master switch |
| `hookPath` | `PRETOOLHOOK_HOOK_PATH` or `<repo>/src/Hook.ps1` | hook script path |
| `pwshPath` | `pwsh` | PowerShell 7+ executable |
| `timeoutMs` | `45000` | hook budget; covers the hook's LLM second-opinion cap (`timeout_ms` + 2000 headroom) |
| `toolMap` | built-in map | DSH tool name → `{ tool_name, input(args) }` |
| `skipNested` | `true` | skip transport sub-dispatches |

**This instance was wired before the bundle existed**, so the web profile
here still carries a manual `- insert: id: pretoolhook` row in
`cordis.patch.yml` (with an explicit `hookPath`) plus a `file:` dependency /
junction on `dsh-plugin/`. Both work. If a later `dsh plugin add/update`
reconciles `dsh-plugin-pretoolhook` into the profile's `dsh.profile.bundles`
list, remove that manual row to avoid a duplicate loader entry.

## Installation on another machine

The `file:` link is machine-local. To install on another DSH/PC, use the
bundle flow — `dsh plugin --profile web add <git-url | tarball>` then set
`PRETOOLHOOK_HOOK_PATH` to that machine's copy of `Hook.ps1` — documented
fully in `docs/INSTALL.md` ("Installing for DeepSeek Harness").

## Activation

The plugin loads at DSH boot. **Restart the harness** (`dsh --profile web`) for
the new row to take effect — the running instance hosts this session and was
deliberately not restarted. Verify the composed tree without booting:

```
dsh --profile web --dump-config      # expect an `id: pretoolhook` row
```

## Fail-closed behavior

A hook failure can never let a gated tool run unchecked:

| Condition | Result |
|-----------|--------|
| hook exits `2` (fatal: unknown tool, no command, config error) | `deny` with the hook's stderr |
| stdout unparseable / unexpected decision | `deny` |
| `pwsh` missing / spawn failure | `deny` |
| hook exceeds `timeoutMs` | `deny` (child killed) |
| `exec.signal` aborts mid-hook | `deny` (child killed) |
| `hookPath` unresolvable | warn + allow (config error, not a security event) |

## Testing

```powershell
# hook side
pwsh -NoProfile -File test/config/live/test-cases.dsh.ps1          # 17 unit tests
pwsh -NoProfile -File test/config/live/FullPipeTestRunner.ps1      # +8 DSH full-pipe cases

# plugin side (Part B spawns the real Hook.ps1)
node dsh-plugin/test/run-tests.mjs                                 # 19 tests

# everything
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
```

Note: `FullPipeTestRunner.ps1` and the plugin's Part B spawn child processes
with redirected stdio — under the DSH file sandbox that requires
`danger-full-access` (or run them outside the harness, as the project's normal
test workflow does).
