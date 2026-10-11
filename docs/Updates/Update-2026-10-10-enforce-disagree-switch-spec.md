# Spec: `llm_third_opinion.enforce_disagree` switch (2026-10-10)

Status: **IMPLEMENTED + GREEN** (full regression 1487/1487).
Amends: `docs/superpowers/specs/2026-09-30-llm-third-opinion-spec.md` (D18) and
`docs/superpowers/specs/2026-09-30-llm-third-opinion-design.md`.
Companion design doc: `docs/Updates/Update-2026-10-10-enforce-disagree-switch-design.md`.

## 1. Request (user, 2026-10-10)

> "the pre-tool-use hook set to 'ask' if the two LLM disagree. I want to add a switch in
> the config, to remove the 'ask' if the two LLM disagree, in case disagree, then just
> follow the regular classification decision before the llm_third_opinion was implemented."

## 2. Requirement statement

A new config key `llm_third_opinion.enforce_disagree` (boolean) controls whether a pair
disagreement changes the decision:

| `enforce_disagree` | Disagreement behavior |
|---|---|
| `true` (default, key absent) | Today's behavior, unchanged: forced **ask** with `*** LLM-DISAGREE ***` wording (spec D5, unconditional — fires before trusted/editable suppression). |
| `false` | The disagreement is still **detected and recorded** (`llm2.compare='disagree'`, `LLM2-RECV` line, RECONCILE prefix `llm2-disagree (not enforced) | ...`) but **never changes the decision**: the flow falls through to the regular classification that existed before `llm_third_opinion` was implemented, i.e. LLM1's verdict drives today's merge (its own veto / suppression / agree rules apply as usual). |

## 3. Decision summary (D18, added to the pair spec)

- **D18.1** Key lives in `llm_third_opinion` (the comparison owner). It is VALIDATED for
  both LLM blocks (a stray key on `llm_second_opinion` throws at load — same
  "ignored keys are still validated" philosophy as D15) but only the third block's value
  is read at runtime.
- **D18.2** Default when absent = `true`. Every existing config (root `config.json`,
  every fixture, every record) stays byte-identical — the switch is opt-in.
- **D18.3** `false` = detect + record, never enforce. The D5 forced-ask early-return is
  skipped; execution continues into the existing merge exactly as if the pair had
  agreed. LLM2 becomes a pure observer (A/B data keeps accumulating in
  `records.jsonl` / `.log` without disagreement prompts).
- **D18.4** Fall-through is NOT a blanket allow. LLM1's own verdict still drives
  today's rules: LLM1 modifying → normal `*** LLM-VETO ***` ask (with the usual
  trusted_program / editable_path / gated path-guard suppressions re-enabled);
  LLM1 read-only + local allow → allow; LLM1 down/unusable → unchanged fail-closed ask.
- **D18.5** `check_blindspot` consults are unaffected either way (D9 already never
  changes the decision — FYI note only).
- **D18.6** Failure-mode handling (llm1-down / llm2-down folds, FYI appends) is
  untouched by the switch.
- **D18.7** Logging: with `false`, `llm2.compare` still records `disagree`; the
  LLM-RECONCILE line is prefixed `llm2-disagree (not enforced) | ` followed by LLM1's
  merge outcome (effect = the merge's own value: `veto` / `agree` /
  `veto-suppressed-policy` / ...). The enforced path keeps `effect='llm2-disagree'` and
  the `disagree LLM=... vs LLM2=... -> FINAL: ask` rendering, byte-identical.
- **D18.8** Live rollout: `config.local.json` ships `"enforce_disagree": false`
  (the user's explicit choice); root `config.json` ships `true` + a
  `_comment_enforce_disagree` explaining both modes.

## 4. Acceptance gates

1. Key absent anywhere → behavior byte-identical to the 2026-09-30 feature (all
   pre-existing pair tests stay green without edits).
2. `enforce_disagree: "yes"` (non-boolean) → `Load-Config` throws with the
   `llm_third_opinion.enforce_disagree` prefix (fail-closed validation).
3. `false` + disagree (LLM1 read-only / LLM2 modifying) on a locally-allowed block →
   **allow**, reason never contains `*** LLM-DISAGREE ***`, `llm2.compare='disagree'`.
4. `false` + disagree where LLM1 says modifying → normal `*** LLM-VETO ***` ask
   (fall-through is not a blanket allow).
5. `false` + trusted-only disagreement → suppression applies → **allow** (mirror of
   the enforced D5 headline case LT3-19, which still asks).
6. `false` + blindspot disagreement → unchanged (D9): ask stands, FYI note only.
7. `false` + fullpipe → decision allow + `LLM2-RECV` line + `llm2-disagree (not
   enforced)` reconcile marker in the hook `.log`.
8. Full regression: zero flips on every pre-existing suite.

## 5. Test plan (delivered)

Fixture dir `test/config/llm-third-opinion/` (suite `llm-third-opinion.llm`, 64 → 72 checks):

| Check | Pins |
|---|---|
| PF-9 | `enforce_disagree:"yes"` → load throws (`config.bad-disagree.json`) |
| PF-10 | `false` compiles to `EnforceDisagree=false` (`config.pair.disagree-off.json`) |
| PF-11 | key absent → default `EnforceDisagree=true` (`config.pair.json`) |
| LT3-29 | disagree + LLM1 modifying → falls through to today's VETO ask |
| LT3-30 | disagree + LLM1 read-only + local allow → ALLOW (the switch headline) |
| LT3-31 | blindspot + enforce off → unchanged (D9 FYI only, ask) |
| LT3-32 | trusted-only disagree → suppression applies → ALLOW (mirror of LT3-19) |
| LT3-33 | fullpipe disagree → allow + `LLM2-RECV` + `llm2-disagree (not enforced)` |

TDD record: RED = 72/65/7 (`debug/_red_enforce.txt` — exactly the 7 new checks;
LT3-31 passes in RED by design since the blindspot path never enforced).
GREEN = 72/72 (`debug/_green_enforce.txt`). Full regression = **1487/1487**
(`debug/_full_enforce.txt`), zero flips.
