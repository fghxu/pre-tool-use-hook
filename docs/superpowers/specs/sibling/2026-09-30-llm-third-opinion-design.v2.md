# Design: LLM Third-Opinion Pair Comparison — Architecture & Implementation Contract

**Date:** 2026-09-30
**Status:** APPROVED FOR IMPLEMENTATION (TDD: write the RED tests first)
**Spec (the contract, wins on any conflict):** `docs/superpowers/specs/2026-09-30-llm-third-opinion-spec.md`
**Audience:** a coder who has NEVER touched this repo. Everything needed to implement is here; you
also read the project source — this doc tells you exactly what to read and exactly what to change.
**Feature name:** `llm_third_opinion` ("LLM2", "the pair"). LLM1 = the existing `llm_second_opinion`.

---

## 1. Context primer (what exists today — read these files first)

The repo is a **PreToolUse safety hook** (PowerShell). An IDE (Claude Code / Copilot / Codex / DSH)
pipes every tool call into `src/Hook.ps1`, which classifies the command `allow` (run silently) or
`ask` (prompt the human). Relevant source files (all dot-sourced into ONE scope by the entry
points — they share functions and `$script:` state freely):

| File | Role |
|---|---|
| `src/Hook.ps1` | Entry point. Loads config, classifies, runs the LLM cross-check (Step 8b), timeout caps (Step 10), logging. |
| `src/ConfigLoader.ps1` | `Load-Config` validates `config.json` and compiles hot-path objects into `$config._compiled.*`. Throws on any schema error (config error = hook exit 2 = EVERY command blocked, so validation must be exactly right). |
| `src/Classifier.ps1` | Local (offline) classification engine. Produces `$ClassifyResult` with `.Decision` (`allow`/`ask`), `.Reason`, `.SubResults` (each with `.Tier`, `.Command`, optional `.DisplayText`). |
| `src/LlmReview.ps1` | The LLM cross-check feature (LLM1). Functions: `Test-LlmReviewScope` (scope gate), `ConvertFrom-BalancedJsonObject` + `ConvertTo-LlmVerdict` (layered response parser), `Get-LlmReviewVerdict` (mock short-circuit + synchronous `Invoke-RestMethod` call), `Test-GatedInvocationSafe` (stage-2 path guard), `Invoke-LlmReview` (orchestrator: scope → verdict → merge → log object). |
| `src/Logger.ps1` | `Format-LlmLogBlock` (human-readable multi-line LLM evidence block), `Write-LogEntry` (.log), `Write-RecordEntry` (.records.jsonl — embeds the ENTIRE llm log object as the `llm` field of each JSON line). |
| `test/config/llm-review/Run-Tests.ps1` | The ONLY harness that can test LLM machinery (the generic XML TestRunner never loads LlmReview.ps1). Params: `-XmlPath`, `-ConfigPath`, `-Cwd`. Per-XML-case attributes: `mock`, `mode` (classify|fullpipe), `config`, `decision`, `reason-contains`, `sent-contains`, `subresult-tier`, ... It runs cases **in-process** (classify mode) or spawns the real `Hook.ps1` (fullpipe mode). |
| `src/Run-AllTests.ps1` | Registers "extra suites" run by the llm-review fixture runner: see `$extraSuites` (~line 91) — the `script-drilldown.llm` entry is the template for this feature's suite. |

### 1.1 Today's LLM1 flow inside `Invoke-LlmReview` (annotated; line numbers ≈ current HEAD)

```
 $llm = $Config._compiled.llmSecondOpinion          # $null when block absent -> feature off
 scope = Test-LlmReviewScope ...                    # level gate: 'all' | 'complex_commands' |
                                                    # 'complex_remote' (+ check_blindspot rescue:
                                                    # sets CheckBlindspotTier when out of scope but
                                                    # a sub-command tier is unknown)
 if in_scope AND NOT blindspot AND all subs in {trusted_program, editable_path, editable_delete}:
     effect='llm-skipped-trusted-editable'; return  # R2 pre-skip (trusted/editable are locally
                                                    # authoritative; the LLM cannot change anything)
 $subTexts = numbered sub-command list              # ALSO the LLM prompt list
 if (-not $scope.InScope) { return }                # out of scope: one-liner log only
 $verdict = Get-LlmReviewVerdict ...                # mock env short-circuit, else sync IRM call,
                                                    # then ConvertTo-LlmVerdict -> {Verdict, Raw,
                                                    # LatencyMs, Recovered, Error, Indices, Mocked}
 if blindspot:                                      # CHECK_BLINDSPOT NEVER changes the decision;
     enrich reason with LLM per-sub verdict; return # local ask stays ask
 switch ($verdict.Verdict) {
   'modifying'  -> veto or suppress per local tier  # trusted_program/editable_path/editable_delete/
                                                    # safe-gated flags SUPPRESSED (veto-suppressed-
                                                    # policy); any surviving flag => ask + veto reason
   'read-only'  -> agree / disagree-kept-ask        # LLM never downgrades a local ask
   'down'       -> forced ask "*** LLM-DOWN ***"
   'unusable'   -> forced ask "*** LLM-UNUSABLE ***"
 }
 return @{ Result; Log }                            # Log -> Format-LlmLogBlock + records.jsonl
```

### 1.2 Today's log block (produced by `Format-LlmLogBlock`)

```
  LLM-SENT      : [ 2 subcommand ] | model=claude-opus-4.7 timeout=30000ms | [1] Get-Date | [2] Get-Process
  LLM-RECV      : '…raw response…' (5150ms, recovered=True) -> verdict=read-only
  LLM-LOCAL     : decision=allow (read-only); tiers: [1]=read_only [2]=read_only
  LLM-RECONCILE : agree -> FINAL: allow
```

---

## 2. Feature overview

Send the **identical prompt** to a **second endpoint** in parallel, compare the parsed verdicts,
and:

- **disagree** → `ask` (unconditionally, before any policy suppression);
- **agree** or **LLM2 failed** → proceed with today's behavior driven by LLM1's verdict;
- **LLM1 failed** → today's fail-closed ask, LLM2's verdict appended as a non-authoritative FYI.

```mermaid-ish ASCII — decision flow (new/changed parts marked *)

 Hook.ps1 Step 8b
   ├─ llm1 enabled? ──no──> llm2 enabled? ──yes──> *skip-note log (no LLM calls)*   [D3]
   │                                └─no──> (today: nothing)
   └─ yes: Invoke-LlmReview
        ├─ scope gate (LLM1's config decides for the PAIR)                          [D1]
        │     └─ out of scope ──> one-liner log; *llm2.compare='out-of-scope'*      [D13]
        ├─ R2 pre-skip (all trusted/editable) ──> skip pair too;                    [D14]
        │     *reconcile note "(pair skipped — comparison not applicable)";
        │      llm2.compare='skipped-trusted-editable'*
        ├─ *pair armed? (llm_third_opinion.enabled)*
        │     ├─ no  ──> today's SYNCHRONOUS LLM1 path (byte-identical)             [D10]
        │     └─ yes ──> *PARALLEL PAIR*
        │           ├─ mocks? both evaluated synchronously (MOCK2→fallback MOCK)    [D12]
        │           ├─ else: build ONE prompt; two bodies (model/uri/key differ);
        │           │       two [powershell] runspaces; BeginInvoke both;
        │           │       EndInvoke both; parse both (ConvertTo-LlmVerdict)       [D10]
        │           ├─ COMPARE raw parsed verdicts (token + index set)              [D4/D5]
        │           │     ├─ DISAGREE ──> *** LLM-DISAGREE *** ask. effect=
        │           │     │            'llm2-disagree'. compare='disagree'. DONE
        │           │     ├─ agree    ──> fall through, LLM1 verdict drives merge  [D6]
        │           │     └─ llm2 down/unusable -> fall through (LLM1 only),
        │           │                   compare='llm2-down'                        [D7]
        │           └─ llm1 down/unusable -> today's forced ask
        │                            + *FYI line with LLM2 verdict*; compare='llm1-down'
        ├─ blindspot branch: *pair note appended (agrees / DISAGREES)*, decision
        │   unchanged                                                                [D9]
        └─ merge switch: UNCHANGED (LLM1 verdict only)
```

**Timing (parallel):** wall-clock ≈ max(t1, t2); each call's timeout enforced by
`Invoke-RestMethod -TimeoutSec` inside its own runspace; LLM2's effective timeout is clamped to
LLM1's (D11) so the pair always finishes inside LLM1's budget. `Hook.ps1` hard cap
(`llm1.timeout_ms + 2000`) is **unchanged**.

```
 t0 ── BeginInvoke(LLM1) ──BeginInvoke(LLM2)
      ├────────── LLM1 runs (≤ llm1.timeout) ──────────┤ parse
      ├────────────── LLM2 runs (≤ min(llm2,llm1)) ────────┤ parse   <- EndInvoke order: L1, then L2
 t1 = max(end1, end2) -> compare -> merge/ask
```

---

## 3. Configuration

### 3.1 Root `config.json` — new block (placed immediately after `llm_second_opinion`)

```json
"llm_third_opinion": {
  "enabled": false,
  "level": "complex_remote",
  "base_uri": "http://127.0.0.1:3031",
  "model": "gpt-5.6-sol",
  "api_key": "",
  "timeout_ms": 30000,
  "temperature": 0.0,
  "llm_response_max_tokens": 256,
  "complex_min_subcommands": 2,
  "attributed_verdicts": true,
  "json_mode": true,
  "check_blindspot": {
    "enabled": true,
    "tiers": ["unclassified", "unregistered_verb", "unregistered_static", "unregistered", "unknown_domain"]
  }
}
```

Plus a documentation key `"\_comment_llm_third_opinion"` (same style as
`\_comment_llm_second_opinion`) that states, among the field reference:

> LIVE fields: `enabled`, `base_uri`, `model`, `api_key`, `timeout_ms` (effective timeout =
> min(this, llm_second_opinion.timeout_ms)). ALL other keys are ACCEPTED-BUT-IGNORED: LLM1's
> `llm_second_opinion` values decide scope (`level`, `complex_min_subcommands`,
> `remote_indicators`, `check_blindspot`) and prompt/sampling (`attributed_verdicts`,
> `temperature`, `llm_response_max_tokens`, `json_mode`) for BOTH models, so the identical prompt
> guarantees a fair A/B comparison. Ignored keys are still VALIDATED (a typo throws at load).
> LLM2 fires iff LLM1 is enabled AND in scope. See docs/superpowers/specs/2026-09-30-llm-third-opinion-*.md.

### 3.2 `ConfigLoader.ps1` — validation

**Extract the existing `llm_second_opinion` validation (~lines 100–178) into a shared helper**
(borrowed from the sibling review — keeps the two blocks DRY and guarantees message parity):

```powershell
function Test-LlmBlockSchema {
    param($Block, [string]$Prefix)   # Prefix = 'llm_second_opinion' | 'llm_third_opinion'
    # existing checks moved VERBATIM; every throw-message prefix becomes "$Prefix."
}
```

LLM1's throw messages must stay **byte-identical** (tests match on `'llm_second_opinion.'`).
Then: `Test-LlmBlockSchema -Block $Config.llm_third_opinion -Prefix 'llm_third_opinion'`.
Checks applied to BOTH blocks:

- block must be an object;
- `enabled`, `attributed_verdicts`, `json_mode` boolean;
- `level` ∈ {`all`,`complex_commands`,`complex_remote`} (validated **even though ignored**);
- `timeout_ms`, `llm_response_max_tokens`, `complex_min_subcommands` integer ≥ 1;
- `temperature` number 0.0–2.0 (validated though ignored);
- `api_key` string;
- `remote_indicators` array of valid regex (validated though ignored);
- `check_blindspot` object { `enabled` bool, `tiers` string array } (validated though ignored);
- when `enabled: true`: `base_uri` AND `model` required (same messages as LLM1's);
- **NO cross-block rule**: `llm_third_opinion` present/ enabled while `llm_second_opinion` is
  absent or disabled is **valid** (that combination is the logged-skip case, D3 — not an error).

Follow the exact `Get-Member -MemberType NoteProperty` idiom used by the existing pass.

### 3.3 `ConfigLoader.ps1` — compile

Right after the `llmSecondOpinion` compile (~line 829), compile:

```powershell
$llm2Compiled = $null
if (Get-Member -InputObject $config -Name 'llm_third_opinion' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
    $l2 = $config.llm_third_opinion
    # ...same PS-5.1-safe Get-Member field extraction idiom as llmSecondOpinion...
    # defaults: enabled=$false, base_uri='', model='', api_key='', timeout_ms=12000
    $eff = $l2Timeout                                          # raw
    if ($llmCompiled) {                                        # clamp to LLM1's budget (D11)
        $eff = [math]::Min($eff, $llmCompiled.TimeoutMs)
    }
    $llm2Compiled = [PSCustomObject]@{
        Enabled            = $l2Enabled
        BaseUri            = $l2BaseUri
        Model              = $l2Model
        ApiKey             = $l2ApiKey
        TimeoutMs          = $l2Timeout       # raw value
        EffectiveTimeoutMs = $eff             # min(raw, llm1.timeout_ms); raw when llm1 absent
    }
}
$config._compiled | Add-Member -MemberType NoteProperty -Name 'llmThirdOpinion' -Value $llm2Compiled -Force
```

`$null` when the block is absent. Consumers null-check. NOTHING else in ConfigLoader changes.

---

## 4. `LlmReview.ps1` — low-level changes

### 4.1 Extract `New-LlmRequestBody` (pure refactor of `Get-LlmReviewVerdict` internals)

Move the request-building half of `Get-LlmReviewVerdict` into a helper so the pair path reuses it
byte-for-byte. **Two-parameter form** (borrowed from the sibling review): `$Llm1Config` supplies
ALL prompt/sampling parameters, `$EndpointConfig` supplies ONLY transport identity — this makes
the D2 "identical prompt/sampling" contract structural instead of conventional:

```powershell
function New-LlmRequestBody {
    # Returns @{ Uri; BodyJson; TimeoutSec; ApiKey }. Prompt+sampling ALWAYS from $Llm1Config
    # (Temperature, LlmResponseMaxTokens, AttributedVerdicts, JsonMode, TimeoutMs for the
    # default TimeoutSec); transport (BaseUri, Model, ApiKey) from $EndpointConfig.
    # Contains, unchanged from today: the 8000-char command truncation, V1/V2 system-prompt
    # selection, the numbered <sub_commands> block, the V2 first-character rule line,
    # json_mode response_format, seed=0, body.model = $EndpointConfig.Model.
    # Body JSON via ConvertTo-Json -Depth 10 -Compress.
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][PSCustomObject]$Llm1Config,
        [Parameter(Mandatory=$true)][PSCustomObject]$EndpointConfig,
        [string[]]$SubCommands = @()
    )
    ...
    $timeoutSec = [int][math]::Ceiling($Llm1Config.TimeoutMs / 1000.0)
    return @{ Uri = "$($EndpointConfig.BaseUri)/v1/chat/completions"; BodyJson = $bodyJson; TimeoutSec = $timeoutSec; ApiKey = "$($EndpointConfig.ApiKey)" }
}
```

For the pair's second call, override the returned `TimeoutSec` with
`Ceiling(EffectiveTimeoutMs/1000)` (the D11 clamp). `Get-LlmReviewVerdict` then calls
`New-LlmRequestBody -Llm1Config $LlmConfig -EndpointConfig $LlmConfig` → sync IRM → parse. **Its
observable behavior, error text, and result object are UNCHANGED** (the LLM2-disabled path must be
byte-identical; the existing llm-review suites pin it).

### 4.2 Extract `Get-LlmMockResult` (mock short-circuit shared by both LLMs)

```powershell
function Get-LlmMockResult {
    # $MockToken: raw env var value; $SubCommandCount: for idx parsing; $VarName: for the throw.
    # Returns @{ Mocked=$true; Raw=<string> } or @{ Mocked=$true; IsDown=$true; Error='mock: simulated unreachable LLM' }
    # Grammar (identical to today): 'modifying'|'read-only'|'garbage'|'down'|'idx:1,2'
    # Unknown value -> throw "Get-LlmReviewVerdict: unknown $VarName value '...' (expected modifying|read-only|garbage|down|idx:...)"
    param([string]$MockToken, [int]$SubCommandCount, [string]$VarName)
}
```

Pair-mode resolution order (D12):

```powershell
$mock1 = $env:PRETOOLHOOK_LLMREVIEW_MOCK
$mock2 = if ($env:PRETOOLHOOK_LLMREVIEW_MOCK2) { $env:PRETOOLHOOK_LLMREVIEW_MOCK2 } else { $mock1 }
```

(`MOCK2` unset ⇒ LLM2 sees the same token as LLM1 ⇒ identical raw ⇒ identical parsed verdict ⇒
`agree` — this is the regression baseline for every existing single-var test.) If `MOCK2` is set
while `MOCK` is not, LLM1 performs a REAL HTTP call and LLM2 is mocked; tests never use this, but
the behavior falls out naturally and is documented here.

### 4.3 New: runspace HTTP sender (the parallel mechanism, D10)

```powershell
function Start-LlmHttpCall {
    # Kicks off ONE Invoke-RestMethod inside its own [powershell] runspace.
    # $Payload = @{ Uri; BodyJson; TimeoutSec; ApiKey } from New-LlmRequestBody.
    # Returns @{ Ps = <PowerShell instance>; Handle = <IAsyncResult>; Sw = <Stopwatch> }.
    param([hashtable]$Payload)
    $workerScript = @'
param([string]$Uri, [string]$BodyJson, [int]$TimeoutSec, [string]$ApiKey)
try {
    $irmParams = @{ Uri = $Uri; Method = 'Post'; Body = $BodyJson; ContentType = 'application/json'; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($ApiKey) { $irmParams['Headers'] = @{ Authorization = "Bearer $ApiKey" } }
    $response = Invoke-RestMethod @irmParams
    $raw = ''
    if ($response.choices -and $response.choices[0].message) { $raw = [string]$response.choices[0].message.content }
    return @{ raw = $raw; error = $null } | ConvertTo-Json -Compress
}
catch {
    return @{ raw = ''; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
'@
    $ps = [powershell]::Create()
    $null = $ps.AddScript($workerScript)
    $null = $ps.AddArgument($Payload.Uri); $null = $ps.AddArgument($Payload.BodyJson)
    $null = $ps.AddArgument($Payload.TimeoutSec); $null = $ps.AddArgument($Payload.ApiKey)
    return @{ Ps = $ps; Handle = $ps.BeginInvoke(); Sw = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Complete-LlmHttpCall {
    # Blocks until THAT call finishes (IRM's own TimeoutSec bounds the wait), parses the
    # worker's JSON envelope, disposes the runspace. Returns @{ Raw; Error }.
    param([hashtable]$Call)
    $raw = ''; $err = $null
    try {
        $out = @($Call.Ps.EndInvoke($Call.Handle))
        if ($out.Count -gt 0) {
            try { $env2 = $out[0] | ConvertFrom-Json } catch { $env2 = $null }
            if ($env2 -and $env2.PSObject.Properties['error'] -and $env2.error) { $err = "$($env2.error)" }
            elseif ($env2 -and $env2.PSObject.Properties['raw']) { $raw = "$($env2.raw)" }
            else { $raw = "$($out[0])" }
        }
    }
    catch { $err = $_.Exception.Message }
    finally { $Call.Ps.Dispose() }
    # Belt-and-braces: a pipeline error that did not throw at EndInvoke
    if (-not $err -and $Call.Ps.Streams.Error -and $Call.Ps.Streams.Error.Count -gt 0) {
        $err = "$($Call.Ps.Streams.Error[0].Exception.Message)"
    }
    return @{ Raw = $raw; Error = $err }
}
```

Design notes (binding):

- The worker ALWAYS returns one JSON string `{"raw":...,"error":null}` — an unambiguous envelope
  across hosts (in-process runspaces share objects, but the string envelope makes the contract
  host-proof and keeps the error TEXT byte-identical to today's sync-path IRM exceptions).
- Per-call timeout = IRM `TimeoutSec` computed from the config's timeout (LLM2 uses
  `EffectiveTimeoutMs`). The main thread does NOT add its own timeout; EndInvoke order is LLM1
  then LLM2, so total wait = max — bounded by LLM1's budget (D11).
- `[powershell]::Create()` works identically on Windows PowerShell 5.1 and pwsh 7 (the test suites
  run under both; this is why `ForEach-Object -Parallel`/`Start-ThreadJob` were rejected).
- A dispatch-time exception (exotic) surfaces as `Error` on that call ⇒ that LLM is `down` ⇒ the
  §4.6 failure matrix applies. No fallback path.

### 4.4 New: verdict comparison (D4/D5)

```powershell
function Test-LlmVerdictsAgree {
    # $true / $false / $null (not comparable: either side down|unusable)
    # Equality = Verdict token equal AND index SET equal (order-insensitive, deduped).
    # V1 mode: both Index sets $null => equal. One-sided indices => NOT equal.
    param($A, $B)
    if ($A.Verdict -in @('down','unusable') -or $B.Verdict -in @('down','unusable')) { return $null }
    if ("$($A.Verdict)" -ne "$($B.Verdict)") { return $false }
    $ai = $null; $bi = $null
    if ($null -ne $A.Indices) { $ai = @($A.Indices | Sort-Object -Unique) }
    if ($null -ne $B.Indices) { $bi = @($B.Indices | Sort-Object -Unique) }
    if (($null -eq $ai) -xor ($null -eq $bi)) { return $false }
    if ($null -ne $ai) {
        if ($ai.Count -ne $bi.Count) { return $false }
        for ($i = 0; $i -lt $ai.Count; $i++) { if ("$($ai[$i])" -ne "$($bi[$i])") { return $false } }
    }
    return $true
}

function Get-LlmVerdictSummary {
    # "read-only" | "modifying indices=[1,2,4]" (indices sorted-unique, joined by ',')
    param($V)
}
```

**One-sided-indices edge (ruled during the sibling review):** when exactly one side has `$null`
Indices — reachable when one answer came back as clean JSON (`{"modifying":[2]}`) while the
other fell back to the bare-token recovery layer (`…true` → modifying, Indices `$null`) — the
sets are NOT comparable. Rule: **disagree** (fail-closed: a lower-fidelity recovered answer must
not count as agreement). The sibling proposed token-only comparison here; **rejected** per D4.
Pinned by `LT3-Disagree-OneSidedIndices`.

### 4.5 `Invoke-LlmReview` — orchestrator changes

New/changed statements (anchored to §1.1's flow):

1. **After the scope evaluation**, immediately:

   ```powershell
   $llm2 = $Config._compiled.llmThirdOpinion
   $pairArmed = ($null -ne $llm2 -and $llm2.Enabled)
   ```

2. **R2 pre-skip early return:** before returning with `effect='llm-skipped-trusted-editable'`,
   if `$pairArmed` stamp `$log.llm2 = New-Llm2SubLog -Model $llm2.Model -EffectiveTimeoutMs $llm2.EffectiveTimeoutMs -Compare 'skipped-trusted-editable'`.

3. **Out-of-scope early return** (`if (-not $scope.InScope)`): if `$pairArmed` stamp the llm2
   sub-log with `Compare='out-of-scope'` first. (check_blindspot consults are IN scope — the scope
   function marks them so — and therefore continue to the pair.)

4. **Verdict acquisition — replace the single call:**

   ```powershell
   if (-not $pairArmed) {
       $verdict = Get-LlmReviewVerdict -Command $ClassifyResult.Command -LlmConfig $llm -SubCommands $subTexts   # UNCHANGED path
   }
   else {
       # --- pair request bodies: sampling from LLM1 for BOTH, transport per endpoint (D2).
       #     New-LlmRequestBody's two-parameter form enforces this structurally — no merged clone.

       $subCount = $subTexts.Count
       $mock1 = $env:PRETOOLHOOK_LLMREVIEW_MOCK
       $mock2 = if ($env:PRETOOLHOOK_LLMREVIEW_MOCK2) { $env:PRETOOLHOOK_LLMREVIEW_MOCK2 } else { $mock1 }

       if ($mock1 -or $mock2) {
           # --- MOCK PAIR: synchronous, in-process, no runspaces (D12)
           $verdict  = New-MockVerdict -Token $mock1 -SubCount $subCount -VarName 'PRETOOLHOOK_LLMREVIEW_MOCK'        # wraps Get-LlmMockResult + ConvertTo-LlmVerdict + LatencyMs=0
           $verdict2 = New-MockVerdict -Token $mock2 -SubCount $subCount -VarName 'PRETOOLHOOK_LLMREVIEW_MOCK2'
       }
       else {
           # --- HTTP PAIR: identical prompt, two endpoints, two runspaces (D10)
           $ep2 = [PSCustomObject]@{ BaseUri = $llm2.BaseUri; Model = $llm2.Model; ApiKey = $llm2.ApiKey }
           $p1 = New-LlmRequestBody -Command $ClassifyResult.Command -Llm1Config $llm -EndpointConfig $llm -SubCommands $subTexts
           $p2 = New-LlmRequestBody -Command $ClassifyResult.Command -Llm1Config $llm -EndpointConfig $ep2 -SubCommands $subTexts
           $p2.TimeoutSec = [int][math]::Ceiling($llm2.EffectiveTimeoutMs / 1000.0)   # D11 clamp
           $c1 = Start-LlmHttpCall -Payload $p1
           $c2 = Start-LlmHttpCall -Payload $p2
           $r1 = Complete-LlmHttpCall -Call $c1; $c1.Sw.Stop()
           $r2 = Complete-LlmHttpCall -Call $c2; $c2.Sw.Stop()
           $verdict  = ConvertTo-LlmVerdict -RawContent $r1.Raw -SubCommandCount $subCount | <wrap: LatencyMs=$c1.Sw.ElapsedMilliseconds, Error=$r1.Error (Error=>Verdict='down')>
           $verdict2 = ConvertTo-LlmVerdict -RawContent $r2.Raw -SubCommandCount $subCount | <wrap: LatencyMs=$c2.Sw.ElapsedMilliseconds, Error=$r2.Error (Error=>Verdict='down')>
       }

       # --- stamp BOTH sides onto $log (LLM1 fields exactly as today + llm2 sub-object)
       $log.llm2 = New-Llm2SubLog -Model $llm2.Model -EffectiveTimeoutMs $llm2.EffectiveTimeoutMs
       # llm2 fields: verdict, indices, latency_ms, recovered, mocked, error, raw_excerpt,
       #              raw_full   (same excerpting rules as LLM1: ws-collapsed, raw_display_limit)

       # --- COMPARE on the RAW parsed verdicts, BEFORE any suppression (D5)
       $agree = Test-LlmVerdictsAgree -A $verdict -B $verdict2
       if ($agree -eq $false) {
           $log.llm2.compare = 'disagree'
           $log.effect       = 'llm2-disagree'
           $sum1 = Get-LlmVerdictSummary $verdict; $sum2 = Get-LlmVerdictSummary $verdict2
           $reason = "*** LLM-DISAGREE *** second-opinion LLMs disagree: LLM1 ($($llm.Model)) -> $sum1 | LLM2 ($($llm2.Model)) -> $sum2 - forced to ask. Review carefully before approving."
           # contested part ONLY when tokens are equal (both 'modifying'): symmetric-difference
           # index set; name the FIRST contested sub-command (120-char cap) — D16
           if ("$($verdict.Verdict)" -eq "$($verdict2.Verdict)" -and $null -ne $verdict.Indices -and $null -ne $verdict2.Indices) {
               $setA = @($verdict.Indices | Sort-Object -Unique); $setB = @($verdict2.Indices | Sort-Object -Unique)
               $diff = @(($setA + $setB) | Sort-Object -Unique | Where-Object { ($setA -notcontains $_) -or ($setB -notcontains $_) })
               if ($diff.Count -gt 0) {
                   $firstIdx = $diff[0]; $ft = "$($scope.SubCommands[$firstIdx - 1].Command)"
                   if ($ft.Length -gt 120) { $ft = $ft.Substring(0, 120) }
                   $reason += " | contested: [$($diff -join ',')] '$ft'"
               }
           }
           $ClassifyResult.Decision = 'ask'
           $ClassifyResult.Reason   = "$reason | local reason: $localReason"
           return [PSCustomObject]@{ Result = $ClassifyResult; Log = $log }
       }
       # agree / not-comparable -> fall through to today's flow with $verdict (LLM1)
       if ($agree -eq $true)  { $log.llm2.compare = 'agree' }
       else {
           # LLM2 down OR unusable (compare state: LLM1 healthy)
           if ($verdict.Verdict -in @('down','unusable')) { $log.llm2.compare = 'llm1-down' }
           else { $log.llm2.compare = 'llm2-down' }
       }
   }
   ```

   `New-Llm2SubLog -Model -EffectiveTimeoutMs [-Compare]` returns:

   ```powershell
   [PSCustomObject]@{ model = ...; effective_timeout_ms = ...; verdict = $null; indices = $null;
                      latency_ms = $null; recovered = $false; mocked = $false; error = $null;
                      raw_excerpt = $null; raw_full = $null; compare = 'out-of-scope' }
   ```

   `compare` final value set (union of all exit paths): **`agree` | `disagree` | `llm1-down` |
   `llm2-down` | `out-of-scope` | `skipped-trusted-editable` | `skipped-primary-disabled`**.
   (`llm1-down` covers LLM1 `down` OR `unusable`; `llm2-down` covers LLM2 `down` OR `unusable`.
   When both fail: `llm1-down` — LLM1's failure drives the decision; LLM2's error is visible in
   `llm2.error`. When LLM2 is disabled/absent there is **NO llm2 sub-object at all** — records stay
   byte-identical to today.)

5. **LLM1 down/unusable branches (today's forced asks):** after setting today's
   `*** LLM-DOWN ***` / `*** LLM-UNUSABLE ***` reason, if `$pairArmed` AND `$verdict2.Verdict` is
   a real verdict (`read-only`/`modifying`), APPEND (D8):

   ```
   ... | local reason: $localReason | LLM2 second-opinion (no authority, FYI): <SUMMARY2>
   ```

   where `<SUMMARY2>` = `Get-LlmVerdictSummary $verdict2` with the verdict token uppercased
   (e.g. `MODIFYING indices=[2,4]`, `READ-ONLY`). If LLM2 also failed, append nothing (both errors
   are already in the log).

6. **check_blindspot branch (decision NEVER changes):** after building today's
   `*** CHECK_BLINDSPOT *** ...` reason, if `$pairArmed` (D9):
   - agree → append `" | LLM2 agrees"` (after the llmHeadline, before `| local reason:` —
     simplest: append at the END of the full reason string; exact placement is cosmetic, tests
     assert substring).
   - disagree → append `" | LLM2 DISAGREES: <sum1> vs <sum2>"`.
   - llm2 failed → append nothing extra (headline already says which LLM state).
   `compare` is stamped agree/disagree/llm2-down as usual; `effect` stays `check-blindspot-ask`.

7. **The merge switch, `Test-GatedInvocationSafe`, suppression tiers: UNTOUCHED.** They only ever
   see `$verdict` (LLM1).

### 4.6 Failure/decision matrix (normative)

| LLM1 | LLM2 | compare | Decision | Reason |
|---|---|---|---|---|
| read-only | read-only (same set) | `agree` | today's (allow, or ask if local ask) | today's |
| modifying | modifying (same set) | `agree` | today's veto/suppress logic | today's |
| any verdict | DIFFERENT token or set | `disagree` | **ask** | `*** LLM-DISAGREE *** ...` |
| read-only/modifying | down or unusable | `llm2-down` | today's (LLM1 merge) | today's |
| down/unusable | read-only/modifying | `llm1-down` | **ask** (today's fail-closed) | today's `*** LLM-DOWN/UNUSABLE ***` + FYI append |
| down/unusable | down/unusable | `llm1-down` | **ask** | today's (no FYI) |

Blindspot consults: same comparisons logged, decision always local-ask, FYI/agrees notes appended.

---

## 5. `Logger.ps1` — `Format-LlmLogBlock` changes

All additions are behind `$LlmLog.llm2` existence checks; with no `llm2` member the output is
byte-identical to today.

1. **Skip-note line (D3):** at the top of the function, before the out-of-scope one-liner:

   ```powershell
   if ("$($LlmLog.effect)" -eq 'skipped-primary-disabled') {
       return "  LLM2          : llm_third_opinion enabled but llm_second_opinion disabled - LLM2 skipped`n"
   }
   ```

2. **`LLM-SENT` extension:** after the existing `timeout=...ms` fragment, when
   `$LlmLog.llm2` exists AND `compare` ∈ {agree, disagree, llm1-down, llm2-down}:

   ```
   ... timeout=30000ms model2=gpt-5.6-sol timeout2=30000ms | [1] ... | [2] ...
   ```

3. **New `LLM2-RECV` line**, directly under `LLM-RECV`, when `compare` ∈ the called set. Exact
   mirror of the `LLM-RECV` formatting rules (error excerpt 200-char cap; raw via
   `raw_full ?? raw_excerpt`, whitespace-collapsed, `raw_display_limit` cap with `…`; `(mock)`
   mark; ` indices=[..]` appended when indices exists). **Label padded so the `:` column aligns
   with `LLM-RECV`/`LLM-LOCAL`/`LLM-RECONCILE`** (label field = 14 chars: `LLM2-RECV` is 9
   chars + 5 spaces — caught via the sibling review):

   ```
     LLM2-RECV     : '{"modifying":[]}' (4100ms, recovered=False) -> verdict=read-only
     LLM2-RECV     : ERROR 'The operation has timed out' (30012ms) -> verdict=down
   ```

4. **`LLM-RECONCILE` extension:**
   - `effect='llm2-disagree'` branch: `"disagree LLM=<sum1> vs LLM2=<sum2> -> FINAL: ask"`.
   - Otherwise, when `llm2.compare` ∈ {agree, llm1-down, llm2-down}: prefix the existing branch
     text with `llm2-agree | ` / `llm1-down | ` / `llm2-down (proceeded on LLM1) | `.
   - `effect='llm-skipped-trusted-editable'` with an llm2 member: append
     ` (pair skipped — comparison not applicable)` to the rendered text.
   - This delivers the spec's "log mentions LLM and LLM2 return same result" requirement.

`Write-RecordEntry` needs NO change — it embeds the whole log object (including `llm2`) into
`records.jsonl`.

---

## 6. `Hook.ps1` — Step 8b change (only change in this file)

```powershell
$llmLog = $null
if ($config._compiled.llmSecondOpinion -and $config._compiled.llmSecondOpinion.Enabled) {
    $llmOutcome = Invoke-LlmReview -ClassifyResult $classifyResult -Config $config
    $classifyResult = $llmOutcome.Result
    $llmLog = $llmOutcome.Log
}
elseif ($config._compiled.llmThirdOpinion -and $config._compiled.llmThirdOpinion.Enabled) {
    # D3: pair cannot fire without its primary. No LLM calls; explicit log note.
    $llmLog = New-Llm2SkipLog -Config $config
}
```

`New-Llm2SkipLog` (define in `LlmReview.ps1`) returns:

```powershell
[PSCustomObject]@{
    enabled = $true; level = $null; in_scope = $false
    scope_reason = 'llm_third_opinion enabled but llm_second_opinion disabled - LLM2 skipped'
    sub_command_count = 0; verdict = 'not_called'; effect = 'skipped-primary-disabled'
    model = $Config._compiled.llmThirdOpinion.Model; latency_ms = $null; mocked = $false
    llm2 = [PSCustomObject]@{ model = ...; effective_timeout_ms = ...; compare = 'skipped-primary-disabled' }
}
```

The Step 10 hard cap (`llm1.timeout_ms + 2000`) is **unchanged** (D11).

---

## 7. Test plan (TDD — RED first, then implement, then GREEN)

### 7.1 Fixture dir: `test/config/llm-third-opinion/`

| File | Content |
|---|---|
| `config.pair.json` | LLM1 enabled: **`level:'complex_commands'`, `complex_min_subcommands:2`** (NOT `'all'` — verified in `Test-LlmReviewScope`: `'all'` returns in-scope immediately, so the check_blindspot rescue is UNREACHABLE and the blindspot cases would silently not fire; bug caught via the sibling review), `base_uri:'http://127.0.0.1:9'` (unreachable ⇒ real-HTTP attempts fail fast), `model:'m1'`, `timeout_ms:30000`, `temperature:0.0`, `llm_response_max_tokens:256`, `attributed_verdicts:true`, `json_mode:true`, `check_blindspot:{enabled:true, tiers:[all 5 defaults]}`. Consequence: in-scope cases use ≥2-sub-command blocks; blindspot cases use a SINGLE unknown-tier sub-command (1 < 2 ⇒ out of scope ⇒ rescue). LLM2 enabled: `base_uri:'http://127.0.0.1:9'`, `model:'m2'`, **`timeout_ms:60000`** (clamps to 30000 — preflight asserts), plus ignored-key copies. ALSO `trusted_programs:['tool-a.exe','tool-b.exe']` for the R2 case. |
| `config.v1.json` | Same as pair but `attributed_verdicts:false` (V1 bare-token mode). |
| `config.llm2-disabled.json` | LLM1 enabled (same as pair) + `llm_third_opinion` present with `enabled:false` (disabled-block parity). |
| `config.llm1-disabled.json` | `llm_second_opinion.enabled:false` + LLM2 `enabled:true` (skip-note, classify leg). |
| `config.llm1-absent.json` | NO `llm_second_opinion` block + LLM2 `enabled:true` (skip-note, fullpipe leg; also preflight "loads fine"). |
| `test-cases.llm.xml` | The cases below (attributes per §7.3). |

### 7.2 Runner changes (`test/config/llm-review/Run-Tests.ps1`)

- `mock2` XML attribute: set/clear `PRETOOLHOOK_LLMREVIEW_MOCK2` at exactly the same sites as
  `mock` (classify set + per-case cleanup, fullpipe set + cleanup, final cleanup). Unset ⇒ falls
  back to `mock` inside the engine (nothing for the runner to do).
- New assertion attributes (classify mode, evaluated against `$LlmLog` when the case sets mocks):
  `effect="..."` (assert `$LlmLog.effect`), `llm2-compare="..."` (assert `$LlmLog.llm2.compare`),
  `llm2-verdict="..."`, `llm2-absent="true"` (assert `$LlmLog.llm2 -eq $null`).
- Mirror the Hook Step 8b gate in classify mode: add the `elseif` skip-log branch (so the
  skip-note case works in-process).
- Fullpipe mode: env vars propagate to the spawned hook automatically.

### 7.3 XML case list (`test-cases.llm.xml`; default config = `config.pair.json`)

| # | Case | Command (shape) | mock / mock2 | Expect |
|---|---|---|---|---|
| 1 | `LT3-Agree-ReadOnly-Allow` | 2 read-only sub-commands | `read-only` / (unset) | allow; `effect=agree`; `llm2-compare=agree`; `llm2-verdict=read-only` |
| 2 | `LT3-Agree-Veto-Ask` | read-only block | `idx:2` / `idx:2` | ask; `effect=veto`; `compare=agree`; reason contains `LLM-VETO` |
| 3 | `LT3-Disagree-ForcedAsk` | read-only block | `idx:2` / `read-only` | ask; `effect=llm2-disagree`; `compare=disagree`; reason contains `*** LLM-DISAGREE ***` and both model names |
| 4 | `LT3-Disagree-IndicesOnly` | 4-sub read-only block | `idx:1,2` / `idx:1,2,4` | ask; `effect=llm2-disagree`; reason contains `contested: [4]` |
| 5 | `LT3-Agree-OrderInsensitive` | read-only block | `idx:2,4` / `idx:4,2` | NOT disagree → LLM1 veto path: ask; `effect=veto`; `compare=agree` |
| 6 | `LT3-Llm2Down-ProceedOnLlm1` | read-only block | `idx:2` / `down` | ask (LLM1 veto); `effect=veto`; `compare=llm2-down`; llm2 error set |
| 7 | `LT3-Llm2Garbage-Proceed` | read-only block | `read-only` / `garbage` | allow; `compare=llm2-down`; `llm2-verdict=unusable` |
| 8 | `LT3-Llm1Down-FYI` | read-only block | `down` / `idx:2` | ask; reason contains `*** LLM-DOWN ***` AND `LLM2 second-opinion (no authority, FYI): MODIFYING indices=[2]`; `compare=llm1-down` |
| 9 | `LT3-Llm1Unusable-FYI` | read-only block | `garbage` / `read-only` | ask; reason contains `LLM-UNUSABLE` + FYI `READ-ONLY`; `compare=llm1-down` |
| 10 | `LT3-BothDown` | read-only block | `down` / `down` | ask; `LLM-DOWN`; `compare=llm1-down`; no FYI in reason |
| 11 | `LT3-Blindspot-Agree` | SINGLE unknown-tier sub-command (e.g. `foobarbaz --x`) — 1 < min 2 ⇒ out of scope ⇒ blindspot rescue | `read-only` / (unset) | ask (local); reason contains `CHECK_BLINDSPOT` and `LLM2 agrees`; `compare=agree` |
| 12 | `LT3-Blindspot-Disagree` | same | `read-only` / `idx:1` | ask; reason contains `LLM2 DISAGREES`; `compare=disagree` |
| 13 | `LT3-Disabled-Parity` (config=`config.llm2-disabled.json`) | read-only block | `idx:2` / — | ask (veto); `llm2-absent=true` (byte-identical LLM1 behavior) |
| 14 | `LT3-R2Skip-Note` | `tool-a.exe; tool-b.exe` (both in fixture `trusted_programs`) | — | allow; `effect=llm-skipped-trusted-editable`; `llm2-compare=skipped-trusted-editable` |
| 15 | `LT3-V1-Disagree` (config=`config.v1.json`) | read-only block | `modifying` / `read-only` | ask; `effect=llm2-disagree` (bare-token compare) |
| 16 | `LT3-V1-Agree` (config=`config.v1.json`) | read-only block | `read-only` / — | allow |
| 17 | `LT3-SkipNote-Classify` (config=`config.llm1-disabled.json`) | read-only command | — | allow (local, no LLM); `effect=skipped-primary-disabled`; `llm2-compare=skipped-primary-disabled` |
| 18 | `LT3-SkipNote-Fullpipe` (config=`config.llm1-absent.json`, `mode="fullpipe"`) | read-only command | — | allow; hook's records.jsonl line has `"effect":"skipped-primary-disabled"`, OR (if the harness gains .log reading) the `.log` contains `LLM2          : llm_third_opinion enabled but llm_second_opinion disabled - LLM2 skipped` |
| 19 | `LT3-Disagree-TrustedOnly` (borrowed from sibling review — the spec's own headline example, pins D5) | `git status && src\Classifier.ps1` (sub [2] = trusted_program) | `idx:2` / `idx:` | ask; `effect=llm2-disagree`; `compare=disagree` — unconditional even though the contested index is trusted territory |
| 20 | `LT3-Disagree-OneSidedIndices` (pins the §4.4 edge ruling) | 2-sub read-only block | `idx:2` / `modifying` (bare-token recovery ⇒ Indices `$null`) | ask; `effect=llm2-disagree`; `compare=disagree` |
| 21 | `LT3-FullPipe-Disagree` (`mode="fullpipe"`) | 2-sub read-only block | `idx:2` / `read-only` | ask; records.jsonl `"compare":"disagree"` (+ `.log` contains the `LLM2-RECV` line if the fullpipe harness reads the log) |

### 7.4 Runner preflights (inside `Run-Tests.ps1`, run before the XML cases)

| # | Check |
|---|---|
| PF-1 | `config.pair.json` loads; `_compiled.llmThirdOpinion` non-null; `Enabled`; `Model='m2'`; `TimeoutMs=60000` (raw); **`EffectiveTimeoutMs=30000`** (clamped). |
| PF-2 | Enabled block missing `base_uri` → `Load-Config` throws. |
| PF-3 | Enabled block missing `model` → throws. |
| PF-4 | `timeout_ms:0` → throws. |
| PF-5 | `level:'bogus'` → throws (ignored key still validated). |
| PF-6 | `temperature:3.0` → throws. |
| PF-7 | `config.llm1-absent.json` loads with NO throw; llm2 compiled present. |
| PF-8 | `config.llm2-disabled.json` loads; llm2 compiled `Enabled=false`. |

Bad-config preflights write throwaway config copies (LLM1-enabled template + one mutated field)
into the fixture dir or `$env:TEMP` — NEVER the repo-root `config.json` (project rule).

### 7.5 http-mock pair-dispatch checks (extend `test/config/llm-review/http/` — plan borrowed from the sibling review, verified feasible against the real code)

Mocks bypass the runspaces, so the real parallel HTTP leg is only testable against the local mock
server. `Mock-LlmServer.ps1` already exposes a synchronized `$State` hashtable programmed per
request (`Body`/`Status`/`DelayMs`) plus `Last*` capture and `RequestCount` — extend it
(backward-compatibly):

- `State.BodyByModel` — synchronized hashtable `model → response body`. In the listener loop,
  after reading `$bodyText`: parse `.model` (try/catch); if `BodyByModel` contains it, respond
  with that body, else fall back to `State.Body`. **Requirement: the two configured model names
  must DIFFER** for divergent scripting (fixtures use `m1` / `mock2-model`).
- `State.Requests` — synchronized `List[hashtable]`, appended per request
  (`@{ Method; Path; Body; Auth; Model }`); `Last*` fields unchanged. Reset both in the runner's
  per-case reset block.
- `Run-LlmCallTests.ps1` fullpipe branch already CLONES the fixture config before spawning the
  hook (verified ~L293–298: `config.json` → set `base_uri` → `c:\temp\llm-call-test-config.json`
  → `PRETOOLHOOK_CONFIG_PATH`): extend the clone to also set
  `llm_third_opinion = { enabled:true, base_uri:<mock>, model:'mock2-model', timeout_ms:<llm1's> }`.

New cases (`test-llm-pair.xml` or inline):

| name | BodyByModel setup | asserts |
|---|---|---|
| `LTP-Pair-BothArrive` | `m1`→`true` envelope, `mock2-model`→`false` envelope | `RequestCount=2`; ask; reason contains `*** LLM-DISAGREE ***`; `Requests` models = {m1, mock2-model} |
| `LTP-Pair-Agree` | both → `false` envelope | `RequestCount=2`; allow |
| `LTP-Pair-Llm2Garbage` | `m1`→`false`, `mock2-model`→ramble-no-token | `RequestCount=2`; allow (LLM1 drives; compare=llm2-down) |

These are the ONLY offline coverage of the real runspace dispatch. If implementation reveals a
blocker, fall back to defer-and-document (spec §5).

### 7.6 Suite registration (`src/Run-AllTests.ps1`)

```powershell
@{ Name = 'llm-third-opinion.llm'; File = (Join-Path $repoRoot 'test\config\llm-review\Run-Tests.ps1');
   Args = @('-XmlPath', (Join-Path $repoRoot 'test\config\llm-third-opinion\test-cases.llm.xml'),
            '-ConfigPath', (Join-Path $repoRoot 'test\config\llm-third-opinion\config.pair.json'),
            '-Cwd', (Join-Path $repoRoot 'test\config\llm-third-opinion')) }
```

### 7.7 Procedure (project rule: red/green TDD)

1. Baseline: run `src\Run-AllTests.ps1` (via **pwsh**, repo convention); record the exact pass
   count — the parity target for acceptance #1.
2. Write fixtures + XML + runner extensions; run the new suite → **RED** (record the failing
   counts in PROGRESS.md, the way prior features did).
3. Implement in GREEN order with a checkpoint regression after each step (borrowed from the
   sibling review):
   (a) ConfigLoader — `Test-LlmBlockSchema` extraction + third-block validation + compile →
       preflights PF-1..8 green AND existing config suites green (byte-identical error prefixes);
   (b) `New-LlmRequestBody` extraction → run existing llm-review suites (pure-refactor proof);
   (c) `Get-LlmMockResult` extraction → same;
   (d) `Test-LlmVerdictsAgree` + pair MOCK path in `Invoke-LlmReview` → classify LT3 cases green;
   (e) Logger rendering;
   (f) Hook.ps1 skip-note `elseif` → skip-note cases green;
   (g) runspace sender + http-mock LTP cases green.
4. New suite **GREEN**; then full `src\Run-AllTests.ps1` → **zero flips** on the existing suites
   (they are the absent-block byte-identical proof).
5. Update PROGRESS.md with counts.

---

## 8. Rollout & docs

1. Root `config.json`: add the §3.1 block (`enabled:false`) + `_comment_llm_third_opinion`.
2. `config.local.json` (live, git-ignored): block with `enabled:true`, real `base_uri`/`model`
   for both LLMs. **Do this LAST** (after full regression) so the live hook only sees the feature
   once it's green.
3. `docs/config-json-guide.md`: sibling subsection next to the `llm_second_opinion` section —
   live vs ignored fields, effective timeout, the skip-note case, `compare` enum, MOCK2.
4. `docs/superpowers/CURRENT-DESIGN.md`: feature bullet (one paragraph, link to spec/design).
5. Runner README/comment header: `mock2` attribute note.

## 9. Acceptance criteria (all must hold)

1. Feature OFF (absent/disabled): **byte-identical** — every pre-existing suite green, zero
   flips; no `llm2` member in any record; LLM1 synchronous path untouched (same error text).
2. Feature ON: decisions change ONLY via disagreement→ask (D5/D7); every other path identical.
3. Identical prompts/sampling to both LLMs (only model/uri/key/timeout-clamp differ).
4. Wall-clock of a pair consult ≤ LLM1's timeout + ε; Hook hard cap unchanged.
5. Every consult LLM1 makes leaves `llm2.compare` in `records.jsonl` (except R2-skips, which
   self-document as `skipped-trusted-editable`).
6. New suite green; full regression green; PROGRESS.md updated with counts.

## 10. Known refinements / deviations vs the interview (recorded, intentional)

- The Q11 draft's `not-armed` compare value is **encoded by absence** of the `llm2` sub-object
  (keeps feature-off records byte-identical). Final enum in §4.5.
- `llm1-down` / `llm2-down` each cover BOTH failure modes (`down` + `unusable`) — single mining
  value per side; the raw verdict distinguishes them.
- The skip-note renders as its own dedicated `.log` line (not the generic out-of-scope one-liner)
  because the user requirement is wording that explicitly names LLM2.

### 10.1 Sibling cross-review record (2026-09-30, `specs/sibling/2026-09-30-llm-third-opinion-design_strata_v1.md`)

**Adopted:** `Test-LlmBlockSchema` extraction (§3.2); two-parameter `New-LlmRequestBody` (§4.1);
concrete http-mock plan `BodyByModel`+`Requests`+config-clone extension (§7.5, verified against
`Mock-LlmServer.ps1` / `Run-LlmCallTests.ps1`); cases LT3-19/20/21; label-padding rule (§5.3);
GREEN checkpoint ordering (§7.7); explicit "runspace script must not reference `$script:` state"
rule (§4.3 — body built on main thread).

**Rejected (spec wins):**
- `.log`-only skip note via new `Write-LogEntry -LlmNote` param, `record.llm` absent — violates
  D13's approved `compare='skipped-primary-disabled'` records value (ours keeps the skip visible
  to the mining script).
- Blindspot disagreement REWRITING the reason to `LLM-DISAGREE` + `effect='llm2-disagree'` —
  violates D9 (FYI line only; effect stays `check-blindspot-ask`). Decision value is unchanged
  either way.
- One-sided-Indices ⇒ compare tokens only (agree) — violates D4; ours rules **disagree**
  (fail-closed; pinned by LT3-20).
- `compare` enum rename `llm1-failed`/`llm2-failed`/`both-failed` — the approved enum is
  `llm1-down`/`llm2-down` (both-failed ⇒ `llm1-down`, LLM2's state visible in `llm2.verdict`).
- Five-field compiled block without `EffectiveTimeoutMs` (computed at use site) — ours
  precomputes at compile (PF-1 asserts it).
- Their disagree-reason template omits the `contested: [N] 'text'` part (D16 requires it).

**Their outright errors (not borrowed):** `LTO-TimeoutClamp` expects `effective=60000` from
min(60000, 12000) — arithmetic wrong (12000); §13 example `timeout=120000 timeout2=30000` is
inconsistent with their own §5.2 clamp; §2 I7 claims an `LTO-R2Skip` case that does not exist in
their §10.3 table; header says "16 decisions" (spec has 17); baseline command uses
`powershell.exe` (repo convention is pwsh, count stale at ~1401 vs current 1412).

**Bug in OUR design caught by the comparison:** §7.1 `config.pair.json` originally specified
`level:'all'`, which short-circuits `Test-LlmReviewScope` in-scope and makes the check_blindspot
rescue unreachable — our own LT3-11/12 could never fire. Fixed to
`complex_commands`/min-2 (their fixture choice was right).

## 11. Out of scope

Automated accuracy scoring, decommission tooling, switchable-primary merge, per-LLM2 scope/sampling
config, mock response files (all explicitly rejected or deferred in the spec).
