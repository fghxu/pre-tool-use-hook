# config.json Reference Guide

**Audience:** maintainers of the PreToolUse hook. This document explains every top-level block in `config.json`, what it controls, and what to watch out for when adding or modifying entries.

**Golden rule before any edit:** the hook loads and validates `config.json` on *every* PreToolUse event. An invalid config (bad JSON or bad regex) makes the hook **fail-closed**: every tool call of the agent is blocked — a total session deadlock. After every config edit, immediately run at least one suite:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"
```

For anything touching patterns or prefixes, run the full differential (all 9 suites) and compare against the baseline in `PROGRESS.md`.

---

## 1. Top-level scalars

| Key | Purpose | Notes |
|---|---|---|
| `version` | Config schema version. | Informational. |
| `description` | Human-readable summary. | Informational. |
| `log_file_path` | Directory for per-day hook logs (`C:\temp\logs\prehook\`). | Must exist / be writable. These logs are the source for "unknown command" analysis. |
| `modifying_strictness` | `normal` or `strict`. Governs redirect-write policy and some AWS/mixed cases. | Test suites run both values (`-Strictness normal/strict`); changes here shift redirect-suite results. |
| `risk_legend` | Text descriptions of low/medium/high. | Documentation only — not read by logic. |

## 2. `editable_paths` / `system_paths` — redirect write policy

**What they do:** applied by the Parser's redirect analysis (`echo x > target`) to the *target path* of `>` / `>>` inside **shell commands**.

- `editable_paths`: writes under these roots auto-approve when `modifying_strictness` is `normal`/`loose`.
- `system_paths`: writes under these roots **always prompt**, any strictness. Windows entries are raw regex; linux entries too (see ConfigLoader notes).

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

The whole-string, pre-classification gate: untrusted match → **ask**; trusted match → **allow**; both checked **before** the command DB and before command chunking.

**Full details, entry-by-entry rationale, and how-to-add guide: see `docs/trusted-untrusted-patterns.md`.**

Cardinal rules (violating these is how you get `rm -rf /` auto-approved):
- **Never** an unanchored or catch-all `trusted_pattern` (`.*`, `^(?!…).*$`). Trusted short-circuits all classification.
- Always anchor with `^` (and usually `.*$`).
- Every trusted root pattern must carry the executable-extension guard.

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

**What it does:** maps `tool_name` → dot-path of the payload field containing the string to classify (`"Bash": "tool_input.command"`, `"Write": "tool_input.file_path"`). Resolution order:

1. Mapping hit → that field's string.
2. Mapping miss/failure → **heuristic walk**: first string field containing `|`/`;`/`&&` or starting with a `known_command_prefix`.
3. Nothing found → `null` → hook treats as no command (skip).

**When adding entries:**
- If the mapped path doesn't exist in the real payload, you silently fall to the heuristic — for file tools that can extract the file *content* (if it contains `;` or `|`) and feed it to the command classifier, producing garbage "unknown command" prompts. Verify new mappings against a real payload (capture one from `log_file_path` logs or a fullpipe test).
- `PowerShell` must stay mapped to `tool_input.command` — without it, operator-less cmdlets slip through unmonitored.
- Mapping a file tool to its path field means `trusted/untrusted_pattern` (not the command DB) decides — that's the file-tool gating design.

## 8. `dry_run_flags`

**What it does:** exact command prefixes that downgrade a modifying command to read-only (`terraform plan`, `rsync --dry-run`, `kubectl apply --dry-run=client`…).

**When adding entries:** the key must match the command as written (prefix match). Only add flags that *provably* change nothing.

## 9. `commands` — the classification database

Domains: `DOS_CMD`, `PowerShell`, `Linux`, `Git`, `Terraform`, `Docker`, `Kubernetes`, `AWS_CLI`. Entry shape:

```json
{ "name": "reg query", "patterns": ["reg query *"], "risk": "high", "description": "..." }
```

**Semantics that surprise people:**
- An entry in a domain's `read_only` array is **auto-approved — even if it carries `"risk"`** (proven: `git add` → allow). `risk` on read_only entries is informational. If it must prompt, it belongs in `modifying`.
- Patterns are **raw regex**, compiled directly — `*` is a regex quantifier, not a glob (`"git status*"` literally means "statu" + zero-or-more "s"). Style is sloppy but established; follow the existing form and prefer adding `^`-anchored or lookahead-bearing patterns where ambiguity matters (precedents: `wmic (?!.*process.*call.*create).*`, `^git tag$`).
- **An invalid regex anywhere in `commands` deadlocks the hook fail-closed** (the `.\gradlew` incident — `\g` is not a valid escape). Use character classes for path separators: `[.][/\\]gradlew`.
- Domain routing is content-based (`Get-CommandDomain` in Parser.ps1): PowerShell markers → hardcoded binary prefixes (docker/kubectl/terraform/aws/git/pwsh/cmd /c) → DOS markers → **fallback `linux`**. A command whose tool isn't in the prefix table lands in `linux` — put entries for such tools in the `Linux` domain (that's where `adb`, `unzip`, `javap`, `gradlew`, `gh` live). A brand-new `commands` domain is *unreachable* without a `Parser.ps1` code change.
- `PowerShell` domain is verb-driven: `read_only_verbs` / `modifying_verbs` (high/medium/low) classify any `Verb-Noun` cmdlet not explicitly listed. `parameter_commands` (e.g. `Invoke-RestMethod -Method`) override by parameter value, with a `default` decision.
- `AWS_CLI` is prefix-driven: `read_only_prefixes` (`describe-`, `list-`…) / `modifying_prefixes`.

**Workflow for new commands (established by the LogGap work):**
1. Add failing test cases to `test-cases.adhoc.xml` first (RED).
2. Add config entries (GREEN).
3. Run the full 9-suite differential — byte-identical except your new cases.

## 10. Editing checklist (any config change)

1. Valid JSON (no trailing commas) and valid regex in every pattern.
2. Run one suite immediately → catches fail-closed deadlocks while you can still act.
3. Run the full differential before committing.
4. Add/adjust test cases for every behavior-affecting change.
5. Commit on a feature branch; note the change in `PROGRESS.md`.
