# llm_second_opinion test fixture

Isolated fixture for the second-opinion LLM feature (phase-I spec:
`docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md`; phase-II spec:
`docs/superpowers/specs/2026-08-02-llm-second-opinion-phase2-design.md` —
attributed verdicts + gated-tier suppression + reconciliation logging;
phase-III spec: `docs/superpowers/specs/2026-08-02-llm-second-opinion-phase3-design.md` —
stage-2 path-guard for gated writable cmdlets).

## Run

```powershell
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1                 # default: phase-II small file (from repo root)
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.p2.large.xml   # opt-in 50-case matrix
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.xml            # phase-I file (regression)
```

- **Default (small)**: 26 checks — 10 phase-II cases (`test-cases.p2.small.xml`)
  plus 16 shared pre-flights (config rejection ×2, 12 `ConvertTo-LlmVerdict`
  parser units, 2 `Format-LlmLogBlock` sub-command-count units).
- **Large (opt-in)**: 80 checks — 64 cases (`test-cases.p2.large.xml`) in seven
  groups: suppression matrix, levels, fallback/malformed indices,
  effects/log/reason, scope numbering, `attributed_verdicts=false` regression,
  and the **stage-2 path-guard** (G7: system-path targets veto, temp/CWD/
  relative/variable-value suppress, skip-list, `%SystemRoot%` fail-closed,
  copy source-vs-dest, `path-guard denied` log marker). The fixture config
  carries a minimal `system_paths` for the guard (without it the compiled
  regex matches nothing and `C:\Windows` allows at normal).
- **Phase-I file**: 34 checks — the original 16 scope/merge cases + 2 fullpipe
  + the same pre-flights.

LLM verdicts are injected via `PRETOOLHOOK_LLMREVIEW_MOCK`
(`modifying|read-only|garbage|down|idx:2|idx:1,2|idx:0|idx:`) — the `idx:`
forms route attributed JSON through the REAL parser. No test ever touches the
network. These suites are deliberately **separate** from the main suites
(`src/Run-AllTests.ps1`): they run in seconds and burn zero LLM quota.

Per-case XML attributes: `level`, `min`, `enabled`, `mock`, `in-scope`,
`verdict`, `effect`, `strictness`, `attributed`, `flagged`, `suppressed`,
`reason-contains`, `reason-not-contains`, `log-contains`, `mode` (see the
header comment in `Run-Tests.ps1`).

**Per-run reconciliation logs**: every run writes
`c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-<timestamp>.log` with
one block per case — what was SENT (numbered sub-command list), what was RECV'd
(raw response, latency, mock mark, indices), the LOCAL decision + tiers, and
the RECONCILE line (flagged/suppressed/veto → FINAL). Same formatter as the
production `.log` (`Format-LlmLogBlock`). Fullpipe child-hook writes also go to
that directory (set via `log_file_path` in the fixture config), never your
real hook logs.

## `http/` — the LLM-CALL suite (real HTTP path, local mock server)

The main suite above injects verdicts via the mock env var, so it never
exercises the HTTP code in `Get-LlmReviewVerdict`. `http/` closes that gap with
a **local mock LLM server** (`Mock-LlmServer.ps1` — a real `HttpListener`
socket on 127.0.0.1; still zero quota, nothing leaves the machine):

```powershell
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1   # from repo root
```

27 checks in two files: `test-llm-call-core.xml` (5 — happy paths, garbage,
HTTP 500, and the headline `Core-FullPipe-HookCallsLlm` case proving the
spawned `Hook.ps1` really emits the LLM call) and `test-llm-call-matrix.xml`
(22 — request shape: method/path/headers/body fields/payload guard; response
parsing variants; attributed `<sub_commands>` block present/absent; dead-port +
timeout failure paths). The key assertion is `expect-hit="1"`: the server
**recorded** the request — proof the call happened. See the runner's header
comment for the attribute vocabulary (`server`, `expect-verdict`, `expect-hit`,
`check`, `attributed`, `subcommands`, …).

## `http/Run-LlmLiveTests.ps1` — LIVE end-to-end test (real gateway, small quota)

The true end-to-end proof: calls the **real** gateway (default `glm-5.2` @
`http://127.0.0.1:3030`) through the production verdict client, plus one case
through the real spawned `Hook.ps1`. **OPT-IN — costs ~2k tokens per run**
(7 calls × ~300 tokens, `max_tokens=16`); commands are only classified as text,
never executed.

```powershell
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1   # offline, mock server (default for code changes)
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1   # LIVE, real gateway - run deliberately
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1 -BaseUri http://host:port -Model some-model
```

What it does:

1. Probes `GET {BaseUri}/v1/models` first — gateway down = loud failure, no
   quota spent, exit 1 (a live test that can't run is a failure, not a skip).
2. Runs 7 cases (`test-llm-live.xml`): 4 phase-I direct verdict assertions
   (local/remote × read-only/modifying), 1 fullpipe `Get-Date` through the real
   hook expecting `allow`, and 2 **attributed** cases (`Live-Attr-*`) that send
   the V2 prompt with a numbered sub-command list and assert the returned
   indices exactly (empty list for all-read-only; `[2]` when only the second
   mutates). The `Live-Attr-*` outcome is the model-compliance signal that
   decides whether production ships `attributed_verdicts: true` for a given
   model.
3. Prints **every** verdict as it arrives (`LIVE [name] verdict=... indices=[...]
   latency=... raw='...'`) so you can watch what the model actually answered.
4. Retry policy: retries once **only** on transient outcomes (`down` /
   `unusable`). A wrong verdict is never retried — that's the model-quality
   signal you're looking for. The offline suites pin the code; this suite
   samples the model.

Last verified 2026-08-01 against glm-5.2 (phase-I cases): **5/5**, clean
bare-token answers on all direct calls (latencies ~5–12 s each). The two
`Live-Attr-*` cases were added 2026-08-02 and have not been run live yet.

## Manual smoke test (live LLM — costs quota, run deliberately)

1. In root `config.json` set `llm_second_opinion.enabled: true` and point
   `base_uri`/`model` at your gateway.
2. With `attributed_verdicts: true` (the default), `normal` strictness is
   usable as-is: gated-tier flags are suppressed as policy instead of vetoing.
   If you set `attributed_verdicts: false` (phase-I binary mode), also set
   `global_modifying_strictness: "strict"` for the test session — otherwise the
   loose gated tier and the LLM disagree on every risk:low command.
3. Trigger any in-scope command through the hook (e.g. in VS Code Copilot:
   `aws s3 ls && aws s3 cp a b` — expect a prompt with LLM wording; a read-only
   remote block with an agreeing LLM passes silently and records an `llm` log
   entry).
4. Check the `.log` for the four-line reconciliation block
   (`LLM-SENT`/`LLM-RECV`/`LLM-LOCAL`/`LLM-RECONCILE`) and the
   `*.records.jsonl` for the `llm` object (in `%USERPROFILE%\.pretoolhook\` or
   your configured `log_file_path`).
5. Set `enabled` back to `false` (and strictness back to `"normal"` if you
   changed it) — or leave them, deliberately.
