# Update 2026-09-16 — parameter_commands subcommand framework + git migration

Status: **IMPLEMENTED (2026-09-16)** — SPEC v3 FINAL, all open items closed by user round 2 (§12). Red/green TDD completed on branch `parameter_commands_rework`: RED confirmed (git-param normal 6 fails, strict 2 fails, llm-review SwitchTrueSuppresses fail), GREEN all pass (26/26, 10/10, 45/45), full regression **1305/1305**. Post-review correction: the no-positional fallback was tightened so flags-without-subcommand fails closed to ask (only truly-bare `git` allows via usage); the two pre-existing flag-only cases keep their original `ask` expectation (see §9 regression note).

## 1. Background / problem

Production log 2026-09-16 12:57: `git --no-pager log -1 --format=%B` forced ask
(tier `unregistered`, "git subcommand 'log' not registered (fail-closed)").

Root cause: all Git tier patterns are start-anchored (`"git log*"` → `^git log.*`).
A global flag between `git` and the subcommand breaks every pattern. Step 0d
(Resolver.ps1) strips only `-C/-c/--git-dir/--work-tree/--namespace/--exec-path` —
`--no-pager` is not in that list, so it survives into matching and kills the anchor.

The config-only fix (regex patterns tolerating flags) was rejected: it cannot
generally distinguish "flag with value" from "positional arg", and the user wants a
**general, extensible mechanism** for many future external tools — not a git-specific
pattern hack.

## 2. Goals / non-goals

Goals:
- Extend `parameter_commands` (currently flag-only: curl/python) so an entry can also
  classify by **subcommand** (first positional) and **compound** conditions
  (subcommand + flag), with flags allowed anywhere in the command line.
- Add a `strictness_gated` rule decision, honoring global/per-domain/entry strictness.
- Add LLM switch `llm_second_opinion.strict_gate_override_llm` (default false).
- Migrate git from its own domain tier lists to `Linux.parameter_commands.git`
  (git becomes "just another tool name" — the pilot for merging all external tools).

Non-goals (this phase):
- No `/flag` (DOS) support in the new framework. The pre-existing DOS branch in
  `Get-ShellParameterMap` (flag *rules*) is untouched; the subcommand walker treats
  `/`-tokens as **positionals**. Accepted limitation: path-first Linux tools
  (`mytool /var/data backup`) fail closed to ask — never a false allow.
- No migration of terraform/docker/kubectl yet (phases 2–3, same pattern).
- No rename of the `Linux` domain section (phase 4, cosmetic).

## 3. Schema (additive — curl/python entries stay byte-compatible)

Location: `commands.Linux.parameter_commands.<tool>` after git migration.

```jsonc
"git": {
  // NEW, optional: per-entry strictness mode ("strict"|"normal"|"loose").
  // Guard semantics identical to domain/global level: a global 'strict' or 'loose'
  // FORCES this entry; the entry value is consulted only when global is 'normal'.
  // Absent => inherit the owning domain's modifying_strictness (then global).
  "modifying_strictness": "normal",

  // NEW, optional: flags that consume the following token as their value.
  // Dash forms only (-x / --x). Undeclared leading flags are boolean (no value).
  "global_value_flags": ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"],

  "rules": [
    // Form A — subcommand rule: phrase(s) match the PREFIX of the positional
    // sequence (case-insensitive, multi-word OK).
    { "subcommand": ["status","log","diff","show","blame","ls-files","ls-tree","ls-remote","check-ignore","fetch"], "decision": "read-only" },

    // Form B — compound rule: subcommand prefix AND flag condition.
    { "subcommand": ["branch"], "param": ["-d","--delete","-D","-m","--move"], "match": "present", "decision": "modifying", "risk": "medium" },

    // Form C — existing flag-only rule (unchanged semantics).
    { "param": ["--version","-v"], "match": "present", "decision": "read-only" }
  ],

  // Entry default: 'read-only' | 'modifying' (validator-enforced, unchanged).
  // For subcommand-rule entries it is VESTIGIAL-but-required: with the section-5
  // order, every reachable no-match path is decided by the usage rule (no
  // positional => allow) or the unregistered fallback (positional => ask), so
  // `default` is only reached if a future eval-order change exposes it. Set to
  // 'read-only' for git; the validator still requires the key on every entry.
  "default": "read-only"
}
```

Rule decision vocabulary: `read-only | modifying | strictness_gated` (new value).
`match`: `present | values` (unchanged; `values` requires non-empty `values[]`).
**Form B + `match: values` is PERMITTED** (subcommand prefix AND flag-value
condition) — validated, framework-supported, no git rule uses it this phase.

### 3a. `global_value_flags` matching semantics (pinned)

- **Exact token equality**, case-insensitive, against the raw token. A value
  attached with `=` (`--git-dir=C:\x`) is ONE token that does not equal
  `--git-dir` → treated as a **boolean** flag → no value consumed. This is
  inherently safe: the value stays glued to the flag and can never be mistaken
  for a subcommand.
- **Undeclared flags are boolean.** Their following token is NOT consumed, so it
  becomes a positional → if it isn't a registered subcommand prefix, fail-closed
  ask (safe direction; pinned by test `git --undeclared-flag somevalue`).

## 4. Subcommand detection (deterministic tokenizer walk — no regex backtracking)

In `Get-ShellParameterMap`, before the existing flag loop, **only for entries that
declare at least one `subcommand` rule** (opt-in; curl/python flows unchanged):

1. Walk tokens from position 1 (program token is position 0).
2. Dash-tokens (`-x`, `--x`) are skipped as flags. If a dash-token is in
   `global_value_flags`, skip it **plus its next token unconditionally** (the value —
   this is what makes `git -C /path status` work; the walker's own rule, separate
   from the flag-map's `^[-/]` consumption guard which stays unchanged).
3. First non-dash token = subcommand. **All** remaining positional tokens are
   collected in order into a reserved `_positionals` list (the subcommand is
   `_positionals[0]`).
4. A phrase matches iff it equals the **prefix** of `_positionals`
   (case-insensitive). `log` matches `[log, -1...]`? No — flags are not positionals;
   `_positionals` for `git --no-pager log -1 --format=%B` is `[log]`.
   `worktree list` matches `_positionals = [worktree, list]`.
5. `git branch --delete log 1` → `_positionals = [branch, log, 1]`: phrase `log`
   ≠ prefix (`branch`) → no read-only match; compound `branch` + `--delete` present
   → modifying. (The user's misclassification concern — pinned by tests.)

Flag *rules* (Form C) still evaluate against the existing flag map, which is built
by the unchanged loop (long/short/DOS forms, value consumption per declared
`values` rules). Subcommand detection and flag-map building share one token walk.

## 5. Evaluation order (extends the existing fail-safe convention)

**Design rule (review point 1): ALL modifying AND strictness_gated rules —
compound, subcommand, and flag-only — outrank every read-only rule.** A read-only
subcommand match never short-circuits
before a modifying/gated flag has been checked, so `git diff --output=C:\path` is
caught by the `--output` GATED flag rule even though `diff` is a read-only
subcommand (allow in normal, ask in strict — stricter than today's tier patterns
in strict mode; an intentional improvement over parity, not a residual).

1. **Modifying rules** (compound + subcommand + flag-only, in config order): any
   match → ask. **Tier stamped: `modifying`** (review point 3; consistent with
   existing flag-rule modifying results; LLM merge always vetoes this tier — correct).
2. **Strictness_gated rules** (compound + subcommand + flag-only): effective mode
   = entry `modifying_strictness` (if set) else domain `modifying_strictness` else
   global — with the standing guard that a global `strict`/`loose` FORCES all.
   strict → ask (entry/rule risk); else allow. **Tier stamped: `strictness_gated`.**
3. **Read-only rules** (compound + subcommand + flag-only): any match → allow,
   tier `read_only` for subcommand/compound matches, `param_rule` for flag-only
   matches (existing behavior preserved).
4. No match:
   - **No positional seen AND no flags seen** (truly bare, e.g. `git`): **allow** —
     usage/help semantics. Scoped to entries that declare subcommand rules, so
     `python` (no subcommand rules; bare = interactive REPL) keeps its
     `default: modifying`.
   - **No positional seen BUT flags were seen** (e.g. `git --online -3`,
     `git -C C:\repo --online -3`): ask, tier `unregistered`, reason
     `git invoked with flags but no recognized subcommand (fail-closed)`. Flags
     alone cannot be positively classified as safe — an unrecognized flag may carry
     a value that changes behavior, and there is no subcommand to anchor the
     classification. (Post-review correction: the initial GREEN pass allowed any
     no-positional invocation; review showed flags-without-subcommand must fail closed.)
   - **Positional seen**: ask, tier `unregistered`, reason
     `git subcommand '<first positional>' not registered (fail-closed)` —
     identical text/tier to today's Resolver.ps1 line-801 fallback, so
     `check_blindspot` LLM behavior for unknown git subcommands is preserved.

Note: the existing flag-only "unrecognized value-taking flag → ask" check stays
inside step 3's flag-rule evaluation (unchanged from today's
`Evaluate-ParameterRules`), but only runs if no modifying rule already fired —
which it always would, since unrecognized-value asks are fail-closed anyway.

## 6. New LLM switch: `llm_second_opinion.strict_gate_override_llm`

```jsonc
"llm_second_opinion": { ..., "strict_gate_override_llm": false }   // NEW, default false
```

Attributed (V2) merge loop only. For a flagged sub-command with tier
`strictness_gated`:

| Switch | Outcome |
|---|---|
| `false` (default) | **Today's behavior unchanged**: path guard (`Test-GatedInvocationSafe`) decides — passes → suppressed/stays allow; fails → forced ask. |
| `true` | **Unconditional suppression**, exactly like `trusted_program` — path guard bypassed, local decision stands. |

Scope notes:
- Governs ALL `strictness_gated` results (tier list + new param rules) — same tier,
  same contract.
- No-op in V1 mode (`attributed_verdicts: false` = full veto, nothing suppressible).
- Never affects LLM-DOWN / LLM-UNUSABLE (unreachable/unparseable LLM still forces ask
  — that is not a disagreement).
- `trusted_program` and index-0 handling unchanged.

## 7. Code changes

| File | Change |
|---|---|
| `src/ConfigLoader.ps1` (~line 478) | Validate: rule forms (A: non-empty `subcommand[]`; B: both `subcommand[]` and `param`; C: unchanged); `decision` vocabulary += `strictness_gated`; `global_value_flags` = string array of dash-tokens; entry `modifying_strictness` ∈ strict/normal/loose. Parse `strict_gate_override_llm` (bool, default false) into `_compiled.llmSecondOpinion`. |
| `src/Resolver.ps1` `Get-ShellParameterMap` (~line 999) | Subcommand/positionals capture per section 4, gated on entry having subcommand rules. Flag-map loop unchanged. |
| `src/Resolver.ps1` `Evaluate-ParameterRules` (~line 1090) | New rule forms + evaluation order (section 5); `strictness_gated` branch via new effective-strictness helper that includes the entry level; unregistered-subcommand fallback; bare→allow. |
| `src/Resolver.ps1` `Get-EffectiveStrictness` (~line 23) | Extend (or add sibling) to accept an optional entry-level value: global forces → entry → domain → 'normal'. Existing callers unaffected. |
| `src/LlmReview.ps1` (attributed merge, ~line 840) | Switch check before the path-guard branch for gated sub-commands. Reads `$Config._compiled.llmSecondOpinion.StrictGateOverrideLlm`. |
| `src/Parser.ps1` line 33 | **Remove** `@{ Pattern = '^git\b'; Domain = 'git' }` from `$script:KnownBinaryPrefixes`. `git ...` now falls through to the `linux` domain; Step 7 finds `Linux.parameter_commands.git`. (Config's `known_command_prefixes` list KEEPS `"git"` — different mechanism, used by HookAdapter command extraction.) |
| `src/Resolver.ps1` Step 0d (~line 196) | **REMOVE** the git global-flag stripping block (user decision: peel it now). Never fires once the domain is `linux`; fully superseded by `global_value_flags` (and it handled `--no-pager` worse than the new walker). |
| `src/Resolver.ps1` line ~801 | **Trim `'git'`** from the unregistered-subcommand fallback's domain list (user decision: trim now) → `@('docker','kubernetes','terraform')`. Git no longer reaches this branch; the new framework produces its own equivalent message. |
| `test/config/llm-review/Run-Tests.ps1` (~line 500) | Test-infra only: per-case `strict_gate_override="true\|false"` attribute → sets `$llmCfg.StrictGateOverrideLlm` (Add-Member -Force, same pattern as the existing `AttributedVerdicts` per-case override). Default false. |

## 8. Config migration (git tier lists → parameter_commands)

Every current Git entry maps 1:1, plus ONE new GATED flag rule (`--output`,
the first beneficiary of the section-5 "modifying/gated outrank read-only" ordering).
**Full migrated entry** (review point 4 — nothing omitted):

```jsonc
"git": {
  "modifying_strictness": "normal",
  "global_value_flags": ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"],
  "rules": [
  // --- modifying rules (evaluated FIRST: compound + subcommand + flag-only) ---
  { "subcommand": ["branch"], "param": ["-d","--delete","-D","-m","--move"], "match": "present", "decision": "modifying", "risk": "medium" },
  { "subcommand": ["push"],   "decision": "modifying", "risk": "medium" },
  { "subcommand": ["merge"],  "decision": "modifying", "risk": "medium" },
  { "subcommand": ["rebase"], "decision": "modifying", "risk": "medium" },
  { "subcommand": ["reset"],  "decision": "modifying", "risk": "high" },
  { "subcommand": ["clean"],  "decision": "modifying", "risk": "high" },
  { "subcommand": ["checkout"],"decision": "modifying", "risk": "medium" },
  { "subcommand": ["restore"],"decision": "modifying", "risk": "medium" },

  // --- strictness_gated (allow in normal/loose, ask in strict) ---
  { "subcommand": ["pull","switch","init","clone","add","commit","stash"], "decision": "strictness_gated", "risk": "low" },
  { "subcommand": ["rev-parse"], "decision": "strictness_gated", "risk": "medium" },
  { "subcommand": ["tag"], "param": ["-d","--delete"], "match": "present", "decision": "strictness_gated", "risk": "low" },
  { "subcommand": ["tag"], "param": ["-a","-s","-m"], "match": "present", "decision": "strictness_gated", "risk": "low" },
  { "subcommand": ["remote add","remote remove","remote set-url","remote rename"], "decision": "strictness_gated", "risk": "low" },
  { "subcommand": ["worktree add","worktree remove","worktree prune","worktree move","worktree lock","worktree unlock"], "decision": "strictness_gated", "risk": "low" },
  // NEW (not in old tier lists): file-writing flag on read-only subcommands.
  // GATED per user decision: allow in normal/loose, ask in strict. Fires before
  // the read-only 'diff'/'log' subcommand rules (section-5 ordering). LONG form
  // only: the flag map lowercases tokens, so short '-o' (write to file) and
  // '-O' (read-only diff ordering) collide as one key — including '-o' would
  // false-positive on `git diff -O pattern`. Short forms stay allowed (parity).
  { "param": ["--output"], "match": "present", "decision": "strictness_gated", "risk": "low" },

  // --- read-only subcommands ---
  { "subcommand": ["status","log","diff","show","blame","ls-files","ls-tree","ls-remote","check-ignore","fetch"], "decision": "read-only" },
  { "subcommand": ["branch"], "param": ["-a","-l","--list","--show-current"], "match": "present", "decision": "read-only" },
  { "subcommand": ["branch"], "decision": "read-only" },
  { "subcommand": ["tag"], "param": ["-l","--list","--sort","-n"], "match": "present", "decision": "read-only" },
  { "subcommand": ["tag"], "decision": "read-only" },
  { "subcommand": ["remote"], "decision": "read-only" },
  { "subcommand": ["worktree list"], "decision": "read-only" },

  // --- flag-only (existing form) ---
  { "param": ["--version","-v"], "match": "present", "decision": "read-only" }
]
```

Notes:
- `git fetch` stays **read-only** (user decision; preserves current policy).
- Bare `git` / flags-only → allow (usage semantics, section 5.4).
- The old `Git.read_only / strictness_gated / modifying` arrays are REMOVED
  (one mechanism per tool: Step 7 never falls through to tier lists when a
  parameter_commands entry exists — keeping both would be dead config).

### Migration target files (11 carry a Git section)

| File | Action |
|---|---|
| `config.local.json` | migrate (live, gitignored) |
| `config.json` | migrate (tracked/publishable) |
| `test/config/live/config.json` | migrate (live suites' config) |
| `test/config/live/config.strict.json` | migrate |
| `test/config/llm-review/config.json` | migrate (LLM-merge suite fixture) |
| `test/config/test-strictness-gate/normal/config.normal.json` | migrate |
| `test/config/test-strictness-gate/strict/config.strict.json` | migrate |
| `config - Copy.json`, `config.local - Copy.json` | **DO NOT touch** (user backups) |
| `test/config/llm-review/config.badlevel.json`, `config.badtype.json` | **DO NOT touch** (negative-test fixtures; intentionally invalid for other fields — verify they still fail for the RIGHT reason after code change) |

## 9. TDD plan (red → green → regression)

### Red — test case files (CREATED + reviewed by user round 2; RED confirmed pre-fix)

**`test/config/live/test-cases.git-param.xml`** (27 cases, normal mode; wired into
`Run-AllTests.ps1` `$suiteConfig` with `-ConfigPath test\config\live\config.json`):

| # | Command | Expected | Pins |
|---|---|---|---|
| 1 | `git --no-pager log -1 --format=%B` | allow | original production failure |
| 2 | `git -C /path status` | allow | declared value-flag + path value (walker consumption) |
| 3 | `git -c user.name=x -C "C:\Program Files\repo" log` | allow | quoted path value, multiple global flags |
| 4 | `git --git-dir=C:\x status` | allow | **=-form** value flag: exact-token match → boolean, value glued (point 5) |
| 5 | bare `git` | allow | truly-bare (no flags, no subcommand) → usage semantics |
| 6 | `git --version` | allow | matches explicit read-only flag rule (`--version`), not the fallback |
| 7 | `git status` / `git LOG --oneline` | allow | read-only subcommand; **case-insensitivity** (point 9) |
| 8 | `git branch -a` | allow | read-only compound (list flag) |
| 9 | `git worktree list` | allow | multi-word phrase |
| 10 | `git tag -l` / `git fetch origin` | allow | read-only compounds; fetch stays read-only |
| 11 | `git push origin main` / `git reset --hard HEAD` | ask | modifying subcommands |
| 12 | `git branch --delete log 1` | ask | user's misclassification concern: `log` is NOT the subcommand here |
| 13 | `git branch -D x` | ask | modifying compound |
| 14 | `git diff --output=C:\temp\out.txt` | allow (normal) / **ask (strict)** | **gated flag rule outranks read-only subcommand** (point 1 fix; user chose gated, decision 4a) |
| 15 | `git worktree add c:\temp\wt` / `git tag -a v1 -m "release"` / `git remote add origin url` / `git commit -m "fix bug"` | allow | gated rules in normal mode |
| 16 | `git frobnicate` | ask | unregistered subcommand, fail-closed (check_blindspot compat) |
| 17 | `git logg` | ask | **token equality**: `logg` must NOT prefix-match `log` (point 9) |
| 18 | `git --undeclared-flag somevalue` | ask | undeclared flag = boolean → value becomes positional → unregistered (point 5/9) |
| 19 | `git --online -3` | ask | **flags-without-subcommand fail-closed** (post-review correction; distinct from truly-bare `git`) |
| 20 | `/usr/bin/git status` | allow | full-path strip → linux domain → param lookup (routing change) |
| 21 | `ssh user@host "git --no-pager log"` | allow | wrapped inner command re-routed to linux |

**`test/config/live/test-cases.git-param-strict.xml`** (10 cases; wired with
`-Strictness strict` + same config — the home for all strict-mode expectations,
point 7): read-only still allows (`git status`, `git --no-pager log -1`); gated
asks (`git worktree add`, `git tag -a v1 -m "release"`, `git remote add origin url`,
`git commit -m "fix bug"`, `git add .`, **`git diff --output=C:\temp\out.txt`** —
RED pre-fix, old `git diff*` tier pattern allows even in strict); modifying asks
(`git push`); fail-closed asks (`git frobnicate`).

**`test/config/llm-review/test-cases.p2.small.xml`** (+2 cases, mock LLM):

| Case | Setup | Expected |
|---|---|---|
| `P2-GateOverride-DefaultDenies` | gated sub flagged (idx:2), switch absent, path guard DENIES (`git commit -m "x" C:\Windows\a.txt` — system-path token) | ask (veto). Guard case: passes pre AND post; pins default = today's reconciliation. |
| `P2-GateOverride-SwitchTrueSuppresses` | same command, `strict_gate_override="true"` | allow (unconditional suppression, trusted_program-style). **RED pre-fix** (attribute not yet read by runner/merge). |

Switch-false + safe-path → suppressed is already pinned by the existing
`P2-GateBothSuppressed` case (no new case needed).

### Green (DONE)
Implemented section 7 changes (incl. the Run-Tests.ps1 per-case switch attribute);
migrated configs per section 8 (7 files; live copies regenerated via Sync-Fixtures.ps1).
All red cases pass: git-param normal **26/26**, strict **10/10**, llm-review small **45/45**.

### Regression — expectation audit (point 6) — DONE, 1305/1305
Verified: **TestRunner asserts Decision only** (`$result.Decision -eq $tc.expected`,
TestRunner.ps1 line 142). The XML `reason=` attribute is documentation, NOT an
assertion; tier/reason text changes do not break live suites. Existing git cases in
`test-cases.xml` / strictness-gate suites keep their decisions under the 1:1 rule
mapping (spot-checked: `git status`, `git log --oneline -5`, `git fetch origin`,
`git push`, `git reset --hard HEAD`, `$x = git add .`). The llm-review suite DOES
assert `reason-contains` markers — audited during green; impact: none (markers
reference command text, not tier labels). Full `Run-AllTests.ps1`: **1305/1305**.

**No expectation change to the two flag-only cases (post-review correction):** two pre-existing
cases in `test-cases.xml` — `git -C C:\repo --online -3` (DOS-Git-Unknown) and `git --online -3`
(AST-Arbiter-Guard) — are **flag-only** invocations with no positional subcommand token. They
were temporarily flipped to `expected="allow"` during the first GREEN pass (when the step-4
fallback allowed any no-positional invocation). Review showed that is wrong: these are invalid
commands (`--online` is not a git option; there is no subcommand), and flags-without-subcommand
cannot be positively classified as safe, so they must fail closed. The fallback was corrected to
distinguish truly-bare (`git`, no flags → allow via usage) from flags-seen-but-no-subcommand
(→ ask, tier `unregistered`), and both cases were **reverted to their original `expected="ask"`**.
Genuine unknown-subcommand ask coverage is preserved by the new git-param suite
(`git frobnicate`, `git logg`). curl/python parameter_commands behavior byte-identical;
ssh-wrapped git, PowerShell-wrapper git, pipeline segments, strictness-gate suites, llm-review
phase-I + check-blindspot suites all green. Negative fixtures (`config.badlevel/badtype`) still
rejected for their original reasons.

## 10. Risks / accepted residuals

- **Routing change is global to git**: every `git ...` command now classifies via
  Step 7 instead of Git-domain tier lists. Mitigated by the 1:1 rule mapping + full
  regression run. Revert = restore one Parser.ps1 line + config sections.
- **Per-domain strictness granularity**: preserved at entry level (section 3), so no
  practical loss. If a future tool needs per-SUBCOMMAND strictness, that's a later
  extension (rule-level `modifying_strictness` — not in this phase).
- **Path-first Linux tools** cannot use subcommand rules (fail closed to ask).
  Accepted; git is unaffected (paths come after the subcommand).
- **`/` tokens as positionals**: a leading `/tmp/foo` arg reads as the subcommand →
  unregistered ask. Fail-closed direction only.
- **Short-flag case collision** (flag map lowercases): `-o` vs `-O` in git are one
  key. The new `--output` GATED rule deliberately uses the LONG form only;
  short-form file-write flags on read-only subcommands stay allowed (parity with
  today). Future tools with colliding short flags should use long forms in rules.

## 11. Review resolutions (2026-09-16, user review of v1 spec)

| # | Point raised | Resolution |
|---|---|---|
| 1 | Read-only subcommand rules bypass flag evaluation | **Fixed**: all modifying AND gated rules (compound + flag-only) outrank every read-only rule (§5). New `--output` GATED rule is the first beneficiary; normal-suite test expects allow, strict-suite test expects ask. |
| 2 | `default` key effectively dead for subcommand entries | Documented as vestigial-but-required-by-validator (§3); reachable only via a future eval-order change. Git sets `read-only`. |
| 3 | Tier for modifying subcommand matches unspecified | Pinned: `Tier = 'modifying'` (§5 step 1). |
| 4 | §8 snippet incomplete | Full entry shown incl. `modifying_strictness`, `global_value_flags`, `default` (§8). |
| 5 | `=`-form + undeclared-flag semantics unstated | Pinned: exact-token equality; `=`-attached values inherently safe; undeclared flags boolean → value becomes positional → fail-closed ask (§3a). Tests 4, 18 pin both. |
| 6 | Existing git test expectations may break | Verified TestRunner asserts Decision only (not reason/tier); XML `reason=` is documentation. llm-review `reason-contains` markers audited during green (§9 regression). |
| 7 | Strict-mode wiring for dual-expectation tests | New suite `test-cases.git-param-strict.xml` with `-Strictness strict` (§9). |
| 8 | Compound + `match: values` permitted? | **Permitted** and validated; no git rule uses it this phase (§3). |
| 9 | Missing test cases (token equality, case-insensitivity, =-form, undeclared flag) | All four added to the normal suite (tests 4, 7, 17, 18). |

## 12. Final decisions (user round 2, 2026-09-16 — all open items closed)

1. **Entry key name**: `modifying_strictness` — confirmed by user.
2. **Step 0d dead code**: REMOVED in this phase (user: "peel the card off the fridge now"). See §7.
3. **Line-801 domain list**: `'git'` trimmed NOW → `@('docker','kubernetes','terraform')`. See §7.
4a. **`--output` rule**: user chose **gated** (not modifying): `{ "param": ["--output"], "match": "present", "decision": "strictness_gated", "risk": "low" }`. Allow in normal/loose, ask in strict; still fires before the read-only `diff` subcommand rule. Long form only (`-o`/`-O` lowercase collision). Tests: normal suite expects **allow**; strict suite expects **ask** (RED pre-fix — old `git diff*` tier pattern allows even in strict).
4b. **`git logg`**: NO config entry needed — the framework is allowlist-based; anything not listed is fail-closed ask by default (typos like `logg`, `stauts`, `pussh` all ask for free). The test case exercises the unregistered fallback, not a specific rule.

## 13. Roadmap (phases)

Branch: `parameter_commands_rework` (cut from `feature_fix`, 2026-09-16).

| Phase | Scope | Status |
|---|---|---|
| 1 | This spec: framework + git migration + switch | **DONE (2026-09-16)** — implemented, red/green TDD complete, full regression 1305/1305 |
| 2 | terraform → `Linux.parameter_commands.terraform`; remove `^terraform\b` routing; drop Terraform section | planned |
| 3 | docker, kubernetes (+helm), npm, gh, ... same pattern | planned |
| 4 | Rename `Linux` domain section to a neutral name (e.g. `ExternalTools`) | planned, cosmetic |
