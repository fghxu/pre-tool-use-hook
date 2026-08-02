# LLM Second Opinion — Phase II Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attributed LLM verdicts (indices) + policy suppression of gated-tier flags + reconciliation-grade logging, per spec `docs/superpowers/specs/2026-08-02-llm-second-opinion-phase2-design.md` (read it first — P1–P9 are locked).

**Architecture:** The LLM receives the raw command block plus a numbered list of the engine's own `SubResults` and returns `{"modifying":[indices]}`. The local merge maps each index to its sub-result's `Tier` (new annotation) and suppresses flags on `strictness_gated` entries; everything else (read_only/unknown/index 0/unattributed) vetoes as in phase I. A shared `Format-LlmLogBlock` (Logger.ps1) renders the reconciliation block in production `.log` and in per-run test logs.

**Tech Stack:** PowerShell 5.1-compatible (no `??`, no ternary, ASCII-only literals in shipped code), same XML+runner fixture style as phase I.

**Test commands:**
- Phase-II default (small file): `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
- Phase-II large (opt-in): `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.p2.large.xml`
- Phase-I file (regression): `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.xml`
- HTTP mock suite: `pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1`
- Full regression: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1`

**File structure:**

| File | Responsibility |
|---|---|
| `src/LlmReview.ps1` | Prompt V1+V2, parser v2 (`-SubCommandCount`, `Indices`), verdict fn (`-SubCommands`, idx mocks, `Mocked`), scope (`SubCommands`), merge v2, guard hook |
| `src/Resolver.ps1` | `Tier` annotation on sub-results (gated/read_only/modifying branches) |
| `src/ConfigLoader.ps1` | `attributed_verdicts` validation + `AttributedVerdicts` compiled field |
| `src/Logger.ps1` | `Format-LlmLogBlock` shared formatter; `Write-LogEntry` uses it |
| `src/Hook.ps1` | NO CHANGE (log object fields ride through automatically) |
| `config.json` | `attributed_verdicts: true` in the llm block |
| `test/config/llm-review/` | Runner `-XmlPath` + new attrs + per-run log; fixture gated tiers; `test-cases.p2.small.xml` (default, 10 cases); `test-cases.p2.large.xml` (opt-in, 50 cases); `config.badtype.json` |
| `test/config/llm-review/http/` | Runner: `attributed`/`subcommands` attrs + 2 check tokens; 2 shape cases; live runner: `expect-indices` + 2 live cases |
| `C:\git\cc\deepseek-tester\api-gateway-caller.ps1` | v2 prompt parity + optional `-SubCommands` |

**Task index:** T1 fixture groundwork (RED) → T2 ConfigLoader → T3 parser+verdict v2 → T4 Tier+merge v2 → T5 Logger+large file → T6 live cases → T7 config+POC+docs+regression.

<!-- APPEND-NEXT-TASK -->

---

### Task 1: Fixture groundwork + RED baseline

**Files:**
- Modify: `test/config/llm-review/config.json`
- Create: `test/config/llm-review/config.badtype.json`
- Modify: `test/config/llm-review/Run-Tests.ps1`
- Create: `test/config/llm-review/test-cases.p2.small.xml`

All test harness changes BEFORE any implementation (TDD). The phase-I case file stays untouched at `test-cases.xml`; the runner's default becomes the new small file.

- [ ] **Step 1: Extend the fixture config**

In `test/config/llm-review/config.json`:

(a) Inside the `"llm_second_opinion"` block, after `"complex_min_subcommands": 2,` add:

```json
    "attributed_verdicts": true,
```

(b) In the `"Git"` domain, after the `"modifying"` array, add a gated tier (used by suppression cases):

```json
      ,
      "strictness_gated": [
        { "name": "git add",    "patterns": ["git add *"],    "description": "Stage changes (gated)" },
        { "name": "git commit", "patterns": ["git commit *"], "description": "Commit (gated)" }
      ]
```

(c) In the `"PowerShell"` domain, after `"modifying": []` add:

```json
      ,
      "strictness_gated": [
        { "name": "Set-Content", "patterns": ["Set-Content *"], "description": "Write file (gated; known path gap, spec P4)" }
      ]
```

NOTE: the fixture's `global_modifying_strictness` is currently `"strict"` (user edit — keep it). Suppression cases need gated=allow, so the runner gains a per-case `strictness` attribute (below); suppression cases set `strictness="normal"`.

- [ ] **Step 2: Create `config.badtype.json`**

```powershell
Copy-Item test/config/llm-review/config.json test/config/llm-review/config.badtype.json
```

Then edit `test/config/llm-review/config.badtype.json`: change `"attributed_verdicts": true,` to `"attributed_verdicts": "yes",`. (Used by a new pre-flight check: `Load-Config` must throw with `llm_second_opinion.attributed_verdicts` in the message — drives Task 2.)

- [ ] **Step 3: Runner — `-XmlPath` param + strictness baseline**

At the top of `test/config/llm-review/Run-Tests.ps1`, immediately BEFORE `$ErrorActionPreference = "Stop"` (param must be the first statement after comments), insert:

```powershell
param(
    # Default = the phase-II small file (fast typical pass). Point at
    # test-cases.xml (phase-I) or test-cases.p2.large.xml (opt-in matrix).
    [string]$XmlPath = "$PSScriptRoot\test-cases.p2.small.xml"
)
```

Replace the XML load line `[xml]$xml = Get-Content (Join-Path $fixtureDir "test-cases.xml") -Encoding UTF8` with:

```powershell
[xml]$xml = Get-Content $XmlPath -Encoding UTF8
```

Immediately after `$config = Load-Config -Path $configPath` add (per-case strictness needs a baseline to restore to):

```powershell
# Baseline global strictness from the fixture file; each case may override it
# via its strictness= attribute and is reset to this afterwards.
$fileStrictness = $config.global_modifying_strictness
```

- [ ] **Step 4: Runner — per-run reconciliation log (spec P9)**

Immediately after the `$fileStrictness` line, add:

```powershell
# Per-run reconciliation log (spec P9): every case appends its outcome plus
# the shared LLM reconciliation block here, so a run leaves the same evidence
# a production call would. Lives beside the fullpipe hook logs (c:\temp).
$runLogDir = if ($config.log_file_path) { $config.log_file_path } else { 'c:\temp\pretoolhook-llm-review-testlogs\' }
if (-not (Test-Path $runLogDir)) { New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null }
$runLogPath = Join-Path $runLogDir ('llm-review-run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
```

Add this helper function right after the `Record-Result` function:

```powershell
# Write-CaseLog - append one case's reconciliation evidence to the run log.
# Uses the shared Format-LlmLogBlock when available (Task 5); until then a
# one-line fallback keeps the run log useful during TDD red phases.
function Write-CaseLog {
    param([string]$Name, [bool]$Ok, $Result, $LlmLog, [string]$Mode)
    $verdictText = if ($Ok) { 'PASS' } else { 'FAIL' }
    $block = "=== [$Name] $verdictText ($Mode) ===`n"
    if ($Mode -eq 'fullpipe') {
        $block += "  (spawned hook; see the hook .log in $runLogDir for LLM-SENT/RECV/RECONCILE)`n"
    }
    elseif ($null -eq $LlmLog) {
        $block += "  (no LLM call - feature disabled or out of scope)`n"
    }
    elseif (Get-Command Format-LlmLogBlock -ErrorAction SilentlyContinue) {
        $block += (Format-LlmLogBlock -Result $Result -LlmLog $LlmLog)
    }
    else {
        $block += "  decision=$($Result.Decision) reason=$($Result.Reason) verdict=$($LlmLog.verdict) effect=$($LlmLog.effect)`n"
    }
    Add-Content -Path $runLogPath -Value $block -Encoding UTF8
}
```

- [ ] **Step 5: Runner — per-case overrides (strictness + attributed) and new assertions**

In the classify branch of the per-case loop, replace the three override lines (`$llmCfg.Enabled = ...`, `$llmCfg.Level = ...`, `$llmCfg.ComplexMinSubcommands = ...`) with:

```powershell
    # Per-case overrides on the compiled block (reset each case).
    $llmCfg = $config._compiled.llmSecondOpinion
    $llmCfg.Enabled               = if ($tc.HasAttribute('enabled')) { [bool]::Parse($tc.GetAttribute('enabled')) } else { $true }
    $llmCfg.Level                 = if ($tc.HasAttribute('level')) { $tc.GetAttribute('level') } else { 'complex_remote' }
    $llmCfg.ComplexMinSubcommands = if ($tc.HasAttribute('min')) { [int]$tc.GetAttribute('min') } else { 2 }
    # attributed_verdicts (phase II, default true). Add-Member -Force so this
    # works on the TDD stub and on the real compiled block alike.
    $attrWant = $true
    if ($tc.HasAttribute('attributed')) { $attrWant = [bool]::Parse($tc.GetAttribute('attributed')) }
    $llmCfg | Add-Member -MemberType NoteProperty -Name 'AttributedVerdicts' -Value $attrWant -Force
    # strictness override (suppression cases need normal so gated allows).
    if ($tc.HasAttribute('strictness')) { $config.global_modifying_strictness = $tc.GetAttribute('strictness') }
    else { $config.global_modifying_strictness = $fileStrictness }
```

Replace the single `reason-contains` assertion with semicolon-list support, and add `reason-not-contains`, `flagged`, `suppressed` assertions (insert after the `effect` assertion, before `Record-Result`):

```powershell
    if ($ok -and $reasonContains) {
        foreach ($want in ($reasonContains -split ';')) {
            if (-not ("$($result.Reason)").Contains($want.Trim())) { $ok = $false; $detail += " | reason missing '$($want.Trim())'" }
        }
    }
    if ($ok -and $tc.HasAttribute('reason-not-contains')) {
        foreach ($bad in ($tc.GetAttribute('reason-not-contains') -split ';')) {
            if (("$($result.Reason)").Contains($bad.Trim())) { $ok = $false; $detail += " | reason unexpectedly contains '$($bad.Trim())'" }
        }
    }
    if ($ok -and $tc.HasAttribute('flagged')) {
        $got = if ($llmLog -and $llmLog.flagged) { ($llmLog.flagged -join ',') } else { '' }
        $ok = ($got -eq $tc.GetAttribute('flagged'))
        if (-not $ok) { $detail += " | flagged expected '$($tc.GetAttribute('flagged'))' got '$got'" }
    }
    if ($ok -and $tc.HasAttribute('suppressed')) {
        $got = if ($llmLog -and $llmLog.suppressed) { ($llmLog.suppressed -join ',') } else { '' }
        $ok = ($got -eq $tc.GetAttribute('suppressed'))
        if (-not $ok) { $detail += " | suppressed expected '$($tc.GetAttribute('suppressed'))' got '$got'" }
    }
```

NOTE: the existing `reason-contains` line in the runner is `if ($ok -and $reasonContains) { $ok = ...Contains($reasonContains) ... }` — replace that whole block with the semicolon-list version above (phase-I values contain no `;`, so they keep working).

At the END of the classify branch (right after `Record-Result -Ok $ok -Name $name -Detail $detail`), add:

```powershell
    Write-CaseLog -Name $name -Ok $ok -Result $result -LlmLog $llmLog -Mode 'classify'
```

- [ ] **Step 6: Runner — fullpipe strictness + log-contains + case log**

In the fullpipe branch, replace the line `$env:PRETOOLHOOK_CONFIG_PATH = $configPath` with:

```powershell
        # Fullpipe config: the fixture file as-is, OR a strictness-overridden
        # temp copy when the case asks for one (the file default is strict).
        $fpConfigPath = $configPath
        if ($tc.HasAttribute('strictness')) {
            $fpCfg = Get-Content $configPath -Raw
            $fpCfg = $fpCfg -replace '"global_modifying_strictness": "\w+"', ('"global_modifying_strictness": "' + $tc.GetAttribute('strictness') + '"')
            $fpConfigPath = 'c:\temp\llm-review-fp-config.json'
            Set-Content $fpConfigPath $fpCfg -Encoding UTF8
        }
        $env:PRETOOLHOOK_CONFIG_PATH = $fpConfigPath
```

After the fullpipe decision assertions (inside the `try`, just before the fullpipe `Record-Result`), add log-file assertions:

```powershell
            if ($ok -and $tc.HasAttribute('log-contains')) {
                # Read the child hook's .log (fixture log_file_path dir) and
                # require every semicolon-separated marker in the newest entry.
                $latestLog = Get-ChildItem (Join-Path $runLogDir '*.log') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $tail = (Get-Content $latestLog.FullName -Tail 40) -join "`n"
                foreach ($marker in ($tc.GetAttribute('log-contains') -split ';')) {
                    if (-not $tail.Contains($marker.Trim())) { $ok = $false; $detail += " | log missing '$($marker.Trim())'" }
                }
            }
```

At the END of the fullpipe branch (right after its `Record-Result`, before `continue`), add:

```powershell
        Write-CaseLog -Name $name -Ok $ok -Result $null -LlmLog $null -Mode 'fullpipe'
```

- [ ] **Step 7: Runner — summary prints the run-log path**

In the summary block, after the `Write-Host "Total: $total  Passed: $passed  Failed: $failed"` line, add:

```powershell
Write-Host "Run log: $runLogPath"
```

- [ ] **Step 8: Runner — badtype pre-flight + parser JSON-layer pre-flights**

Immediately after the existing `LlmConfig-BadLevel` pre-flight block, add the badtype pre-flight:

```powershell
# ---- Pre-flight: bad attributed_verdicts type must be rejected (Task 2) ----
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badtype.json")
    Record-Result -Ok $false -Name "LlmConfig-BadType" -Detail "Load-Config did NOT throw for attributed_verdicts='yes'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_second_opinion\.attributed_verdicts'
    Record-Result -Ok $ok -Name "LlmConfig-BadType" -Detail "threw but unexpected message: $($_.Exception.Message)"
}
```

In the `$parserCases` array, after the existing 6 entries, append these 6 (each pins a spec section 4 JSON-layer behavior; `Count` feeds `-SubCommandCount`, `WantIndices` is the expected indices joined by comma, '' = none):

```powershell
    # JSON attributed layer (Task 3): valid index list -> attributed modifying
    @{ Name = 'LlmParser-AttrIdx';        Raw = '{"modifying":[2]}';        Count = 2; WantVerdict = 'modifying'; WantRecovered = $false; WantIndices = '2' },
    # empty array = all read-only
    @{ Name = 'LlmParser-AttrEmpty';      Raw = '{"modifying":[]}';        Count = 2; WantVerdict = 'read-only'; WantRecovered = $false; WantIndices = '' },
    # index 0 = "something not listed" (spec P3) - a valid flag
    @{ Name = 'LlmParser-AttrZero';       Raw = '{"modifying":[0]}';       Count = 2; WantVerdict = 'modifying'; WantRecovered = $false; WantIndices = '0' },
    # out of range (3 > Count=2) -> unusable
    @{ Name = 'LlmParser-AttrOutOfRange'; Raw = '{"modifying":[3]}';       Count = 2; WantVerdict = 'unusable';  WantRecovered = $false; WantIndices = '' },
    # wrong type (string, not array) -> unusable
    @{ Name = 'LlmParser-AttrWrongType';  Raw = '{"modifying":"yes"}';     Count = 2; WantVerdict = 'unusable';  WantRecovered = $false; WantIndices = '' },
    # ramble then JSON on the last line -> rescued (Recovered)
    @{ Name = 'LlmParser-AttrLastLine';   Raw = "reasoning`n{`"modifying`":[1]}"; Count = 2; WantVerdict = 'modifying'; WantRecovered = $true; WantIndices = '1' }
```

Replace the parser pre-flight loop body with (adds try/catch so a missing `-SubCommandCount` parameter records a RED failure instead of aborting the run, plus the indices assertion):

```powershell
foreach ($pc in $parserCases) {
    if (-not (Get-Command ConvertTo-LlmVerdict -ErrorAction SilentlyContinue)) {
        Record-Result -Ok $false -Name $pc.Name -Detail "ConvertTo-LlmVerdict not defined (TDD red phase)"
        continue
    }
    $cnt = if ($pc.ContainsKey('Count')) { $pc.Count } else { 0 }
    $wantIdx = if ($pc.ContainsKey('WantIndices')) { $pc.WantIndices } else { '' }
    try {
        $got = ConvertTo-LlmVerdict -RawContent $pc.Raw -SubCommandCount $cnt
    }
    catch {
        Record-Result -Ok $false -Name $pc.Name -Detail "threw: $($_.Exception.Message)"
        continue
    }
    $idxGot = if ($got.Indices) { ($got.Indices -join ',') } else { '' }
    $ok = ($got.Verdict -eq $pc.WantVerdict) -and ($got.Recovered -eq $pc.WantRecovered) -and ($idxGot -eq $wantIdx)
    Record-Result -Ok $ok -Name $pc.Name -Detail "raw='$($pc.Raw)' => verdict=$($got.Verdict) recovered=$($got.Recovered) indices='$idxGot' (wanted $($pc.WantVerdict)/$($pc.WantRecovered)/'$wantIdx')"
}
```

- [ ] **Step 9: Create `test-cases.p2.small.xml` (the 10 typical cases, spec section 10)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- PHASE-II SMALL SUITE - the 10 typical attributed-verdict cases.
     DEFAULT file for Run-Tests.ps1. Mock values idx:... inject attributed JSON
     verdicts through the REAL parser; strictness="normal" makes the gated tier
     allow (the fixture file's global default is strict).
     Run:  pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -->
<commands>
  <category-group name="P2Small">

    <test-case expected="allow" category="P2-GatedBothSuppressed" level="complex_commands" strictness="normal" mock="idx:1,2" in-scope="true" verdict="modifying" effect="veto-suppressed-policy" flagged="1,2" suppressed="1,2" reason="both gated commands flagged; all suppressed by policy => allow">
      <description>suppression: git add + git commit flagged, all suppressed</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-MixedVetoOnReadOnly" level="complex_commands" strictness="normal" mock="idx:1,2" in-scope="true" verdict="modifying" effect="veto" flagged="1,2" suppressed="1" reason-contains="curl -o;suppressed as policy" reason="gated flag suppressed, read_only flag vetoes => ask naming the offender">
      <description>mixed: veto stands only on the read_only sub-command</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; curl -o c:\temp\x http://h/y]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-ReadOnlyFlagVeto" level="complex_commands" strictness="normal" mock="idx:1" in-scope="true" verdict="modifying" effect="veto" flagged="1" suppressed="" reason-contains="git status" reason="read_only tier flagged (git status) => veto, not suppressible">
      <description>read_only tier flag => veto</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git status && git add .]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="P2-EmptyIdxAgree" level="complex_commands" mock="idx:" in-scope="true" verdict="read-only" effect="agree" reason="empty modifying array = all read-only => agree allow">
      <description>idx: (empty) => agree</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-BareTrueFallback" level="complex_commands" strictness="normal" mock="modifying" in-scope="true" verdict="modifying" effect="veto" flagged="" suppressed="" reason="bare 'true' is unattributed (P5) => full veto even on a gated block">
      <description>bare-token fallback: unattributed true => full veto</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-IdxZeroVeto" level="complex_commands" strictness="normal" mock="idx:0" in-scope="true" verdict="modifying" effect="veto" flagged="0" suppressed="" reason="index 0 = unlisted danger (P3) => veto, never suppressible">
      <description>idx:0 => veto</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-InvalidIdxUnusable" level="complex_commands" strictness="normal" mock="idx:5" in-scope="true" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="index 5 out of range for 2 sub-commands => unusable => fail-closed ask">
      <description>out-of-range index => unusable</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-LocalAskAgree" level="complex_commands" strictness="normal" mock="idx:1,2" in-scope="true" verdict="modifying" effect="agree" reason="local already asks (git push is modifying tier) => LLM modifying agrees; LLM never downgrades">
      <description>local ask + attributed modifying => agree</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git push origin main ; git add .]]></copilot-command>
    </test-case>

    <test-case expected="ask" category="P2-AttributedOffVeto" level="complex_commands" strictness="normal" attributed="false" mock="modifying" in-scope="true" verdict="modifying" effect="veto" reason="attributed_verdicts=false restores the phase-I binary path: gated block vetoes as in phase I">
      <description>attributed=false => phase-I veto</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

    <test-case expected="allow" category="P2-SingleGatedOutOfScope" level="complex_commands" strictness="normal" mock="idx:1" in-scope="false" verdict="not_called" effect="none" reason="single sub-command below min=2 => not checked (scope rules unchanged)">
      <description>single gated command at complex_commands => out of scope</description>
      <tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>

  </category-group>
</commands>
```

- [ ] **Step 10: Run RED baselines**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 24  Passed: 9  Failed: 15`. Passing: LlmConfig-BadLevel, the 6 phase-I parser checks, P2-BareTrueFallback, P2-AttributedOffVeto. Failing: LlmConfig-BadType (loader ignores the key today), 6 new parser checks (`-SubCommandCount` unknown parameter), 8 classify cases (all `idx:` mocks throw "unknown PRETOOLHOOK_LLMREVIEW_MOCK value").

Run the phase-I file as regression: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.xml`
Expected: FAIL — `Total: 32  Passed: 25  Failed: 7` (the 25 phase-I checks still green; the 7 failures are the new T2/T3 pre-flight targets: LlmConfig-BadType + 6 JSON parser checks).

- [ ] **Step 11: Commit**

```powershell
git add test/config/llm-review/config.json test/config/llm-review/config.badtype.json test/config/llm-review/Run-Tests.ps1 test/config/llm-review/test-cases.p2.small.xml
git commit -m "test: phase-II fixture groundwork - runner -XmlPath/new attrs/run-log, gated tiers, small suite (RED 9/24)"
```

---

### Task 2: ConfigLoader — `attributed_verdicts` validation + compilation

**Files:**
- Modify: `src/ConfigLoader.ps1` (llm validation block in Test-ConfigSchema; llm compilation block in Load-Config)
- Test: `test/config/llm-review/Run-Tests.ps1`

- [ ] **Step 1: Validation**

In `Test-ConfigSchema`'s `llm_second_opinion` block (added in phase I), immediately after the `enabled` boolean check, insert:

```powershell
        if ((Get-Member -InputObject $llm -Name 'attributed_verdicts' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
            $llm.attributed_verdicts -isnot [bool]) {
            throw "Configuration validation failed: 'llm_second_opinion.attributed_verdicts' must be a boolean"
        }
```

- [ ] **Step 2: Compilation**

In `Load-Config`'s llm compilation block, immediately after the `$llmMinSubs = 2` pre-compute lines, insert:

```powershell
        $llmAttributed = $true
        if (Get-Member -InputObject $llmRaw -Name 'attributed_verdicts' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $llmAttributed = [bool]$llmRaw.attributed_verdicts }
```

And in the `$llmCompiled = [PSCustomObject]@{ ... }` literal, add this line after `ComplexMinSubcommands = $llmMinSubs`:

```powershell
            AttributedVerdicts      = $llmAttributed
```

- [ ] **Step 3: Run fixture — badtype flips GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 24  Passed: 10  Failed: 14` (LlmConfig-BadType now green; the 6 JSON parser checks and 8 `idx:` classify cases still red).

Also confirm the phase-I file: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.xml` → `Total: 32  Passed: 26  Failed: 6`.

- [ ] **Step 4: Full regression (loader change must be a no-op for existing configs)**

Run: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1`
Expected: all green (962/962) — the live test copy's llm block has no `attributed_verdicts` key, so the default `true` compiles but `enabled:false` keeps the gate closed.

- [ ] **Step 5: Commit**

```powershell
git add src/ConfigLoader.ps1
git commit -m "feat: ConfigLoader validates + compiles attributed_verdicts (default true)"
```

---

### Task 3: LlmReview v2 — prompt V2 + parser v2 + verdict fn v2

**Files:**
- Modify: `src/LlmReview.ps1`
- Modify: `test/config/llm-review/http/Run-LlmCallTests.ps1` (+ 2 check tokens, `attributed`/`subcommands` attrs)
- Modify: `test/config/llm-review/http/test-llm-call-matrix.xml` (+ 2 cases)
- Test: `test/config/llm-review/Run-Tests.ps1`, `test/config/llm-review/http/Run-LlmCallTests.ps1`

This task makes the parser pre-flights green and lets `idx:` mocks flow; the merge (Task 4) stays phase-I, so most small-file classify cases remain red by design.

- [ ] **Step 1: Add the V2 system prompt (keep V1 for `attributed_verdicts=false`)**

In `src/LlmReview.ps1`, immediately after the existing `$script:LlmSystemPrompt` here-string, add:

```powershell
# --- V2 system prompt (attributed verdicts; used when AttributedVerdicts is on) ---
$script:LlmSystemPromptV2 = @'
You are a binary command-safety classifier protecting a production environment.
You receive one command block (it may mix AWS CLI, PowerShell, CMD, bash, ssh,
docker, kubectl, terraform, git, etc.) plus a numbered list of its sub-commands,
and you report WHICH numbered sub-commands are modifying.

DEFINITIONS
- MODIFYING: creates, updates, deletes, moves, copies, renames, sends,
  installs, starts, stops, or otherwise changes the state of any file,
  directory, system, service, process, configuration, cloud resource, or data
  store; or performs an HTTP/API call that mutates (POST, PUT, PATCH, DELETE,
  or data-upload flags such as curl -d/--data/-F/-T, wget --post-data).
- READ-ONLY: only inspects, queries, lists, prints, or downloads. This
  includes HTTP GET/HEAD/OPTIONS (curl/wget/Invoke-RestMethod with no data
  flags), aws ... describe-*/list-*/get-*, kubectl get/describe,
  docker ps/images/logs/inspect, git status/diff/log/show, Get-*/dir/ls/cat/type.

EXAMPLES
block: aws s3 ls && aws s3 cp f s3://b/k
sub_commands: 1. aws s3 ls / 2. aws s3 cp f s3://b/k
answer: {"modifying":[2]}

block: Get-ChildItem C:\logs | Select-Object -First 5
sub_commands: 1. Get-ChildItem C:\logs / 2. Select-Object -First 5
answer: {"modifying":[]}

OUTPUT CONTRACT - CRITICAL
Your ENTIRE response must be one JSON object, nothing else:
  {"modifying": []}        - every numbered sub-command is read-only
  {"modifying": [2]}       - sub-command 2 is modifying
  {"modifying": [1, 2]}    - several are modifying
Use index 0 for anything modifying that is NOT in the numbered list
(for example a redirect target or an unlisted nested command).
No reasoning. No explanation. No markdown. No code fences. Emit the JSON
object immediately.
'@
```

- [ ] **Step 2: Rewrite `ConvertTo-LlmVerdict` (parser v2, spec section 4)**

Replace the whole `ConvertTo-LlmVerdict` function with:

```powershell
function ConvertTo-LlmVerdict {
    <#
    .SYNOPSIS
        Layered verdict parser (phase-II spec section 4). Returns a
        PSCustomObject @{ Verdict; Recovered; Indices } where Indices is an
        int array for attributed JSON answers and $null when unattributed
        (bare token / phase-I JSON keys). Layers: 1 bare token; 2 JSON
        {"modifying":[...]} (strictly validated against -SubCommandCount) or
        phase-I verdict-ish JSON keys; 3 last-line rescue (bare token or the
        modifying JSON); 4 unusable. Garbage NEVER maps to a verdict.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$RawContent,
        [int]$SubCommandCount = 0
    )

    # Local helper: uniform result shape.
    function New-Verdict([string]$V, [bool]$R, $Idx) {
        return [PSCustomObject]@{ Verdict = $V; Recovered = $R; Indices = $Idx }
    }
    # Local helper: validate a parsed {"modifying": <value>} property.
    # Returns an int array (empty = read-only) or $null on any violation.
    function Test-ModifyingArray($M, [int]$Max) {
        if ($null -eq $M) { return @() }                      # {"modifying":null} ~ empty
        if ($M -isnot [System.Collections.IList]) { return $null }
        $list = @()
        foreach ($el in $M) {
            $n = 0
            if (-not [int]::TryParse("$el", [ref]$n)) { return $null }
            if ($n -lt 0 -or $n -gt $Max) { return $null }
            $list += $n
        }
        return ,$list
    }

    if ([string]::IsNullOrWhiteSpace($RawContent)) { return (New-Verdict 'unusable' $false $null) }
    $norm = $RawContent.Trim().ToLowerInvariant()

    # Layer 1: bare token (unattributed)
    if ($norm -eq 'true')  { return (New-Verdict 'modifying' $false $null) }
    if ($norm -eq 'false') { return (New-Verdict 'read-only' $false $null) }

    # Layer 2: JSON forms (whole response)
    $parsedObj = $null
    try { $parsedObj = $RawContent | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($parsedObj) {
        if ($parsedObj.PSObject.Properties.Name -contains 'modifying') {
            $idxs = Test-ModifyingArray $parsedObj.modifying $SubCommandCount
            if ($null -eq $idxs) { return (New-Verdict 'unusable' $false $null) }
            if ($idxs.Count -eq 0) { return (New-Verdict 'read-only' $false @()) }
            return (New-Verdict 'modifying' $false $idxs)
        }
        # Phase-I JSON verdict-ish keys (back-compat)
        foreach ($key in @('verdict', 'classification', 'decision', 'answer')) {
            if ($parsedObj.PSObject.Properties.Name -contains $key) {
                $v = ("$($parsedObj.$key)").Trim().ToLowerInvariant()
                if ($v -in @('modifying', 'true'))  { return (New-Verdict 'modifying' $false $null) }
                if ($v -in @('read-only', 'false')) { return (New-Verdict 'read-only' $false $null) }
            }
        }
    }

    # Layer 3: last non-empty line is a bare token or the modifying JSON (recovered)
    $lines = @($RawContent -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 0) {
        $last = $lines[-1]
        $lastNorm = $last.ToLowerInvariant()
        if ($lastNorm -eq 'true')  { return (New-Verdict 'modifying' $true $null) }
        if ($lastNorm -eq 'false') { return (New-Verdict 'read-only' $true $null) }
        if ($last.StartsWith('{')) {
            $lastObj = $null
            try { $lastObj = $last | ConvertFrom-Json -ErrorAction Stop } catch { }
            if ($lastObj -and ($lastObj.PSObject.Properties.Name -contains 'modifying')) {
                $idxs = Test-ModifyingArray $lastObj.modifying $SubCommandCount
                if ($null -ne $idxs) {
                    if ($idxs.Count -eq 0) { return (New-Verdict 'read-only' $true @()) }
                    return (New-Verdict 'modifying' $true $idxs)
                }
            }
        }
    }

    # Layer 4: unusable (distinct state - never treated as a verdict)
    return (New-Verdict 'unusable' $false $null)
}
```

- [ ] **Step 3: Run fixture — parser pre-flights flip GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 24  Passed: 16  Failed: 8` (all 14 pre-flight checks green; the 8 `idx:` classify cases still red — the verdict fn doesn't know the mock values yet).

- [ ] **Step 4: Rewrite `Get-LlmReviewVerdict` (sub_commands, idx mocks, Mocked flag)**

Replace the whole `Get-LlmReviewVerdict` function with:

```powershell
function Get-LlmReviewVerdict {
    <#
    .SYNOPSIS
        Returns the LLM verdict for a command. Checks the
        PRETOOLHOOK_LLMREVIEW_MOCK short-circuit FIRST (test-only), then makes
        the OpenAI-compatible chat-completions call. When
        $LlmConfig.AttributedVerdicts is on, the V2 prompt is used and the
        numbered -SubCommands are appended as <sub_commands>; the parser
        returns Indices with the verdict. Result fields: Verdict, Raw,
        LatencyMs, Recovered, Error, Indices, Mocked.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][PSCustomObject]$LlmConfig,
        [string[]]$SubCommands = @()
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [PSCustomObject]@{ Verdict = 'down'; Raw = ''; LatencyMs = 0; Recovered = $false; Error = $null; Indices = $null; Mocked = $false }
    $subCount = $SubCommands.Count

    # Mock short-circuit (no network). The mock supplies the RAW content and the
    # REAL parser decides the verdict. 'idx:...' injects the attributed JSON
    # form; the 4 phase-I values inject bare/garbage/down as before.
    $mock = $env:PRETOOLHOOK_LLMREVIEW_MOCK
    if ($mock) {
        $result.Mocked = $true
        if ($mock -like 'idx:*') {
            $list = $mock.Substring(4)
            if ($list.Trim() -eq '') { $result.Raw = '{"modifying":[]}' }
            else {
                $items = @($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                $result.Raw = '{"modifying":[' + ($items -join ',') + ']}'
            }
        }
        else {
            switch ($mock) {
                'modifying' { $result.Raw = 'true' }
                'read-only' { $result.Raw = 'false' }
                'garbage'   { $result.Raw = "Let me analyze this command carefully.`nIt seems to read files, but I am not entirely sure about every part." }
                'down'      { $result.Verdict = 'down'; $result.Error = 'mock: simulated unreachable LLM' }
                default     { throw "Get-LlmReviewVerdict: unknown PRETOOLHOOK_LLMREVIEW_MOCK value '$mock' (expected modifying|read-only|garbage|down|idx:...)" }
            }
        }
        if ($mock -ne 'down') {
            $parsed = ConvertTo-LlmVerdict -RawContent $result.Raw -SubCommandCount $subCount
            $result.Verdict   = $parsed.Verdict
            $result.Recovered = $parsed.Recovered
            $result.Indices   = $parsed.Indices
        }
        $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
        return $result
    }

    # Payload guard
    $cmdText = $Command
    if ($cmdText.Length -gt 8000) { $cmdText = $cmdText.Substring(0, 8000) }

    # User message: raw block, plus the numbered sub-command list in V2 mode
    $userPrompt = "<command_block>`n$cmdText`n</command_block>"
    $sysPrompt = $script:LlmSystemPrompt
    if ($LlmConfig.AttributedVerdicts) {
        $sysPrompt = $script:LlmSystemPromptV2
        if ($SubCommands.Count -gt 0) {
            $numbered = @()
            for ($i = 0; $i -lt $SubCommands.Count; $i++) { $numbered += "{0}. {1}" -f ($i + 1), $SubCommands[$i] }
            $userPrompt += "`n<sub_commands>`n" + ($numbered -join "`n") + "`n</sub_commands>"
        }
    }

    $body = [ordered]@{
        model       = $LlmConfig.Model
        messages    = @(
            @{ role = 'system'; content = $sysPrompt },
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
        $parsed = ConvertTo-LlmVerdict -RawContent $raw -SubCommandCount $subCount
        $result.Verdict   = $parsed.Verdict
        $result.Recovered = $parsed.Recovered
        $result.Indices   = $parsed.Indices
    }
    catch {
        $result.Verdict = 'down'
        $result.Error   = $_.Exception.Message
    }
    $sw.Stop(); $result.LatencyMs = $sw.ElapsedMilliseconds
    return $result
}
```

- [ ] **Step 5: Run fixture — most classify cases still red (merge is Task 4)**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: FAIL — `Total: 24  Passed: 19  Failed: 5`. Newly green: P2-EmptyIdxAgree, P2-InvalidIdxUnusable, P2-SingleGatedOutOfScope. Still red: P2-GatedBothSuppressed, P2-MixedVetoOnReadOnly, P2-ReadOnlyFlagVeto, P2-IdxZeroVeto, P2-LocalAskAgree (all need the merge's attributed path / `flagged`+`suppressed` fields).

Also run the phase-I file: `... -XmlPath test/config/llm-review/test-cases.xml` → `Total: 32  Passed: 32  Failed: 0` (all pre-flights green now).

- [ ] **Step 6: HTTP suite — `attributed`/`subcommands` attrs + 2 check tokens + 2 shape cases**

In `test/config/llm-review/http/Run-LlmCallTests.ps1`:

(a) In the per-case attribute reads, add:

```powershell
        $attrVerdicts    = if ($tc.HasAttribute('attributed'))       { [bool]::Parse($tc.GetAttribute('attributed')) } else { $true }
        $subCmds         = @()
        if ($tc.HasAttribute('subcommands')) { $subCmds = @($tc.GetAttribute('subcommands') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
```

(b) In the `$llmCfg = [PSCustomObject]@{ ... }` literal, add after `ComplexMinSubcommands = 2,`:

```powershell
            AttributedVerdicts      = $attrVerdicts
```

(c) Replace the direct-mode call `$verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg` with:

```powershell
            $verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg -SubCommands $subCmds
```

(d) In `Invoke-RequestChecks`'s `switch ($t)`, add two tokens:

```powershell
            'subcmds-tags'   { $c = $bodyObj.messages[1].content; $ok = ($bodyObj -and $c.Contains('<sub_commands>') -and $c.Contains('</sub_commands>') -and $c.Contains('1. ')); $why = "user content missing numbered <sub_commands> block" }
            'nosubcmds-tags' { $c = $bodyObj.messages[1].content; $ok = ($bodyObj -and -not $c.Contains('<sub_commands>')); $why = "user content unexpectedly contains <sub_commands>" }
```

(e) Append to `test/config/llm-review/http/test-llm-call-matrix.xml` inside the `LlmCallMatrix` category-group:

```xml
    <test-case name="M-Attr-SubCommandsPresent" server="true" subcommands="Get-Date;Get-ChildItem c:\temp" expect-verdict="modifying" check="subcmds-tags">
      <description>attributed mode: user message carries the numbered sub_commands block</description>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>

    <test-case name="M-AttrOff-NoSubCommands" server="true" attributed="false" subcommands="Get-Date" expect-verdict="modifying" check="nosubcmds-tags">
      <description>attributed=false: user message stays phase-I shape (no sub_commands block)</description>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>
```

- [ ] **Step 7: Run the HTTP suite — 27/27**

Run: `pwsh -NoProfile -File test/config/llm-review/http/Run-LlmCallTests.ps1`
Expected: `Total: 27  Passed: 27  Failed: 0` (25 phase-I + 2 new shape cases; the existing cases build `$llmCfg` with `AttributedVerdicts=$true` now but no `subcommands`, so the `<sub_commands>` block is correctly absent for them).

- [ ] **Step 8: Commit**

```powershell
git add src/LlmReview.ps1 test/config/llm-review/http/Run-LlmCallTests.ps1 test/config/llm-review/http/test-llm-call-matrix.xml
git commit -m "feat: attributed prompt V2 + parser v2 (indices) + verdict fn sub_commands/idx-mocks"
```

---

### Task 4: Tier annotation + scope SubCommands + merge v2

**Files:**
- Modify: `src/Resolver.ps1` (`New-ResolutionResult` + tier branches)
- Modify: `src/LlmReview.ps1` (`Test-LlmReviewScope` returns SubCommands; `Test-GatedInvocationSafe` hook; `Invoke-LlmReview` merge v2)
- Test: `test/config/llm-review/Run-Tests.ps1`

- [ ] **Step 1: `New-ResolutionResult` gains `-Tier`**

In `src/Resolver.ps1`, replace the helper (currently at ~line 107):

```powershell
    function New-ResolutionResult {
        param([string]$Decision, [string]$Reason, [string]$MatchedPattern, [string]$Risk, [string]$Tier = '')
        return [PSCustomObject]@{
            Command        = $Command
            Decision       = $Decision
            Reason         = $Reason
            MatchedPattern = $MatchedPattern
            Risk           = $Risk
            Tier           = $Tier
        }
    }
```

- [ ] **Step 2: Annotate the tier-match branches (spec section 5)**

Append `-Tier "..."` to these `New-ResolutionResult` calls in `Resolve-Command` (line numbers approximate from phase-I state; empty Tier stays the default everywhere else — suppression only ever trusts `'strictness_gated'`):

| Location | Change |
|---|---|
| Step 1a read_only match (~:407) | append `-Tier "read_only"` |
| Step 1a.5 gated strict-ask (~:431) | append `-Tier "strictness_gated"` |
| Step 1a.5 gated allow (~:433) | append `-Tier "strictness_gated"` |
| Step 1b modifying match (~:453) | append `-Tier "modifying"` |
| PowerShell read-only verb (~:514) | append `-Tier "read_only"` |
| PowerShell modifying verb (~:518) | append `-Tier "modifying"` |
| PowerShell verb-prefix read-only (~:531) | append `-Tier "read_only"` |
| PowerShell verb-prefix modifying (~:535) | append `-Tier "modifying"` |
| AWS read-only prefix (~:592) | append `-Tier "read_only"` |
| AWS modifying prefix (~:600) | append `-Tier "modifying"` |

Example for the gated allow branch:

```powershell
                        return New-ResolutionResult -Decision "allow" -Reason "$($entry.name) (strictness-gated)" -MatchedPattern $entry.name -Risk "none" -Tier "strictness_gated"
```

- [ ] **Step 3: `Test-LlmReviewScope` returns the sub-command objects**

In `src/LlmReview.ps1`'s `Test-LlmReviewScope`:

(a) Change the scope object construction to include `SubCommands`:

```powershell
    $scope = [PSCustomObject]@{ InScope = $false; Reason = ''; SubCommandCount = 0; RemoteMatch = $null; SubCommands = @() }
```

(b) Immediately after `$scope.SubCommandCount = $subs.Count`, add:

```powershell
    $scope.SubCommands = $subs
```

(The merge and the prompt builder then use the SAME filtered list the scope engine computed — spec P2.)

- [ ] **Step 4: Add the stage-1 guard hook**

In `src/LlmReview.ps1`, before `Invoke-LlmReview`, add:

```powershell
function Test-GatedInvocationSafe {
    <#
    .SYNOPSIS
        Stage-2 extension point (spec P4): decides whether a strictness_gated
        invocation is safe to suppress. Stage 1: always safe (tier-only
        suppression). Stage 2 will path-check writable gated cmdlets;
        unknown argument shapes must fail safe ($false = do not suppress).
    #>
    param([string]$Command, [PSCustomObject]$Config)
    return $true
}
```

- [ ] **Step 5: Merge v2 in `Invoke-LlmReview`**

(a) Replace the `$log = [PSCustomObject]@{ ... }` initialization with the expanded object:

```powershell
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
        indices           = $null
        flagged           = @()
        suppressed        = @()
        error             = $null
        mocked            = $false
        sent              = @()
        tiers             = @()
        local_decision    = ''
        local_reason      = ''
        timeout_ms        = $llm.TimeoutMs
    }
```

(b) Immediately after the `$log.remote_match = $scope.RemoteMatch` line (before the `if (-not $scope.InScope)` guard), add:

```powershell
    # Numbered list for the prompt AND the index lookup (spec P2: same list).
    $subTexts = @($scope.SubCommands | ForEach-Object { "$($_.Command)" })
    $log.sent  = $subTexts
    $log.tiers = @($scope.SubCommands | ForEach-Object { "$($_.Tier)" })
    $log.local_decision = $ClassifyResult.Decision
    $log.local_reason   = "$($ClassifyResult.Reason)"
```

(c) Replace the verdict call `$verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm` with:

```powershell
    $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm -SubCommands $subTexts
```

(d) After the existing log fills (`$log.verdict`, `$log.recovered`, `$log.latency_ms`, raw_excerpt), add:

```powershell
    $log.indices = $verdict.Indices
    $log.mocked  = $verdict.Mocked
    if ($verdict.Error) { $log.error = $verdict.Error }
```

(e) Replace the `'modifying' { ... }` branch of the merge `switch` with:

```powershell
        'modifying' {
            if ($localDecision -ne 'allow') { $log.effect = 'agree' }
            elseif (-not $llm.AttributedVerdicts -or $null -eq $verdict.Indices) {
                # Phase-I path: unattributed -> full veto, nothing suppressible (spec P5)
                $ClassifyResult.Decision = 'ask'
                $ClassifyResult.Reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING but local hook classified read-only - forced to ask. Review carefully before approving. | local reason: $localReason"
                $log.effect = 'veto'
            }
            else {
                # Attributed merge (spec section 6): map each flagged index to its tier
                $log.flagged = @($verdict.Indices)
                $vetoIdx = @()
                $suppIdx = @()
                foreach ($ix in $verdict.Indices) {
                    if ($ix -eq 0) { $vetoIdx += 0; continue }   # unlisted danger: never suppressible (P3)
                    $sub = $scope.SubCommands[$ix - 1]
                    if ($sub -and $sub.Tier -eq 'strictness_gated' -and
                        (Test-GatedInvocationSafe -Command $sub.Command -Config $Config)) {
                        $suppIdx += $ix
                    }
                    else { $vetoIdx += $ix }
                }
                $log.suppressed = @($suppIdx)
                if ($vetoIdx.Count -eq 0) {
                    # Every flag was accepted policy (the flood-killer)
                    $log.effect = 'veto-suppressed-policy'
                }
                else {
                    $first = $vetoIdx[0]
                    if ($first -eq 0) {
                        $firstText = "(unlisted part of the block) [index 0]"
                    }
                    else {
                        $ft = "$($scope.SubCommands[$first - 1].Command)"
                        if ($ft.Length -gt 120) { $ft = $ft.Substring(0, 120) }
                        $firstText = "'$ft' [sub-command $first]"
                    }
                    $reason = "*** LLM-VETO *** second-opinion LLM says MODIFYING: $firstText - forced to ask."
                    if ($suppIdx.Count -gt 0) {
                        $suppTexts = @()
                        foreach ($sx in $suppIdx) {
                            $st = "$($scope.SubCommands[$sx - 1].Command)"
                            if ($st.Length -gt 60) { $st = $st.Substring(0, 60) }
                            $suppTexts += "'$st' [$sx]"
                        }
                        $reason += " | suppressed as policy: " + ($suppTexts -join ', ')
                    }
                    $reason += " | local reason: $localReason"
                    $ClassifyResult.Decision = 'ask'
                    $ClassifyResult.Reason = $reason
                    $log.effect = 'veto'
                }
            }
        }
```

- [ ] **Step 6: Run fixture — small file fully GREEN**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1`
Expected: PASS — `Total: 24  Passed: 24  Failed: 0`, exit 0.

Also verify: phase-I file `-XmlPath test-cases.xml` → `Total: 32  Passed: 32  Failed: 0`; HTTP suite → `Total: 27  Passed: 27`.

- [ ] **Step 7: Full regression (Tier annotation must be byte-identical behavior)**

Run: `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1` → 962/962.
Sandbox: `powershell.exe -ExecutionPolicy Bypass -File test/config/test-strictness-gate/Run-Tests.ps1` → 938/938.
Codex: `pwsh -NoProfile -File test/config/live/test-cases.codex.ps1` → 17/17.

- [ ] **Step 8: Commit**

```powershell
git add src/Resolver.ps1 src/LlmReview.ps1
git commit -m "feat: Tier annotation + attributed merge with gated-tier suppression (stage 1)"
```

---

### Task 5: Logger `Format-LlmLogBlock` + large suite (50 cases)

**Files:**
- Modify: `src/Logger.ps1` (new `Format-LlmLogBlock`; `Write-LogEntry` uses it)
- Create: `test/config/llm-review/test-cases.p2.large.xml`
- Test: `test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.p2.large.xml`

`Write-RecordEntry` needs NO change: the expanded log object (Task 4) serializes into the JSONL `llm` field automatically (`flagged`/`suppressed` ride along — spec section 7). The runner's `Write-CaseLog` (Task 1) also needs no change: its `Get-Command Format-LlmLogBlock` guard starts resolving to the real formatter as soon as it exists.

- [ ] **Step 1: Add `Format-LlmLogBlock` to `src/Logger.ps1`**

Insert before `function Write-LogEntry`:

```powershell
function Format-LlmLogBlock {
    <#
    .SYNOPSIS
        Shared reconciliation formatter (phase-II spec section 7 + P9).
        Returns the multi-line LLM evidence block for the human-readable .log
        when a call actually happened (in_scope), a one-line summary when the
        feature was enabled but out of scope, and '' when $LlmLog is null.
        Used by Write-LogEntry (production) and by test runners (per-run logs).
    #>
    param(
        [PSCustomObject]$Result,
        [PSCustomObject]$LlmLog
    )
    if ($null -eq $LlmLog) { return '' }

    # Out-of-scope: keep the phase-I one-liner.
    if (-not $LlmLog.in_scope) {
        return "  LLM: in_scope=$($LlmLog.in_scope) verdict=$($LlmLog.verdict) effect=$($LlmLog.effect) latency_ms=$($LlmLog.latency_ms)`n"
    }

    $mockMark = if ($LlmLog.mocked) { ' (mock)' } else { '' }

    # --- LLM-SENT: model + timeout + the numbered sub-command list (<=120 chars each)
    $sentLine = "  LLM-SENT      : model=$($LlmLog.model)"
    if ($LlmLog.timeout_ms) { $sentLine += " timeout=$($LlmLog.timeout_ms)ms" }
    if ($LlmLog.sent -and $LlmLog.sent.Count -gt 0) {
        $parts = @()
        for ($i = 0; $i -lt $LlmLog.sent.Count; $i++) {
            $t = "$($LlmLog.sent[$i])"
            if ($t.Length -gt 120) { $t = $t.Substring(0, 120) }
            $parts += "[$($i + 1)] $t"
        }
        $sentLine += " | " + ($parts -join ' | ')
    }
    $sentLine += "`n"

    # --- LLM-RECV: raw response (single line) or the error, latency, recovered, mock
    $recvLine = "  LLM-RECV      : "
    if ($LlmLog.verdict -eq 'down') {
        $err = "$($LlmLog.error)"
        if ($err.Length -gt 200) { $err = $err.Substring(0, 200) }
        $recvLine += "ERROR '$err'"
    }
    else {
        $recvLine += "'$($LlmLog.raw_excerpt)'"
    }
    $recvLine += " ($($LlmLog.latency_ms)ms, recovered=$($LlmLog.recovered)$mockMark) -> verdict=$($LlmLog.verdict)"
    if ($LlmLog.indices) { $recvLine += " indices=[$($LlmLog.indices -join ',')]" }
    $recvLine += "`n"

    # --- LLM-LOCAL: the pre-merge local decision + per-index tier
    $localReason = "$($LlmLog.local_reason)"
    if ($localReason.Length -gt 120) { $localReason = $localReason.Substring(0, 120) }
    $localLine = "  LLM-LOCAL     : decision=$($LlmLog.local_decision) ($localReason)"
    if ($LlmLog.tiers -and $LlmLog.tiers.Count -gt 0) {
        $tierParts = @()
        for ($i = 0; $i -lt $LlmLog.tiers.Count; $i++) {
            $tier = "$($LlmLog.tiers[$i])"
            if (-not $tier) { $tier = 'unknown' }
            $tierParts += "[$($i + 1)]=$tier"
        }
        $localLine += "; tiers: " + ($tierParts -join ' ')
    }
    $localLine += "`n"

    # --- LLM-RECONCILE: how the final decision was reached
    $reconLine = "  LLM-RECONCILE : "
    switch ($LlmLog.effect) {
        'veto' {
            $reconLine += "flagged=[$($LlmLog.flagged -join ',')]"
            if ($LlmLog.suppressed -and $LlmLog.suppressed.Count -gt 0) {
                $reconLine += " suppressed=[$($LlmLog.suppressed -join ',')](strictness_gated)"
            }
            $vetoIdx = @($LlmLog.flagged | Where-Object { $LlmLog.suppressed -notcontains $_ })
            $reconLine += " veto=[$($vetoIdx -join ',')] -> FINAL: $($Result.Decision)"
        }
        'veto-suppressed-policy' {
            $reconLine += "flagged=[$($LlmLog.flagged -join ',')] all suppressed (strictness_gated policy) -> FINAL: $($Result.Decision)"
        }
        'agree' { $reconLine += "agree -> FINAL: $($Result.Decision)" }
        'disagree-kept-ask' { $reconLine += "LLM read-only but local ask (LLM never downgrades) -> FINAL: $($Result.Decision)" }
        'forced-ask' { $reconLine += "fail-closed ($($LlmLog.verdict)) -> FINAL: $($Result.Decision)" }
        default { $reconLine += "$($LlmLog.effect) -> FINAL: $($Result.Decision)" }
    }
    $reconLine += "`n"

    return ($sentLine + $recvLine + $localLine + $reconLine)
}
```

- [ ] **Step 2: `Write-LogEntry` uses the shared formatter**

In `Write-LogEntry`, replace the phase-I one-liner block:

```powershell
    # Optional second-opinion LLM summary line
    if ($LlmLog) {
        $body += "  LLM: in_scope=$($LlmLog.in_scope) verdict=$($LlmLog.verdict) effect=$($LlmLog.effect) latency_ms=$($LlmLog.latency_ms)`n"
    }
```

with:

```powershell
    # Optional second-opinion LLM reconciliation block (phase II)
    if ($LlmLog) {
        $body += (Format-LlmLogBlock -Result $ClassifyResult -LlmLog $LlmLog)
    }
```

- [ ] **Step 3: Verify production formatting through the fullpipe cases**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1` → `Total: 24  Passed: 24`.
Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.xml` → `Total: 32  Passed: 32` (the two phase-I fullpipe cases exercise the new formatter against the live hook; the out-of-scope one-liner is preserved).
Then inspect a run log from the runner (path printed in the summary): every in-scope case now shows the `LLM-SENT` / `LLM-RECV` / `LLM-LOCAL` / `LLM-RECONCILE` block with a `(mock)` marker.

- [ ] **Step 4: Create `test-cases.p2.large.xml` — G1 suppression matrix (14) + G2 levels × gated (8)**

Create `test/config/llm-review/test-cases.p2.large.xml` with this header and the first two groups (G3–G6 follow in Steps 5–6). Unless noted, cases use `level="complex_commands"` and `strictness="normal"`; the G1 block decomposes to `[git add . (gated), git commit -m x (gated), git status (read_only)]`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- PHASE-II LARGE SUITE (~50 cases, opt-in matrix).
     Run:  pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.p2.large.xml -->
<commands>
  <category-group name="P2G1-SuppressionMatrix">

    <test-case expected="allow" category="G1-Flag1" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="flag 1 = gated => suppressed">
      <description>G1: flag [1] only</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-Flag2" strictness="normal" mock="idx:2" verdict="modifying" effect="veto-suppressed-policy" flagged="2" suppressed="2" reason="flag 2 = gated => suppressed">
      <description>G1: flag [2] only</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-Flag12" strictness="normal" mock="idx:1,2" verdict="modifying" effect="veto-suppressed-policy" flagged="1,2" suppressed="1,2" reason="both gated flags suppressed">
      <description>G1: flags [1,2]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag3" strictness="normal" mock="idx:3" verdict="modifying" effect="veto" flagged="3" suppressed="" reason-contains="git status" reason="flag 3 = read_only => veto">
      <description>G1: flag [3] read_only => veto</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag13" strictness="normal" mock="idx:1,3" verdict="modifying" effect="veto" flagged="1,3" suppressed="1" reason="mixed: 1 suppressed, 3 vetoes">
      <description>G1: flags [1,3]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag23" strictness="normal" mock="idx:2,3" verdict="modifying" effect="veto" flagged="2,3" suppressed="2" reason="mixed: 2 suppressed, 3 vetoes">
      <description>G1: flags [2,3]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag123" strictness="normal" mock="idx:1,2,3" verdict="modifying" effect="veto" flagged="1,2,3" suppressed="1,2" reason-contains="suppressed as policy" reason="all flagged: gated two suppressed, read_only vetoes">
      <description>G1: flags [1,2,3]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag0" strictness="normal" mock="idx:0" verdict="modifying" effect="veto" flagged="0" suppressed="" reason="index 0 = unlisted danger => veto (P3)">
      <description>G1: flag [0]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-Flag01" strictness="normal" mock="idx:0,1" verdict="modifying" effect="veto" flagged="0,1" suppressed="1" reason="0 vetoes, 1 suppressed">
      <description>G1: flags [0,1]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-EmptyIdx" strictness="normal" mock="idx:" verdict="read-only" effect="agree" reason="empty array = all read-only => agree">
      <description>G1: empty indices</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G1-BareTrue" strictness="normal" mock="modifying" verdict="modifying" effect="veto" flagged="" suppressed="" reason="bare true = unattributed => full veto (P5)">
      <description>G1: bare true fallback</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-BareFalse" strictness="normal" mock="read-only" verdict="read-only" effect="agree" reason="bare false => agree">
      <description>G1: bare false</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-SetContentGated" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="Set-Content is gated; stage-1 suppresses on tier alone (P4, known path gap)">
      <description>G1: PS-domain gated (Set-Content) suppressed</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Set-Content c:\temp\a.txt x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G1-SetContentGated2" strictness="normal" mock="idx:2" verdict="modifying" effect="veto-suppressed-policy" flagged="2" suppressed="2" reason="gated write at index 2 suppressed">
      <description>G1: Set-Content at [2]</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Set-Content c:\temp\a.txt x]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="P2G2-Levels">

    <test-case expected="allow" category="G2-AllSingleGated" level="all" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="level all checks a single gated command; suppressed">
      <description>G2: level=all single gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G2-ComplexSingleGated" level="complex_commands" strictness="normal" mock="idx:1" in-scope="false" verdict="not_called" effect="none" reason="single sub-command below min => not checked">
      <description>G2: complex_commands single gated skipped</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G2-Min1SingleGated" level="complex_commands" min="1" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="min=1 makes even a single command complex">
      <description>G2: min=1 single gated checked</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G2-RemoteGatedMix" level="complex_remote" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="complex_remote: curl makes it remote; gated flag suppressed">
      <description>G2: complex_remote gated+remote mix</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; curl -s http://h]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G2-RemoteNoRemote" level="complex_remote" strictness="normal" mock="idx:1,2" in-scope="false" verdict="not_called" effect="none" reason="gated block with no remote indicator => not checked">
      <description>G2: complex_remote skips local-only gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G2-Min3TwoGated" level="complex_commands" min="3" strictness="normal" mock="idx:1,2" in-scope="false" verdict="not_called" effect="none" reason="2 sub-commands &lt; min=3 => not checked">
      <description>G2: min=3 skips 2-command gated block</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G2-AllReadOnly" level="all" mock="idx:1" verdict="modifying" effect="veto" flagged="1" suppressed="" reason="level=all: read_only Get-Date flagged => veto">
      <description>G2: level=all read_only veto</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G2-StrictGatedAgree" level="complex_commands" strictness="strict" mock="idx:1,2" verdict="modifying" effect="agree" reason="strict mode: gated already asks locally => LLM modifying agrees; suppression moot">
      <description>G2: strict mode gated asks, LLM agrees</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>

  </category-group>
```

- [ ] **Step 5: Append G3 fallback + malformed (10) and G4 effects/log (6) to `test-cases.p2.large.xml`**

```xml
  <category-group name="P2G3-FallbackMalformed">

    <test-case expected="ask" category="G3-BareTrueGated" strictness="normal" mock="modifying" verdict="modifying" effect="veto" flagged="" suppressed="" reason="bare true on gated block => unattributed full veto">
      <description>G3: bare true on gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G3-BareFalseGated" strictness="normal" mock="read-only" verdict="read-only" effect="agree" reason="bare false on gated block => agree">
      <description>G3: bare false on gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-Idx0" strictness="normal" mock="idx:0" verdict="modifying" effect="veto" flagged="0" reason="idx:0 => veto">
      <description>G3: idx:0</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-OorIdx" strictness="normal" mock="idx:3" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="index 3 out of range for 2 sub-commands => unusable">
      <description>G3: out-of-range index</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-AlphaIdx" strictness="normal" mock="idx:abc" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="non-JSON idx mock => invalid JSON => unusable">
      <description>G3: alpha index</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-DecimalIdx" strictness="normal" mock="idx:1.5" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="non-integer index => unusable">
      <description>G3: decimal index</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-NegativeIdx" strictness="normal" mock="idx:-1" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="negative index => unusable">
      <description>G3: negative index</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-Garbage" strictness="normal" mock="garbage" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="ramble with no final token => unusable">
      <description>G3: garbage ramble</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-BareTrueReadOnly" mock="modifying" verdict="modifying" effect="veto" reason="bare true on a read_only block => veto (phase-I path preserved)">
      <description>G3: bare true on read_only block</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G3-DisagreeKeptAsk" mock="read-only" verdict="read-only" effect="disagree-kept-ask" reason-contains="Remove-" reason="local ask (Remove-Item) + LLM read-only => stays ask">
      <description>G3: disagree-kept-ask</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Remove-Item c:\temp\x.txt]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="P2G4-EffectsLogReason">

    <test-case expected="allow" category="G4-SuppressedReasonAbsent" strictness="normal" mock="idx:1,2" verdict="modifying" effect="veto-suppressed-policy" reason-not-contains="suppressed" reason="fully-suppressed allow keeps the original local reason (no suppression wording leaks into the prompt)">
      <description>G4: suppressed allow reason unchanged</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G4-VetoReasonAttribution" strictness="normal" mock="idx:1,2" verdict="modifying" effect="veto" reason-contains="curl -o;sub-command 2;suppressed as policy" reason="veto reason names the offender with its index AND lists the suppressed">
      <description>G4: attributed veto reason format</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; curl -o c:\temp\x http://h/y]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G4-LogFieldsMixed" strictness="normal" mock="idx:1,3" verdict="modifying" effect="veto" flagged="1,3" suppressed="1" reason="flagged/suppressed log fields on a mixed block">
      <description>G4: flagged/suppressed fields</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G4-FallbackNoFlagged" strictness="normal" mock="modifying" verdict="modifying" effect="veto" flagged="" suppressed="" reason="unattributed veto leaves flagged/suppressed empty">
      <description>G4: fallback empty fields</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G4-FullPipeSuppressed" mode="fullpipe" strictness="normal" mock="idx:1,2" log-contains="LLM-SENT;LLM-RECV;LLM-RECONCILE;veto-suppressed-policy" reason="fullpipe: suppressed allow + the child hook's .log carries the reconciliation block">
      <description>G4: fullpipe suppressed + .log block</description><tool-name>run_in_terminal</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G4-FullPipeVeto" mode="fullpipe" strictness="normal" mock="idx:1,2" log-contains="LLM-VETO;suppressed as policy" reason="fullpipe: attributed veto + suppression clause in the child hook's .log">
      <description>G4: fullpipe veto + .log clause</description><tool-name>run_in_terminal</tool-name>
      <copilot-command><![CDATA[git add . ; curl -o c:\temp\x http://h/y]]></copilot-command>
    </test-case>

  </category-group>
```

- [ ] **Step 6: Append G5 scope/numbering edges (4) + G6 attributed=false regression (8), close the XML**

```xml
  <category-group name="P2G5-ScopeNumbering">

    <test-case expected="allow" category="G5-RedirectExcluded" strictness="normal" mock="idx:1" in-scope="false" verdict="not_called" effect="none" reason="redirect pseudo-entry is excluded from numbering: 1 real sub-command &lt; min=2 => out of scope">
      <description>G5: redirect not numbered</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . > c:\temp\gitout.txt]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G5-NumberingMaps" strictness="normal" mock="idx:3" verdict="modifying" effect="veto" reason-contains="git status;sub-command 3" reason="index 3 maps to the third sub-command (git status)">
      <description>G5: index-to-command mapping</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x ; git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G5-AstUnwrapNumbering" strictness="normal" mock="idx:1" verdict="modifying" effect="veto-suppressed-policy" flagged="1" suppressed="1" reason="AST-unwrapped inner command (git add inside Invoke-Command) is numbered and tiered correctly">
      <description>G5: AST-unwrapped numbering</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Invoke-Command -ScriptBlock { git add . } ; git status]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G5-UnknownTierVeto" strictness="normal" mock="idx:2" verdict="modifying" effect="veto" flagged="2" suppressed="" reason="unknown command has empty Tier => never suppressible => veto">
      <description>G5: unknown tier vetoes</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; somerandomtool --x]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="P2G6-AttributedOff">

    <test-case expected="ask" category="G6-VetoGated" attributed="false" strictness="normal" mock="modifying" verdict="modifying" effect="veto" reason="switch off: gated block vetoes (phase-I)">
      <description>G6: veto gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G6-AgreeGated" attributed="false" strictness="normal" mock="read-only" verdict="read-only" effect="agree" reason="switch off: agree allow">
      <description>G6: agree gated</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G6-VetoReadOnly" attributed="false" mock="modifying" verdict="modifying" effect="veto" reason="switch off: read_only block vetoes">
      <description>G6: veto read_only</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G6-AgreeAsk" attributed="false" mock="modifying" verdict="modifying" effect="agree" reason="switch off: local ask agrees">
      <description>G6: agree ask</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Remove-Item c:\temp\x.txt]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G6-Down" attributed="false" mock="down" verdict="down" effect="forced-ask" reason-contains="*** LLM-DOWN ***" reason="switch off: down forces ask">
      <description>G6: down</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G6-Unusable" attributed="false" mock="garbage" verdict="unusable" effect="forced-ask" reason-contains="*** LLM-UNUSABLE ***" reason="switch off: garbage forces ask">
      <description>G6: unusable</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date ; Get-ChildItem c:\temp]]></copilot-command>
    </test-case>
    <test-case expected="ask" category="G6-IdxIgnoredWhenOff" attributed="false" strictness="normal" mock="idx:1,2" verdict="modifying" effect="veto" flagged="" suppressed="" reason="CRITICAL: even with indices returned, attributed_verdicts=false means NO suppression - full veto">
      <description>G6: indices ignored when off</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[git add . ; git commit -m x]]></copilot-command>
    </test-case>
    <test-case expected="allow" category="G6-OutOfScope" attributed="false" level="complex_commands" mock="modifying" in-scope="false" verdict="not_called" effect="none" reason="switch off: out of scope unchanged">
      <description>G6: out of scope</description><tool-name>Bash</tool-name>
      <copilot-command><![CDATA[Get-Date]]></copilot-command>
    </test-case>

  </category-group>
</commands>
```

- [ ] **Step 7: Run the large suite — 64/64**

Run: `pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.p2.large.xml`
Expected: PASS — `Total: 64  Passed: 64  Failed: 0` (2 config pre-flights + 12 parser + 50 cases). Also re-verify: small file 24/24, phase-I file 32/32, HTTP 27/27.

- [ ] **Step 8: Commit**

```powershell
git add src/Logger.ps1 test/config/llm-review/test-cases.p2.large.xml
git commit -m "feat: Format-LlmLogBlock reconciliation formatter + 50-case phase-II large suite"
```

---

### Task 6: Live suite — 2 attributed cases (real gateway, user-run)

**Files:**
- Modify: `test/config/llm-review/http/Run-LlmLiveTests.ps1` (`expect-indices` attr, `subcommands` attr, `AttributedVerdicts` in llmCfg)
- Modify: `test/config/llm-review/http/test-llm-live.xml` (+2 cases)

- [ ] **Step 1: Live runner — attributed support**

In `test/config/llm-review/http/Run-LlmLiveTests.ps1`:

(a) In the `$llmCfg = [PSCustomObject]@{ ... }` literal, add after `ComplexMinSubcommands = 2,`:

```powershell
    AttributedVerdicts      = $true
```

(b) In the direct-mode section, after resolving `$command`, add:

```powershell
    $subCmds = @()
    if ($tc.HasAttribute('subcommands')) { $subCmds = @($tc.GetAttribute('subcommands') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
```

(c) Replace the direct-mode call `$verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg` with:

```powershell
            $verdict = Get-LlmReviewVerdict -Command $command -LlmConfig $llmCfg -SubCommands $subCmds
```

(d) After the existing `$ok = ($verdict.Verdict -eq $expectVerdict)` line, add the indices assertion:

```powershell
    if ($ok -and $tc.HasAttribute('expect-indices')) {
        $got = if ($verdict.Indices) { ($verdict.Indices -join ',') } else { '' }
        $ok = ($got -eq $tc.GetAttribute('expect-indices'))
    }
```

Also append the indices to the LIVE print line so you can watch them: change the `Write-Host "LIVE [$name] verdict=..."` line to include `indices='...'`:

```powershell
    $idxShown = if ($verdict.Indices) { ($verdict.Indices -join ',') } else { '' }
    Write-Host "LIVE [$name] verdict=$($verdict.Verdict) indices='$idxShown' latency=$($verdict.LatencyMs)ms raw='$($verdict.Raw)'$(if ($verdict.Recovered) {' (recovered)'})$(if ($ok) {' - OK'} else { " - WRONG (wanted $expectVerdict)" })"
```

- [ ] **Step 2: Add the 2 live cases**

Append to `test/config/llm-review/http/test-llm-live.xml` inside the `LlmLive` category-group:

```xml
    <test-case name="Live-Attr-EmptyIdx" subcommands="aws s3 ls;kubectl get pods" expect-verdict="read-only">
      <description>attributed live: two read-only remote commands => LLM returns {"modifying":[]} (verdict read-only)</description>
      <copilot-command><![CDATA[aws s3 ls && kubectl get pods]]></copilot-command>
    </test-case>

    <test-case name="Live-Attr-MixedIdx" subcommands="aws s3 ls;aws s3 cp file.txt s3://bucket/key" expect-verdict="modifying" expect-indices="2">
      <description>attributed live: mixed block => LLM flags exactly index 2 (measures the model's index compliance)</description>
      <copilot-command><![CDATA[aws s3 ls && aws s3 cp file.txt s3://bucket/key]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Offline verify (no quota)**

Parse-check only: `powershell.exe -NoProfile -Command "$t=$null; $e=$null; $null = [System.Management.Automation.Language.Parser]::ParseFile('test/config/llm-review/http/Run-LlmLiveTests.ps1', [ref]$t, [ref]$e); if ($e.Count) { $e | ForEach-Object { $_.Message } } else { 'PARSE OK' }"` → `PARSE OK`. Validate the XML loads: `pwsh -NoProfile -Command "[xml](Get-Content test/config/llm-review/http/test-llm-live.xml) | Out-Null; 'XML OK'"` → `XML OK`.

The live run itself (`Run-LlmLiveTests.ps1`, now 7 cases) is USER-RUN — the model's index compliance decides whether production keeps `attributed_verdicts: true` or flips to `false`.

- [ ] **Step 4: Commit**

```powershell
git add test/config/llm-review/http/Run-LlmLiveTests.ps1 test/config/llm-review/http/test-llm-live.xml
git commit -m "test: 2 attributed live cases + live-runner attributed support"
```

---

### Task 7: Root config key + POC parity + docs + final regression

**Files:**
- Modify: `config.json`
- Modify: `C:\git\cc\deepseek-tester\api-gateway-caller.ps1`
- Modify: `docs/config-json-guide.md`, `README.md`, `test/config/llm-review/README.md`, `PROGRESS.md`

- [ ] **Step 1: Root config key**

In root `config.json`'s `llm_second_opinion` block, after `"complex_min_subcommands": 2` add:

```json
    "attributed_verdicts": true,
```

NOTE for the executor: root `config.json` also carries the user's pending live-state edits (enabled:true, deepseek-v4-flash, timeout 30000, strict). The commit of this file will include them — the user was informed (that state is live and intentional). Do NOT run Sync-Fixtures (its guard correctly refuses while the LLM is enabled / strictness is non-normal).

- [ ] **Step 2: POC v2 prompt parity**

In `C:\git\cc\deepseek-tester\api-gateway-caller.ps1`:

(a) Replace the default `$SystemPrompt` here-string with the `$script:LlmSystemPromptV2` text from `src/LlmReview.ps1` (copy verbatim).

(b) Add an optional parameter after `$CommandBlock`:

```powershell
    [Parameter(Mandatory = $false)]
    [string[]]$SubCommands,
```

(c) Replace the user-message assembly `$Prompt = "<command_block>`n$CommandBlock`n</command_block>"` with:

```powershell
# V2 shape: raw block + optional numbered sub-command list (parity with
# src/LlmReview.ps1 Get-LlmReviewVerdict's attributed mode).
$Prompt = "<command_block>`n$CommandBlock`n</command_block>"
if ($SubCommands -and $SubCommands.Count -gt 0) {
    $numbered = @()
    for ($i = 0; $i -lt $SubCommands.Count; $i++) { $numbered += "{0}. {1}" -f ($i + 1), $SubCommands[$i] }
    $Prompt += "`n<sub_commands>`n" + ($numbered -join "`n") + "`n</sub_commands>"
}
```

(d) Extend the layered parser: in the JSON branch, before the verdict-ish keys loop, add the attributed form (non-empty array => 'true', empty => 'false', invalid => 'unusable'):

```powershell
            if ($obj.PSObject.Properties.Name -contains 'modifying') {
                $m = $obj.modifying
                if ($null -eq $m) { $decision = 'false' }
                elseif ($m -isnot [System.Collections.IList]) { $decision = 'unusable' }
                elseif ($m.Count -eq 0) { $decision = 'false' }
                else { $decision = 'true' }
                $parsedJson = $true
            }
```

(Place it inside the `try { $obj = ... }` block right after `ConvertFrom-Json` succeeds and before the `foreach ($key in ...)` loop; also set `$parsedJson = $true` so the last-line rescue is skipped. The `.SYNOPSIS` already mentions the third state; update it to mention the attributed JSON form.)

(e) Parse-check: same Parser::ParseFile one-liner as Task 6 Step 3 against the POC path → `PARSE OK`. No gateway call (user's quota).

- [ ] **Step 3: Docs**

- `docs/config-json-guide.md` §10.5: add `attributed_verdicts` to the field table (bool, default true; `false` = phase-I binary contract, no suppression); add a "Phase II — attributed verdicts + policy suppression" subsection: the `{"modifying":[indices]}` contract, index 0 semantics, the suppression matrix (gated=suppress via `Test-GatedInvocationSafe`, read_only/unknown/0/unattributed=veto), the `veto-suppressed-policy` effect, the reconciliation `.log` block (SENT/RECV/LOCAL/RECONCILE), and the per-run test-log location (`c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-*.log`).
- `README.md`: extend the `llm_second_opinion` paragraph with one sentence on attributed verdicts + gated suppression + reconciliation logging.
- `test/config/llm-review/README.md`: document the two phase-II files (small = default, large = opt-in), the new XML attributes (`strictness`, `attributed`, `flagged`, `suppressed`, `reason-not-contains`, `log-contains`), and the per-run reconciliation log path.
- `PROGRESS.md`: phase-II completion entry (tasks T1–T7, suites green, live pending user run).

- [ ] **Step 4: Final full regression**

Run: small 24/24, large 64/64, phase-I file 32/32, HTTP 27/27, Run-AllTests 962/962, sandbox 938/938, codex 17/17.

- [ ] **Step 5: Commit**

```powershell
git add config.json docs/config-json-guide.md README.md test/config/llm-review/README.md PROGRESS.md
git commit -m "feat: attributed_verdicts in live config + phase-II docs"
git -C C:\git\cc\deepseek-tester status --short   # POC repo is not git-tracked; file saved only
```

---

## Self-review notes (completed by plan author)

- **Spec coverage:** P1 (indices→T3/T4), P2 (same list: scope `SubCommands`→T4 Steps 3,5b), P3 (index 0: parser T3, merge T4, cases P2-IdxZeroVeto/G1-Flag0/G3-Idx0), P4 (suppression matrix + guard hook T4 Step 4; G1-SetContentGated documents the stage-1 path gap), P5 (bare fallback: parser layer 1, merge `elseif`, G1-BareTrue/G3-BareTrueGated/G6-IdxIgnoredWhenOff), P6 (no config shipping — V2 prompt adds only the numbered list), P7 (stats purity: `flagged`/`suppressed`/`veto-suppressed-policy` in logs, verdict untouched), P8 (small=default/large=opt-in/phase-I file untouched), P9 (runner `Write-CaseLog` T1 Step 4 + shared `Format-LlmLogBlock` T5 + fullpipe `log-contains` G4). Sections: 3 (prompt→T3 Step 1), 4 (parser→T3 Step 2), 5 (tier→T4 Steps 1-2), 6 (merge→T4 Step 5), 7 (logger→T5), 8 (config→T2 + T7 Step 1), 9 (mocks→T3 Step 4), 10 (testing→T1 + T5 + T6), 11 (errors→G3 cases), 12 (risks→G6 + live cases), 14 (components→all tasks).
- **Placeholder scan:** every code step contains complete code; every XML case is fully written; expected run outputs are stated per step.
- **Type consistency:** `Indices`/`Mocked` fields flow verdict→log identically in T3/T4; `Tier` values (`read_only`/`strictness_gated`/`modifying`/`''`) match between T4 annotation and the merge's suppression check; runner attribute names (`strictness`/`attributed`/`flagged`/`suppressed`/`log-contains`/`reason-not-contains`) match between T1 runner code and the XML; `AttributedVerdicts` compiled field matches between T2 ConfigLoader and T3/T4 consumers (null-safe: absent = falsy = phase-I path for hand-built configs).
- **Known executor notes:** (a) `ConvertFrom-Json` on PS5.1 returns `Object[]` for arrays — `IList` check covers it. (b) The runner's per-case `Add-Member -Force AttributedVerdicts` works on both the TDD stub and the real compiled block. (c) G4 fullpipe cases rely on the runner's `strictness` temp-config copy (T1 Step 6). (d) `New-Verdict`/`Test-ModifyingArray` are nested helper functions inside `ConvertTo-LlmVerdict` — PowerShell allows nested function definitions; keep them inside the function body.
