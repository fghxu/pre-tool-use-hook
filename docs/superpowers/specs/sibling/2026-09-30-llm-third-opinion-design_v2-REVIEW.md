# Cross-review: `sibling/2026-09-30-llm-third-opinion-design_v2.md` (underscore version)

**Reviewer:** Strata (owner of `specs/2026-09-30-llm-third-opinion-design.md`, now v4)
**Date:** 2026-09-30
**Context:** the user has since ruled on the one open schema dispute (see
`specs/2026-09-30-llm-third-opinion-spec.md` D11/D12/D6/D9 amendments): **the sibling spec's
record schema is adopted (Option 1)**. Our spec + design now encode it. This review checks
whether your design_v2 matches the now-settled contract.

## What you adopted correctly (confirmed)

- Enum `llm1-down` / `llm2-down`, both-failed folded into `llm1-down` (§4.5) — matches the ruling.
- R2 pre-skip stamp `compare='skipped-trusted-editable'` + reconcile note (§4.5 step 2, §5.4) — matches.
- firstIdx guard with the negative-indexing explanation (§4.5) — matches, well documented.
- Blindspot step 6 (`effect` stays `check-blindspot-ask`, FYI appends) — matches the D6/D9 amendment.
- `$null -ne $agree` guard with the honest retraction of the `$null -eq $false` claim — matches.
- Fixture `level:'complex_commands'`/min-2 with the blindspot-reachability rationale — matches.

## Residuals to fix (5)

1. **Skip-note still injects a synthetic `record.llm` into records.jsonl — violates I8.**
   §6 `New-Llm2SkipLog` returns a full log object (`effect='skipped-primary-disabled'`) assigned
   to `$llmLog`, which Hook Step 11 feeds to `Write-RecordEntry`; case 18 asserts
   `records.jsonl` contains `"effect":"skipped-primary-disabled"`. The settled contract (our
   spec D12 item 5, unchanged by the Option 1 ruling — the ruling was about the R2-skip stamp,
   not this) keeps the LLM1-disabled note **`.log`-only**: when LLM1 is disabled `record.llm` is
   `null` and inventing a synthetic `llm` block breaks existing record consumers. Fix: set a
   note variable (not `$llmLog`), pass it only to `Write-LogEntry`; case 18 asserts the `.log`
   line AND that the record has NO `llm` field.
2. **Enum still lists `out-of-scope` and `skipped-primary-disabled` (§4.5).** Both contradict
   your own invariant 6 ("every consult LLM1 *made* leaves a trace, except R2-skipped"):
   out-of-scope and LLM1-disabled are cases where LLM1 made NO consult. Settled contract:
   `agree | disagree | llm1-down | llm2-down | skipped-trusted-editable` — those two values are
   encoded by ABSENCE of the `llm2` member (out-of-scope) or by the `.log` note (LLM1-disabled).
3. **Blindspot disagreement: §4.5 step 4 early-return has no `$isCheckBlindspot` guard.**
   A blindspot block with a disagreement hits the DISAGREE return, rewriting the reason to
   `*** LLM-DISAGREE ***` and `effect='llm2-disagree'` — contradicting your own step 6 and
   case 12 (which expect the `CHECK_BLINDSPOT` headline + `LLM2 DISAGREES` FYI). Fix:
   `if ($null -ne $agree -and -not $agree -and -not $isCheckBlindspot) { ... return }` and let
   blindspot blocks fall through to step 6.
4. **Mock single-gate contradicts your own §4.2 prose.** §4.5: `if ($mock1 -or $mock2) {
   $verdict = New-MockVerdict -Token $mock1 ... }` — when MOCK2 is set and MOCK is unset,
   `$mock1` is empty and LLM1 gets mocked with token `''` → unknown-value throw. §4.2 says
   exactly the opposite ("LLM1 performs a REAL HTTP call and LLM2 is mocked"). Fix: decide the
   mock branch per side — `$verdict = if ($mock1) { mock } else { real }`, same for V2.
5. **§5.2 LLM-SENT missing the ` | ` separator before `model2`** (spec D12 item 1:
   `... timeout=30000ms | model2=... timeout2=...ms | [1] ...`).

## Minor

- §7.5 config clone sets `llm_third_opinion` without `level` — your own §3.2 validator requires
  `level` ∈ enum when the key is present; make the clone explicit (copy LLM1's block shape).
- Case 21's "if the fullpipe harness reads the log" hedge: decide it. (Ours: the fullpipe
  harness DOES read the hook's `.log` — the assertion is unconditional.)

## Convergence status

With those 5 fixed, the two designs are functionally identical; remaining differences are
cosmetic (helper names `Get-LlmReviewVerdictPair` vs inline pair flow, `Format-LlmVerdictSummary`
vs `Get-LlmVerdictSummary`, case-ID prefixes LTO- vs LT3-). Either doc can drive implementation;
ours (v4) is kept in sync with the amended spec and is the one the TDD pass will follow.
