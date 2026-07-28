# test-strictness-gate — the "all-gated" config sandbox

> **Restored 2026-07-28** after an unconfirmed deletion — content identical to the
> 2026-07-27 "good shape" state. Note: since then the all-gated config was promoted
> to the repo-root `config.json` (see `test/config/live/`), so this sandbox now
> mirrors live behavior; it is kept for isolated normal/strict fixture testing.

Self-contained preview of "what if every domain gated its low-risk commands": **every command
domain gets a `strictness_gated` tier, and every `"risk": "low"` entry moves from
`modifying` into it** (allow in normal/loose, ask in strict).

## Layout

Split by config — each suite sits beside the config that drives it:

```
test-strictness-gate/
  Run-Tests.ps1            one-shot runner (exit 0 = fully green)
  README.md
  normal/
    config.normal.json     copy of live config (incl. git tag create gated) with the
                           low-risk moves applied to all 8 domains; Docker's gated
                           tier is intentionally empty (no low-risk entries)
    test-cases.xml                   main suite duplicate (701)
    test-cases.strictness-gated.normal.xml   (48)
    test-cases.strictness-gated.strict.xml   (49; runs config.normal.json + -Strictness strict)
    test-cases.trustedpattern.xml            (74; runs config.normal.json + -Cwd C:\git\repo)
  strict/
    config.strict.json     same + global strict, editable_paths.linux reduced to /tmp/
    test-cases.redirect-strict.xml           (25)
```

`test-fullpipe.xml` is deliberately **not** duplicated: it spawns `Hook.ps1` per
case, which always loads the live `config.json` and cannot be pointed here.

The per-domain `config.git-strict.json` fixture and its suite were **retired**
(user decision — per-domain strictness reach is out of scope here). Its one
non-duplicate, still-valid case (`git tag -a`) was merged into
`test-cases.strictness-gated.strict.xml`; its per-domain *isolation* cases were
dropped because they are invalid under global strict.

## How strict mode is tested without a strict config file

The SG-strict suite runs `normal/config.normal.json` with `-Strictness strict`:
TestRunner.ps1 loads the config, then overrides the **global**
`modifying_strictness` in memory — and global strict forces every domain. So for
command tiers a strict config file is unnecessary. `strict/config.strict.json`
exists only because the redirect suite additionally needs the
`editable_paths.linux` divergence (/home + ~ removed), which a flag cannot express.

## Run

```
powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1
```

Current state: **897/897 green** (main 701, SG-normal 48, SG-strict 49,
redirect-strict 25, trustedpattern 74).

## What changed in the duplicates vs the originals

- **test-cases.xml** — 29 cases flipped `ask` → `allow` (normal mode): every case
  whose command moved to `strictness_gated` (DOS mkdir; PS New-Item/Copy-Item/
  Move-Item/Rename-Item/Set-Content/Add-Content/Out-File; Linux mkdir/ln/unzip/
  gradlew/adb install/push/shell am start/logcat -c; git worktree remove/prune,
  git tag -a; terraform fmt/init; two ssh-inner-mkdir cases). Reason strings read
  `gated: ... (allow in normal)`.
- **SG normal/strict** — extended with per-domain gated coverage (PS, Linux,
  Git, Terraform, Kubernetes, AWS) + a Docker control (`docker start` still asks;
  empty gated tier).
- **trustedpattern** — one case flipped: `Set-Content C:\Windows\x.txt` now
  **allows** in normal (gated cmdlet; cmdlet arguments are never path-checked —
  path policy covers only redirects and file tools). This is the headline
  trade-off of the all-gated idea; strict mode still asks.
- **redirect-strict** — unchanged (path policy is independent of command tiers).

## Documented quirks surfaced by this sandbox

1. `terraform providers mirror` allows in **every** mode: the read_only pattern
   `^terraform providers` prefix-matches before the gated tier is consulted.
   Pre-existing shadowing, also in the live config.
2. DOS `move` / `ren` / `setx` still ask as "unknown command": they are not in
   the parser's DOS-marker list, so they route to the `linux` fallback domain
   and match nothing. The DOS_CMD gated entries only fire for DOS-routed
   commands. Pre-existing routing gap, not caused by the move.

## Regenerating

If the live `config.json` changes, re-copy it over this folder's two JSON files
(`normal/config.normal.json`, `strict/config.strict.json`), re-apply the moves +
the strict-fixture transformation (the `_comment_fixture` fields say what each
file is), then re-run `Run-Tests.ps1`.
