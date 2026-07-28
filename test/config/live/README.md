# test/config/live — the live-config test suites

Every suite here validates the **repo-root `config.json`** (all-gated since
2026-07-27: every command domain has a `strictness_gated` tier holding its
`risk: "low"` commands — allow in normal/loose, ask in strict).

Run everything from the repo root:

```
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
pwsh -NoProfile -File test/config/live/test-cases.codex.ps1   # not in Run-AllTests
```

## Layout

| File | Invoked with | Cases |
|---|---|---|
| `test-cases.xml` | default config.json | 701 |
| `test-cases.strictness-gated.normal.xml` | default | 48 |
| `test-cases.strictness-gated.strict.xml` | `-Strictness strict` | 49 |
| `test-cases.strictness-gated.git-strict.xml` | `-ConfigPath config.git-strict.json` | 12 |
| `test-cases.redirect-strict.xml` | `-ConfigPath config.strict.json` | 25 |
| `test-cases.trustedpattern.xml` | `-Cwd C:\git\repo` | 74 |
| `test-fullpipe.xml` | FullPipeTestRunner.ps1 (spawns Hook.ps1) | 19 |
| `test-cases.codex.ps1` | standalone (pwsh) | 17 |

Fixtures (regenerate from `config.json` whenever it changes — each carries a
`_comment_fixture` saying what transformation to apply):

- `config.git-strict.json` — copy of config.json, `commands.Git.modifying_strictness = "strict"`
- `config.strict.json` — copy of config.json, global `strict`, `editable_paths.linux` = `/tmp/` only

## History

Promoted from the `test/config/test-strictness-gate/` experiment (deleted after
promotion): the all-gated config became the live config, and its adjusted
expectations (29 flips in the main suite, 1 in trustedpattern, extended SG
suites) came with it. Documented behavior: gated cmdlet file-writes
(`Set-Content`, `Out-File`, ...) are NOT path-checked — `Set-Content
C:\Windows\x.txt` allows in normal mode; strict still asks.
