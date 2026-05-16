# PreToolUse Hook System — Architecture Design Spec

**Version:** 1.0
**Date:** 2026-05-15
**Status:** Approved — ready for implementation

---

## 1. Overview

### 1.1 Purpose

The PreToolUse Hook System intercepts AI-generated shell commands before execution, classifies them as read-only or modifying, and either auto-approves (read-only) or requires manual confirmation (modifying). It supports both **Claude Code** and **GitHub Copilot** as IDE backends.

### 1.2 Classification Pipeline (Sequential Gates)

```
Incoming tool call
  │
  ├─► STEP 0: Extract tool_name from JSON
  │     │
  │     ├─ tool_name in ignore_tool_name? → [SKIP] log + allow (exit 0)
  │     ├─ tool_name NOT in intercept_tool_name? → log unknown tool + ask (exit 2)
  │     └─ tool_name in intercept_tool_name? → continue
  │
  ├─► STEP 1: Extract command string via tool_name_mapping
  │
  ├─► STEP 2: Check untrusted_pattern (regex match on raw command)
  │     └─ Match? → ask immediately (exit 2), reason = "matched untrusted pattern: <pattern>"
  │
  ├─► STEP 3: Check trusted_pattern (regex match on raw command)
  │     └─ Match? → allow immediately (exit 0), reason = "matched trusted pattern: <pattern>"
  │
  ├─► STEP 4: Run classification engine
  │     ├─ 4a: Domain detection (content-based)
  │     ├─ 4b: Parse command into sub-commands (AST for PS, pattern for others)
  │     ├─ 4c: Classify each sub-command against config.json
  │     ├─ 4d: Aggregate: if any sub-command is modifying → ask
  │     └─ 4e: If all sub-commands are read-only → allow
  │
  └─► Always: Write record file + log file
```

### 1.3 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | PowerShell 7 | Cross-platform (Win/Mac/Linux), AST parser built-in |
| Modules | Flat `src/` directory | PowerShell dot-sourcing is simpler without nested folders |
| Patterns | Regex throughout `config.json` | One match engine, consistent syntax |
| PowerShell verbs | Explicit two-word entries checked before single-word verb prefixes | `Invoke-Command` (read-only) overrides `Invoke-*` (modifying) |
| Domain detection | Content-based from command string | No dependency on IDE-provided shell hints |
| Aggregation | Collect ALL blocking sub-commands | User needs full picture of why a command is blocked |
| Pipeline context | Rich reasoning shows pipeline chains | `"kubectl get pods → xargs kubectl delete pod"` |
| IDE detection | Combined: `hook_event_name` + `tool_use_id` + `timestamp` | Distinguishes Claude Code vs Copilot reliably |
| Test runner | Custom .ps1 script reading `test-cases.xml` | No external dependencies, real-time progress, TDD-ready |
| Logs | Daily JSONL (records) + daily text (logs) | JSONL is crash-safe append-only |
| Error handling | Defensive: fail-to-ask | Malformed input, timeouts → ask user |
| Timeout | 500ms target, 1000ms hard cap | Hooks run on every tool call, must be fast |

---

## 2. Project File Structure

```
pretoolhook/
├── test-cases.xml                      # Test cases — authoritative source of truth
├── test-cases.adhoc.xml                # Quick test subset (smaller, faster iteration)
├── config.json                # Runtime configuration loaded by Hook.ps1
├── requirement.md                    # Original requirements document (reference)
├── CLAUDE.md                         # Project instructions
├── .mcp.json                         # MCP server configuration
├── docs/
│   └── superpowers/
│       ├── specs/
│       │   ├── 2026-05-15-architecture-design.md    ← THIS FILE
│       │   └── 2026-05-15-complex-command-test-cases-design.md
│       └── plans/
│           └── 2026-05-15-complex-command-test-cases.md
└── src/
    ├── Hook.ps1                      # Entry point — stdin JSON → classify → stdout JSON
    ├── Classifier.ps1                # Top-level orchestration of classification pipeline
    ├── Parser.ps1                    # AST parsing + command extraction from mixed shells
    ├── Resolver.ps1                  # Pattern matching against config.json
    ├── HookAdapter.ps1               # IDE detection, I/O formatting, output shaping
    ├── ConfigLoader.ps1              # Load, validate, and cache config.json
    ├── Logger.ps1                    # Record files (JSONL) + log files (text)
    └── TestRunner.ps1                # TDD test runner: reads XML, runs tests, reports
```

### 2.1 File Purposes (Implementation Detail)

#### `Hook.ps1` — Entry Point

```
Purpose:    Receives JSON from IDE on stdin, orchestrates classification, writes JSON to stdout
Input:      JSON on stdin (Claude Code or Copilot format)
Output:     JSON on stdout ({ "permissionDecision": "allow"|"ask", ... })
Exit codes: 0 = allow, 1 = non-blocking error, 2 = block/ask
Called by:  IDE preToolUse hook mechanism

Pseudocode:
  1. Read all stdin text
  2. $rawInput = ConvertFrom-Json
  3. $startTime = Get-Date
  4. . $PSScriptRoot/HookAdapter.ps1; . $PSScriptRoot/ConfigLoader.ps1
     . $PSScriptRoot/Logger.ps1; . $PSScriptRoot/Classifier.ps1
  5. $ide = Detect-IDE -InputObject $rawInput
  6. $config = Load-Config -Path "$PSScriptRoot/../config.json"
  7. $classifyResult = Invoke-Classify -RawInput $rawInput -IDE $ide -Config $config
  8. $elapsed = (Get-Date) - $startTime
  9. Write-LogEntry -Result $classifyResult -Elapsed $elapsed -Config $config
 10. Write-RecordEntry -RawInput $rawInput -Result $classifyResult -Config $config
 11. Format-Output -Result $classifyResult -IDE $ide | ConvertTo-Json -Compress
 12. exit $classifyResult.ExitCode
```

#### `Classifier.ps1` — Top-Level Orchestration

```
Purpose:    Implements the sequential gate pipeline (steps 0-4 from section 1.2)
Input:      $RawInput (PSCustomObject), $IDE (string), $Config (PSCustomObject)
Output:     $ClassifyResult with keys: Decision, Reason, SubResults, ExitCode
Dot-sources: Parser.ps1, Resolver.ps1

Exported functions:
  - Invoke-Classify         Main entry — runs the full pipeline
  - Test-ToolNameFilter     Returns skip/classify/unknown decision for tool_name
  - Test-TrustedUntrusted   Runs steps 2-3 (untrusted/trusted pattern checks)
```

#### `Parser.ps1` — AST + Command Extraction

```
Purpose:    Detect domain, parse command string into individual sub-commands
Input:      Raw command string (e.g., "Get-Process | ForEach-Object { taskkill /pid $_.Id }")
Output:     Array of [PSCustomObject]@{ CommandText, Domain, IsPipeline, ParentCommand }

Algorithm:
  1. DOMAIN DETECTION (content-based):
     - Check for PowerShell syntax markers (Verb-Noun, $_, | ForEach-Object, ${}, $(), @())
       → PowerShell domain
     - Check for aws/docker/kubectl/terraform prefixes → respective domain
     - Otherwise → General (DOS/Linux)

  2. COMMAND EXTRACTION:
     a. If PowerShell domain:
        - Use [System.Management.Automation.Language.Parser]::ParseInput()
        - Walk AST to find CommandAst nodes, pipeline elements
        - For string literals that look like commands (e.g., ssh 'rm -rf /'),
          extract and recurse with appropriate domain
        - For ScriptBlockAst (curly braces), extract inner commands recursively
     b. If General/DOS/Linux domain:
        - Split on ; && || | operators
        - For each segment, detect if it's a known binary (docker, kubectl, etc.)
          and tag with appropriate domain
     c. For mixed commands (e.g., pwsh -Command "docker ps; kubectl get pods"):
        - Outer shell = detected domain
        - String arguments to -Command/-ScriptBlock are recursively parsed
        - Each nested segment gets delegated to sub-classifier

  3. Return flat list of extracted sub-commands, each tagged with Domain
```

#### `Resolver.ps1` — Pattern Matching Engine

```
Purpose:    Classify a single sub-command against config.json patterns
Input:      Sub-command string, Domain tag, Config
Output:     [PSCustomObject]@{ Command, Decision ("allow"|"ask"), Reason, MatchedPattern }

Algorithm:
  1. Look up config.commands.<Domain>
  2. PowerShell domain:
     a. FIRST: check explicit "read_only" entries → if match, return allow
     b. THEN:  check explicit "modifying" entries → if match, return ask
     c. THEN:  check two-word verb (e.g., "Invoke-Command") against read_only_verbs
     d. THEN:  check single-word verb prefix (e.g., "Invoke-") against modifying_verbs
     e. FALLBACK: return ask with reason "unknown PowerShell cmdlet"

  3. AWS CLI domain:
     a. Extract: aws <service> <verb-*> from command
     b. FIRST: check explicit entries for non-standard verbs (s3 ls, s3 cp, etc.)
     c. THEN:  check verb prefix against read_only_verbs / modifying_verbs
       - read_only_verbs: ["describe-", "list-", "get-", "head-", "wait"]
       - modifying_verbs: ["delete-", "create-", "put-", "update-", "terminate-",
                           "start-", "stop-", "reboot-", "run-", "modify-", "attach-",
                           "detach-", "add-", "remove-", "register-", "deregister-"]
     d. FALLBACK: return ask with reason "unknown AWS CLI verb: <verb>"

  4. Linux / DOS / Docker / Kubernetes / Terraform domains:
     a. Check explicit "read_only" entries (regex patterns) → first match = allow
     b. Check explicit "modifying" entries (regex patterns) → first match = ask
     c. FALLBACK: return ask with reason "no matching pattern for <command>"

  Each explicit entry has:
    { "name": "...", "patterns": ["regex1", "regex2"], "description": "...", "risk": "low|medium|high" }

  Patterns are checked in array order. First regex match wins.
```

#### `HookAdapter.ps1` — I/O & IDE Detection

```
Purpose:    Detect IDE from input JSON, format output for correct IDE API
Input:      Raw PSCustomObject from stdin
Output:     IDE identifier string, formatted output JSON

Exported functions:
  - Detect-IDE            Returns "ClaudeCode" or "Copilot"
  - Format-Output         Wraps result in correct JSON shape per IDE
  - Get-CommandFromInput  Extracts command string using tool_name_mapping

IDE Detection Logic (Detect-IDE):

  Check these three signals together:

  1. hook_event_name field:
     - "PreToolUse"  → Claude Code
     - "preToolUse"  → Copilot
  2. tool_use_id field:
     - Present → Claude Code
     - Absent  → Copilot
  3. timestamp field format:
     - ISO 8601 with milliseconds → Claude Code
     - Unix epoch or simpler format → Copilot

  Majority vote of the three signals. If ambiguous, default to Claude Code format
  (Claude Code is the more restrictive/fail-safe format).

Tool Name → Command Extraction (Get-CommandFromInput):

  Use the tool_name_mapping from config.json:

  {
    "tool_name_mapping": {
      "run_in_terminal":    { "field": "tool_input", "type": "string" },
      "send_to_terminal":   { "field": "tool_input", "type": "string" },
      "bash":               { "field": "tool_input.command", "type": "string" },
      "Bash":               { "field": "tool_input.command", "type": "string" }
    }
  }

  For unknown tool_names (not in mapping):
    - Walk $rawInput recursively for any field that looks like a command string
      (heuristic: string with shell operators, known command prefixes, etc.)
    - If found, use it
    - If not found, return $null → classification fails → ask

Output Format per IDE (Format-Output):

  Claude Code output MUST be:
    {
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow" | "ask",
        "permissionDecisionReason": "<reason string>"
      }
    }

  Copilot output MUST be:
    {
      "permissionDecision": "allow" | "ask",
      "permissionDecisionReason": "<reason string>"
    }
```

#### `ConfigLoader.ps1` — Configuration Loading

```
Purpose:    Load config.json, validate structure, cache in memory
Input:      Path to config.json
Output:     PSCustomObject (the parsed and validated config)

Exported functions:
  - Load-Config           Main entry — returns parsed config
  - Test-ConfigSchema     Validates required keys exist

Validation rules:
  - "version" must be present
  - "commands" must have at least one domain key
  - "trusted_pattern" and "untrusted_pattern" must be arrays of valid regex strings
  - "tool_name_mapping" must exist and be non-empty
  - "intercept_tool_name" and "ignore_tool_name" must be arrays
  - All regex patterns must compile (test with [regex]::new())

Cache behavior:
  - Config is loaded once per hook invocation (no persistent cross-call cache,
    since each hook call is a separate process)
  - Invalid config → exit 2 immediately with error message
```

#### `Logger.ps1` — Audit Logging

```
Purpose:    Write record files (JSONL) and log files (human-readable text)
Input:      Raw input, classification result, elapsed time, config
Output:     Files written to disk

Exported functions:
  - Write-RecordEntry     Writes one line to <date>.records.jsonl
  - Write-LogEntry        Writes one entry to <date>.log
  - New-LogDirectory      Ensures log directory exists, creates if needed

Log Path Resolution:

  If config.log_file_path is not empty:
    $logDir = config.log_file_path
  Else:
    $logDir = "$env:USERPROFILE\.pretoolhook\"     (Windows)
    $logDir = "$HOME/.pretoolhook/"                 (Linux/Mac)

  Directory is created if it does not exist.

Record File (<date>.records.jsonl):

  One file per day: "2026-05-15.records.jsonl"
  Each line is a complete JSON object:
    {
      "received_at": "2026-05-15T14:32:01.234Z",
      "raw": { <the complete incoming IDE JSON, preserved as-is> }
    }

  Appended atomically. No parsing needed for append — open for append, write line, close.

Log File (<date>.log):

  One file per day: "2026-05-15.log"
  Human-readable text format:

  For classified commands:
    [2026-05-15 14:32:01.234] IDE:ClaudeCode Tool:run_in_terminal Decision:ask Time:12ms
      Reason: Remove-Item (modifying), curl (unknown). Pipeline: Get-ChildItem → Remove-Item
      Command: [[[Get-ChildItem | ForEach-Object { Remove-Item $_.FullName }; curl -s https://api.example.com/data]]]

  For allowed commands:
    [2026-05-15 14:32:01.234] IDE:ClaudeCode Tool:run_in_terminal Decision:allow Time:8ms
      Reason: read-only
      Command: [[[Get-ChildItem /etc/nginx]]]

  For ignored tools:
    [2026-05-15 14:32:01.234] IDE:ClaudeCode Tool:read_file Decision:allow [SKIP]
      Input: {"tool_name":"read_file","tool_input":{"file_path":"/etc/config.json"}}

  For unknown tools (neither intercept nor ignore list):
    [2026-05-15 14:32:01.234] IDE:ClaudeCode Tool:unknown_tool Decision:ask [UNKNOWN_TOOL]
      Input: {"tool_name":"unknown_tool","tool_input":"..."}

  The [[[ ]]] markers surround the exact command text that was classified.
```

---

## 3. `config.json` — Complete Schema

```jsonc
{
  "version": "1.0",
  "description": "PreToolUse Hook command classification configuration.",

  // Log directory path. If empty string, defaults to ~/.pretoolhook/
  "log_file_path": "",

  // ---------------------------------------------------------------------------
  // Sequential Gate 1: TRUSTED patterns (regex)
  // If the raw command matches any regex here → allow immediately.
  // Checked AFTER tool_name filtering.
  // ---------------------------------------------------------------------------
  "trusted_pattern": [
    "^git\\s+status",
    "^git\\s+diff",
    "^git\\s+log",
    "^npm\\s+test",
    "^npm\\s+run\\s+build"
  ],

  // ---------------------------------------------------------------------------
  // Sequential Gate 2: UNTRUSTED patterns (regex)
  // If the raw command matches any regex here → ask immediately.
  // Checked BEFORE trusted_pattern. Overrides everything.
  // ---------------------------------------------------------------------------
  "untrusted_pattern": [
    "rm\\s+-rf\\s+/",
    "DROP\\s+(TABLE|DATABASE)",
    "TRUNCATE\\s+TABLE",
    "kubectl\\s+delete\\s+--all",
    "terraform\\s+destroy",
    "aws\\s+\\S+\\s+delete-",
    "shutdown\\s+/[sr]"
  ],

  // Tool names whose tool_input should be classified
  "intercept_tool_name": [
    "run_in_terminal",
    "send_to_terminal",
    "bash",
    "Bash"
  ],

  // Tool names to skip (log + allow, no classification)
  "ignore_tool_name": [
    "read_file",
    "list_files",
    "search_file_content",
    "manage_todo_list",
    "edit_file",
    "write_file"
  ],

  // How to extract the command string from each tool type
  "tool_name_mapping": {
    "run_in_terminal":    { "field": "tool_input", "type": "string" },
    "send_to_terminal":   { "field": "tool_input", "type": "string" },
    "bash":               { "field": "tool_input.command", "type": "string" },
    "Bash":               { "field": "tool_input.command", "type": "string" }
  },

  "risk_legend": {
    "low": "Changes easily reversible or localized (creating files, copying data, setting env vars).",
    "medium": "Changes affecting system config, service state, or persistent storage. Generally recoverable.",
    "high": "Destructive operations causing irreversible data loss, permanent resource deletion, or security compromise."
  },

  // ---------------------------------------------------------------------------
  // DOMAIN-SPECIFIC COMMAND PATTERNS
  // Each domain has: read_only array, modifying array, and optionally
  // read_only_verbs / modifying_verbs arrays (for verb-based classification).
  //
  // Pattern matching order per domain:
  //   1. Explicit "read_only" entries (regex)
  //   2. Explicit "modifying" entries (regex)
  //   3. Verb-based: two-word read_only_verbs → single-word modifying_verbs
  //   4. Fallback: "ask" with reason "unknown command"
  //
  // PowerShell: explicit entry check before verb pattern check enables
  //   Invoke-Command (explicit read_only) to override Invoke-* (modifying verb).
  // ---------------------------------------------------------------------------
  "commands": {

    "powershell": {
      "description": "PowerShell cmdlets and scripts.",
      "read_only_verbs": [
        "Get-",
        "Select-",
        "Where-",
        "Sort-",
        "Measure-",
        "Compare-",
        "Group-",
        "Format-",
        "Out-GridView",
        "Write-Host",
        "Write-Output",
        "Write-Information",
        "Test-",
        "Show-",
        "Receive-"
      ],
      "modifying_verbs": [
        "Set-",
        "Remove-",
        "New-",
        "Add-",
        "Start-",
        "Stop-",
        "Restart-",
        "Enable-",
        "Disable-",
        "Clear-",
        "Copy-",
        "Move-",
        "Rename-",
        "Export-",
        "Import-",
        "Install-",
        "Uninstall-",
        "Register-",
        "Unregister-",
        "Invoke-",
        "Enter-",
        "Exit-",
        "Push-",
        "Pop-"
      ],
      "read_only": [
        {
          "name": "Invoke-Command",
          "patterns": ["^Invoke-Command"],
          "description": "PowerShell remoting command — remote commands are classified separately by the engine"
        },
        {
          "name": "Get-WmiObject",
          "patterns": ["^Get-WmiObject"],
          "description": "WMI query — read-only inspection"
        }
      ],
      "modifying": [
        {
          "name": "Invoke-Expression",
          "patterns": ["^Invoke-Expression"],
          "risk": "high",
          "description": "Dynamic command execution — high risk due to arbitrary code execution"
        },
        {
          "name": "Remove-Item with -Recurse",
          "patterns": ["Remove-Item.*-Recurse"],
          "risk": "high",
          "description": "Recursive deletion — irreversible data loss"
        }
      ]
    },

    "aws": {
      "description": "AWS CLI commands. Pattern: aws <service> <verb-command>.",
      "read_only_verbs": [
        "describe-",
        "list-",
        "get-",
        "head-",
        "wait"
      ],
      "modifying_verbs": [
        "delete-",
        "create-",
        "put-",
        "update-",
        "terminate-",
        "start-",
        "stop-",
        "reboot-",
        "run-",
        "modify-",
        "attach-",
        "detach-",
        "add-",
        "remove-",
        "deregister-",
        "register-",
        "import-",
        "restore-"
      ],
      "read_only": [
        {
          "name": "s3 ls",
          "patterns": ["^aws\\s+s3\\s+ls"],
          "description": "List S3 buckets or objects"
        },
        {
          "name": "s3api head-object",
          "patterns": ["^aws\\s+s3api\\s+head-object"],
          "description": "Retrieve object metadata"
        },
        {
          "name": "cloudformation describe-stacks",
          "patterns": ["^aws\\s+cloudformation\\s+describe-stacks"],
          "description": "Describe CloudFormation stacks"
        },
        {
          "name": "cloudformation estimate-template-cost",
          "patterns": ["^aws\\s+cloudformation\\s+estimate-template-cost"],
          "description": "Estimate cost without creating resources"
        },
        {
          "name": "cloudformation create-change-set",
          "patterns": ["^aws\\s+cloudformation\\s+create-change-set"],
          "description": "Creates a change set — does not apply changes"
        },
        {
          "name": "ssm describe-*",
          "patterns": ["^aws\\s+ssm\\s+describe-"],
          "description": "Describe SSM resources"
        }
      ],
      "modifying": [
        {
          "name": "s3 cp",
          "patterns": ["^aws\\s+s3\\s+cp"],
          "risk": "medium",
          "description": "Copy objects to/from S3"
        },
        {
          "name": "s3 sync",
          "patterns": ["^aws\\s+s3\\s+sync"],
          "risk": "medium",
          "description": "Synchronize directory with S3"
        },
        {
          "name": "s3 rm",
          "patterns": ["^aws\\s+s3\\s+rm"],
          "risk": "high",
          "description": "Delete S3 objects"
        },
        {
          "name": "s3 mv",
          "patterns": ["^aws\\s+s3\\s+mv"],
          "risk": "medium",
          "description": "Move S3 objects"
        },
        {
          "name": "ec2 run-instances",
          "patterns": ["^aws\\s+ec2\\s+run-instances"],
          "risk": "high",
          "description": "Launch EC2 instances"
        },
        {
          "name": "ec2 reboot-instances",
          "patterns": ["^aws\\s+ec2\\s+reboot-instances"],
          "risk": "high",
          "description": "Reboot EC2 instances"
        },
        {
          "name": "ec2 terminate-instances",
          "patterns": ["^aws\\s+ec2\\s+terminate-instances"],
          "risk": "high",
          "description": "Terminate EC2 instances — irreversible"
        }
      ]
    },

    "linux": {
      "description": "Linux / Bash / Zsh commands.",
      "read_only": [
        { "name": "ls", "patterns": ["^ls\\b"], "description": "List directory contents" },
        { "name": "cat", "patterns": ["^cat\\s"], "description": "Display file contents" },
        { "name": "head/tail", "patterns": ["^(head|tail)\\s"], "description": "Display file portions" },
        { "name": "less/more", "patterns": ["^(less|more)\\s"], "description": "Pager file viewing" },
        { "name": "grep", "patterns": ["^grep\\s"], "description": "Search text patterns" },
        { "name": "awk (read-only)", "patterns": ["^awk\\s(?!.*>)"], "description": "Text processing (no redirection)" },
        { "name": "sed (read-only)", "patterns": ["^sed\\s(?!.*(-i|>))"], "description": "Stream editing (no in-place)" },
        { "name": "find (read-only)", "patterns": ["^find\\s(?!.*(-delete|-exec|>))"], "description": "File search without side effects" },
        { "name": "ps", "patterns": ["^ps\\s"], "description": "Process listing" },
        { "name": "df/du", "patterns": ["^(df|du)\\s"], "description": "Disk usage" },
        { "name": "free", "patterns": ["^free\\b"], "description": "Memory usage" },
        { "name": "uname/whoami/id", "patterns": ["^(uname|whoami|id)\\b"], "description": "System/user identity" },
        { "name": "which/whereis", "patterns": ["^(which|whereis)\\s"], "description": "Locate binaries" },
        { "name": "echo (no redirect)", "patterns": ["^echo\\s(?!.*>)"], "description": "Print text (no redirection)" },
        { "name": "env/printenv", "patterns": ["^(env|printenv)\\b"], "description": "Environment variables" },
        { "name": "date", "patterns": ["^date\\b"], "description": "Display date/time" },
        { "name": "wc", "patterns": ["^wc\\s"], "description": "Word/line count" },
        { "name": "journalctl (query)", "patterns": ["^journalctl\\s(?!.*rotate|.*vacuum)"], "description": "Systemd journal query" },
        { "name": "systemctl status", "patterns": ["^systemctl\\s+status"], "description": "Service status" },
        { "name": "git status/log/diff", "patterns": ["^git\\s+(status|log|diff|show|branch|tag|remote\\s+-v)"], "description": "Git read-only operations" }
      ],
      "modifying": [
        { "name": "rm", "patterns": ["^rm\\s"], "risk": "high", "description": "Remove files/directories" },
        { "name": "mv/cp to system paths", "patterns": ["^(mv|cp)\\s.*(/etc/|/usr/|/var/|/boot/|/root/)"], "risk": "high", "description": "Move/copy to protected paths" },
        { "name": "chmod", "patterns": ["^chmod\\s"], "risk": "medium", "description": "Change file permissions" },
        { "name": "chown", "patterns": ["^chown\\s"], "risk": "high", "description": "Change file ownership" },
        { "name": "sed -i", "patterns": ["sed\\s.*-i"], "risk": "medium", "description": "In-place file editing" },
        { "name": "redirection >", "patterns": [">\\s*[^/]"], "risk": "low", "description": "Output redirection to file" },
        { "name": "tee", "patterns": ["\\btee\\s"], "risk": "low", "description": "Write to file while passing through" },
        { "name": "systemctl start/stop/restart", "patterns": ["^systemctl\\s+(start|stop|restart|enable|disable|mask)"], "risk": "medium", "description": "Service management" },
        { "name": "apt/yum/dnf/pacman install/remove", "patterns": ["^(apt|apt-get|yum|dnf|pacman|zypper)\\s+(install|remove|purge|update|upgrade)"], "risk": "medium", "description": "Package management" },
        { "name": "useradd/userdel/usermod", "patterns": ["^(useradd|userdel|usermod|groupadd|groupdel)"], "risk": "high", "description": "User/group management" },
        { "name": "mount/umount", "patterns": ["^(mount|umount)\\s"], "risk": "high", "description": "Filesystem mount operations" },
        { "name": "shutdown/reboot", "patterns": ["^(shutdown|reboot|halt|poweroff)\\b"], "risk": "high", "description": "System power operations" },
        { "name": "dd", "patterns": ["^dd\\s"], "risk": "high", "description": "Disk operations — potential data destruction" },
        { "name": "ssh (execution mode)", "patterns": ["^ssh\\s(?!.*(-V|--version)$)"], "risk": "medium", "description": "SSH remote execution — commands on remote host classified separately" },
        { "name": "scp", "patterns": ["^scp\\s"], "risk": "medium", "description": "Secure copy over SSH" },
        { "name": "rsync", "patterns": ["^rsync\\s"], "risk": "medium", "description": "File synchronization" },
        { "name": "sudo", "patterns": ["^sudo\\s"], "risk": "high", "description": "Elevated execution — sub-command classified separately" }
      ]
    },

    "dos": {
      "description": "DOS / Windows CMD commands.",
      "read_only": [
        { "name": "dir", "patterns": ["^dir\\s"], "description": "List directory" },
        { "name": "type", "patterns": ["^type\\s"], "description": "Display file contents" },
        { "name": "tree", "patterns": ["^tree\\b"], "description": "Directory tree" },
        { "name": "findstr", "patterns": ["^findstr\\s"], "description": "Search strings" },
        { "name": "where", "patterns": ["^where\\s"], "description": "Locate files" },
        { "name": "ipconfig", "patterns": ["^ipconfig\\b"], "description": "Network config display" },
        { "name": "ping", "patterns": ["^ping\\s"], "description": "Network connectivity test" },
        { "name": "tracert/pathping", "patterns": ["^(tracert|pathping)\\s"], "description": "Route tracing" },
        { "name": "netstat", "patterns": ["^netstat\\b"], "description": "Network statistics" },
        { "name": "systeminfo", "patterns": ["^systeminfo\\b"], "description": "System information" },
        { "name": "whoami", "patterns": ["^whoami\\b"], "description": "Current user" },
        { "name": "tasklist", "patterns": ["^tasklist\\b"], "description": "Process list" },
        { "name": "sc query", "patterns": ["^sc\\s+query"], "description": "Service query" },
        { "name": "reg query", "patterns": ["^reg\\s+query"], "description": "Registry query" },
        { "name": "set (display)", "patterns": ["^set$"], "description": "Display environment variables" },
        { "name": "ver", "patterns": ["^ver$"], "description": "OS version" },
        { "name": "driverquery", "patterns": ["^driverquery\\b"], "description": "Driver listing" },
        { "name": "schtasks /query", "patterns": ["^schtasks\\s+/query"], "description": "Scheduled task query" }
      ],
      "modifying": [
        { "name": "del/erase", "patterns": ["^(del|erase)\\s"], "risk": "high", "description": "Delete files" },
        { "name": "rmdir/rd", "patterns": ["^(rmdir|rd)\\s"], "risk": "high", "description": "Remove directory" },
        { "name": "copy/xcopy/robocopy", "patterns": ["^(copy|xcopy|robocopy)\\s"], "risk": "medium", "description": "Copy files" },
        { "name": "move", "patterns": ["^move\\s"], "risk": "medium", "description": "Move files" },
        { "name": "mkdir/md", "patterns": ["^(mkdir|md)\\s"], "risk": "low", "description": "Create directory" },
        { "name": "taskkill", "patterns": ["^taskkill\\b"], "risk": "high", "description": "Terminate processes" },
        { "name": "shutdown", "patterns": ["^shutdown\\s"], "risk": "high", "description": "System shutdown" },
        { "name": "net start/stop", "patterns": ["^net\\s+(start|stop)\\s"], "risk": "medium", "description": "Service control" },
        { "name": "reg add/delete", "patterns": ["^reg\\s+(add|delete)\\s"], "risk": "high", "description": "Registry modification" },
        { "name": "sc config/delete/stop/start", "patterns": ["^sc\\s+(config|delete|stop|start)\\s"], "risk": "high", "description": "Service configuration" },
        { "name": "netsh advfirewall", "patterns": ["^netsh\\s+advfirewall"], "risk": "high", "description": "Firewall modification" },
        { "name": "wmic delete/call", "patterns": ["^wmic\\s+\\S+\\s+(delete|call)"], "risk": "high", "description": "WMI modification" },
        { "name": "format", "patterns": ["^format\\s"], "risk": "high", "description": "Disk formatting — irreversible" },
        { "name": "diskpart", "patterns": ["^diskpart\\b"], "risk": "high", "description": "Disk partitioning" }
      ]
    },

    "docker": {
      "description": "Docker CLI commands.",
      "read_only": [
        { "name": "docker ps", "patterns": ["^docker\\s+ps\\b"], "description": "List containers" },
        { "name": "docker images", "patterns": ["^docker\\s+images\\b"], "description": "List images" },
        { "name": "docker inspect", "patterns": ["^docker\\s+inspect\\b"], "description": "Inspect resources" },
        { "name": "docker logs", "patterns": ["^docker\\s+logs\\b"], "description": "View container logs" },
        { "name": "docker stats", "patterns": ["^docker\\s+stats\\b"], "description": "Container resource stats" },
        { "name": "docker info", "patterns": ["^docker\\s+info\\b"], "description": "Docker system info" },
        { "name": "docker history", "patterns": ["^docker\\s+history\\b"], "description": "Image layer history" },
        { "name": "docker diff", "patterns": ["^docker\\s+diff\\b"], "description": "Container filesystem changes" },
        { "name": "docker events", "patterns": ["^docker\\s+events\\b"], "description": "Docker event stream" },
        { "name": "docker top", "patterns": ["^docker\\s+top\\b"], "description": "Container processes" },
        { "name": "docker volume ls/inspect", "patterns": ["^docker\\s+volume\\s+(ls|inspect)"], "description": "Volume inspection" },
        { "name": "docker network ls/inspect", "patterns": ["^docker\\s+network\\s+(ls|inspect)"], "description": "Network inspection" },
        { "name": "docker compose config/ps/logs", "patterns": ["^docker\\s+(compose|compose)\\s+(config|ps|logs)"], "description": "Compose inspection" }
      ],
      "modifying": [
        { "name": "docker rm", "patterns": ["^docker\\s+rm\\b"], "risk": "high", "description": "Remove containers" },
        { "name": "docker rmi", "patterns": ["^docker\\s+rmi\\b"], "risk": "high", "description": "Remove images" },
        { "name": "docker run", "patterns": ["^docker\\s+run\\b"], "risk": "medium", "description": "Create and run container" },
        { "name": "docker exec", "patterns": ["^docker\\s+exec\\b"], "risk": "medium", "description": "Execute command in container" },
        { "name": "docker start/stop/restart/kill", "patterns": ["^docker\\s+(start|stop|restart|kill)\\b"], "risk": "medium", "description": "Container lifecycle" },
        { "name": "docker build", "patterns": ["^docker\\s+build\\b"], "risk": "medium", "description": "Build image from Dockerfile" },
        { "name": "docker push/pull", "patterns": ["^docker\\s+(push|pull)\\b"], "risk": "medium", "description": "Registry operations" },
        { "name": "docker volume rm", "patterns": ["^docker\\s+volume\\s+rm\\b"], "risk": "high", "description": "Remove volumes — deletes persistent data" },
        { "name": "docker system prune", "patterns": ["^docker\\s+system\\s+prune"], "risk": "high", "description": "System cleanup — removes unused data" },
        { "name": "docker compose up/down", "patterns": ["^docker\\s+(compose|compose)\\s+(up|down)"], "risk": "medium", "description": "Compose lifecycle" }
      ]
    },

    "kubernetes": {
      "description": "Kubernetes kubectl commands.",
      "read_only": [
        { "name": "kubectl get", "patterns": ["^kubectl\\s+get\\b"], "description": "Get resources" },
        { "name": "kubectl describe", "patterns": ["^kubectl\\s+describe\\b"], "description": "Describe resources" },
        { "name": "kubectl logs", "patterns": ["^kubectl\\s+logs\\b"], "description": "View pod logs" },
        { "name": "kubectl top", "patterns": ["^kubectl\\s+top\\b"], "description": "Resource usage" },
        { "name": "kubectl cluster-info", "patterns": ["^kubectl\\s+cluster-info\\b"], "description": "Cluster information" },
        { "name": "kubectl api-resources", "patterns": ["^kubectl\\s+api-resources\\b"], "description": "API resources list" },
        { "name": "kubectl explain", "patterns": ["^kubectl\\s+explain\\b"], "description": "Resource documentation" },
        { "name": "kubectl rollout status", "patterns": ["^kubectl\\s+rollout\\s+status"], "description": "Rollout status" },
        { "name": "kubectl auth can-i", "patterns": ["^kubectl\\s+auth\\s+can-i"], "description": "Permission check" },
        { "name": "kubectl config view", "patterns": ["^kubectl\\s+config\\s+view"], "description": "Kubeconfig view" },
        { "name": "kubectl config current-context", "patterns": ["^kubectl\\s+config\\s+current-context"], "description": "Current context" }
      ],
      "modifying": [
        { "name": "kubectl delete", "patterns": ["^kubectl\\s+delete\\b"], "risk": "high", "description": "Delete resources" },
        { "name": "kubectl apply", "patterns": ["^kubectl\\s+apply\\b"], "risk": "medium", "description": "Apply configuration" },
        { "name": "kubectl create", "patterns": ["^kubectl\\s+create\\b"], "risk": "medium", "description": "Create resources" },
        { "name": "kubectl patch", "patterns": ["^kubectl\\s+patch\\b"], "risk": "medium", "description": "Patch resources" },
        { "name": "kubectl edit", "patterns": ["^kubectl\\s+edit\\b"], "risk": "high", "description": "Direct resource editing" },
        { "name": "kubectl scale", "patterns": ["^kubectl\\s+scale\\b"], "risk": "medium", "description": "Scale resources" },
        { "name": "kubectl exec", "patterns": ["^kubectl\\s+exec\\b"], "risk": "medium", "description": "Execute command in pod" },
        { "name": "kubectl rollout undo", "patterns": ["^kubectl\\s+rollout\\s+undo"], "risk": "medium", "description": "Rollback deployment" },
        { "name": "kubectl rollout restart", "patterns": ["^kubectl\\s+rollout\\s+restart"], "risk": "medium", "description": "Restart deployment" },
        { "name": "kubectl drain", "patterns": ["^kubectl\\s+drain\\b"], "risk": "high", "description": "Drain node — evicts all pods" },
        { "name": "kubectl cordon/uncordon", "patterns": ["^kubectl\\s+(cordon|uncordon)\\b"], "risk": "medium", "description": "Node scheduling" },
        { "name": "kubectl port-forward", "patterns": ["^kubectl\\s+port-forward\\b"], "risk": "medium", "description": "Port forwarding" }
      ]
    },

    "terraform": {
      "description": "Terraform CLI commands.",
      "read_only": [
        { "name": "terraform plan", "patterns": ["^terraform\\b.*\\bplan\\b"], "description": "Show execution plan" },
        { "name": "terraform state list", "patterns": ["^terraform\\b.*\\bstate\\s+list\\b"], "description": "List state resources" },
        { "name": "terraform state show", "patterns": ["^terraform\\b.*\\bstate\\s+show\\b"], "description": "Show resource state" },
        { "name": "terraform output", "patterns": ["^terraform\\b.*\\boutput\\b"], "description": "Show output values" },
        { "name": "terraform console", "patterns": ["^terraform\\b.*\\bconsole\\b"], "description": "Interactive console" },
        { "name": "terraform fmt -check", "patterns": ["^terraform\\b.*\\bfmt\\s+-check"], "description": "Format check only" },
        { "name": "terraform validate", "patterns": ["^terraform\\b.*\\bvalidate\\b"], "description": "Validate configuration" },
        { "name": "terraform providers", "patterns": ["^terraform\\b.*\\bproviders\\b"], "description": "Show providers" },
        { "name": "terraform graph", "patterns": ["^terraform\\b.*\\bgraph\\b"], "description": "Dependency graph" },
        { "name": "terraform version", "patterns": ["^terraform\\b.*\\bversion\\b"], "description": "Show version" },
        { "name": "terraform workspace list", "patterns": ["^terraform\\b.*\\bworkspace\\s+list\\b"], "description": "List workspaces" },
        { "name": "terraform workspace show", "patterns": ["^terraform\\b.*\\bworkspace\\s+show\\b"], "description": "Current workspace" }
      ],
      "modifying": [
        { "name": "terraform apply", "patterns": ["^terraform\\b.*\\bapply\\b"], "risk": "high", "description": "Apply infrastructure changes" },
        { "name": "terraform destroy", "patterns": ["^terraform\\b.*\\bdestroy\\b"], "risk": "high", "description": "Destroy all infrastructure" },
        { "name": "terraform state rm", "patterns": ["^terraform\\b.*\\bstate\\s+rm\\b"], "risk": "high", "description": "Remove from state — loses tracking" },
        { "name": "terraform state mv", "patterns": ["^terraform\\b.*\\bstate\\s+mv\\b"], "risk": "high", "description": "Move resource in state" },
        { "name": "terraform import", "patterns": ["^terraform\\b.*\\bimport\\b"], "risk": "medium", "description": "Import existing resource" },
        { "name": "terraform force-unlock", "patterns": ["^terraform\\b.*\\bforce-unlock\\b"], "risk": "high", "description": "Force unlock state — can corrupt state" },
        { "name": "terraform fmt", "patterns": ["^terraform\\b.*\\bfmt\\b(?!.*-check)"], "risk": "low", "description": "Format files in place" },
        { "name": "terraform workspace new/select/delete", "patterns": ["^terraform\\b.*\\bworkspace\\s+(new|select|delete)\\b"], "risk": "medium", "description": "Workspace management" }
      ]
    }
  }
}
```

---

## 4. `test-cases.xml` — Schema

```xml
<?xml version="1.0" encoding="UTF-8"?>
<commands>

  <category-group name="DOMAIN_NAME">
    <!-- e.g., DOS_CMD, PowerShell, Linux, Terraform, Docker, Kubernetes, AWS_CLI -->

    <test-case expected="allow|ask" reason="read-only|<specific-trigger>" category="DOMAIN-Subcategory">
      <description>Human-readable description of what this test exercises</description>
      <copilot-command><![CDATA[
the actual command text — preserves all characters including < > " ' \ | & ; without escaping
      ]]></copilot-command>
    </test-case>

  </category-group>

</commands>
```

### 4.1 `expected` Attribute

| Value | Meaning |
|-------|---------|
| `"allow"` | The classification engine should auto-approve this command |
| `"ask"` | The classification engine should require manual confirmation |

### 4.2 `reason` Attribute

| `expected` value | `reason` value |
|---|---|
| `"allow"` | `"read-only"` |
| `"ask"` | The specific modifying sub-command(s) that triggered the ask, e.g., `"Remove-Item"`, `"kubectl delete, docker rm"` |

---

## 5. Test Runner Design (`TestRunner.ps1`)

### 5.1 Overview

```
Purpose:    Reads test-cases.xml (or test-cases.adhoc.xml), feeds each test case
            into Classifier.ps1, and reports pass/fail.

Usage:      .\TestRunner.ps1 [-XmlPath <path>] [-Filter <category>]
            Default XmlPath = "..\test-cases.xml"

Exit code:  0 if all tests pass; non-zero if any test fails
```

### 5.2 Progress Display

Real-time progress line that updates in-place:

```
[23/200 12% - PowerShell chained remoting]
```

- The line uses `Write-Host -NoNewline` with `\r` carriage return to refresh in-place
- Each test updates: `[current/total percentage% - category-name test-name]`
- On **success**: the line clears and redraws with the next test case
- On **failure**: the failure is printed as a block BELOW the progress line, then the progress line continues with the next test

### 5.3 Failure Output Format

```
FAIL [23/200 12% - PowerShell chained remoting]  Time: 34ms
  Command: Invoke-Command -ComputerName SRV1 -ScriptBlock { Remove-Item C:\temp\* }
  Expected: ask  Got: allow
  Classifier said: Invoke-Command is in read_only list → allowed
```

- The failure stays on screen (the progress line moves down)
- Each failure is numbered

### 5.4 Summary Output

At the end, print:

```
========================================
Test Run Complete
========================================
Total:    200
Passed:   187 (93.5%)
Failed:   13
Duration: 14.2s
Config:   config.json

Failed Tests:
  [ 23] PowerShell chained remoting
  [ 45] Linux SSH nested subshell
  [ 89] Docker compose multi-service
  ...
========================================
```

### 5.5 Implementation Pseudocode

```powershell
param(
    [string]$XmlPath = "$PSScriptRoot\..\test-cases.xml",
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

# Load dependencies
. "$PSScriptRoot\ConfigLoader.ps1"
. "$PSScriptRoot\Parser.ps1"
. "$PSScriptRoot\Resolver.ps1"

$config = Load-Config -Path "$PSScriptRoot\..\config.json"
[xml]$xml = Get-Content $XmlPath
$testCases = $xml.commands.'category-group'.'test-case'

if ($Filter) {
    $testCases = $testCases | Where-Object { $_.category -like "*$Filter*" }
}

$total = $testCases.Count
$passed = 0
$failed = 0
$failures = @()
$startTime = Get-Date

for ($i = 0; $i -lt $total; $i++) {
    $tc = $testCases[$i]
    $num = $i + 1
    $pct = [math]::Floor($num / $total * 100)
    $name = "$($tc.category) - $($tc.description)"

    # Draw progress line
    Write-Host -NoNewline "`r[$num/$total $pct% - $name]                    "

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Test-SingleCase -TestCase $tc -Config $config
    } catch {
        $result = @{ Decision = "error"; Reason = $_.Exception.Message }
    }
    $sw.Stop()
    $elapsed = $sw.ElapsedMilliseconds

    if ($result.Decision -eq $tc.expected) {
        $passed++
    } else {
        $failed++
        $fail = [PSCustomObject]@{
            Number   = $num
            Name     = $name
            Command  = $tc.'copilot-command'.Trim()
            Expected = $tc.expected
            Got      = $result.Decision
            Reason   = $result.Reason
            Time     = $elapsed
        }
        $failures += $fail

        # Print failure below progress line
        Write-Host ""
        Write-Host "FAIL [$num/$total $pct% - $name]  Time: ${elapsed}ms" -ForegroundColor Red
        Write-Host "  Command: $($fail.Command.Substring(0, [Math]::Min(200, $fail.Command.Length)))"
        Write-Host "  Expected: $($fail.Expected)  Got: $($fail.Got)"
        Write-Host "  Classifier said: $($fail.Reason)"
        Write-Host ""
    }

    # Hard timeout check per test
    if ($elapsed -gt 1000) {
        Write-Host "  WARNING: Classification exceeded 1000ms hard cap (${elapsed}ms)" -ForegroundColor Yellow
    }
}

# Summary
$totalTime = (Get-Date) - $startTime
Write-Host "========================================"
Write-Host "Test Run Complete"
Write-Host "========================================"
Write-Host "Total:    $total"
Write-Host "Passed:   $passed ($([math]::Round($passed/$total*100, 1))%)"
Write-Host "Failed:   $failed"
Write-Host "Duration: $([math]::Round($totalTime.TotalSeconds, 1))s"
Write-Host "Config:   config.json"
Write-Host ""

if ($failures.Count -gt 0) {
    Write-Host "Failed Tests:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host ("  [{0,4}] {1}" -f $f.Number, $f.Name) -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "========================================"

exit ($failed -gt 0 ? 1 : 0)
```

---

## 6. Data Flow Diagrams

### 6.1 Classification Pipeline (Detailed)

```
IDE sends JSON on stdin
         │
         ▼
┌─────────────────┐
│   Hook.ps1      │  Read stdin → ConvertFrom-Json
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ HookAdapter.ps1 │  Detect-IDE (hook_event_name+tool_use_id+timestamp)
│                 │  Get-CommandFromInput (tool_name_mapping lookup)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ ConfigLoader.ps1│  Load config.json; compile regex; validate
└────────┬────────┘
         │
         ▼
  ┌──────┴──────┐
  │ STEP 0      │  tool_name in ignore_tool_name? → [SKIP] log+allow
  │             │  tool_name NOT in intercept_tool_name? → [UNKNOWN] log+ask
  │             │  tool_name in intercept_tool_name? → continue
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 1      │  Extract command via tool_name_mapping
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 2      │  Check untrusted_pattern.regex → match? ask
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 3      │  Check trusted_pattern.regex → match? allow
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 4a     │  Parser.ps1: Domain detection (content-based)
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 4b     │  Parser.ps1: Extract sub-commands (AST + pattern)
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 4c     │  Resolver.ps1: For each sub-command →
  │             │    1. explicit read_only patterns
  │             │    2. explicit modifying patterns
  │             │    3. verb-based (PowerShell/AWS CLI)
  │             │    4. fallback: unknown → ask
  └──────┬──────┘
         │
  ┌──────┴──────┐
  │ STEP 4d     │  Aggregate: if ANY sub-command = ask → overall = ask
  │             │  Collect ALL blocking commands for reason
  │             │  Capture pipeline context for richer reasoning
  └──────┬──────┘
         │
         ▼
┌─────────────────┐
│   Logger.ps1    │  Write-RecordEntry → <date>.records.jsonl
│                 │  Write-LogEntry    → <date>.log
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ HookAdapter.ps1 │  Format-Output → Claude Code or Copilot JSON
└────────┬────────┘
         │
         ▼
  stdout JSON → IDE receives decision
```

### 6.2 Mixed-Shell Parsing Example

```
Input:  pwsh -Command "Get-Process | ForEach-Object { taskkill /pid $_.Id }; ssh admin@server 'systemctl restart nginx'"

  1. Domain detection: sees pwsh -Command → PowerShell domain (outer)
  2. AST parse: finds CommandAst "pwsh" with argument "-Command" "string..."
  3. Extract string argument: "Get-Process | ForEach-Object { taskkill /pid $_.Id }; ssh admin@server 'systemctl restart nginx'"
  4. Recurse into the string as PowerShell domain:
     a. AST parse inner: finds pipeline Get-Process | ForEach-Object { ... }
     b. Walk ScriptBlockAst inside ForEach-Object:
        - Find "taskkill /pid $_.Id" → DOMAIN: DOS, classify as modifying
     c. Find "ssh admin@server 'systemctl restart nginx'":
        - DOMAIN: Linux, classify as modifying (ssh → risk:medium)
        - Extract ssh argument: "systemctl restart nginx"
        - Recurse: DOMAIN: Linux, classify "systemctl restart" → modifying
  5. Aggregate: taskkill (modifying) + ssh (modifying) + systemctl restart (modifying)
     → Decision: ask
     → Reason: "taskkill, ssh admin@server (systemctl restart nginx)"
```

---

## 7. IDE Detection

### 7.1 Detection Matrix

| Signal | Claude Code | GitHub Copilot |
|--------|-------------|----------------|
| `hook_event_name` | `"PreToolUse"` (PascalCase P, T, U) | `"preToolUse"` (camelCase p, t, U) |
| `tool_use_id` | Present (UUID string) | Absent |
| `timestamp` | ISO 8601 with milliseconds: `"2026-05-15T14:32:01.234Z"` | Simpler format or Unix epoch |

### 7.2 Implementation

```powershell
function Detect-IDE {
    param([PSCustomObject]$InputObject)

    $signals = @{ Claude = 0; Copilot = 0 }

    # Signal 1: hook_event_name
    if ($InputObject.hook_event_name) {
        if ($InputObject.hook_event_name -ceq "PreToolUse") { $signals.Claude++ }
        elseif ($InputObject.hook_event_name -ceq "preToolUse") { $signals.Copilot++ }
    }

    # Signal 2: tool_use_id presence
    if ($InputObject.PSObject.Properties.Name -contains "tool_use_id" -and $InputObject.tool_use_id) {
        $signals.Claude++
    } else {
        $signals.Copilot++
    }

    # Signal 3: timestamp format
    $ts = $InputObject.timestamp
    if ($ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z?$') {
        $signals.Claude++
    } elseif ($ts -match '^\d{10,13}$') {
        $signals.Copilot++
    }

    # Majority vote
    if ($signals.Claude -gt $signals.Copilot) { return "ClaudeCode" }
    else { return "Copilot" }
}
```

---

## 8. Error Handling Strategy

| Scenario | Behavior | Exit Code | Reason |
|----------|----------|-----------|--------|
| Malformed JSON on stdin | Log error, output `ask` | 2 | `"Input JSON could not be parsed"` |
| Missing `tool_name` field | Log error, output `ask` | 2 | `"Missing required field: tool_name"` |
| Missing `tool_input` field | Log error, output `ask` | 2 | `"Missing required field: tool_input"` |
| Classification timeout (>1000ms) | Log warning, output `ask` | 2 | `"Classification timed out after 1000ms"` |
| `config.json` missing | Exit immediately | 2 | `"Configuration file not found"` |
| `config.json` has invalid regex | Exit immediately | 2 | `"Invalid regex pattern in config: <pattern>"` |
| Log directory cannot be created | Output to stderr, still classify | 0/2 | Classification proceeds; logging failure is non-fatal |
| PowerShell AST parse failure | Fall back to pattern-based parsing | — | Graceful degradation |

---

## 9. Performance Budget

| Metric | Target | Hard Cap |
|--------|--------|----------|
| Simple command classification | < 50ms | 500ms |
| Complex chain classification | < 200ms | 500ms |
| PowerShell AST parse | < 100ms | 300ms |
| Total hook execution | < 500ms | 1000ms |
| Config loading (regex compilation) | < 50ms | — |
| Record file append | < 10ms | — |
| Log file append | < 10ms | — |

---

## 10. TDD Implementation Order

The implementation follows TDD: write test cases first (red), implement until they pass (green), refactor (clean).

### Phase 1: Test Infrastructure
1. Create `test-cases.adhoc.xml` — small subset of test cases (~30) for fast iteration
2. Implement `TestRunner.ps1` — verify it reads XML and reports all failures (no engine yet, so ALL fail)
3. Implement `ConfigLoader.ps1` — load and validate `config.json`
4. Implement `Logger.ps1` — write record and log files

### Phase 2: Simple Classification
5. Implement `HookAdapter.ps1` — `Detect-IDE`, `Get-CommandFromInput`, `Format-Output`
6. Implement `Resolver.ps1` — explicit entry matching only (no verb-based)
7. Run test runner against `test-cases.adhoc.xml` — simple single-command tests should pass

### Phase 3: Parser
8. Implement `Parser.ps1` — domain detection + command splitting
9. Run tests against chained/multi-command test cases — split should work

### Phase 4: Verb-Based Classification
10. Add verb-based matching to `Resolver.ps1` (PowerShell verbs, AWS CLI verbs)
11. Run tests against PowerShell and AWS CLI verb-based test cases

### Phase 5: Sequential Gates
12. Implement `Classifier.ps1` — the full pipeline (tool_name → untrusted → trusted → classify)
13. Add trusted/untrusted pattern checks
14. Run full suite against `test-cases.xml`

### Phase 6: Hook Integration
15. Implement `Hook.ps1` entry point
16. End-to-end test: pipe JSON to Hook.ps1, verify correct stdout output

### Phase 7: Hardening
17. Error handling: malformed JSON, missing fields, timeouts
18. Performance: benchmark and optimize if needed
19. Full `test-cases.xml` pass verification — ALL 228+ tests must pass

---

## 11. Notes for the Implementing Agent

1. **All pattern matching uses regex.** There is no glob-to-regex conversion. The patterns in `config.json` are regex strings that must compile via `[regex]::new($pattern)`.

2. **PowerShell dot-sourcing** works with flat `src/` layout. Each file sources its dependencies:
   ```powershell
   . "$PSScriptRoot\Parser.ps1"
   . "$PSScriptRoot\Resolver.ps1"
   ```
   Using `$PSScriptRoot` (not relative paths) so it works regardless of invocation directory.

3. **PowerShell AST API**:
   ```powershell
   $ast = [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
   ```
   The `$tokens` and `$errors` are `[ref]` parameters — pass them as variables. Check `$errors.Count -gt 0` for parse failures and fall back to pattern-based.

4. **The `$PSNativeCommandArgumentPassing`** preference variable may need to be set for consistent argument handling across platforms.

5. **Encoding**: All files read/written as UTF-8. Use `-Encoding UTF8` on `Get-Content` and `Out-File` / `Add-Content`.

6. **Newlines**: Record files use `\n` (LF) line endings. Log files use `\r\n` (CRLF) on Windows, `\n` on Linux/Mac.

7. **The JSON output must be compressed** (single line, no extra whitespace) via `ConvertTo-Json -Compress`.

8. **Both log file types** (records and text logs) are daily. Filename format:
   - Records: `yyyy-MM-dd.records.jsonl`
   - Logs: `yyyy-MM-dd.log`
   - Use UTC date for filename to avoid issues around midnight transitions.

9. **The `test-case.expected` attribute** maps to classifier output as:
   - `expected="allow"` → classifier Decision must be `"allow"`
   - `expected="ask"` → classifier Decision must be `"ask"`
