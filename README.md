# PreToolUse Hook — Command Classification System

A cross-IDE preToolUse hook that intercepts terminal commands before execution, classifies them as read-only (auto-allow) or modifying (prompt user), and enforces safety policies across AI-powered developer tools.

## What It Does

When an AI coding assistant (Claude Code, GitHub Copilot) invokes a terminal tool like `run_in_terminal` or `bash`, this hook intercepts the request and runs it through a multi-stage classification pipeline:

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
    ├── Domain detection (content-based: DOS, Linux, PowerShell, Docker, etc.)
    ├── Split into sub-commands (handle ;, &&, ||, | chains)
    ├── PowerShell AST extraction (preferred over regex for PS commands)
    ├── Nested command detection (ssh, docker exec, kubectl exec, pwsh -Command)
    ├── Subshell extraction ($(...))
    ├── Redirection target analysis (> file, >> file)
    └── Per-sub-command classification against config.json
    │
    ▼
Aggregate: "allow" only if every sub-command is read-only
    │
    ▼
Output JSON (stdout): { permissionDecision, permissionDecisionReason }
```

**Result**: Read-only commands (ls, cat, Get-Process, docker ps, kubectl get) pass through silently. Modifying commands (rm, Stop-Process, terraform apply, kubectl delete) prompt the user for confirmation with a detailed reason showing exactly which sub-command triggered the block.

## Supported IDEs

| IDE | Hook Event | Detection Method |
|-----|-----------|------------------|
| **Claude Code** | `PreToolUse` | PascalCase event name, presence of `tool_use_id`, ISO 8601 timestamps |
| **GitHub Copilot** | `preToolUse` | camelCase event name, absence of `tool_use_id`, Unix epoch timestamps |

IDE detection uses a three-signal majority vote (see HookAdapter.ps1). The output format adapts automatically — Claude Code expects a `hookSpecificOutput` wrapper; Copilot expects a flat decision object.

## Supported Command Domains

| Domain | Examples | Classification Approach |
|--------|----------|------------------------|
| **DOS / CMD** | `dir`, `del`, `move`, `schtasks`, `bcdedit` | Pattern matching + shell flow-control detection |
| **Linux / Bash** | `ls`, `rm`, `find`, `systemctl`, `apt-get` | Pattern matching + shell keyword/heredoc/function detection |
| **PowerShell** | `Get-Process`, `Stop-Service`, `Invoke-Command` | Pattern matching + verb-based classification + AST parsing |
| **Docker** | `docker ps`, `docker rm`, `docker compose up` | Pattern matching + nested command extraction |
| **Kubernetes** | `kubectl get`, `kubectl delete`, `helm install` | Pattern matching + `kubectl exec` nesting detection |
| **Terraform** | `terraform plan`, `terraform apply`, `terraform destroy` | Pattern matching for subcommands |
| **AWS CLI** | `aws ec2 describe-*`, `aws s3 cp`, `aws lambda delete-*` | Prefix-based operation classification |

## Project Structure

```
pretoolhook/
├── src/
│   ├── Hook.ps1              # Main entry point (stdin → stdout hook script)
│   ├── HookAdapter.ps1       # IDE detection, command extraction, output formatting
│   ├── Classifier.ps1        # Top-level classification pipeline orchestrator
│   ├── Parser.ps1            # Domain detection, command splitting, AST extraction
│   ├── Resolver.ps1          # Pattern matching engine against config
│   ├── ConfigLoader.ps1      # JSON config loading, validation, regex compilation
│   ├── Logger.ps1            # Daily JSONL record files + human-readable text logs
│   └── TestRunner.ps1        # TDD test runner for the test suite
├── config.json        # Runtime configuration — the classification database
├── test/
│   ├── test-cases.xml         # Full test case database (339 test cases)
│   └── test-cases.adhoc.xml   # Quick test subset (40 test cases)
├── debug/                     # Debug and verification scripts
├── README.md                 # This file
├── INSTALL.md                # Installation guide
└── docs/
    └── superpowers/
        ├── specs/            # Architecture and test case design specs
        └── plans/            # TDD implementation plans
```

## Configuration Files

### `config.json` — The File You'll Edit Most

This is the **runtime configuration** that controls everything. You edit this to add new commands, change classifications, or tune behavior.

```jsonc
{
  "version": "1.0",
  "description": "PreToolUse Hook command classification database",

  // === Top-Level Gate Patterns (fast path before full classification) ===
  "trusted_pattern": ["^git status$", "^git diff$"],
  "untrusted_pattern": ["^rm -rf /$", "^kubectl delete --all$"],

  // === Tool Name Control ===
  // Tools listed here are processed by the hook
  "intercept_tool_name": ["send_to_terminal", "run_in_terminal"],
  // Tools listed here bypass the hook entirely (silently allowed)
  "ignore_tool_name": ["read_file", "manage_todo_list"],

  // === Command Extraction Mapping ===
  // Maps tool_name → JSON field path containing the command string
  "tool_name_mapping": {
    "run_in_terminal": "tool_input",
    "send_to_terminal": "tool_input",
    "bash": "tool_input.command"
  },

  // === Logging ===
  "log_file_path": "c:\\users\\frank\\prehook\\",

  // === Classification Database (8 domains, ~400 entries) ===
  "commands": {
    "DOS_CMD": {
      "read_only":  [ { "name": "dir",   "patterns": ["dir *", "dir /?"], "description": "..." } ],
      "modifying":  [ { "name": "del",   "patterns": ["del *"], "risk": "medium", "description": "..." } ]
    },
    "PowerShell": {
      "read_only":  [ /* pattern entries */ ],
      "modifying":  [ /* pattern entries */ ],
      "read_only_verbs":  ["Get-*", "Test-*", "Select-*"],
      "modifying_verbs":  { "low": ["Out-*"], "medium": ["Remove-*"], "high": ["Stop-*"] }
    },
    "Linux":       { "read_only": [...], "modifying": [...] },
    "Git":         { "read_only": [...], "modifying": [...] },
    "Terraform":   { "read_only": [...], "modifying": [...] },
    "Docker":      { "read_only": [...], "modifying": [...] },
    "Kubernetes":  { "read_only": [...], "modifying": [...] },
    "AWS_CLI":     {
      "read_only": [...],
      "modifying": [...],
      "read_only_prefixes": ["describe-", "list-", "get-"],
      "modifying_prefixes": { "low": ["put-"], "medium": ["create-"], "high": ["delete-", "terminate-"] }
    }
  }
}
```

**Key sections you'll modify:**

| Section | When to Edit |
|---------|-------------|
| `intercept_tool_name` | When a new IDE adds a terminal tool name |
| `ignore_tool_name` | When you want to skip certain tools |
| `trusted_pattern` | To auto-allow specific command patterns |
| `untrusted_pattern` | To auto-block specific dangerous patterns |
| `commands.<domain>.read_only` | To add new read-only commands |
| `commands.<domain>.modifying` | To add new modifying commands with risk levels |
| `commands.<domain>.read_only_verbs` | To add PowerShell verb prefixes |
| `tool_name_mapping` | When tool input field names change |

### `test-cases.xml` — The Test Database

The full test suite (339 test cases). Each entry specifies:
- The command text (exactly what the IDE would send)
- The expected classification (`allow` or `ask`)
- A human-readable description and category

You should add new test cases here whenever you add patterns to `config.json`.

### Config Files You Should NOT Edit

| File | Reason |
|------|--------|
| `test-cases.adhoc.xml` | Auto-generated subset for quick testing |
| `src/*.ps1` | Source code — changes should go through the test suite |
| `docs/superpowers/*` | Design documents, not runtime config |

## How to Run the Tests

### Full Test Suite (339 tests)

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "C:\path\to\pretoolhook\test\test-cases.xml"
```

### Quick Test Subset (40 tests)

```powershell
pwsh -NoProfile -File src/TestRunner.ps1
```

### Filter by Category

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test\test-cases.xml" -Filter "Docker"
```

### Test Runner Output

```
[1/339 0% - DOS-FileInspection - dir lists directory contents with details]
[2/339 0% - DOS-FileInspection - dir recursive search for .log files]
...
========================================
Test Run Complete
========================================
Total:    339
Passed:   339 (100%)
Failed:   0
Duration: 2.2s
Config:   config.json
========================================
```

Any failure prints the test number, command, expected vs actual, and the classifier's reasoning — making it easy to debug classification issues.

## How Classification Works in Detail

### For PowerShell Commands

1. **AST Parsing** — The PowerShell AST is walked to extract actual cmdlet invocations while skipping variable assignments, loop scaffolding, and flow-control keywords
2. **Verb-Based Classification** — If the cmdlet name matches a `read_only_verbs` pattern (e.g., `Get-*`, `Write-Host`), it's allowed; if it matches a `modifying_verbs` tier, it's blocked
3. **Wrapper Detection** — `pwsh -Command "..."; docker ps` is unwrapped so the inner commands are classified individually

### For Linux/Bash Commands

1. **Pattern Matching** — Command is matched against `read_only` and `modifying` patterns in the config
2. **Shell Construct Detection** — Flow-control keywords (`for`, `while`, `if`, `case`), variable assignments (`VAR=value`), heredoc delimiters, and user-defined function calls are detected and stripped before classification
3. **Chained Command Decomposition** — `&&`, `||`, `;`, `|`, `$()`, `>`, `>>`, and newline separators split compound commands into individual segments

### For Docker/Kubernetes/AWS/Terraform

Subcommand-based classification: `docker ps` matches read-only patterns, `docker rm` matches modifying patterns, `docker exec <container> <command>` extracts and classifies the inner command.

## Performance

- **Target**: < 500ms per classification
- **Hard cap**: 1000ms (exceeding forces an "ask" decision to stay safe)
- **Typical**: ~6ms average across 339 tests
- **Logging**: Append-only JSONL + text files, crash-safe

## License

See the repository license.
