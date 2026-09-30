# llm_third_opinion — pair-comparison test fixture (GREEN suite, 2026-09-30)

Test fixtures for the `llm_third_opinion` feature (parallel comparison LLM "LLM2").
**Implemented + GREEN (2026-09-30):** suite `llm-third-opinion.llm` = 64 checks (28 LT3
cases + 8 PF config preflights + assertion checks), all green; full regression 1479/1479
with zero flips on the pre-existing 1412. The RED record (56 total / 40 passed / 16 failed)
is in `debug/_red_baseline.txt`.

- Spec (authority): `docs/superpowers/specs/2026-09-30-llm-third-opinion-spec.md` (D1–D17)
- Design (implementation contract): `docs/superpowers/specs/2026-09-30-llm-third-opinion-design.md` (§7 = this suite)

## Run (trusted path — never the fixture runner directly, the hook prompts)

```powershell
pwsh -NoProfile -File src\Run-AllTests.ps1 -Filter llm-third-opinion
```

which invokes:

```powershell
test/config/llm-review/Run-Tests.ps1
  -XmlPath    test/config/llm-third-opinion/test-cases.llm.xml
  -ConfigPath test/config/llm-third-opinion/config.pair.json
  -Cwd        test/config/llm-third-opinion
```

## Files

| File | Role |
|---|---|
| `config.pair.json` | Base: LLM1 enabled (complex_commands/min 2, timeout 30000, discard-port base_uri) + LLM2 enabled (m2, timeout 60000 → effective 30000, PF-1). `trusted_programs`: tool-a/tool-b (R2 case) + `src\Classifier.ps1` (D5 case). |
| `config.v1.json` | LLM1 `attributed_verdicts:false` (V1 bare-token pair). LLM2's ignored copy DELIBERATELY stays `true` — pins D2 (LLM1's sampling governs both). |
| `config.llm2-disabled.json` | Third block present, `enabled:false` — disabled-block byte-identical parity (LT3-13) + PF-8. |
| `config.llm1-disabled.json` | LLM1 disabled + LLM2 enabled — skip-note classify leg (LT3-17). |
| `config.llm1-absent.json` | NO llm_second_opinion block — skip-note fullpipe leg (LT3-18) + PF-7 (legal combination). |
| `config.bad-*.json` (×5) | Malformed third blocks for validation preflights PF-2..PF-6 (nouri / nomodel / timeout "abc" / level "bogus" / temperature 3.0 — the last two are IGNORED keys, still validated per D15). |
| `test-cases.llm.xml` | The 28 LT3 cases with a per-case pin map in the header (22 original + 6 from the 2026-10-01 sibling fixture audit, merged with two adjudications — see design §10.3). |

## STATE of the shared runner extensions (audit-note, 2026-10-01)

The sibling audit called the runner extensions "NOT yet shipped" — that was based on
inspecting the **committed HEAD**; in this working tree they ARE present and proven
(the 2026-09-30 RED run executed them end-to-end). They live as **uncommitted
working-tree changes** in `test/config/llm-review/Run-Tests.ps1` and
`src/Run-AllTests.ps1` alongside this fixture dir — commit them together when the
feature lands.

## Mocks

- LLM1: `PRETOOLHOOK_LLMREVIEW_MOCK` (runner `mock=` attr), grammar unchanged.
- LLM2: `PRETOOLHOOK_LLMREVIEW_MOCK2` (runner `mock2=` attr), same grammar; **unset ⇒ falls
  back to MOCK** (= "both agree" = regression baseline for every pre-existing test).
- Only LT3-22 touches the network — deliberately, to the discard port `127.0.0.1:9`
  (fast connection-refused ⇒ LLM1 `down`), pinning the per-side mock gate.

## GREEN result (2026-09-30, post-implementation)

- All 64 checks pass: PF-1..PF-8 (config compile/validation/clamp), the 28 LT3 cases, and
  the llm-review runner's built-in preflight unit checks.
- Parity pins (LT3-13 disabled-block, and every case without `llm2-*` attrs) stay green —
  the feature-off path is byte-identical (acceptance #1).
- The pair's real parallel runspace dispatch is additionally pinned by the 3 real-socket
  cases in `test/config/llm-review/http/test-llm-pair.xml` and verified on PS 5.1 via
  `debug/_probe_pair51.ps1`.
- Wording deviation (intentional): the R2-skip reconcile note uses an ASCII hyphen
  `(pair skipped - comparison not applicable)` where the design prose shows an em dash —
  em dashes in .ps1 are a UTF-8/BOM encoding hazard on PS 5.1 (see `src/Notify-Ask.ps1:71`).

## Runner extensions shipped with this fixture (shared file — other suites unaffected)

`test/config/llm-review/Run-Tests.ps1` gained: `mock2` env handling (arm/clear at every
site of the primary var), `llm2-present` / `llm2-verdict` / `llm2-compare` / `llm2-mocked`
assertion attrs, the Hook Step-8b `elseif` skip-log mirror in classify mode, guarded pair
preflights (only when the base config carries the block), and fullpipe honoring the
per-case `config=` attribute. All additions are no-ops for the pre-existing suites.
