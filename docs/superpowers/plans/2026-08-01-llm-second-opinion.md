# LLM Second Opinion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `llm_second_opinion` feature that cross-checks the local classification with an LLM verdict and forces `ask` (with eye-catching wording) on dangerous disagreement or LLM failure — a complete no-op when disabled.

**Architecture:** Approach A per spec `docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md` (read it first — D1-D10 are locked). New `src/LlmReview.ps1` module (scope engine + verdict client + merge orchestrator), `Invoke-Classify` untouched, merge wired into `src/Hook.ps1` after Step 8, ConfigLoader validates/compiles the optional config block, Logger records an `llm` object. Tests use the `PRETOOLHOOK_LLMREVIEW_MOCK` env short-circuit — no test ever touches the network.

**Tech Stack:** PowerShell (5.1-compatible — **no `??`, no ternary, ASCII-only string literals in all shipped code**; `powershell.exe` 5.1 misreads UTF-8 punctuation), OpenAI-compatible chat-completions endpoint, XML-driven test fixtures.

**File structure:**

| File | Responsibility |
|---|---|
| `src/LlmReview.ps1` (new) | `Test-LlmReviewScope`, `ConvertTo-LlmVerdict`, `Get-LlmReviewVerdict`, `Invoke-LlmReview` |
| `src/ConfigLoader.ps1` | Optional `llm_second_opinion` validation (Test-ConfigSchema) + compilation onto `_compiled.llmSecondOpinion` (Load-Config) |
| `src/Hook.ps1` | Dot-source LlmReview; Step 8b merge call; conditional hard cap; pass `-LlmLog` to Logger |
| `src/Logger.ps1` | Optional `-LlmLog` on `Write-RecordEntry` (JSONL `llm` field) and `Write-LogEntry` (one text line) |
| `config.json` | New `llm_second_opinion` block, `enabled: false` |
| `test/config/llm-review/` (new) | Isolated fixture: `config.json`, `config.badlevel.json`, `test-cases.xml`, `Run-Tests.ps1`, `README.md` |
| `C:\git\cc\deepseek-tester\api-gateway-caller.ps1` | POC prompt + parser sync (separate repo, user's experiment tool) |
| `docs/config-json-guide.md`, `README.md`, `PROGRESS.md` | Documentation |

**Test command (fixture):** `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1` (from repo root). 25 checks total: 16 classify-mode cases + 1 config negative test + 6 parser unit checks + 2 fullpipe cases.

---

### Task 1: Fixture skeleton + runner + RED baseline

**Files:**
- Create: `test/config/llm-review/config.json`
- Create: `test/config/llm-review/config.badlevel.json`
- Create: `test/config/llm-review/test-cases.xml`
- Create: `test/config/llm-review/Run-Tests.ps1`

This task creates the complete test harness BEFORE any implementation (TDD). The runner auto-fails classification cases while `src/LlmReview.ps1` is missing (same scaffold pattern as `src/TestRunner.ps1`'s missing-Classifier guard) and stubs `_compiled.llmSecondOpinion` with `Enabled=$false` until ConfigLoader implements it.

- [ ] **Step 1: Create the fixture config**

`test/config/llm-review/config.json` (complete content). Minimal domains; `remote_indicators` deliberately omitted so the compiled defaults are exercised:

```json
{
  "version": "1.0",
  "description": "TEST FIXTURE for llm_second_opinion (second-opinion LLM cross-check). Minimal domains; LLM verdicts come from PRETOOLHOOK_LLMREVIEW_MOCK, never the network.",
  "_comment_fixture": "Isolated fixture for llm_second_opinion. Run via test/config/llm-review/Run-Tests.ps1. Scope is decided from SubResults (engine decomposition); verdicts are injected by the mock env var.",

  "global_modifying_strictness": "normal",

  "trusted_pattern": [],
  "untrusted_pattern": [],

  "intercept_tool_name": [ "Bash", "run_in_terminal" ],

  "tool_name_mapping": {
    "Bash": "tool_input.command",
    "run_in_terminal": "tool_input.command"
  },

  "ignore_tool_name": [],

  "llm_second_opinion": {
    "enabled": true,
    "level": "complex_remote",
    "base_uri": "http://127.0.0.1:3030",
    "model": "glm-5.2",
    "api_key": "",
    "timeout_ms": 12000,
    "temperature": 0.0,
    "max_tokens": 16,
    "complex_min_subcommands": 2,
    "_comment": "remote_indicators omitted on purpose -> the compiled default list is under test. Verdicts are mocked via PRETOOLHOOK_LLMREVIEW_MOCK; no network call ever happens."
  },

  "commands": {
    "PowerShell": {
      "modifying_strictness": "normal",
      "description": "Minimal PowerShell domain (verb-based classification).",
      "read_only_verbs": ["Get-*", "Test-*", "Select-*", "Where-*", "Sort-*", "Measure-*", "Format-*", "Write-Host", "Write-Output"],
      "modifying_verbs": {
        "high":   ["Remove-*", "Stop-*"],
        "medium": ["Set-*", "New-*", "Copy-*", "Move-*", "Rename-*"],
        "low":    []
      },
      "read_only": [],
      "modifying": []
    },

    "Linux": {
      "modifying_strictness": "normal",
      "description": "Minimal Linux domain. curl is treated as read-only here so a curl pipeline is locally ALLOWED (needed to exercise the veto path on a remote command).",
      "read_only": [
        { "name": "ls",   "patterns": ["ls *"],   "description": "List directory contents" },
        { "name": "cat",  "patterns": ["cat *"],  "description": "Print file contents" },
        { "name": "curl", "patterns": ["curl *"], "description": "HTTP fetch (fixture: read-only)" }
      ],
      "modifying": [
        { "name": "rm", "patterns": ["rm *"], "risk": "high", "description": "Remove files/directories" }
      ]
    },

    "Git": {
      "modifying_strictness": "normal",
      "description": "Minimal Git domain. git counts as LOCAL for llm_second_opinion (no remote indicator).",
      "read_only": [
        { "name": "git status", "patterns": ["git status"], "description": "Working tree status" }
      ],
      "modifying": [
        { "name": "git push", "patterns": ["git push *"], "risk": "medium", "description": "Push refs" }
      ]
    }
  }
}
```

- [ ] **Step 2: Create the bad-level config**

```powershell
Copy-Item test/config/llm-review/config.json test/config/llm-review/config.badlevel.json
```

Then edit `test/config/llm-review/config.badlevel.json`: change `"level": "complex_remote"` to `"level": "bogus"`. (Used by the runner's pre-flight check: `Load-Config` must throw with `llm_second_opinion.level` in the message.)

- [ ] **Step 3: Create the test cases XML**

`test/config/llm-review/test-cases.xml` (complete content). Per-case attributes consumed by the runner: `level` (default `complex_remote`), `min` (default 2), `enabled` (default true), `mock` (`modifying|read-only|garbage|down`; unset = env var cleared), `in-scope` (`true|false`, asserted against `Log.in_scope`), `verdict`, `effect` (asserted against the Log object), `reason-contains` (substring asserted on the final reason), `mode` (`classify` default, `fullpipe` = spawn the real hook):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- LLM-REVIEW SUITE - isolated fixture (test/config/llm-review/config.json).
     Proves llm_second_opinion: leveled scope (all/complex_commands/complex_remote),
     veto/agree/disagree-kept-ask/down/unusable merge matrix, disabled no-op,
     bad-level config rejection, and end-to-end Hook.ps1 wiring (fullpipe).
     LLM verdicts are injected via PRETOOLHOOK_LLMREVIEW_MOCK - NO network.
     Run:
       pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -->
<commands>
  <category-group name="LlmScope">

    <test-case expected="ask" category="LlmScope-All-SingleChecked" level="all" mock="modifying" in-scope="true" verdict="modifying" effect="veto" reason-contains="*** LLM-VETO ***" reason="level all checks even a single command; local allow + LLM modifying => veto ask">
      <description>level=all: single read-only command is LLM-checked; veto applies</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmScope-Complex-SingleSkipped" level="complex_commands" mock="modifying" in-scope="false" verdict="not_called" effect="none" reason="single command below min => not checked; mock never consulted">
      <description>level=complex_commands: single command NOT checked</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmScope-Complex-PipeChecked" level="complex_commands" mock="modifying" in-scope="true" verdict="modifying" effect="veto" reason-contains="*** LLM-VETO ***" reason="2-stage pipe meets min=2 => checked; veto applies">
      <description>level=complex_commands: read-only pipe checked; veto applies</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmScope-Min3-PipeSkipped" level="complex_commands" min="3" mock="modifying" in-scope="false" verdict="not_called" effect="none" reason="2 sub-commands < min=3 => not checked">
      <description>complex_min_subcommands=3: 2-stage pipe NOT checked</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmScope-Remote-LocalPipeSkipped" level="complex_remote" mock="modifying" in-scope="false" verdict="not_called" effect="none" reason="complex but local-only (no remote indicator) => not checked">
      <description>level=complex_remote: local pipe NOT checked</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmScope-Remote-AwsChecked" level="complex_remote" mock="read-only" in-scope="true" verdict="read-only" effect="disagree-kept-ask" reason-contains="unknown domain" reason="aws chain is complex+remote => checked; local ask (no AWS domain in fixture) + LLM read-only => stays ask">
      <description>level=complex_remote: aws chain checked; disagreement keeps ask</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[aws s3 ls && aws s3 cp f s3://b/k]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmScope-Remote-DockerChecked" level="complex_remote" mock="read-only" in-scope="true" verdict="read-only" effect="disagree-kept-ask" reason-contains="unknown domain" reason="docker chain is complex+remote => checked; local ask kept">
      <description>level=complex_remote: docker chain checked; disagreement keeps ask</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[docker ps && docker rm c1]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmScope-Remote-LocalICSkipped" level="complex_remote" mock="modifying" in-scope="false" verdict="not_called" effect="none" reason="Invoke-Command WITHOUT -ComputerName is local => not checked">
      <description>level=complex_remote: local Invoke-Command NOT checked</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Invoke-Command -ScriptBlock { Get-Process }; Get-Date]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmScope-Remote-RemoteICChecked" level="complex_remote" mock="modifying" in-scope="true" verdict="modifying" effect="veto" reason-contains="*** LLM-VETO ***" reason="Invoke-Command with -ComputerName matches the remote indicator via the ORIGINAL command text (wrapper is unwrapped in SubResults) => checked; local allow + LLM modifying => veto">
      <description>level=complex_remote: Invoke-Command -ComputerName checked; veto applies</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Invoke-Command -ComputerName srv01 -ScriptBlock { Get-Process }; Get-Date]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmScope-Remote-GitLocalSkipped" level="complex_remote" mock="read-only" in-scope="false" verdict="not_called" effect="none" reason="git is LOCAL (no indicator) => not checked; local ask (git push) stands">
      <description>level=complex_remote: git chain NOT checked (git is local)</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git status && git push origin main]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="LlmMerge">

    <test-case expected="ask" category="LlmMerge-Veto" level="complex_commands" mock="modifying" in-scope="true" verdict="modifying" effect="veto" reason-contains="*** LLM-VETO ***" reason="local allow + LLM modifying => forced ask with veto wording">
      <description>merge: veto escalates allow to ask</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmMerge-AgreeAllow" level="complex_commands" mock="read-only" in-scope="true" verdict="read-only" effect="agree" reason-contains="read-only" reason="local allow + LLM read-only => allow; reason unchanged">
      <description>merge: agree keeps allow</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmMerge-DisagreeKeptAsk" level="complex_commands" mock="read-only" in-scope="true" verdict="read-only" effect="disagree-kept-ask" reason-contains="Remove-" reason="local ask (Remove-Item) + LLM read-only => stays ask; local reason preserved (LLM never downgrades)">
      <description>merge: LLM read-only never downgrades a local ask</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Remove-Item c:\temp\x.txt]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmMerge-Down" level="complex_commands" mock="down" in-scope="true" verdict="down" effect="forced-ask" reason-contains="*** LLM-DOWN ***" reason="LLM unreachable => fail-closed ask with down wording">
      <description>merge: LLM down forces ask with notification wording</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="LlmMerge-Unusable" level="complex_commands" mock="garbage" in-scope="true" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="unparseable LLM response => fail-closed ask with unusable wording">
      <description>merge: garbage response forces ask with unusable wording</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmMerge-Disabled" level="complex_commands" enabled="false" mock="modifying" reason="enabled=false => feature no-op; local allow stands; mock never consulted">
      <description>merge: disabled feature is a complete no-op</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-ChildItem c:\temp | Select-Object -First 5]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="LlmFullPipe" mode="fullpipe">

    <test-case expected="ask" category="LlmFullPipe-Veto" mode="fullpipe" mock="modifying" reason-contains="*** LLM-VETO ***" reason="end-to-end through Hook.ps1: remote curl pipe (fixture level=complex_remote) + mock modifying => permissionDecision ask with veto wording, exit 0">
      <description>fullpipe: veto flows through the real hook process</description>
      <tool-name>run_in_terminal</tool-name>
      <copilot-command><![CDATA[curl -s http://example.com | cat]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="LlmFullPipe-OutOfScope" mode="fullpipe" mock="modifying" reason="end-to-end through Hook.ps1: single local command out of scope at fixture level=complex_remote => allow, exit 0 (mock set but never consulted)">
      <description>fullpipe: out-of-scope command passes through unchanged</description>
      <tool-name>run_in_terminal</tool-name>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>

  </category-group>
</commands>
```

- [ ] **Step 4: Create the runner**

`test/config/llm-review/Run-Tests.ps1` (complete content):

```powershell
# Run-Tests.ps1 - llm_second_opinion fixture runner
# In-process classify+merge tests (mode=classify) plus end-to-end Hook.ps1
# process tests (mode=fullpipe). LLM verdicts are injected via
# PRETOOLHOOK_LLMREVIEW_MOCK - no network call ever happens.
#
# Per-case XML attributes:
#   expected         allow|ask (required) - final decision
#   category         group label (required)
#   reason           free text, shown on failure
#   level            all|complex_commands|complex_remote (default complex_remote)
#   min              complex_min_subcommands override (default 2)
#   enabled          true|false (default true)
#   mock             modifying|read-only|garbage|down (unset = env var cleared)
#   in-scope         true|false - asserted against Log.in_scope (optional)
#   verdict          asserted against Log.verdict (optional)
#   effect           asserted against Log.effect (optional)
#   reason-contains  substring asserted on the final Reason (optional)
#   mode             classify (default) | fullpipe (spawns src/Hook.ps1)
#
# Run from repo root:  pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1

$ErrorActionPreference = "Stop"
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"
$hookPath   = Join-Path $srcDir "Hook.ps1"
$configPath = Join-Path $fixtureDir "config.json"

# Dot-source engine modules
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "Classifier.ps1")

# TDD scaffold: auto-fail classify cases while LlmReview.ps1 does not exist
$LlmReviewLoaded = $false
if (Test-Path (Join-Path $srcDir "LlmReview.ps1")) {
    . (Join-Path $srcDir "LlmReview.ps1")
    $LlmReviewLoaded = $true
}

$config = Load-Config -Path $configPath

# TDD scaffold: until ConfigLoader compiles the block, stub it so the per-case
# override lines below have a non-null object to mutate (Enabled=$false there is
# irrelevant - every case sets Enabled/Level/ComplexMinSubcommands explicitly).
if (-not $config._compiled.llmSecondOpinion) {
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'llmSecondOpinion' -Force -Value (
        [PSCustomObject]@{
            Enabled               = $false
            Level                 = 'complex_remote'
            BaseUri               = 'http://127.0.0.1:3030'
            Model                 = 'glm-5.2'
            ApiKey                = ''
            TimeoutMs             = 12000
            Temperature           = 0.0
            MaxTokens             = 16
            ComplexMinSubcommands = 2
            RemoteIndicators      = @()
        })
}

# Child-process engine for fullpipe cases (same family as the current process)
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

[xml]$xml = Get-Content (Join-Path $fixtureDir "test-cases.xml") -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

$total = 0; $passed = 0; $failed = 0; $failures = @()

function Record-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    $script:total++
    if ($Ok) { $script:passed++ }
    else {
        $script:failed++
        $script:failures += [PSCustomObject]@{ Name = $Name; Detail = $Detail }
        Write-Host "FAIL [$Name]" -ForegroundColor Red
        Write-Host "  $Detail"
    }
}

# ---- Pre-flight: bad-level config must be rejected fail-closed ----
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badlevel.json")
    Record-Result -Ok $false -Name "LlmConfig-BadLevel" -Detail "Load-Config did NOT throw for level='bogus'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_second_opinion\.level'
    Record-Result -Ok $ok -Name "LlmConfig-BadLevel" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# ---- Pre-flight: ConvertTo-LlmVerdict parser unit checks (spec 5.3 layers) ----
$parserCases = @(
    @{ Name = 'LlmParser-BareTrue';      Raw = 'true';                                WantVerdict = 'modifying'; WantRecovered = $false },
    @{ Name = 'LlmParser-BareFalseCase'; Raw = "  FALSE`n";                           WantVerdict = 'read-only'; WantRecovered = $false },
    @{ Name = 'LlmParser-Json';          Raw = '{"verdict":"modifying"}';             WantVerdict = 'modifying'; WantRecovered = $false },
    @{ Name = 'LlmParser-LastLine';      Raw = "reasoning about the command`nfalse";  WantVerdict = 'read-only'; WantRecovered = $true },
    @{ Name = 'LlmParser-Garbage';       Raw = 'I think this is safe but I am unsure'; WantVerdict = 'unusable'; WantRecovered = $false },
    @{ Name = 'LlmParser-Empty';         Raw = '';                                    WantVerdict = 'unusable'; WantRecovered = $false }
)
foreach ($pc in $parserCases) {
    if (-not (Get-Command ConvertTo-LlmVerdict -ErrorAction SilentlyContinue)) {
        Record-Result -Ok $false -Name $pc.Name -Detail "ConvertTo-LlmVerdict not defined (TDD red phase)"
        continue
    }
    $got = ConvertTo-LlmVerdict -RawContent $pc.Raw
    $ok = ($got.Verdict -eq $pc.WantVerdict) -and ($got.Recovered -eq $pc.WantRecovered)
    Record-Result -Ok $ok -Name $pc.Name -Detail "raw='$($pc.Raw)' => verdict=$($got.Verdict) recovered=$($got.Recovered) (wanted $($pc.WantVerdict)/$($pc.WantRecovered))"
}

# ---- Per-case loop ----
foreach ($tc in $testCases) {
    $name = $tc.category
    $mode = if ($tc.HasAttribute('mode')) { $tc.GetAttribute('mode') } else { 'classify' }
    $reasonContains = if ($tc.HasAttribute('reason-contains')) { $tc.GetAttribute('reason-contains') } else { $null }

    # Resolve command text (handles CDATA)
    $cmdNode = $tc.'copilot-command'
    if ($cmdNode -is [System.Xml.XmlElement]) { $command = $cmdNode.InnerText } else { $command = "$cmdNode" }
    $command = $command.Trim()

    $toolName = "Bash"
    $toolNameNode = $tc.SelectSingleNode('tool-name')
    if ($toolNameNode -and $toolNameNode.InnerText.Trim()) { $toolName = $toolNameNode.InnerText.Trim() }

    # Mock env var
    if ($tc.HasAttribute('mock')) { $env:PRETOOLHOOK_LLMREVIEW_MOCK = $tc.GetAttribute('mock') }
    else { Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue }

    if ($mode -eq 'fullpipe') {
        # ---- End-to-end: spawn the real hook process ----
        $payload = (@{
            tool_name       = $toolName
            tool_input      = @{ command = $command }
            hook_event_name = 'preToolUse'
            timestamp       = '1790000000000'
        } | ConvertTo-Json -Compress -Depth 5)
        $env:PRETOOLHOOK_CONFIG_PATH = $configPath
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

        try {
            $out = $stdout | ConvertFrom-Json -ErrorAction Stop
            $decision = $out.hookSpecificOutput.permissionDecision
            $reason   = "$($out.hookSpecificOutput.permissionDecisionReason)"
            $ok = ($decision -eq $tc.expected) -and ($exitCode -eq 0)
            if ($ok -and $reasonContains) { $ok = $reason.Contains($reasonContains) }
            Record-Result -Ok $ok -Name $name -Detail "cmd: $command | expected $($tc.expected)+exit0 got $decision+exit$exitCode | reason: $reason"
        }
        catch {
            Record-Result -Ok $false -Name $name -Detail "cmd: $command | stdout not JSON: $stdout"
        }
        continue
    }

    # ---- In-process classify + merge ----
    # Per-case overrides on the compiled block (reset each case)
    $llmCfg = $config._compiled.llmSecondOpinion
    $llmCfg.Enabled               = if ($tc.HasAttribute('enabled')) { [bool]::Parse($tc.GetAttribute('enabled')) } else { $true }
    $llmCfg.Level                 = if ($tc.HasAttribute('level')) { $tc.GetAttribute('level') } else { 'complex_remote' }
    $llmCfg.ComplexMinSubcommands = if ($tc.HasAttribute('min')) { [int]$tc.GetAttribute('min') } else { 2 }

    $rawInput = [PSCustomObject]@{
        tool_name  = $toolName
        tool_input = [PSCustomObject]@{ command = $command }
    }

    $result = $null; $llmLog = $null
    try {
        $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        # Mirror the Hook.ps1 gate
        if ($llmCfg.Enabled) {
            if (-not $LlmReviewLoaded) { throw "LlmReview.ps1 not loaded (TDD red phase)" }
            $outcome = Invoke-LlmReview -ClassifyResult $result -Config $config
            $result = $outcome.Result
            $llmLog = $outcome.Log
        }
    }
    catch {
        $result = [PSCustomObject]@{ Decision = "error"; Reason = $_.Exception.Message }
    }
    Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

    $ok = ($result.Decision -eq $tc.expected)
    $detail = "cmd: $command | expected $($tc.expected) got $($result.Decision) | reason: $($result.Reason)"

    if ($ok -and $reasonContains) {
        $ok = ("$($result.Reason)").Contains($reasonContains)
        if (-not $ok) { $detail += " | reason missing '$reasonContains'" }
    }
    if ($ok -and $tc.HasAttribute('in-scope')) {
        $wantScope = [bool]::Parse($tc.GetAttribute('in-scope'))
        $gotScope = if ($llmLog) { [bool]$llmLog.in_scope } else { $false }
        $ok = ($gotScope -eq $wantScope)
        if (-not $ok) { $detail += " | in_scope expected $wantScope got $gotScope" }
    }
    if ($ok -and $tc.HasAttribute('verdict')) {
        $got = if ($llmLog) { "$($llmLog.verdict)" } else { '<null>' }
        $ok = ($got -eq $tc.GetAttribute('verdict'))
        if (-not $ok) { $detail += " | verdict expected $($tc.GetAttribute('verdict')) got $got" }
    }
    if ($ok -and $tc.HasAttribute('effect')) {
        $got = if ($llmLog) { "$($llmLog.effect)" } else { '<null>' }
        $ok = ($got -eq $tc.GetAttribute('effect'))
        if (-not $ok) { $detail += " | effect expected $($tc.GetAttribute('effect')) got $got" }
    }
    Record-Result -Ok $ok -Name $name -Detail $detail
}

Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================"
Write-Host "LLM-Review Fixture Run Complete"
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
if ($failures.Count -gt 0) {
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $($f.Name)" -ForegroundColor Red }
}
Write-Host "========================================"
if ($failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 5: Run to verify RED baseline**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1` (from repo root)
Expected: FAIL — `Total: 25  Passed: 2  Failed: 23`, exit code 1. The only 2 passes: LlmMerge-Disabled (the runner's per-case `enabled="false"` skips the LLM gate entirely, so pure local allow matches) and LlmFullPipe-OutOfScope (the unwired hook returns local allow). Everything else fails: 15 classify cases throw "LlmReview.ps1 not loaded (TDD red phase)" via the runner guard, LlmConfig-BadLevel fails (Load-Config ignores the unknown block today), the 6 parser checks fail (module missing), and LlmFullPipe-Veto fails (allow ≠ ask).

- [ ] **Step 6: Commit**

```powershell
git add test/config/llm-review/
git commit -m "test: llm_second_opinion fixture + runner (RED baseline 9/19)"
```

---

### Task 2: ConfigLoader — validate + compile `llm_second_opinion`

**Files:**
- Modify: `src/ConfigLoader.ps1` (Test-ConfigSchema after the `trusted_programs` validation ~line 74; Load-Config after the `trustedPrograms` compilation ~line 440)
- Test: `test/config/llm-review/Run-Tests.ps1`

- [ ] **Step 1: Add schema validation**

In `Test-ConfigSchema`, immediately after the optional `trusted_programs` validation block (ends ~line 74), insert:

```powershell
    # Validate optional "llm_second_opinion" block (second-opinion LLM cross-check).
    # OPTIONAL: absent = feature off. When present it is validated even with
    # enabled=false so bad values surface at load time, not at first use.
    $hasLlm = Get-Member -InputObject $Config -Name 'llm_second_opinion' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasLlm) {
        $llm = $Config.llm_second_opinion
        if ($llm -isnot [PSCustomObject] -and $llm -isnot [hashtable]) {
            throw "Configuration validation failed: 'llm_second_opinion' must be an object"
        }
        if ((Get-Member -InputObject $llm -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.enabled -isnot [bool]) {
            throw "Configuration validation failed: 'llm_second_opinion.enabled' must be a boolean"
        }
        if ((Get-Member -InputObject $llm -Name 'level' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.level -notin @('all', 'complex_commands', 'complex_remote')) {
            throw "Configuration validation failed: 'llm_second_opinion.level' must be 'all', 'complex_commands', or 'complex_remote', got '$($llm.level)'"
        }
        $intFields = @('complex_min_subcommands', 'timeout_ms', 'max_tokens')
        foreach ($f in $intFields) {
            if (Get-Member -InputObject $llm -Name $f -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                $v = 0
                if (-not [int]::TryParse("$($llm.$f)", [ref]$v) -or $v -lt 1) {
                    throw "Configuration validation failed: 'llm_second_opinion.$f' must be an integer >= 1, got '$($llm.$f)'"
                }
            }
        }
        if (Get-Member -InputObject $llm -Name 'temperature' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $tv = 0.0
            if (-not [double]::TryParse("$($llm.temperature)", [ref]$tv) -or $tv -lt 0.0 -or $tv -gt 2.0) {
                throw "Configuration validation failed: 'llm_second_opinion.temperature' must be a number between 0.0 and 2.0, got '$($llm.temperature)'"
            }
        }
        if ((Get-Member -InputObject $llm -Name 'api_key' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $null -ne $llm.api_key -and $llm.api_key -isnot [string]) {
            throw "Configuration validation failed: 'llm_second_opinion.api_key' must be a string"
        }
        if (Get-Member -InputObject $llm -Name 'remote_indicators' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            if ($llm.remote_indicators -isnot [array]) {
                throw "Configuration validation failed: 'llm_second_opinion.remote_indicators' must be an array of regex strings"
            }
            foreach ($p in $llm.remote_indicators) {
                try { $null = [regex]::new($p.ToString()) }
                catch { throw "Invalid regex in llm_second_opinion.remote_indicators: $p" }
            }
        }
        # base_uri and model are required only when the feature is enabled
        if ($llm.enabled -eq $true) {
            if (-not (Get-Member -InputObject $llm -Name 'base_uri' -MemberType NoteProperty) -or [string]::IsNullOrWhiteSpace($llm.base_uri)) {
                throw "Configuration validation failed: 'llm_second_opinion.base_uri' is required when enabled is true"
            }
            if (-not (Get-Member -InputObject $llm -Name 'model' -MemberType NoteProperty) -or [string]::IsNullOrWhiteSpace($llm.model)) {
                throw "Configuration validation failed: 'llm_second_opinion.model' is required when enabled is true"
            }
        }
    }
```

- [ ] **Step 2: Add compilation**

In `Load-Config`, immediately after the `trustedPrograms` compilation block (ends ~line 440 with `$config._compiled | Add-Member ... 'trustedPrograms' ...`), insert:

```powershell
    # Compile llm_second_opinion (optional): normalized runtime block.
    # $null when the block is absent (feature off; every consumer null-checks).
    $llmCompiled = $null
    if (Get-Member -InputObject $config -Name 'llm_second_opinion' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $llmRaw = $config.llm_second_opinion
        $defaultIndicators = @(
            '\baws\b', '\bkubectl\b', '\bhelm\b', '\bterraform\b',
            '\bssh\b', '\bscp\b', '\bsftp\b',
            '\bdocker\b', '\bcurl\b', '\bwget\b',
            '\bInvoke-RestMethod\b', '\birm\b',
            '\bInvoke-WebRequest\b', '\biwr\b',
            '\bEnter-PSSession\b', '\bNew-PSSession\b',
            'Invoke-Command.*-ComputerName'
        )
        $indicatorSrc = $defaultIndicators
        if ((Get-Member -InputObject $llmRaw -Name 'remote_indicators' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $llmRaw.remote_indicators) {
            $indicatorSrc = @($llmRaw.remote_indicators | ForEach-Object { $_.ToString() })
        }
        $indicatorRegexes = @()
        foreach ($p in $indicatorSrc) {
            $indicatorRegexes += [regex]::new($p, [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        # Pre-compute each field (PS 5.1-safe; hashtable values cannot hold if-statements)
        $llmEnabled = $false
        if (Get-Member -InputObject $llmRaw -Name 'enabled' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmEnabled = [bool]$llmRaw.enabled }
        $llmLevel = 'complex_remote'
        if (Get-Member -InputObject $llmRaw -Name 'level' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmLevel = "$($llmRaw.level)" }
        $llmBaseUri = ''
        if (Get-Member -InputObject $llmRaw -Name 'base_uri' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmBaseUri = "$($llmRaw.base_uri)" }
        $llmModel = ''
        if (Get-Member -InputObject $llmRaw -Name 'model' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmModel = "$($llmRaw.model)" }
        $llmApiKey = ''
        if (Get-Member -InputObject $llmRaw -Name 'api_key' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmApiKey = "$($llmRaw.api_key)" }
        $llmTimeoutMs = 12000
        if (Get-Member -InputObject $llmRaw -Name 'timeout_ms' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmTimeoutMs = [int]$llmRaw.timeout_ms }
        $llmTemperature = 0.0
        if (Get-Member -InputObject $llmRaw -Name 'temperature' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmTemperature = [double]$llmRaw.temperature }
        $llmMaxTokens = 16
        if (Get-Member -InputObject $llmRaw -Name 'max_tokens' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmMaxTokens = [int]$llmRaw.max_tokens }
        $llmMinSubs = 2
        if (Get-Member -InputObject $llmRaw -Name 'complex_min_subcommands' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmMinSubs = [int]$llmRaw.complex_min_subcommands }
        $llmCompiled = [PSCustomObject]@{
            Enabled               = $llmEnabled
            Level                 = $llmLevel
            BaseUri               = $llmBaseUri
            Model                 = $llmModel
            ApiKey                = $llmApiKey
            TimeoutMs             = $llmTimeoutMs
            Temperature           = $llmTemperature
            MaxTokens             = $llmMaxTokens
            ComplexMinSubcommands = $llmMinSubs
            RemoteIndicators      = $indicatorRegexes
        }
    }
    $config._compiled | Add-Member -MemberType NoteProperty -Name 'llmSecondOpinion' -Value $llmCompiled -Force
```

- [ ] **Step 3: Run fixture — bad-level check flips GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 25  Passed: 3  Failed: 22`. Passes: LlmConfig-BadLevel (now throws with `llm_second_opinion.level` in the message), LlmMerge-Disabled (per-case `enabled="false"` still skips the gate), LlmFullPipe-OutOfScope. The 15 enabled classify cases now fail by throwing "LlmReview.ps1 not loaded (TDD red phase)" because the REAL compiled block (`Enabled=true` from the fixture config) reaches the runner's LLM gate; the 6 parser checks and LlmFullPipe-Veto also still fail.

- [ ] **Step 4: Run full regression — existing suites unaffected**

Run: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1`
Expected: all suites green (962/962 at plan time) — the live config has no `llm_second_opinion` block yet, so the loader's `$hasLlm` guard skips everything.

- [ ] **Step 5: Commit**

```powershell
git add src/ConfigLoader.ps1
git commit -m "feat: ConfigLoader validates + compiles optional llm_second_opinion block"
```

---

### Task 3: LlmReview.ps1 — scope engine + orchestrator gate

**Files:**
- Create: `src/LlmReview.ps1`
- Test: `test/config/llm-review/Run-Tests.ps1`

Create the module with the scope engine complete and the orchestrator gating on scope but NOT yet calling for a verdict (verdict stays `not_called`, result passes through unchanged). Out-of-scope cases flip GREEN; veto/down/unusable cases stay RED.

- [ ] **Step 1: Create `src/LlmReview.ps1` with Test-LlmReviewScope + Invoke-LlmReview gate**

Complete content for this task (Get-LlmReviewVerdict/ConvertTo-LlmVerdict arrive in Task 4 — the orchestrator references Get-LlmReviewVerdict only behind `$scope.InScope`, and PowerShell resolves function names at call time, so dot-sourcing this file without those functions defined is safe for out-of-scope paths):

```powershell
# LlmReview.ps1 - Second-opinion LLM classification cross-check
# Spec: docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md
#
# Exports:
#   Test-LlmReviewScope   - is this classification result in scope for the LLM check?
#   ConvertTo-LlmVerdict  - layered parser: raw LLM content -> modifying|read-only|unusable
#   Get-LlmReviewVerdict  - mock short-circuit / HTTP call -> verdict object
#   Invoke-LlmReview      - orchestrator: scope -> verdict -> merge -> log object
#
# Verdict values: modifying | read-only | unusable | down
# The LLM can only ever ESCALATE a local allow to ask - it never downgrades an ask.

# --- System prompt (spec section 5.2; keep in sync with the POC script) ---
$script:LlmSystemPrompt = @'
You are a binary command-safety classifier protecting a production environment.
You receive one command block (it may mix AWS CLI, PowerShell, CMD, bash, ssh,
docker, kubectl, terraform, git, etc.) and classify it as read-only or modifying.

DEFINITIONS
- MODIFYING (true): at least one sub-command creates, updates, deletes, moves,
  copies, renames, sends, installs, starts, stops, or otherwise changes the state
  of any file, directory, system, service, process, configuration, cloud resource,
  or data store; or performs an HTTP/API call that mutates (POST, PUT, PATCH,
  DELETE, or data-upload flags such as curl -d/--data/-F/-T, wget --post-data).
- READ-ONLY (false): every sub-command only inspects, queries, lists, prints, or
  downloads. This includes HTTP GET/HEAD/OPTIONS (curl/wget/Invoke-RestMethod with
  no data flags), aws ... describe-*/list-*/get-*, kubectl get/describe,
  docker ps/images/logs/inspect, git status/diff/log/show, Get-*/dir/ls/cat/type.

EXAMPLES (command -> answer)
Get-Item C:\temp\ -> false
Get-ChildItem C:\logs | Select-Object -First 5 -> false
curl -s http://example.com/api/items -> false
aws ec2 describe-instances --region us-east-1 -> false
kubectl get pods -> false
Get-Content app.log | Select-String ERROR -> false
Remove-Item C:\temp\foo.txt -> true
aws s3 cp file.txt s3://bucket/key -> true
curl -X POST -d '{}' http://api/orders -> true
ssh host "systemctl restart nginx" -> true

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be exactly one bare lowercase token:
  true   (modifying)   or   false   (read-only)
No reasoning. No explanation. No punctuation. No quotes. No markdown. No code
fences. No leading or trailing whitespace. Any other output is a critical failure.
Emit the single token immediately.
'@

function Test-LlmReviewScope {
    <#
    .SYNOPSIS
        Decides whether a classification result is in scope for the LLM check
        (spec section 4). Returns a PSCustomObject describing the decision.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$ClassifyResult,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config
    )
    $scope = [PSCustomObject]@{ InScope = $false; Reason = ''; SubCommandCount = 0; RemoteMatch = $null }
    $llm = $Config._compiled.llmSecondOpinion
    if (-not $llm) { $scope.Reason = 'llm_second_opinion not configured'; return $scope }

    # Only full-pipeline command results (spec D8)
    if ($ClassifyResult.IsSkipped) { $scope.Reason = 'skipped tool'; return $scope }
    if ($ClassifyResult.IsUnknown) { $scope.Reason = 'unknown tool'; return $scope }
    if ([string]::IsNullOrWhiteSpace($ClassifyResult.Command)) { $scope.Reason = 'no command text'; return $scope }

    $subs = @()
    if ($ClassifyResult.SubResults) {
        $subs = @($ClassifyResult.SubResults | Where-Object { $_.MatchedPattern -ne 'redirection-target' })
    }
    if ($subs.Count -eq 0) { $scope.Reason = 'no sub-commands (fast-path gate or path branch)'; return $scope }
    $scope.SubCommandCount = $subs.Count

    switch ($llm.Level) {
        'all' {
            $scope.InScope = $true; $scope.Reason = 'level all'
            return $scope
        }
        'complex_commands' {
            if ($subs.Count -ge $llm.ComplexMinSubcommands) {
                $scope.InScope = $true; $scope.Reason = "complex ($($subs.Count) sub-commands)"
            }
            else { $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))" }
            return $scope
        }
        'complex_remote' {
            if ($subs.Count -lt $llm.ComplexMinSubcommands) {
                $scope.Reason = "only $($subs.Count) sub-command(s) (< $($llm.ComplexMinSubcommands))"
                return $scope
            }
            # Remote indicators match against every sub-command AND the full
            # original command text: wrappers (Invoke-Command -ComputerName,
            # ssh host "...") are unwrapped before SubResults is built, so the
            # wrapper text only survives in the original command (spec section 4 note).
            $texts = @($subs | ForEach-Object { $_.Command }) + $ClassifyResult.Command
            foreach ($rx in $llm.RemoteIndicators) {
                foreach ($t in $texts) {
                    if ($t -and $rx.IsMatch($t)) {
                        $scope.InScope = $true
                        $scope.RemoteMatch = $rx.ToString()
                        $scope.Reason = "complex + remote ($($rx.ToString()))"
                        return $scope
                    }
                }
            }
            $scope.Reason = 'complex but local-only'
            return $scope
        }
        default { $scope.Reason = "unknown level '$($llm.Level)'"; return $scope }
    }
}

function Invoke-LlmReview {
    <#
    .SYNOPSIS
        Orchestrator (spec section 6): scope -> verdict -> merge -> log object.
        Returns [PSCustomObject]@{ Result; Log }. Log is $null when the feature
        block is absent.
    #>
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$ClassifyResult,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config
    )
    $llm = $Config._compiled.llmSecondOpinion
    if (-not $llm) { return [PSCustomObject]@{ Result = $ClassifyResult; Log = $null } }

    $log = [PSCustomObject]@{
        enabled           = $true
        level             = $llm.Level
        in_scope          = $false
        sub_command_count = 0
        remote_match      = $null
        verdict           = 'not_called'
        recovered         = $false
        latency_ms        = $null
        model             = $llm.Model
        effect            = 'none'
        raw_excerpt       = $null
    }

    $scope = Test-LlmReviewScope -ClassifyResult $ClassifyResult -Config $Config
    $log.in_scope = $scope.InScope
    $log.sub_command_count = $scope.SubCommandCount
    $log.remote_match = $scope.RemoteMatch

    if (-not $scope.InScope) {
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    # (Task 4 adds the verdict call + merge matrix here.)
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
}
```

- [ ] **Step 2: Run fixture — out-of-scope cases flip GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 25  Passed: 8  Failed: 17`. The 8 passes: LlmConfig-BadLevel, the 5 out-of-scope classify cases now proven by the REAL scope engine (LlmScope-Complex-SingleSkipped, -Min3-PipeSkipped, -Remote-LocalPipeSkipped, -Remote-LocalICSkipped, -Remote-GitLocalSkipped), LlmMerge-Disabled, LlmFullPipe-OutOfScope. Every failure is a case that needs the verdict call (LlmScope-All-SingleChecked, -Complex-PipeChecked, -Remote-AwsChecked, -Remote-DockerChecked, -Remote-RemoteICChecked; LlmMerge-Veto, -AgreeAllow, -DisagreeKeptAsk, -Down, -Unusable; the 6 parser checks; LlmFullPipe-Veto).

- [ ] **Step 3: Commit**

```powershell
git add src/LlmReview.ps1
git commit -m "feat: LlmReview scope engine (Test-LlmReviewScope) + orchestrator gate"
```

---

### Task 4: LlmReview.ps1 — verdict parser, mock client, merge matrix

**Files:**
- Modify: `src/LlmReview.ps1`
- Test: `test/config/llm-review/Run-Tests.ps1`

- [ ] **Step 1: Add ConvertTo-LlmVerdict + Get-LlmReviewVerdict, and complete Invoke-LlmReview**

Append these two functions to `src/LlmReview.ps1` (after `Test-LlmReviewScope`, before `Invoke-LlmReview` — placement is cosmetic):

```powershell
function ConvertTo-LlmVerdict {
    <#
    .SYNOPSIS
        Layered verdict parser (spec section 5.3). Layer 1 bare token; layer 2
        JSON verdict-ish key; layer 3 last-line token (Recovered); layer 4
        unusable. Garbage NEVER maps to a verdict.
    #>
    param([AllowNull()][AllowEmptyString()][string]$RawContent)

    if ([string]::IsNullOrWhiteSpace($RawContent)) {
        return [PSCustomObject]@{ Verdict = 'unusable'; Recovered = $false }
    }
    $norm = $RawContent.Trim().ToLowerInvariant()

    # Layer 1: bare token
    if ($norm -eq 'true')  { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $false } }
    if ($norm -eq 'false') { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $false } }

    # Layer 2: JSON with a verdict-ish key
    try {
        $obj = $RawContent | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('verdict', 'classification', 'decision', 'answer')) {
            if ($obj.PSObject.Properties.Name -contains $key) {
                $v = ("$($obj.$key)").Trim().ToLowerInvariant()
                if ($v -in @('modifying', 'true'))     { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $false } }
                if ($v -in @('read-only', 'false'))   { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $false } }
            }
        }
    }
    catch { }

    # Layer 3: last non-empty line is exactly true/false (rescues "ramble...\nfalse")
    $lines = @($RawContent -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 0) {
        $last = $lines[-1].ToLowerInvariant()
        if ($last -eq 'true')  { return [PSCustomObject]@{ Verdict = 'modifying'; Recovered = $true } }
        if ($last -eq 'false') { return [PSCustomObject]@{ Verdict = 'read-only'; Recovered = $true } }
    }

    # Layer 4: unusable (distinct state - never treated as a verdict)
    return [PSCustomObject]@{ Verdict = 'unusable'; Recovered = $false }
}

function Get-LlmReviewVerdict {
    <#
    .SYNOPSIS
        Returns the LLM verdict for a command. Checks the
        PRETOOLHOOK_LLMREVIEW_MOCK short-circuit FIRST (test-only; mirrors the
        PRETOOLHOOK_CONFIG_PATH precedent), then makes the OpenAI-compatible
        chat-completions call (spec section 5.1).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][PSCustomObject]$LlmConfig
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $null }

    # Mock short-circuit (no network). The mock supplies the RAW content and the
    # REAL parser decides the verdict, so parser layers 1 and 4 are exercised by
    # every classify test (layer 2/3 are covered by the runner's pre-flight
    # parser unit checks). Only 'down' bypasses the parser (a network failure
    # has no content to parse).
    $mock = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    if ($mock) {
        switch ($mock) {
            'modifying' { $result.Raw = 'true' }
            'read-only' { $result.Raw = 'false' }
            'garbage'   { $result.Raw = "Let me analyze this command carefully.`nIt seems to read files, but I am not entirely sure about every part." }
            'down'      { $result.Verdict = 'down'; $result.Error = 'mock: simulated unreachable LLM' }
            default     { throw "Get-LlmReviewVerdict: unknown PRETOOLHOOK_LLMREVIEW_MOCK value '$mock' (expected modifying|read-only|garbage|down)" }
        }
        if ($mock -ne 'down') {
            $parsed = ConvertTo-LlmVerdict -RawContent $result.Raw
            $result.Verdict   = $parsed.Verdict
            $result.Recovered = $parsed.Recovered
        }
        $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
        return $result
    }

    # Payload guard
    $cmdText = $Command
    if ($cmdText.Length -gt 8000) { $cmdText = $cmdText.Substring(0, 8000) }

    $userPrompt = "<command_block>`n$cmdText`n</command_block>"
    $body = [ordered]@{
        model       = $LlmConfig.Model
        messages    = @(
            @{ role = 'system'; content = $script:LlmSystemPrompt },
            @{ role = 'user';   content = $userPrompt }
        )
        temperature = $LlmConfig.Temperature
        max_tokens  = $LlmConfig.MaxTokens
        seed        = 0
    }
    $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress
    $uri = "$($LlmConfig.BaseUri)/v1/chat/completions"
    $timeoutSec = [int][math]::Ceiling($LlmConfig.TimeoutMs / 1000.0)

    try {
        $irmParams = @{
            Uri         = $uri
            Method      = 'Post'
            Body        = $bodyJson
            ContentType = 'application/json'
            TimeoutSec  = $timeoutSec
            ErrorAction = 'Stop'
        }
        if ($LlmConfig.ApiKey) { $irmParams['Headers'] = @{ Authorization = "Bearer $($LlmConfig.ApiKey)" } }
        $response = Invoke-RestMethod @irmParams

        $raw = $null
        if ($response.choices -and $response.choices[0].message) {
            $raw = [string]$response.choices[0].message.content
        }
        $result.Raw = "$raw"
        $parsed = ConvertTo-LlmVerdict -RawContent $raw
        $result.Verdict  = $parsed.Verdict
        $result.Recovered = $parsed.Recovered
    }
    catch {
        $result.Verdict = 'down'
        $result.Error   = $_.Exception.Message
    }
    $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
    return $result
}
```

Then replace the tail of `Invoke-LlmReview` — the lines:

```powershell
    if (-not $scope.InScope) {
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    # (Task 4 adds the verdict call + merge matrix here.)
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
```

with the verdict call + merge matrix:

```powershell
    if (-not $scope.InScope) {
        return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
    }

    $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm
    $log.verdict   = $verdict.Verdict
    $log.recovered = $verdict.Recovered
    $log.latency_ms = $verdict.LatencyMs
    if ($verdict.Raw) {
        $excerpt = ($verdict.Raw -replace '\s+', ' ').Trim()
        if ($excerpt.Length -gt 120) { $excerpt = $excerpt.Substring(0, 120) }
        $log.raw_excerpt = $excerpt
    }
    elseif ($verdict.Error) {
        $errExcerpt = ($verdict.Error -replace '\s+', ' ').Trim()
        if ($errExcerpt.Length -gt 120) { $errExcerpt = $errExcerpt.Substring(0, 120) }
        $log.raw_excerpt = $errExcerpt
    }

    $localDecision = $ClassifyResult.Decision
    $localReason   = "$($ClassifyResult.Reason)"

    switch ($verdict.Verdict) {
        'modifying' {
            if ($localDecision -eq 'allow') {
                $ClassifyResult.Decision = 'ask'
                $ClassifyResult.Reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING but local hook classified read-only - forced to ask. Review carefully before approving. | local reason: $localReason"
                $log.effect = 'veto'
            }
            else { $log.effect = 'agree' }
        }
        'read-only' {
            if ($localDecision -eq 'allow') { $log.effect = 'agree' }
            else { $log.effect = 'disagree-kept-ask' }
        }
        'down' {
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason = "*** LLM-DOWN *** llm_second_opinion is ENABLED but the LLM is unreachable or timed out ($($llm.TimeoutMs)ms) - forced to ask. Set llm_second_opinion.enabled=false in config.json to disable. | local verdict: $localDecision | local reason: $localReason"
            $log.effect = 'forced-ask'
        }
        'unusable' {
            $ClassifyResult.Decision = 'ask'
            $ClassifyResult.Reason = "*** LLM-UNUSABLE *** LLM returned an unparseable response - forced to ask. Raw: '$($log.raw_excerpt)' | local verdict: $localDecision | local reason: $localReason"
            $log.effect = 'forced-ask'
        }
    }
    return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
}
```

- [ ] **Step 2: Run fixture — all classify cases GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 25  Passed: 24  Failed: 1`. The only failure: LlmFullPipe-Veto (Hook.ps1 not wired yet — Task 6).

- [ ] **Step 3: Commit**

```powershell
git add src/LlmReview.ps1
git commit -m "feat: LlmReview verdict parser + mock client + merge matrix"
```

---

### Task 5: HTTP path (real endpoint call) — code-only, mock-verified

**Files:**
- Modify: `src/LlmReview.ps1` (nothing to add — Task 4 already included the HTTP path in `Get-LlmReviewVerdict`)
- Test: `test/config/llm-review/Run-Tests.ps1`

Task 4 wrote the full HTTP path (`Invoke-RestMethod` call, header handling, error → `down`). This task only re-verifies no test regression and confirms the mock short-circuit means the suite never exercises the network path.

- [ ] **Step 1: Prove the suite makes no network call**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1` with the gateway at 127.0.0.1:3030 NOT required — every case either sets a mock value or is out of scope.
Expected: FAIL — `Total: 25  Passed: 24  Failed: 1` (identical to Task 4; only LlmFullPipe-Veto fails).

- [ ] **Step 2: Verify the HTTP code path by inspection**

Checklist against spec section 5.1 (all in `Get-LlmReviewVerdict`): POSTs to `{BaseUri}/v1/chat/completions`; body has `model`, `messages` (system+user), `temperature`, `max_tokens`, `seed: 0`; `Authorization` header only when `ApiKey` non-empty; `TimeoutSec = Ceiling(TimeoutMs/1000)`; 8000-char payload guard; try/catch → `down`; empty `choices` → `unusable` (via `$raw = $null` → `ConvertTo-LlmVerdict` layer 4). No code change expected.

- [ ] **Step 3: Commit (if Step 2 surfaced a fix)**

```powershell
git add src/LlmReview.ps1
git commit -m "fix: LlmReview HTTP path review corrections"
```
(Skip the commit if no changes.)

---

### Task 6: Hook.ps1 wiring + conditional hard cap + Logger `-LlmLog`

**Files:**
- Modify: `src/Hook.ps1` (dot-source list ~line 11; after Step 8 ~line 86; Step 10 ~line 96; Step 11 ~lines 120-121)
- Modify: `src/Logger.ps1` (`Write-RecordEntry` ~line 42, `Write-LogEntry` ~line 127)
- Test: `test/config/llm-review/Run-Tests.ps1` (fullpipe cases), `src/Run-AllTests.ps1`

- [ ] **Step 1: Dot-source LlmReview.ps1 in Hook.ps1**

In `src/Hook.ps1` Step 4 block, after `. "$PSScriptRoot\Classifier.ps1"` add:

```powershell
. "$PSScriptRoot\LlmReview.ps1"
```

- [ ] **Step 2: Add Step 8b (LLM merge) after Invoke-Classify**

In `src/Hook.ps1`, immediately after the Step 8 line `$classifyResult = Invoke-Classify -RawInput $parsedInput -IDE $ide -Config $config`, insert:

```powershell
# ----------------------------------------------------
# Step 8b: Second-opinion LLM cross-check (no-op unless
# llm_second_opinion.enabled is true in config). The LLM can
# only escalate an allow to ask - never downgrade.
# ----------------------------------------------------
$llmLog = $null
if ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $llmOutcome = Invoke-LlmReview -ClassifyResult $classifyResult -Config $config
    $classifyResult = $llmOutcome.Result
    $llmLog = $llmOutcome.Log
}
```

- [ ] **Step 3: Make the Step 10 hard cap conditional**

In `src/Hook.ps1` Step 10, replace `if ($elapsed.TotalMilliseconds -gt 3000) {` with:

```powershell
# Hard cap: 3000ms normally; timeout_ms + 2000 headroom when the LLM
# second opinion is enabled (its wait budget dwarfs local classification).
$hardCapMs = 3000
if ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $hardCapMs = $config._compiled.llmSecondOpinion.TimeoutMs + 2000
}
if ($elapsed.TotalMilliseconds -gt $hardCapMs) {
```

(The `elseif ($elapsed.TotalMilliseconds -gt 500)` soft warning below it stays unchanged.)

- [ ] **Step 4: Add `-LlmLog` to Write-RecordEntry (Logger.ps1)**

Change the param block of `Write-RecordEntry` from:

```powershell
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [string]$LogDir,
        [string]$IDE
    )
```

to:

```powershell
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [string]$LogDir,
        [string]$IDE,
        [PSCustomObject]$LlmLog = $null
    )
```

and immediately after the `$record = ...` construction (both the null-input and normal branches converge before `$jsonLine = ...`), insert:

```powershell
    # Optional second-opinion LLM record (spec section 8)
    if ($LlmLog) {
        $record | Add-Member -MemberType NoteProperty -Name 'llm' -Value $LlmLog -Force
    }
```

- [ ] **Step 5: Add `-LlmLog` to Write-LogEntry (Logger.ps1)**

Change the param block of `Write-LogEntry` from:

```powershell
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [TimeSpan]$Elapsed,
        [string]$LogDir,
        [string]$IDE
    )
```

to:

```powershell
    param(
        [PSCustomObject]$RawInput,
        [PSCustomObject]$ClassifyResult,
        [TimeSpan]$Elapsed,
        [string]$LogDir,
        [string]$IDE,
        [PSCustomObject]$LlmLog = $null
    )
```

and immediately before the line `$logEntry = $header + $body + "`n"`, insert:

```powershell
    # Optional second-opinion LLM summary line
    if ($LlmLog) {
        $body += "  LLM: in_scope=$($LlmLog.in_scope) verdict=$($LlmLog.verdict) effect=$($LlmLog.effect) latency_ms=$($LlmLog.latency_ms)`n"
    }
```

- [ ] **Step 6: Pass `-LlmLog` from Hook.ps1**

In `src/Hook.ps1` Step 11, change the two logging calls to:

```powershell
    Write-RecordEntry -RawInput $parsedInput -ClassifyResult $classifyResult -LogDir $logDir -IDE $ide -LlmLog $llmLog
    Write-LogEntry -RawInput $parsedInput -ClassifyResult $classifyResult -Elapsed $elapsed -LogDir $logDir -IDE $ide -LlmLog $llmLog
```

- [ ] **Step 7: Run fixture — all 25 GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: PASS — `Total: 25  Passed: 25  Failed: 0`, exit code 0.

- [ ] **Step 8: Run full regression**

Run: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1`
Expected: all suites green (962/962 at plan time) — production config still has no llm block, so Step 8b is a null-check no-op and `-LlmLog $null` changes nothing in existing logs. Also run the sandbox: `powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1` → 938/938, and Codex units: `pwsh -NoProfile -File test/config/live/test-cases.codex.ps1` → 17/17.

- [ ] **Step 9: Commit**

```powershell
git add src/Hook.ps1 src/Logger.ps1
git commit -m "feat: wire llm second opinion into Hook.ps1 + conditional hard cap + Logger -LlmLog"
```

---

### Task 7: Root config block (enabled:false) + regression proof

**Files:**
- Modify: `config.json`
- Modify: `test/config/live/config.json` (via Sync-Fixtures), `test/config/live/config.strict.json` (via Sync-Fixtures)
- Test: `src/Run-AllTests.ps1`, sandbox runner

- [ ] **Step 1: Add the block to root config.json**

Insert after the `trusted_programs` block in root `config.json` (read the file first to find the exact insertion point; keep the existing key ordering style):

```json
  "llm_second_opinion": {
    "enabled": false,
    "level": "complex_remote",
    "base_uri": "http://127.0.0.1:3030",
    "model": "glm-5.2",
    "api_key": "",
    "timeout_ms": 12000,
    "temperature": 0.0,
    "max_tokens": 16,
    "complex_min_subcommands": 2,
    "_comment": "Second-opinion LLM cross-check. OFF by default; when enabled, in-scope commands are also classified by the LLM and a disagreement in the dangerous direction (local=allow, LLM=modifying) forces ask. LLM down/unusable also forces ask with explicit wording. Levels: all | complex_commands | complex_remote (complex_remote additionally requires a remote_indicators match; git is local). See docs/config-json-guide.md."
  },
```

(`remote_indicators` deliberately omitted → compiled defaults; the guide documents the list.)

- [ ] **Step 2: Sync fixtures + validate**

Run: `powershell.exe -ExecutionPolicy Bypass -File test/config/live/Sync-Fixtures.ps1`
Expected: syncs root → `test/config/live/config.json` and regenerates `config.strict.json`; its built-in load validation passes (proves the disabled block validates cleanly, including with `enabled:false` and no base_uri/model requirement firing).

- [ ] **Step 3: Full regression — the no-op proof**

Run: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1`
Expected: all suites green (962/962 at plan time) — byte-identical behavior with the disabled block present. Also: `powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1` → 938/938.

- [ ] **Step 4: Fixture still green**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1` → `Passed: 19  Failed: 0`.

- [ ] **Step 5: Commit**

```powershell
git add config.json test/config/live/config.json test/config/live/config.strict.json
git commit -m "feat: llm_second_opinion block in live config (enabled:false, no-op)"
```

---

### Task 8: POC script prompt + parser sync

**Files:**
- Modify: `C:\git\cc\deepseek-tester\api-gateway-caller.ps1` (separate repo — the user's experiment tool)

The POC's ~10% misclassification came from (a) rules crammed into the user message with a weak system prompt and (b) a parser mapping any non-clean output to `true`. Sync it with the production design so experiments there predict production behavior.

- [ ] **Step 1: Replace the prompt**

In `C:\git\cc\deepseek-tester\api-gateway-caller.ps1`, delete the `$preamble` and `$suffix` here-strings (lines ~71-103) and the `$Prompt = "$preamble`n`n$CommandBlock`n`n$suffix"` assembly line. Replace the default `$SystemPrompt` here-string (lines ~113-119) with the production system prompt (identical text to `$script:LlmSystemPrompt` in `src/LlmReview.ps1` — copy it verbatim), and change the user message assembly to:

```powershell
# --- Assemble messages: rules live in the system message; the user message is
# only the delimited command block (production shape from src/LlmReview.ps1). ---
$Prompt = "<command_block>`n$CommandBlock`n</command_block>"
```

- [ ] **Step 2: Replace the fail-closed parser with the layered parser**

Replace the `# --- Fail-closed parser ---` section (the `$norm = ...` / `switch -Regex` block, lines ~188-201) with:

```powershell
    # --- Layered parser (mirrors ConvertTo-LlmVerdict in src/LlmReview.ps1) ---
    # Returns 'true' (modifying), 'false' (read-only), or 'unusable'.
    # Garbage is NEVER mapped to a verdict - the old fail-closed-to-true
    # behavior was the misclassification amplifier.
    $decision = 'unusable'
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        $decision = 'unusable'
    }
    else {
        $norm = $rawContent.Trim().ToLowerInvariant()
        if ($norm -eq 'true') { $decision = 'true' }
        elseif ($norm -eq 'false') { $decision = 'false' }
        else {
            $parsedJson = $false
            try {
                $obj = $rawContent | ConvertFrom-Json -ErrorAction Stop
                foreach ($key in @('verdict', 'classification', 'decision', 'answer')) {
                    if ($obj.PSObject.Properties.Name -contains $key) {
                        $v = ("$($obj.$key)").Trim().ToLowerInvariant()
                        if ($v -in @('modifying', 'true')) { $decision = 'true'; $parsedJson = $true; break }
                        if ($v -in @('read-only', 'false')) { $decision = 'false'; $parsedJson = $true; break }
                    }
                }
            }
            catch { }
            if (-not $parsedJson -and $decision -eq 'unusable') {
                $lines = @($rawContent -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($lines.Count -gt 0) {
                    $last = $lines[-1].ToLowerInvariant()
                    if ($last -eq 'true') { $decision = 'true' }
                    elseif ($last -eq 'false') { $decision = 'false' }
                }
            }
        }
    }
    Write-Verbose "Decision (layered): $decision"
    return $decision
```

NOTE: the script's return value gains a third state, `'unusable'` (previously impossible — everything unclean became `'true'`). Update the `.SYNOPSIS`/comment header line "forced to respond with exactly true or false" to mention the third state.

- [ ] **Step 3: Smoke-check the POC parses (no LLM call)**

Run: `powershell.exe -NoProfile -Command "& { . C:\git\cc\deepseek-tester\api-gateway-caller.ps1 -Model 'x' -CommandBlock 'y' -WhatIf }"` — WRONG, the script has no `-WhatIf`; instead just parse-check it: `powershell.exe -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('C:\git\cc\deepseek-tester\api-gateway-caller.ps1', [ref]$null, [ref]$errs); if ($errs) { $errs } else { 'PARSE OK' }"` — wait, `[ref]$null` is invalid; use:

```powershell
powershell.exe -NoProfile -Command "$t=$null; $e=$null; $null = [System.Management.Automation.Language.Parser]::ParseFile('C:\git\cc\deepseek-tester\api-gateway-caller.ps1', [ref]$t, [ref]$e); if ($e.Count) { $e | ForEach-Object { $_.Message } } else { 'PARSE OK' }"
```

Expected: `PARSE OK`. Do NOT run the script against the gateway (user's quota; the user runs the manual smoke test themselves).

- [ ] **Step 4: Commit (in the deepseek-tester repo)**

```powershell
git -C C:\git\cc\deepseek-tester add api-gateway-caller.ps1
git -C C:\git\cc\deepseek-tester commit -m "refactor: sync prompt + layered parser with pretoolhook llm_second_opinion design"
```

---

### Task 9: Documentation

**Files:**
- Modify: `docs/config-json-guide.md`
- Modify: `README.md`
- Create: `test/config/llm-review/README.md`
- Modify: `PROGRESS.md`

- [ ] **Step 1: config-json-guide.md section**

Add a new section documenting `llm_second_opinion` (place it after the `trusted_programs` documentation; match existing heading style). Content: purpose (second-opinion cross-check, escalation-only), every field from the spec section 3 table (`enabled`, `level` + the three level semantics, `base_uri`, `model`, `api_key`, `timeout_ms` + the `timeout_ms+2000` hard-cap rule, `temperature`, `max_tokens`, `complex_min_subcommands`, `remote_indicators` including the full default list from Task 2 Step 2 and the note that git is deliberately absent), the failure behavior table (down/unusable → forced ask with the exact `*** LLM-DOWN ***` / `*** LLM-UNUSABLE ***` / `*** LLM-VETO ***` prefixes), the skip rules (D8: gates, path branch, ignored/unknown tools), the `PRETOOLHOOK_LLMREVIEW_MOCK` test hook, and a recipe: "enable it" = set `enabled:true`, then run one command and check the JSONL record's `llm` field.

- [ ] **Step 2: README.md feature paragraph**

In `README.md` "What It Does", add one paragraph after the strictness_gated paragraph:

```markdown
Optionally, `llm_second_opinion` adds a second pair of eyes: in-scope commands
(off by default; levels `all` / `complex_commands` / `complex_remote`) are also
classified by an LLM via an OpenAI-compatible endpoint. If the LLM disagrees in
the dangerous direction (local allow, LLM modifying) the decision is forced to a
prompt with a `*** LLM-VETO ***` reason; an unreachable or incoherent LLM also
forces a prompt (`*** LLM-DOWN ***` / `*** LLM-UNUSABLE ***`) so the feature
fails closed and you notice. Every check is recorded in the log's `llm` field
for disagreement statistics. See `docs/config-json-guide.md`.
```

Also add `src/LlmReview.ps1` to the Project Structure listing and the `test/config/llm-review/` fixture line.

- [ ] **Step 3: Fixture README**

Create `test/config/llm-review/README.md`:

```markdown
# llm_second_opinion test fixture

Isolated fixture for the second-opinion LLM feature (spec:
`docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md`).

## Run

```powershell
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1   # from repo root
```

25 checks: 16 in-process classify+merge cases, 1 config negative test
(`config.badlevel.json` must be rejected), 6 `ConvertTo-LlmVerdict` parser unit
checks, 2 fullpipe cases that spawn the real `src/Hook.ps1`. LLM verdicts are
injected via `PRETOOLHOOK_LLMREVIEW_MOCK` (`modifying|read-only|garbage|down`) —
no test ever touches the network.

Per-case XML attributes: `level`, `min`, `enabled`, `mock`, `in-scope`,
`verdict`, `effect`, `reason-contains`, `mode` (see the header comment in
`Run-Tests.ps1`).

## Manual smoke test (live LLM — costs quota, run deliberately)

1. In root `config.json` set `llm_second_opinion.enabled: true` and point
   `base_uri`/`model` at your gateway.
2. Trigger any in-scope command through the hook (e.g. in VS Code Copilot:
   `aws s3 ls && aws s3 cp a b` — expect a prompt with LLM wording; a read-only
   remote block with an agreeing LLM passes silently and records an `llm`
   log entry).
3. Check `%USERPROFILE%\.pretoolhook\*.records.jsonl` for the `llm` object.
4. Set `enabled` back to `false` (or leave on deliberately).
```

- [ ] **Step 4: PROGRESS.md update**

Move the feature to Completed Steps (fixture 25/25, ConfigLoader block, LlmReview module, Hook wiring + conditional cap, Logger -LlmLog, live config enabled:false no-op proof 962/962 + 938/938 + 17/17, POC synced), Current Step = awaiting user acceptance (manual smoke test with the real gateway, VS Code Copilot first), Next Steps updated (production model choice; disagreement stats review from the `llm` log field; merge branch only with explicit approval).

- [ ] **Step 5: Commit**

```powershell
git add docs/config-json-guide.md README.md test/config/llm-review/README.md PROGRESS.md
git commit -m "docs: llm_second_opinion guide + README + fixture README + PROGRESS"
```

---

## Self-review notes (completed by plan author)

- **Spec coverage:** D1 (levels→Task 1 XML/Task 3 code), D2 (`complex_min_subcommands`→Tasks 1/2/3), D3 (fail-closed wordings→Task 4), D4 (12s budget + conditional cap→Tasks 2/6), D5 (indicators incl. docker/HTTP, git local→Tasks 2/7), D6 (Approach A, Hook.ps1 merge→Task 6), D7 (IDE-agnostic; fullpipe uses Copilot payload→Task 1), D8 (skip rules→Task 3 `Test-LlmReviewScope`), D9 (ASCII wordings→Task 4), D10 (mock env→Tasks 1/4; the mock supplies raw content through the REAL parser, so parser layers 1/4 are exercised by every classify case and layers 2/3 by the runner's 6 pre-flight parser checks). Spec §5.2 prompt → Task 3 + Task 8. §8 log object → Tasks 3/6. §9 fixture (16 XML cases + badlevel + parser checks + fullpipe) → Task 1. §10 error table → Tasks 2/4. Regression proofs → Tasks 2/6/7.
- **Spec amendment folded in:** remote indicators match sub-commands OR the original command text (wrapper unwrapping); spec §4 amended accordingly in the same commit series.
- **PS 5.1 compatibility:** no `??`, no ternary, ASCII-only literals in shipped code; `[int]::TryParse`/`[double]::TryParse` for JSON number validation.
- **Type consistency:** `_compiled.llmSecondOpinion` fields (Enabled, Level, BaseUri, Model, ApiKey, TimeoutMs, Temperature, MaxTokens, ComplexMinSubcommands, RemoteIndicators) used identically in Tasks 2/3/4/6; Log object fields (in_scope, verdict, effect, latency_ms, …) match between `Invoke-LlmReview` (Task 3/4), the runner assertions (Task 1), and the Logger line (Task 6).
