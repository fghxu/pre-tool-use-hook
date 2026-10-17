# Design: `normal_override_llm` strictness mode (2026-10-16)

Status: **DESIGNED** — hand this document to the implementing agent.
Spec (decisions + rationale): `docs/Updates/Update-2026-10-16-strictness-normal-override-llm-spec.md`
(read §4 "Consolidated decision ledger" there first; this doc assumes D1–D12).
Repo rules that bind implementation: **red/green TDD**; test fixtures carry their **own config.json
next to the test files** — never the live root `config.json`/`config.local.json`; temporary files go
under the repo `temp/` dir and are removed when done.

---

## 1. High-level design

### 1.1 One-paragraph summary

Add a 4th value `normal_override_llm` to the modifying-strictness enum (`global_modifying_strictness`,
`commands.<domain>.modifying_strictness`, `parameter_commands[].modifying_strictness`). The value is
**normal-family**: everywhere strictness semantics branch, it behaves exactly like `normal` (D11/D12),
with exactly two new powers, both inside the LLM second-opinion merge:

1. **Gated arm (D1):** an LLM "modifying" flag on a `strictness_gated` sub-command is suppressed even
   when `Test-GatedInvocationSafe` would deny — the only surviving denial is a literal system-path
   target (INV-3 style).
2. **Index-0 arm (D3):** an index-0 flag is suppressed when it can be attributed to a locally
   validated editable redirect (local decision allow + ≥1 `redirection-target` SubResult with Tier
   `editable_path` + no system-path literal in the full command).

Nothing else changes: trusted/editable arms untouched (D2), LLM-down/unusable still ask (D6),
read_only-tier flags still ask (D8), locally-unknown tiers still ask (D9), tool gate untouched (D5).

### 1.2 Where the mode plugs in (pipeline view)

```
 tool_input.command
        |
        v
 Hook.ps1 ──> Invoke-Classify (Classifier.ps1)
        |        |
        |        |  domain detect ($domain)
        |        |  ...... NEW: stamp ClassifyResult.OverrideLlmActive ............... (A5)
        |        |
        |        v  per sub-command segment, its OWN domain
        |  Resolve-Command (Resolver.ps1)
        |        |   Step 7 strictness_gated entries / parameter rules:
        |        |     effective = Get-EffectiveStrictness(cfg, domain, entry)   ... (A2)
        |        |     if effective == 'strict'            -> ask (gated)
        |        |     else                                 -> allow (gated)
        |        |     ...... NEW: Tier stays 'strictness_gated'; when effective ........
        |        |     ...... == 'normal_override_llm', stamp OverrideLlm=$true ..... (A4)
        |        v
        |  SubResults [1..N] (+ redirection-target SubResult, excluded from LLM list)
        v
 Invoke-LlmReview (Hook.ps1:98 -> LlmReview.ps1)
        |
        v  verdict = {"modifying":[indices]}  (mock: PRETOOLHOOK_LLMREVIEW_MOCK=idx:1,2 / idx:0)
 MERGE LOOP (LlmReview.ps1 ~1326-1410)
        |
        |  for each flagged index ix:
        |    ix == 0 ?  ...... NEW: index-0 carve-out (D3) ......................... (A6)
        |              override if OverrideLlmActive && local==allow
        |                          && exists redirection-target SubResult Tier=editable_path
        |                          && !Test-CommandTargetsSystemPaths(fullCommand)
        |              else veto (P3, unchanged)
        |    Tier trusted_program            -> suppress                 (unchanged, D2)
        |    Tier editable_path/editable_del -> suppress unless INV-3     (unchanged, D2)
        |    Tier strictness_gated && OverrideLlm stamp
        |                                   -> suppress unless
        |                                      Test-CommandTargetsSystemPaths(sub)   (A6, D1)
        |    Tier strictness_gated && legacy strict_gate_override_llm flag -> suppress (unchanged)
        |    Tier strictness_gated && Test-GatedInvocationSafe             -> suppress (unchanged)
        |    else                          -> veto -> DECISION ask
        v
 all flags suppressed -> allow stands (effect=veto-suppressed-policy)
 any veto left         -> DECISION ask (*** LLM-VETO ***)
```

### 1.3 Strictness resolution after this feature (D4/D5)

```
                 global_modifying_strictness
                            |
        +-------------------+--------------------+
        |                   |                    |
   strict | loose      normal | normal_override_llm   ("normal family")
        |                   |
        v                   v
   RETURN global     entry-level modifying_strictness (parameter_commands)
                            |  (when key present)
                            v
                domain-level commands.<domain>.modifying_strictness
                            |  (when key present)
                            v
                inherit the GLOBAL normal-family value      ...... CHANGED (A2)
                (today: hardcoded 'normal')
```

Enum validity:

| Config key | Legal values |
|---|---|
| `global_modifying_strictness` | `strict` `normal` `loose` **`normal_override_llm`** |
| `commands.<domain>.modifying_strictness` | `strict` `normal` `loose` **`normal_override_llm`** |
| `parameter_commands[].modifying_strictness` | `strict` `normal` `loose` **`normal_override_llm`** |
| `tool_name_modifying_strictness` | `strict` `normal` `loose` (REJECTS the new value) |

---

## 2. Low-level design — every edit, by file

Load order (all dot-sourced into one scope): `ConfigLoader.ps1` → `Parser.ps1` → `Resolver.ps1` →
`Classifier.ps1` → `LlmReview.ps1` → `Logger.ps1`; entry `Hook.ps1`. Keep helpers in the file that is
loaded before first use.

### A1. `src/ConfigLoader.ps1` — validators (4 sites)

1. Global (~line 365): `$Config.global_modifying_strictness -notin @('normal','strict','loose')`
   → add `'normal_override_llm'` to the array; update the throw message to list all four.
2. Per-domain (~line 603): same 4-value array for `domain.modifying_strictness`.
3. Entry-level (~line 639): same 4-value array for `parameter_commands` entries.
4. `tool_name_modifying_strictness` (~line 321): **leave 3-value**; its throw message stays.

No compiled artifacts needed — the raw string values are compared at the sites below.

### A2. `src/Resolver.ps1` — `Get-EffectiveStrictness` (~lines 37–76)

Rewrite the guard + fallback (behavior for the 3 legacy values must be byte-identical):

```powershell
function Get-EffectiveStrictness {
    param([PSCustomObject]$Config, [string]$Domain, $Entry = $null)
    $g = if ($Config.global_modifying_strictness) { $Config.global_modifying_strictness } else { 'normal' }
    # strict/loose still FORCE (unchanged law); the normal family defers.
    if ($g -eq 'strict' -or $g -eq 'loose') { return $g }

    if ($Entry -and (Get-Member -InputObject $Entry -Name 'modifying_strictness' ...)) {
        return $Entry.modifying_strictness
    }
    foreach ($key in $Config.commands.PSObject.Properties.Name) {
        if ($key.ToLowerInvariant() -eq $Domain.ToLowerInvariant()) {
            $dom = $Config.commands.$key
            if (Get-Member -InputObject $dom -Name 'modifying_strictness' ...) { return $dom.modifying_strictness }
            break
        }
    }
    return $g   # CHANGED: was 'return "normal"' — absent domain key INHERITS the
                # normal-family global (normal | normal_override_llm). This is D4.
}
```

Also update the function's `.DESCRIPTION` ("Path policy (Parser.ps1) intentionally stays on the
global value" — still true; see A3).

### A3. Normalization of literal `-eq 'normal'` consumers (D11) — 2 sites

Both must treat `normal_override_llm` **as** `normal`. Implement a tiny helper in `Resolver.ps1`
(loaded before Parser? — NO: Parser loads BEFORE Resolver. Put the helper in `Parser.ps1` or make it
a `filter` in ConfigLoader.ps1, which loads first; simplest: inline the two-token membership test at
each site, no shared helper):

1. `src/Resolver.ps1` ~229 (AWS flag-stripping):
   `... -and (Get-EffectiveStrictness ...) -eq 'normal' ...` →
   `... -and (Get-EffectiveStrictness ...) -in @('normal','normal_override_llm') ...`
2. `src/Parser.ps1` ~1807–1812 (path-policy strictness fallback, reads the GLOBAL raw value):
   `if ($Config.global_modifying_strictness -eq 'normal' -and -not $Config._editablePathsEnabled)`
   → `if ($Config.global_modifying_strictness -in @('normal','normal_override_llm') -and -not $Config._editablePathsEnabled)`

All other consumers are already normal-like: `-eq 'strict'` gates (Resolver ~608 gated ask,
~1410 param-rule ask), `-ne 'loose'` (Resolver ~1477 unrecognized value → ask),
`Resolve-ToolGate` (`Classifier.ps1` ~145: global `-eq 'strict'` only → new value falls to
`$tool` mode, exactly per spec D5).

### A4. `src/Resolver.ps1` — stamp `OverrideLlm` on gated results (2 sites)

`New-ResolutionResult` (~line 134, nested helper) gains an optional switch:

```powershell
param([string]$Decision, [string]$Reason, [string]$MatchedPattern, [string]$Risk,
      [string]$Tier = '', [switch]$OverrideLlm)
$obj = [PSCustomObject]@{ Command=$Command; Decision=$Decision; Reason=$Reason;
                          MatchedPattern=$MatchedPattern; Risk=$Risk; Tier=$Tier }
if ($OverrideLlm) { $obj | Add-Member -MemberType NoteProperty -Name 'OverrideLlm' -Value $true }
return $obj
```

Property ABSENT for every other caller (falsy later; byte-identical objects otherwise).

Stamp sites (both already compute `$effective`/`$effectiveStrict` via `Get-EffectiveStrictness`):

1. Step 1a.5 strictness_gated entries (~lines 603–616): on the **allow** branch, pass
   `-OverrideLlm:($effective -eq 'normal_override_llm')`. The **strict→ask** branch never stamps
   (irrelevant — local ask).
2. Parameter rules `decision -eq 'strictness_gated'` (~lines 1405–1418): same, allow branch only.

**Verify the property survives to SubResults.** SubResults are assembled in `Classifier.ps1`
STEP 4/4e from these resolution objects (and `Parser.ps1` `AddResult`). Before coding, trace one
gated command end-to-end (e.g. `git status && git diff` under a fixture) and confirm
`$ClassifyResult.SubResults[0].OverrideLlm` is present in `Invoke-LlmReview`. If the SubResult
constructor whitelists fields, add `OverrideLlm` to the copy list there (one more edit site — find
it with `grep 'Tier =' src/Parser.ps1 src/Classifier.ps1`). The RED tests (T1/T17) catch any drop.

### A5. `src/Classifier.ps1` — `ClassifyResult.OverrideLlmActive` (index-0 arm input)

In `Invoke-Classify`, immediately after `$domain = Get-CommandDomain ...` (the whole-command domain,
~line 558 area), stamp the result-level flag used by the index-0 carve-out (mixed-domain pipelines:
per-sub arms use the per-sub stamp from A4; ONLY index 0 uses this primary-domain approximation —
documented, deliberate):

```powershell
# normal_override_llm mode marker for the LLM merge's index-0 carve-out (D3).
# Primary-domain approximation for whole-command (unlisted) flags; per-sub
# gated flags carry their own OverrideLlm stamp (A4).
$classifyResult | Add-Member -MemberType NoteProperty -Name 'OverrideLlmActive' -Force -Value (
    (Get-EffectiveStrictness -Config $Config -Domain $domain) -eq 'normal_override_llm')
```

Place it where the result object exists (before `return`). Fast paths (skipped/unknown tool,
path-branch) may skip the stamp — the merge's scope gate already excludes them (no sub-commands ⇒
out of scope). If `Repair-ResultProperties` rebuilds the object, stamp AFTER repair.

### A6. `src/LlmReview.ps1` — merge loop (~lines 1326–1410)

Keep the existing arms byte-identical; insert the two new arms.

**(a) Index-0 carve-out (D3).** Replace the current unconditional
`if ($ix -eq 0) { $vetoIdx += 0; continue }` with:

```powershell
if ($ix -eq 0) {
    # D3 (2026-10-16): under normal_override_llm, an index-0 flag is ATTRIBUTED
    # to a locally-validated editable redirect when one exists. Conditions:
    # local decision allow (merge precondition for suppressions anyway),
    # >=1 redirection-target SubResult carries Tier editable_path, the full
    # command has no system-path literal. No redirects => P3 stands (ask).
    $attr = $false
    if ($localDecision -eq 'allow' -and $ClassifyResult.OverrideLlmActive) {
        $redirOk = @($ClassifyResult.SubResults | Where-Object {
            $_.MatchedPattern -eq 'redirection-target' -and "$($_.Tier)" -eq 'editable_path' })
        if ($redirOk.Count -gt 0 -and
            -not (Test-CommandTargetsSystemPaths -Command $ClassifyResult.Command -Config $Config)) {
            $attr = $true
        }
    }
    if ($attr) { $suppIdx += 0 } else { $vetoIdx += 0 }
    continue
}
```

**(b) Gated override arm (D1).** Insert BETWEEN the existing `$isPathPolicyAllow` arm and the
legacy `$isGated -and $gateOverride` arm (order among gated arms is not decision-relevant — all
suppress — but keep legacy arms' code untouched below it):

```powershell
elseif ($isGated -and $sub.PSObject.Properties['OverrideLlm'] -and $sub.OverrideLlm -and
        -not (Test-CommandTargetsSystemPaths -Command $sub.Command -Config $Config)) {
    # D1 (2026-10-16): strictness mode normal_override_llm — local gated
    # classification overpowers the LLM veto; ONLY a literal system-path
    # target keeps the veto (INV-3 family, mirrors the editable tiers).
    $suppIdx += $ix
}
elseif ($isGated -and $sub.PSObject.Properties['OverrideLlm'] -and $sub.OverrideLlm) {
    # override mode active but system path present: veto stands, record WHY
    $vetoIdx += $ix
    $pgDenied += $ix
}
```

(The second arm is the D1 denial; it must come after the first and before the legacy
`Test-GatedInvocationSafe` arm, otherwise the legacy arm would double-suppress. Note the denial arm
does NOT fall through to `Test-GatedInvocationSafe` — in override mode the guard is fully replaced.)

**(c) Reason wording.** In the `$vetoIdx.Count -gt 0` reason builder, suppressed entries already
render `suppressed as policy: ...`. Append `(override)` to an entry's text when it was suppressed by
either new arm (track e.g. `$ovIdx` set) — gives records.jsonl miners a distinguishable marker.
`$log.effect` stays `veto-suppressed-policy` for the all-suppressed outcome; `path_guard_denied`
now also carries override-mode system-path denials (label is tier-accurate; `Logger.ps1`
`Get-SuppressedTierLabel` needs NO change).

**(d) Do NOT touch:** trusted arm, editable arm (already INV-3), legacy
`strict_gate_override_llm` arm, `Test-GatedInvocationSafe` itself, down/unusable branches,
check_blindspot, pair logic.

### A7. Docs & config comments (same change-set)

1. Root `config.json`: `_readme_strictness_guard` and `_comment_global_modifying_strictness` gain
   the 4th value + the normal-family guard law ("strict/loose force; the normal family defers to
   per-domain values; an absent domain key inherits the global normal-family value"). Root VALUE
   stays `"normal"` (D7).
2. `docs/config-json-guide.md`: strictness section — 4-value table (like §1.3 above) + the two merge
   arms in one paragraph.
3. `config.local.json` (live, user-operated per r2): optional first flip, e.g.
   `"commands": { "Linux": { "modifying_strictness": "normal_override_llm", ... } }`. The implementing
   agent does NOT edit the live value; document the recipe only.

---

## 3. Invariants & traps (MUST hold)

1. **Zero-flip parity:** with only the 3 legacy values in play, every object, decision, reason, and
   log line is byte-identical to today. The `OverrideLlm`/`OverrideLlmActive` properties are absent
   (falsy) unless the new value is configured.
2. **LLM never downgrades** — unchanged; the new arms only turn would-be vetoes into suppressions.
3. **D8/D9 channels stay open:** `read_only`-tier flag → ask in every mode; locally-unknown tiers →
   local ask stands.
4. **PowerShell 5.1 traps (repo-proven):** wrap pipeline results in `@()` before `.Count`
   (single-element returns have none); never start an argument with a `[type]` literal (argument
   mode parses it as a string — cast into a variable first); `[int]$arr[0].x` parses as
   `([int]$arr)[0].x`.
5. **`Test-CommandTargetsSystemPaths`** is defined in `Parser.ps1` (~1648) — available in the merge
   (LlmReview loads after Parser). It inspects literal path tokens only (canonicalized), so
   `$var`-targeted gated writers OVERRIDE under the new mode — that is the accepted (c) semantics
   (spec D1 rationale); pinned by T7/T22 twins.
6. **Mixed-domain pipelines:** per-sub gated stamps are exact (each segment resolves its own
   domain); only the index-0 arm uses `OverrideLlmActive` (primary domain). Accepted approximation.
7. **Guard order matters in the merge:** new gated-override arms must precede the legacy
   `Test-GatedInvocationSafe` arm; the D1-denial arm must not fall through to the legacy guard.

---

## 4. TDD plan (red → green) — ARTIFACTS MATERIALIZED 2026-10-16

All test files below EXIST in the repo and their RED records are captured. The implementing agent
does NOT author tests; start at step 3.

| Artifact | File |
|---|---|
| Decision suite (32 cases: 16 allow / 16 ask) | `test/config/llm-review/test-cases.override.xml` |
| Base fixture | `test/config/llm-review/config.ov.json` (global `normal_override_llm`; Linux no key = inherit-ON; PowerShell explicit `normal` = opt-out) |
| Variant fixtures | `config.ov-inherit-ps.json`, `config.ov-domainon.json`, `config.ov-strictdomain.json`, `config.ov-editable.json`, `config.ov-entryflip.json`, `config.ov-pair.json` |
| Preflight script (PF-1..PF-6) | `test/config/llm-review/Run-Ov-Preflights.ps1` |

Run (repo root, pwsh):

```
pwsh -NoProfile -File test/config/llm-review/Run-Ov-Preflights.ps1
pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath test/config/llm-review/test-cases.override.xml -ConfigPath test/config/llm-review/config.ov.json
```

**RED record (2026-10-16, unmodified src):** preflights = 6 total / 2 pass (PF-2 bad-value,
PF-3 tool-name rejection — both correctly throw today) / 4 fail (PF-1 load wall; PF-4/5/6 skipped
behind it). Decision suite = **startup throw** (`ConfigLoader.ps1:366` rejects the 4th value while
eagerly loading the base config) — zero cases execute until A1 lands; after A1, re-run for the
behavior red (T1–T9, T13–T16 still ask; T17/T20/T24/T25/T31 decide for the wrong reason), then
green after A2–A6. T33 still needs its own tiny TestRunner fixture (agent task).

**Runner caveats baked into the cases** (do not "fix" them away): (1) ALWAYS pass
`-ConfigPath config.ov.json` — the runner resets every no-`strictness`-attr case's global to the
BASE config's value, so variant configs assume global = `normal_override_llm`; (2) `level`
defaults to `complex_remote` in the runner — every case pins `level="complex_commands"`;
(3) run from the REPO ROOT (CWD-relative redirect targets must resolve as CWD → editable_path);
(4) `mock` grammar `idx:1,2` / `idx:0` injects attributed verdicts.

Remaining workflow:

1. ~~Create the fixture suite first~~ (DONE — see artifact table above; RED captured).
2. Implement A1→A6 in that order (ConfigLoader → Resolver → Parser → Classifier → LlmReview); after
   A1 re-run the suite to capture the behavior RED, after A6 the GREEN.
3. Re-run the new suite → all green; then full `pwsh -NoProfile -File src\Run-AllTests.ps1` →
   zero flips on pre-existing suites.
4. Register the new suite in `src/Run-AllTests.ps1` (`$extraSuites`/`$suiteConfig` with an explicit
   `-ConfigPath` + `-XmlPath`, precedent: the script-drilldown.llm entry driving this runner).

Harness = existing `test/config/llm-review/Run-Tests.ps1` (unmodified; it already supports `-XmlPath`,
`-ConfigPath`, per-case `config=`/`strictness=`/`level=`/`min=`/`mock=`/`mock2=`/`effect=`/`flagged=`/
`suppressed=`/`in-scope=`/`verdict=`/`reason-contains`/`llm2-*` attributes).

### 4.1 Fixture configs (MATERIALIZED in `test/config/llm-review/`; never the live configs)

Base `config.ov.json`:
- `global_modifying_strictness`: `"normal_override_llm"`
- `system_paths` as the existing fixture; `trusted_programs`: [`src\Run-AllTests.ps1`]; log path
  `c:\temp\pretoolhook-ov-testlogs\`; `llm_second_opinion` enabled / `complex_commands` / min 2 /
  attributed / json_mode off / check_blindspot off (attr-toggled)
- `Linux` domain: NO `modifying_strictness` (inherits override-ON); read_only `git status*`,
  `git diff*`, `terraform validate*`, `kubectl get*`; strictness_gated `git add*` (name `git-add`),
  `terraform plan*`, `kubectl config *`; modifying `rm *` (name `rm-rf`); `parameter_commands.curl`
  (rules: `-X` present→modifying, `-o` present→strictness_gated; default read-only; entry-level
  `modifying_strictness: normal_override_llm`)
- `PowerShell` domain: EXPLICIT `"normal"` (opt-out pin); read_only_verbs + `Get-Date` entry;
  gated entries `Set-Content*`/`Copy-Item*`/`New-Item*`; modifying `Remove-Item*`

Variants (each a FULL config differing only as noted):
- `config.ov-inherit-ps.json` — PowerShell `modifying_strictness` key REMOVED (inherit ON). [T6,T7,T14,T17,T22]
- `config.ov-domainon.json` — global `normal`; Linux EXPLICIT `normal_override_llm`. [T5 w/ `strictness="normal"`]
- `config.ov-strictdomain.json` — base + Linux EXPLICIT `strict`. [T24]
- `config.ov-editable.json` — base + `editable_paths: ["C:\\tmp\\ov-edit\\.*"]` (non-empty ⇒ guard-deniable foreign paths) + PS key removed (inherit ON). [T8,T21,T23]
- `config.ov-entryflip.json` — ov-editable + Linux EXPLICIT ON + curl ENTRY flipped to `normal` (entry beats domain). [T31]
- `config.ov-pair.json` — base + `llm_third_opinion` enabled, `enforce_disagree: false`. [T16]

### 4.2 Preflight (PF) checks — MATERIALIZED in `Run-Ov-Preflights.ps1`

| ID | Check | Expect | RED 2026-10-16 |
|---|---|---|---|
| PF-1 | `Load-Config config.ov.json` | loads (4th value legal at global/domain/entry) | FAIL (load wall `ConfigLoader.ps1:366`) |
| PF-2 | global typo value | throws, message names the key | PASS (already throws) |
| PF-3 | `tool_name_modifying_strictness: normal_override_llm` | throws (stays 3-value) | PASS (already throws) |
| PF-4 | `Get-EffectiveStrictness` ov-base, Linux | `normal_override_llm` (inherit) | FAIL (skipped behind PF-1) |
| PF-5 | same, ov-strictdomain, Linux | `strict` (domain wins) | FAIL (skipped) |
| PF-6 | same, ov-base, PowerShell | `normal` (explicit opt-out) | FAIL (skipped) |

### 4.3 Decision test cases — 33 total: 16 allow / 17 ask

All LLM cases: tool `Bash`, `min="2"` unless noted, `attributed` on. "mode" = which strictness arm is
active for the flagged sub's domain. Assertions beyond `expected` listed in "Assert".

**ALLOW (16)**

| ID | Mode source | mock | Command (CDATA) | Why allow | Assert |
|---|---|---|---|---|---|
| T1 | base (inherit ON) | `idx:1` | `git add . && git status` | gated sub + D1 override, no path tokens | `effect=veto-suppressed-policy`, `suppressed=1`, `flagged=1` |
| T2 | base | `idx:2` | `terraform validate; terraform plan` | gated `terraform plan` overridden | allow + suppressed=2 |
| T3 | base | `idx:1` | `kubectl config set-context ctx; kubectl get pods` | gated `kubectl config` overridden (read-only sibling unflagged) | allow |
| T4 | base, entry-level (curl entry ON) | `idx:1` | `curl -s -o page.html http://example.com` (min=1) | entry-level mode (D5) stamps OverrideLlm | allow + suppressed=1 |
| T5 | `config.ov-domainon.json` + `strictness="normal"` (global normal, domain ON) | `idx:1` | `git add . && git status` | per-domain mode (r2 shape) | allow |
| T6 | `config.ov-inherit-ps.json` | `idx:1` | `Set-Content .\log.txt hi; Get-Date` | PowerShell inherited override ON (D4 inherit) | allow |
| T7 | base | `idx:1` | `Copy-Item src.txt $dst; Get-Date` | writer+$var: legacy guard would deny; (c) overrides | allow, reason-not-contains `LLM-VETO` |
| T8 | `config.ov-editable.json` | `idx:1` | `Copy-Item a.txt D:\elsewhere\x.txt; Get-Date` | foreign literal: legacy guard denies; (c) overrides (non-system) | allow |
| T9 | base | `idx:0` | `git status > out.txt` (min=1; CWD redirect ⇒ editable_path) | D3 index-0 carve-out | allow, `suppressed=0` |
| T10 | mode OFF (fixture default, trusted_programs) | `idx:1` | `pwsh -NoProfile -File src\Run-AllTests.ps1` (min=1) | Option B pin — trusted unconditional (D2) | allow |
| T11 | mode OFF | `idx:2` | `Get-ChildItem c:\temp \| Where-Object Name -like '*a*' > .\o.txt` | R2 pin — per-segment editable redirect suppressible | allow |
| T12 | `strictness=normal` (mode OFF) | `idx:1` | `git add . && git status` | status-quo pin — no-path gated passes legacy guard | allow |
| T13 | base | `idx:1` | `git add .; Get-Date` | mixed pipeline: linux gated(ON) flagged+suppressed; PS read_only unflagged | allow |
| T14 | base | `idx:1` | `Set-Content .\x.txt 'v'; Get-Date` — NOTE uses `config.ov-inherit-ps.json` | gated cmdlet to CWD under inherited mode | allow |
| T15 | base (editable_paths ABSENT), mode ON | `read-only` | `git status > D:\elsewhere\o.txt` (min=1) | D11 pin — Parser path-policy fallback must treat the new value AS normal: foreign redirect allows ("normal mode" branch); pre-fix it falls to the final ask | allow, `effect=agree` |
| T16 | base + pair, `enforce_disagree:false` | mock=`read-only`, `mock2=idx:1` | `git add . && git status` | D18 fall-through + new suppression (D10) | allow, `llm2-compare=disagree` |

**ASK (17)**

| ID | Mode source | mock | Command | Why ask | Assert |
|---|---|---|---|---|---|
| T17 | `config.ov-inherit-ps.json` | `idx:1` | `Copy-Item a.txt C:\Windows\b.txt; Get-Date` | D1 denial — literal system path keeps veto | ask, reason-contains `*** LLM-VETO ***` + system path, `path_guard_denied=1` |
| T18 | base | `idx:2` | `git status; Get-Date` | D8 — read_only-tier flag asks (audit channel), even in override mode | ask |
| T19 | `strictness=normal` | `idx:2` | `git status; Get-Date` | D8 pin under plain normal | ask |
| T20 | base | `idx:0` | `git status && git diff` | D3 — index 0 with NO redirect keeps P3 | ask, reason-contains `unlisted part of the block` |
| T21 | `config.ov-editable.json` | `idx:0` | `git status > D:\elsewhere\o.txt` | foreign redirect: local redirect ask anyway | ask, reason-contains redirect/high |
| T22 | `strictness=normal` | `idx:1` | `Copy-Item src.txt $dst; Get-Date` | status-quo pin — writer+$var denied by legacy guard | ask |
| T23 | `config.ov-editable.json` + `strictness=normal` | `idx:1` | `Copy-Item a.txt D:\elsewhere\x.txt; Get-Date` | status-quo pin — foreign literal denied by legacy guard | ask |
| T24 | `config.ov-strictdomain.json` | `idx:1` | `git add . && git status` | D4 — domain `strict` wins over override global (gated asks locally) | ask (local, gated-strict reason) |
| T25 | base + `strictness="strict"` | `idx:1` | `git add . && git status` | guard pin — global `strict` forces even over base's inherit-ON Linux | ask |
| T26 | base | (none — local ask) | `rm -rf /tmp/x; git status` | locally `modifying` ⇒ local ask stands | ask |
| T27 | base | `read-only` | `Frobnicate-Thing -x; Get-Date` | D9 — unregistered verb: local ask, LLM never rescues | ask, `effect=disagree-kept-ask` |
| T28 | base | `down` | `git add . && git status` | D6 — LLM down asks even in override mode | ask, reason-contains `LLM-DOWN` |
| T29 | base | `garbage` | `git add . && git status` | D6 — unusable response asks | ask, reason-contains `LLM-UNUSABLE` |
| T30 | base, `check_blindspot=true` | `modifying` | `Frobnicate-Thing -x` (min=1) | D10 — blindspot never changes the decision | ask, reason-contains `CHECK_BLINDSPOT` |
| T31 | `config.ov-entryflip.json` | `idx:1` | `curl -s -o D:\elsewhere\p.html http://example.com` (min=1) | D5 precedence — entry `normal` beats domain ON ⇒ legacy guard denies the foreign `-o` target | ask |
| T32 | base | (local ask) | `git status > C:\Windows\o.txt` | redirect to system path: local redirect ask | ask |
| T33 | TestRunner suite (not LLM): `strictness_gated_tool_name` fixture + `tool_name_modifying_strictness: strict` + global `normal_override_llm` | n/a | gated tool payload with foreign write path | D5 — tool gate UNAFFECTED by the new global value | ask (tool-gate strict reason) |

Totals: **39 checks = 6 PF + 16 allow + 17 ask** (decision cases 16/17 ≈ half/half, diversified
across: domains Linux/PowerShell/aws_cli, tiers gated/read_only/modifying/trusted/editable/
unregistered, mode sources global-inherit/domain/entry/strict-forcing, guards system/foreign/$var/
no-path, LLM states modifying/read-only/down/garbage/pair-disagree, index 0 with/without redirect,
mode OFF twins for every loosening case).

### 4.4 Suite mechanics

- New XML `test/config/llm-review/test-cases.override.xml` (category-groups `OvAllow` / `OvAsk`)
  EXISTS (32 cases), driven by the UNMODIFIED llm-review runner via `-XmlPath` + `-ConfigPath`
  (both params pre-date this feature).
- T33 goes into a small TestRunner-style suite (or an existing non-LLM suite) with its own fixture
  config in a new `test/config/llm-override-tools/` dir (mock `strictness_gated_tool_name` +
  `tool_name_modifying_strictness: "strict"` + `global_modifying_strictness:
  "normal_override_llm"` + `system_paths`), registered in `Run-AllTests.ps1`. This is the only
  test artifact the implementing agent still authors.
- RED expectations (pre-implementation): every T1–T9, T13–T16 allow-case FAILS today (they ask);
  T17–T20, T24–T25, T31 fail in the DIRECTION of allowing-or-asking-for-the-wrong-reason where
  noted (T17/T20/T24/T25 currently… verify against live behavior and record actuals); PF-1/PF-2/
  PF-3 fail (validators). T10–T12, T18–T19, T22–T23, T26–T30, T32 pass already (parity pins) —
  they are the zero-flip guards.

---

## 5. Definition of done

1. New suite green (6 PF + 33 decision cases) with the RED record captured first.
2. `pwsh -NoProfile -File src\Run-AllTests.ps1` — zero flips, all pre-existing suites green.
3. A4 property-flow verified end-to-end (note in the suite README where the copy happens).
4. Root `config.json` comments + `docs/config-json-guide.md` updated; root VALUE stays `normal`.
5. `PROGRESS.md` updated with the feature summary and the green counts.
