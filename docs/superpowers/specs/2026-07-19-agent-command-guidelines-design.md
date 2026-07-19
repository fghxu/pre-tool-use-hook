# Agent Command Guidelines + config.json Gap-Fill — Design

**Date:** 2026-07-19
**Status:** Approved (user sign-off in brainstorming session)

## 1. Background and Problem

A full scan of `C:\temp\logs\prehook\*.log` (all agents: claude, copilot, codex) found **895 "unknown command" classifications**. They decompose into two root causes:

### Category A — Heredoc / embedded-content shrapnel: 507 hits (57%)

A single multi-line command shatters into dozens of phantom "commands" when the splitter cannot isolate embedded content:

- Kotlin/test files written via heredoc → fragments `val`, `import`, `fun`, `class`, `assertEquals(`, `BlockType.CODE`, `listOf(word(...`
- `git commit` / `git tag -a` with multi-line `-m` messages → `Co-Authored-By:`, `docs:`, `Deploy`, `Summary`, random message words
- `pwsh -Command` with escaped `\$variables` → `\$code = ...` fragments

### Category B — Real commands the hook cannot classify: 388 hits (43%)

| Hits | Command | Nature |
|---|---|---|
| ~43 | `powershell.exe -NoProfile -Command "<pipeline>"` / `-File` | format: inline blob |
| 30 | `cmd //c "..."` | format: wrapper |
| 20 | `./gradlew ...` | DB gap |
| 14 | `adb ...` | DB gap |
| 11 | `reg query` | DB gap |
| 9 + 9 | `git worktree`, `git branch --show-current` | DB gap (branch fixed since) |
| 7 + 7 | `git ls-files`, `git tag -a` | DB gap (ls-files fixed since) |
| ~10 | `unzip`, `javap`, `python3 -c`, `node`, `gh`, `net share`, `sc qc` | DB gap |

### Key constraint: no feedback loop

The PreToolUse hook verdict is one-way — it approves or prompts; the classification never returns to the agent as usable feedback. Therefore "retry-with-rewrite" strategies are impossible and the guidance must be **prevention-only**: teach agents to emit hook-friendly forms on the first attempt. Guidance must never restrict what tasks the agent may perform — only the *form* of emitted commands. Genuinely unknown commands may still be run; they simply prompt.

## 2. Scope — Four Deliverables

| # | Deliverable | Path |
|---|---|---|
| 1 | Canonical guidance file (Option A) | `docs/agent-command-guidelines/guidance.md` |
| 2 | Backup skill (Option B) | `docs/agent-command-guidelines/hook-friendly-commands/SKILL.md` |
| 3 | Install companion | `docs/agent-command-guidelines/README.md` |
| 4 | config.json gap-fill + XML test cases | `config.json`, `test/test-cases.adhoc.xml` |

`guidance.md` is the single source of truth. `SKILL.md` is condensed from it. `README.md` contains installation/maintenance only, no rules.

### Note on in-flight config.json work

`config.json` currently has uncommitted changes that already cover some log offenders: `git ls-files` (read_only), `git branch --show*` (read_only), `git worktree add` (modifying/low), `sc query` (read_only), `python3`/`py` aliases. Deliverable 4 builds on top of these and does not duplicate them.

## 3. Deliverable 1 — `guidance.md`

Audience: LLM agents (Claude Code, Copilot CLI, Codex CLI) composing shell/PowerShell commands on a machine protected by the hook. Tone: short imperative rules with a one-line rationale each.

### Content spec

**Intro (3 lines max):** A PreToolUse hook classifies every command. Unclassifiable forms → "unknown command" → manual approval → slower session. These rules maximize first-attempt classifiability without restricting what you may do.

**Rules:**

- **R1 — No heredocs.** Never use heredocs (`<<EOF`, `@"..."@`) to write files or feed multi-line input. Use the Write/create file tool for file contents. *(Eliminates the #1 offender: 57% of all unknowns.)*
- **R2 — Multi-line commit messages → repeated `-m`.** `git commit -m "Subject" -m "Body line"` — never a multi-line `-m` string. Same for `git tag -a -m`.
- **R3 — No `powershell.exe -NoProfile -Command "<pipeline>"` blobs.** Run cmdlets directly, one per line. If a shell wrapper is unavoidable, keep the inner command a single simple cmdlet.
- **R4 — No `cmd //c "..."` wrappers.** Invoke the target command directly.
- **R5 — Simple quoting.** One quoting layer; no `\$` / `\"` escape soup; no `pwsh -Command` with escaped variables — write a `.ps1` via the file tool if logic is non-trivial (see known-gap note about `-File`).
- **R6 — One command per line.** Prefer separate invocations over `&&`/`;` chains when steps are independent. Keep pipelines simple and linear.
- **R7 — Known-gap commands.** The following prompt regardless of form (not yet in the hook DB): `gradlew`, `adb`, `unzip`, `javap`, `gh`, `net share`, `sc qc`, `powershell.exe -File`, `python3 -c`. Run them plainly and unwrapped when the task needs them; do not contort the command to avoid the prompt. *(This list shrinks as Deliverable 4 lands; guidance.md gets a maintenance note to that effect.)*

**Authoring constraint:** every form the guidance recommends must be verified to classify cleanly through the hook (TestRunner or direct hook invocation) before the file is finalized. No rule may recommend a form that itself classifies unknown.

## 4. Deliverable 2 — `hook-friendly-commands/SKILL.md`

Standard skill frontmatter:

```yaml
---
name: hook-friendly-commands
description: Use when composing shell or PowerShell commands - emits forms the PreToolUse safety hook can auto-classify, avoiding "unknown command" approval prompts
---
```

Body: condensed R1–R7 (same wording, rationale trimmed), plus a pointer to `guidance.md` as the full source. No scripts (user decision: guidance text only, no validator).

## 5. Deliverable 3 — `README.md` (install companion)

Per-IDE install matrix:

| IDE | Option A (guidance.md) | Option B (skill) |
|---|---|---|
| Claude Code | Add `@<absolute-path-to-guidance.md>` import line to `~/.claude/CLAUDE.md` (import syntax supported) | Copy `hook-friendly-commands/` to `~/.claude/skills/` |
| Copilot CLI | **No import syntax** — paste contents into `~/.copilot/AGENTS.md` (global) or repo `AGENTS.md` / `.github/copilot-instructions.md` | Skills load only via installed plugins → the paste-into-AGENTS.md route is the practical install |
| Codex CLI | Paste contents into `~/.codex/AGENTS.md` (no import syntax) | Copy to `~/.codex/skills/` on current builds (version-dependent — marked "verify") |

Also includes: maintenance note (edit `guidance.md` only; re-paste into AGENTS.md targets when it changes) and a "how to confirm it's loaded" line per IDE. Copilot CLI's inability to follow file links is the reason paste (not reference) is documented for AGENTS.md targets.

## 6. Deliverable 4 — config.json gap-fill

| Command | Entry | Risk |
|---|---|---|
| `git worktree list` | read_only | — |
| `git worktree remove` / `prune` / `move` / `lock` / `unlock` | modifying | low |
| `git tag -a` / `-m` / `-s` (creation forms) | modifying | low |
| `reg query` | read_only | — |
| `adb devices`, `adb logcat` (without `-c`), `adb shell getprop *`, `adb shell pm list *` | read_only | — |
| `adb install`, `adb push`, `adb shell am start *`, `adb logcat -c` | modifying | low |
| `gradlew` / `./gradlew` / `.\gradlew` (any task) | modifying | low |
| `unzip` | modifying | low |
| `javap` | read_only | — |
| `net share` (bare), `net share <name>` (view) | read_only | — |
| `net share <name>=...`, `net share <name> /delete` | modifying | high |
| `sc qc` | read_only | — |
| `gh pr list/view/status`, `gh repo view`, `gh release list/view` | read_only | — |
| other `gh *` state-changing subcommands (`create`, `merge`, `close`, `delete`, `edit`) | modifying | medium |

Supporting changes:

- Add `gradlew` and `adb` to `known_command_prefixes`.
- Verify at implementation time whether `sc config/create/delete/start/stop` modifying entries already exist; add only if missing.

**Tests:** new cases appended to `test/test-cases.adhoc.xml` (precedent: ast-arbiter +24). Each new config entry gets ≥1 positive case; `net share` and `gh` get mixed read_only/modifying cases; `adb logcat` vs `adb logcat -c` gets a contrast pair.

## 7. Verification

1. **config.json:** full differential re-run of all suites (test-cases.xml, adhoc, var-assignment, fullpath, redirect-normal, redirect-strict, trustedpattern, new-samples, fullpipe). Pre-existing suites must be byte-identical to current results; adhoc grows by exactly the new cases, all passing.
2. **guidance.md:** every recommended form in R1–R7 is run through the hook/classifier and confirmed to NOT classify as unknown (authoring constraint, Section 3).
3. **README.md:** documented install paths verified to exist on this machine (`~/.claude/`, `~/.copilot/`, `~/.codex/` as applicable).

## 8. Out of Scope

- Hook parser changes to support `powershell.exe -File` or `cmd //c` natively (format discouraged via guidance instead; may be a future spec).
- Classifying `python3 -c "<arbitrary code>"` — remains fail-safe prompt **by design** (arbitrary code execution must not auto-approve).
- Any validator/precheck script (user decision: guidance text only).
- Committing the pre-existing uncommitted `config.json` changes as a separate act — Deliverable 4's changes land together with whatever is already in the working tree, in one commit, since they touch the same sections.

## 9. Success Criteria

1. The three artifacts exist under `docs/agent-command-guidelines/` and README install steps are followable without ambiguity.
2. All log-offender commands in the Section 6 table classify as specified (proven by new test cases).
3. All pre-existing test suites remain byte-identical/green.
4. When the guidance is followed by an agent, Category A unknowns (heredoc/message shrapnel — 57% of observed volume) are eliminated; Category B drops to the explicitly-accepted `python3 -c` residue.
