# `strictness_gated` Section + Per-Domain Strictness — Design

**Date:** 2026-07-25
**Status:** Approved (user sign-off in brainstorming session)
**Branching:** implementation branches from `master`. Config fixtures + test cases are part of this deliverable.

## 1. Background and Problem

Each domain in `config.json` (`commands.Git`, `.PowerShell`, `.Linux`, …) has `read_only` (→ allow) and `modifying` (→ ask) arrays. There is no middle tier: a command that is *technically* modifying but usually safe to allow (e.g. `git add`) must live in `read_only` — where it allows in **every** mode, including `strict`. There is no way to say "allow this normally, but prompt under `strict`."

Separately, `modifying_strictness` is a single **global** value applied to all domains at once. There is no way to make Git strict while PowerShell stays normal.

## 2. Locked Decisions

| # | Decision | Choice |
|---|---|---|
| L1 | New section name | **`strictness_gated`** |
| L2 | Scope | Third section **and** per-domain strictness |
| L3 | Guard precedence | **global `strict`/`loose` forces all domains; global `normal` defers to each domain's own strictness** |
| L4 | Strictness reach | `strictness_gated` **and** AWS flag-stripping **and** `parameter_commands` use effective strictness; **path policy stays global** (cross-domain) |
| L5 | Testing | separate test config fixtures via a new `-ConfigPath` TestRunner param; the live `config.json` is never modified by feature tests |

## 3. Design

### 3.1 Config schema

```jsonc
"Git": {
  "modifying_strictness": "strict",        // optional; consulted ONLY when global == "normal"
  "read_only":  [ /* truly read-only: git status, log, diff, show, branch/tag/remote list, fetch, ls-remote, ls-files, check-ignore */ ],
  "strictness_gated": [                     // NEW — allow normally, ask when effective strictness is "strict"
    { "name": "git add", "patterns": ["git add*", "git add *"], "risk": "low", "description": "Stage file changes" }
  ],
  "modifying": [ /* git push, merge, rebase, reset, clean, checkout, restore, branch -D, remote modify, worktree remove/prune/… */ ]
}
```

`strictness_gated` entries use the same shape as `read_only`/`modifying` (`name`/`patterns`/`risk`/`description`). ConfigLoader compiles their `_compiledPatterns` the same way. `risk` is what's reported when the entry prompts in `strict`.

### 3.2 Effective strictness (the guard rule)

New helper `Get-EffectiveStrictness($Config, $Domain)`:

```
if  $Config.modifying_strictness -ne 'normal'  →  return $Config.modifying_strictness   # strict forces strict, loose forces loose, ALL domains
elseif  $Config.commands.$Domain has 'modifying_strictness'  →  return that value        # per-domain applies (global is normal)
else  →  return 'normal'
```

### 3.3 Resolver integration (src/Resolver.ps1)

1. **New match step between read_only (1a) and modifying (1b):**
   ```powershell
   # Step 1a.5: strictness_gated
   if (Get-Member $domainConfig 'strictness_gated') {
       foreach ($entry in $domainConfig.strictness_gated) {
           foreach ($regex in $entry._compiledPatterns) {
               if ($regex.IsMatch($Command)) {
                   $eff = Get-EffectiveStrictness -Config $Config -Domain $domainKey
                   if ($eff -eq 'strict') { return ask (Reason $entry.name, Risk $entry.risk) }
                   else                   { return allow (Reason "$($entry.name) (strictness-gated)") }
               }
           }
       }
   }
   ```
2. **AWS flag-stripping (Resolver:180):** `$Config.modifying_strictness -eq 'normal'` → `(Get-EffectiveStrictness -Config $Config -Domain 'aws_cli') -eq 'normal'`.
3. **parameter_commands unrecognized-value (Resolver:890):** `$Config.modifying_strictness -ne 'loose'` → `(Get-EffectiveStrictness -Config $Config -Domain $domainKey) -ne 'loose'`.
4. **Path policy (`Resolve-PathPolicy`):** unchanged — stays on global `modifying_strictness`.

### 3.4 ConfigLoader changes (src/ConfigLoader.ps1)

- Extend the pattern-compilation loop to also compile each domain's `strictness_gated` entries' `_compiledPatterns` (and validate their regexes, same as `read_only`/`modifying` — invalid regex still fails config load fail-closed).
- Validate each domain's optional `modifying_strictness` ∈ {`strict`,`normal`,`loose`} when present. Absent = inherit via §3.2 (no default written).

### 3.5 Entries moved (read_only-with-risk → strictness_gated)

These are `read_only` entries carrying a `risk` attr (i.e. "modifying but allow") — exactly the middle tier's purpose. In `normal` they still allow (**byte-identical**); in `strict` they now ask.

**Git (10):** `git pull`, `git switch`, `git init`, `git clone`, `git tag -d`, `git add`, `git worktree add`, `git commit`, `git rev-parse`, `git stash`.

**Linux (1, cross-domain isolation demo):** `printf` (already `read_only` with `risk: low`).

No per-domain `modifying_strictness` is set in the shipped config (all domains inherit `normal`), so **default behavior is unchanged**.

## 4. Behavior Impact

| Scenario | Before | After |
|---|---|---|
| `git add` in `normal`/`loose` | allow (read_only) | allow (strictness_gated) — **unchanged** |
| `git add` in `strict` | allow (read_only) | **ask** (strictness_gated) — new |
| `git add` with `commands.Git.modifying_strictness=strict`, global `normal` | allow | **ask** — new per-domain capability |
| `printf` with Git strict, global normal | allow | allow (Linux inherits normal — isolation) |
| `git status` any mode | allow (read_only) | allow — unchanged |
| AWS flag-strip / param_commands | global | honor domain effective strictness (only differs when a domain sets its own strictness) |
| redirect / file-tool path policy | global | global — unchanged |

`var-assignment #14` (`$x = git add .` expects ask) stays a pre-existing fail in `normal` (still allows); it would **pass** under `strict`.

## 5. Testing Strategy (fixtures + cases — part of this deliverable)

### 5.1 TestRunner `-ConfigPath`

Add `[string]$ConfigPath = ""` param; when non-empty, `Load-Config -Path $ConfigPath` instead of the default `$PSScriptRoot\..\config.json`. Backward compatible.

### 5.2 Test config fixtures (`test/config/`)

- **`config.git-strict.json`** — post-feature `config.json` **plus** `commands.Git.modifying_strictness = "strict"`. Used to prove per-domain override *without* shipping it (shipping it would flip `git add → allow` cases and break the normal-mode differential).
- `config.aws-strict.json` — optional, for AWS reach multi-angle coverage.

The live `config.json` is **never** modified by feature tests (isolation from the fail-closed deadlocks seen this session).

### 5.3 New suite files (one per scenario; redirect-suite pattern)

| Suite file | Invocation | Expectation |
|---|---|---|
| `test/test-cases.strictness-gated.normal.xml` | default config, normal | all gated → **allow**; read_only → allow |
| `test/test-cases.strictness-gated.strict.xml` | default config, `-Strictness strict` | gated → **ask**; read_only → allow |
| `test/test-cases.strictness-gated.git-strict.xml` | `-ConfigPath test/config/config.git-strict.json` | git gated → **ask**; `printf` (Linux, normal) → **allow** (isolation); read_only → allow |

All three must pass 100% and are added to the differential run.

### 5.4 Regression gate

- All existing suites **byte-identical** (normal mode): test-cases 664/665 (1 pre-existing git-add fail), adhoc 94/94, fullpath 20/20, new-samples 14/14, redirect-normal 20/25, redirect-strict 24/25, trustedpattern 69/74, var-assignment 63/64, fullpipe 19/19.
- **Verify redirect-strict** contains none of the moved Git entries expecting allow (it runs under `strict`; if it does, they now ask — reconcile before shipping).

## 6. Out of Scope

- Conditional **verb** tiers (e.g. `Set-*` asks only in strict) — `strictness_gated` is for explicit command patterns only.
- Per-domain strictness for the **path policy** (cross-domain by nature).
- A catch-all "loose tier" that downgrades `modifying` → allow (the reverse direction).

## 7. Success Criteria

1. `strictness_gated` matches allow in normal/loose and ask in strict, per the §3.2 guard.
2. Per-domain strictness works (`Git=strict` asks Git gated while other domains stay normal), with global strict/loose forcing all.
3. Normal-mode behavior byte-identical across all existing suites; the three new strictness-gated suites pass 100%.
4. Live `config.json` untouched by feature tests; fixtures live under `test/config/`.
5. Docs updated: `config-json-guide.md` (new section + guard rule), trusted-untrusted doc cross-reference.
