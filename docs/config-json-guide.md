# config.json Reference Guide

**Audience:** maintainers of the PreToolUse hook. This document explains every top-level block in `config.json`, what it controls, and what to watch out for when adding or modifying entries.

**Golden rule before any edit:** the hook loads and validates `config.json` on *every* PreToolUse event. An invalid config (bad JSON or bad regex) makes the hook **fail-closed**: every tool call of the agent is blocked — a total session deadlock. After every config edit, immediately run at least one suite:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/config/live/test-cases.xml"
```

For anything touching patterns or prefixes, run the full differential (`src/Run-AllTests.ps1`, all suites under `test/config/live/`) and compare against the baseline in `PROGRESS.md`.

---

## 1. Top-level scalars

| Key | Purpose | Notes |
|---|---|---|
| `version` | Config schema version. | Informational. |
| `description` | Human-readable summary. | Informational. |
| `log_file_path` | Directory for per-day hook logs (`C:\temp\logs\prehook\`). | Must exist / be writable. These logs are the source for "unknown command" analysis. |
| `global_modifying_strictness` | `normal` or `strict` (or `loose`). Global strictness — renamed from `modifying_strictness` 2026-07-28; the loader **rejects** the legacy key fail-closed. Governs redirect-write policy and some AWS/mixed cases. Per-domain `commands.<domain>.modifying_strictness` keeps the old name. | Test suites run both values (`-Strictness normal/strict`); changes here shift redirect-suite results. |
| `risk_legend` | Text descriptions of low/medium/high. | Documentation only — not read by logic. |

## 2. `editable_paths` / `system_paths` — redirect write policy

**What they do:** applied by the Parser's redirect analysis (`echo x > target`) to the *target path* of `>` / `>>` inside **shell commands**.

- `editable_paths`: writes under these roots auto-approve in **every** strictness mode (the CWD/editable check runs before the strictness fallbacks in `Resolve-PathPolicy`).
- `system_paths`: writes under these roots **always prompt**, any strictness. Windows entries are raw regex; linux entries too (see ConfigLoader notes).
- **POSIX-path gotcha (Windows host):** redirect targets like `/home/user/x` are resolved through `GetFullPath` inside `Test-EditableOrCwd`, so the regex sees `C:\home\user\x` — a plain `/home/user/` pattern never matches. Use the `([A-Za-z]:)?[/\\]home[/\\](user|dev)[/\\]` form (see the shipped `linux` entries and their `_comment_linux`). `~` home paths keep their `~\` form.

**When adding entries:**
- These apply **only to shell redirection**, NOT to file-tool writes (Write/Edit). File-tool writes are governed by `trusted_pattern`/`untrusted_pattern` (see companion doc).
- Windows backslashes are JSON-escaped twice: `"C:\\\\temp\\\\"` → regex `C:\\temp\\`.
- Entries are regex, not plain prefixes — escape `(` `)` etc. (see the `Program Files \(x86\)` entry).
- Overlap between the two lists: system_paths wins (checked first in the redirect analysis).

## 3. `safe_expressions`

**What it does:** the AST arbiter's .NET method allowlist. A PowerShell expression that the AST certifier (`Test-SafeAst`) proves contains no commands may still call .NET methods; only methods listed here are permitted (matched case-insensitively). Anything else → ask.

**When adding entries:**
- Add only methods with **no side effects** (pure readers/transforms). A single mutating method (e.g. `Kill`, `Delete`, `WriteAllText`) silently auto-approves destructive code. The `AST-Arbiter-Guard` adhoc group pins this — add a guard test for every new method.

## 4. `known_command_prefixes`

**What it does:** two consumers. (a) The heuristic command extractor (`Get-CommandFromInput` in HookAdapter.ps1): when a tool has no `tool_name_mapping` entry, it walks the payload for strings containing `|`/`;`/`&&` **or starting with one of these prefixes**. (b) General "is this token a command" hints.

**When adding entries:**
- Adding a prefix changes what the heuristic extracts from unmapped tools — can flip classifications of *existing* inputs. Run the full differential.
- Keep them lowercase; matching is case-insensitive but consistency aids review.

## 5. `trusted_pattern` / `untrusted_pattern`

The whole-string, pre-classification gate for **command text**: untrusted match → **ask**; trusted match → **allow**; both checked **before** the command DB and before command chunking.

**Post path-branch (2026-07-25):** these lists gate *command text only*. File-tool writes are decided earlier by the path-branch (`path_tool_mapping` → `Resolve-PathPolicy`, §7.5), which reads `system_paths`/`editable_paths`/CWD directly. The path-related regexes that used to live here (temp/git roots, catch-all, traversal guards) are retired — to add a writable root for file tools, edit `editable_paths` (§2), not these lists.

**Full details, entry-by-entry rationale, and how-to-add guide: see `docs/trusted-untrusted-patterns.md`.**

Cardinal rules (violating these is how you get `rm -rf /` auto-approved):
- **Never** an unanchored or catch-all `trusted_pattern` (`.*`, `^(?!…).*$`). Trusted short-circuits all classification.
- Always anchor with `^` (and usually `.*$`).
- Keep the command-side exe asker in `untrusted_pattern` — without it, bare full-path executables (`C:\temp\tool.exe` via Bash) hit the zero-command allow.

## 6. `intercept_tool_name` / `ignore_tool_name`

**What they do:** the tool gate (`Test-ToolNameFilter` in Classifier.ps1):

| Tool is in… | Result |
|---|---|
| `ignore_tool_name` | `skip` → **silently allowed**, nothing inspected |
| `intercept_tool_name` | `classify` → command/path extracted and classified |
| **neither** | `unknown tool` → **ask** (fail-safe) |

**When adding entries:**
- The ignore list is an *allow-list of tools* — every entry means "this tool's actions are never inspected." Only put genuinely read-only tools there (`read_file`, `Grep`, `WebFetch`…). Anything that writes files, runs code, or mutates state must NOT be here.
- A tool in **both** lists: ignore is checked first → it wins. Don't do this.
- Removing a tool from ignore without adding to intercept → it becomes `unknown` → prompts every call. Usually you want both moves together.
- New tool from a new IDE version? It defaults to `unknown` → ask. Decide its home explicitly.

## 7. `tool_name_mapping`

**What it does:** maps `tool_name` → dot-path of the payload field containing the **command** to classify. Holds command tools only: `run_in_terminal`, `send_to_terminal`, `Bash`, `PowerShell` → `tool_input.command`. Resolution order:

1. Mapping hit → that field's string.
2. Mapping miss/failure → **heuristic walk**: first string field containing `|`/`;`/`&&` or starting with a `known_command_prefix`.
3. Nothing found → `null` → hook treats as no command (skip).

**When adding entries:**
- File tools (Write/Edit/etc.) do **not** belong here — they go in `path_tool_mapping` (§7.5). A path is not a command.
- `PowerShell` must stay mapped to `tool_input.command` — without it, operator-less cmdlets slip through unmonitored.
- If the mapped path doesn't exist in the real payload, you silently fall to the heuristic. Verify new mappings against a real payload (capture one from `log_file_path` logs or a fullpipe test).

## 7.5 `path_tool_mapping`

**What it does:** maps file-tool `tool_name` → dot-path of the payload field holding the **file path** (`"Write": "tool_input.file_path"`, `"NotebookEdit": "tool_input.notebook_path"`, `"create_file": "tool_input.filePath"`, `"create_directory": "tool_input.dirPath"`, etc.). Tools listed here are decided by `Resolve-PathPolicy` (Classifier STEP 1.5), **not** the command DB:

```
Resolve-PathPolicy(canonicalized path):
  temp (raw)              → allow (low)
  system_paths            → ask   (high)
  under CWD               → allow (low)   [every strictness mode]
  editable_paths          → allow (low)   [per strictness]
  loose / normal(no-EP)   → allow (low)
  default                 → ask   (medium)
```

The path is canonicalized first (`ConvertTo-CanonicalWritePath`): `\\?\` and `\\?\UNC\` prefixes stripped, `/`↔`\` unified, `..` collapsed via `GetFullPath` (drive/relative/UNC only; POSIX-absolute and `~` paths unified without `GetFullPath`), relative paths anchored to the payload CWD.

**Semantics:**
- **Location-only** — writing an executable extension inside an editable root *allows* (`C:\temp\evil.exe` → allow). Execution of that file by a command tool is governed separately by the command-side exe pattern + classification.
- **Extraction failure → ask** (fail-safe; no heuristic fallback on file content).
- `edit_files` / `apply_patch` carry path *lists* with unverified payload shapes — deliberately **not** mapped yet; they stay intercepted and prompt.

**When adding entries:** verify the dot-path against a real payload from the logs before mapping, or extraction silently fails to ask. Single source of truth for path policy is now `system_paths`/`editable_paths` (§2) — no regex duplication.

## 8. `dry_run_flags`

**What it does:** exact command prefixes that downgrade a modifying command to read-only (`terraform plan`, `rsync --dry-run`, `kubectl apply --dry-run=client`…).

**When adding entries:** the key must match the command as written (prefix match). Only add flags that *provably* change nothing.

## 9. `commands` — the classification database

Domains: `DOS_CMD`, `PowerShell`, `Linux`, `Git`, `Terraform`, `Docker`, `Kubernetes`, `AWS_CLI`. Entry shape:

```json
{ "name": "reg query", "patterns": ["reg query *"], "risk": "high", "description": "..." }
```

**Semantics that surprise people:**
- An entry in a domain's `read_only` array is **auto-approved — even if it carries `"risk"`**; `risk` on read_only entries is informational. If it must prompt, it belongs in `modifying` — or in `strictness_gated` (§10) if it should prompt only under strict (that's where `git add` now lives).
- Patterns are **raw regex**, compiled directly — `*` is a regex quantifier, not a glob (`"git status*"` literally means "statu" + zero-or-more "s"). Style is sloppy but established; follow the existing form and prefer adding `^`-anchored or lookahead-bearing patterns where ambiguity matters (precedents: `wmic (?!.*process.*call.*create).*`, `^git tag$`).
- **An invalid regex anywhere in `commands` deadlocks the hook fail-closed** (the `.\gradlew` incident — `\g` is not a valid escape). Use character classes for path separators: `[.][/\\]gradlew`.
- Domain routing is content-based (`Get-CommandDomain` in Parser.ps1): PowerShell markers → hardcoded binary prefixes (docker/kubectl/terraform/aws/git/pwsh/cmd /c) → DOS markers → **fallback `linux`**. A command whose tool isn't in the prefix table lands in `linux` — put entries for such tools in the `Linux` domain (that's where `adb`, `unzip`, `javap`, `gradlew`, `gh` live). A brand-new `commands` domain is *unreachable* without a `Parser.ps1` code change.
- `PowerShell` domain is verb-driven: `read_only_verbs` / `modifying_verbs` (high/medium/low) classify any `Verb-Noun` cmdlet not explicitly listed. `parameter_commands` (e.g. `Invoke-RestMethod -Method`) override by parameter value, with a `default` decision.
- `AWS_CLI` is prefix-driven: `read_only_prefixes` (`describe-`, `list-`…) / `modifying_prefixes`.

**Workflow for new commands (established by the LogGap work):**
1. Add failing test cases to `test/config/live/test-cases.xml` first (RED).
2. Add config entries (GREEN).
3. Run the full differential (`src/Run-AllTests.ps1`) — byte-identical except your new cases.

## 10. `strictness_gated` — the strictness-dependent middle tier

Each domain may carry a `strictness_gated` array between `read_only` and `modifying`.
Entry shape is identical (`name` / `patterns` / `risk` / `description`); `risk` is what
the prompt shows when the entry asks.

Decision: **allow** when the effective strictness is `normal` or `loose`, **ask** when
it is `strict`. Use it for commands that are technically modifying but safe enough to
auto-approve day-to-day (e.g. `git add`) while still prompting under strict.

### Per-domain `modifying_strictness` + the global guard

Any domain may set its own `"modifying_strictness": "strict" | "normal" | "loose"`.
The global key is now **`global_modifying_strictness`** (top level); the per-domain
key keeps the old name. The effective strictness for a domain is resolved by
`Get-EffectiveStrictness`:

1. Global `global_modifying_strictness` is `strict` or `loose` → that value **forces every domain**.
2. Global is `normal` → the domain's own value (absent → `normal`).

Effective strictness drives three things: the `strictness_gated` tier, AWS CLI
flag-stripping (active only when the AWS domain is effectively normal), and
parameter_commands unrecognized-value handling (asks unless effectively loose).
Path policy (`system_paths` / `editable_paths` / CWD) is cross-domain and always
uses the **global** value.

Every shipped domain carries an explicit `"modifying_strictness": "normal"` (same
effect as inheriting normal) so the knob is visible exactly where you would change
it. To force one domain, flip that line to `"strict"` — e.g. inside `commands.Git`
(note: the git-strict fixture/suite was retired 2026-07-28; per-domain strictness
remains supported by `Get-EffectiveStrictness` but is no longer suite-covered).

### All-gated is the live policy (since 2026-07-27)

The live `config.json` IS the all-gated config (promoted from the former
`test/config/test-strictness-gate/` experiment): every domain carries a
`strictness_gated` tier and **every `"risk": "low"` command lives there** —
allow in normal/loose, ask in strict. `modifying` holds only medium/high risk.
Docker's gated tier is intentionally empty (it has no low-risk entries).
All suites live in `test/config/live/` (see its README); run them with
`src/Run-AllTests.ps1`. Behaviors the suites deliberately pin down:

- **Cmdlet file-writes allow in normal** — `Set-Content`/`Out-File` etc. are
  gated, so `Set-Content C:\Windows\x.txt ...` auto-approves in normal mode:
  command classification never path-checks cmdlet arguments (path policy covers
  only redirects and file tools). Strict mode still asks.
- **read_only prefix patterns shadow gated entries** — `terraform providers mirror`
  matches `^terraform providers` (read_only) before the gated tier, so it allows
  in every mode. Pre-existing pattern-shadowing.
- **DOS routing quirk** — `move` / `ren` / `setx` are not in the parser's
  DOS-marker list, so they fall to the `linux` fallback domain and hit
  "unknown command" (ask) regardless of the DOS_CMD gated entries. Pre-existing.

## 10.5 `llm_second_opinion` — second-opinion LLM cross-check

Optional block. **Absent or `enabled: false` = the feature is a complete no-op**
(the hook performs one null check per invocation). When enabled, in-scope
commands are *also* classified by an LLM (OpenAI-compatible endpoint) and the
two verdicts are compared. The LLM can only ever **escalate** an `allow` to
`ask` — it never downgrades a local `ask`.

```jsonc
"llm_second_opinion": {
  "enabled": false,
  "level": "complex_remote",
  "base_uri": "http://127.0.0.1:3030",
  "model": "glm-5.2",
  "api_key": "",
  "timeout_ms": 12000,
  "temperature": 0.0,
  "max_tokens": 16,
 complex_min_subcommands": 2,
  "attributed_verdicts": true,
  "json_mode": false
  // "remote_indicators": [ ... ]  // optional; compiled defaults used when omitted
}
```

| Field | Meaning |
|-------|---------|
| `enabled` | Master switch (bool). When true, `base_uri` and `model` are required (loader throws otherwise). |
| `level` | `all` = check every command · `complex_commands` = check only blocks with ≥ `complex_min_subcommands` decomposed sub-commands (a pipe implies 2+) · `complex_remote` = the `complex_commands` rule AND a `remote_indicators` match. Unknown value → loader throws (fail-closed). |
| `base_uri` / `model` | OpenAI-compatible gateway; the hook POSTs to `{base_uri}/v1/chat/completions`. |
| `api_key` | Optional; sent as `Authorization: Bearer …` only when non-empty. Empty for a local gateway. |
| `timeout_ms` | LLM wait budget (default 12000). When the feature is enabled, the hook's hard cap becomes `timeout_ms + 2000` (3000 ms otherwise). |
| `temperature` / `max_tokens` | Sampling parameters (defaults 0.0 / 64 — raised from 16 in phase II because attributed JSON answers are longer; a token cap is never a target, a well-behaved model stops after the closing `}`). |
| `complex_min_subcommands` | Integer ≥ 1 (default 2). What "complex" means for the two complex levels. |
| `attributed_verdicts` | Bool (default true; non-bool → loader throws). Phase II: the LLM also receives the numbered sub-command list and answers `{"modifying":[indices]}`; see the suppression table below. `false` restores the phase-I binary prompt/veto. |
| `json_mode` | Bool (default false; non-bool → loader throws). Phase III (2026-08-03): send `response_format: {"type":"json_object"}` on **attributed** calls, constraining the model to emit valid JSON — the hard fix for reasoning-leaning models that ignore the output contract and answer with analysis prose (→ unusable → fail-closed ask). Requires gateway support (the local gateway documents it). Ignored for the V1 binary contract (a bare token is not JSON). Pair with the hardened V2 prompt (negative example + first-character rule). |
| `remote_indicators` | Optional array of regex (case-insensitive), matched against every sub-command AND the full original command text. Defaults: `\baws\b`, `\bkubectl\b`, `\bhelm\b`, `\bterraform\b`, `\bssh\b`, `\bscp\b`, `\bsftp\b`, `\bdocker\b`, `\bcurl\b`, `\bwget\b`, `\bInvoke-RestMethod\b`, `\birm\b`, `\bInvoke-WebRequest\b`, `\biwr\b`, `\bEnter-PSSession\b`, `\bNew-PSSession\b`, `Invoke-Command.*-ComputerName`. **git is deliberately absent (local).** |

**Outcome matrix** (in-scope results only; all forced asks keep exit code 0):

| Local | LLM | Final | Reason prefix |
|-------|-----|-------|---------------|
| allow | modifying | **ask** | `*** LLM-VETO ***` |
| allow | read-only | allow | (unchanged) |
| ask | modifying | ask | (unchanged — agree) |
| ask | read-only | ask | (unchanged — the LLM never downgrades) |
| any | unreachable / timeout / HTTP error | **ask** | `*** LLM-DOWN ***` (tells you the feature is on but the LLM is down, and how to disable it) |
| any | unparseable response | **ask** | `*** LLM-UNUSABLE ***` |

**Attributed verdicts (phase II, `attributed_verdicts: true`).** The LLM
receives the raw block *plus* the engine's own numbered sub-command list and
answers `{"modifying":[indices]}`. Each flagged index is then reconciled
against the tier the local engine recorded for that sub-command:

| Flagged sub-command's local tier | Result |
|----------------------------------|--------|
| `strictness_gated` (risk:low, allows in normal mode) | **suppressed as policy** — no veto, *unless* the stage-2 path-guard refuses (below); if every flag suppresses, the final decision stays the local one (`effect=veto-suppressed-policy`) |
| `read_only` | **veto** → ask, reason names the offender with its index |
| unknown / untiered | **veto** (never suppressible) |
| index `0` ("something modifying not in the list") | **veto** (never suppressible) |

**Stage-2 path-guard (phase III).** Before a gated flag is suppressed, the
guard (`Test-GatedInvocationSafe`) checks *where* the gated command writes —
closing the documented gap where `Set-Content -Path C:\Windows\x.txt` (gated,
args never path-checked locally) had its LLM flag suppressed. The guard scans
every token of the flagged command: any absolute path (drive / UNC / POSIX)
goes through the same `Resolve-PathPolicy` ladder redirects use, and an `ask`
there **denies suppression** (veto). Three refinements keep the noise out:
`printf`/`setx` are skip-listed (their arguments are data, not targets);
relative paths are not scanned (CWD is writable in every mode); and a known
writer cmdlet whose target is an *unresolvable variable* fails closed —
unless a literal path token is present (`Set-Content C:\temp\a.txt $content`
suppresses; `Set-Content $reportPath x` vetoes; `%SystemRoot%\x` always
vetoes). Guard denials are reconciled in the `.log`
(`path-guard denied: [N]` on the LLM-RECONCILE line) and in the JSONL `llm`
object (`path_guard_denied`). Known residual: source and destination are not
distinguished — `Copy-Item` *from* a system dir vetoes even though it only
reads (rare; the reason names the path).

A bare `true`/`false` answer is the *unattributed fallback* (P5): it vetoes
exactly like phase I, even on a gated block. Out-of-range, non-integer, or
negative indices make the response **unusable** (fail-closed ask). Veto
reasons list both the offenders and the suppressed
(`*** LLM-VETO *** ... [sub-command N] ... | suppressed as policy: ...`).
Every in-scope check writes a four-line reconciliation block to the `.log`
(`LLM-SENT` numbered list → `LLM-RECV` raw response → `LLM-LOCAL` decision +
tiers → `LLM-RECONCILE` flagged/suppressed/veto → FINAL), and the JSONL `llm`
object gains `indices`, `flagged`, `suppressed`, `tiers`, `local_decision`,
`path_guard_denied`.

**Never checked** (even at level `all`… `all` means "all full-pipeline command
results"): ignore-listed tools, unknown tools, `trusted_pattern` /
`untrusted_pattern` gate hits, file-tool path decisions (Write/Edit — paths, not
commands), unextractable commands.

Every check is recorded in the JSONL record's `llm` object (`in_scope`,
`verdict`, `effect`, `latency_ms`, `model`, `raw_excerpt`, …) — use it for
disagreement statistics before trusting the feature.

**Testing the feature:** with `attributed_verdicts: true` (the default),
`normal` strictness is fully usable — gated-tier flags are suppressed as
policy instead of vetoing, so the two classifiers no longer fight over
risk:low commands. If you set `attributed_verdicts: false` (phase-I binary
mode), expect many vetoes on gated commands in normal mode; temporarily set
`global_modifying_strictness: "strict"` so the gated tier asks locally and the
classifiers mostly agree.

**Automated tests never call the LLM.** The `PRETOOLHOOK_LLMREVIEW_MOCK` env var
(`modifying` | `read-only` | `garbage` | `down` | `idx:2` | `idx:1,2` | `idx:0`
| `idx:`) short-circuits before any HTTP — the `idx:` forms inject attributed
JSON through the REAL parser (mirrors `PRETOOLHOOK_CONFIG_PATH`). See
`test/config/llm-review/` for the isolated fixture — a 10-case default suite
(`Run-Tests.ps1`, 24 checks incl. pre-flights) and a 50-case opt-in matrix
(`-XmlPath test/config/llm-review/test-cases.p2.large.xml`, 64 checks), plus
the mock-HTTP suite (`http/Run-LlmCallTests.ps1`) and the opt-in LIVE suite
(`http/Run-LlmLiveTests.ps1`, real gateway, costs ~2k tokens — user-run only;
its two `Live-Attr-*` cases decide whether a model complies with the
attributed JSON contract). Never run these against the ~1000-case main suites.

**Recipe — enable it:** set `enabled: true`, point `base_uri`/`model` at your
gateway, run one in-scope command (e.g. `aws s3 ls && aws s3 cp a b`), then
check the newest `*.records.jsonl` in your log directory for the `llm` object.

## 10.6 `ask_notification` — toast + sound on ask decisions

**What it does:** pops a Windows toast notification and plays a sound whenever the hook decides `ask` (approval needed). Useful when the IDE is in the background or on another monitor — you hear/see the alert instead of wondering why the agent went quiet.

```json
"ask_notification": {
  "enabled": true,
  "popup": true,
  "sound": true,
  "sound_file": ""
}
```

| Field | Type | Default | Purpose |
|---|---|---|---|
| `enabled` | bool | `true` | Master switch. `false` = no notification at all. |
| `popup` | bool | `true` | Show toast popup. Falls back to NotifyIcon balloon tip if toast fails (RDP/VDI). |
| `sound` | bool | `true` | Play a sound. |
| `sound_file` | string | `""` | Path to a `.wav` file. Empty = `[console]::beep(800, 300)`. Missing file = beep fallback. |

- **Absent block = all defaults on.** Setting `enabled: false` alone is enough to disable.
- **Fire-and-forget:** the notification launches in a detached PowerShell process; it adds ~0ms to the hook's decision path and can never block, delay, or change the decision.
- Fires on ALL `ask` paths: local classification, LLM veto, LLM-down, check_blindspot, and hard-timeout.
- Validated at load time: wrong types (`enabled: "yes"`) throw and fail-closed the hook.
- Testing: env var `PRETOOLHOOK_ASKNOTIFY_MOCK=<dir>` makes the notifier write `<dir>\ask-notified.txt` instead of a real toast (used by `test/config/ask-notification/`).

## 11. Editing checklist (any config change)

1. Valid JSON (no trailing commas) and valid regex in every pattern.
2. Run one suite immediately → catches fail-closed deadlocks while you can still act.
3. Run the full differential before committing.
4. Add/adjust test cases for every behavior-affecting change.
5. Commit on a feature branch; note the change in `PROGRESS.md`.
