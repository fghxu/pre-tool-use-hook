# =============================================================================
# Run-Tests.ps1 - llm_second_opinion fixture runner
# =============================================================================
#
# WHAT THIS FILE IS
#   The dedicated test suite for the llm_second_opinion feature (the
#   second-opinion LLM cross-check). It is deliberately SEPARATE from the main
#   suites (src/Run-AllTests.ps1, ~1000 cases): this suite runs in seconds and
#   NEVER calls the LLM, so it burns zero quota.
#
# HOW TO RUN
#   From the repo root:
#       pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1
#   Exit code 0 = all green. Exit code 1 = at least one check failed.
#
# HOW TO READ THE OUTPUT
#   - Silence = passing. Only failures print, as:
#         FAIL [<check-name>]
#           <one line: command, expected vs got, and why it failed>
#   - At the end a summary prints:  Total / Passed / Failed  and the list of
#     failed check names (empty list = everything green).
#   - Expected healthy state:  Total: 25  Passed: 25  Failed: 0
#
# THE 25 CHECKS, IN THREE GROUPS
#   1. Pre-flight (7 checks, no XML):
#      - LlmConfig-BadLevel : config.badlevel.json has level="bogus";
#        Load-Config MUST throw (proves config validation is fail-closed).
#      - LlmParser-* (6)    : unit checks for ConvertTo-LlmVerdict, the layered
#        parser that turns raw LLM text into modifying|read-only|unusable.
#   2. XML classify cases (16 checks, mode=classify, the default):
#      Each <test-case> in test-cases.xml is run IN-PROCESS: the command goes
#      through Invoke-Classify (the real local engine) and then Invoke-LlmReview
#      (the real merge), with the LLM verdict INJECTED by an environment
#      variable instead of an HTTP call.
#   3. XML fullpipe cases (2 checks, mode="fullpipe"):
#      The same idea but through the REAL hook process: we spawn src/Hook.ps1
#      as a child process, pipe a fake IDE payload to its stdin, and validate
#      the JSON it prints. This proves the end-to-end wiring (dot-sourcing,
#      the enabled gate, the merge, the output format, exit code 0).
#
# THE NO-NETWORK GUARANTEE (why this costs no quota)
#   Get-LlmReviewVerdict (in src/LlmReview.ps1) checks the env var
#   PRETOOLHOOK_LLMREVIEW_MOCK FIRST. If set to:
#       modifying  -> behaves as if the LLM answered "modifying" (raw 'true')
#       read-only  -> behaves as if the LLM answered "read-only" (raw 'false')
#       garbage    -> behaves as if the LLM rambled nonsense (parser => unusable)
#       down       -> behaves as if the LLM server were unreachable
#   ...and returns WITHOUT any HTTP call. Every XML case that would reach the
#   LLM sets one of these; out-of-scope cases never reach the call at all.
#
# PER-CASE XML ATTRIBUTES (what you can set on a <test-case>)
#   expected         allow|ask (required) - the final decision we assert
#   category         unique check name (required) - printed on failure
#   reason           free text shown on failure (documentation)
#   level            all|complex_commands|complex_remote (default complex_remote)
#   min              complex_min_subcommands override (default 2)
#   enabled          true|false (default true) - feature on/off for this case
#   mock             modifying|read-only|garbage|down (unset = env var cleared)
#   in-scope         true|false - asserted against Log.in_scope (optional)
#   verdict          asserted against Log.verdict (optional)
#   effect           asserted against Log.effect (optional)
#   reason-contains  substring asserted on the final Reason text (optional)
#   mode             classify (default) | fullpipe (spawns src/Hook.ps1)
#
# Spec: docs/superpowers/specs/2026-08-01-llm-second-opinion-design.md
# Run from repo root:  pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1
# Wait-Debugger

param(
    # Default = the phase-II small file (fast typical pass). Point at
    # test-cases.xml (phase-I) or test-cases.p2.large.xml (opt-in matrix).
    [string]$XmlPath = "$PSScriptRoot\test-cases.p2.small.xml"
)

# Stop on any unexpected error - a broken runner must not masquerade as green.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths. $PSScriptRoot = the folder this file lives in (test/config/llm-review).
# src/ is three levels up (test/config/llm-review -> repo root -> src).
# ---------------------------------------------------------------------------
$fixtureDir = $PSScriptRoot
$srcDir     = Join-Path $fixtureDir "..\..\..\src"
$hookPath   = Join-Path $srcDir "Hook.ps1"        # spawned by fullpipe cases
$configPath = Join-Path $fixtureDir "config.json" # this fixture's own config

# ---------------------------------------------------------------------------
# Dot-source the REAL engine modules (same files the production hook uses).
# This loads their functions into this script's scope:
#   ConfigLoader.ps1 -> Load-Config (JSON config -> validated+compiled object)
#   Parser.ps1       -> command splitting / domain detection / AST helpers
#   Resolver.ps1     -> per-command pattern matching against the config
#   HookAdapter.ps1  -> IDE detection + input extraction + output shaping
#   Classifier.ps1   -> Invoke-Classify, the full local classification pipeline
# ---------------------------------------------------------------------------
. (Join-Path $srcDir "ConfigLoader.ps1")
. (Join-Path $srcDir "Parser.ps1")
. (Join-Path $srcDir "Resolver.ps1")
. (Join-Path $srcDir "HookAdapter.ps1")
. (Join-Path $srcDir "Classifier.ps1")

# ---------------------------------------------------------------------------
# Dot-source the feature under test, IF it exists.
# TDD scaffold: while LlmReview.ps1 does not exist (red phase), classify cases
# fail with a clear "not loaded" reason instead of crashing the whole run.
# ---------------------------------------------------------------------------
$LlmReviewLoaded = $false
if (Test-Path (Join-Path $srcDir "LlmReview.ps1")) {
    . (Join-Path $srcDir "LlmReview.ps1")
    $LlmReviewLoaded = $true
}

# ---------------------------------------------------------------------------
# Load the fixture config through the REAL loader (validation + compilation).
# After this, $config._compiled.llmSecondOpinion holds the normalized feature
# block the scope engine reads (Enabled / Level / RemoteIndicators / ...).
# ---------------------------------------------------------------------------
$config = Load-Config -Path $configPath

# Baseline global strictness from the fixture file; each case may override it
# via its strictness= attribute and is reset to this afterwards.
$fileStrictness = $config.global_modifying_strictness

# Per-run reconciliation log (spec P9): every case appends its outcome plus
# the shared LLM reconciliation block here, so a run leaves the same evidence
# a production call would. Lives beside the fullpipe hook logs (c:\temp).
$runLogDir = if ($config.log_file_path) { $config.log_file_path } else { 'c:\temp\pretoolhook-llm-review-testlogs\' }
if (-not (Test-Path $runLogDir)) { New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null }
$runLogPath = Join-Path $runLogDir ('llm-review-run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

# ---------------------------------------------------------------------------
# TDD scaffold: if the loader does not yet compile the block (red phase),
# create a stub so the per-case override lines in the loop below have a
# non-null object to set properties on. Enabled=$false here is irrelevant -
# every case sets Enabled/Level/ComplexMinSubcommands explicitly anyway.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Pick the PowerShell executable used to spawn Hook.ps1 in fullpipe cases.
# Same family as the current process: pwsh (7+) runs pwsh, Windows PowerShell
# (5.1) runs powershell.exe - so the hook is exercised under the same engine.
# ---------------------------------------------------------------------------
$engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

# ---------------------------------------------------------------------------
# Load the XML suite. Structure:
#   <commands> -> <category-group> (3 groups: LlmScope, LlmMerge, LlmFullPipe)
#   -> <test-case> elements. The @(...) forces an array even for one case.
# ---------------------------------------------------------------------------
[xml]$xml = Get-Content $XmlPath -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# Counters + failure list for the end-of-run summary.
$total = 0; $passed = 0; $failed = 0; $failures = @()

# ---------------------------------------------------------------------------
# Record-Result - the one place every check reports through.
#   -Ok $true  : silent pass (only counted).
#   -Ok $false : prints FAIL [<Name>] + a detail line immediately, and the name
#                is collected for the end-of-run failed list.
# $script: is required because functions get their own scope by default.
# ---------------------------------------------------------------------------
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

# =============================================================================
# PRE-FLIGHT CHECK 1 of 7 - LlmConfig-BadLevel
# config.badlevel.json is identical to config.json EXCEPT level="bogus".
# Load-Config MUST throw, and the message must name llm_second_opinion.level.
# Why: an unknown level is a config typo that would silently change behavior;
# the loader must reject it fail-closed (same philosophy as the legacy-key
# guard). "Did NOT throw" and "threw with the wrong message" are both failures.
# =============================================================================
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badlevel.json")
    Record-Result -Ok $false -Name "LlmConfig-BadLevel" -Detail "Load-Config did NOT throw for level='bogus'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_second_opinion\.level'
    Record-Result -Ok $ok -Name "LlmConfig-BadLevel" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# ---- Pre-flight: bad attributed_verdicts type must be rejected (Task 2) ----
try {
    $null = Load-Config -Path (Join-Path $fixtureDir "config.badtype.json")
    Record-Result -Ok $false -Name "LlmConfig-BadType" -Detail "Load-Config did NOT throw for attributed_verdicts='yes'"
}
catch {
    $ok = $_.Exception.Message -match 'llm_second_opinion\.attributed_verdicts'
    Record-Result -Ok $ok -Name "LlmConfig-BadType" -Detail "threw but unexpected message: $($_.Exception.Message)"
}

# =============================================================================
# PRE-FLIGHT CHECKS 2-7 - LlmParser-* (ConvertTo-LlmVerdict unit checks)
# The layered parser (spec section 5.3) turns RAW LLM text into a verdict:
#   layer 1: the whole response is exactly 'true'/'false'      -> verdict
#   layer 2: the response is JSON with a verdict-ish key       -> verdict
#   layer 3: the LAST non-empty line is 'true'/'false'         -> verdict,
#            flagged Recovered (the model rambled, we salvaged the answer)
#   layer 4: anything else                                     -> 'unusable'
#            (a distinct state - garbage is NEVER read as "modifying")
# Each case pins one layer, plus case/whitespace tolerance and empty input.
# The guard keys on the FUNCTION existing (not the file) so a partial module
# still shows these as red during TDD.
# =============================================================================
$parserCases = @(
    # Layer 1: clean bare token, lower case.
    @{ Name = 'LlmParser-BareTrue';      Raw = 'true';                                 WantVerdict = 'modifying'; WantRecovered = $false },
    # Layer 1 with noise tolerance: uppercase + surrounding whitespace/newline.
    @{ Name = 'LlmParser-BareFalseCase'; Raw = "  FALSE`n";                            WantVerdict = 'read-only'; WantRecovered = $false },
    # Layer 2: a JSON object carrying the verdict (future gateways / JSON mode).
    @{ Name = 'LlmParser-Json';          Raw = '{"verdict":"modifying"}';              WantVerdict = 'modifying'; WantRecovered = $false },
    # Layer 3: reasoning text, but the final line is a bare token -> salvaged.
    @{ Name = 'LlmParser-LastLine';      Raw = "reasoning about the command`nfalse";   WantVerdict = 'read-only'; WantRecovered = $true },
    # Layer 4: pure ramble with no final token -> unusable, NOT "modifying".
    @{ Name = 'LlmParser-Garbage';       Raw = 'I think this is safe but I am unsure'; WantVerdict = 'unusable';  WantRecovered = $false },
    # Layer 4 edge: empty response -> unusable.
    @{ Name = 'LlmParser-Empty';         Raw = '';                                     WantVerdict = 'unusable';  WantRecovered = $false },
    # JSON attributed layer (phase II): valid index list -> attributed modifying
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
)
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

# =============================================================================
# MAIN LOOP - the 16 XML cases
# Each case either runs fully in-process (mode=classify, the default) or
# through a real child hook process (mode=fullpipe). Per-case attributes reset
# the feature config and the mock env var BEFORE the case runs.
# =============================================================================
foreach ($tc in $testCases) {
    # Human-readable check name (printed on failure) + execution mode.
    $name = $tc.category
    $mode = if ($tc.HasAttribute('mode')) { $tc.GetAttribute('mode') } else { 'classify' }
    $reasonContains = if ($tc.HasAttribute('reason-contains')) { $tc.GetAttribute('reason-contains') } else { $null }

    # ------------------------------------------------------------------
    # Extract the command text. <copilot-command> usually wraps it in CDATA
    # (so commands may contain <, >, &, quotes). InnerText unwraps CDATA;
    # the string fallback covers a plain-text node.
    # ------------------------------------------------------------------
    $cmdNode = $tc.'copilot-command'
    if ($cmdNode -is [System.Xml.XmlElement]) { $command = $cmdNode.InnerText } else { $command = "$cmdNode" }
    $command = $command.Trim()

    # ------------------------------------------------------------------
    # Tool name the fake IDE payload claims (Bash by default; fullpipe cases
    # use run_in_terminal - both are in the fixture's intercept list).
    # ------------------------------------------------------------------
    $toolName = "Bash"
    $toolNameNode = $tc.SelectSingleNode('tool-name')
    if ($toolNameNode -and $toolNameNode.InnerText.Trim()) { $toolName = $toolNameNode.InnerText.Trim() }

    # ------------------------------------------------------------------
    # Arm the mock: the LLM verdict this case wants injected. Unset attribute
    # means CLEAR the env var (paranoia: never leak one case's mock into the
    # next). With no mock set, an in-scope case WOULD attempt a real HTTP
    # call - which fails the case and thereby flags the authoring mistake.
    # ------------------------------------------------------------------
    if ($tc.HasAttribute('mock')) { $env:PRETOOLHOOK_LLMREVIEW_MOCK = $tc.GetAttribute('mock') }
    else { Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue }

    # ==================================================================
    # MODE: fullpipe - spawn the REAL hook as a child process
    # Proves end-to-end wiring that in-process tests cannot:
    #   Hook.ps1 dot-sources LlmReview.ps1, the enabled gate fires,
    #   PRETOOLHOOK_CONFIG_PATH points the child at THIS fixture config,
    #   the merge changes the decision JSON on stdout, exit code stays 0
    #   (a decision was produced; exit 2 would mean a fatal hook error).
    # The payload mimics a VS Code Copilot preToolUse event (camelCase
    # event name, epoch-ms timestamp, no tool_use_id).
    # ==================================================================
    if ($mode -eq 'fullpipe') {
        # Build the one-line JSON payload the IDE would write to the hook's stdin.
        $payload = (@{
            tool_name       = $toolName
            tool_input      = @{ command = $command }
            hook_event_name = 'preToolUse'
            timestamp       = '1790000000000'
        } | ConvertTo-Json -Compress -Depth 5)

        # Point the child at the fixture config (production default is the
        # repo-root config.json) and hand it the mock verdict via inheritance.
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

        # Pipe the payload to the child's stdin; capture stdout (the decision
        # JSON). stderr is discarded (the hook only writes warnings there).
        $stdout = $payload | & $engine -NoProfile -File $hookPath 2>$null
        $exitCode = $LASTEXITCODE

        # Clean up env vars immediately so later cases / the parent shell
        # are unaffected.
        Remove-Item Env:\PRETOOLHOOK_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

        # Assert: stdout parses as JSON, permissionDecision matches expected,
        # exit code is 0, and (if asked) the reason carries the eye-catch text.
        try {
            $out = $stdout | ConvertFrom-Json -ErrorAction Stop
            $decision = $out.hookSpecificOutput.permissionDecision
            $reason   = "$($out.hookSpecificOutput.permissionDecisionReason)"
            $ok = ($decision -eq $tc.expected) -and ($exitCode -eq 0)
            $detail = "cmd: $command | expected $($tc.expected)+exit0 got $decision+exit$exitCode | reason: $reason"
            if ($ok -and $reasonContains) {
                foreach ($want in ($reasonContains -split ';')) {
                    if (-not $reason.Contains($want.Trim())) { $ok = $false; $detail += " | reason missing '$($want.Trim())'" }
                }
            }
            if ($ok -and $tc.HasAttribute('log-contains')) {
                # Read the child hook's .log (fixture log_file_path dir) and
                # require every semicolon-separated marker in the newest entry.
                $latestLog = Get-ChildItem (Join-Path $runLogDir '*.log') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $tail = (Get-Content $latestLog.FullName -Tail 40) -join "`n"
                foreach ($marker in ($tc.GetAttribute('log-contains') -split ';')) {
                    if (-not $tail.Contains($marker.Trim())) { $ok = $false; $detail += " | log missing '$($marker.Trim())'" }
                }
            }
            Record-Result -Ok $ok -Name $name -Detail $detail
            Write-CaseLog -Name $name -Ok $ok -Result $null -LlmLog $null -Mode 'fullpipe'
        }
        catch {
            Record-Result -Ok $false -Name $name -Detail "cmd: $command | stdout not JSON: $stdout"
        }
        continue
    }

    # ==================================================================
    # MODE: classify (default) - in-process classify + merge
    # ==================================================================

    # ------------------------------------------------------------------
    # Per-case feature-config overrides. We mutate the COMPILED block
    # directly (same object Test-LlmReviewScope reads) - equivalent to
    # editing config.json for just this one case. Every case sets all three,
    # so there is no cross-case leakage even though the object is shared.
    # ------------------------------------------------------------------
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

    # Build the minimal fake IDE input: the shape HookAdapter expects after
    # tool_name_mapping ("Bash" -> tool_input.command in the fixture config).
    $rawInput = [PSCustomObject]@{
        tool_name  = $toolName
        tool_input = [PSCustomObject]@{ command = $command }
    }

    # ------------------------------------------------------------------
    # Run the REAL local classification, then mirror the Hook.ps1 Step 8b
    # gate exactly: only when the feature is enabled, call Invoke-LlmReview
    # and take its (possibly modified) result + the log object.
    # Any throw becomes Decision="error" so a single broken case cannot
    # abort the whole suite (and counts as a failure via mismatch).
    # ------------------------------------------------------------------
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

    # Disarm the mock right after the call (belt-and-braces cleanup).
    Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------
    # ASSERTIONS, in a chain - each only runs if all previous held, and the
    # first failure short-circuits the rest:
    #   1. decision         : final Decision == expected (allow|ask)
    #   2. reason-contains  : final Reason carries the eye-catch marker
    #   3. in-scope         : the scope engine's verdict (from the Log object;
    #                         no Log at all counts as in_scope=$false - that is
    #                         what a disabled feature looks like)
    #   4. verdict          : which LLM answer was seen (modifying|read-only|
    #                         unusable|down|not_called)
    #   5. effect           : what the merge did (veto|agree|disagree-kept-ask|
    #                         forced-ask|none)
    # ------------------------------------------------------------------
    $ok = ($result.Decision -eq $tc.expected)
    $detail = "cmd: $command | expected $($tc.expected) got $($result.Decision) | reason: $($result.Reason)"

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
    Record-Result -Ok $ok -Name $name -Detail $detail
    Write-CaseLog -Name $name -Ok $ok -Result $result -LlmLog $llmLog -Mode 'classify'
}

# Final cleanup: never leave the mock armed in the caller's environment.
Remove-Item Env:\PRETOOLHOOK_LLMREVIEW_MOCK -ErrorAction SilentlyContinue

# =============================================================================
# SUMMARY - totals always print; the failed list prints only when non-empty.
# Exit 0 = all green, exit 1 = at least one failure (CI-friendly).
# =============================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "LLM-Review Fixture Run Complete"
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
Write-Host "Run log: $runLogPath"
if ($failures.Count -gt 0) {
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $($f.Name)" -ForegroundColor Red }
}
Write-Host "========================================"
if ($failed -gt 0) { exit 1 } else { exit 0 }
