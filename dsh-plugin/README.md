# dsh-plugin-pretoolhook

DeepSeek Harness bridge for the PreToolUse Hook (`src/Hook.ps1`).

Registers a `tools/pre-execute` listener on DSH's tool scheduler and gates
mapped tool calls (default map: `bash`, `pwsh`, `write`, `edit`) through
`Hook.ps1` before they execute:

| hook decision | DSH mapping |
|---|---|
| `allow` | `next()` — continue the chain (runs) |
| `ask`   | `{ kind: "ask", reason }` — DSH approval UI prompts the user |
| `deny`  | `{ kind: "deny", reason }` — tool blocked |

Fail-closed: hook errors, non-zero exits, unparseable output, timeouts, and
aborts map to `deny`. A missing/unresolvable `hookPath`, however, is a *config
error* — the plugin warns and lets tools through rather than blocking all of
them. See `docs/INSTALL.md` and `docs/Updates/DeepSeekHarness-Wiring.md`.
Full detail is in the main [INSTALL](../docs/INSTALL.md).

## Install (any machine)

This is a **bundle** package: it ships a `cordis.patch.yml` and declares
`dsh.bundle.patch`, so `dsh plugin --profile web add <pkg>` auto-enables it (no
manual patch row). The one machine-specific setting is where `Hook.ps1` lives:

```sh
# 1. Get the hook folder (src/ + config.json) and the plugin onto this machine.
git clone <your-pretoolhook-repo> C:\git\cc\pretoolhook

# 2. Install the plugin (git URL, tarball, or a file: link to dsh-plugin/).
dsh plugin --profile web add github:<you>/<plugin-repo>   # or ./pkg.tgz

# 3. Point the plugin at the hook — the DSH analog of an IDE hook-script path.
$env:PRETOOLHOOK_HOOK_PATH = 'C:\git\cc\pretoolhook\src\Hook.ps1'

# 4. Restart the harness.
dsh --profile web
```

`hookPath` resolves in this order: `config.hookPath` → `PRETOOLHOOK_HOOK_PATH`
(env) → `<plugin>/../src/Hook.ps1`. The repo-relative fallback only works for a
`file:` link to this checkout; a normal npm/git install requires the env var.

## Layout

- `index.js` — the Cordis plugin (`name` + `apply`), plus exported helpers
  (`buildHookPayload`, `parseHookOutput`, `runHook`, `resolveHookPath`) for
  testing.
- `cordis.patch.yml` — the bundle patch (auto-inserts the `pretoolhook` row).
- `test/run-tests.mjs` — checks: payload builder, fail-closed parser, and an
  end-to-end spawn contract against the real `Hook.ps1`.
- `test/Run-NodeTests.ps1` — wrapper so `src/Run-AllTests.ps1` can drive the
  node suite.

## Test

```powershell
node dsh-plugin/test/run-tests.mjs
```
