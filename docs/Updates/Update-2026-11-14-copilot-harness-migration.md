# Update 2026-11-14 — Multi-harness migration: Copilot / Claude / Codex support

**Status: DESIGN DECIDED (grilling session 2026-11-14) — implementation not started.**

Decision ledger: ADR `docs/adr/0001-quad-contract-harness-adapter.md`.
Vocabulary: `CONTEXT.md`.

## 1. Background

- 2026-11-13: VS Code updated to 1.146.0. Chat gained a **Session Target**
  picker with four harnesses: **Local** (deprecated, removal **Feb 2027**),
  **Copilot** (shared runtime with Copilot CLI/app), **Claude** (Anthropic
  Agent SDK), **Codex** (OpenAI).
- Symptom: "the hook is no longer active" — no harness-driven invocations in
  `c:\temp\logs\prehook` after 2026-11-11 20:42; the invocations that did
  appear came from the Copilot CLI misdetected as ClaudeCode.
- Root cause (research, sources below): the Copilot harness **reads our repo
  `.claude/settings.local.json` registration** and fires the hook, but its
  PascalCase-alias payload keeps snake_case fields while its runner **ignores
  the nested `hookSpecificOutput` envelope** — so `allow` became
  indistinguishable from "no hook" and `ask` paths degraded. Registrations
  also tripled (repo `.claude` + `~/.copilot/hooks` + `.github/hooks`) because
  Copilot **combines** sources without dedup.

## 2. Contract research summary

| | Local | Copilot | Claude | Codex |
|---|---|---|---|---|
| Sources | `.claude/settings*.json` (gated by `chat.useClaudeHooks`/`hookFilesLocations`), `.github/hooks`, `~/.copilot/hooks` | `.github/hooks/*.json` (`version:1`), `~/.copilot/hooks/*.json`, inline in `.github/copilot/settings*.json` + `~/.copilot/settings.json`, **and repo `.claude/settings*.json`**; sources **combine** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`; identical handler in two files runs **once** | `~/.codex/hooks.json`, `~/.codex/config.toml [hooks]`, `<repo>/.codex/*`; **every hook needs `/hooks` trust review** (hash-pinned) |
| Event | `PreToolUse` | `preToolUse` (camel) / `PreToolUse` alias | `PreToolUse` | `PreToolUse` |
| Payload | snake_case + `tool_use_id` | camel: `toolName`/`toolArgs`/`sessionId`/epoch-ms (alias: snake_case, Claude-style tool names) | snake_case + `tool_use_id`/`permission_mode` | snake_case + **`turn_id`**/`model`/`permission_mode` |
| Output | nested envelope | **top-level** `permissionDecision` (nested ignored; `{}` = no decision) | nested envelope | nested envelope (or legacy `{"decision":"block"}`) |
| `ask` | ✅ | ✅ (needs interactive flow) | ✅ | ❌ **parsed then hook marked failed → tool call continues (fail-open)** |
| Exit codes | 0=JSON, 2=block | nonzero/error=**deny**; timeout=fail-open | 0=JSON, 2=block, other+JSON=JSON decides | 2=block; other=failure→tool runs |
| Timeout default → on timeout | 30 s → proceeds | **30 s → normal permissions** | 600 s → discarded | 600 s → tool runs |

Sources: `code.visualstudio.com/docs/agent-customization/hooks`,
`.../migrate-customizations`, `.../agents/run/agent-harnesses`,
`code.claude.com/docs/en/hooks`, `learn.chatgpt.com/docs/hooks`
(redirect target of `developers.openai.com/codex/hooks`).
Known-gap tracker: microsoft/vscode#346231.

## 3. Decision ledger (Q1–Q10, all approved by user)

| Q | Decision |
|---|---|
| 1 | **Quad-contract single adapter** in `Hook.ps1` (not per-harness front-ends, not Copilot-only). |
| 2 | Detection precedence: camelCase `toolName` → Copilot; `tool_use_id` ends `__vscode-` → Local; DSH marker; `turn_id` → Codex; else Claude; fallback `timestamp` ∧ ¬`tool_use_id` → Copilot (1.141-era). Keep `Detect-IDE`/`$ide` names (glossary fixes vocabulary); new log suffix **`.local`**. |
| 3 | Every Decision → **exit 0 + dual envelope** (nested + top-level fields). Exit 2 only for Fatal (unparseable input, bad config, no extractable command) — block/deny on all four. Codex: `ask` → `deny` **plus `systemMessage`** ("PreToolUse hook DENIED (Codex has no ask): …"). Unknown tool → **`ask`** (exit 0), superseding the old exit-2 deny. |
| 4 | Boundary normalizer: camelCase → internal snake_case; tool-name kebabing (`runInTerminal`→`run_in_terminal`) for intercept/ignore **lookup only** (logs keep the original). `apply_patch` → **ignore** (Codex native approval gates edits; bypass-mode caveat accepted). Unknown-name harvesting = our own ask/deny logs (`Select-String 'unknown tool'`), no observation mode. File-tool `path_tool_mapping` entries staged after real arg names are observed. |
| 5 | **Single source of truth**: `config.local.json` keeps `timeout_ms: 60000` and gains `answer_deadline_ms: {"Copilot": 28000, "Local": 28000}`. Hook enforces the deadline per detected harness; on deadline-before-verdict → `ask` "LLM assessment incomplete (<N> ms <H> deadline) — fail-closed". Registrations are **bare** (no timeout keys); the `7200000` entries are removed once code lands. |
| 6 | **All user-scope, one source per harness**; delete the repo `.claude/settings.local.json` hooks block and `.github/hooks/pre-cli-hook.json` (both approved). |
| 7 | `~/.copilot/hooks/pre-cli-hook.json` rewritten: `{"version":1,"hooks":{"preToolUse":[{"type":"command","command":"pwsh -NonInteractive -NoProfile -File C:/git/cc/pretoolhook/src/Hook.ps1"}]}}` — camelCase (clean detection + native tool names), bare, no matcher. Local reads the same file during the interim (accepts the alias, sends Local payloads → detected via `__vscode-`). |
| 8 | `~/.codex/hooks.json` new: same shape, PascalCase `PreToolUse`, bare. Rollout step: **`/hooks` trust review** (re-arms on file hash change). |
| 9 | Cutover gate (all must be green): ① full suite green incl. quad-contract cases; ② zero double-fire for 14 days (exactly 1 record per tool call); ③ zero discarded verdicts; ④ no new `unknown tool` entries for 14 days; ⑤ one real fail-closed degradation observed (deadline or LLM-DOWN ask). Flip `chat.defaultToCopilotHarness` by **2026-12-01**; keep Local escape hatch (`chat.editor.localAgent.enabled: true`) until **2027-01-15**; delete the inert `chat.hookFilesLocations` block at flip time. |
| 10 | Docs: ADR 0001, this update, `config-json-guide` §10.5.2, `CONTEXT.md`, `PROGRESS.md`. |

## 4. Planned code changes (TDD, red/green per slice)

1. **F1 detection + normalizer** (`HookAdapter.ps1`): camel→snake payload
   normalization, tool-name kebabing for lookup, new detection rules, `.local`
   log suffix. Unit fixtures for all four payload shapes.
2. **F2 output contract** (`HookAdapter.ps1` `Format-Output`): dual envelope,
   exit-0-for-Decisions policy, Codex deny+`systemMessage`, unknown-tool → ask
   (flips pinned fixtures from exit 2 → ask — planned red).
3. **F3 answer deadline** (`ConfigLoader.ps1` + `LlmReview.ps1`/`Hook.ps1`):
   validate `answer_deadline_ms` (int, per-harness, `< 30000` for
   Copilot/Local); enforce with the existing runspace-abandon mechanism; mock
   hang → ask at deadline.
4. **F4 fullpipe**: spawn real `Hook.ps1` with each of the four payloads;
   assert envelope + exit 0 + correct log suffix.

## 5. Manual rollout checklist (after green)

- [ ] Rewrite `~/.copilot/hooks/pre-cli-hook.json` (content §3 Q7) — keep the
      old `7200000` file until F3 lands, then it becomes bare by definition.
- [ ] Create `~/.codex/hooks.json` (§3 Q8); open a Codex session → `/hooks` →
      trust.
- [ ] Delete the hooks block from repo `.claude/settings.local.json`.
- [ ] Delete `.github/hooks/pre-cli-hook.json`.
- [ ] Add `"chat.editor.localAgent.enabled": true` to VS Code user settings
      (Local stays pickable during interim).
- [ ] `config.local.json`: add `answer_deadline_ms`; `timeout_ms` unchanged.
- [ ] Drive Copilot manually via Session Target; start the 14-day gate log
      review (`c:\temp\logs\prehook\*.copilot.log` / `*.local.log`).
- [ ] Gate green → flip defaults (by 2026-12-01), remove
      `chat.hookFilesLocations` block, schedule Local settings removal
      2027-01-15.

## 6. Verification recipes

- Copilot: new session → harmless task using a tool → expect exactly one
  record in `yyyy-MM-dd.copilot.log`; `echo hi`-class commands allow
  silently; unknown tool names produce an approval prompt naming the tool.
- Local: same via Local target → `yyyy-MM-dd.local.log` (new suffix).
- Claude: unchanged behavior → `yyyy-MM-dd.claude.log`.
- Codex: trusted session → `echo hi` allows; a modifying command prompts
  nowhere but is denied with `systemMessage` + reason fed to the model →
  `yyyy-MM-dd.codex.log`.
- Fail-closed proof: stop the gateway (`127.0.0.1:3030`) or let a long
  command exceed the deadline under Copilot → expect the
  "LLM assessment incomplete … fail-closed" ask, not a fall-through.

## 7. Implementer brief (read before coding; pre-answers the open details)

**Reading list (in order):** repo `CLAUDE.md` (TDD + fixture rules),
`CONTEXT.md`, ADR `docs/adr/0001-…`, this doc, `PROGRESS.md` head sections,
`src/HookAdapter.ps1` (`Detect-IDE`, `Get-CommandFromInput`,
`Format-Output`), `src/Hook.ps1` (steps 4/6/8/8b/12/14), `src/Logger.ps1`
(`$ideSuffix`), `src/ConfigLoader.ps1` (block-validation patterns),
`src/Run-AllTests.ps1` + `test/config/live/TestRunner.ps1` +
`test/config/live/FullPipeTestRunner.ps1` (runner/fixture conventions).

**Pre-decided implementation choices (pin each with a test, do not re-litigate):**

1. `Detect-IDE` returns existing values plus **`'Local'`**; Logger gains
   suffix mapping `Local → 'local'` (files `yyyy-MM-dd.local.log`). Keep the
   function/variable names.
2. Normalizer lives in `HookAdapter.ps1`, runs right after JSON parse in
   `Hook.ps1` Step 3.5, and rewrites the parsed object: `toolName→tool_name`,
   `toolArgs→tool_input`, `sessionId→session_id`, `turnId→turn_id` (defensive),
   epoch-ms `timestamp→timestamp` (leave as-is; detection reads presence).
   Tool-name kebabing (`([a-z0-9])([A-Z])` → `$1_$2`, lowercased) applies to
   the intercept/ignore/path-mapping **lookup key only**; log lines keep the
   raw name.
3. Reason-string templates (exact wording is contractual via tests):
   - deadline: `LLM assessment incomplete (<N> ms <Harness> answer deadline) - fail-closed`
   - Codex deny: `ask unsupported on Codex - denied fail-closed: <original reason>`
   - Codex `systemMessage`: `PreToolUse hook DENIED (Codex has no ask): <original reason>. Tell the agent to proceed if intentional.`
4. Unknown-tool path: reuse the existing "unknown tool: X" reason but return
   Decision `ask` + exit 0 (update the pinned fixtures — this is the planned
   F2 red).
5. `answer_deadline_ms` enforcement: measure from `$startTime` (Hook.ps1 step
   5); check before LLM wait and inside the LLM completion path using the
   existing runspace-abandon mechanism; effective budget
   `min(deadline, timeout_ms + 2000)`.
6. New fixtures live under `test/config/harness-contracts/` with their own
   `config.json` (per CLAUDE.md — never the live root configs); register the
   suite in `src/Run-AllTests.ps1`.

**Do-not-touch list (rollout is user-owned, §5, AFTER green):** anything under
`~/.copilot/`, `~/.claude/`, `~/.codex/`, VS Code user settings,
`config.local.json` (except: this feature's documented test fixtures),
and do NOT delete `.github/hooks/pre-cli-hook.json` or the repo
`.claude/settings.local.json` hooks block during coding — those deletions are
checklist items gated on green suites.

**Ambiguity rule:** if anything else is unclear, choose the fail-closed
option, pin it with a test, and record the choice in `PROGRESS.md` — do not
block on questions.

### 7.3 Base-branch amendments (2026-11-14, after re-basing the design onto `origin/feature/workspace-roots`)

The work branch `feature/quad-contract` is cut from
`origin/feature/workspace-roots` @ `8bf7f2f` (baseline **1634/1634**), which
carries the `workspace_roots` feature. Re-analysis verdict: **the design
holds**; three amendments:

1. **`Add-WorkspaceRoots` gate must widen (required, F1 scope).** The
   workspace-roots code returns immediately unless `$IDE -eq 'Copilot'`, and
   today's Signal 0b maps `__vscode-` payloads to `Copilot`. F1 renames those
   payloads to **`Local`** — without this fix, multi-root path policy silently
   turns off for Local sessions. Change the gate to
   `$IDE -notin @('Copilot','Local')` and pin it with a test
   (WR-10..14 territory). Claude-harness-in-VS Code sessions stay excluded
   (payload-indistinguishable from Claude Code CLI) — accepted degradation,
   single-CWD semantics.
2. **No normalizer additions needed for workspace_roots.** Discovery reads no
   payload fields — it anchors on the process CWD (`$Config._cwd`) and scans
   `%APPDATA%\Code\User\workspaceStorage`; its only contact with our design is
   the `-IDE` gate above.
3. **Known Copilot ask-rendering quirk (documented on this base branch,
   2026-10-20 section):** VS Code renders hook-originated `ask` confirmations
   through the `kind:"hook"` default path as a **raw JSON dump** instead of
   the clean reason. Not fixable from the hook; verification recipes in §6
   should expect JSON-looking prompts on Copilot, not treat them as failure.

Branch hygiene notes: `feature/tier-integrity`'s two commits (24c4917
static-allowlist pins, 08d6bfb git subcommand config) are **not** in this
base — both are `config.json`/fixture-only, production already carries them
via the git-ignored live `config.local.json`, so nothing is lost; merge that
branch (or cherry-pick) later — its `config.json` edits land in different
regions. Cosmetic: `8bf7f2f` re-encoded several `HookAdapter.ps1` comment
em-dashes to literal `?` characters; F1/F2 touch those files anyway — fix the
mojibake in passing, don't propagate it.
