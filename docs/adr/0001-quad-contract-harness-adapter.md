# 0001 — One hook, four harness contracts

VS Code 1.146 turned "which agent runtime invokes us" into four different wire
contracts (Local, Copilot, Claude, Codex) that can each be selected per chat
session, and the Copilot harness ignores the nested `hookSpecificOutput`
envelope we emit. We decided that the single `src/Hook.ps1` speaks **all four
contracts itself** — it sniffs the payload shape to detect the harness, emits
*both* output envelopes (nested + top-level `permissionDecision`), and always
exits 0 for any Decision (exit 2 reserved for Fatal) — instead of growing
per-harness front-end scripts or rewriting for Copilot only.

## Considered Options

- **Copilot-only rewrite** — rejected: breaks Claude harness, Claude Code CLI,
  and the DSH bridge, which all still consume the nested envelope.
- **Per-harness front-end scripts sharing the classify core** — rejected:
  duplicates the registration × payload × output matrix and drifts.
- **Quad-contract single adapter** (chosen) — the output side is ~15 lines and
  legal under every contract; only Codex needs a vocabulary map (`ask` →
  `deny` + `systemMessage`, since Codex parses `ask` but then fails open).

## Consequences

- **Registrations are user-scope, one per harness, and carry no timeout**:
  `~/.copilot/hooks/pre-cli-hook.json` (camelCase `preToolUse`, `version: 1`),
  `~/.claude/settings.json`, `~/.codex/hooks.json` (+ manual `/hooks` trust).
  The repo `.claude/settings.local.json` hooks block and
  `.github/hooks/pre-cli-hook.json` are deleted — Copilot *combines* sources
  without dedup, so they only caused double/triple invocation.
- **All timing lives in `config.local.json`** (`llm_second_opinion.timeout_ms`
  plus the new `answer_deadline_ms` map). The hook enforces a per-harness
  answer deadline kept below each harness's bare-default kill timer (30 s for
  Copilot/Local); on deadline it degrades fail-closed to `ask`. Harness
  timeouts are fail-open by contract and therefore must never fire — the
  7 200 000 ms entries in registration files are obsolete and removed.
- Local is deprecated (removal Feb 2027); cutover gate and dates are tracked
  in `docs/Updates/Update-2026-11-14-copilot-harness-migration.md`.
- Vocabulary is pinned in `CONTEXT.md` (Harness / Contract / Registration /
  Decision / Fatal failure / Answer deadline). `Detect-IDE` and `$ide` remain
  as legacy spellings of harness detection.
