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
it. To force one domain, flip that line to `"strict"` — e.g. inside `commands.Git`;
see the fixture `test/config/live/config.git-strict.json` for a working example.

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

## 11. Editing checklist (any config change)

1. Valid JSON (no trailing commas) and valid regex in every pattern.
2. Run one suite immediately → catches fail-closed deadlocks while you can still act.
3. Run the full differential before committing.
4. Add/adjust test cases for every behavior-affecting change.
5. Commit on a feature branch; note the change in `PROGRESS.md`.
