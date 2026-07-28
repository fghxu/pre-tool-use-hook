# test/config/live — the live-config test suites

Every suite here validates **`config.json` IN THIS FOLDER** — a test copy of the
repo-root `config.json`, so edits to the root config do not affect the suites
until you sync (the repo-root config is all-gated since 2026-07-27: every
command domain has a `strictness_gated` tier holding its `risk: "low"` commands).

**After editing the repo-root `config.json`:**

```
powershell.exe -ExecutionPolicy Bypass -File test/config/live/Sync-Fixtures.ps1
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
```

`test-cases.codex.ps1` is standalone (not in Run-AllTests):

```
pwsh -NoProfile -File test/config/live/test-cases.codex.ps1
```

## Layout

| File | Invoked with | Cases |
|---|---|---|
| `test-cases.xml` | `-ConfigPath config.json` | 701 |
| `test-cases.strictness-gated.normal.xml` | `-ConfigPath config.json` | 48 |
| `test-cases.strictness-gated.strict.xml` | `-ConfigPath config.json -Strictness strict` | 49 |
| `test-cases.redirect-strict.xml` | `-ConfigPath config.strict.json` | 25 |
| `test-cases.trustedpattern.xml` | `-ConfigPath config.json -Cwd C:\git\repo` | 74 |
| `test-fullpipe.xml` | FullPipeTestRunner.ps1 (spawns Hook.ps1 with `PRETOOLHOOK_CONFIG_PATH` = config.json) | 19 |
| `test-cases.codex.ps1` | standalone (pwsh), no config | 17 |

Configs (all produced by `Sync-Fixtures.ps1` from the repo-root config):

- `config.json` — the test copy (carries a `_comment_test_copy` marker)
- `config.strict.json` — test copy + global `strict`, `editable_paths.linux` = `/tmp/` only

The per-domain `config.git-strict.json` fixture and its suite were **retired**
(2026-07-28, user decision — no git-only strict testing). All its applicable
cases were already covered by `test-cases.strictness-gated.strict.xml`; the
per-domain `modifying_strictness` feature remains in the code but is no longer
covered by a suite.

## History

Promoted from the `test/config/test-strictness-gate/` experiment: the all-gated
config became the live config, and its adjusted expectations (29 flips in the
main suite, 1 in trustedpattern, extended SG suites) came with it. Documented
behavior: gated cmdlet file-writes (`Set-Content`, `Out-File`, ...) are NOT
path-checked — `Set-Content C:\Windows\x.txt` allows in normal mode; strict
still asks. (The sandbox folder was later restored at the user's request and
still exists at `test/config/test-strictness-gate/` for isolated testing.)
