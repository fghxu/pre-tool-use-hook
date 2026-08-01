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
