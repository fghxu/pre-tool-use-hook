# Spec: LLM Third-Opinion Pair Comparison (`llm_third_opinion`)

**Date:** 2026-09-30
**Status:** APPROVED (grilling interview complete; all rulings user-confirmed)
**Design doc (implementation contract):** `docs/superpowers/specs/2026-09-30-llm-third-opinion-design.md`
**On any conflict between the two documents, THIS spec wins.**
**Feature name:** llm_third_opinion (a.k.a. "LLM2", "the pair", "third-opinion LLM")

---

## 1. Goal and motivation

Send the *identical* classification prompt to a **second LLM endpoint** in parallel with the existing
`llm_second_opinion` LLM ("LLM1"), compare the two parsed verdicts, and:

- **Agreement** → proceed with today's behavior exactly (LLM1's verdict vs. the local classifier).
- **Disagreement** → force `ask` (the two experts split; the human decides).

Purpose: an **A/B accuracy evaluation** of two models over real traffic, so that one of them —
explicitly the more expensive one — can be **decommissioned** later. The feature is temporary by
intent: when the evaluation concludes, the loser's config is deleted and the winner is promoted by
repointing `llm_second_opinion` at it.

Only the **parsed verdict** (`verdict=xxx` and, in attributed mode, `indices=[...]`) is compared.
The verbose prose of a response is never compared — it is only logged.

---

## 2. Decision summary

| # | Decision (short) |
|---|---|
| D1 | **Slave scope.** LLM2 fires iff LLM1 is enabled AND in scope. LLM2's own `level`, `complex_min_subcommands`, `remote_indicators`, `check_blindspot` are accepted-but-ignored; LLM1's scope config decides for the pair. |
| D2 | **LLM2 owns only endpoint identity:** `enabled`, `base_uri`, `model`, `api_key`, `timeout_ms`. The prompt/sampling keys (`attributed_verdicts`, `temperature`, `llm_response_max_tokens`, `json_mode`) are accepted-but-ignored — LLM1's values are used, guaranteeing identical prompts and a fair comparison. |
| D3 | LLM1 disabled (or block absent) + LLM2 enabled → **no LLM calls at all**; the log explicitly says LLM2 was skipped because LLM1 is disabled. |
| D4 | **Comparison = verdict token + exact index set** (order-insensitive). `[1,2,4]` vs `[2,4]` = different. V1 mode = bare token equality. `down`/`unusable` are failure states, not verdicts. |
| D5 | Comparison happens on the **raw parsed verdicts BEFORE any policy suppression** (before trusted_program / editable_path / gated path-guard overrides). **Disagreement → ask UNCONDITIONALLY**, even when the contested indices are trusted/editable territory. |
| D6 | On agreement, **LLM1's verdict object drives the existing merge**; LLM2 never touches the veto/suppression machinery. Promotion of a survivor = repoint `llm_second_opinion`; zero merge-code changes. |
| D7 | **LLM2 never has decision authority.** LLM2 down/unusable alone → proceed with LLM1's normal merge (error logged). LLM1 down/unusable → today's fail-closed forced ask, with LLM2's verdict still logged. Disagreement (both healthy) is the *only* path where LLM2 changes the decision (→ ask). |
| D8 | LLM1-down + LLM2-verdict → the ask **reason gains a non-authoritative FYI** line with LLM2's verdict. |
| D9 | **check_blindspot consults: the pair fires too.** Both verdicts shown in the blindspot headline; disagreement = an `LLM2 DISAGREES` FYI line only; the decision never changes (local ask stays ask). |
| D10 | **Parallel mechanism: two self-contained `Invoke-RestMethod` runspaces** (works on both Windows PowerShell 5.1 and pwsh 7 — the test suites exercise both engines). Prompt built once on the main thread; parsing on the main thread; per-call timeout enforced by IRM's `TimeoutSec` inside each runspace. Mock short-circuit stays synchronous in-process. When LLM2 is disabled, today's synchronous LLM1 path runs byte-identical. |
| D11 | **LLM2 effective timeout = `min(llm2.timeout_ms, llm1.timeout_ms)`** (clamped, logged as the effective value). Hook.ps1's hard-cap formula stays untouched (`llm1.timeout + 2000`). |
| D12 | **Tests: `PRETOOLHOOK_LLMREVIEW_MOCK2`** env var, same grammar as `PRETOOLHOOK_LLMREVIEW_MOCK`, read only by LLM2, **falling back to the primary var when unset** (single-var tests = "both agree" = regression baseline). Runner gains a `mock2` XML attribute. |
| D13 | **Log layout:** `LLM-SENT` extended with `model2=`/`timeout2=`; new `LLM2-RECV` line mirroring `LLM-RECV`; `LLM-RECONCILE` gains a comparison prefix (`llm2-agree` / `llm2-DISAGREE` / pair-skipped note); `records.jsonl` gets a nested `llm2` sub-object with a `compare` field; the LLM1-disabled+LLM2-enabled case gets a one-line `.log` note. |
| D14 | **R2 trusted/editable pre-skip stays as-is** — the pair is skipped too (LLM2 fires iff LLM1 fires). Reconcile line notes `(pair skipped — comparison not applicable)`; `compare='skipped-trusted-editable'`. Rationale: bypassing R2 for data collection would let the unconditional disagreement-ask fire on whitelisted daily traffic — prompts resurrected purely for decision-irrelevant data. Only 100%-trusted/editable blocks are invisible to the A/B dataset, and their verdicts are decision-irrelevant by construction. |
| D15 | **Shipped defaults:** root `config.json` carries the full block `enabled:false`; `ConfigLoader` runs full validation parity (ignored keys still type-checked); **no error** when `llm_third_opinion` exists but `llm_second_opinion` is absent/disabled (that is the logged-skip case); live `config.local.json` rolls out enabled with the two real models; docs updated (config-json-guide, runner README note, root `_comment_llm_third_opinion`). |
| D16 | **Disagreement ask reason wording** (see §3 Q14) — `*** LLM-DISAGREE ***` headline, both model names + verdict lines, contested sub-command text, `| local reason:` suffix, `effect='llm2-disagree'`. Blindspot consults are exempt (FYI inside the blindspot headline). |
| D17 | **Fixture placement:** new dir `test/config/llm-third-opinion/` (own configs + XML), executed by the existing llm-review runner, registered as suite `llm-third-opinion.llm` in `Run-AllTests.ps1` (the `script-drilldown.llm` precedent). Existing llm-review suites stay untouched — their continued green IS the absent-block byte-identical proof. Disabled-block parity cases live in the new XML. |

---

## 3. Interview record — questions, options, rationale, rulings

Format: **Q** — question. Options with trade-offs. **RULING** — what the user decided.

### Q1. Scope coupling: does `llm_third_opinion` get its own scope gate, or is it slaved to LLM1's?

A full copy of the block carries `level` / `complex_min_subcommands` / `check_blindspot` /
`remote_indicators`. Independent scopes mean some commands consult only one LLM → nothing to
compare → undefined behavior for an A/B feature.

- (a) **Slave scope:** LLM2 consulted exactly when LLM1 is; the scope keys are accepted-but-ignored. Guarantees a comparable pair on every consult.
- (b) Full independent scope; single-LLM consults merge locally per today's rules (comparison silently degraded).
- (c) Copy fields and validate they equal LLM1's (load error on divergence).

**RULING: (a).** Follow-up confirmed: when both are enabled, **LLM1's** `level` /
`complex_min_subcommands` / `remote_indicators` / `check_blindspot` decide whether the *pair* is
consulted.

### Q2. Which fields does LLM2 actually own? (prompt-shaping / sampling boundary)

`attributed_verdicts` shapes the prompt (V1 vs V2) so it must be shared. `temperature`,
`llm_response_max_tokens`, `json_mode` sit on the boundary (they shape sampling/parseability, not
the prompt text).

- (a) Everything except endpoint identity mirrors LLM1: LLM2 owns only `enabled`, `base_uri`, `model`, `api_key`, `timeout_ms`; the rest are ignored. A fair A/B requires identical sampling settings; drift silently contaminates the decommission decision.
- (b) LLM2 owns the three boundary fields (flexible for gateway quirks, but requires manual sync).

**RULING: (a)**, plus the addendum that became **D3**: LLM2 fires only when LLM1 is enabled + in
scope; when LLM1 is disabled but LLM2 enabled, **the log must explicitly say LLM2 was skipped
because LLM1 is disabled**.

### Q3. What counts as "the same verdict"?

- (a) Verdict token + exact index-set equality (order-insensitive): `modifying [1,2]` vs `modifying [1,2,4]` = **different**. The index list is the actionable output of the attributed merge; index-level divergence is a genuine disagreement about a specific sub-command.
- (b) Verdict token only: fewer asks, but index-sloppiness becomes invisible.

**RULING: (a)** — explicitly re-confirmed by the user: *"verdict + index set. [1,2,4] and [2,4] are
different."*

### Q4. Failure modes (down = unreachable/timeout; unusable = unparseable)

Four asymmetric cases. Two philosophies:

- (a) **LLM2 never has decision authority:** LLM2 down/unusable → proceed with LLM1's merge, error logged (safety posture identical to today; a flaky evaluation endpoint must not force-ask for weeks; the sample drops out of the A/B dataset honestly). LLM1 down/unusable → today's fail-closed ask; LLM2's verdict still logged (free sample). Both down → today's ask, both errors logged. Net: disagreement is the ONLY LLM2-caused decision change.
- (b) Strict fail-closed on LLM2 too (flaky evaluation endpoint escalates prompts despite zero authority).

**RULING: (a).**

### Q4b. When LLM1 is down and LLM2 returned a verdict — reason-text FYI or log-only?

- (a) Append a non-authoritative FYI to the ask reason (approval-time signal; matches check_blindspot enrichment philosophy; helps eyeball LLM2 quality during evaluation).
- (b) Log-only.

**RULING: (a).**

### Q5. When both agree, whose verdict object drives the existing local merge?

- (a) LLM1's always; LLM2 purely observational; survivor promotion = repoint `llm_second_opinion`, zero merge changes.
- (b) Switchable primary via config.

**RULING: (a).**

### Q6 (user-raised). Does "disagree → automatic ask" apply unconditionally, or only for non-policy-suppressible indices?

Today's attributed merge suppresses LLM flags on `trusted_program` / `editable_path` /
`editable_delete` / safe-gated sub-commands. Concrete case: `git status && src\TestRunner.ps1` →
LLM1 `{"modifying":[2]}` (index 2 = trusted → suppressed today → allow) vs LLM2 `{"modifying":[]}`
→ verdicts differ → unconditional-ask says ask, but the disagreement is about locally-trusted
territory (ask = pure comparison noise).

**RULING (user, explicit):** comparison happens **before** the override: *"I need the two LLM
comparison happen before the override happens — process the json right after both LLM returns, see
them agree or not, then apply the override to LLM1 with the custom rules."* So: **disagreement →
ask UNCONDITIONALLY** (D5), accepting the re-introduced ask-noise on trusted scripts for the
lifetime of the evaluation. Consequence recorded: only fully-trusted/editable *blocks* (R2 skip)
remain comparison-free; mixed blocks like the example above DO compare and DO ask on disagreement.

### Q7. check_blindspot consults: does the pair fire there too?

Blindspot consults are out-of-normal-scope rescues where the decision is already ask and the LLM
verdict only enriches the reason. Blindspot commands are unknown-tier — arguably the most
interesting accuracy samples.

- (a) **Pair fires; both verdicts shown;** agreement → normal blindspot enrichment + "same result" note; disagreement → an `LLM2 DISAGREES` FYI line; decision unchanged either way.
- (b) LLM2 skipped on blindspot (less latency; loses the hardest samples from the A/B dataset).

**RULING: (a)** — "LLM2 joins blindspot, both shown."

### Q8. The parallel mechanism (constraint: must run under BOTH PowerShell 5.1 and pwsh 7 — the test suites exercise both engines; `ForEach-Object -Parallel` / `Start-ThreadJob` are 7-only → disqualified).

- (a) **Two self-contained background runspaces:** each call is a tiny `[powershell]::Create()` runspace containing only `Invoke-RestMethod` parameterized by (uri, bodyJson, timeoutSec, apiKey). Main thread BeginInvokes both, EndInvokes both, parses both. IRM stays the HTTP engine → error text and timeout behavior stay identical to today's LLM-DOWN logs; ~50–150ms overhead; single code path for both hosts; LLM2-disabled = today's sync path byte-identical; dispatch failure = that LLM `down` → Q4 rules.
- (b) `Start-Job` ×2: simplest, but ~0.5–1s process spawn overhead per consult + lifecycle cleanup in a short-lived hook.
- (c) `HttpClient`/task-based: fastest, but different exception text (LLM-DOWN reason drift) and the biggest refactor.

**RULING: (a).**

### Q8b (user-raised). Evaluation of an external proposal: "`Invoke-WebRequest -Async` tasks + `Task.WaitAll`, PS 7.4+"

**Analysis: NOT the same as (a); it is a (c)-flavored variant, and rejected:**
- "PS 7.4+ only" **disqualifies it**: the llm-review runner calls `Invoke-LlmReview` in its own
  process and legitimately runs under 5.1 (the leg that caught the V-3 argument-mode bug). A 7.4+
  mechanism forces a second fallback code path.
- "`$script:` prompt constants stay directly accessible" — illusory: in design (a) the prompt is
  built on the main thread; the runspace carries only (uri, body, timeout, key).
- "parsing reused untouched" — equally true in (a).
- "independent timeouts" — equally true in (a) (two runspaces end independently).
- Task-cancellation exceptions produce different error text than IRM timeouts → LLM-DOWN reason
  drift mid-dataset; (a) keeps IRM so error text stays byte-identical.

**RULING: stay with (a).**

### Q9. Timeout budgets: LLM2's effective timeout and the Hook hard cap

Today: per-call `timeout_ms`; Hook hard cap = `llm1.timeout_ms + 2000`.

- (a) **LLM2 effective timeout = `min(llm2.timeout_ms, llm1.timeout_ms)`** (clamped + logged); pair finishes within LLM1's budget; **Hook hard cap unchanged**. No reason to wait longer than the operative classifier's budget for an observer's answer.
- (b) Independent timeouts; hard cap = max(both) + 2000 (every LLM2-slow consult stretches to the larger budget; Hook logic grows).

**RULING: (a).**

### Q10 (user-raised). Test mocking: how do the two LLMs return *different* raw content offline?

- 1. **`PRETOOLHOOK_LLMREVIEW_MOCK2`**, same grammar, read only by LLM2, **fallback to the primary var when unset** (existing single-var tests = both-agree = regression baseline, zero rewrites); runner `mock2` attribute. **CHOSEN.**
- 2. Combined single var with `|` separator — breaks existing grammar; prose containing `|` is ambiguous. Rejected.
- 3. Mock response files — doesn't compose with string mocks; deferred unless parser-robustness replay tests are later needed.

**RULING: 1** (= D12).

### Q11. Log layout (five artifacts)

1. `LLM-SENT` (existing line) extended with `| model2=<name> timeout2=<effective-ms>` — the numbered sub-command list is identical for both LLMs, so no second SENT line.
2. New `LLM2-RECV` line mirroring `LLM-RECV` exactly, directly beneath it.
3. `LLM-RECONCILE` gains a comparison prefix — `llm2-agree | ...` / `llm2-DISAGREE -> FINAL: ask` / `(pair skipped — comparison not applicable)` — so "LLM and LLM2 return same result" reads off the reconcile line.
4. `records.jsonl`: nested `llm2` sub-object on the llm log (`record.llm.llm2 = { model, verdict, indices, latency_ms, recovered, mocked, effective_timeout_ms, error, raw_full, raw_excerpt, compare }`); `compare` is the single field the decommission analysis filters on.
5. LLM1-disabled + LLM2-enabled: one explicit line in the human-readable `.log`.

**RULING: OK as proposed** (= D13). (Refinement made in design: when LLM2 is disabled/absent there
is **no** `llm2` sub-object at all — records stay byte-identical to today; the Q11 draft's
`not-armed` enum value is therefore encoded by absence rather than a field value.)

### Q12 (user-raised). The R2 trusted/editable pre-skip: does it also skip the comparison?

Options: (1) R2 stays as-is, pair fires iff LLM1 fires today; (2) bypass R2 when LLM2 enabled (pure
data collection); (3) option 1 + self-documenting log note.

**Analysis:** option 2 would **weaponize D5 against the user**: on all-trusted blocks (the most
frequent daily traffic — whitelisted test runners), any model-pair disagreement about flagging a
whitelisted script would force `ask` — prompts resurrected purely to collect data that cannot
change any decision. The dataset bias of skipping is narrow: R2 skips only 100%-trusted/editable
blocks; a trusted script next to anything else still compares (and still asks on disagreement).

**RULING: option 3** (= D14): R2 unchanged; reconcile note + `compare='skipped-trusted-editable'`.

### Q13. Shipped defaults, validation, rollout, docs

1. Root `config.json`: full structural copy of `llm_second_opinion`, `enabled:false`, ignored keys marked via `_comment`.
2. Validation parity: same validator incl. type-checks on ignored keys (typo'd `level` still throws — fail-fast doctrine); nothing required when disabled; `base_uri`+`model` required when enabled; **no error** when `llm_third_opinion` exists while `llm_second_opinion` is absent/disabled.
3. Live rollout: `config.local.json` enabled with the two real models.
4. Docs: root `_comment_llm_third_opinion` field reference; `docs/config-json-guide.md` section; runner README `mock2` note; this spec + the design doc.

**RULING: OK as proposed** (= D15).

### Q14 (user-raised). Human-facing ask reason wording for the disagreement-ask

**RULING: full both-verdicts detail** with three refinements: model names are dynamic (read from
config); contested sub-command text is named (symmetric-difference indices, first entry's text,
120-char cap) — not just index numbers; house-style `| local reason:` suffix and
`effect='llm2-disagree'`; reason rewritten even when local was already ask; blindspot exempt.
Final template:

```
*** LLM-DISAGREE *** second-opinion LLMs disagree: LLM1 (<model1>) -> <verdict1> [indices=[..]] | LLM2 (<model2>) -> <verdict2> [indices=[..]] - forced to ask. Review carefully before approving. | contested: [4] 'src\Run-AllTests.ps1' | local reason: <original>
```

### Q15 (user-raised, at go-time). Fixture placement

- 1. New fixture dir + own suite (script-drilldown precedent).
- 2. Extend llm-review in place (blurs the absent-block proof).
- 3. New dir + disabled-block parity cases inside llm-review.

**Analysis:** a plain TestRunner XML suite cannot test this feature at all (TestRunner never loads
`LlmReview.ps1`); every LLM-machinery case must run through the llm-review runner, which already
accepts `-XmlPath`/`-ConfigPath`/`-Cwd`. The repo precedent (`script-drilldown.llm`,
`editable-delete.llm`) is a new fixture dir executed by that runner. Option 2's mutation of the
shared fixture config would destroy the absent-block byte-identical proof (the untouched existing
suites provide it for free).

**RULING: option 1 executed the `script-drilldown.llm` way, with option 3's disabled-block parity
folded in** (= D17): `test/config/llm-third-opinion/` configs + XML, run by the llm-review runner,
one new suite registration.

---

## 4. Invariants (acceptance gates)

1. **Feature OFF (block absent or `enabled:false`): byte-identical** to today — every existing
   suite green, zero flips; `records.jsonl` and the human log unchanged in shape; LLM1's call
   path untouched (synchronous, same error text).
2. **Feature ON: additive only**, with exactly two decision deltas: (i) disagreement → ask;
   (ii) nothing else. LLM2's failure modes never change a decision (D7).
3. LLM2 fires **iff** LLM1 fires (scope, blindspot, R2 skip — all slaved to LLM1).
4. Identical prompts + identical sampling parameters to both LLMs; only endpoint identity differs.
5. Wall-clock of the pair ≈ max(t1, t2), bounded by LLM1's timeout (D11); Hook hard cap unchanged.
6. Every consult that LLM1 made leaves an A/B-comparable trace in `records.jsonl`
   (`llm2.compare`), except decision-irrelevant R2-skipped blocks (self-documented).

## 5. Open items

- **http-mock pair-dispatch checks:** the runspace (real HTTP) leg is only exercisable offline via
  the local mock server (`test/config/llm-review/http/Run-LlmCallTests.ps1`). Ruling: **extend it
  with 2–3 pair-dispatch checks if its mock server can serve divergent consecutive responses;
  otherwise defer and record the gap in the design doc's implementation-result note.**
  (Mocks bypass runspaces, so without this the parallel machinery ships with zero offline coverage.)
  **2026-09-30 sibling review:** verified FEASIBLE — the mock server's synchronized `$State`
  pattern supports a `BodyByModel` (model→response) hashtable + `Requests` capture, and the
  http-runner's fullpipe branch already clones the fixture config (extend the clone to arm LLM2).
  Concrete plan = design §7.5; defer-and-document remains the fallback only if implementation hits
  a blocker.
- The user mentioned an attached picture for the blindspot reason-line detail (Q7) that never
  arrived; the textual ruling ("LLM2 joins blindspot, both shown") governs.

## 6. Out of scope

- Any automated accuracy scoring / decommission recommendation tooling (the analysis is done
  offline by the user from `records.jsonl`).
- Making LLM2's scope/sampling configurable (explicitly rejected, D1/D2).
- Switchable-primary merge input (explicitly rejected, D6).
- Mock response *files* for parser-robustness replay (deferred, Q10).
