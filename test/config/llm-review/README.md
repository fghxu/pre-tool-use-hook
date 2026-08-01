# llm_second_opinion test fixture

Isolated fixture for the second-opinion LLM feature (spec:
`docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md`).

## Run

```powershell
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1   # from repo root
```

25 checks: 16 in-process classify+merge cases, 1 config negative test
(`config.badlevel.json` must be rejected), 6 `ConvertTo-LlmVerdict` parser unit
checks, 2 fullpipe cases that spawn the real `src/Hook.ps1`. LLM verdicts are
injected via `PRETOOLHOOK_LLMREVIEW_MOCK` (`modifying|read-only|garbage|down`) —
no test ever touches the network. This suite is deliberately **separate** from
the main suites (`src/Run-AllTests.ps1`): it runs in seconds and burns zero LLM
quota.

Per-case XML attributes: `level`, `min`, `enabled`, `mock`, `in-scope`,
`verdict`, `effect`, `reason-contains`, `mode` (see the header comment in
`Run-Tests.ps1`).

Fullpipe log writes go to `c:\temp\pretoolhook-llm-review-testlogs\` (set via
`log_file_path` in the fixture config), never your real hook logs.

## `http/` — the LLM-CALL suite (real HTTP path, local mock server)

The main suite above injects verdicts via the mock env var, so it never
exercises the HTTP code in `Get-LlmReviewVerdict`. `http/` closes that gap with
a **local mock LLM server** (`Mock-LlmServer.ps1` — a real `HttpListener`
socket on 127.0.0.1; still zero quota, nothing leaves the machine):

```powershell
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1   # from repo root
```

25 checks in two files: `test-llm-call-core.xml` (5 — happy paths, garbage,
HTTP 500, and the headline `Core-FullPipe-HookCallsLlm` case proving the
spawned `Hook.ps1` really emits the LLM call) and `test-llm-call-matrix.xml`
(20 — request shape: method/path/headers/body fields/payload guard; response
parsing variants; dead-port + timeout failure paths). The key assertion is
`expect-hit="1"`: the server **recorded** the request — proof the call
happened. See the runner's header comment for the attribute vocabulary
(`server`, `expect-verdict`, `expect-hit`, `check`, …).

## `http/Run-LlmLiveTests.ps1` — LIVE end-to-end test (real gateway, small quota)

The true end-to-end proof: calls the **real** gateway (default `glm-5.2` @
`http://127.0.0.1:3030`) through the production verdict client, plus one case
through the real spawned `Hook.ps1`. **OPT-IN — costs ~1.5k tokens per run**
(5 calls × ~300 tokens, `max_tokens=16`); commands are only classified as text,
never executed.

```powershell
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1   # offline, mock server (default for code changes)
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1   # LIVE, real gateway - run deliberately
pwsh -NoProfile -File test/config/llm-review/http/Run-LlmLiveTests.ps1 -BaseUri http://host:port -Model some-model
```

What it does:

1. Probes `GET {BaseUri}/v1/models` first — gateway down = loud failure, no
   quota spent, exit 1 (a live test that can't run is a failure, not a skip).
2. Runs 5 cases (`test-llm-live.xml`): 4 direct verdict assertions
   (local/remote × read-only/modifying) + 1 fullpipe `Get-Date` through the
   real hook expecting `allow`.
3. Prints **every** verdict as it arrives (`LIVE [name] verdict=... latency=...
   raw='...'`) so you can watch what the model actually answered.
4. Retry policy: retries once **only** on transient outcomes (`down` /
   `unusable`). A wrong verdict is never retried — that's the model-quality
   signal you're looking for. The offline suites pin the code; this suite
   samples the model.

Last verified 2026-08-01 against glm-5.2: **5/5**, clean bare-token answers on
all direct calls (latencies ~5–12 s each).

## Manual smoke test (live LLM — costs quota, run deliberately)

1. In root `config.json` set `llm_second_opinion.enabled: true` and point
   `base_uri`/`model` at your gateway.
2. **Set `global_modifying_strictness: "strict"` for the test session.** The
   live config is loose: the `strictness_gated` tier auto-allows risk:low
   commands in normal mode, which the LLM will correctly call *modifying* —
   strict mode makes the local classifier ask on the gated tier too, so the two
   classifiers mostly agree and you don't drown in low-risk vetoes. Revert both
   settings after testing (phase II will teach the LLM about the gated tier).
3. Trigger any in-scope command through the hook (e.g. in VS Code Copilot:
   `aws s3 ls && aws s3 cp a b` — expect a prompt with LLM wording; a read-only
   remote block with an agreeing LLM passes silently and records an `llm` log
   entry).
4. Check `%USERPROFILE%\.pretoolhook\*.records.jsonl` (or your configured
   `log_file_path`) for the `llm` object.
5. Set `enabled` back to `false` and `global_modifying_strictness` back to
   `"normal"` (or leave them, deliberately).
