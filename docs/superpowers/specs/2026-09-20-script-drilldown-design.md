# Design: Script Drilldown — Architecture & Implementation Contract

**Date:** 2026-09-20
**Status:** IMPLEMENTED + VERIFIED (v3 + verification record §0, 2026-09-21). Revision history: v1 drafted after the
sibling v1 cross-review; v2 folded in user rulings RUL-1..RUL-6 (§17); v3 incorporates the
sibling v2's empirically verified walker-collapse fact (F11) — with the RUL-1/RUL-2 consequence
that the COLLAPSED nested `-File` path IS expanded via the bare-invocation rule (§6.5) — and
the trusted-inner Domain fix (F12, §6.2 step 9b-NULL). All line anchors refer to `feature_fix`
HEAD 2026-09-20.

**Implementation result (2026-09-20):** all modules implemented per §3–§9 and green.
- `test/config/script-drilldown/Run-Tests.ps1`: **Total 8 / Passed 8 / Failed 0** — 5 preflights
  (BadRunner/BadScope/BadCap/CompiledPresent/OffNoCompile) + SDD-CoreSuite (22/22 XML cases ON)
  + SDD-OFF-Parity (22/22, byte-identical with block absent) + SDD-AbsolutePath.
- LLM sub-suite via `test/config/llm-review/Run-Tests.ps1` on `test-cases.llm.xml`: **33 / 33**
  (5 SDL cases: Count-InScope, Count-Veto, Exclude-OutOfScope, SentDisplayText, One-Request-Chained).
- Two necessary deviations from the literal §8.2 "two surgical edits" text, both load-bearing for
  §6.4/§6.5 to hold: (a) `AddResult` extended with `-AtomicReason`/`-DrilldownMarker`/`-DisplayText`
  so engine entries re-added through the AST wrapper loop keep their fail-closed reason and display
  form (§8.1); (b) a `-DrilldownEnabled` flag threaded through the walker so the engine's OWN content
  walk collapses nested `-File` to bare paths for step 9b rather than double-expanding (which claimed
  the HT key and made 9b's re-entry hit the loop-check spuriously). A third PS 5.1 quirk fixed: a
  single-entry engine return arrives as a bare object with no `.Count`, so every `$sub.Count` guard
  is wrapped in `@()`.
**Spec (the contract, wins on any conflict):** `docs/superpowers/specs/sibling/2026-09-20-script-drilldown-spec.md`
(sibling draft — not edited by us; user rulings are recorded in §17 instead)
**Branch:** `feature_fix` (standing rule: no merge to master until live soak passes)
**Audience:** a junior coder who has NEVER touched this repo. Everything needed to implement is
here or pointed at. You still read the project code — this doc tells you exactly what to read and
exactly what to change.

---

## 0. Independent verification pass (2026-09-21) — line-by-line audit vs this doc

Every §3–§9 module contract was re-read against the committed code, and every §13 case/preflight was
re-run. Result: **`script-drilldown` 17/17 checks + `script-drilldown.llm` 34/34; full
`src/Run-AllTests.ps1` = 1411/1411, zero flips.**

### 0.1 Verified as specified (no change needed)

| § | Item | Evidence |
|---|---|---|
| 4.1–4.3 | schema, `_comment_*` tolerance, per-rule validation (`runners` unknown/empty, caps ≥ 1, `llm_scope`), compile only when enabled, `Config`/`Cwd` reference members, explicit `$script:ScriptDrilldown = $null` on OFF | code + preflights BadRunner/BadScope/BadCap/**EmptyRunners**/**BadMaxBytes**/**Defaults** |
| 5 | matcher registry + dispatcher, `-Command`-precedes-`-File` guard, runner-set gate | code; **SD-Allow-CommandWrapsFile** pins the guard |
| 6.2 | steps 0→9 incl. trust-first, canonical resolution, HT loop/cap, size cap, `ReadAllText`, `@()` PS 5.1 guards | code; SD-Ask-NotFound/TooLarge/Loop/LoopViaFile/Cap/**SiblingCap**/**NonLiteralFileArg** |
| 6.4/6.5 | FAILURE entry shape, `DrilldownMarker`, `SkipRewalk`, collapsed-path expansion on 9b | code; SD-Ask-NestedMissing, **SD-Allow-NestedTrusted**, **SD-Allow-FuncBodyNestedFile** |
| 7 | HT keys canonical+lowercase, insert only at step 7, reset + `Cwd` refresh at STEP 4 | code; **SDD-StateReset** |
| 8.1–8.4 | entry/SubResult metadata, `SkipRewalk` scoping, 4e reason template, 4f verbatim branch | code; **SDD-WrapperEntryShape**, **SDD-LineNumberReason** |
| 9.1–9.4 | single verdict call, `llm_scope`, `DisplayText ?? Command`, blindspot/merge untouched | SDL-* cases; production `records.jsonl` `llm.sent` shows `<script:…>` prefixes |
| 10 | log rendering path (Logger unchanged); reason line = Logger's `<command> (<reason>)` form, so the §6-2 text appears verbatim INSIDE it | live hook log 2026-09-21 00:32:48 |
| 11.1–11.6 | entry order/shape, cap boundary, loops, trusted shortcut, SITE-B compound, nested collapse | **SDD-WrapperEntryShape**, **SDD-CompoundSiteB**, SD-Allow-Chain3, SD-Compound-Cd |
| 12 | I1–I19 | per-row tests (below); I11 and I15 remain documented-and-untested accepted quirks |
| 13.5/14 | suite registration, generic config ships disabled, live fixtures re-synced, docs updated | `src/Run-AllTests.ps1`, `config.json`, `test/config/live/*`, CURRENT-DESIGN §1/§2/§4, config-json-guide §10.7 |

### 0.2 Deviations found that were NOT in the original "three deviations" list

| # | Deviation | Why it is needed | Where |
|---|---|---|---|
| D-4 | `Get-AstCommands` skips the ROOT ScriptBlockAst in its §3 recursion | section 2's `FindAll(CommandAst, $true)` already visits every command in nested scriptblocks; the recursion re-runs the wrapper machinery with the same dedup keys, so with drilldown ON it re-enters the engine, hits the HT loop-check and would mint a spurious `recursive …` blocker | §8.2 |
| D-5 | §6.2 step 8 gained an intermediate recovery stage: when the AST parses cleanly but yields zero `CommandAst`, the raw top-level statement texts are emitted (one entry each) *before* falling back to `Split-Commands` | `Split-Commands` mangles comment-only/expression-only content (it splits on `:` inside interpolations and swallows comments), which would turn an unknown statement into a misleading fragment. Consequence: the §6 "no classifiable statements" FAILURE is now reachable only for whitespace/empty files — which is why the fixture `assignments-only.ps1` is whitespace-only (design §13.1 said `$x = 1 + 2`; that content now yields the RUL-3 `contains unknown command: $x = 1 + 2` ask instead) | §6.2 |
| D-6 | new helper `Test-DrilldownInvocationText` (engine step 9b's regex, exposed for the walker) | lets the walker recognize a collapsed `-File` child of a script statement (fix V-2 below) | §8.2 |

### 0.3 Bugs found by the audit and fixed (red → green, TDD)

| # | Symptom | Root cause | Fix | Pinned by |
|---|---|---|---|---|
| V-1 | a nested `pwsh -File z.ps1` inside a **function body** produced `recursive script invocation detected` (twice) for a non-recursive script | the §3 ScriptBlockAst recursion (D-4) and the re-walk were called WITHOUT the inherited `-DrilldownEnabled`, so they expanded `z` a second time inside the engine's own content walk and claimed the HT key before step 9b | inherit `-DrilldownEnabled` in both recursive calls | **SD-Allow-FuncBodyNestedFile** |
| V-2 | `pwsh -Command "pwsh -File z.ps1"` inside a script over-asked with a bogus `recursive …` AND an `unknown command: scripts\z.ps1` | the walker emits two entries for that ONE invocation (the inner wrapper text from the `-Command` unwrapping, plus the collapsed bare path produced by re-walking it); the second hits the loop-check, and the depth-0 re-walk of the engine statement re-derives the bare path as a fresh, unexpandable entry | (a) re-walk skips a bare-`.ps1` child when the SOURCE entry carries `OriginScript` (the engine already owns that invocation); (b) `Expand-ScriptFile` step 9 remembers targets already expanded in the same statement list and skips duplicate representations | **SD-Allow-CommandWrapsFile** |
| V-3 | `SubResult.LineNumber` held the STRING `"[int]<entry dump>.LineNumber"` instead of an int | PowerShell **argument mode** does not treat a leading `[int]` as a cast: `Add-Member -Value [int]$sc.LineNumber` was parsed as an expandable string | convert in a variable first (`$n = [int]$x; Add-Member … $n`) | **SDD-LineNumberReason** + **SDD-WrapperEntryShape** (type assertion) |

V-4 (behaviour note, not a bug): with drilldown ON, `pwsh -File $var` (non-literal) now **asks**
(`script file not found`), whereas without the block the AST arbiter allows that line. The pair
**SD-Ask-NonLiteralFileArg / SDO-Ask-NonLiteralFileArg** exists to pin that asymmetry: enabling the
feature can only make a `-File` invocation stricter, never looser (I16/RUL-4).

### 0.4 Test coverage added by the audit (fixtures + cases + runner checks)

- ON matrix 22 → **34** cases: FuncBodyNestedFile, NestedTrusted, VariablePath (I7), CrossDomain (I12),
  CommandWrapsFile, SpacedNestedPath (§6.5 edge), NonLiteralFileArg (I16), TwoScripts, SiblingCap
  (D11/D12 budget is per decision, not per chain), FileThenCommandArg (I5), Utf8Script (I17).
- OFF matrix 21 → **33** twins for every new command (byte-identical-behavior proof; the
  NonLiteralFileArg twin documents today's arbiter allow, see V-4).
- Runner preflights 5 → **8** (+ SDD-EmptyRunners (RUL-6), SDD-BadMaxBytes (4.2 rule 6),
  SDD-Defaults (rules 2/4/7 defaults + in-block `_comment_*`)).
- Runner programmatic checks: + SDD-WrapperEntryShape (entry order/shape + int LineNumber),
  SDD-NestedFileExpanded, **SDD-TrustOnlyNoRead** (the previously unused `config.trustonly.json`
  now proves D9's "trusted ⇒ never read"), SDD-StateReset, SDD-LineNumberReason, SDD-CompoundSiteB.
- LLM sub-suite + SDL-Exclude-LocalAskStands (exclusion must not weaken the local ask).
- New fixtures: `config.emptyrunner.json`, `config.badbytes.json`, `config.defaults.json`,
  `scripts/func-file.ps1`, `calls-nested-trusted.ps1`, `variable-path.ps1`, `cross-domain.ps1`,
  `cmd-file-inside.ps1`, `spaced-nested.ps1`, `my script.ps1`, `utf8-nonascii.ps1`.

### 0.5 Still open / accepted

- I11 (quoted `pwsh.exe -File` normalization may duplicate the wrapper entry) and I15 (symlink loops
  are not detected; the count cap bounds the work) remain documented-and-untested accepted quirks.
- §13.1's `assignments-only.ps1` content differs from the doc (whitespace-only, see D-5); the doc's
  `$x = 1 + 2` example would now be a RUL-3 unknown-command ask.
- Production cost observation: with drilldown ON, an expanded script raises the LLM sub-command count
  (observed 29 sub-commands / ~12 s on a 34-line helper script in the live soak), and `check_blindspot`
  still consults the LLM for drilldown asks carrying `unclassified` tiers. Both are decision-neutral
  but visible in latency.

---

## 1. What we are building (one paragraph)

Today, when the AI agent runs `pwsh -File <script>.ps1`, the hook extracts only the script **path**
and classifies that path (trusted ⇒ allow, otherwise unknown ⇒ ask). The user must blindly
approve/deny a script whose contents were never inspected. **Script drilldown** makes the hook
*open the file* (PowerShell only in v1), split it into statements with the existing AST walker,
and classify every statement as if it were typed on the command line — surfaced as numbered
`[N]` sub-commands in the log and the LLM second-opinion prompt, each prefixed
`<script:basename>`. The whole feature is gated by a `script_drilldown` config block; when the
block is absent or `enabled: false`, behavior is **byte-identical to today** (spec D2).

Non-goals (spec §8): other languages (framework must be extendable by *addition*), depth-0
dot-source on the agent's own command line, `python -c` inline forms, safe-expression
certification of pure-assignment scripts (v1 asks), re-expansion reuse on double invocation
(v1 asks).

---

## 2. Current implementation (verified in code — read these first)

All modules are dot-sourced into ONE PowerShell scope: `Hook.ps1` sources `HookAdapter.ps1`,
`ConfigLoader.ps1`, `Logger.ps1`, `Classifier.ps1` (which itself sources `Parser.ps1` +
`Resolver.ps1` at its lines 21–22), `LlmReview.ps1`, `Notify-Ask.ps1`. Consequence: **any function
can call any other function at runtime**, and `$script:`-prefixed variables are shared session
state. This is the load-bearing fact that makes the design below work.

### 2.1 The end-to-end flow today (command branch)

```
IDE tool call (JSON on stdin)
  └─ Hook.ps1            Load-Config  →  Detect-IDE  →  Invoke-Classify
                                                    │
                                                    ▼
  Classifier.ps1  Invoke-Classify (L322)
    STEP 4a  $domain = Get-CommandDomain($command)          [Parser.ps1 L66]
    STEP 4b  $subCommands = Split-Commands(...)             [Parser.ps1 L190]
    STEP 4b-2 (domain==powershell only, L555)
             $astCommands = Get-PowerShellCommands($command)   [Parser.ps1 L1550]
               └─ Get-AstCommands (L1600) — AST walker
                   └─ per CommandAst: Get-AstWrapperInnerCommands (L1857)
                       └─ *** SITE A: the "-File <path> — TERMINAL" branch (~L1898) ***
                          emits {CommandText=<path>, Domain='powershell',
                                 IsPipeline=$false, IsTerminal=$true}
                       └─ IsTerminal ⇒ $suppressOuter=$true ⇒ outer 'pwsh ...' NOT added
    STEP 4c  foreach SEGMENT of $subCommands (L582):
             Find-NestedCommands($seg)                        [Parser.ps1 L607]
               └─ *** SITE B: the regex "-File" branch (~L702) ***
                  regex: (?i)^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-File\s+
                         (?:"([^"]+)"|'([^']+)'|(\S+))
                  emits {CommandText=<path>, Domain='powershell', ParentCommand=<segment>}
    STEP 4c-2/4c-3  subshell $(...) + redirection analysis
    COMBINE (L590-655)  pick $allCommands:
       astCommands>0  → astCommands + subshell          (SITE B results DISCARDED)
       safeExpr>0     → safeExpr + nested + subshell
       atomic-unknown (L623) → one entry w/ AtomicReason + nested + subshell
       nested>0       → segments minus parentTexts + nested + subshell
       else           → segments + nested + subshell
    STEP 4e  foreach entry → Resolve-Command (Resolver.ps1 L77) → SubResult
             {Command, Decision, Reason, MatchedPattern, Risk, Tier}
             AtomicReason entries honored verbatim: ask/unclassified, MatchedPattern=$null
    STEP 4f  aggregate worst-case-wins; all-unknown blockers ⇒ AST-arbiter try;
             blocking reason = "MatchedPattern (Risk)" | MatchedPattern | Reason
  Hook.ps1 STEP 8b  Invoke-LlmReview (LlmReview.ps1 L652) when llm enabled
             Test-LlmReviewScope (L172): count non-redirection SubResults
               ≥ complex_min_subcommands (live: 2) ⇒ in scope
             ONE Get-LlmReviewVerdict call; numbered list built at LlmReview.ps1 ~L510
             $subTexts built at Invoke-LlmReview ~L747 from $_.Command
  Logger.ps1  Format-LlmLogBlock (L159) renders LLM-SENT [N] list from $log.sent
```

### 2.2 What each numbered `[N]` entry is

`SubResults` (array on the classify result) is the SINGLE source of numbering:
`Invoke-LlmReview` builds `$subTexts = $scope.SubCommands | % { "$($_.Command)" }` — that array
is BOTH the LLM prompt's numbered `<sub_commands>` list AND `$log.sent` (what `Format-LlmLogBlock`
prints as `LLM-SENT : [N] text`), and `$log.tiers` (`LLM-LOCAL tiers: [N]=tier`) comes from the
same array's `Tier` fields. **Add a SubResult ⇒ it appears in log + LLM automatically.** (Spec
fact #2; verified at LlmReview.ps1 ~L747–755 and Logger.ps1 L197–210.)

### 2.3 Today's `-File` behavior (what we must preserve when OFF)

| Situation | Today's entries | Decision |
|---|---|---|
| `pwsh -File <trusted path>` (AST path) | ONE entry: the path (outer suppressed by IsTerminal) | allow, Tier `trusted_program` (Resolver Step 0f-trust, L304) |
| `pwsh -File <untrusted path>` | ONE entry: the path | ask, unknown fallback |
| compound `cd x; pwsh -File p` (domain=linux ⇒ SITE B) | segment filtered via parentTexts + path entry | same outcomes (2026-09-17 incident fix — do not break) |
| `pwsh -File a.ps1 -Command "Remove-Item x"` | `-File` wins (guard `hasFileBeforeCommand`, ~L633); `-Command` is script $args | path entry only |

Trust matching happens in `Resolve-Command` **Step 0f-trust** (Resolver.ps1 L304): first token
(after stripping leading `&` / `.` at L279–282) → `Test-TrustedProgram` (L999; literal path-suffix
/basename + R1 regex pass) → allow Tier `trusted_program` unless `Test-StatementContainsModifying`
finds a modifying arg. The pwsh **wrapper line** itself classifies read_only via the
PowerShell-domain pattern `pwsh(?:\.exe)? *` (config.json L485) — that is what makes the wrapper
renderable as a harmless `[1]`.

### 2.4 More verified facts you will need

| # | Fact | Where |
|---|---|---|
| F1 | Hook input JSON has NO cwd field; the hook process CWD (captured at load as `$Config._cwd`, trailing-separator form) IS the VS Code workspace root (empirically proven, spec R8) | ConfigLoader.ps1 L350–356 |
| F2 | `ConvertTo-CanonicalWritePath` = the canonicalization primitive: `\\?\` strip, relative→`$Config._cwd` anchor, `..` collapse via GetFullPath, separator unify | Parser.ps1 L1307 |
| F3 | AST walker reaches function bodies (`FindAll(ScriptBlockAst)` recursion) — statements inside `function X { ... }` are already extracted | Parser.ps1 L1778–1793 |
| F4 | AST entries are CommandAst-granularity with `.Extent.StartLineNumber` available at extraction (currently dropped) | Parser.ps1 L1650ff |
| F5 | AtomicReason precedent: combination stage can pre-compute a reason onto an entry; STEP 4e honors it verbatim (ask / unclassified / MatchedPattern=$null) | Classifier.ps1 L623–700, L760–773 |
| F6 | `Resolve-AsArbiter` (arbiter) re-enters `Find-NestedCommands` on wrapper texts — any expansion living in SITE A/B **will be re-entered by arbitration** | Classifier.ps1 L1094 |
| F7 | The combination-stage atomic-unknown probe calls `Get-PowerShellCommands($command)` on the FULL command for counting — another re-entry path for SITE A | Classifier.ps1 L623 |
| F8 | All modules share one scope (§2 preamble) — Parser-side functions may call `Test-TrustedProgram` (Resolver) and read `$script:` state without parameter threading | spec fact #8 |
| F9 | TestRunner supports `-Cwd` (overrides `_cwd`/`_cwdNorm` post-load) and per-case XML attrs `expected`, `reason-contains`, `subresult-tier`, `subresult-reason-contains` | TestRunner.ps1 L31–37, L142–168 |
| F10 | LLM mock env var `PRETOOLHOOK_LLMREVIEW_MOCK=idx:2,4` injects an attributed verdict — zero quota | LlmReview.ps1 L475–495 |
| F11 | **Walker collapse:** `Get-PowerShellCommands` applied to script CONTENT unwraps a nested `pwsh -File .\b.ps1` statement itself — the emitted entry is the BARE PATH `.\b.ps1` (the `-File` branch + `IsTerminal`/`$suppressOuter` run at file level too); the wrapper text never reaches the engine's emit loop on the AST path. Dot-source/`&` statements are NOT wrappers to the walker ⇒ their full text survives. (Sibling v2 probe `debug/_drilldown_probe.ps1`; code-verified against the `-File` branch + suppressOuter mechanism.) | Parser.ps1 ~L1898 + L1735–1775 |
| F12 | `Get-CommandDomain('. .\helper.ps1')` returns **linux** (no Verb-Noun, no PS marker, not pwsh-prefixed) — an unforced dot-source/bare-path statement entry would classify against Linux tiers and miss the Resolver's dot-strip + trust path. (Sibling v2 probe case C.) | Parser.ps1 L66 |

---

## 3. Target architecture

### 3.1 Component graph (new/changed parts marked)

```
                              ┌────────────────────────────────────────────────┐
                              │ ConfigLoader.ps1  (CHANGED)                    │
                              │  Load-Config:                                  │
                              │   + validate "script_drilldown" block (throw   │
                              │     fail-closed on bad runner/scope/caps)     │
                              │   + compile → $Config._compiled.scriptDrilldown│
                              │   + publish gate → $script:ScriptDrilldown     │
                              └───────────────┬────────────────────────────────┘
                                              │ (gate object or $null)
 ┌────────────────────────────────────────────▼──────────────────────────────────────┐
 │ Parser.ps1  (CHANGED — all new engine parts live here)                            │
 │                                                                                    │
 │  $script:ScriptRunnerMatchers   registry: @{ Runner='powershell'; Match=<script> } │
 │  Find-ScriptRunnerInvocation    dispatcher: segment text → @{Runner;ScriptPath}|null│
 │  $script:DrilldownVisited       per-tool-call hashtable (canonical path → $true)   │
 │  Reset-ScriptDrilldownState     clears the hashtable (called by Classifier)        │
 │                                                                                    │
 │  Expand-ScriptFile  ══ THE ENGINE ══  path + wrapper text → entries[]              │
 │    1 Test-TrustedProgram      (D9 trust-first; hit ⇒ $null, site keeps path entry) │
 │    2 resolve+canonicalize via ConvertTo-CanonicalWritePath (D8)                    │
 │    3 Test-Path → not-found entry            (AtomicReason, §6)                     │
 │    4 HT loop check → recursive entry        (AtomicReason, §6)                     │
 │    5 HT cap check  → max-chained entry      (AtomicReason, §6)                     │
 │    6 size check    → too-large entry        (AtomicReason, §6)                     │
 │    7 insert into HT; read file; Get-PowerShellCommands(content) [+LineNumber]      │
 │    8 0 statements → no-statements entry     (AtomicReason, §6)                     │
 │    9 per statement: invocation-shaped? (dot-source/&/bare .ps1 — incl. the          │
 │      COLLAPSED nested -File path, F11 — or fallback-path wrapper text)              │
 │        └─ yes → RECURSE Expand-ScriptFile (same checks; §6.5)                      │
 │      emit statement entries: OriginScript, LineNumber, DisplayText, SkipRewalk     │
 │                                                                                    │
 │  SITE A  Get-AstWrapperInnerCommands -File branch  → calls dispatcher+engine       │
 │  SITE B  Find-NestedCommands        -File branch  → calls dispatcher+engine        │
 │  Get-AstCommands: honor SkipRewalk (skip per-entry re-walk for engine entries)     │
 │  AddResult: optional LineNumber passthrough                                        │
 └────────────────────────────────────────────┬──────────────────────────────────────┘
                                              │ entries flow in existing $allCommands
 ┌────────────────────────────────────────────▼──────────────────────────────────────┐
 │ Classifier.ps1  (CHANGED, small)                                                  │
 │  STEP 4 entry : Reset-ScriptDrilldownState   (fresh HT per tool call)             │
 │  STEP 4e      : copy DisplayText/OriginScript/LineNumber onto SubResult;          │
 │                 AtomicReason+DrilldownMarker ⇒ MatchedPattern='script-drilldown'; │
 │                 format §6 reason for script-origin ask entries                    │
 │  STEP 4f      : blocking-reason builder prefers Reason for OriginScript entries   │
 └────────────────────────────────────────────┬──────────────────────────────────────┘
                                              │ SubResults (unchanged shape + additive)
 ┌────────────────────────────────────────────▼──────────────────────────────────────┐
 │ LlmReview.ps1  (CHANGED, small)                                                   │
 │  Test-LlmReviewScope: llm_scope='exclude' ⇒ drop OriginScript SubResults          │
 │  Invoke-LlmReview   : $subTexts uses DisplayText ?? Command                       │
 │  (one request for ALL chained scripts already true — R17 needs NO new code)       │
 └──────────────────────────────────────────────────────────────────────────────────┘
  Logger.ps1: NO CHANGE (renders $log.sent/$log.tiers; DisplayText rides along)
  Resolver.ps1, Hook.ps1, HookAdapter.ps1, Notify-Ask.ps1: NO CHANGE
```

### 3.2 The two injection sites (spec D1 — both change identically in behavior)

| | SITE A (AST primary) | SITE B (regex fallback) |
|---|---|---|
| Function | `Get-AstWrapperInnerCommands` | `Find-NestedCommands` |
| Anchor | Parser.ps1 ~L1898 (`-File <path> — TERMINAL`) | Parser.ps1 ~L702 |
| Reaches it | domain==powershell commands (4b-2 walker; also arbiter + atomic probe re-entries, F6/F7) | every command's segments (4c), linux-domain compounds (2026-09-17 fix), arbiter (F6) |
| Path source | parsed: next CommandElement value after `-File`/`-f` | production regex (quoted/unquoted) |
| Today emits | path entry, `IsTerminal=$true` | path entry, `ParentCommand=$segment` |
| With drilldown ON: **trusted** | unchanged (path entry, IsTerminal) — file never read (D9) | unchanged |
| ON: **expansion OK** | wrapperResults = `[pseudo-wrapper(IsTerminal,SkipRewalk), stmt1..stmtN(plain, re-walkable)]`; real outer suppressed ⇒ `[1]`=wrapper, `[2..n]`=statements | returns `[wrapper entry, stmt1..stmtN]` with `ParentCommand=$trimmed`; the segment itself is dropped by the existing `parentTexts` filter |
| ON: **expansion FAILED** | path entry + `AtomicReason` (+`DrilldownMarker`), `IsTerminal=$true` | same, `ParentCommand=$trimmed` |
| OFF / absent | today's code path byte-identical | same |

**Why the pseudo-wrapper at SITE A:** `Get-AstCommands` adds inner (wrapper) results BEFORE the
outer command; if we let the normal outer-add run, the wrapper would land AFTER its statements
(`[n+1]`), violating the approved log format (spec §7: `[1]` = wrapper). Emitting the wrapper as
the FIRST wrapper-result with `IsTerminal=$true` both preserves order and reuses the existing
`$suppressOuter` mechanism to kill the duplicate real outer entry.

**Why `SkipRewalk` — and why it is SCOPED, not blanket:** after adding each inner result,
`Get-AstCommands` re-walks it (`Get-PowerShellCommands($innerCmd)`, ~L1750–1775). Two facts
shape the guard: (a) the engine's OWN walk of the file content already ran the full wrapper
machinery — a `pwsh -Command "Remove-Item x"` statement inside a script arrives at the emit
loop ALREADY unwrapped (the inner `Remove-Item x` is its own statement entry carrying
OriginScript), so plain statements never need the SITE-A re-walk for safety — their re-walk is
a harmless same-text skip that also lets rare deeper re-walk children inherit origin
attribution (§8.2.3); (b) re-walking a wrapper-SHAPED text (the pseudo-wrapper, a fallback-path
`pwsh -File z` statement, a failure entry whose text is an invocation) would re-enter the
engine and mint spurious `recursive …` entries via the HT loop-check. So the marker goes ONLY
on wrapper-shaped engine entries — pseudo-wrapper, NESTED-WRAPPER (step 9a), FAILURE entries —
**never** on plain STATEMENT entries. Pinned by SD-Ask-CommandInsideScript (the unwrapped inner
must ask). Bonus: with the matcher's `-Command`-precedes-`-File` guard (§5), a fallback-path
statement like `pwsh -Command "pwsh -File z.ps1"` skips 9a, gets re-walked as plain text, and
the walker's own `-Command` branch then routes `pwsh -File z.ps1` into SITE A → z expands
through the LEGITIMATE recursion with full HT protection.

### 3.3 New/changed functions inventory

| Function | File | New/Changed | Signature |
|---|---|---|---|
| `$script:ScriptRunnerMatchers` | Parser.ps1 | NEW | registry array (§5) |
| `Find-ScriptRunnerInvocation` | Parser.ps1 | NEW | `param([string]$SegmentText)` → `$null` \| `@{Runner=[string];ScriptPath=[string]}` |
| `Expand-ScriptFile` | Parser.ps1 | NEW | `param([string]$ScriptPath, [string]$WrapperText)` → entries array (§6) |
| `Reset-ScriptDrilldownState` | Parser.ps1 | NEW | `param()` — clears `$script:DrilldownVisited` |
| `Get-AstWrapperInnerCommands` | Parser.ps1 | CHANGED | same signature; `-File` branch calls dispatcher+engine |
| `Find-NestedCommands` | Parser.ps1 | CHANGED | same signature; `-File` branch calls dispatcher+engine |
| `Get-AstCommands` | Parser.ps1 | CHANGED | same signature; honor `SkipRewalk`; `AddResult` gains optional `LineNumber` |
| `Invoke-Classify` | Classifier.ps1 | CHANGED | reset at STEP 4 entry; 4e stamping/formatting; 4f reason branch |
| `Load-Config` | ConfigLoader.ps1 | CHANGED | validate + compile + publish `script_drilldown` |
| `Test-LlmReviewScope` | LlmReview.ps1 | CHANGED | `llm_scope='exclude'` filter |
| `Invoke-LlmReview` | LlmReview.ps1 | CHANGED | `$subTexts` uses `DisplayText ?? Command` |

---

## 4. Config: schema, validation, compilation (spec D7/D12/D15)

### 4.1 Schema (generic `config.json` ships it explicit-disabled)

```jsonc
"script_drilldown": {
    "_comment_1": "Script drilldown: extract + classify statements of scripts invoked via -File",
    "_comment_2": "absent key OR enabled=false => behavior identical to before this feature",
    "enabled": false,
    "runners": ["powershell"],
    "max_chained_files": 3,
    "max_file_bytes": 4096,
    "llm_scope": "count"
}
```

### 4.2 Validation (in `Load-Config`, immediately after the `ask_notification` compile block,
~ConfigLoader.ps1 L870; fail-closed = throw, exactly like `trusted_programs_regex` bad regex)

Rules — validated whenever the block is PRESENT (even if `enabled:false`):

1. Block must be a JSON object (`PSCustomObject`) — else throw
   `script_drilldown must be an object`.
2. Ignore any property whose name starts with `_` (the `_comment_*` convention).
3. `enabled`: bool, default `$false`.
4. `runners`: array of strings; EVERY entry must be in the implemented set `{ 'powershell' }` —
   else throw `script_drilldown.runners: unknown runner '<name>' (implemented: powershell)`.
   Omitted ⇒ `@('powershell')` (all implemented matchers armed). An explicitly EMPTY array
   ALSO throws (`runners must list at least one implemented runner`) — an empty list would
   arm zero matchers and silently turn `enabled: true` into a no-op, the one failure mode
   fail-closed validation exists to prevent.
5. `max_chained_files`: integer ≥ 1, default `3`.
6. `max_file_bytes`: integer ≥ 1, default `4096`.
7. `llm_scope`: `'count'` | `'exclude'`, default `'count'` — else throw
   `script_drilldown.llm_scope must be 'count' or 'exclude'`.

### 4.3 Compiled shape

```powershell
# built only when block present AND enabled == true; otherwise $null
$drill = [PSCustomObject]@{
    Enabled         = $true
    Runners         = @('powershell')                 # validated names
    MaxChainedFiles = 3
    MaxFileBytes    = 4096
    LlmScope        = 'count'
    # + Cwd / Config reference members — see §6.3
}
$config._compiled | Add-Member -Force NoteProperty 'scriptDrilldown' $drill
# Parser-side functions have no $Config parameter — publish the SAME object as
# shared session state (all modules are dot-sourced into one scope, F8):
$script:ScriptDrilldown = $drill        # see the OFF line below
# OFF is an EXPLICIT assignment (not omission): fixture runners load several
# configs in ONE process (preflights!), and a stale gate from a previous
# Load-Config would leak the feature into an OFF run:
if (-not $drill) { $script:ScriptDrilldown = $null }
```

`Load-Config` is the ONLY writer of `$script:ScriptDrilldown`. TestRunner / fixture runners load
config once per run, so the gate follows whichever config was loaded (this is exactly how
`$Config._cwd` behaves today).

---

## 5. Matcher registry & dispatcher (spec D6/R2/R6)

Purpose: per-language "does this command line invoke a script file?" detection, structured so
Python et al. are an **addition** (new registry entry + config validation set extension), never a
rework. Match entries are **scriptblocks**, not regex strings (the PowerShell one wraps the
production regex; Python will need a token loop).

```powershell
# Parser.ps1 — place near $script:KnownBinaryPrefixes (~L27)
# Registry of per-language script-runner matchers. Each matcher:
#   INPUT : the command/statement text, RAW (the matcher normalizes internally — see below)
#   OUTPUT: $null (no invocation) or @{ Runner = 'powershell'; ScriptPath = '<as written>' }
$script:ScriptRunnerMatchers = @(
    @{
        Runner = 'powershell'
        Match  = {
            param([string]$Text)
            # Normalize EXACTLY like Find-NestedCommands' head (~L619-627): strip a leading
            # call operator, rewrite a quoted full-path pwsh.exe/powershell.exe to 'pwsh' so
            # the anchored pattern matches. Idempotent with SITE B's own pre-normalization;
            # extends matcher coverage to '& "C:\...\pwsh.exe" -File z' statements inside
            # scripts and to SITE A wrapper texts the structured parse cannot name.
            $s = ($Text -replace '^\s*&\s+', '').Trim()
            if ($s -match '^[''"]([A-Za-z]:\\(?:.*\\)?(?:pwsh|powershell)(?:\.exe)?)[''"]') {
                $s = 'pwsh' + $s.Substring($Matches[0].Length)
            }
            # GUARD (mirrors hasFileBeforeCommand, Find-NestedCommands ~L633): when a
            # -Command/-c token PRECEDES -File, that '-File' belongs to the inner command
            # string, not to this runner -- refuse, or the (\S+) arm grabs a garbage path
            # like 'z.ps1"'. The caller falls through to normal -Command unwrapping.
            $f = [regex]::Match($s, '(?i)-File\b')
            if ($f.Success) {
                $c = [regex]::Match($s, '(?i)-(?:Command|c)\s+["'']')
                if ($c.Success -and $c.Index -lt $f.Index) { return $null }
            }
            if ($s -match '(?i)^(?:\\.?\\)?(?:pwsh|powershell)(?:\\.exe)?\\s+.*?-File\\s+(?:"([^"]+)"|'+'([^'']+)'+'|(\\S+))') {
                $p = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
                if ($p) { return @{ Runner = 'powershell'; ScriptPath = $p } }
            }
            return $null
        }
    }
)

function Find-ScriptRunnerInvocation {
    param([string]$SegmentText)
    $gate = $script:ScriptDrilldown
    if (-not $gate) { return $null }
    foreach ($m in $script:ScriptRunnerMatchers) {
        if ($gate.Runners -notcontains $m.Runner) { continue }
        $hit = & $m.Match -Text $SegmentText
        if ($hit) { return $hit }
    }
    return $null
}
```

Notes:
- The regex is the PRODUCTION regex verbatim (spec fact #3). Keep its existing asymmetries
  (SITE A also accepts short `-f` via its element parse; SITE B regex is long-form only) — do not
  "improve" them in this change.
- SITE A already parsed the path reliably from CommandElements; it calls the dispatcher for the
  gate/registry decision but overrides `ScriptPath` with the element VALUE (handles
  quoted-with-spaces paths the regex's `(\S+)` arm cannot).
- v1 ships ONE entry. The implemented-runner set for validation (§4.2 rule 4) must be kept in
  sync with this registry — derive it: `@($script:ScriptRunnerMatchers | % { $_.Runner })` if
  you like, or hardcode `@('powershell')` with a comment pointing at the registry.

**Future Python matcher (DO NOT IMPLEMENT — extension sketch only, spec §8):** token loop over
the segment; skip boolean flags; skip value-taking flags together with their value; if the first
non-flag token after the runner resolves to `*.py` → hit; REFUSE `-m` / `-c` forms (module /
inline code are not files).

---

## 6. The expansion engine — `Expand-ScriptFile` (spec D8–D14)

One function, one recursion point. Lives in Parser.ps1 near `Find-NestedCommands`. It is called
ONLY from the two `-File` sites (for the outer invocation) and from itself (for nested
invocations found inside expanded scripts).

### 6.1 Signature and return contract

```powershell
function Expand-ScriptFile {
    param(
        [string]$ScriptPath,     # path AS WRITTEN in the command/statement
        [string]$WrapperText     # the invoking text (wrapper line or statement), for ParentCommand
    )
    # Returns $null (DO NOT EXPAND — feature OFF or path TRUSTED; the calling SITE then
    # emits today's path entry itself, so OFF and trusted are indistinguishable to the sites)
    # or an array of parser-level entries. Entry kinds:
    #
    # KIND              Properties (beyond the standard CommandText/Domain/IsPipeline/ParentCommand)
    # ----              ----------
    # STATEMENT         OriginScript=<basename>, LineNumber=<int>, DisplayText='<script:b> <stmt>'
    #                   (NO SkipRewalk — plain statements MUST stay re-walkable so nested
    #                    wrappers inside scripts keep unwrapping; see §3.2)
    # NESTED-WRAPPER    SkipRewalk=$true (a 'pwsh -File z' statement kept as an entry;
    #                   re-walking it would re-enter the engine for z)
    # FAILURE           AtomicReason=<§6-2 text>, DrilldownMarker=$true, SkipRewalk=$true,
    #                   IsTerminal=$true (SITE A only)
}
```

### 6.2 Algorithm (ordered — the order IS the spec)

```
Expand-ScriptFile(ScriptPath, WrapperText):
│
├─ 0. GATE      $gate = $script:ScriptDrilldown; if -not $gate → caller never calls (sites check
│              first). Defensive: return $null.
│
├─ 1. TRUST     $hit = Test-TrustedProgram -Token $ScriptPath -Config <config-ref §6.3>
│              if $hit → return $null  (signal: DO NOT EXPAND — the calling SITE emits
│              today's path entry: IsTerminal=$true at SITE A, ParentCommand at SITE B).
│              FILE IS NEVER READ. (D9: trust short-circuits before expansion; today's
│              behavior for every currently-trusted path. Same return as OFF, so the
│              sites treat trusted exactly like feature-off — one code path, no drift.)
│
├─ 2. RESOLVE   $full = ConvertTo-CanonicalWritePath -TargetPath $ScriptPath -Config $gate.Config
│               (ONE call does everything F2 provides: anchors RELATIVE paths to $Config._cwd
│                — the workspace root in production AND under TestRunner -Cwd — unifies
│                separators, strips \\?\, collapses '..'. Do NOT use bare
│                [System.IO.Path]::GetFullPath: it anchors to PROCESS cwd and diverges under
│                -Cwd, breaking every relative fixture case — the sibling v1 bug, fixed in its
│                v2, adopted here. $full doubles as the HT key base in step 4.)
│
├─ 3. EXISTS    if -not (Test-Path -LiteralPath $full -PathType Leaf) →
│                 FAILURE 'script file not found: <ScriptPath> (resolved to <full>)' ; return
│               (NOT inserted into the HT — an unread file consumes no chain slot.)
│
├─ 4. LOOP      $key = (ConvertTo-CanonicalWritePath -TargetPath $full -Config <cfg>).ToLowerInvariant()
│               if $script:DrilldownVisited.ContainsKey($key) →
│                 FAILURE 'recursive script invocation detected: <ScriptPath>' ; return
│               (Same hit covers true recursion a→b→a AND double invocation a;a — spec §9
│                deliberately lumps them; reuse-instead-of-ask is out-of-scope v1.)
│
├─ 5. CAP       if $script:DrilldownVisited.Count -ge $gate.MaxChainedFiles →
│                 FAILURE 'max chained files exceeded (<N>): <ScriptPath>'   (N = MaxChainedFiles)
│
├─ 6. SIZE      $len = (Get-Item -LiteralPath $full).Length
│               if $len -gt $gate.MaxFileBytes →
│                 FAILURE 'script too large to inspect (<len> > <cap>): <ScriptPath>'
│
├─ 7. CLAIM+READ  $script:DrilldownVisited[$key] = $true
│                 $content = [System.IO.File]::ReadAllText($full)
│                 (ReadAllText, NOT Get-Content: BOM-sniffing + UTF-8 default. Several suites
│                  run under powershell.exe 5.1, where Get-Content without -Encoding reads
│                  BOM-less UTF-8 as ANSI → mojibake → AST parse fails → false ask. CRLF/LF fine.)
│                 $stmts   = @(Get-PowerShellCommands -Command $content)   # existing walker (F3/F4)
│
├─ 8. EMPTY/UNPARSABLE
│               if $stmts.Count -eq 0 (zero commands OR AST parse failure — the walker
│               returns @() for both):
│                 $stmts = @(Split-Commands -Command $content -Domain 'powershell')  # regex fallback
│               if STILL 0 →
│                 FAILURE 'script contains no classifiable statements (fail-closed): <ScriptPath>'
│               (Mirrors the codebase doctrine 'AST primary, regex fallback': a script the AST
│                cannot parse still gets classified instead of over-asking. Fallback statements
│                carry NO LineNumber ⇒ their §6-2 reasons omit the '(line N)' suffix — exactly
│                the spec §6 clause 'when a line number is unavailable (regex-fallback path),
│                omit the (line N) suffix'.)
│
├─ 9. EMIT      $out = @()
│               foreach $s in $stmts:
│                 $text = $s.CommandText
│                 a) FALLBACK-PATH RUNNER?  $inv = Find-ScriptRunnerInvocation -SegmentText $text
│                    (Only statements from the step-8 Split-Commands fallback can carry
│                     wrapper text — on the AST path the walker already COLLAPSED every
│                     nested 'pwsh -File z' to the bare path (F11), which 9b handles.
│                     9a exists so the fallback path recurses identically.)
│                    if $inv (statement is 'pwsh [flags] -File z.ps1 [args]'):
│                        $sub = Expand-ScriptFile -ScriptPath $inv.ScriptPath -WrapperText $text
│                        if expansion SUCCEEDED (any STATEMENT in $sub):
│                            emit NESTED-WRAPPER entry (text=$text, Domain='powershell',
│                                SkipRewalk=$true — resolves read_only via the pwsh pattern,
│                                a harmless [N] line like the depth-0 wrapper)
│                            emit all $sub entries (their ParentCommand=$text)
│                        else: emit FAILURE entry = text + sub's AtomicReason (SkipRewalk)
│                 b) INVOCATION-SHAPED? (D13 + RUL-1/RUL-2 — THE recursion rule for AST-walked
│                    statements; also catches COLLAPSED nested -File paths, §6.5)  $text -match
│                       '^\s*([.&]\s*)?(?:"([^"]+\.ps1)"|''([^'']+\.ps1)''|([^\s$''"]+\.ps1))(\s|$)'
│                    — matches '. .\y.ps1', '& .\y.ps1 -Flag', bare '.\y.ps1 -Flag' (RUL-2),
│                      AND the bare 'scripts\z.ps1' entry a nested 'pwsh -File scripts\z.ps1'
│                      collapses to (F11/RUL-1). Path must be the FIRST token (anchored);
│                      the unquoted arm excludes '$' so variable paths stay fail-closed.
│                    if match (literal .ps1 paths ONLY):
│                        $sub = Expand-ScriptFile -ScriptPath <path> -WrapperText $text
│                        if $sub is $null (helper TRUSTED, or feature off mid-tree):
│                            emit the statement KEPT as a plain entry with Domain FORCED to
│                            'powershell' (F12: the walker labels '. x.ps1'/bare paths
│                            'linux', which would miss the Resolver's dot-strip +
│                            Test-TrustedProgram and wrongly ask; forced powershell resolves
│                            trusted_program allow, exactly like a command-line dot-source
│                            today) — with OriginScript + LineNumber; NO SkipRewalk needed
│                        elseif SUCCEEDED (any STATEMENT in $sub): emit $sub entries ONLY
│                            (the invocation statement is
│                            REPLACED, not kept — if kept, it would resolve unknown and
│                            always ask, since '. .\y.ps1' has no read_only wrapper pattern.
│                            Nothing is lost: y's statements fully represent it.)
│                        else: emit FAILURE entry = the statement text + AtomicReason
│                 c) PLAIN: emit STATEMENT entry (NO SkipRewalk — §3.2: the engine's own
│                    walk already unwrapped any nested wrappers, so the re-walk is a
│                    harmless same-text skip (+ attribution); wrapper-shaped texts never
│                    reach here because 9a/9b consumed them):
│                        CommandText=$text, Domain=$s.Domain, IsPipeline=$s.IsPipeline,
│                        ParentCommand=$WrapperText, LineNumber=$s.LineNumber,
│                        OriginScript=<basename of $ScriptPath>,
│                        DisplayText="<script:<basename>> $text"
│               return $out
└─
```

`<basename>` = `[System.IO.Path]::GetFileName($ScriptPath)` — as written, basename only (R10).

**Statement text truncation for reasons:** when a statement is echoed into a §6 reason string,
truncate to 80 characters and append `'...'` when truncated (atomic-reason precedent,
Classifier.ps1 L687).

### 6.3 Config/cwd reference inside the engine

`Expand-ScriptFile` needs `$Config` for `Test-TrustedProgram` and `ConvertTo-CanonicalWritePath`,
but its callers (deep inside the walker) don't carry one. Solution (already sanctioned by F8):
`Load-Config` stashes the live config object on the shared gate:

```powershell
$drill | Add-Member -Force NoteProperty 'Cwd'   "$($config._cwd)"
$drill | Add-Member -Force NoteProperty 'Config' $config     # reference, not a copy
```

Engine reads `$gate.Config` / `$gate.Cwd`. (TestRunner's `-Cwd` override rewrites `$config._cwd`
AFTER Load-Config — see TestRunner.ps1 L31–37 — so ALSO have `Reset-ScriptDrilldownState` refresh
`$script:ScriptDrilldown.Cwd = $gate.Config._cwd` on each classify; one line, keeps `-Cwd`
fixtures correct.)

### 6.4 FAILURE entry construction (all six causes)

```powershell
$entry = [PSCustomObject]@{
    CommandText   = $ScriptPath                 # or the statement text, case (a)/(b) failed
    Domain        = 'powershell'
    IsPipeline    = $false
    ParentCommand = $WrapperText
    AtomicReason  = '<§6-2 reason text>'        # honored verbatim by STEP 4e (F5)
    DrilldownMarker = $true                     # 4e: set MatchedPattern='script-drilldown'
    SkipRewalk    = $true
}
# SITE A additionally sets IsTerminal=$true (single-entry, outer suppressed — today's shape)
```

`MatchedPattern='script-drilldown'` (stamped in 4e, not here — entries are parser-level) makes
these KNOWN blockers, which keeps the AST-arbiter gate closed for drilldown asks. That is
deliberate: the arbiter only re-parses the original command line and cannot see file contents;
letting it run would waste a parse and re-enter the engine (F6) before inevitably returning
'NO'. Decision safety is unchanged (ask stays ask either way).

### 6.5 The walker-collapse fact and nested `-File` (F11 — why 9b IS the RUL-1 mechanism)

The engine reads file content and calls `Get-PowerShellCommands` on it — the SAME walker that
parses command lines, wrapper extraction included. Consequence: a statement `pwsh -File z.ps1`
written INSIDE a script never reaches the emit loop as wrapper text; the walker's own `-File`
branch + `IsTerminal`/`$suppressOuter` collapse it to the bare path entry `z.ps1` (F11).
Dot-source/`&` statements are not wrappers to the walker, so their full text survives.

Three consequences for this design:

1. **RUL-1 is satisfied by 9b, not 9a.** The collapsed bare path `scripts\z.ps1` matches the
   9b invocation regex (first token, ends `.ps1`, no `$`) ⇒ the nested file IS expanded. No
   wrapper `[N]` entry exists for the nested invocation (cosmetic only — its statements carry
   the `<script:z.ps1>` origin). This OVERRIDES the sibling v2's contrary stance (their T16
   asserts the nested file is never read and the command asks) — under their reading the
   collapsed path resolves unknown→ask, which is fail-closed but contradicts the user's
   RUL-1 ruling that nested `-File` chains expand.
2. **9a is fallback-path-only.** Wrapper-shaped statement texts (`pwsh … -File z …`) can only
   originate from the step-8 `Split-Commands` fallback (the regex splitter does not unwrap),
   so 9a exists to give that path identical recursion.
3. **Kept trusted-inner entries need the F12 Domain fix.** When the 9b recursion returns `$null`
   (helper is trusted), the KEPT statement (`. .\helper.ps1` or a collapsed bare path) is
   emitted with `Domain='powershell'` FORCED — otherwise the walker's `Get-CommandDomain`
   label (`linux`, F12) would classify it against Linux tiers and miss the Resolver's
   dot-strip + `Test-TrustedProgram` path, wrongly asking on a trusted helper.

Edge: a collapsed path containing spaces (from a quoted `pwsh -File "C:\my scripts\b.ps1"` —
the entry text is the unquoted VALUE) does NOT match 9b's no-space unquoted arm ⇒ plain entry
⇒ unknown ⇒ ask (fail-closed over-ask, documented; accepted v1 edge, I7-family).

---

## 7. State management

| Item | Value |
|---|---|
| Store | `$script:DrilldownVisited` — plain hashtable, initialized `@{}` at Parser.ps1 load |
| Keys | canonicalized absolute paths: `ConvertTo-CanonicalWritePath(...).ToLowerInvariant()` (D11) |
| Insert | only at engine step 7 (CLAIM) — after loop/cap/size pass |
| Reset | `Reset-ScriptDrilldownState` called at the TOP of STEP 4 in `Invoke-Classify` (before 4a). Cheap; call unconditionally. Also refreshes `$script:ScriptDrilldown.Cwd` (§6.3). |
| Lifetime | one intercepted tool call. Production Hook = one process per call anyway; TestRunner = one process, many cases ⇒ the reset is what makes cases independent. |
| Max work bound | ≤ `MaxChainedFiles` (3) file reads + AST parses per decision (D11/D12) — milliseconds against the 3000 ms hard cap. |

**Engine idempotence (why double extraction is harmless):** the SAME invocation gets extracted
by SITE A and later probed again by the atomic-counting call (F7) / SITE B / the arbiter (F6).
Every re-entry hits step 4 (LOOP) and returns a FAILURE entry **into a list that is discarded**
(SITE B results are dropped when `astCommands>0`; the counting probe only counts; the arbiter
reads only Decision). No file is read twice; no spurious entry survives into `SubResults`. This
is load-bearing — do not "fix" the re-entries, and do not remove the `SkipRewalk` guard that
prevents them from originating inside the walker itself.

---

## 8. Entry shapes & metadata flow

### 8.1 Parser-level entry (what the engine/sites emit)

Standard shape (unchanged): `CommandText, Domain, IsPipeline, ParentCommand`.
Additive properties (all optional; absent on every pre-existing entry):

| Property | Carried by | Meaning | Consumer |
|---|---|---|---|
| `IsTerminal` | SITE A -File results | existing mechanism (outer suppression) | `Get-AstCommands` |
| `LineNumber` | STATEMENT entries | statement's line in its file (`Extent.StartLineNumber`, F4) | 4e reason formatting |
| `OriginScript` | STATEMENT entries | basename of the file the statement came from | 4e/4f formatting; LLM scope `exclude` |
| `DisplayText` | STATEMENT entries | `"<script:<basename>> <statement text>"` | `$subTexts` → LLM prompt + `$log.sent` |
| `SkipRewalk` | pseudo-wrapper, NESTED-WRAPPER, FAILURE entries — NOT plain STATEMENTs | do not re-walk this entry in `Get-AstCommands` (prevents engine re-entry); plain statements keep the re-walk so nested `-Command`/`bash -c` inside scripts still unwrap (§3.2) | `Get-AstCommands` |
| `AtomicReason` | FAILURE entries | pre-computed §6-2 reason | STEP 4e (existing mechanism, F5) |
| `DrilldownMarker` | FAILURE entries | 4e sets `MatchedPattern='script-drilldown'` | STEP 4e/4f, arbiter gate |

### 8.2 `Get-AstCommands` changes (two surgical edits)

1. `AddResult` gains optional `[int]$LineNumber = 0` and `[string]$OriginScript = ''`
   parameters, stored when non-empty. The CommandAst loop passes
   `$cmd.Extent.StartLineNumber`. (Walker-level statements inside function bodies get their
   true lines via the existing ScriptBlockAst recursion, F3.)
2. The per-inner-result re-walk block becomes:
   ```powershell
   if ($innerDom -eq 'powershell' -and -not ($wr.PSObject.Properties['SkipRewalk'])) { ... }
   ```
   Everything else in the function is untouched. The `$suppressOuter` / `IsTerminal` mechanics
   are untouched (they already do what we need — see §3.2 pseudo-wrapper).
3. **Origin attribution for re-walk children:** inside the (unskipped) re-walk loop, when the
   SOURCE entry `$wr` carries `OriginScript`, pass it (and a `DisplayText` built from the
   child's text) onto the entries the re-walk adds — so the inner `Remove-Item` extracted from
   a script's `pwsh -Command "Remove-Item x"` statement still logs as
   `<script:x.ps1> Remove-Item x` and gets the §6-2 reason template. Deeper descendants
   (wrapper-inside-string-inside-wrapper) classify correctly but display unprefixed —
   documented v1 cosmetic limit.

### 8.3 SubResult additions (stamped in STEP 4e)

After `$r = Resolve-Command ...` (Classifier.ps1 ~L774), copy the additive props:

```powershell
if ($sc.PSObject.Properties['OriginScript']) {
    $r | Add-Member -Force NoteProperty 'OriginScript' $sc.OriginScript
    if ($sc.PSObject.Properties['LineNumber']) { $r | Add-Member -Force NoteProperty 'LineNumber' $sc.LineNumber }
    if ($sc.PSObject.Properties['DisplayText']) { $r | Add-Member -Force NoteProperty 'DisplayText' $sc.DisplayText }
    # §6-2 reason formatting for blocking statements (modifying OR unknown):
    if ($r.Decision -eq 'ask') {
        $stmt = $sc.CommandText; if ($stmt.Length -gt 80) { $stmt = $stmt.Substring(0,80) + '...' }
        $kind = if ($r.MatchedPattern) { 'modifying command' } else { 'unknown command' }
        $line = if ($sc.LineNumber) { " (line $($sc.LineNumber))" } else { '' }
        $r.Reason = "script $($sc.OriginScript) contains ${kind}: ${stmt}${line}"
    }
}
```

And in the existing AtomicReason branch of 4e (~L760): when `$sc.PSObject.Properties['DrilldownMarker']`,
set `MatchedPattern = 'script-drilldown'` on the built SubResult (keeps the arbiter gate closed,
§6.4). Leave all other AtomicReason behavior identical.

### 8.4 STEP 4f aggregation edit

In the blocking-reason builder (Classifier.ps1 ~L905–920), add ONE branch FIRST:

```powershell
if ($bc.PSObject.Properties['OriginScript'] -and $bc.Reason) { $blockingReasons.Add("$($bc.Reason)") }
elseif ($bc.MatchedPattern -and $bc.Risk) { ... existing ... }
```

so script-origin blockers print their §6-2 formatted reason instead of `copy-item (high)`, while
KEEPING their real `MatchedPattern` (they remain known blockers for the arbiter gate). FAILURE
entries already carry `MatchedPattern='script-drilldown'` + their AtomicReason as Reason, so the
existing `else { $bc.Reason }` arm prints them — the new branch simply also covers them.

---

## 9. LLM integration (spec R16/R17, D15)

1. **One request for everything — already true.** All SubResults from the whole tool call (wrapper
   + every file's statements) form one flat numbered list; `Get-LlmReviewVerdict` is called once
   (LlmReview.ps1 L775). NO new code for R17.
2. **`llm_scope`** — in `Test-LlmReviewScope` right after `$subs` is built (L200–206):
   ```powershell
   $llmScope = 'count'
   if ($llm.PSObject.Properties['LlmScope']) { $llmScope = "$($llm.LlmScope)" }
   if ($llmScope -eq 'exclude') {
       $subs = @($subs | Where-Object { -not ($_.PSObject.Properties['OriginScript']) })
   }
   ```
   (`LlmScope` must be added to the compiled `$llmCompiled` object in Load-Config — default
   `'count'`; reads from the SAME `script_drilldown.llm_scope` value, published onto the llm
   compiled block for single-sourced access.) `count` (default): statements count toward
   `complex_min_subcommands` ⇒ a standalone expanded script (≥2 entries) IS reviewed. `exclude`:
   script-origin entries are absent from both the count and the sent list — the LLM never sees
   them and cannot flag them.
3. **DisplayText** — in `Invoke-LlmReview` (~L747):
   ```powershell
   $subTexts = @($scope.SubCommands | ForEach-Object {
       if ($_.PSObject.Properties['DisplayText']) { "$($_.DisplayText)" } else { "$($_.Command)" }
   })
   ```
   `$log.sent` and the numbered `<sub_commands>` prompt both come from `$subTexts` ⇒ the
   `<script:basename>` prefix appears in LLM-SENT exactly as in spec §7.
4. **Interactions (no code needed, verify in tests):**
   - The `llm-skipped-trusted-editable` short-circuit (Invoke-LlmReview L703–722) skips the call
     when EVERY in-scope sub is trusted/editable — statements rarely carry those tiers; behavior
     stands as-is.
   - `check_blindspot`: FAILURE entries carry Tier `unclassified`, which is in the blindspot tier
     list ⇒ drilldown asks get the (decision-neutral) consult + enriched reason, like every other
     unknown today. Spec §11: unchanged.
   - Attributed merge: statements have ordinary tiers (`read_only`/`modifying`/…) — flagged
     statements veto exactly like command-line statements. `trusted_program` suppression etc.
     unchanged.

---

## 10. Log output (target — spec §7, byte-format)

```
[2026-09-20 …] IDE:Copilot Tool:[run_in_terminal] Decision:[ask] Time:[…]
  Reason: script restore-copilot-chat.ps1 contains modifying command: Copy-Item ... (line 42)
  Command: ___ [powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\...\restore-copilot-chat.ps1 -Date 08/09/2026 -List] ___
  LLM-SENT      : [ 4 subcommand ] | model=GLM-5.3 timeout=30000ms | [1] powershell -NoProfile ... restore-copilot-chat.ps1 -Date 08/09/2026 -List | [2] <script:restore-copilot-chat.ps1> Get-ChildItem $targetDir | [3] <script:restore-copilot-chat.ps1> Write-Host "restoring..." | [4] <script:restore-copilot-chat.ps1> Copy-Item ...
  LLM-LOCAL     : decision=ask (...); tiers: [1]=read_only [2]=read_only [3]=read_only [4]=modifying
```

Rendering path (NO Logger change): `[1]` is the wrapper entry (read_only via the
`pwsh(?:\.exe)? *` pattern, config.json L485); `[2..n]` render from `$log.sent` (DisplayText);
tiers from `$log.tiers`; the Reason is the STEP 4f aggregation with the §8.4 branch. Entries are
truncated at 120 chars by the existing formatter. `records.jsonl` picks up the additive
SubResult properties wherever SubResults are serialized — verify during GREEN.

---

## 11. Worked examples (entry-order walkthroughs)

### 11.1 Untrusted script, one modifying statement (the spec §7 case)

Input: `powershell -NoProfile -ExecutionPolicy Bypass -File C:\sk\restore-copilot-chat.ps1 -Date 08/09/2026 -List`
domain=powershell ⇒ SITE A. Engine: not trusted → found → not in HT → size ok → read →
statements `[Get-ChildItem $targetDir, Write-Host "restoring...", Copy-Item -Path ... (line 42)]`.

```
allCommands (in order)                      SubResults after 4e
[1] powershell -NoProfile ... -File ...   → read_only
[2] Get-ChildItem $targetDir              → read_only   DisplayText '<script:restore-copilot-chat.ps1> Get-ChildItem $targetDir'
[3] Write-Host "restoring..."             → read_only   ...
[4] Copy-Item -Path ...                   → ask/modifying, Reason 'script restore-copilot-chat.ps1
                                                           contains modifying command: Copy-Item ... (line 42)'
```
4f: ask, Reason as above. LLM scope (count): 4 ≥ 2 ⇒ one call, list = the four DisplayTexts.

### 11.2 Chain a → b → c (cap boundary)

`pwsh -File scripts\a.ps1`; a dot-sources `b.ps1` (literal path); b dot-sources `c.ps1`; c
dot-sources `d.ps1`. HT grows a(1), b(2), c(3); d hits step 5 (3 ≥ 3) ⇒ FAILURE
`max chained files exceeded (3): <d-path>`; decision ask with that reason (plus c's read-only
statements listed as SubResults).

### 11.3 Loop

a dot-sources b, b dot-sources a ⇒ at the second a, step 4 fires:
`recursive script invocation detected: <a>` ⇒ ask. Double invocation
(`pwsh -File a.ps1; pwsh -File a.ps1`) hits the same check (spec §9 row 7) ⇒ ask.

### 11.4 Trusted script (live-config reality)

`pwsh -File src\Run-AllTests.ps1` with live regex `src\\.*\.ps1$`: engine step 1 ⇒ TRUSTED entry,
file never read, ONE sub-command, Tier trusted_program, LLM below threshold ⇒ fast allow —
byte-identical to today (D9; spec fact #12: in the live env, temp/ and src/ scripts are never
expanded; drilldown's live effect concentrates on non-trusted paths).

### 11.5 Compound, linux domain (2026-09-17 shape)

`cd c:\work; pwsh -NoProfile -File scripts\probe.ps1` — domain=linux (leading `cd`), 4b-2 skipped,
SITE B expands the pwsh SEGMENT. parentTexts filter drops the raw segment; entries:
`[1] cd c:\work` (its own resolution), `[2] pwsh -NoProfile -File scripts\probe.ps1` (wrapper,
read_only), `[3..]` statements. The incident's untrusted-script-must-ask property is
STRENGTHENED (content now visible).

### 11.6 Script invoking another script (the collapse path — RUL-1's mechanism)

Script y contains `pwsh -File helpers\clean.ps1 -Mode dry`. The engine's own walk of y's content
COLLAPSES that statement to the bare entry `helpers\clean.ps1` (F11 — the walker runs its
`-File` branch at file level too, so the wrapper text never survives). Step 9b's invocation rule
matches the bare path ⇒ recursion into clean.ps1 ⇒ y's entry list = clean's statements
(`<script:clean.ps1> ...`); no wrapper `[N]` entry exists for the nested invocation (cosmetic —
the collapsed form simply replaces it). If clean.ps1 were missing ⇒ the kept statement carries
`script file not found: helpers\clean.ps1 (resolved to <full>)` ⇒ ask. If clean.ps1 were
TRUSTED ⇒ the kept statement (Domain forced 'powershell', F12) resolves trusted_program ⇒ allow.
(Without 9b catching the collapsed path it would resolve unknown → ask — fail-closed but
over-asking; the sibling v2 chose exactly that stance and pinned it as their T16 — OVERRIDDEN
here by RUL-1/RUL-2: the collapsed path IS the invocation, so we expand it.)

---

## 12. Edge cases & invariants (security review)

| # | Invariant / edge | How the design upholds it |
|---|---|---|
| I1 | OFF ⇒ byte-identical | Both sites check `$script:ScriptDrilldown` first; OFF returns today's code path. `Test-LlmReviewScope` filter and `DisplayText` fallback are no-ops without the props. Baseline 1360 holds by construction (no fixture config has the block). |
| I2 | Trusted ⇒ never read | Engine step 1 before ANY filesystem touch; same entry shape as today. |
| I3 | Untrusted script never silently allowed | Expansion emits every statement; worst-case-wins aggregates. FAILURE paths all ⇒ ask. |
| I4 | 2026-09-17 fix intact | Per-segment SITE B call, parentTexts filter, wrapper suppression untouched; drilldown only replaces what the -File branch EMITS. |
| I5 | `pwsh -File a.ps1 -Command "Remove-Item x"` | `hasFileBeforeCommand` guard (SITE B ~L633) + SITE A terminal early-return unchanged; `-Command` stays script-$args. Expansion sees only a.ps1's statements. |
| I6 | Function bodies classified as-if-run (R11) | Existing ScriptBlockAst recursion (F3) — zero new code; line numbers correct. |
| I7 | Dynamic constructs fail closed (R13 + RUL-1/2) | `& $p` (variable path), `iex $x`, `Start-Process` hiding: no matcher/rule hit ⇒ plain statement ⇒ unknown ⇒ ask. Literal forms — `.`/`&` operator AND bare `.\x.ps1` — ARE expanded (user ruling 2026-09-20, RUL-2). |
| I8 | Arbiter cannot rescue drilldown asks | FAILURE entries are known blockers (`script-drilldown`); modifying statements keep real MatchedPattern; unknown statements may open the gate but the arbiter resolves the untrusted wrapper to 'NO' (it re-enters SITE B via F6, hits LOOP, returns failure entries ⇒ 'NO'). Ask stands. |
| I9 | Re-entrant extraction harmless | §7 idempotence + scoped `SkipRewalk` (§3.2). |
| I9b | Wrappers nested INSIDE expanded scripts still unwrap | Plain STATEMENT entries are re-walkable (no SkipRewalk), so `pwsh -Command "…"` / `bash -c '…'` statements inside a script decompose exactly as they would typed at depth 0; their children inherit `OriginScript` (§8.2.3). Pinned by SD-Ask-CommandInsideScript. |
| I10 | Same statement text twice in one file | `AddResult` dedup key `text<<|>>parent` — second occurrence dropped (same classification; cosmetic only). |
| I11 | `& 'C:\...\pwsh.exe' -File y.ps1` (regex path) | SITE B normalizes to `pwsh …`; emitted wrapper text = normalized form; raw segment may survive the parentTexts filter (normalization ≠ raw) ⇒ possible duplicate read_only wrapper entry. Pre-existing quirk (today: segment + path entry); acceptable, documented. |
| I12 | Statement domains inside scripts | `Get-AstCommands` assigns per-CommandAst domains — `git status` inside a .ps1 classifies against Linux patterns. Cross-language statements can't be matcher-expanded in v1 ⇒ unknown ⇒ ask (fail-closed). |
| I13 | Max work | ≤ 3 reads + parses (D11/D12); LLM latency governed by D15 (~9.4 s observed, user-accepted). |
| I14 | Timeout / exit codes / Codex mapping / ask toast | Untouched paths. |
| I15 | Symlink / junction aliases | Canonicalization is TEXTUAL (no `Resolve-Path`) — a loop traversed via two names of the same physical file is NOT detected; the count cap still bounds total work. Accepted v1 limitation. |
| I16 | `-File $var` (non-literal) | Matcher captures the literal token `$var`; `$` is a legal Windows filename char, so resolution "succeeds" to a path containing it; `Test-Path` fails ⇒ not-found FAILURE ⇒ ask (fail-closed, informative). |
| I17 | Script file encoding | `[System.IO.File]::ReadAllText` (BOM sniffing, UTF-8 default, engine step 7) — PS 5.1 `Get-Content` without `-Encoding` would read BOM-less UTF-8 as ANSI and break the parse. `.PS1`/mixed case extensions match everywhere `-match` is used (case-insensitive by default). |
| I18 | Nested `pwsh -File` inside scripts (F11/RUL-1) | The walker collapses it to the bare path; 9b expands that path (§6.5). Variable/`$`-containing or spaced collapsed paths miss 9b ⇒ unknown ⇒ ask (fail-closed). |
| I19 | Trusted dot-sourced / bare helper inside a script (F12) | 9b's `$null` branch keeps the statement with `Domain='powershell'` FORCED so the Resolver's dot-strip + `Test-TrustedProgram` can allow it; unforced, the walker's `linux` label would wrongly ask. Pinned by SD-Allow-TrustedDotSource. |

---

## 13. Test design (spec D16/R18 — write RED before any src/ change)

### 13.1 Fixture layout

```
test/config/script-drilldown/
    config.json            drilldown ON: {enabled:true, runners:["powershell"],
                           max_chained_files:3, max_file_bytes:4096, llm_scope:"count"}
                           + minimal PowerShell domain (pwsh wrapper read_only pattern, a few
                           read_only cmdlets: Get-ChildItem/Write-Host/Get-Content, modifying:
                           Copy-Item/Remove-Item/Set-Content) + trusted_programs:["trusted.ps1"]
                           (basename form — matches anywhere)
    config.off.json        identical MINUS the script_drilldown block (OFF-parity)
    config.badrunner.json  runners:["python"]                     (Load-Config must throw)
    config.badscope.json   llm_scope:"sometimes"                  (Load-Config must throw)
    config.badcap.json     max_chained_files:0                    (Load-Config must throw)
    config.trustonly.json  drilldown ON but trusted_programs covers everything under scripts\
                           (proves D9 short-circuit without reading files)
    Run-Tests.ps1          preflights + TestRunner invocations (mirrors
                           test/config/trusted-programs-regex/Run-Tests.ps1 house style) + one
                           PROGRAMMATIC absolute-path check (SDD-AbsolutePath, §13.3)
    test-cases.xml         core matrix (below) — run with -Cwd <fixtureDir> so relative
                           script paths anchor (F9). NEVER the repo-root live config (CLAUDE.md).
    test-cases.off.xml     OFF-parity matrix — same commands, expected = TODAY's outcomes
    test-cases.llm.xml     llm_scope matrix — run by test/config/llm-review/Run-Tests.ps1
                           (mock verdicts, zero quota) — needs the runner extensions in §13.4
    scripts/
        trusted.ps1            Get-ChildItem only (trusted via trusted_programs basename)
        readonly.ps1           Get-ChildItem $env:TEMP; Write-Host "ok"     (allow case)
        modifying.ps1          read-only lines, then Copy-Item at a KNOWN line (pin: line 7)
        func-body.ps1          function Clean { Remove-Item C:\temp\x } ; Clean   (R11)
        chain-a.ps1            . .\chain-b.ps1 ; Write-Host a
        chain-b.ps1            . .\chain-c.ps1 ; Write-Host b
        chain-c.ps1            Write-Host c
        loop-a.ps1             . .\loop-b.ps1 ; Write-Host a
        loop-b.ps1             . .\loop-a.ps1 ; Write-Host b        (loop via D13 dot-source)
        file-loop-a.ps1        pwsh -File scripts\file-loop-b.ps1 ; Write-Host a
        file-loop-b.ps1        pwsh -File scripts\file-loop-a.ps1 ; Write-Host b
                               (loop via nested -File: walker COLLAPSES each to the bare
                                path (F11) → 9b recursion → loop ask; the OTHER chain form)
        dotsrc-trusted.ps1     . scripts\trusted.ps1 ; Write-Host ok
                               (dot-sources the TRUSTED script → 9b $null branch → kept
                                statement, Domain forced 'powershell' (F12) → trusted allow)
        target2.ps1            read-only only (target of dot-with-args / bare-call)
        cap-a/b/c/d.ps1        chain of four (cap hit at d)
        calls-nested.ps1       pwsh -File scripts\nested-target.ps1 ; Write-Host n
        nested-target.ps1      Get-Content C:\temp\log.txt
        nested-missing.ps1-invoking script: calls 'pwsh -File scripts\no-such.ps1'
        cmd-inside.ps1         pwsh -Command "Remove-Item C:\temp\x" ; Write-Host done
                               (modifying command hidden behind a nested -Command wrapper —
                                pins the SkipRewalk SCOPE: must still unwrap and ask)
        assignments-only.ps1   $x = 1 + 2 (zero commands ⇒ no-statements ask)
        big.ps1                > 4096 bytes (pad with comment lines; deterministic)
        dot-with-args.ps1      & scripts\target2.ps1 -Flag          (D13 with args)
        bare-call.ps1           scripts\target2.ps1 -Flag           (bare literal call, no
                               operator — expanded per RUL-2 / user ruling 2026-09-20)
```

### 13.2 Core case matrix (test-cases.xml; assertions use `expected`, `reason-contains`,
`subresult-tier`, `subresult-reason-contains` — F9)

| ID | command (CDATA, tool Bash) | expected | assertions |
|---|---|---|---|
| SD-Allow-ReadOnly | `pwsh -NoProfile -File scripts\readonly.ps1` | allow | — |
| SD-Ask-Modifying | `pwsh -NoProfile -File scripts\modifying.ps1` | ask | reason-contains `script modifying.ps1 contains modifying command: Copy-Item` and `(line 7)` |
| SD-WrapperEntry | (same as SD-Allow-ReadOnly) | allow | subresult-tier `read_only` present ≥2 (wrapper + statements) |
| SD-DisplayMarker | (same as SD-Allow-ReadOnly) | allow | (LLM-suite asserts the `<script:…>` prefix; here: subresult-reason-contains is n/a) |
| SD-Allow-Trusted | `pwsh -NoProfile -File scripts\trusted.ps1` | allow | subresult-tier `trusted_program`; OFF-parity twin asserts identical decision+tier |
| SD-Ask-NotFound | `pwsh -File scripts\no-such.ps1` | ask | reason-contains `script file not found: scripts\no-such.ps1` |
| SD-Ask-TooLarge | `pwsh -File scripts\big.ps1` | ask | reason-contains `script too large to inspect (` and `> 4096` |
| SD-Ask-NoStatements | `pwsh -File scripts\assignments-only.ps1` | ask | reason-contains `script contains no classifiable statements (fail-closed)` |
| SD-Ask-Loop | `pwsh -File scripts\loop-a.ps1` | ask | reason-contains `recursive script invocation detected` (via D13 dot-source) |
| SD-Ask-LoopViaFile | `pwsh -File scripts\file-loop-a.ps1` | ask | reason-contains `recursive script invocation detected` (loop via nested `-File` → collapsed bare path → 9b recursion, §6.5) |
| SD-Ask-Cap | `pwsh -File scripts\cap-a.ps1` | ask | reason-contains `max chained files exceeded (3)` |
| SD-Allow-Chain3 | `pwsh -File scripts\chain-a.ps1` | allow | — |
| SD-Allow-NestedFile | `pwsh -File scripts\calls-nested.ps1` | allow | — (OVERRIDES sibling v2's T16: the collapsed nested path IS expanded per RUL-1/§6.5, so nested-target's statements appear; assert via LLM-suite sent-list or subresult count ≥ 3) |
| SD-Allow-TrustedDotSource | `pwsh -File scripts\dotsrc-trusted.ps1` | allow | subresult-tier `trusted_program` — pins the F12 forced-Domain fix (unforced, the kept dot-source statement is `linux` → wrong ask) |
| SD-Ask-NestedMissing | `pwsh -File scripts\calls-missing.ps1` | ask | reason-contains `script file not found` |
| SD-Ask-FuncBody | `pwsh -File scripts\func-body.ps1` | ask | reason-contains `script func-body.ps1 contains modifying command: Remove-Item` |
| SD-Ask-CommandInsideScript | `pwsh -File scripts\cmd-inside.ps1` | ask | reason-contains `Remove-Item` — a modifying command hidden behind `pwsh -Command "…"` INSIDE a script must still be unwrapped and ask (SkipRewalk is scoped to wrapper-shaped entries only, §3.2) |
| SD-Allow-DotWithArgs | `pwsh -File scripts\dot-with-args.ps1` | allow | — |
| SD-Allow-BareCall | `pwsh -File scripts\bare-call.ps1` | allow | bare literal `.ps1` statement (no `.`/`&` operator) is expanded too (RUL-2) |
| SD-Ask-DoubleInvoke | `pwsh -File scripts\readonly.ps1; pwsh -File scripts\readonly.ps1` | ask | reason-contains `recursive script invocation detected` |
| SD-Compound-Cd | `cd c:\work; pwsh -NoProfile -File scripts\readonly.ps1` | allow | — |
| SD-Ask-UntrustedUnknownStmt | script containing `[Foo]::Bar()` line | ask | reason-contains `contains unknown command` |
| SD-Relative-ForwardSlash | `pwsh -File scripts/readonly.ps1` | allow | — |

(Where a case needs a script variant not listed in §13.1 — e.g. `calls-missing.ps1`,
unknown-statement script — add it; the table is the contract, the files serve it. Line numbers in
`reason-contains` assertions must match the committed fixture files exactly — recheck after any
edit to those files.)

### 13.3 Preflights (Run-Tests.ps1, mirroring TPR-BadRegex style)

| ID | check |
|---|---|
| SDD-BadRunner | `Load-Config config.badrunner.json` throws, message contains `runners` |
| SDD-BadScope | throws, message contains `llm_scope` |
| SDD-BadCap | throws, message contains `max_chained_files` |
| SDD-CompiledPresent | `config.json` ⇒ `_compiled.scriptDrilldown` non-null with `Runners=@('powershell')`, caps 3/4096, LlmScope `count` |
| SDD-OffNoCompile | `config.off.json` ⇒ `_compiled.scriptDrilldown` `$null` |
| SDD-OFF-Parity | run test-cases.off.xml — every case must yield TODAY's decision (the untrusted `-File` asks, trusted allows, etc.) |
| SDD-AbsolutePath | programmatic (in Run-Tests.ps1, not static XML — the fixture dir is machine-specific): build `pwsh -NoProfile -File "$fixtureDir\scripts\readonly.ps1"`, invoke Invoke-Classify directly with the fixture config, assert allow — covers D8 absolute-path-as-is without baking an absolute path into the XML |

### 13.4 LLM sub-suite (test-cases.llm.xml — run by the llm-review fixture runner)

The llm-review runner loads ITS OWN config (test/config/llm-review/config.json) and has no
`-Cwd`; extend it with two OPTIONAL parameters (backward-compatible defaults):
`-ConfigPath` (default: current fixture config) and `-Cwd` (default: none; when set, rewrite
`$config._cwd`/`_cwdNorm` after Load-Config exactly like TestRunner L31–37). Then:

`test-cases.llm.xml` with runner invocation
`Run-Tests.ps1 -XmlPath test\config\script-drilldown\test-cases.llm.xml -ConfigPath test\config\script-drilldown\config.llm.json -Cwd <fixtureDir>`
where `config.llm.json` = drilldown config + a minimal `llm_second_opinion` block
(`enabled:true, level:"complex_commands", complex_min_subcommands:2, attributed_verdicts:true` —
copy the shape from test/config/llm-review/config.json). Cases (mock via
`PRETOOLHOOK_LLMREVIEW_MOCK=idx:N`, F10):

| ID | scenario | mock | expected |
|---|---|---|---|
| SDL-Count-InScope | `pwsh -File scripts\readonly.ps1` (3 entries ≥ 2) | `idx:` (empty) | in scope; `idx:` empty yields `{"modifying":[]}` ⇒ read-only verdict ⇒ agree-allow |
| SDL-Count-Veto | same | `idx:2` | ask; log shows flagged=[2] suppressed=[] veto=[2] |
| SDL-Exclude-Out OfScope | `config.llm.exclude.json` (llm_scope exclude) same command | — | out of scope (only wrapper entry counts ⇒ 1 < 2), verdict not_called |
| SDL-SentDisplayText | any in-scope case | `idx:` | log assertion: `LLM-SENT` line contains `<script:readonly.ps1>` |
| SDL-One-Request-Chained | chain-a (statements from a+b+c in ONE list) | `idx:3` | single verdict indices span files |

Plan B (borrowed from cross-review, if the `-ConfigPath`/`-Cwd` runner extensions prove
awkward): unit-level scope assertions inside this fixture's `Run-Tests.ps1` — dot-source the
modules, build a synthetic ClassifyResult whose SubResults carry `OriginScript`, and assert
`Test-LlmReviewScope` output directly for both `llm_scope` modes; keeps the coverage in this
fixture dir with zero llm-review runner changes.

### 13.5 Suite registration

`src/Run-AllTests.ps1` `$extraSuites` += (house style of the R1/R2/R3 entries):
`@{ Name='script-drilldown'; File='test\config\script-drilldown\Run-Tests.ps1'; Args=@() }` and
`@{ Name='script-drilldown.llm'; File='test\config\llm-review\Run-Tests.ps1'; Args=@('-XmlPath', '<…>\test-cases.llm.xml', '-ConfigPath', '<…>\config.llm.json', '-Cwd', '<fixtureDir>') }`.

### 13.6 RED expectations

Before any src/ change: every ON-case fails (no expansion ⇒ e.g. SD-Allow-ReadOnly gets ask via
unknown path), preflights SDD-BadRunner/BadScope/BadCap fail (no validation), SDD-CompiledPresent
fails. OFF-parity and SDD-OffNoCompile PASS already (feature absent = today). Record the RED
count in PROGRESS.md, then implement to GREEN, then full `Run-AllTests.ps1` (1360 + new, zero
flips).

---

## 14. Implementation plan (single red/green cycle, spec D19 — ordered)

1. **Fixtures first (RED):** create §13.1 tree + cases + runner; register suites; run; record RED.
2. **ConfigLoader:** §4 validation + compile + `$script:ScriptDrilldown` publish (+ `LlmScope`
   onto llm compiled block). → preflights + OFF cases green; ON cases still red.
3. **Parser:** registry + dispatcher (§5); `LineNumber` in `AddResult`; `SkipRewalk` guard;
   `Reset-ScriptDrilldownState`; `Expand-ScriptFile` (§6); wire SITE A and SITE B -File branches
   (§3.2 table). → most core cases green.
4. **Classifier:** reset call at STEP 4 entry; 4e stamping + reason formatting + `DrilldownMarker`
   ⇒ `MatchedPattern='script-drilldown'`; 4f OriginScript reason branch (§8.3/8.4).
5. **LlmReview:** `LlmScope` filter + `DisplayText` (§9). → llm sub-suite green.
6. **Generic config.json:** explicit disabled `script_drilldown` block with `_comment_*` (§4.1);
   re-sync `test/config/live` via its Sync-Fixtures.ps1 (house rule).
7. **Docs:** CURRENT-DESIGN.md §1 pipeline diagram (+drilldown box), §2 module table rows,
   §4 schema; `docs/config-json-guide.md` new `script_drilldown` section; spec status →
   IMPLEMENTED with the GREEN counts.
8. **Full regression:** `Run-AllTests.ps1` — expect 1360 + ~25 new, zero flips. Update PROGRESS.md.

---

## 15. Acceptance criteria

- [ ] Every §13 case + preflight green; OFF-parity proves byte-identical behavior with the block
      absent (decisions + tiers identical on the OFF twin matrix).
- [ ] Full `Run-AllTests.ps1` green, zero regressions vs the 1360 baseline.
- [ ] Spec §6 reason strings emitted verbatim for all six causes (asserted via `reason-contains`).
- [ ] Spec §7 log shape reproduced by an SDL case (LLM-SENT `[2] <script:…>` prefix, tiers line).
- [ ] R17: ONE `Get-LlmReviewVerdict` call covering wrapper + all chained files (SDL-One-Request).
- [ ] Trusted paths never read (SD-Allow-Trusted + trustonly config variant).
- [ ] ≤3 reads per decision (cap case proves the bound).
- [ ] Docs updated (CURRENT-DESIGN §1/§2/§4, config-json-guide); generic config ships disabled
      block; spec status flips to IMPLEMENTED.

## 16. Extension guide (v2 and beyond — DO NOT build now)

- **Python (R2):** add a registry entry (§5 sketch) + extend the validation set
  `{ 'powershell', 'python' }`; nothing else changes — matcher output feeds the same engine; the
  engine's statement walk for .py files would need a Python-aware splitter (token loop) instead
  of `Get-PowerShellCommands`. At that point revisit spec Q1 Option C (dedicated stage).
- **Depth-0 dot-source** (`. .\x.ps1` typed by the agent): run the D13 rule at SITE-B segment
  level pre-classification.
- **Reuse-on-double-invocation:** cache STATEMENT arrays per canonical path per tool call and
  replay instead of LOOP-ask (spec §8 follow-up).
- **Safe-expression certification for assignment-only scripts:** feed file content through
  `Get-PowerShellSafeExpressions` before declaring "no classifiable statements".

---

## Appendix A — reason-string contract (copy of spec §6; the assertable truth)

| Cause | Reason text |
|---|---|
| Chain cap hit | `max chained files exceeded (3): <path>` |
| Loop detected | `recursive script invocation detected: <path>` |
| Size cap hit | `script too large to inspect (<size> > 4096): <path>` |
| File not found | `script file not found: <orig> (resolved to <full>)` |
| No classifiable statements | `script contains no classifiable statements (fail-closed): <path>` |
| Modifying statement found | `script <basename> contains modifying command: <statement> (line N)` |

`<path>` = path as written; `<full>` = workspace-root-anchored resolution; `(line N)` omitted on
the regex-fallback path when no line is known; multiple causes joined by the existing
worst-case-wins aggregation. Design-documented addition (consistent with R15, asserted by
SD-Ask-UntrustedUnknownStmt, wording user-accepted 2026-09-20 — RUL-3): unknown
statements render `script <basename> contains unknown command: <statement> (line N)`.

## 17. Rulings register (user Q&A, 2026-09-20)

The requirement spec lives with the sibling draft (`docs/superpowers/specs/sibling/`) and is not
edited by us; user rulings from the 2026-09-20 clarification round are recorded HERE and bind
this design (fold them into whichever spec becomes canonical):

- **RUL-1 (extends D13/R13):** a `pwsh -File z.ps1` statement INSIDE an expanded script is
  expanded exactly like dot-source/`&` (same trust → HT → cap → size → read ladder). The intent
  was always present — R12's "chained files" are chains of any invocation form — but D13's
  letter named only the `.`/`&` operators; now explicit. Security: NOT expanding them would
  open a hole unique to drilldown-on (the statement resolves read_only via the pwsh wrapper
  pattern and the nested file would never be inspected). Implemented by engine step 9b — the
  walker COLLAPSES the nested `-File` statement to its bare path (F11), and 9b's invocation
  rule expands that path (§6.5); step 9a + the matcher guard (§5) cover the Split-Commands
  fallback path where wrapper texts survive.
- **RUL-2 (extends D13/R13):** a BARE literal script call — a statement whose FIRST token is a
  literal (quoted or unquoted, no `$`) `.ps1` path with no `.`/`&` operator, e.g.
  `.\helper.ps1 -Flag` — is expanded like dot-source/`&`. Rationale (user): "the .\x.ps1 will
  be executed by PowerShell." Variable paths (`& $p`), `iex`, and `Start-Process` forms remain
  fail-closed unknown→ask. Implemented by engine step 9b's extended regex.
- **RUL-3 (supplements D14):** an UNKNOWN statement inside a script renders
  `script <basename> contains unknown command: <statement> (line N)` — same shape as the
  modifying row (wording user-accepted). §8.3 implements it.
- **RUL-4 (supplements D1):** expansion-failure entries are a SINGLE SubResult (path-only,
  today's shape) whose Reason IS the §6-2 cause string — every failure ask states its error
  type (not-found / too-large / loop / cap / no-statements). §6.4 implements it; already how
  the design read, user-confirmed.
- **RUL-5 (defines D15):** `llm_scope:"exclude"` means **entire exclusion** — script-origin
  entries are removed from BOTH the `complex_min_subcommands` count AND the numbered list sent
  to the LLM (user-confirmed 2026-09-20). §9.2 already implements exactly this; no change.
- **RUL-6 (defines §5 schema edge):** an explicitly empty `runners: []` under `enabled:true`
  **throws at load** — `runners must list at least one implemented runner` (user-confirmed
  2026-09-20). §4.2 rule 4 already implements exactly this; no change.

**Sibling v2 cross-review (2026-09-20, final):** v2 fixed its v1's two hard bugs (path
anchoring via `ConvertTo-CanonicalWritePath` — adopted, §6.2 step 2; SITE A ordering via the
pseudo-wrapper — it adopted ours) and contributed the empirically verified collapse fact (F11)
plus the trusted-inner Domain fix (F12) — both folded in (§6.2 step 9b, §6.5). Its remaining
stance — that nested `pwsh -File` cannot be expanded in v1 and must ask (its T16) — is
OVERRIDDEN by RUL-1/RUL-2: the collapsed bare path is itself an invocation-shaped statement,
so 9b expands it; no pre-collapse AST interception (v2's suggested v2 mechanism) is needed.
Its `Get-StatementLineMap` double-parse was not adopted (our `AddResult` LineNumber threading
is single-parse, §8.2); its blanket `SkipRewalk` was not adopted (scoped, §3.2); its
2-entry failure layout was not adopted (RUL-4 keeps one entry).

All six clarification points are settled; the spec's settled decisions (R1–R19, D1–D16) were
verified against the code during design and needed no correction. This document is FINAL and
implementation-ready — proceed with §14.

## Appendix B — file-by-file change checklist

| File | Changes |
|---|---|
| `src/Parser.ps1` | registry + `Find-ScriptRunnerInvocation`; `Expand-ScriptFile`; `Reset-ScriptDrilldownState`; `$script:DrilldownVisited` init; SITE A + SITE B rewiring; `AddResult` LineNumber; `SkipRewalk` guard |
| `src/Classifier.ps1` | STEP 4 reset call; 4e stamping/formatting/`script-drilldown` MatchedPattern; 4f OriginScript reason branch |
| `src/ConfigLoader.ps1` | `script_drilldown` validation + compile + `$script:ScriptDrilldown` publish; `LlmScope` onto llm compiled block |
| `src/LlmReview.ps1` | scope `exclude` filter; `$subTexts` DisplayText |
| `src/Logger.ps1` | none |
| `src/Resolver.ps1`, `src/Hook.ps1`, `src/HookAdapter.ps1`, `src/Notify-Ask.ps1` | none |
| `src/Run-AllTests.ps1` | two `$extraSuites` entries |
| `test/config/llm-review/Run-Tests.ps1` | optional `-ConfigPath` / `-Cwd` params |
| `config.json` | disabled `script_drilldown` block + `_comment_*` |
| `test/config/script-drilldown/**` | new fixture suite (§13) |
| `docs/superpowers/CURRENT-DESIGN.md`, `docs/config-json-guide.md` | sections per §14 step 7 |
