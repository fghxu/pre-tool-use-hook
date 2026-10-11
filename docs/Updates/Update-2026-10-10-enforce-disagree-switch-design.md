# Design: `llm_third_opinion.enforce_disagree` implementation (2026-10-10)

Status: **IMPLEMENTED + GREEN** (full regression 1487/1487).
Requirement doc: `docs/Updates/Update-2026-10-10-enforce-disagree-switch-spec.md`.
Parent feature: `docs/superpowers/specs/2026-09-30-llm-third-opinion-spec.md` (D5 disagree→ask,
D9 blindspot FYI) + `docs/superpowers/specs/2026-09-30-llm-third-opinion-design.md`.
User-facing reference: `docs/config-json-guide.md` §10.5.1.

## 1. Shape of the change

Three production files, one boolean threaded end-to-end:

```
config.json                 ConfigLoader.ps1              LlmReview.ps1            Logger.ps1
llm_third_opinion  ──►  EnforceDisagree (compiled)  ──►  early-return gate  ──►  RECONCILE prefix
{enforce_disagree}         default true                  +$enforceDisagree       "(not enforced)"
```

No parser/classifier/resolver changes. No new functions. The switch is a single
gate condition plus a default-true compile plus a log-render branch.

## 2. `src/ConfigLoader.ps1`

### 2.1 Validation — `Test-LlmBlockSchema` (shared by both LLM blocks)

Added after the `json_mode` check (~line 55):

```powershell
if ((Get-Member -InputObject $llm -Name 'enforce_disagree' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
    $llm.enforce_disagree -isnot [bool]) {
    throw "Configuration validation failed: '$Prefix.enforce_disagree' must be a boolean"
}
```

- Key is OPTIONAL (absence never throws) but type-checked when present.
- `Test-LlmBlockSchema` is called with prefix `llm_second_opinion` AND
  `llm_third_opinion`, so a stray/mistyped key on the second block also fails at
  load (D18.1 — "ignored keys are still validated", same as D15 for other keys).
  Only the third block's value is ever read at runtime.
- JSON `true`/`false` deserializes to `[bool]`; `"yes"`/`0`/`null` throw. Fail-closed.

### 2.2 Compile — llm_third_opinion section (~line 903)

```powershell
$l2EnforceDisagree = $true
if (Get-Member -InputObject $l2Raw -Name 'enforce_disagree' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $l2EnforceDisagree = [bool]$l2Raw.enforce_disagree }
```

and `EnforceDisagree = $l2EnforceDisagree` in `$llm2Compiled` (fields now:
`Enabled, BaseUri, Model, ApiKey, TimeoutMs, EffectiveTimeoutMs, EnforceDisagree`).

- **Default true when absent** → every pre-existing config is byte-identical in
  behavior; no fixture except the new one sets the key.
- `Get-Member -Name` presence test (not `$null -ne`) so an explicit JSON `null`
  fails validation in 2.1 rather than compiling to `$false` (`[bool]$null` is false).

## 3. `src/LlmReview.ps1` — `Invoke-LlmReview` merge (~line 1233)

The D5 disagree early-return gains one conjunct:

```powershell
$enforceDisagree = $llm2.EnforceDisagree
if ($null -ne $agree -and -not $agree -and -not $isCheckBlindspot -and $enforceDisagree) {
    # ... unchanged: compare='disagree', effect='llm2-disagree',
    #     *** LLM-DISAGREE *** reason, forced ask, return
}
```

Why this one line is sufficient:

- With `false`, the branch is skipped and control reaches the existing line
  `$log.llm2.compare = Get-LlmPairCompareState ...` — which stamps `'disagree'`
  anyway (D18.3: detect + record). `llm2.compare` is the single source of truth
  for the LLM2-RECV line and the RECONCILE prefix; nothing else needs to know the
  switch existed.
- The flow then continues into the pre-existing merge switch on `$verdict.Verdict`
  (LLM1's verdict) — literally "the regular classification decision before
  llm_third_opinion was implemented", plus today's suppression rules:
  - `modifying` → veto path (trusted_program / editable_path / gated path-guard
    suppressions re-enabled as usual) → `*** LLM-VETO ***` ask or allow.
  - `read-only` + local allow → allow (`effect='agree'`).
  - `down` / `unusable` → unchanged fail-closed forced ask.
- `$isCheckBlindspot` guard (D9) is untouched and precedes the switch in the
  condition — blindspot consults never enforced disagreement before, and still
  don't (LT3-31 passes in RED, by design).
- `$enforceDisagree` is read from the compiled `$llm2` object, so a hand-built
  `$llm2` without the property yields `$null` → falsy → would skip enforcement.
  In practice every call path goes through `Load-Config`, which always compiles
  the field (default true); tests that build `$llm2` by hand set it explicitly.
  (Deliberate: the compiled object is the contract, PF-11 pins the default.)

## 4. `src/Logger.ps1` — `Format-LlmLogBlock` (~line 294)

New RECONCILE branch, placed after the existing agree/down prefix block and
before the enforced-disagree renderer:

```powershell
if ($pairCalled -and $llm2Compare -eq 'disagree' -and "$($LlmLog.effect)" -ne 'llm2-disagree') {
    $reconPrefix = 'llm2-disagree (not enforced) | '
}
```

- The `effect -ne 'llm2-disagree'` test distinguishes *not-enforced fall-through*
  (effect is LLM1's merge outcome: `veto`, `agree`, `veto-suppressed-policy`, ...)
  from the *enforced* early-return (effect is exactly `llm2-disagree`), which
  keeps its byte-identical `disagree LLM=... vs LLM2=... -> FINAL: ask` rendering.
- LLM2-RECV line needs no change: it renders from `llm2.compare='disagree'`,
  which is stamped on both paths.

Example log with the switch off (LT3-33 pinned shape):

```
LLM2-RECV  : verdict=modifying indices=[2] (model=glm-5.3-flash)
LLM-RECONCILE : llm2-disagree (not enforced) | agree LLM=read-only -> FINAL: allow
```

## 5. Config files

| File | Value | Notes |
|---|---|---|
| `config.local.json` (live, gitignored) | `"enforce_disagree": false` | user's explicit choice; `_comment_llm_third_opinion` bullet added. Verified via `debug/_probe_enforce_disagree_live.ps1`: `Enabled=True EnforceDisagree=False` |
| `config.json` (shipped) | `"enforce_disagree": true` | explicit + `_comment_enforce_disagree` doc key explaining both modes |
| `test/config/live/*` | re-synced | `test/config/live/Sync-Fixtures.ps1` after the root change |

Hook reloads config per call — flipping the live key takes effect on the next
tool call, no restart.

## 6. Test fixtures (`test/config/llm-third-opinion/`)

- `config.pair.disagree-off.json` — copy of `config.pair.json` with
  `"enforce_disagree": false` in `llm_third_opinion`; `llm_second_opinion`
  deliberately has NO key (pins D18.1 asymmetry: validated there, read only here).
- `config.bad-disagree.json` — `"enforce_disagree": "yes"` → load must throw with
  the `llm_third_opinion.enforce_disagree` prefix.
- Preflights in `test/config/llm-review/Run-Tests.ps1`: PF-9 (bad throws),
  PF-10 (false compiles), PF-11 (absent → default true).
- XML cases in `test-cases.llm.xml`: LT3-29 (LLM1 modifying → VETO ask),
  LT3-30 (LLM1 read-only → ALLOW, no `*** LLM-DISAGREE ***`),
  LT3-31 (blindspot unchanged), LT3-32 (trusted suppression → ALLOW),
  LT3-33 (fullpipe log contains `LLM2-RECV;llm2-disagree (not enforced)`).
- Suite went 64 → 72 checks; README counts updated.

## 7. TDD record

| Step | Result | Capture |
|---|---|---|
| RED (fixtures + cases only) | 72 / 65 / **7 failed** — exactly PF-9/10/11 + LT3-29/30/32/33 (LT3-31 passes pre-change by design) | `debug/_red_enforce.txt` |
| GREEN (ConfigLoader + LlmReview + Logger) | 72 / 72 | `debug/_green_enforce.txt` |
| Full regression (`src/Run-AllTests.ps1`) | **GRAND TOTAL 1487/1487, 0 failed — OVERALL: all suites match expectations** | `debug/_full_enforce.txt` |

## 8. Operational notes / gotchas

- A log line showing `disagree ... FINAL: ask` after the feature landed is NOT a
  bug if it predates the live config edit — default `true` applies until the key
  is present in `config.local.json`.
- Agent-terminal PATH gotcha (venv activation overflow, "The filename or
  extension is too long" on `pwsh`): rebuild PATH from the registry before
  running the suite —
  `$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.
  Do NOT hand-trim PATH (TestRunner spawns `powershell.exe`; node-based runners
  need the full PATH).
- `enforce_disagree: false` weakens the pair's safety net by design (D18.3):
  LLM2's objections become advisory only. The A/B record stream
  (`records.jsonl`, `llm2.compare`) keeps accumulating so the switch can be
  re-enabled with evidence.
