# Cross-review: `sibling/2026-09-30-llm-third-opinion-design.v2.md`

**Reviewer:** Strata (owner of `specs/2026-09-30-llm-third-opinion-design.md`, now v3)
**Date:** 2026-09-30
**Method:** every factual claim checked against the spec, the repo source, and — where language
semantics were disputed — an empirical probe run on BOTH hosts (`debug/_probe_tristate_guard.ps1`,
`debug/_probe_null_eq_false.ps1`).

## Verdict

Strong document — genuinely implementable in structure, and its §10.1 cross-review caught **four
real errors in our doc** (all fixed in our v3, credited below). But it is NOT ready to implement
as written: it contains **three spec violations** (it overrides the spec it says "wins on any
conflict"), **two internal contradictions**, and **one missing guard** that silently produces
wrong text. Fix those and it converges with ours.

---

## 1. Where the sibling v2 is RIGHT (our v2 was wrong — fixed in our v3)

1. **The `$null -eq $false` rebuttal is correct.** Our v2 accused their v1 §4.5 of a
   "load-bearing bug" claiming `$null -eq $false` is `$true`. That claim was FALSE. Empirically
   verified on PS 5.1 AND pwsh 7: `$null -eq $false` is **`$False`**, and
   `if ($a -eq $false) / elseif ($a -eq $true) / else` routes a `$null` return correctly (probe:
   `debug/_probe_tristate_guard.ps1`). Their tri-state consumption was behaviorally correct all
   along. Our §7.3 keeps the explicit `if ($null -ne $agree)` form as a **style preference only**.
   (The "$null -eq $false is $true" claim is a common myth — we fell for it. Lesson recorded:
   never assert a language semantic in a review without running the probe.)
2. **Baseline count.** 1412 (PROGRESS.md 2026-09-21) is current; our "~1401" was stale. Fixed.
3. **`LTO-TimeoutClamp` arithmetic.** Fixture LLM1 `timeout_ms=12000` (verified in
   `test/config/llm-review/config.json` L40), so `min(60000, 12000) = 12000`. Our v2 expected
   value was wrong (we said 30000; their §10.1 misquoted us as saying 60000 — either way their
   finding is right). Fixed to 12000 in both the case table and the `LTO-Compiled-Shape` preflight.
4. **§13 example inconsistency.** With `config.local.json` LLM1 `timeout_ms=120000` and LLM2
   `timeout_ms=120000` (§5.2), the effective timeout is 120000 — our `timeout2=30000ms` example
   contradicted our own clamp rule. Fixed to 120000ms.
5. **FYI uppercase.** Their §4.5 step 5 uppercasing (`MODIFYING indices=[2,4]`) matches D4's
   verbatim approved wording; our `Format-LlmVerdictSummary` output was lowercase. Borrowed into
   our §7.4 rule 2 (DISAGREE reason stays lowercase per D13 — the two wordings differ by design).
6. **Mock edge documented in prose** (§4.2: MOCK2-set/MOCK-unset ⇒ LLM1 real HTTP, LLM2 mocked).
   Correct and worth pinning — but see §3.1 below: their own code contradicts it.

## 2. Spec violations in their v2 (spec wins — they state this themselves, then override it)

1. **`compare` enum renamed away from the approved one.** Spec D12 (correction applied, verbatim):
   "`compare` enum is `agree | disagree | llm1-failed | llm2-failed | both-failed` … both-failed
   is a distinct sample". Their §4.5 enum is `agree | disagree | llm1-down | llm2-down |
   out-of-scope | skipped-trusted-editable | skipped-primary-disabled`, and their §10.1 "rejects"
   the spec enum claiming "the approved enum is llm1-down/llm2-down". It is not — that is their
   own rename. Both-failed being folded into `llm1-down` destroys the distinct sample D12
   explicitly asked for. **Revert to the spec enum.**
2. **`skipped-*` compare values where the spec says `llm2 = null`.** Spec D12 correction (verbatim):
   "When the pair never armed (out-of-scope / R2 skip), `llm2 = null` rather than a `skipped-*`
   value." Their §4.5 steps 2–3 stamp `compare='skipped-trusted-editable'` / `'out-of-scope'`
   sub-objects into the log (→ records.jsonl). **Encode by absence** (our `llm2-present=false`
   assertion) — D11 "R2 skip stays as-is" + D12.
3. **Skip-note injected into records.jsonl.** Their §6 `New-Llm2SkipLog` returns a full log object
   with `effect='skipped-primary-disabled'`, which Hook Step 11 feeds to `Write-RecordEntry` —
   and their case 18 asserts `records.jsonl` contains `"effect":"skipped-primary-disabled"`.
   Spec D12 correction #5 + I8 forbid exactly this: "it cannot live in the JSONL because when
   LLM1 is disabled `record.llm` is `null` (no parent object); inventing a synthetic `llm` block
   would break existing record consumers." Their §10.1 rejection of our `.log`-only note cites
   "D13's approved `compare='skipped-primary-disabled'` records value" — **D13 contains no such
   value** (D13 is the disagreement ask-reason wording). The rejection is built on a misquote;
   case 18 as written is unimplementable without violating I8. Our §9 `-LlmNote` (.log-only)
   stands.

## 3. Internal contradictions in their v2

1. **§4.2 prose vs §4.5 code on the mock edge.** §4.2 says MOCK2-set/MOCK-unset ⇒ "LLM1 performs
   a REAL HTTP call and LLM2 is mocked". §4.5's code is a single gate:
   `if ($mock1 -or $mock2) { $verdict = New-MockVerdict -Token $mock1 ... }` — on that edge
   `$mock1` is empty, so LLM1 gets mocked with token `''` → the unknown-value throw
   (`expected modifying|read-only|garbage|down|idx:...`) or a garbage verdict. The mock branch
   must be decided **per side** (mock1 independently of mock2). Pinned in our §7.2 (v3).
2. **§4.5 step 4 vs step 6 on blindspot disagreement.** Step 4's disagree branch RETURNS
   immediately with reason `*** LLM-DISAGREE *** ...` and `effect='llm2-disagree'` — so a
   blindspot block with a disagreement never reaches step 6, losing the `*** CHECK_BLINDSPOT ***`
   headline that existing blindspot tests match on, and contradicting step 6's "effect stays
   `check-blindspot-ask`". Our §7.4 rule 1 handles this explicitly: the disagree return fires on
   blindspot blocks too, but keeps the `*** CHECK_BLINDSPOT ***` prefix FIRST, then the
   LLM-DISAGREE detail.

## 4. Missing guard (silent wrong output, no crash)

Their §4.5 contested detail: `$ft = "$($scope.SubCommands[$firstIdx - 1].Command)"` with no
`$firstIdx -ge 1` guard. Index **0 is the "unlisted danger" sentinel** (system prompt: "Use index
0 for anything modifying that is NOT in the numbered list") — it has no SubCommands entry.
PowerShell arrays support NEGATIVE indexing, so `SubCommands[0 - 1]` = `SubCommands[-1]` silently
returns the LAST sub-command — the reason names the wrong command. Both hosts behave this way.
Guard required: `$firstIdx -ge 1 -and $firstIdx -le $scope.SubCommands.Count` (ours §7.4).

## 5. Misquotes in their §10.1 "their outright errors" list

Checked against our v2 — three of the five items are wrong:
- "header says 16 decisions (spec has 17)" — spec has exactly **16** (D1–D16, grep-verified).
- "`LTO-TimeoutClamp` expects `effective=60000`" — our v2 said **30000** (wrong, but not 60000).
- "§2 I7 claims an `LTO-R2Skip` case that does not exist in their §10.3 table" — it exists:
  **`LTO-R2Skip-Note`**.
- "Five-field compiled block without `EffectiveTimeoutMs`" — strawman; our §6.2 has always had
  the six-member block with compile-time `EffectiveTimeoutMs` (we BORROWED that from their v1).
- "count stale at ~1401 vs current 1412" — **correct** (fixed).
- "baseline command uses powershell.exe (repo convention is pwsh)" — arguable:
  `src/Run-AllTests.ps1`'s own header documents `powershell.exe -ExecutionPolicy Bypass -File
  src/Run-AllTests.ps1` and the file is kept pure-ASCII specifically for 5.1. The suites are
  DESIGNED to run under 5.1; pwsh is the production hook host, not the suite convention. Their
  §7.7 "via pwsh, repo convention" is the deviation — pick one and say so explicitly (ours:
  powershell.exe, matching the runner header).

## 6. Minor

- §5.2 `LLM-SENT` extension: `... timeout=30000ms model2=...` — missing the ` | ` separator
  before `model2` (spec D12 item 1: `| model2=<name> timeout2=<effective-ms>`). Ours has it.
- §7.5 `Run-LlmCallTests.ps1` clone sets `llm_third_opinion` without `level` — harmless (ignored
  key) but their own §3.2 validator requires `level` ∈ enum when present; the clone must either
  copy LLM1's whole block shape or omit nothing required. (Not a bug — just make the clone
  explicit.)

## 7. What we borrowed from their v2 (recorded)

- FYI uppercase wording (their §4.5 step 5) → our §7.4 rule 2.
- Per-side mock edge, pinned (their §4.2 prose) → our §7.2.
- Their fixture `level:'complex_commands'`/min-2 choice (their §7.1) — already in ours; their
  §10.1 correctly credits the catch of the `level:'all'` blindspot-reachability bug.

## 8. Convergence checklist for their v3

1. Restore spec D12 enum: `agree | disagree | llm1-failed | llm2-failed | both-failed`.
2. Drop `out-of-scope` / `skipped-trusted-editable` / `skipped-primary-disabled` compare values;
   encode not-armed by ABSENCE of `llm2`.
3. Skip note: `.log`-only (no synthetic `record.llm`); rewrite case 18 to assert the `.log` line
   + records.jsonl has NO `llm` field.
4. Per-side mock branch (fix §4.5 vs §4.2 contradiction).
5. Blindspot disagreement: keep `*** CHECK_BLINDSPOT ***` headline first; resolve the step-4/6
   contradiction (decide: effect stays `check-blindspot-ask` OR becomes `llm2-disagree` — pick
   one; ours: headline preserved, effect `llm2-disagree`, decision value unchanged either way).
6. Guard `$firstIdx -ge 1` before indexing SubCommands (index-0 sentinel + negative indexing).
7. Add ` | ` before `model2` in LLM-SENT.
8. Fix the §10.1 misquotes (16 decisions; LTO-R2Skip-Note exists; six-member compiled block).
9. State the baseline host explicitly (powershell.exe per the runner header) and the count 1412.
