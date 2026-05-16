# PreToolUse Hook System — TDD Implementation Plan

> **Source spec:** `docs/superpowers/specs/2026-05-15-architecture-design.md`
>
> **Methodology:** Test-Driven Development. Each task starts with writing/updating test cases, then implementing code until all tests pass. The test runner begins with ALL tests failing and progressively passes them as each module is implemented.

---

## Task 1: Create `test-cases.adhoc.xml` — Quick Test Subset

- [ ] **Step 1: Create `test-cases.adhoc.xml`**

Extract ~30 representative test cases from `test-cases.xml` covering:
- Simple allow (dir, ls, Get-ChildItem, docker ps, kubectl get, aws ec2 describe-*, terraform plan)
- Simple ask (del, rm, Remove-Item, docker rm, kubectl delete, terraform apply, aws s3 rm)
- PowerShell chained: `Get-Process | ForEach-Object { Stop-Process $_.Id }`
- Mixed shell: `pwsh -Command "docker ps; kubectl get pods"`
- Complex remoting: `Invoke-Command -ComputerName SRV1 -ScriptBlock { Get-Service }`
- Complex remoting (modifying): `Invoke-Command -ComputerName SRV1 -ScriptBlock { Remove-Item C:\temp\* }`
- Linux SSH: `ssh admin@server 'ls -la /etc'`
- Linux SSH (modifying): `ssh admin@server 'sudo systemctl restart nginx'`
- AWS CLI: `aws s3 ls`, `aws ec2 describe-instances`, `aws s3 rm --recursive`, `aws s3 sync`
- Terraform: `terraform -chdir="./test/" apply -auto-approve`, `terraform plan -out=plan.out`
- Docker: `docker ps -a --format '{{.ID}}' | xargs docker rm`
- DOS: `for /f %i in (servers.txt) do wmic /node:%i process call create "cmd.exe"`
- Pipeline context: `kubectl get pods -o json | jq '.items[].metadata.name' | xargs kubectl delete pod`

Structure follows `test-cases.xml` format with `<category-group>` sections.

- [ ] **Step 2: Verify both XML files are valid**

```powershell
[xml]$xml = Get-Content test-cases.xml
[xml]$xml = Get-Content test-cases.adhoc.xml
```

---

## Task 2: Implement `ConfigLoader.ps1`

**Files:** `src/ConfigLoader.ps1`

- [ ] **Step 1: Write unit-test cases in `test-cases.xml` for ConfigLoader**

Add test cases that verify:
- Valid `config.json` loads without error
- Missing file returns an error
- Invalid regex in `trusted_pattern` is caught
- Missing required keys (`version`, `commands`) are caught
- `log_file_path` defaults to empty string behavior

- [ ] **Step 2: Implement `Load-Config`**

```powershell
function Load-Config {
    param([string]$Path)
    # Read file, ConvertFrom-Json
    # Validate schema (version, commands, etc.)
    # Compile all regex patterns, catch invalid ones
    # Return PSCustomObject
}
```

- [ ] **Step 3: Implement `Test-ConfigSchema`**

Validates required top-level keys: `version`, `commands`, `trusted_pattern`, `untrusted_pattern`, `intercept_tool_name`, `ignore_tool_name`, `tool_name_mapping`.

- [ ] **Step 4: Run test runner, fix until ConfigLoader tests pass**

---

## Task 3: Implement `Logger.ps1`

**Files:** `src/Logger.ps1`

- [ ] **Step 1: Implement `New-LogDirectory`**

```powershell
function New-LogDirectory {
    param([string]$LogFilePath, [PSCustomObject]$Config)
    # Resolve log directory path
    # If config.log_file_path is set, use it
    # Otherwise use $env:USERPROFILE\.pretoolhook\ or $HOME/.pretoolhook/
    # Create directory if it doesn't exist
    # Return resolved path
}
```

- [ ] **Step 2: Implement `Write-RecordEntry`**

```powershell
function Write-RecordEntry {
    param([PSCustomObject]$RawInput, [PSCustomObject]$ClassifyResult, [string]$LogDir)
    # Build JSONL line: { "received_at": "<UTC timestamp>", "raw": <preserved JSON> }
    # Append to <date>.records.jsonl
}
```

- [ ] **Step 3: Implement `Write-LogEntry`**

```powershell
function Write-LogEntry {
    param([PSCustomObject]$RawInput, [PSCustomObject]$ClassifyResult, [TimeSpan]$Elapsed, [string]$LogDir)
    # Format log line based on decision type (ask/allow/skip/unknown_tool)
    # Include [[[command]]] markers
    # Append to <date>.log
}
```

- [ ] **Step 4: Test**

Create test cases that verify:
- Log directory is created at correct path
- Record file gets one JSONL line per call
- Log file gets correctly formatted entry
- `[SKIP]` entries for ignored tools
- `[UNKNOWN_TOOL]` entries for unknown tools
- `[[[ ]]]` markers around command text

---

## Task 4: Implement `TestRunner.ps1`

**Files:** `src/TestRunner.ps1`

- [ ] **Step 1: Implement the test runner script**

Per architecture spec section 5 — custom .ps1 with:
- Parameter: `-XmlPath` (default `../test-cases.xml`), `-Filter` (category filter)
- Loads XML, iterates test cases
- Progress display: `[23/200 12% - category name]`
- Failure output: command, expected vs got, classifier reason
- Summary: total/passed/failed/duration, list of failed test names
- Exit code: 0 on all pass, non-zero on any failure
- Calls into Classifier modules (dot-sources them)

- [ ] **Step 2: First run — ALL tests fail**

Verify the runner shows all tests as failed (no engine modules yet).
Verify progress display updates correctly.
Verify summary output is correct.

---

## Task 5: Implement `HookAdapter.ps1`

**Files:** `src/HookAdapter.ps1`

- [ ] **Step 1: Implement `Detect-IDE`**

Three-signal majority vote: `hook_event_name` + `tool_use_id` + `timestamp` format.

- [ ] **Step 2: Implement `Get-CommandFromInput`**

```powershell
function Get-CommandFromInput {
    param([PSCustomObject]$RawInput, [PSCustomObject]$Config)
    # Look up tool_name in tool_name_mapping
    # Extract command field (supports "string" and "nested.field" paths)
    # Fallback heuristic for unmapped tools
    # Return command string or $null
}
```

- [ ] **Step 3: Implement `Format-Output`**

```powershell
function Format-Output {
    param([PSCustomObject]$ClassifyResult, [string]$IDE)
    # Claude Code: wrap in hookSpecificOutput
    # Copilot: flat JSON
    # Return PSCustomObject ready for ConvertTo-Json
}
```

- [ ] **Step 4: Write tests and verify**

Test cases for:
- Claude Code detection from sample JSON
- Copilot detection from sample JSON
- Command extraction for `run_in_terminal` (tool_input as string)
- Command extraction for `bash` (tool_input.command nested path)
- Command extraction for unknown tool (heuristic fallback)
- Both output formats produce correct JSON structure

---

## Task 6: Implement `Resolver.ps1` — Explicit Entries

**Files:** `src/Resolver.ps1`

- [ ] **Step 1: Implement explicit entry matching (no verb-based yet)**

```powershell
function Resolve-Command {
    param([string]$Command, [string]$Domain, [PSCustomObject]$Config)
    # 1. Get config.commands.<Domain>
    # 2. Check read_only entries (regex patterns in order)
    # 3. Check modifying entries (regex patterns in order)
    # 4. If no match → return @{ Decision = "ask"; Reason = "unknown command" }
    # Return @{ Decision, Reason, MatchedPattern, Risk }
}
```

- [ ] **Step 2: Run against `test-cases.adhoc.xml`**

Simple single-domain commands should now pass:
- `dir C:\Windows` → allow
- `rm /tmp/file` → ask
- `docker ps` → allow
- `docker rm container` → ask
- `kubectl get pods` → allow
- `kubectl delete pod` → ask
- `terraform plan` → allow
- `terraform apply` → ask
- `aws s3 ls` → allow (explicit entry)
- `aws s3 rm` → ask (explicit entry)

---

## Task 7: Implement `Parser.ps1` — Simple Splitting

**Files:** `src/Parser.ps1`

- [ ] **Step 1: Implement domain detection**

```powershell
function Get-CommandDomain {
    param([string]$Command)
    # Check for PowerShell syntax markers (Verb-Noun, $_, | ForEach-Object, $(), @())
    # Check for known binary prefixes (docker, kubectl, aws, terraform, pwsh)
    # Check for DOS patterns (cmd /c, wmic, reg, net, sc, taskkill, tasklist)
    # Fallback → "linux"
}
```

- [ ] **Step 2: Implement command splitting**

```powershell
function Split-Commands {
    param([string]$Command)
    # Split on ; && || |
    # Return array of { CommandText, IsPipeline }
}
```

- [ ] **Step 3: Run tests for chained commands**

Test cases that should now pass:
- `ls -la && cat /etc/hosts` → allow (both read-only)
- `ls -la && rm -rf /tmp/cache` → ask (rm triggers)
- `docker ps; kubectl get pods` → allow (both read-only)
- `dir /s /b *.log ; taskkill /f /im notepad.exe` → ask (taskkill triggers)

---

## Task 8: Implement PowerShell AST Parsing

**Files:** `src/Parser.ps1` (extend)

- [ ] **Step 1: Add AST-based PowerShell parsing**

```powershell
function Get-PowerShellCommands {
    param([string]$Command)
    # Parse with [System.Management.Automation.Language.Parser]::ParseInput()
    # Walk AST: find CommandAst, ScriptBlockAst, StringConstantExpressionAst
    # For nested strings that look like commands → recurse with appropriate domain
    # For script blocks ({}), extract sub-commands recursively
    # Return flat list of { CommandText, Domain }
}
```

- [ ] **Step 2: Handle mixed shells**

For commands like:
```powershell
pwsh -Command "docker ps; kubectl get pods"
```
- AST finds `pwsh` command with `-Command` argument
- Extracts string: `"docker ps; kubectl get pods"`
- Detects domain as "general" (not PowerShell)
- Splits and classifies `docker ps` (allow) and `kubectl get pods` (allow)

- [ ] **Step 3: Run tests for PowerShell complex cases**

Test cases:
- `Get-Process | ForEach-Object { Stop-Process $_.Id }` → ask (Stop-Process)
- `Invoke-Command -ComputerName SRV1 -ScriptBlock { Get-Service }` → allow (remote Get-Service is read-only)
- `Invoke-Command -ComputerName SRV1 -ScriptBlock { Remove-Item C:\temp\* }` → ask (remote Remove-Item)
- `Get-ChildItem | Where-Object { $_.Length -gt 1MB } | ForEach-Object { Remove-Item $_.FullName }` → ask (Remove-Item in pipeline)

---

## Task 9: Implement Verb-Based Classification

**Files:** `src/Resolver.ps1` (extend)

- [ ] **Step 1: Add PowerShell verb matching**

```powershell
# In Resolve-Command, after explicit entries, before fallback:
if ($Domain -eq "powershell") {
    # Try two-word verbs first (e.g., "Invoke-Command")
    $twoWordVerb = ($Command -split '\s+')[0]
    if ($Config.commands.powershell.read_only_verbs -contains $twoWordVerb) { return allow }
    if ($Config.commands.powershell.modifying_verbs -contains $twoWordVerb) { return ask }

    # Try single-word verb prefix
    $verbPrefix = ($twoWordVerb -split '-')[0] + "-"
    if ($Config.commands.powershell.read_only_verbs -match "^$verbPrefix") { return allow }
    if ($Config.commands.powershell.modifying_verbs -match "^$verbPrefix") { return ask }
}
```

- [ ] **Step 2: Add AWS CLI verb matching**

```powershell
if ($Domain -eq "aws") {
    # Extract: aws <service> <verb-*>
    if ($Command -match '^aws\s+(\S+)\s+(\S+)') {
        $service = $matches[1]
        $verb = $matches[2]
        # Check explicit entries first (already done above)
        # Then check verb prefix
        foreach ($readVerb in $Config.commands.aws.read_only_verbs) {
            if ($verb -like "$readVerb*") { return allow }
        }
        foreach ($modVerb in $Config.commands.aws.modifying_verbs) {
            if ($verb -like "$modVerb*") { return ask }
        }
    }
}
```

- [ ] **Step 3: Test PowerShell verb classification**

Test cases:
- `Get-Process` → allow (Get- verb)
- `Set-Content file.txt "data"` → ask (Set- verb)
- `Invoke-Command -ComputerName ...` → allow (explicit read_only entry overrides Invoke-* verb)
- `Invoke-Expression "..."` → ask (Invoke-Expression in modifying list)
- `Invoke-WebRequest https://...` → ask (Invoke- verb, not Invoke-Command)

- [ ] **Step 4: Test AWS CLI verb classification**

Test cases:
- `aws ec2 describe-instances` → allow (describe- verb)
- `aws ec2 terminate-instances` → ask (terminate- verb)
- `aws s3 ls` → allow (explicit entry)
- `aws s3 sync ./dir s3://bucket/` → ask (explicit modifying entry)
- `aws rds create-db-instance` → ask (create- verb)
- `aws lambda list-functions` → allow (list- verb)

---

## Task 10: Implement `Classifier.ps1` — Full Pipeline

**Files:** `src/Classifier.ps1`

- [ ] **Step 1: Implement `Test-ToolNameFilter`**

```powershell
function Test-ToolNameFilter {
    param([string]$ToolName, [PSCustomObject]$Config)
    # Check ignore_tool_name → return skip
    # Check intercept_tool_name → return classify
    # Neither → return unknown
}
```

- [ ] **Step 2: Implement `Test-TrustedUntrusted`**

```powershell
function Test-TrustedUntrusted {
    param([string]$Command, [PSCustomObject]$Config)
    # Check untrusted_pattern regexes → if match, return ask
    # Check trusted_pattern regexes → if match, return allow
    # No match → return $null (continue to classification)
}
```

- [ ] **Step 3: Implement `Invoke-Classify` — full pipeline orchestration**

```powershell
function Invoke-Classify {
    param([PSCustomObject]$RawInput, [string]$IDE, [PSCustomObject]$Config)

    # STEP 0: Tool name filtering
    $toolFilter = Test-ToolNameFilter -ToolName $RawInput.tool_name -Config $Config
    if ($toolFilter -eq "skip") {
        return @{ Decision = "allow"; Reason = "ignored tool: $($RawInput.tool_name)"; ExitCode = 0 }
    }
    if ($toolFilter -eq "unknown") {
        return @{ Decision = "ask"; Reason = "unknown tool: $($RawInput.tool_name)"; ExitCode = 2 }
    }

    # STEP 1: Extract command
    $command = Get-CommandFromInput -RawInput $RawInput -Config $Config
    if (-not $command) {
        return @{ Decision = "ask"; Reason = "could not extract command from input"; ExitCode = 2 }
    }

    # STEP 2-3: Trusted/untrusted gate
    $gateResult = Test-TrustedUntrusted -Command $command -Config $Config
    if ($gateResult) { return $gateResult }

    # STEP 4: Classification engine
    $domain = Get-CommandDomain -Command $command
    $subCommands = Split-Commands -Command $command -Domain $domain

    $results = @()
    $blockingCommands = @()
    foreach ($sc in $subCommands) {
        $r = Resolve-Command -Command $sc.CommandText -Domain $sc.Domain -Config $Config
        $results += $r
        if ($r.Decision -eq "ask") {
            $blockingCommands += $r
        }
    }

    if ($blockingCommands.Count -gt 0) {
        $reasons = ($blockingCommands | ForEach-Object { $_.Reason }) -join ", "
        return @{
            Decision = "ask"
            Reason = $reasons
            SubResults = $results
            ExitCode = 2
        }
    }

    return @{
        Decision = "allow"
        Reason = "read-only"
        SubResults = $results
        ExitCode = 0
    }
}
```

- [ ] **Step 4: Run full test suite against `test-cases.adhoc.xml`**

All tests should now pass EXCEPT complex nesting (SSH remoting, PowerShell remoting with modifying commands inside).

---

## Task 11: Implement Nested/Pipeline Command Handling

**Files:** `src/Parser.ps1` (extend), `src/Classifier.ps1` (extend)

- [ ] **Step 1: Handle SSH remoting**

```powershell
# In Split-Commands, detect ssh patterns:
if ($command -match '^ssh\s+\S+\s+[''"]?(.+?)[''"]?\s*$') {
    $remoteCmd = $matches[1]
    # Recurse: classify the remote command separately
    $innerResult = Resolve-Command -Command $remoteCmd -Domain "linux" -Config $Config
    # Tag the ssh as a wrapper with embedded modifying/read-only
}
```

- [ ] **Step 2: Handle pipeline context**

When a command is part of a pipeline chain, capture the relationship:
```powershell
# e.g., kubectl get pods | xargs kubectl delete pod
# → "kubectl get pods → kubectl delete pod (output piped to modify)"
```

- [ ] **Step 3: Handle nested subshells and redirections**

- `$(command)` — recursive classification
- `command > /etc/config` — redirection to system path → modifying
- `command > /tmp/out.txt` — redirection to temp → low-risk modifying
- `command > /dev/null` — discard output → still read-only (no side effect)

- [ ] **Step 4: Run ALL tests, verify complex remoting passes**

---

## Task 12: Implement `Hook.ps1` Entry Point

**Files:** `src/Hook.ps1`

- [ ] **Step 1: Implement the main hook script**

```powershell
# Read stdin
$rawJson = $input | Out-String
if ([string]::IsNullOrWhiteSpace($rawJson)) {
    Write-Error "No input received on stdin"
    exit 2
}

$startTime = Get-Date

try {
    $rawInput = $rawJson | ConvertFrom-Json
} catch {
    Write-Error "Malformed JSON input: $_"
    exit 2
}

# Dot-source modules
. "$PSScriptRoot\HookAdapter.ps1"
. "$PSScriptRoot\ConfigLoader.ps1"
. "$PSScriptRoot\Logger.ps1"
. "$PSScriptRoot\Classifier.ps1"

try {
    $config = Load-Config -Path "$PSScriptRoot\..\config.json"
} catch {
    Write-Error "Configuration error: $_"
    exit 2
}

$ide = Detect-IDE -InputObject $rawInput
$classifyResult = Invoke-Classify -RawInput $rawInput -IDE $ide -Config $config
$elapsed = (Get-Date) - $startTime

# Hard timeout check
if ($elapsed.TotalMilliseconds -gt 1000) {
    Write-Error "Classification exceeded 1000ms hard cap ($($elapsed.TotalMilliseconds)ms)"
    $classifyResult = @{ Decision = "ask"; Reason = "classification timed out"; ExitCode = 2 }
}

# Logging
try {
    $logDir = New-LogDirectory -Config $config
    Write-RecordEntry -RawInput $rawInput -ClassifyResult $classifyResult -LogDir $logDir
    Write-LogEntry -RawInput $rawInput -ClassifyResult $classifyResult -Elapsed $elapsed -LogDir $logDir
} catch {
    Write-Error "Logging error (non-fatal): $_"
}

# Format and output
$output = Format-Output -Result $classifyResult -IDE $ide
$output | ConvertTo-Json -Compress | Write-Output

exit $classifyResult.ExitCode
```

- [ ] **Step 2: End-to-end tests**

Pipe sample JSON to Hook.ps1, verify correct stdout:
```powershell
$input = '{"hook_event_name":"PreToolUse","tool_use_id":"abc-123","timestamp":"2026-05-15T14:32:01.234Z","tool_name":"run_in_terminal","tool_input":"docker ps"}'
$input | pwsh -File src/Hook.ps1
# Expected: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",...}}
```

---

## Task 13: Error Handling & Edge Cases

**Files:** All `src/*.ps1` (extend)

- [ ] **Step 1: Malformed JSON handling** (Hook.ps1)

- [ ] **Step 2: Missing field handling** (HookAdapter.ps1)

- [ ] **Step 3: Classification timeout guard** (Classifier.ps1)

Add a `[System.Diagnostics.Stopwatch]` check after each major step. If cumulative time exceeds 1000ms, abort and return ask.

- [ ] **Step 4: PowerShell AST parse error fallback** (Parser.ps1)

When AST parse fails ($errors.Count > 0), fall back to pattern-based splitting.

- [ ] **Step 5: Log directory creation failure** (Logger.ps1)

Non-fatal: log to stderr, classification still proceeds.

- [ ] **Step 6: Write edge case tests**

Test cases for:
- Empty command string
- Extremely long command (>10KB)
- Unicode/emoji in commands
- Commands that look obfuscated (base64 encoded pipes)
- Commands with only whitespace
- Commands with only comments

---

## Task 14: Performance Tuning

**Files:** `src/*.ps1`

- [ ] **Step 1: Benchmark each module**

Measure time spent in:
- Config loading (one-time per invocation)
- Domain detection
- Command splitting
- Pattern matching per sub-command
- Log writing

- [ ] **Step 2: Optimize bottlenecks**

If any step exceeds targets from architecture spec:
- Cache compiled regex objects (`[regex]::new($pattern, 'Compiled')`)
- Use hash lookups instead of linear scans for common verb lists
- Lazy PowerShell AST invocation (only for PS-looking commands)

- [ ] **Step 3: Run full `test-cases.xml` suite, verify timing**

All 228+ tests must pass with per-test classification under 500ms.

---

## Task 15: Expand `test-cases.xml` to 328+ Test Cases

**Files:** `test-cases.xml`

- [ ] **Step 1: Retrofit `reason` attribute on all existing 228 entries**

Per the design spec (`2026-05-15-complex-command-test-cases-design.md`):
- `expected="allow"` entries → `reason="read-only"`
- `expected="ask"` entries → specific modifying sub-command(s)

- [ ] **Step 2: Add 100+ complex test cases**

Target per domain:
- PowerShell: 15+ (heavy remoting focus)
- Linux: 15+ (heavy SSH remoting focus)
- DOS/CMD: 12+
- Terraform: 12+ (flag-separated subcommand focus)
- Docker: 12+
- Kubernetes: 12+
- AWS CLI: 12+
- Remainder: distributed to domains with richest findings

All new entries require `reason` attribute.

- [ ] **Step 3: Validation**

```powershell
# XML well-formed
[xml]$xml = Get-Content test-cases.xml
# All test cases have reason attribute
$xml.commands.'category-group'.'test-case' | ForEach-Object {
    if (-not $_.reason) { Write-Error "Missing reason: $($_.description)" }
}
# Count total test cases
$total = ($xml.commands.'category-group'.'test-case').Count
Write-Host "Total test cases: $total"  # Must be >= 328
```

- [ ] **Step 4: Run test runner, verify ALL pass**

---

## Task 16: Final Verification

- [ ] **Step 1: Full `test-cases.xml` suite — zero failures**

```powershell
pwsh src/TestRunner.ps1 -XmlPath test-cases.xml
# Exit code must be 0
```

- [ ] **Step 2: Performance verification**

All tests complete in under 500ms each; no test exceeds 1000ms.

- [ ] **Step 3: Record + log file verification**

Verify both files are created, correctly formatted, and contain expected entries.

- [ ] **Step 4: Cross-IDE test**

Pump both Claude Code format and Copilot format JSON through Hook.ps1. Verify correct output shape for each.
