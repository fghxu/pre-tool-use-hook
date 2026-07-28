# PreToolUse Hook — Command Classification System

A cross-IDE preToolUse hook that intercepts terminal commands before execution, classifies them as read-only (auto-allow) or modifying (prompt the user), and enforces safety policies across AI-powered developer tools.

## What It Does

When an AI coding assistant (Claude Code, GitHub Copilot, Codex CLI) invokes a terminal tool such as `run_in_terminal`, `bash`, or `Bash`, this hook intercepts the request and runs it through a multi-stage classification pipeline:

```
Input JSON (stdin)
    │
    ▼
Step 0: Tool name filter      — skip ignored tools, flag unknown tools
    │
    ▼
Step 1: Extract command       — pull the command string from the tool input
    │
    ▼
Steps 2-3: Trusted/untrusted  — regex gate checks (fast path)
    │
    ▼
Step 4: Classification engine
    ├── Domain detection (content-based: DOS, Linux, PowerShell, Docker, …)
    ├── Split into sub-commands (handle ;, &&, ||, | chains)
    ├── PowerShell AST extraction (preferred over regex for PS commands)
    ├── Parameter-aware rules (e.g. Invoke-RestMethod -Method, curl -d)
    ├── Nested command detection (ssh, docker exec, kubectl exec, pwsh -Command)
    ├── Subshell extraction $(…)
    ├── Redirection target analysis (> file, >> file, editable_paths, CWD)
    └── Three-tier per-domain match: read_only → strictness_gated → modifying
    │
    ▼
Aggregate: "allow" only if every sub-command is read-only
    │
    ▼
Output JSON (stdout): { permissionDecision, permissionDecisionReason }
```

**Result**: read-only commands (`ls`, `cat`, `Get-Process`, `docker ps`, `kubectl get`,
`Invoke-RestMethod -Method Get`, `curl https://example.com`) pass through silently. Modifying
commands (`rm`, `Stop-Process`, `terraform apply`, `kubectl delete`, `Invoke-RestMethod -Method Post`,
`curl -d '{…}'`) prompt the user for confirmation with a reason showing exactly which sub-command
triggered the block. In between sits the `strictness_gated` tier: low-risk commands (`git add`,
`git commit`, `mkdir`, `Set-Content`, `terraform init`, …) auto-allow in `normal`/`loose` mode and
prompt only when strictness is `strict`.

**Exit-code contract**: the hook exits `0` whenever it produced a decision — the JSON on stdout is
the verdict (`allow` / `ask`; `deny` for Codex). Exit `2` is reserved for fatal failures (empty
stdin, unparseable JSON, config load error) where no decision exists; an IDE treats exit `2` as a
blocking hook error and never shows a prompt. This is why file-writing tools (`Write`, `Edit`,
`MultiEdit`, `NotebookEdit`, Copilot `create_file`, …) also exit `0` for path-policy `ask`s — an
`ask` must reach the IDE as JSON so the user gets a confirmation prompt, exactly like a modifying
Bash/PowerShell command. (Pinned by `test-fullpipe.xml` *-FileTool* cases.)

## Supported IDEs

| IDE | Hook Event | Detection Method |
|-----|-----------|------------------|
| **Claude Code** | `PreToolUse` | PascalCase event name, presence of `tool_use_id`, ISO 8601 timestamps |
| **GitHub Copilot** | `preToolUse` | camelCase event name, absence of `tool_use_id`, Unix epoch timestamps |
| **Codex CLI** | `PreToolUse` | PascalCase event name, presence of `turn_id` or `model` fields |

IDE detection uses multi-signal voting (see `HookAdapter.ps1`). The output format adapts
automatically per-IDE — Codex uses `permissionDecision: "deny"` instead of `"ask"`.

## Supported Command Domains

| Domain | Examples | Classification Approach |
|--------|----------|------------------------|
| **DOS / CMD** | `dir`, `del`, `move`, `schtasks`, `bcdedit` | Pattern matching + shell flow-control detection |
| **Linux / Bash** | `ls`, `rm`, `find`, `systemctl`, `apt-get`, `curl`, `python` | Pattern matching + parameter rules + shell keyword/heredoc/function detection |
| **PowerShell** | `Get-Process`, `Stop-Service`, `Invoke-Command`, `Invoke-RestMethod` | Pattern matching + verb-based classification + AST parsing + parameter rules |
| **Docker** | `docker ps`, `docker rm`, `docker compose up` | Pattern matching + nested command extraction |
| **Kubernetes** | `kubectl get`, `kubectl delete`, `helm install` | Pattern matching + `kubectl exec` nesting detection |
| **Terraform** | `terraform plan`, `terraform apply`, `terraform destroy` | Pattern matching for subcommands |
| **AWS CLI** | `aws ec2 describe-*`, `aws s3 cp`, `aws lambda delete-*` | Prefix-based operation classification |
| **Git** | `git status`, `git push`, `git reset` | Pattern matching |

## Project Structure

```
pretoolhook/
├── src/
│   ├── Hook.ps1              # Entry point (stdin → stdout hook script)
│   ├── HookAdapter.ps1       # IDE detection, command extraction, output formatting
│   ├── Classifier.ps1        # Top-level classification pipeline orchestrator
│   ├── Parser.ps1            # Domain detection, command splitting, AST + redirect analysis
│   ├── Resolver.ps1          # Pattern matching + parameter-rule engine against config
│   ├── ConfigLoader.ps1      # JSON config loading, validation, regex compilation
│   ├── Logger.ps1            # Daily JSONL record files + human-readable text logs
│   ├── TestRunner.ps1        # Single-suite test runner (-ConfigPath/-Strictness/-Cwd)
│   └── Run-AllTests.ps1      # One-shot runner for every suite (verdicts + baselines)
├── config.json               # Runtime configuration — the classification database (YOU edit this)
├── test/config/
│   ├── live/                      # Suites validating the live policy (run via src/Run-AllTests.ps1)
│   │   ├── config.json                # TEST COPY of repo-root config.json (sync, don't hand-edit)
│   │   ├── config.strict.json         # strict fixture for the redirect suite (generated)
│   │   ├── Sync-Fixtures.ps1          # refreshes both configs from repo-root config.json
│   │   ├── test-cases.xml             # Main classification suite (701 cases)
│   │   ├── test-cases.strictness-gated.{normal,strict}.xml
│   │   ├── test-cases.redirect-strict.xml
│   │   ├── test-cases.trustedpattern.xml
│   │   ├── test-fullpipe.xml + FullPipeTestRunner.ps1  # Per-IDE full-pipe integration tests
│   │   └── test-cases.codex.ps1       # Codex IDE detection + output mapping unit tests
│   └── test-strictness-gate/      # Isolated normal/strict fixture sandbox (+ own Run-Tests.ps1)
├── debug/                    # Debug and verification scripts
├── README.md                 # This file
├── INSTALL.md                # Installation guide
├── PROGRESS.md               # Running work log (goals, completed steps, baselines)
└── docs/
    ├── config-json-guide.md     # Field-by-field config editing guide (read before editing config.json)
    └── superpowers/{specs,plans}  # Design specs and TDD implementation plans
```

---

## Configuration — `config.json`

This is the **runtime configuration** you edit to add commands, change classifications, tune
strictness, and define safe/forbidden paths. It is loaded once per hook invocation, validated, and
pre-compiled (regexes compiled, lookups built) for fast matching.

Below is a reference for **every section**, in the order they appear in the file, followed by
recipes for common tasks.

### Top-level fields

| Field | Type | Purpose |
|-------|------|---------|
| `version` | string | Config schema version (currently `"1.0"`). |
| `description` | string | Free-text description. |
| `log_file_path` | string | Directory for daily log files. Empty string → default `~/.pretoolhook/`. |
| `global_modifying_strictness` | `"normal"` \| `"strict"` \| `"loose"` | How aggressive the write-policy is. See **Strictness** below. (Renamed from `modifying_strictness` 2026-07-28 — the loader rejects the legacy key fail-closed.) |
| `editable_paths` | object (optional) | Whitelist of paths whose writes are auto-approved. See **editable_paths**. |
| `system_paths` | object | Blacklist of paths whose writes always require approval. See **system_paths**. |
| `safe_expressions` | object | Allowlist for the safe-expression certifier (AST arbiter for pure PowerShell expressions). |
| `known_command_prefixes` | array | Command names used as domain-detection hints. |
| `trusted_pattern` | array of regex | Commands that match → **allow immediately** (fast path). |
| `untrusted_pattern` | array of regex | Commands that match → **ask immediately** (checked before `trusted_pattern`). |
| `intercept_tool_name` | array of tool names | Tool calls to classify. |
| `ignore_tool_name` | array of tool names | Tool calls to skip (silently allow). |
| `tool_name_mapping` | object | Per-tool JSON field path that holds the command string. |
| `path_tool_mapping` | object | Per-tool JSON field path that holds the target file path (for Write/Edit-type tools). |
| `dry_run_flags` | object | Maps a command prefix to `read-only` when a dry-run form is used. |
| `risk_legend` | object | Human-readable text for `low` / `medium` / `high` risk. |
| `commands` | object | Per-domain classification database. See **The `commands` section**. |

#### `global_modifying_strictness` — the write-policy knob

Controls how redirection targets (`>`, `>>`) and the `editable_paths` whitelist are enforced.
`system_paths` **always** requires approval (it wins over everything else), and the **current
working directory (CWD) is always editable** (including subdirectories) in every mode.

For a redirect target that is not temp/discard, not a system path, and not under CWD:

| Mode | Target matches `editable_paths` | Everything else |
|------|---------------------------------|-----------------|
| `strict`  | allow | **ask** |
| `normal`  | allow | **ask** when `editable_paths` is non-empty, otherwise allow (the default, permissive behavior) |
| `loose`   | allow | **allow** (additive — `editable_paths`/CWD are guaranteed safe; nothing else is restricted) |

Default is `normal`. Use `strict` to lock writes down to a whitelist, `loose` to be permissive.

#### `editable_paths` — writable whitelist (optional)

Paths matching these patterns are auto-approved for writes (via `>` / `>>`), alongside CWD.
The structure mirrors `system_paths` (`{ "linux": […], "windows": […] }`), but with one
difference: **both sides are raw regex** — unlike `system_paths`, the `linux` list is **not**
escaped to a literal, so you can use regex on Linux paths too. Patterns are matched
case-insensitively against the resolved target path; end a pattern with a separator (or `.*`)
to match a directory and everything beneath it.

```jsonc
"editable_paths": {
  "linux":   ["/tmp/", "/home/[^/]+/workspace/.*"],
  "windows": ["c:\\\\temp\\\\.*", "D:\\\\temp\\\\"]
}
```

#### `system_paths` — always-ask blacklist

Writes (via `>` / `>>`) to paths under these always require approval, in every mode. `linux`
entries are treated as **literal** path prefixes; `windows` entries are **regex**.

```jsonc
"system_paths": {
  "linux":   ["/etc/", "/var/", "/usr/", "/boot/", "/sys/", "/proc/", "/opt/"],
  "windows": ["[A-Za-z]:\\\\Windows\\\\", "[A-Za-z]:\\\\Program Files\\(x86\\)\\\\"]
}
```

#### `trusted_pattern` / `untrusted_pattern` — fast-path regex gates

Checked against the raw command **before** full classification. `untrusted_pattern` is checked
first and overrides everything; then `trusted_pattern`. Both are regex (single-line mode, so `.*`
can span a multi-line command).

```jsonc
"trusted_pattern":   ["^git status$", "^git diff$", "^docker\\s+exec\\s+(?:-\\S+\\s+)?comfyui\\b"],
"untrusted_pattern": ["^rm -rf /$", "^kubectl delete --all"]
```

#### `intercept_tool_name` / `ignore_tool_name`

`intercept_tool_name` lists tool names whose commands are classified. `ignore_tool_name` lists
tools that bypass the hook entirely (silently allowed, e.g. `read_file`, `Edit`, `Grep`). A tool
in **neither** list is treated as unknown → the hook asks (fail-safe).

#### `tool_name_mapping`

Maps a tool name to the JSON field path (dotted) inside the tool input that contains the command
string:

```jsonc
"tool_name_mapping": {
  "run_in_terminal":  "tool_input.command",
  "send_to_terminal": "tool_input.command",
  "Bash":             "tool_input.command"
}
```

#### `dry_run_flags`

Maps a command prefix to `"read-only"` when a dry-run/simulation form is recognized, so a normally
modifying command becomes read-only:

```jsonc
"dry_run_flags": {
  "terraform plan": "read-only",
  "kubectl apply --dry-run=client": "read-only",
  "apt-get install -s": "read-only"
}
```

### The `commands` section — per-domain classification

Each domain (`DOS_CMD`, `PowerShell`, `Linux`, `Git`, `Terraform`, `Docker`, `Kubernetes`,
`AWS_CLI`) has **three tiers**, checked in order:

- **`read_only`** — allows in every strictness mode.
- **`strictness_gated`** — allows in `normal`/`loose`, **asks in `strict`**. Since 2026-07-27
  every domain carries this tier and all `risk: "low"` commands live there (the "all-gated"
  policy). Note: gated cmdlet file-writes (`Set-Content`, `Out-File`, …) are **not**
  path-checked — they allow in normal mode even to system paths; strict mode still asks.
- **`modifying`** — always asks; the `risk` level (`low` | `medium` | `high`) shows in the prompt.

Entries look like:

```jsonc
{ "name": "del", "patterns": ["del *"], "risk": "high", "description": "Delete files" }
```

`patterns` are regex, auto-anchored with `^`; glob `*` is converted to `.*`. First match wins.

Each domain may also set its own **`modifying_strictness`** (`strict` | `normal` | `loose`),
consulted only when the global `global_modifying_strictness` is `normal` (a global `strict` or
`loose` forces every domain). The effective value drives the gated tier, AWS flag-stripping,
and `parameter_commands` fallback — path policy always uses the global value.

- **PowerShell only** — verb-based classification:
  - `read_only_verbs`: `["Get-*", "Test-*", "Write-Host", …]`
  - `modifying_verbs`: `{ "low": […], "medium": ["Set-*","New-*",…], "high": ["Remove-*","Stop-*",…] }`

- **AWS_CLI only** — operation-prefix classification:
  - `read_only_prefixes`: `["describe-", "list-", "get-", "head-"]`
  - `modifying_prefixes`: `{ "high": ["delete-","terminate-"], "medium": ["create-","put-","update-"] }`

- **`parameter_commands`** (optional; present on `PowerShell` and `Linux`) — value/presence-aware
  rules. See below.

#### `parameter_commands` — classify by a parameter's value or presence

Some commands are read-only **or** modifying depending on a flag/parameter, regardless of where it
appears in the line. Declare them here — **no code changes needed** to add a new command.

```jsonc
"parameter_commands": {
  "Invoke-RestMethod": {
    "aliases": ["irm"],
    "rules": [
      { "param": "Method", "match": "values", "values": ["Get","Head","Options"],     "decision": "read-only" },
      { "param": "Method", "match": "values", "values": ["Post","Put","Patch"],       "decision": "modifying", "risk": "medium" },
      { "param": "Method", "match": "values", "values": ["Delete"],                   "decision": "modifying", "risk": "high" }
    ],
    "default": "read-only"
  }
}
```

**Rule fields**

| Field | Meaning |
|-------|---------|
| `param` | Parameter/flag name. PowerShell: **without** leading `-` (e.g. `"Method"`). Linux/DOS: **with** leading marker (`"-d"`, `"--data"`, `"-X"`). A single name or an array of synonyms. |
| `match` | `present` (flag exists; covers **switch/boolean** params like `-d`, `--force`, `--version`) or `values` (the flag's value is in `values`). |
| `values` | Required for `values`; compared case-insensitively. |
| `decision` | `read-only` (→ allow) or `modifying` (→ ask). |
| `risk` | Optional `low`/`medium`/`high`, for modifying decisions. |

**Per-command fields**

| Field | Meaning |
|-------|---------|
| `aliases` | Optional other invocations of the same command (e.g. `["irm"]`, `["python3","py"]`). |
| `rules` | Array of rules (see above). |
| `default` | Decision when no rule matches. |
| `default_risk` | Optional risk for a `modifying` default. |

**Evaluation order (fail-safe):**
1. **Modifying** rules (first match → ask).
2. **Read-only** rules (first match → allow).
3. No match:
   - Declared parameter **absent** → use `default` (e.g. `Invoke-RestMethod -Uri X` with no `-Method` → default GET → allow).
   - Declared parameter **present with an unrecognized value** (e.g. `-Method Custom`, `-X FROG`) → **ask** in `strict`/`normal`, use `default` in `loose`.

**Position-independence:** PowerShell parameters are read from the AST; Linux/DOS flags from a
quote-aware tokenizer. Both find the flag wherever it sits (`-Method Post -Uri X` or
`-Uri X -Method Post`; `curl url -d '{…}'` or `curl -d '{…}' url`) and handle attached forms
(`-XPOST`, `--data=…`), combined short clusters, and quoting. This is why `Invoke-RestMethod`
rules also work inside `Invoke-Command -ScriptBlock { … }` and `pwsh -Command "…"`.

**Examples shipped in `config.json`:**
- `Invoke-RestMethod` / `Invoke-WebRequest` (`-Method` values) — GET/Head/Options read-only; Post/Put/Patch/Delete modifying.
- `curl` — `GET/HEAD/OPTIONS` via `-X` read-only; `POST/PUT/PATCH/DELETE` modifying; `-d`/`--data*`/`-F`/`-T` present → modifying; default read-only.
- `python` — `--version`/`-V`/`--help`/`-h` present → read-only; otherwise (running a script) → modifying.

### Recipes (common tasks)

**Add a new read-only / modifying command** — append to the domain's `read_only` or `modifying` array:
```jsonc
{ "name": "mytool query", "patterns": ["mytool query *"], "description": "read-only query" }
```
(Use the domain's `strictness_gated` array instead if it should auto-allow in normal but ask in
strict mode.)

**Add a parameter-aware command** (e.g. a future `Invoke-WebRequest`) — add a `parameter_commands` entry; zero code changes:
```jsonc
"My-Cmdlet": {
  "rules": [
    { "param": "Mode", "match": "values", "values": ["view"],            "decision": "read-only" },
    { "param": "Mode", "match": "values", "values": ["edit","publish"],  "decision": "modifying", "risk": "medium" }
  ],
  "default": "modifying", "default_risk": "medium"
}
```

**Auto-allow a specific safe command** — add a regex to `trusted_pattern` (e.g. `"^mytool check$"`).
**Always prompt for a dangerous one** — add to `untrusted_pattern`.

**Lock writes to the project + a temp dir** — set `"global_modifying_strictness": "strict"` and add those
paths to `editable_paths` (CWD is already always editable).

**Make a normally-modifying command read-only when dry-run** — add a `"prefix": "read-only"` entry
to `dry_run_flags`.

> Whenever you change `config.json`, add corresponding cases to `test/config/live/test-cases.xml`,
> run `test/config/live/Sync-Fixtures.ps1` to refresh the test copy, then run the suites (see below).

### Files you should NOT hand-edit

| File | Reason |
|------|--------|
| `src/*.ps1` | Source — changes should go through the test suite. |
| `test/config/live/config*.json` | Generated test copies — refresh with `test/config/live/Sync-Fixtures.ps1`. |
| `docs/superpowers/*` | Design documents, not runtime config. |

---

## How to Run the Tests

### Everything at once (`Run-AllTests.ps1`)

Discovers every suite under `test/config/live/`, runs each with its required invocation, and
reports REGRESSION/OK/IMPROVED against per-suite known-failure baselines (all currently 0):

```powershell
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1 -Filter strictness   # subset
```

**Important:** the suites run against `test/config/live/config.json` — a **test copy**, not the
repo-root config. After editing `config.json`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File test/config/live/Sync-Fixtures.ps1   # refresh the copy + strict fixture
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1
```

### Layer 1: Classification tests (`TestRunner.ps1`)

Tests the classification engine in isolation (no process spawning). Defaults to the main suite;
supports overrides:

```powershell
# Main suite (default)
pwsh -NoProfile -File src/TestRunner.ps1

# Any suite, with its config
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath test/config/live/test-cases.xml -ConfigPath test/config/live/config.json

# Filter by category
pwsh -NoProfile -File src/TestRunner.ps1 -Filter "Docker"

# Strict-mode: fixture config, or in-memory override (equivalent for command tiers)
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath test/config/live/test-cases.redirect-strict.xml -ConfigPath test/config/live/config.strict.json
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath test/config/live/test-cases.strictness-gated.strict.xml -ConfigPath test/config/live/config.json -Strictness strict

# editable_paths / CWD overrides (for redirect experimentation)
pwsh -NoProfile -File src/TestRunner.ps1 -Cwd 'C:\proj\' -EditablePaths 'c:\\temp\\.*'
```

Only the `expected` value (`allow`/`ask`) is compared; `reason` is informational and shown on
failure along with the command and the classifier's reasoning.

### Layer 2: Full-pipe integration tests (`FullPipeTestRunner.ps1`)

Spawns `Hook.ps1` as a child process, pipes JSON to stdin, validates stdout / stderr / exit code.
Data-driven via XML — one `<category-group>` per IDE. Uses the in-folder `config.json` copy via
`PRETOOLHOOK_CONFIG_PATH` (production hook always reads repo-root `config.json`).

```powershell
pwsh -NoProfile -File test/config/live/FullPipeTestRunner.ps1
```

### Layer 2b: Codex unit tests (`test-cases.codex.ps1`)

Validates Codex-specific `Detect-IDE` / `Format-Output` functions in isolation.

```powershell
pwsh -NoProfile -File test/config/live/test-cases.codex.ps1
```

**Adding a new IDE:** create a new `<category-group>` in `test-fullpipe.xml` with the IDE's payload
format and expected decisions. No runner changes needed.

### Optional: the test-strictness-gate sandbox

`test/config/test-strictness-gate/` holds an isolated normal/strict fixture pair with its own
runner, for experimenting with config changes without touching the live suites:

```powershell
powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1
```

## How Classification Works in Detail

### PowerShell
1. **AST parsing** — the AST is walked to extract cmdlet invocations, skipping variable
   assignments, loop scaffolding, and flow-control keywords.
2. **Parameter rules** (`parameter_commands`) — if the cmdlet has an entry, classify from its
   parameters (e.g. `-Method`); aliases like `irm`/`iwr` are resolved via a cross-domain fallback.
3. **Explicit patterns** — `read_only` / `modifying` regex entries.
4. **Verb-based** — `read_only_verbs` / `modifying_verbs` (e.g. `Get-*`, `Remove-*`).
5. **Wrapper detection** — `pwsh -Command "…"`, `Invoke-Command -ScriptBlock { … }` are unwrapped
   so inner commands are classified individually (which is why parameter rules work remoting-wide).

### Linux / Bash
1. **Parameter rules** (`parameter_commands`, e.g. `curl`, `python`) — from a quote-aware,
   position-independent tokenizer.
2. **Pattern matching** — `read_only` / `modifying` patterns.
3. **Shell-construct detection** — flow keywords (`for`/`while`/`if`/`case`), variable assignments
   (`VAR=value`), heredoc delimiters, and user-defined functions are detected/stripped first.
4. **Chained decomposition** — `&&`, `||`, `;`, `|`, `$()`, `>`, `>>`, newlines split compound
   commands into segments.

### Docker / Kubernetes / AWS / Terraform / Git
Subcommand-based pattern matching; wrappers (`docker exec`, `kubectl exec`, `ssh`) extract and
classify the inner command. AWS CLI also classifies by operation prefix (`describe-*`, `delete-*`).

## Performance

- **Target:** < 500 ms per classification. **Hard cap:** 3000 ms (exceeding forces `ask`).
- **Typical:** ~10 ms average across the full suite.
- **Logging:** append-only JSONL + text files, crash-safe.

## Test status

All suites are green with zero known-failure baselines — any new failure is a regression by
definition (tracked in `PROGRESS.md`). Current: 916/916 across the 6 `test/config/live/` suites
+ 17/17 Codex unit tests; 897/897 in the test-strictness-gate sandbox.

## License

See the repository license.
