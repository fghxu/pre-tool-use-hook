# Regex-matched allowlists (trusted_programs / safe_expressions) + editable_paths deletion authority — design

<!-- 2026-09-18. Status: PROPOSED (awaiting user confirmation), not yet implemented. -->
<!-- Rev 2 (same day): full code-verification pass against Hook.ps1, TestRunner.ps1, -->
<!-- Run-AllTests.ps1, Test-LlmReviewScope, Test-SystemPathsOnly, Find-NestedCommands -->
<!-- and the llm-review mock harness. §4.3 corrected: redirect sub-results are      -->
<!-- FILTERED OUT of the LLM's indexed list (LlmReview.ps1:193), so the            -->
<!-- editable_path tier must be stamped on the UNDERLYING segment, not the         -->
<!-- redirect entry. Test plan aligned with the real harness capabilities.         -->
<!-- Covers three user requirements recorded 2026-09-18:                            -->
<!--   R1. trusted_programs entries matched by regular expression                   -->
<!--   R2. editable_paths folders allow recursive file deletion + trump the remote   -->
<!--       LLM veto; system_paths deletions are absolute (never allowed, never      -->
<!--       over-rule the LLM)                                                        -->
<!--   R3. safe_expressions / dotnet_static_method_allowlist entries matched by      -->
<!--       regular expression                                                        -->

## 0. Requirements (as received)

1. **R1 — trusted_programs regex.** The coding agent creates PowerShell files with
   names it decides, so explicit entries like `src\Parser.ps1` cannot be listed ahead of
   time. Want: one regex entry such as `"src\\\\.*\\.ps1"` (JSON) matching
   `src\Parser.ps1`, `src\Resolver.ps1`, `src\Run-Tests.ps1`, and any future `src\*.ps1`.
2. **R2 — editable_paths deletion authority.** Folders under `editable_paths` (e.g.
   `C:\temp\`) must allow removal of ANY file recursively beneath them
   (`c:\temp\1\2\a.txt`). This authority must **trump / over-rule the remote LLM's
   decision**. `system_paths` targets can NEVER be deleted and can NEVER over-rule the
   remote LLM.
3. **R3 — safe_expressions regex.** Allowlist entries such as
   `"regex::Matches"`, `"regex::Match"`, `"regex::IsMatch"` should be expressible as a
   regular expression, so the config does not need so many entries.

## 1. Current state (verified in source, 2026-09-18)

### 1.1 trusted_programs (R1)

- Loaded in `ConfigLoader.ps1` (~line 604): entries are normalized
  (lowercased, `/` → `\`) into the plain string array `_compiled.trustedPrograms`.
  **These are NOT regexes** (comment says so explicitly).
- Matched in `Test-TrustedProgram` (`Resolver.ps1` ~line 809): three literal forms —
  exact token, path-suffix (`token` ends with `\entry`), or bare basename. Case-insensitive.
- Consumed at `Resolve-Command` Step 0f-trust (`Resolver.ps1` ~line 288): a match grants
  `allow` with tier `trusted_program`, subject to Option B
  (`Test-StatementContainsModifying` scans the args; a modifying sibling statement still
  forces ask via worst-case-wins).
- LLM merge (`LlmReview.ps1` ~line 836): tier `trusted_program` is **unconditionally
  suppressible** — an LLM veto on a trusted program is logged
  `veto-suppressed-policy` and the local allow stands.

### 1.2 editable_paths vs deletion (R2)

- `editable_paths` patterns are ALREADY regexes, compiled into the anchored alternation
  `_editablePathRegex` (`ConfigLoader.ps1` ~line 319) and matched with `^(...)` prefix
  semantics, so `C:\\temp\\` already covers `C:\temp\1\2\a.txt` at any depth **for
  writes**: shell redirects (`Test-RedirectionTarget` → `Resolve-PathPolicy`,
  `Parser.ps1` ~line 1280) and file tools / the tool gate (`Resolve-ToolGate`,
  `Classifier.ps1`).
- **Deletions are NOT path-checked.** `Remove-Item` / `rm` / `del` / `ri` are ordinary
  command-DB entries (`config.json` PowerShell domain: `"Remove-Item"`, patterns
  `Remove-Item *`, `rm *`, `del *`, `ri *`, risk `high`) → tier `modifying` → ask,
  regardless of target path. So "I thought we already had this feature" is half right:
  recursive WRITES under editable paths — yes; recursive DELETES — no.
- **LLM does NOT respect editable paths.** The redirect sub-result added at
  `Classifier.ps1` STEP 4e-2 carries `MatchedPattern = "redirection-target"` and NO
  `Tier`. Worse (verified at `LlmReview.ps1:193`): `Test-LlmReviewScope` FILTERS OUT
  redirection-target entries when building the LLM's indexed sub-command list
  (`Where-Object { $_.MatchedPattern -ne 'redirection-target' }`), so the LLM's
  flagged indices always point at the UNDERLYING command segments
  (`echo hi > file`), never at the redirect entry itself. In the attributed merge only
  tiers `trusted_program` (unconditional) and `strictness_gated` (via
  `Test-GatedInvocationSafe` or `strict_gate_override_llm`) are suppressible. A
  path-policy allow for an editable target is therefore vetoable today: local allow +
  LLM "modifying" → ask.

### 1.3 safe_expressions allowlists (R3)

- `safe_expressions.dotnet_method_allowlist` (instance-style, name-only) compiles to the
  HashSet `_dotnetMethodAllowlist` (`ConfigLoader.ps1` ~line 371).
- `safe_expressions.dotnet_static_method_allowlist` (`Type::Method` keys) compiles to
  `_dotnetStaticMethodAllowlist` (~line 389). Keys are checked case-insensitively
  against BOTH the type as written (`regex::Matches`) and the reflected full name
  (`System.Text.RegularExpressions.Regex::Matches`) in `Test-SafeAst`
  (`Parser.ps1` ~line 2210) and in the Classifier atomic-unknown truthfulness guard
  (`Classifier.ps1` ~line 634).
- Both are exact-membership sets. 183 static entries + ~100 instance names today.

## 2. Design decision common to R1 + R3: SEPARATE regex arrays, not in-band sigils

Two candidate syntaxes were considered for marking "this entry is a regex":

| Option | Pros | Cons — rejected because |
|---|---|---|
| **A. In-band sigil** (`"re:^src\\.*\.ps1$"`) | single array, ordering | Every literal path entry already contains `\` — an accidental regex-looking literal (`c:\temp\x(1).ps1`) becomes a load-time surprise or a silent non-match; validation errors point at a mixed bag; no repo precedent. |
| **B. Sibling regex arrays** (`trusted_programs_regex`, `..._allowlist_regex`) | Zero ambiguity, zero back-compat risk (absent key = byte-identical behavior), trivial load-time validation, matches the existing repo split (`trusted_pattern` [regex] vs `trusted_programs` [literal]) | Two keys per feature |

**Decision: Option B.** Each existing literal list keeps its exact semantics; a new
optional sibling array holds regex entries. This mirrors how `trusted_pattern` /
`untrusted_pattern` (pure regex) already sit beside `trusted_programs` (pure literal).

JSON escaping note (applies to all new arrays): a regex intended as
`^src\\.*\.ps1$` is written `"^src\\\\.*\\.ps1$"` in JSON (`\\` per backslash).
The user's sample `"src\\\\.*\\.ps1"` decodes to the regex `src\\.*\.ps1` and — under
the substring semantics chosen below — matches all three example tokens.

## 3. R1 — `trusted_programs_regex`

### 3.1 Semantics

- New optional config key `trusted_programs_regex`: array of regex strings.
- Matched **after** the literal entries miss (literal list stays the fast path and keeps
  first-class meaning), in listed order, first match wins.
- Matched against the **normalized program token** — exactly the string
  `Test-TrustedProgram` already builds: lowercased, `/` → `\` (e.g.
  `c:\git\cc\pretoolhook\src\newscript.ps1`). Regexes should be written lowercase;
  the compiled regex additionally uses `IgnoreCase` (belt and braces, mirrors the
  case-insensitive literal matching).
- **Unanchored `-match` semantics** (substring), exactly like `trusted_pattern`. The
  user's `src\\.*\.ps1` therefore covers both the relative invocation token
  (`src\parser.ps1`) and the full-path invocation token
  (`c:\git\cc\pretoolhook\src\parser.ps1`). Users anchor explicitly with `^`/`$` when
  they want strictness (recommended: at least `$`).
- On match, `Test-TrustedProgram` returns the pattern itself (prefixed
  `regex:` in the reason text), so prompts read
  `trusted program (regex): src\\.*\.ps1`.
- **Everything downstream is unchanged** because the match funnels into the same
  Step 0f-trust branch: Option B arg-scan (`Test-StatementContainsModifying`), sibling
  worst-case-wins, tier `trusted_program`, LLM unconditional suppression, and the
  `pwsh -File <path>` program-token extraction (the Parser feeds the same token).

### 3.2 Loader (`ConfigLoader.ps1`)

- Validation (~line 67, next to `trusted_programs`): key optional; if present must be an
  array of non-empty strings.
- Compile (~line 615, next to `trustedPrograms`) into
  `_compiled.trustedProgramRegexes` as `[regex]` objects
  (`Compiled -bor IgnoreCase`); a non-compiling entry throws
  `"Invalid regex in trusted_programs_regex: <pattern>"` at load time — same fail-fast
  contract as `trusted_pattern` / `untrusted_pattern`.

### 3.3 Matcher change (`Resolver.ps1` `Test-TrustedProgram`)

After the existing literal loop returns nothing, iterate the compiled regexes and
return the first pattern whose `-match $tok` succeeds. Empty/absent array → behavior
byte-identical to today.

### 3.4 Config example (live config.json)

```json
"trusted_programs": [
    "TestRunner.ps1",
    "live\\Sync-Fixtures.ps1",
    "llm-review\\Run-Tests.ps1",
    "test-strictness-gate\\Run-Tests.ps1",
    "Classifier.ps1"
],
"trusted_programs_regex": [
    "src\\\\.*\\.ps1$",
    "^test\\\\.*\\.ps1$"
],
```

i.e. the three `src\*.ps1` literals collapse into the single regex entry
`src\\.*\.ps1$` (the `$` anchor prevents also matching `src\foo.ps1.txt`-shaped
tokens); `src\ConfigLoader.ps1` and `src\Run-AllTests.ps1` are then covered by the same
entry, and any FUTURE `src\<agent-invented-name>.ps1` is trusted automatically — the
stated goal of R1.

### 3.5 Security sharp edges (documented in config guide)

- An over-broad regex trusts whatever it matches. `\.ps1$` alone would auto-trust
  `& c:\users\frank\downloads\evil.ps1` (Option B still scans its ARGS, but the program
  itself runs unprompted). Guidance: scope regexes to a folder prefix
  (`src\\.*\.ps1$`, `^c:\\tools\\`), anchor with `$`, and keep machine-wide patterns in
  `config.local.json`.
- Regexes see the NORMALIZED token (lowercase, backslashes). A pattern written with `/`
  never matches. Documented in the key's `_comment_`.

## 4. R2 — editable_paths deletion authority + LLM trump; system_paths absolutism

### 4.1 Invariants (restating the requirement precisely)

1. **INV-1 (editable delete allow):** a deletion command whose EVERY filesystem target
   canonicalizes under an `editable_paths` folder, the CWD subtree, or a temp form is
   **allowed** (risk low) — recursively, at any depth (`c:\temp\1\2\a.txt`, wildcards
   `-Recurse`, comma lists, quotes).
2. **INV-2 (editable trumps the LLM):** that allow is **not vetoable** by the remote LLM
   — same reconciliation status as `trusted_program` (`veto-suppressed-policy`).
3. **INV-3 (system_paths absolute):** a deletion touching ANY `system_paths` target is
   **ask** in every strictness mode, and NO local rule (editable overlap, loose mode,
   LLM read-only verdict) may turn it into an allow. The LLM's "modifying" verdict can
   never be over-ruled for system paths.
4. **INV-4 (fail-closed):** unresolvable targets (`$var`, `%VAR%`, drive roots like
   `c:\`, canonicalization failure) and mixed editable+foreign target sets → ask.

### 4.2 New resolution step: Step 0g-delete (path-aware deletion classification)

Placement: inside `Resolve-Command`, immediately AFTER the full-path recursion block
(~`Resolver.ps1` line 330) and BEFORE the pattern tiers — so `c:\tools\rm.exe x` is
normalized to `rm x` first, and the modifying DB entry never fires when the path policy
already decided. Mirrors how redirects bypass command tiers via a dedicated path check.

**Deleter recognition.** Script-level canonical list (same pattern as
`$script:LlmGuardWriterCommands` in `LlmReview.ps1` — single obvious place to extend):

```
$script:PathPolicyDeleters = 'remove-item','rm','del','ri','erase','rd','rmdir','unlink'
```

First token, basename with extension stripped (`.exe`), case-insensitive. Domain-
agnostic — `rm` detected as Linux and `Remove-Item` detected as PowerShell both enter
the branch.

**Target extraction.** Tokenize the argument text with a quote-aware whitespace
tokenizer (the `Split-GuardTokens` algorithm, currently private to `LlmReview.ps1` —
**relocated to `Parser.ps1` as a shared helper**, `LlmReview.ps1` keeps calling it).
This placement is load-graph-verified, not cosmetic: `src/TestRunner.ps1` dot-sources
ConfigLoader/Parser/Resolver/HookAdapter/Classifier but **NOT** `LlmReview.ps1`, so a
helper left in `LlmReview.ps1` would be undefined when the delete branch runs under
the test runner; anything `Resolver.ps1` calls must live in `Parser.ps1` or earlier in
the load order. Rules:

- Drop flag tokens (`-Recurse`, `-Force`, ...) EXCEPT path-bearing parameters
  (`-Path`, `-LiteralPath`, `-lp`, `-p`): their VALUE (next token, or the `:value`
  same-token form) IS a target.
- Values of `-Filter` / `-Include` / `-Exclude` are NOT targets (they are glob
  restrictions, not locations). Mis-guessing here only under-allows → ask (fail-closed).
- Split comma lists (`Remove-Item a.txt, b.txt`) into separate targets.
- Remaining bare tokens that contain a path signal (drive letter, `\`, `/`, leading
  `~`, or a dot-extension) are targets; anything else is ignored data.

If NO target can be extracted the branch does NOT decide — the command falls through to
the existing tiers (today's behavior; protects exotic forms from misparses).

**Decision ladder** (order matters; mirrors `Resolve-PathPolicy` exactly —
system-before-editable is what makes INV-3 structural, not incidental):

| # | Condition (over ALL extracted targets, canonicalized via `ConvertTo-CanonicalWritePath` — collapses `..`, strips `\\?\`, anchors CWD) | Decision | Risk | Tier |
|---|---|---|---|---|
| 1 | any canonical matches `_systemPathRegex` | ask | high | `modifying` |
| 2 | any target is a drive root (`^[a-z]:\\?$`), a bare UNC root, or fails canonicalization, or is variable-only (`$v`, `%V%`) | ask | high | `modifying` |
| 3 | EVERY target passes `Test-EditableOrCwd` (editable path / under current directory) or the temp-form check (`^/tmp/`, `%TEMP%`, `$env:TEMP`, ...) | **allow** | low | `editable_delete` (new) |
| 4 | otherwise (foreign non-system target, or mixed sets) | ask | high | `modifying` |

Row 3 reasons read: `delete under editable path: c:\temp\1\2\a.txt` /
`delete under current directory: ...`. Row 1:
`delete of system path: c:\windows\x.dll (high risk)`.

**Wildcard handling.** `*` / `?` survive canonicalization as literal characters, and the
editable prefix check still applies (`c:\temp\*` starts with `c:\temp\`). The dangerous
shape `remove-item c:\temp\..\windows\* -Recurse` collapses via `GetFullPath` to
`c:\windows\*` → row 1 ask. POSIX targets follow the existing redirect normalization
(`Test-EditableOrCwd` resolves `/tmp/x` on Windows hosts; the config
`editable_paths.linux` patterns already account for it) — `rm -rf /tmp/foo` reuses the
identical machinery, no new path logic.

**Strictness modes.** Row 3 applies in EVERY global strictness mode, matching the
existing redirect behavior (`Resolve-PathPolicy` never consults `strict` — editable
redirect targets allow in strict mode today) and matching the user's requirement that
editable folders are trusted territory. System paths ask in every mode (INV-3).
*(Open question OQ-2 lists the stricter alternative.)*

### 4.3 Tier stamping for existing path-policy allows (redirects)

`Classifier.ps1` STEP 4e-2 builds the redirect sub-result with no `Tier`. Two stamps,
two purposes (the scope filter at `LlmReview.ps1:193` makes BOTH necessary):

1. **Redirect sub-result (display/logging only):** Decision `allow` →
   `Tier = 'editable_path'`; Decision ask → `Tier = 'modifying'`. This entry is
   EXCLUDED from the LLM's indexed list, so this stamp alone changes nothing in the
   merge — it exists so logs, `subresult-tier` test assertions, and check_blindspot
   tier display are truthful.
2. **Underlying sub-command result (the merge-relevant one):** in the STEP 4e
   per-segment loop, after `Resolve-Command` returns `allow` for a segment whose text
   contains a redirect, run `Test-RedirectionTarget` on the SEGMENT text; if its
   policy is allow with an editable/CWD/temp reason, stamp `Tier = 'editable_path'` on
   that sub-result (never overwrite an existing meaningful tier). This is the entry
   the LLM's flagged index points at, so THIS is what makes INV-2 work for writes:
   `echo hi > c:\temp\o.txt` → the segment carries `Tier = 'editable_path'` → an LLM
   veto on that index is suppressed.

This extends INV-2 to writes — the requirement says editable folders "trump /
over-rule the remote-LLM's decision", unqualified.

### 4.4 LLM reconciliation changes (`LlmReview.ps1`, attributed merge)

In the per-index loop (~line 836), alongside `$isTrusted`:

```powershell
$isPathPolicyAllow = ($sub -and $sub.Tier -in @('editable_path','editable_delete'))
```

- `trusted_program` OR `isPathPolicyAllow` → `$suppIdx` (unconditionally suppressible;
  log `veto-suppressed-policy`; reason lists it under "suppressed as policy").
- **Belt-and-braces INV-3 guard:** before suppressing a path-policy tier, run the
  sub-command text through `Test-CommandTargetsSystemPaths` (new tiny helper: tokenize
  with the shared tokenizer, canonicalize each literal absolute-path token via
  `ConvertTo-CanonicalWritePath`, match `_systemPathRegex` — same shape as the existing
  `Test-SystemPathsOnly` at `Classifier.ps1:99`, which takes a path ARRAY for tool
  payloads; the new one takes command TEXT for the merge). If it returns true the flag
  is NOT suppressed (`$vetoIdx` + `path_guard_denied`). By construction rows 1/2 of
  the ladder can never produce an allow tier, so this guard only defends against future
  regressions — cheap, and it makes INV-3 auditable in code, the same way the
  2026-08-26 tool-gate spec made system_paths absolute for tools.
- `trusted_program` suppression semantics are NOT touched (spec P3 of the LLM phases).
- System-path deletions are local ask → the merge path is `agree`/`disagree-kept-ask`;
  they can never be downgraded by the LLM. INV-3 holds at the merge too.
- **LLM-DOWN is unchanged** for all suppressible tiers when the LLM IS consulted (a down gateway still forces ask, exactly as it does today for `trusted_program`) — but see §4.6: for fully trusted/editable blocks the LLM is no longer consulted at all, so LLM-DOWN cannot force an ask on them.

### 4.5 What deliberately does NOT change

- `strictness_gated_tool_name` / `ignore_tool_name` tool payloads (2026-08-26 spec
  already makes system_paths absolute there).
- The Option B trusted-program machinery (R1 only adds a second matcher).
- `check_blindspot` (never changes decisions).

## 4.6 LLM-call skip for fully trusted/editable blocks (OQ-1 — RESOLVED YES)

User decision (2026-09-18): **skip the remote LLM call entirely when, after local
classification, EVERY in-scope sub-command tier is in
`{trusted_program, editable_path, editable_delete}`.**

Rationale: those tiers are locally authoritative AND unconditionally veto-suppressed
(§4.4), so the LLM's answer cannot change the decision either way — the call is pure
latency plus an LLM-DOWN failure mode. Skipping it makes trusted/editable runs immune
to gateway outages.

Implementation (in `Hook.ps1`, where the scope gate decides whether to invoke
`LlmReview.ps1`):

- After local classification and BEFORE the existing scope gate
  (`Test-LlmReviewScope`), compute the set of tiers over the SAME sub-command list the
  LLM would receive (i.e. post scope-filtering, redirect entries already excluded).
- If the list is non-empty AND every tier ∈ {`trusted_program`, `editable_path`,
  `editable_delete`} → bypass the LLM entirely: no HTTP call, no LLM-DOWN/UNUSABLE
  check, log `llm-skipped-trusted-editable` in the decision record.
- Empty list (e.g. all sub-commands were redirect entries) → no skip, fall through to
  the normal scope gate (no sub-commands means out of scope anyway).
- `check_blindspot` interaction: the blindspot trigger tiers (`unclassified`,
  `unregistered_*`, `unknown_domain`) are by construction absent from an all-
  trusted/editable block, so the skip cannot suppress a blindspot consult. The skip
  check runs BEFORE the blindspot gate too (blindspot exists to enrich ask prompts;
  an all-allow block has nothing to enrich).
- The skip is decision-neutral by design: every tier in the set is both a local allow
  and veto-suppressed, so consult-vs-skip always yields the same final decision.

## 5. R3 — regex entries for the safe-expression allowlists

### 5.1 New keys

- `safe_expressions.dotnet_method_allowlist_regex` — matched (IgnoreCase) against the
  bare instance method NAME as written (`ReadAllText`, `Matches`, ...).
- `safe_expressions.dotnet_static_method_allowlist_regex` — matched (IgnoreCase)
  against BOTH spellings the exact-set already checks: the type as written
  (`regex::Matches`) and the reflected full name
  (`System.Text.RegularExpressions.Regex::Matches`). Either match ⇒ allowed.

### 5.2 Matching order

Exact HashSet first (O(1) fast path unchanged), then the regex array in order. A miss
on both ⇒ unsafe ⇒ ask (fail-closed posture preserved — regexes can only ENLARGE the
allowlist, never shrink it).

### 5.3 Loader

Compile both arrays at load (`Compiled -bor IgnoreCase`) into
`_dotnetMethodAllowlistRegex` / `_dotnetStaticMethodAllowlistRegex`; invalid pattern ⇒
throw `"Invalid regex in safe_expressions.<key>: <pattern>"`. Validation sits next to
the existing `dotnet_static_method_allowlist` array check (~`ConfigLoader.ps1` line 382).

### 5.4 Check sites

- `Parser.ps1` `Test-SafeAst` `InvokeMemberExpressionAst`: after `$allowSet.Contains`
  / `$staticSet.Contains` misses, try the corresponding regexes (instance branch:
  name-only; static branch: written key, then reflected key).
- `Classifier.ps1` truthfulness guard (~line 634) gains the same miss-then-regex
  fallback so an allowlisted-by-regex static inside an atomic-unknown expression is not
  mislabeled "not on allowlist".
- `Resolver.ps1` fallback reason text (~line 784): unchanged wording, but the config
  `_comment_` will mention both keys.

### 5.5 Config example

```json
"dotnet_static_method_allowlist_regex": [
    "^regex::(match(es)?|ismatch|replace|split|escape|unescape)$",
    "^system\\.io\\.path::[a-z]+$",
    "^math::[a-z]+$"
]
```

The first entry collapses the 7 `regex::*` literals; the family prefixes collapse the
19 `System.IO.Path::*` and 33 `math::*` entries (every member of both families is
reflection-verified read-only, 2026-07-31 audit). Estimated config shrink: ~60 entries.

### 5.6 Security sharp edges (documented in config guide)

- Prefer `$`-anchored enumerations (`^regex::(a|b|c)$`). Use family prefixes
  (`^math::`) ONLY for types with NO static writers — audit note in the `_comment_`
  keeps the 2026-07-31 reflection audit as the gate for adding a family.
- Regexes are matched case-insensitively against the key strings, so short-form type
  aliases (`regex`, `math`, `string`) and full names both work with one pattern using
  alternation, e.g. `^(regex|system\\.text\\.regularexpressions\\.regex)::`.

## 6. Config surface summary

| Key | Type | Default | Where consumed |
|---|---|---|---|
| `trusted_programs_regex` | string[] (regex) | `[]` (absent) | `Test-TrustedProgram` |
| `safe_expressions.dotnet_method_allowlist_regex` | string[] (regex) | `[]` | `Test-SafeAst` instance branch, Classifier guard |
| `safe_expressions.dotnet_static_method_allowlist_regex` | string[] (regex) | `[]` | `Test-SafeAst` static branch, Classifier guard |
| (no new key) deletion policy | — | — | Step 0g-delete; deleter list is a script constant |

All keys optional; an absent key leaves behavior byte-identical (back-compat
guarantee). New tiers `editable_delete` / `editable_path` appear in logs,
`docs/tier-labels.md`, and the LLM merge.

## 7. TDD implementation plan (red/green, per CLAUDE.md)

Fixtures live under `test/config/<feature>/` with their OWN `config.json` (never the
live one). Runner:
`pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath <fixture>\test-cases.xml -ConfigPath <fixture>\config.json`.
TestRunner (verified) asserts per case: `expected` (decision), optional
`reason-contains` (pins reason TEXT), optional `subresult-tier` (pins a SubResult's
`Tier`) — the new `editable_delete` / `editable_path` tiers are directly assertable
with `subresult-tier`.

### 7.1 Suite 1 — `test/config/trusted-programs-regex/`

Fixture: copy of `test/config/trusted-programs/config.json` with
`"trusted_programs_regex": ["src\\\\.*\\.ps1$", "safe-.+\\.ps1"]` and empty(ish)
literal list.

| # | Command | Expected | Proves |
|---|---|---|---|
| 1 | `& src\Brand-New.ps1 Get-ChildItem c:\temp` | allow, reason contains `trusted program (regex)` | R1 core: future name matched |
| 2 | `& c:\repo\src\other.ps1 Get-ChildItem c:\temp` | allow | substring semantics over full-path token |
| 3 | `& src\Brand-New.ps1 Remove-Item c:\temp` | ask (Option B) | regex trust still arg-scanned |
| 4 | `& src\Brand-New.ps1 ; Remove-Item c:\temp` | ask | sibling worst-case-wins intact |
| 5 | `& tools\notps1.cmd Get-ChildItem` | ask | non-matching token not trusted |
| 6 | `pwsh -File src\agent-made.ps1 -Flag` | allow | -File extraction feeds same matcher |
| 7 | literal entry still wins for a token matching both lists | allow, reason shows literal entry | precedence |
| Loader pre-flight | `config.badregex.json` with `"trusted_programs_regex": ["("]` | `Load-Config` THROWS `Invalid regex in trusted_programs_regex` | fail-fast; pre-flight check in the fixture's own `Run-Tests.ps1` (ask-notification `config.badtype.json` / llm-review `LlmConfig-BadType` precedent — TestRunner cannot express load-throws) |

### 7.2 Suite 2 — `test/config/editable-delete/`

Fixture: `editable_paths.windows = ["c:\\temp\\"]`, `system_paths` default Windows set,
minimal PowerShell + Linux domains (remove-item/rm registered modifying/high as today —
proving the carve-out, not tier changes).

| # | Command | Expected | Proves |
|---|---|---|---|
| 1 | `Remove-Item c:\temp\1\2\a.txt` | **allow**, tier `editable_delete` | INV-1 recursive depth |
| 2 | `Remove-Item c:\temp\1 -Recurse -Force` | allow | flags skipped, recursive delete |
| 3 | `rm c:\temp\log.txt` | allow | linux-detected deleter |
| 4 | `rm -rf /tmp/foo` | allow | POSIX + temp reuse |
| 5 | `Remove-Item c:\temp\a.txt, c:\temp\b.txt` | allow | comma list |
| 6 | `Remove-Item "c:\temp\my file.txt"` | allow | quote-aware tokenizer |
| 7 | `Remove-Item c:\temp\*.tmp` | allow | wildcard under editable |
| 8 | `Remove-Item log.txt` (CWD under editable fixture dir) | allow | CWD subtree |
| 9 | `Remove-Item c:\windows\system32\x.dll` | ask, high, tier `modifying` | INV-3 |
| 10 | `Remove-Item c:\temp\..\windows\x.dll` | ask | `..` canonicalized → system |
| 11 | `Remove-Item c:\other\x.txt` | ask | foreign target |
| 12 | `Remove-Item c:\temp\a.txt, c:\other\b.txt` | ask | mixed set fail-closed (INV-4) |
| 13 | `Remove-Item $target` | ask | variable target fail-closed |
| 14 | `Remove-Item c:\` | ask | drive root fail-closed |
| 15 | `Remove-Item -LiteralPath c:\temp\x` | allow | parameter-value extraction |
| 16 | `Remove-Item -Filter *.tmp` (no target) | ask via existing tiers | no-target fall-through unchanged |

LLM sub-suite — run by the **llm-review fixture runner**
(`pwsh -NoProfile -File test/config/llm-review/Run-Tests.ps1 -XmlPath
test/config/editable-delete/test-cases.llm.xml`), NOT by TestRunner (TestRunner does
not load `LlmReview.ps1`). The harness (verified) injects verdicts via the
`PRETOOLHOOK_LLMREVIEW_MOCK` env var and asserts per-case attributes `mock`, `effect`,
`level`, `min`, `reason-contains`. NOTE: default scope is `complex_remote` with
`min=2` — single-sub-command cases MUST set `level="all"` (or `min="1"`) or the LLM
is never consulted and the case proves nothing.

| # | Scenario (attrs) | Expected | Proves |
|---|---|---|---|
| L1 | `rm c:\temp\x`, `level="all"`, `mock="modifying"` | allow, `effect="veto-suppressed-policy"` | INV-2 |
| L2 | `echo hi > c:\temp\o.txt`, `level="all"`, `mock="modifying"` | allow — the UNDERLYING segment carries tier `editable_path` (the redirect entry itself is scope-filtered) | INV-2 writes |
| L3 | `rm c:\windows\x`, `level="all"`, `mock="read-only"` | ask, `effect="disagree-kept-ask"` | INV-3 merge side |
| L4 | `rm c:\temp\x`, `level="all"`, `mock="down"` | ask, `effect="forced-ask"` | documented unchanged behavior |
| L5 | system-path text inside a path-policy allow shape (regression probe) | `effect="veto"`, `path_guard_denied` set | belt-and-braces guard |

### 7.3 Suite 3 — `test/config/safe-expr-regex/`

Fixture: `dotnet_static_method_allowlist_regex = ["^regex::(match(es)?|ismatch)$"]`,
`dotnet_method_allowlist_regex = ["^to(String|Upper)$"]`, exact lists EMPTY
(proves regex-only operation; a second fixture keeps exact lists to prove precedence).

| # | Input | Expected | Proves |
|---|---|---|---|
| 1 | `$x = [regex]::IsMatch('a','a')` | allow (safe expression) | static regex hit, written form |
| 2 | `$x = [System.Text.RegularExpressions.Regex]::Matches('a','a')` | allow | reflected full-name form |
| 3 | `$x = [regex]::Replace('a','a','b')` | ask, `unregistered_static`-style reason | regex miss fail-closed |
| 4 | `$s.ToLower()` alone in expression | allow | instance regex |
| 5 | `$s.Mutate()` | ask | instance miss |
| 6 | exact entry + overlapping regex | reason shows exact semantics | precedence (behavior identical either way; asserts no double-logging) |
| Loader pre-flight | `config.badregex.json` with `"^("` in a regex key | `Load-Config` throws (pre-flight in the fixture's own `Run-Tests.ps1`) | fail-fast |

### 7.4 Red/green sequence

1. **Red A:** Suite 1 cases 1–7 + loader case → fail (key ignored / no regex matching).
2. **Green A:** ConfigLoader validation+compile, `Test-TrustedProgram` regex pass → pass.
3. **Red B:** Suite 3 + loader → fail.
4. **Green B:** loader arrays + `Test-SafeAst` / Classifier guard fallbacks → pass.
5. **Red C:** Suite 2 rows 1–16 → fail (all ask today except none).
6. **Green C:** shared tokenizer relocation + Step 0g-delete + tier stamps → pass.
7. **Red D:** Suite 2 L1–L5 (llm-review runner, `level="all"` cases) → fail (vetoes
   stand today).
8. **Green D:** LlmReview merge `editable_path`/`editable_delete` + system guard →
   pass.
9. Full regression: register the three new suites in `src/Run-AllTests.ps1`'s
   extra-suites list (same style as the existing `tool-gate` / `llm-review.*` entries,
   verified at lines ~92–99), then run `src/Run-AllTests.ps1` — byte-identical behavior
   for configs without the new keys must show ZERO diffs (live suites run against
   `test/config/live/config.json`, never the repo-root config).

## 8. Documentation updates

- `docs/config-json-guide.md`: new sections for `trusted_programs_regex`,
  `safe_expressions.*_regex` (semantics, JSON escaping, sharp edges), and the deletion
  path-policy ladder.
- `docs/tier-labels.md`: `editable_delete`, `editable_path`.
- `config.json`: `_comment_` blocks for the three keys; collapse the 7 `regex::*`
  statics and the `src\*.ps1` trusted-program literals into regex entries (live proof).
- `PROGRESS.md` entry after implementation.

## 9. Accepted residuals / risks (explicit)

- **Over-broad regex entries** (both R1/R3) enlarge auto-allow surfaces; mitigated by
  docs guidance + anchoring conventions, not by code limits.
- **`-Recurse` through junctions/symlinks** inside an editable tree that point into
  system areas: static analysis sees only the editable prefix. Accepted residual (same
  class as today's redirect policy); users should not junction system dirs into
  `C:\temp`. Documented.
- **Source-vs-destination not distinguished** for deleters with multiple path-like args
  (none in the canonical set today; `Split-GuardTokens` treats all path tokens as
  targets — conservative direction: MORE asks, never fewer).
- **LLM-DOWN immunity for fully trusted/editable blocks:** with §4.6 the LLM is not called at all when every sub-command is trusted/editable, so gateway outages can no longer force asks on those blocks (resolves the former LLM-DOWN residual). Mixed blocks (any non-trusted/editable sub-command) keep today's behavior: consulted, LLM-DOWN forces ask.

## 10. Open questions — ALL RESOLVED (2026-09-18, user decisions)

- **OQ-1 (RESOLVED: YES):** the LLM call IS skipped entirely when every sub-command
  tier ∈ {`trusted_program`, `editable_path`, `editable_delete`}. Spec: §4.6.
- **OQ-2 (RESOLVED: NO):** `global_modifying_strictness=strict` does NOT block
  editable-path deletes — editable folders are trusted territory in every mode,
  mirroring redirect policy exactly (default stands, §4.2).
- **OQ-3 (RESOLVED):** ship the canonical 8 deleters PLUS `clear-content`
  (`remove-item, rm, del, ri, erase, rd, rmdir, unlink, clear-content` — 9 entries in
  `$script:PathPolicyDeleters`, §4.2).
