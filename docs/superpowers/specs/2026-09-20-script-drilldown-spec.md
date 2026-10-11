# Script Drilldown — Specification

**Date:** 2026-09-20
**Status:** APPROVED (grill session complete; all decisions confirmed by user) — pending implementation
**Branch:** `feature_fix` (no merge to master until soak passes — standing rule)
**Companion design doc:** `docs/superpowers/specs/2026-09-20-script-drilldown-design.md`
**Interview record:** `.grill/interview-questions.md` + `.grill/decisions-so-far.md` (working notes; this spec is the contract)

---

## 1. User requirements

This section lists every requirement stated by the user, in the order it was raised.
Requirements marked *(interview)* emerged during the grill session on 2026-09-19/20.

### R1 — Original problem (2026-09-19)
> "Many times the agent will write some PowerShell code and run it from the command; this will be
> intercepted by our hook script and always classified as 'ask'."

When an intercepted command invokes a **script file** (`pwsh {params} {file}.ps1`), the hook must
**extract the file's content and classify its statements** together with the rest of the command,
so the user "don't need to blindly approve or deny the scripts."

### R2 — Original scope (2026-09-19)
> "We will focus on the PowerShell script first, but leave the other type of source code for now;
> our new framework should be left extendable to new types of source files and their invocation."

v1 = PowerShell only. The detection layer must be structured so that Python
(`python {params} {file}.py`) and later languages are an **addition** (new matcher + config entry),
not a rework.

### R3 — Use the existing logging framework *(interview, Q1 round)*
> "I want to use this logging framework to help me deal with the extra commands from the actual
> files … all those commands are labeled with [0] [1]..[n] when sending to the LLM."

Extracted script statements must appear as **numbered `[N]` sub-command entries** in the log
(`LLM-SENT` line), each with its own tier (`LLM-LOCAL tiers:`), exactly like existing sub-commands.
The user's 2026-08-10 production log sample is the reference artifact (see §7).

### R4 — Drop string splicing *(interview, Q1 round)*
> "You forget about those ';;;' or '\n' that I put in my original request … how we split the content
> of the PowerShell/python files is one of the outputs of this grill session."

The original idea of appending file content to the command string with `;;;`/`\n` separators is
**explicitly dropped**. Content becomes structured sub-command entries, not a spliced string.
How file content is split into statements is settled in §3 (Q8).

### R5 — Config gate *(interview, Q1 round)*
> "Let's add a configure option … when it is set to false, then it follows everything like
> now-a-days. Only when it is set to true, we will begin to extract the detected scripts/files and
> also classify them."

A config block gates the entire feature. **Absent or disabled ⇒ behavior byte-identical to today.**
User asked for naming help → settled name: **`script_drilldown`** (Q3).

### R6 — Matcher-based extension mechanism *(interview, Q2)*
> "Option A Matcher is fine."

Per-language script-path detection lives in a matcher registry with one dispatcher; matchers run on
the intercepted command line (per segment), pre-classification; they never touch LLM prompts.
Match entries are functions (scriptblocks), not regex strings — PowerShell v1 wraps the existing
production regex internally; Python later needs a token loop (skip boolean flags, skip value-taking
flag + its value, refuse `-m`/`-c` forms).

### R7 — Config block shape *(interview, Q3)*
> "Option A is fine."

Object with `enabled` + explicit `runners` list. Unknown/typo'd runner name ⇒ `Load-Config` throws
(fail-closed at startup). `enabled: true` with `runners` omitted ⇒ all implemented matchers armed.

### R8 — Path resolution against the workspace root *(interview, Q4)*
> "We can't rely on the hook's cwd. The terminal issued from the VS Code project should provide the
> cwd as the current workspace's root folder."

Empirically proven (2026-09-19): VS Code spawns child `pwsh` with cwd = **workspace root** — a
freshly spawned child's CWD and `[System.IO.Path]::GetFullPath('test\config\live\README.md')` both
resolved against `C:\git\cc\pretoolhook`, and the file read successfully. So anchoring relative
paths to the hook-process CWD **is** anchoring them to the workspace root. Settled: absolute paths
used as-is; relative paths anchored via `GetFullPath` (same primitive as
`ConvertTo-CanonicalWritePath`).

### R9 — Trusted programs are never expanded *(interview, Q5)*
> "Option B. Anything listed in trusted still will be skipped checking; they are listed as trusted
> for a reason, we trust them, even they have delete command."

The `trusted_programs` / `trusted_programs_regex` check runs **before** expansion. A trusted path is
never read; it allows via the trust tier exactly as today. Drilldown fires only for paths that miss
every trust entry. **No behavior change for any currently-trusted path.**

### R10 — Splitting + display format *(interview, Q8)*
> "Option A, feed the whole file to AST walker, but make sure the commands from the PowerShell
> script will be showing in the log … actually you don't need show whole file path, just
> `<script:restore-copilot-chat.ps1>` is enough."

- Mechanism: read file → one `Get-PowerShellCommands` call on the full content (existing AST walker).
- Origin marker on `[N]` entries: **`<script:basename>`** — basename only, no full path.
- `[N]` entries carry **no** line numbers; the **Reason line** names the offending statement and its
  line number (e.g. `… contains modifying command: Copy-Item … (line 42)`).

### R11 — Function bodies are classified *(interview, Q8b)*
> "A is good. safe."

Empirically verified: the AST walker's `ScriptBlockAst` search **does** reach function-definition
bodies. Default kept: `function X { Remove-Item … }` inside an expanded script is classified as-if-run
(fail-closed, zero extra code). No exclusion filter.

### R12 — Recursion/loop protection (user's own design) *(interview, Q6)*
> "We can maintain a hashtable (with absolute file path as the hash), put the starting PowerShell in
> the HT too; when a new file is needed to check, throw it into the hashtable; if it already existed
> in the HT, then it will error out, then don't process that file … we also create a new entry in the
> config, it is the maximum chained file we will allow, default it to 3, if the number of file paths
> in the hashtable more than this value, then mark decision as 'ask' (fail-closed)."

Adopted with three implementation details: keys are **canonicalized** absolute paths (lowercase +
separator-unify, via `ConvertTo-CanonicalWritePath`); on loop/cap hit a **path-only entry with an
informative reason** is emitted (→ unknown → ask via worst-case-wins); the HT is fresh per
intercepted tool call. The count-based cap (not depth-based) bounds total work including breadth.

### R13 — Catch dot-sourced / `&`-invoked scripts *(interview, Q7)*
> "Option A, we will catch these files."

Inside **expanded** scripts only: a statement whose command is `.` (dot-source) or `&` (call
operator) with a **literal string path** ending in `.ps1` is treated exactly like a nested `-File`
(trust check → HT/cap checks → read → walk; marker `<script:basename>`). Variable paths (`& $p`),
`Invoke-Expression`, and `Start-Process` argument-hiding keep today's fail-closed unknown→ask.
Depth-0 dot-source (the agent's command line itself) is **out of v1 scope**.

### R14 — 4 KB file-size cap *(interview, Q4b)*
> "Let's start with 4k. Remember, all these will popup in VS Code windows; I don't think a file more
> than 4k will have all read-only commands."

`max_file_bytes` default **4096**. Over-cap ⇒ no expansion ⇒ ask with informative reason.

### R15 — Informative ask reasons *(interview, Q11 round)*
> "When drill-down scripts gives decision: 'ask', you need give informational info, like if it is due
> to more than 3 of the chained scripts, or the file is more than 4k, or you found the modifying
> commands, etc."

Every drilldown-caused ask states its **cause** in the reason text. Exact strings in §6.

### R16 — LLM scope selector, default "count" *(interview, Q11)*
> "Is the C a combination of the A and B, which only one of them in place? If yes, I like C with A is
> the default."

Confirmed: `llm_scope` is a **selector** (one mode active at a time). Values `"count"` | `"exclude"`,
**default `"count"`** — script-origin entries count toward `complex_min_subcommands`, so standalone
expanded scripts receive LLM second-opinion review. User chose coverage over the ~10 s latency tax.

### R17 — One LLM request for all chained scripts *(interview, Q11 round)*
> "When multiple PowerShell scripts in the hash table, I want you to be able to combine all of them
> together and do a classification … I want only send one LLM request in order to save the token
> cost. Is our framework supporting this?"

**Answered: yes, already.** All sub-command entries from the entire tool call (wrapper + every
expanded file's statements) form one flat numbered list sent in a **single** `Get-LlmReviewVerdict`
call; one verdict with indices spanning all files. No new code required. Classification stays
per-statement (precise reasons + worst-case-wins); only the LLM review is combined.

### R18 — Dedicated test fixture directory *(interview, Q9)*
> "Option A."

`test/config/script-drilldown/` with its own config(s), XML case files with `reason=` assertions,
and **real `.ps1` files on disk** under `scripts/`. Per CLAUDE.md: never the repo-root live config;
red/green TDD.

### R19 — Single TDD cycle, full deliverable set *(interview, Q10)*
> "Option A."

One red/green pass implementing all settled decisions, with the complete deliverable list in §10.

---

## 2. Interview questions and decisions (summary)

Full option-by-option detail: `.grill/interview-questions.md`. Decisions register: D1–D16 below.

| # | Question | Decision |
|---|----------|----------|
| Q1 | Where in the pipeline does expansion happen? | **Option A** — inside the existing `-File` extraction branches, at BOTH sites in `Parser.ps1` (`Get-AstWrapperInnerCommands` = AST primary; `Find-NestedCommands` = regex fallback). Script statements become SubResults entries. Zero changes to Logger/LlmReview aggregation logic. Rejected: B (string splicing — pipeline re-splits on `;`/newlines), C (dedicated STEP 1.75 stage — extra plumbing, revisit when a 2nd language lands), D (display-only — fails the `[N]` log requirement). |
| Q2 | Extension mechanism shape? | **Option A** — matcher registry + single dispatcher in `Parser.ps1`; v1 ships one entry (powershell); each matcher returns `{ Runner, ScriptPath }` or `$null`. Kills the two-site duplication of the `-File` rule. Clarified: matchers run on the intercepted command line per segment, pre-classification; entries are scriptblocks, not regex strings. |
| Q3 | Config block shape + name? | **Option A** — object `{ enabled, runners }`; name **`script_drilldown`** confirmed. Unknown runner ⇒ Load-Config throws. `enabled:true` + `runners` omitted ⇒ all implemented matchers armed. |
| Q4 | Script-path resolution? | **Option A** — absolute as-is; relative anchored to workspace root via hook-process CWD (empirically proven identical). Not found ⇒ no expansion + reason naming both forms. Residual case: agent `cd`'d inside its own terminal session ⇒ fallback ask. |
| Q5 | `trusted_programs` interaction? | **Option B** — trust short-circuits BEFORE expansion; trusted files are never read (R9). Order: trust check → expand → else path-only entry (today's behavior). |
| Q8 | How is file content split? | **Option A** — whole file through existing AST walker `Get-PowerShellCommands`. Marker `<script:basename>` on `[N]` entries; no line numbers on entries; line number in Reason. Sub-decision (Q8b): function bodies classified as-if-run (R11). |
| Q6 | Recursion/loop protection? | **User's design** — per-decision hashtable keyed by canonicalized absolute path; starting script inserted first; repeat ⇒ don't read, emit path-only entry + reason; config `max_chained_files` default 3; count exceeded ⇒ ask (R12). |
| Q7 | Dynamic constructs inside expanded scripts? | **Option A** — dot-source/`&` of literal `.ps1` paths inside expanded scripts are expanded like nested `-File`; all other dynamic forms keep fail-closed unknown→ask (R13). |
| Q4b | File-size cap? | `max_file_bytes` default **4096** (R14). |
| Q11 | LLM scope for expanded scripts? | **Option C** — config key `llm_scope`: `"count"` \| `"exclude"`, **default `"count"`** (R16). |
| Q9 | Test fixture strategy? | **Option A** — dedicated `test/config/script-drilldown/` dir with real `.ps1` files (R18). |
| Q10 | Rollout/deliverables? | **Option A** — single TDD cycle, full deliverable set (R19). |

---

## 3. Settled decisions register (D1–D16)

- **D1 (Q1)** Expansion point: both `-File` extraction branches in `Parser.ps1`. When drilldown is ON
  and the file is readable: keep a visible wrapper entry, emit each statement as a sub-command entry
  with origin marker; recurse via existing wrapper detection. When OFF/unreadable: today's behavior
  exactly (path-only entry → trust check / unknown→ask).
- **D2** Config gate: opt-in; key absent or `enabled:false` ⇒ byte-identical to today.
- **D3** Log/LLM target format: script statements as numbered `[N]` SubResults entries with per-entry
  tiers; reason names offending statement + origin file (user's log sample, §7).
- **D4** `;;;`/`\n` splicing dropped (R4).
- **D5** Scope: PowerShell first; framework extends to other languages by addition (R2).
- **D6 (Q2)** Matcher registry in `Parser.ps1`; per-segment detection on intercepted command line;
  scriptblock matchers, not regex strings.
- **D7 (Q3)** Config block: `{ enabled, runners }`, name `script_drilldown`; unknown runner ⇒ throw.
- **D8 (Q4)** Path resolution: absolute as-is; relative ⇒ workspace-root anchor via hook-process CWD
  (proven); not found ⇒ no expansion + both-forms reason.
- **D9 (Q5)** Trust-first: `Test-TrustedProgram(path)` before any read; trusted ⇒ never expanded,
  allow via trust tier (today's behavior).
- **D10 (Q8)** Splitting: whole file → `Get-PowerShellCommands`; marker `<script:basename>`; no line
  numbers on `[N]` entries; line number in Reason; function bodies classified as-if-run.
- **D11 (Q6)** Loop/cap protection: per-decision hashtable, canonicalized-path keys, starting script
  inserted first; repeat ⇒ path-only entry + `recursive script invocation detected: <path>`;
  `max_chained_files` (default 3) exceeded ⇒ path-only entry + `max chained files exceeded (N): <path>`.
- **D12 (Q4b)** `max_file_bytes` default 4096; over-cap ⇒ no expansion + size reason.
- **D13 (Q7)** Dot-source/`&` of literal `.ps1` inside expanded scripts ⇒ expand like nested `-File`;
  other dynamic forms fail-closed as today.
- **D14** Informative ask reasons — exact strings in §6.
- **D15 (Q11)** `llm_scope`: `"count"` (default) | `"exclude"`.
- **D16 (Q9)** Test fixture: dedicated dir, real files, ON + OFF config variants, `reason=` assertions.

---

## 4. Verified facts (code + empirical, 2026-09-19/20)

1. **Two extraction sites** for `pwsh -File`, both emit a path-only "terminal" entry today:
   `Get-AstWrapperInnerCommands` (~Parser.ps1 L1842; AST primary — `IsTerminal=true` triggers
   `suppressOuter` so a standalone trusted-script run counts as ONE sub-command, staying below the
   LLM scope threshold) and `Find-NestedCommands` (~L600; regex fallback). **Both must change identically.**
2. **SubResults is the single source** for `[N]` numbering: `LlmReview.ps1` numbers entries into the
   LLM prompt (`Get-LlmReviewVerdict -SubCommands`); `Logger.ps1` `Format-LlmLogBlock` renders
   `LLM-SENT` and `LLM-LOCAL tiers:` from the same array. New entries ⇒ automatic log + LLM visibility.
3. **Existing `-File` regex** (to be moved into the matcher):
   `(?i)^(?:\.?\\)?(?:pwsh|powershell)(?:\.exe)?\s+.*?-File\s+(?:"([^"]+)"|'([^']+)'|(\S+))`
   plus normalization of a leading `&` call operator and full-path `pwsh.exe`/`powershell.exe`.
4. **Hook input JSON carries no working-directory field** (grep of src). The only CWD is captured by
   `ConfigLoader.ps1` at startup from the hook process (`_cwd`/`_cwdNorm`).
5. **Empirical proof (R8):** VS Code spawns child pwsh with cwd = workspace root; `GetFullPath` of a
   relative path resolved correctly and the file read successfully.
6. **AST walker reaches function bodies** (empirical): `FindAll(ScriptBlockAst)` finds bodies inside
   `function` definitions — so D10/R11 need zero extra code.
7. **2026-09-17 production incident** (in code comments): per-segment nested extraction + wrapper
   suppression exist because an untrusted script was once ALLOWED instead of asked. Any change here
   must preserve that fix.
8. **`Test-TrustedProgram`** (Resolver.ps1 ~L991) is callable from Parser at runtime — all modules are
   dot-sourced into one scope before `Invoke-Classify` runs. It already handles literal + regex trust
   entries and path-suffix/basename matching.
9. **Resolver strips the dot-source operator** (~L280) for trusted-program matching — `. .\x.ps1`
   already resolves to its path token for trust checks today.
10. **AtomicReason precedent:** Classifier's atomic-unknown branch emits an entry carrying a
    pre-computed `AtomicReason`; STEP 4e honors it instead of re-resolving. Drilldown block reasons
    (D14) reuse this mechanism.
11. **pwsh wrapper read_only pattern** exists in the command DB (`config.local.json` L498):
    `{ "name": "pwsh", "patterns": ["pwsh(?:\\.exe)? *", "powershell(?:\\.exe)? *"] }` — the outer
    wrapper line classifies as read_only/allow, so it can appear as `[1]` without forcing an ask.
12. **Live config trust entries** (`config.local.json`): literals incl. `temp\Classify.ps1`; regexes
    `src\\*.ps1$`, `src/*.ps1$`, `(?:^|\\)temp\\[^\\]+\.ps1$` (stopgap added 2026-09-19: "it will allow
    any PowerShell under any temp folder to be executed. useful for agentic coding"). **Consequence of
    D9:** in the live environment, temp probe scripts and repo scripts are never expanded — drilldown
    mainly inspects non-trusted paths (e.g. `.agents` skill scripts like `restore-copilot-chat.ps1`).
13. **LLM config (live):** enabled, `level: complex_commands`, `complex_min_subcommands: 2`,
    timeout 30000 ms, `check_blindspot` enabled for the 5 unknown tiers. Observed LLM round-trip: ~9.4 s.
14. **TestRunner.ps1** accepts `-Cwd` (overrides the CWD the config captures) — existing suites use it
    (e.g. `-Cwd C:\git\repo`). This is how drilldown fixtures anchor relative script paths.
15. **Baseline:** 1360/1360 across 21 suites (`src\Run-AllTests.ps1`).
16. **Largest `.ps1` in repo:** `src\Parser.ps1` at 109.6 KB (next: 73.7 / 56 / 50.4 KB). Agent probe
    scripts are typically 1–10 KB — all under the 4 KB cap only if small; larger untrusted scripts ask.

---

## 5. Config schema (final)

```jsonc
"script_drilldown": {
    "enabled": true,              // absent key OR false ⇒ today's behavior byte-identical
    "runners": ["powershell"],    // v1: only valid value is "powershell"; unknown name ⇒ Load-Config throws
    "max_chained_files": 3,       // int >= 1; total files (incl. starting script) expandable per tool call
    "max_file_bytes": 4096,       // int >= 1; per-file size cap before reading
    "llm_scope": "count"          // "count" | "exclude"; default "count"
}
```

Validation (in `Load-Config`, fail-closed): block must be an object when present; `enabled` bool
(default false); `runners` array of strings, each in the implemented set `{powershell}` else throw;
`max_chained_files` / `max_file_bytes` integers >= 1 (defaults 3 / 4096); `llm_scope` in
`{count, exclude}` (default count). Compiled into `$config._compiled.scriptDrilldown` (`$null` when
absent/disabled).

Generic `config.json` ships an **explicit disabled block** with `_comment_*` documentation (discoverable
when copied to `config.local.json`).

---

## 6. Reason-string contract (D14 — assertable in tests)

Every drilldown-caused ASK states its cause:

| Cause | Reason text |
|---|---|
| Chain cap hit | `max chained files exceeded (3): <path>` |
| Loop detected | `recursive script invocation detected: <path>` |
| Size cap hit | `script too large to inspect (<size> > 4096): <path>` |
| File not found | `script file not found: <orig> (resolved to <full>)` |
| No classifiable statements | `script contains no classifiable statements (fail-closed): <path>` |
| Modifying statement found | `script <basename> contains modifying command: <statement> (line N)` |

`<path>` = the path as written in the command; `<full>` = workspace-root-anchored resolution. When a
line number is unavailable (regex-fallback path), omit the `(line N)` suffix. Multiple causes are
joined by the existing worst-case-wins aggregation (all blockers listed).

---

## 7. Log format (user-approved target)

Reference: user's 2026-08-10 production log sample, extended per R3/R10. After drilldown, a
`pwsh -File` invocation whose script contains read-only + one modifying statement logs:

```
[2026-09-20 …] IDE:Copilot Tool:[run_in_terminal] Decision:[ask] Time:[…]
  Reason: script restore-copilot-chat.ps1 contains modifying command: Copy-Item … (line 42)
  Command: ___ [powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\fghxu\...\restore-copilot-chat.ps1 -Date 08/09/2026 -List] ___
  LLM-SENT      : [ 5 subcommand ] | model=GLM-5.3 timeout=30000ms | [1] powershell -NoProfile ... restore-copilot-chat.ps1 -Date 08/09/2026 -List | [2] <script:restore-copilot-chat.ps1> Get-ChildItem $targetDir | [3] <script:restore-copilot-chat.ps1> Write-Host "restoring..." | [4] <script:restore-copilot-chat.ps1> Copy-Item ...
  LLM-LOCAL     : decision=ask (...); tiers: [1]=read_only [2]=read_only [3]=read_only [4]=modifying
```

Rules: `[1]` = the original wrapper command line (classifies via the pwsh read_only wrapper pattern);
`[2..n]` = script statements, each prefixed `<script:basename>` (basename only — R10); per-entry tiers;
full paths + line numbers live in the Reason line and `records.jsonl`.

---

## 8. Scope

**In (v1):** PowerShell scripts via `-File`; dot-source/`&` of literal `.ps1` inside expanded scripts;
trust-first ordering; loop/cap/size/not-found fail-closed handling; informative reasons; LLM scope
selector; dedicated test suite; docs.

**Out (v1, documented for later):** Python and other languages (framework ready per D6); depth-0
dot-source on the agent's own command line; `python -c` / `node -e` inline forms; reusing a first
expansion when the same file is invoked twice non-loopingly (v1 asks — cheap follow-up); safe-expression
certification for pure-assignment scripts (v1 asks via "no classifiable statements"); per-runner config
tuning beyond the four keys.

---

## 9. Behavior matrix (summary)

| Situation | Decision | Reason |
|---|---|---|
| Drilldown OFF / key absent | today's behavior exactly | — |
| Path trusted (literal or regex) | allow (trust tier), file never read | `trusted program: <entry>` (today's text) |
| Expanded; all statements read-only | allow | per-statement reasons |
| Expanded; any statement modifying/unknown | ask | §6 modifying line (+ other blockers) |
| File not found | ask | §6 not-found |
| File > `max_file_bytes` | ask | §6 too-large |
| Path already in HT (loop / double-invocation) | ask | §6 recursive |
| HT count would exceed `max_chained_files` | ask | §6 max-chained |
| Script with zero classifiable statements | ask | §6 no-statements |
| Dynamic construct (`iex $x`, `& $p`, …) inside script | ask (statement unknown) | existing fail-closed |

---

## 10. Deliverables and rollout (Q10 = Option A)

Single TDD cycle, red/green per CLAUDE.md:

1. **This spec** (`docs/superpowers/specs/2026-09-20-script-drilldown-spec.md`) — written first.
2. **Design doc** (`docs/superpowers/specs/2026-09-20-script-drilldown-design.md`) — architecture +
   implementation contract for a junior coder.
3. **Test fixture suite** `test/config/script-drilldown/` (D16) — written RED before any src/ change.
4. **Implementation:** `src/Parser.ps1` (matcher, expansion engine, both `-File` branches, dot-source/`&`,
   line numbers), `src/Classifier.ps1` (state reset, entry→SubResults plumbing, reason formatting),
   `src/ConfigLoader.ps1` (validation/compilation), `src/LlmReview.ps1` (`llm_scope` counting,
   DisplayText in the numbered list).
5. **Generic `config.json`:** explicit disabled block + `_comment_*` docs.
6. **Docs:** `CURRENT-DESIGN.md` §1 (pipeline diagram) / §2 (module table) / §4 (config schema);
   `docs/config-json-guide.md` section for `script_drilldown`.
7. **Regression:** full `Run-AllTests.ps1` — 1360 existing + new suite all green; spec status → IMPLEMENTED.

Rollout: land on `feature_fix`; soak in live `config.local.json` (`enabled: true`) before any merge to
master (standing rule).

---

## 11. Related areas and impact analysis

- **Existing suites audit (2026-09-20):** `-File` cases exist only in `live/test-cases.xml` (~15, incl.
  the 2026-09-17 incident case), `llm-review/test-cases.p2.small.xml` (6), and
  `trusted-programs-regex/test-cases.xml` (1). **None are affected**: no fixture config contains a
  `script_drilldown` key ⇒ feature OFF ⇒ byte-identical behavior. The 1360 baseline holds by construction.
- **2026-09-17 incident fix preserved:** per-segment extraction + wrapper suppression untouched; the
  untrusted-script-must-ask property is strengthened (content now visible).
- **LLM second opinion:** with default `llm_scope: "count"`, a standalone expanded script (≥2 entries)
  crosses `complex_min_subcommands: 2` ⇒ LLM review on every expanded script run (~10 s, user-accepted
  per R16). `check_blindspot` behavior unchanged. One LLM request covers all chained scripts (R17).
- **ask_notification / Codex mapping:** unchanged — drilldown asks fire the toast and map ask→deny for
  Codex like any other ask.
- **Performance budget:** ≤3 file reads + AST parses per decision (D11/D12 caps) — milliseconds, well
  under the 3000 ms hard cap; LLM latency is the dominant cost and is governed by D15.
- **Live-config implication (R9 consequence):** `temp\*.ps1$` and `src\*.ps1$` trust regexes mean those
  scripts are never expanded in the live environment; drilldown's live effect concentrates on
  non-trusted paths (`.agents` skill scripts, workspace scripts outside temp/src).
- **Repo rules applied:** red/green TDD; per-fixture config.json (never repo-root live config); design
  doc sections are deliverables; no master merge before soak.
