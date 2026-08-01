# LLM Second Opinion — Design Spec

Date: 2026-08-01
Status: Approved design (pending written-spec review)
Branch: strictness-gated

## 1. Background and goal

A mis-classified command (modifying classified as read-only) recently reached the
production environment because the hook auto-allowed it silently. This feature adds a
**second pair of eyes**: for in-scope commands, the hook asks an LLM (via an
OpenAI-compatible local gateway) to independently classify the command as read-only or
modifying, then compares the two verdicts. Disagreement in the dangerous direction
(local=allow, LLM=modifying) forces the decision to `ask` with an eye-catching reason.

The feature must be a **complete no-op when disabled** (byte-identical behavior, all
existing suites green), must work for all three supported IDEs (Claude Code, VS Code
Copilot, Codex CLI), and is tested first with the VS Code Copilot integration.

## 2. Locked decisions (from brainstorming Q&A)

| # | Decision |
|---|----------|
| D1 | Scope is **leveled**: `all` / `complex_commands` / `complex_remote` (level 3 name chosen by designer). |
| D2 | "Complex" threshold is configurable: `complex_min_subcommands` (default 2; 3 or 4 tightens it). A pipe implies 2+ sub-commands, so pipes are covered by the threshold automatically. |
| D3 | Failure posture: **fail-closed with notification**. LLM unreachable/timeout/HTTP-error → in-scope commands become `ask` with explicit "LLM is enabled but down" wording so the user notices and can flip `enabled` off. Unparseable LLM output is a distinct "unusable" state, also forced to `ask` — never treated as a "modifying" verdict. |
| D4 | LLM wait budget: `timeout_ms = 12000`. Hook hard cap becomes `timeout_ms + 2000` when the feature is enabled (3000ms unchanged when disabled). |
| D5 | Remote-touching signals: `aws`, `kubectl`, `helm`, `terraform`, `ssh`/`scp`/`sftp`, PowerShell remoting (`Enter-PSSession`, `New-PSSession`, `Invoke-Command` only with `-ComputerName`), plain HTTP (`curl`/`wget`/`Invoke-RestMethod`/`irm`/`Invoke-WebRequest`/`iwr`), `docker`. **Git is local.** List lives in config as editable regexes. |
| D6 | Architecture: **Approach A** — new `src/LlmReview.ps1` module; `Invoke-Classify` untouched; merge happens in `Hook.ps1`. Sequential (classify ~10ms, then LLM only if in scope). No parallel pre-pass: scope depends on the classification result, and parallelism would save ~50ms of ~5s while wasting quota on out-of-scope calls. |
| D7 | IDE-agnostic: the LLM call is the same OpenAI-compatible endpoint for all IDEs. Per-IDE differences are only hook I/O, already handled by `HookAdapter.ps1`; a forced `ask` maps to `deny` for Codex automatically. No Codex-specific work. |
| D8 | LLM check applies **only to full-pipeline command results** (Classifier STEP 4 output). Skipped: ignore-listed tools, unknown tools, `trusted_pattern`/`untrusted_pattern` gate hits (explicit hand-written rules; no decomposition to scope on), file-tool path-branch (Write/Edit — paths, not commands), unextractable commands. |
| D9 | Eye-catch reason wording is **ASCII-only** (`powershell.exe` 5.1 mangles UTF-8; documented Run-AllTests lesson). Prefixes: `*** LLM-VETO ***`, `*** LLM-DOWN ***`, `*** LLM-UNUSABLE ***`. |
| D10 | Tests never call a live LLM. Mock env var `PRETOOLHOOK_LLMREVIEW_MOCK` (mirrors the `PRETOOLHOOK_CONFIG_PATH` precedent) short-circuits before any HTTP. |

## 3. Config block

Root `config.json` gains one block, shipped with `enabled: false`:

```jsonc
"llm_second_opinion": {
  "enabled": false,                        // master switch
  "level": "complex_remote",               // all | complex_commands | complex_remote
  "base_uri": "http://127.0.0.1:3030",     // OpenAI-compatible gateway
  "model": "glm-5.2",
  "api_key": "",                           // optional Bearer; empty for the local gateway
  "timeout_ms": 12000,                     // LLM wait budget
  "temperature": 0.0,
  "max_tokens": 16,
  "complex_min_subcommands": 2,            // integer >= 1; see D2
  "remote_indicators": [                   // regex, per sub-command, case-insensitive
    "\\baws\\b", "\\bkubectl\\b", "\\bhelm\\b", "\\bterraform\\b",
    "\\bssh\\b", "\\bscp\\b", "\\bsftp\\b",
    "\\bdocker\\b", "\\bcurl\\b", "\\bwget\\b",
    "\\bInvoke-RestMethod\\b", "\\birm\\b",
    "\\bInvoke-WebRequest\\b", "\\biwr\\b",
    "\\bEnter-PSSession\\b", "\\bNew-PSSession\\b",
    "Invoke-Command.*-ComputerName"
  ],
  "_comment": "Second-opinion LLM. See docs/config-json-guide.md."
}
```

### ConfigLoader changes (established optional-block pattern)

Same pattern as `trusted_programs` / `safe_expressions`:

- **Block absent** → skip silently; `Config._compiled.llmSecondOpinion` is `$null`.
- **Block present** → validate and compile onto `Config._compiled.llmSecondOpinion`:
  - `enabled` must be a boolean.
  - `level` must be one of `all`, `complex_commands`, `complex_remote` — an unknown
    value **throws fail-closed** with an actionable message (same style as the
    legacy `modifying_strictness` key guard).
  - `complex_min_subcommands` must be an integer ≥ 1 (default 2 when absent).
  - When `enabled` is true: `base_uri` and `model` must be non-empty.
  - `timeout_ms` integer > 0 (default 12000); `temperature` 0.0–2.0 (default 0.0);
    `max_tokens` integer ≥ 1 (default 16); `api_key` string (default "").
  - `remote_indicators` compiled to case-insensitive regex objects (default: the
    shipped list above when the key is absent).
- When `enabled` is false, validation still runs (bad values surface immediately)
  but the runtime path is a no-op.

## 4. Scope engine

Implemented as `Test-LlmReviewScope -ClassifyResult -Config` in `src/LlmReview.ps1`,
returning a PSCustomObject `{ InScope, Reason, SubCommandCount, RemoteMatch }` (the
extra fields feed the log object).

Applies only to full-pipeline command results (D8). Concretely, out of scope when:
`IsSkipped` is true, `IsUnknown` is true, `SubResults` is empty, or `Command` is
empty/whitespace. (Gate hits and path-branch results all have empty `SubResults`;
the redirection pseudo-sub-result `MatchedPattern="redirection-target"` is excluded
from the count.)

| Level | In-scope rule |
|---|---|
| `all` | Every full-pipeline command result. |
| `complex_commands` | Count of real sub-results (excluding `redirection-target`) ≥ `complex_min_subcommands`. |
| `complex_remote` | The `complex_commands` rule AND at least one `remote_indicators` regex matches any sub-result's `Command` text **or the full original command text**. |

Note on wrapper commands: `Invoke-Command -ComputerName … { … }`, `ssh host "…"` and
friends are unwrapped during classification, so `SubResults` holds the *inner*
commands and the wrapper text survives only in the result's original `Command`.
Matching against the original text too is what makes the
`Invoke-Command.*-ComputerName` indicator work. This is a scope *gate* (fail toward
checking), so a rare false positive only costs one LLM call.

Sub-command count uses the engine's own decomposition (`SubResults`) — no duplicated
split logic. AST-extracted PowerShell results count extracted cmdlets (variable
assignments/loop scaffolding are noise and do not count).

## 5. LLM call and prompt design

### 5.1 Call shape

`POST {base_uri}/v1/chat/completions` (OpenAI-compatible chat completions — same
shape as the working POC `C:\git\cc\deepseek-tester\api-gateway-caller.ps1`):

- Body: `model`, `messages` (system + user), `temperature`, `max_tokens`, `seed: 0`.
- `Authorization: Bearer {api_key}` header only when `api_key` is non-empty.
- `Invoke-RestMethod -TimeoutSec ([math]::Ceiling(timeout_ms/1000))`.
- The **full original command text** is sent (not sub-commands), so the LLM judges
  the whole pipeline in context. Command text is truncated to 8000 chars as a
  payload guard.
- Mock short-circuit (D10): if `PRETOOLHOOK_LLMREVIEW_MOCK` is set
  (`modifying` | `read-only` | `garbage` | `down`), return the corresponding
  synthetic verdict without any network call.

### 5.2 Prompt redesign (fixes the POC's ~10% misclassification)

POC diagnosis (confirmed by sampling before the user stopped further calls): the
~10% splits into (a) rare clean wrong tokens and (b) frequent **output-contract
violations** — the model rambles reasoning and the POC's parser maps *anything* that
is not a clean bare token to `true` (modifying), amplifying the error rate. The POC
also crams rules + command + output contract into the user message with a weak
system prompt.

Fixes:

1. **System/user split** — all rules, definitions, few-shot examples, and the output
   contract move to the system message; the user message is only the delimited
   command block.
2. **Sharpened definitions at the observed confusion points** — curl/wget/IRM GET
   with no data flags = read-only; `aws describe-*/list-*/get-*` = read-only;
   HTTP POST/PUT/PATCH/DELETE or data-upload flags = modifying.
3. **Model-agnostic** — the model will be swapped for production; nothing
   model-specific in the prompt.
4. **Layered parser** (§5.3) — garbage no longer masquerades as "modifying".

System prompt (shipped text):

```text
You are a binary command-safety classifier protecting a production environment.
You receive one command block (it may mix AWS CLI, PowerShell, CMD, bash, ssh,
docker, kubectl, terraform, git, etc.) and classify it as read-only or modifying.

DEFINITIONS
- MODIFYING (true): at least one sub-command creates, updates, deletes, moves,
  copies, renames, sends, installs, starts, stops, or otherwise changes the state
  of any file, directory, system, service, process, configuration, cloud resource,
  or data store; or performs an HTTP/API call that mutates (POST, PUT, PATCH,
  DELETE, or data-upload flags such as curl -d/--data/-F/-T, wget --post-data).
- READ-ONLY (false): every sub-command only inspects, queries, lists, prints, or
  downloads. This includes HTTP GET/HEAD/OPTIONS (curl/wget/Invoke-RestMethod with
  no data flags), aws ... describe-*/list-*/get-*, kubectl get/describe,
  docker ps/images/logs/inspect, git status/diff/log/show, Get-*/dir/ls/cat/type.

EXAMPLES (command -> answer)
Get-Item C:\temp\ -> false
Get-ChildItem C:\logs | Select-Object -First 5 -> false
curl -s http://example.com/api/items -> false
aws ec2 describe-instances --region us-east-1 -> false
kubectl get pods -> false
Get-Content app.log | Select-String ERROR -> false
Remove-Item C:\temp\foo.txt -> true
aws s3 cp file.txt s3://bucket/key -> true
curl -X POST -d '{}' http://api/orders -> true
ssh host "systemctl restart nginx" -> true

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be exactly one bare lowercase token:
  true   (modifying)   or   false   (read-only)
No reasoning. No explanation. No punctuation. No quotes. No markdown. No code
fences. No leading or trailing whitespace. Any other output is a critical failure.
Emit the single token immediately.
```

User message:

```text
<command_block>
{command text, max 8000 chars}
</command_block>
```

The same prompt text replaces the hard-coded prompt in the POC script
(`C:\git\cc\deepseek-tester\api-gateway-caller.ps1`) so experiments there match
production behavior.

### 5.3 Layered verdict parser

`Get-LlmReviewVerdict` parses the raw response content in order:

1. **Bare token** — trimmed/lower-cased content is exactly `true` or `false` → verdict.
2. **JSON** — content parses as JSON and has a verdict-ish key
   (`verdict`/`classification`/`decision`/`answer`) with value in
   {`modifying`, `read-only`, `true`, `false`} → verdict. (Future-proofs gateways
   offering `response_format: json_object`.)
3. **Last line** — the last non-empty line is exactly `true`/`false` → verdict,
   flagged `Recovered = $true` in the log (rescues the observed "ramble...\nfalse"
   mode instead of failing it).
4. **Otherwise** → `unusable` — a distinct state, **never** mapped to a verdict.

Verdict values: `modifying` | `read-only` | `unusable` | `down`
(`down` = unreachable / timeout / HTTP error / mock `down`).

## 6. Verdict merge (Hook.ps1)

New `src/LlmReview.ps1` is dot-sourced by `Hook.ps1`. One orchestrator function
`Invoke-LlmReview -ClassifyResult -Config` returns `@{ Result; Log }`:

- `Result` — the (possibly modified) classification result.
- `Log` — the `llm` object for the logger (§8).

Insertion point: **after Step 8 (`Invoke-Classify`), before Steps 9–10
(elapsed/timeout)** so LLM latency counts toward the elapsed time and the extended
hard cap applies.

### Merge matrix (in-scope results only)

| Local | LLM verdict | Final | Reason |
|---|---|---|---|
| allow | modifying | **ask** | `*** LLM-VETO ***` wording |
| allow | read-only | allow | unchanged (Log: agree) |
| ask | modifying | ask | unchanged (Log: agree) |
| ask | read-only | ask | unchanged (Log: disagree-kept-ask — stats) |
| any | down | **ask** | `*** LLM-DOWN ***` wording |
| any | unusable | **ask** | `*** LLM-UNUSABLE ***` wording |

Out-of-scope results: LLM not called; `Log.effect = "none"`, `verdict = "not_called"`.

### Exact reason wordings (ASCII-only, D9)

- Veto:
  `*** LLM-VETO *** second-opinion LLM says MODIFYING but local hook classified read-only - forced to ask. Review carefully before approving. | local reason: {original reason}`
- Down:
  `*** LLM-DOWN *** llm_second_opinion is ENABLED but the LLM is unreachable or timed out ({timeout_ms}ms) - forced to ask. Set llm_second_opinion.enabled=false in config.json to disable. | local verdict: {allow|ask} | local reason: {original reason}`
- Unusable:
  `*** LLM-UNUSABLE *** LLM returned an unparseable response - forced to ask. Raw: '{first 120 chars, single-lined}' | local verdict: {allow|ask} | local reason: {original reason}`

A forced `ask` keeps `ExitCode = 0` (a decision was produced — the exit-code
contract in README.md). All other result fields pass through unchanged.

### Timeout change (Hook.ps1 Step 10)

`$hardCapMs` = `timeout_ms + 2000` when the feature is enabled, else 3000. The 500ms
soft warning and the existing "classification timed out" forced-ask path are
unchanged.

## 7. Component summary

| File | Change |
|---|---|
| `src/LlmReview.ps1` | **New.** `Test-LlmReviewScope`, `Get-LlmReviewVerdict` (mock short-circuit + HTTP + layered parser), `Invoke-LlmReview` (orchestrator: scope → verdict → merge → log object). |
| `src/Hook.ps1` | Dot-source LlmReview.ps1; call `Invoke-LlmReview` after Step 8; pass its `Log` to the logger; Step 10 hard cap becomes conditional. |
| `src/ConfigLoader.ps1` | Optional-block validation + compilation of `llm_second_opinion` onto `_compiled.llmSecondOpinion`. |
| `src/Logger.ps1` | `Write-RecordEntry` accepts an optional `-LlmLog` object, serialized as the `llm` field in the JSONL record; one-line text-log summary when present. |
| `config.json` | New block, `enabled: false`. |
| `docs/config-json-guide.md` | New section documenting every field. |
| `README.md` | Feature paragraph + log-field documentation. |
| `C:\git\cc\deepseek-tester\api-gateway-caller.ps1` | Hard-coded prompt replaced with §5.2 text (kept in sync manually afterward). |

## 8. Logging

JSONL record gains (when the feature is enabled):

```json
"llm": {
  "enabled": true,
  "level": "complex_remote",
  "in_scope": true,
  "sub_command_count": 3,
  "remote_match": "aws",
  "verdict": "modifying",          // modifying|read-only|unusable|down|not_called
  "recovered": false,
  "latency_ms": 4820,
  "model": "glm-5.2",
  "effect": "veto",                // veto|agree|disagree-kept-ask|forced-ask|none
  "raw_excerpt": "true"
}
```

This yields the disagreement statistics needed to judge whether the LLM earns its
keep before production rollout.

## 9. Testing

### Mock mechanism (D10)

`PRETOOLHOOK_LLMREVIEW_MOCK` = `modifying` | `read-only` | `garbage` | `down`.
Checked in `Get-LlmReviewVerdict` before any HTTP. `garbage` returns a rambling
multi-line string (exercises parser layer 4); `down` returns the `down` verdict
(exercises the failure path). No network in any test.

### New isolated fixture: `test/config/llm-review/`

Same pattern as `test/config/trusted-programs/`: own `config.json`
(`enabled: true`, `level`/`complex_min_subcommands` varied per case group), own
`test-cases.xml`, own in-process runner `Run-Tests.ps1` that dot-sources `src`,
calls `Invoke-Classify` then `Invoke-LlmReview` with the case's `mock=` attribute
mapped to the env var, and compares final decision + reason prefix. 16 cases:

1. Level `all`: single command checked (veto applies).
2. Level `complex_commands`: single command **not** checked.
3. Level `complex_commands`: 2-command chain checked.
4. `complex_min_subcommands: 3`: 2-command chain **not** checked.
5. Level `complex_remote`: local complex block (`Get-ChildItem | Select-Object`) **not** checked.
6. Level `complex_remote`: `aws` complex block checked.
7. Level `complex_remote`: `docker` complex block checked.
8. Level `complex_remote`: `Invoke-Command -ScriptBlock { ... }` (local) **not** checked; `Invoke-Command -ComputerName x { ... }` checked. (Two cases.)
9. Level `complex_remote`: `git push origin main` chain **not** checked (git is local).
10. Veto: mock `modifying` + local allow → `ask` with `*** LLM-VETO ***` prefix.
11. Agree: mock `read-only` + local allow → `allow`, reason unchanged.
12. Disagree-kept-ask: mock `read-only` + local ask → `ask`, reason unchanged.
13. Down: mock `down` → `ask` with `*** LLM-DOWN ***` prefix.
14. Unusable: mock `garbage` → `ask` with `*** LLM-UNUSABLE ***` prefix.
15. Disabled (`enabled: false` in fixture config variant): decision identical to local, no `llm` log content.
16. Bad `level` value → `Load-Config` throws (negative validation test).

### Regression proof

Root `config.json` ships the block with `enabled: false`; fixtures re-synced via
`test/config/live/Sync-Fixtures.ps1`. Run-AllTests must stay 962/962 (live) and
938/938 (sandbox) — byte-identical behavior. Codex unit tests 17/17 untouched.

### Manual smoke test (user-run, documented — live LLM, real quota)

One real command against the real gateway, e.g. an `aws ... && ...` complex block
with the feature enabled, verifying the veto/agree path end-to-end. Not part of any
automated suite.

## 10. Error handling

| Failure | Behavior |
|---|---|
| Gateway unreachable / TCP error | verdict `down` → forced ask (`*** LLM-DOWN ***`). |
| HTTP 4xx/5xx | verdict `down` → forced ask; status code in `raw_excerpt`. |
| Timeout (≥ timeout_ms) | verdict `down` → forced ask. |
| 200 but unparseable content | verdict `unusable` → forced ask (`*** LLM-UNUSABLE ***`). |
| Empty `choices`/content | verdict `unusable`. |
| Config validation error | `Load-Config` throws → hook exits 2 (existing fatal path). |
| Feature disabled or block absent | Zero code runs beyond a `$null` check; no measurable overhead. |
| Logger failure after LLM merge | Non-fatal warning (existing behavior). |

## 11. Risks and boundaries

- **Quota/latency cost**: every in-scope command adds up to ~12s worst case. Mitigated
  by the leveled scope (D1/D2) and the off switch.
- **Trusted-pattern gap (accepted)**: `trusted_pattern` gate hits skip the LLM (D8).
  The audit's H1 hole (over-broad trusted patterns) is therefore *not* covered by the
  second opinion; the `trusted_programs` migration remains the right fix there.
- **False vetoes**: an LLM false-positive forces an `ask` — annoying but safe, and
  the disagreement stats in the log expose the rate.
- **Prompt injection via command text**: a crafted command could try to talk the LLM
  into "read-only". The local classifier's verdict is never *downgraded* by the LLM
  (ask stays ask), so injection can only suppress a veto, never create an allow that
  the local engine did not already produce. Accepted; noted for the production model
  choice.
- **500ms soft warning** will fire for every checked command (expected — LLM latency);
  it is informational only.

## 12. Out of scope (YAGNI)

- `response_format`/JSON-mode request flags (parser layer 2 already handles JSON).
- Self-consistency voting (n=3 calls) — latency/quota cost; revisit if the production
  model's clean-token error rate stays high.
- Parallel LLM launch (rejected — see D6).
- LLM checks for file-tool path decisions (paths are policy, not command semantics).
- Codex-specific work (D7).
