# Spec: `normal_override_llm` strictness mode — local gated classification overrides the LLM veto (2026-10-16)

Status: **SPECIFIED** (interview complete; awaiting red/green implementation).
Companion design doc: `docs/Updates/Update-2026-10-16-strictness-normal-override-llm-design.md` (contains the full HLD/LLD, edit anchors, and the 39-case test plan).

---

## 1. Request (user, 2026-10-15/16, verbatim excerpts)

> "currently, the global_modifying_strictness has three mode, strict, normal, loose … currently, if the
> LLM and local classifier don't agree, we always classify the whole commands as 'ask', it becomes
> bothersome now. I need add one more mode: 'normal_override_llm' … I need the local classification
> override the LLM … if local is read-only, but remote is modify, then still classify as [ask], I can use
> this opportunity to check why the local is classified as read-only … those local
> 'unrecognized/unregistered_verb/etc' command still need to final = 'ask' … I believe the
> tool_name_modifying_strictness is not affected by this change."

> "my thinking was add another enumeration named 'normal_override_llm' to the existing
> global_modifying_strictness … so, there are four enums: strict | loose | normal | normal_override_llm."

Operational intent recorded alongside: the user also intends to keep
`llm_third_opinion.enforce_disagree: false` in the live config (existing D18 switch — config-only,
no code change in this feature).

## 2. Current-state facts established during the interview (code-verified)

1. **The LLM can only escalate** (allow→ask), never downgrade. Merge loop: `src/LlmReview.ps1`
   ~1326–1410.
2. **Existing local-overrides-LLM conditions** (attributed merge, per flagged index):
   - Tier `trusted_program` → suppressed **unconditionally** (Option B, 2026-09-16; both
     `trusted_programs` and `trusted_programs_regex` stamp this tier).
   - Tier `editable_path` / `editable_delete` → suppressed unless the INV-3 belt-and-braces guard
     `Test-CommandTargetsSystemPaths` trips (R2, 2026-09-18).
   - Tier `strictness_gated` + `llm_second_opinion.strict_gate_override_llm: true` → suppressed
     unconditionally (flag defaults false; **not set** in live config).
   - Tier `strictness_gated` + `Test-GatedInvocationSafe` passes → suppressed (stage-2 path guard:
     skip-list commands; every literal path token must resolve allow; writer-with-unresolved-`$var`
     fail-closed; no-path commands pass).
   - Everything else — **index 0**, `read_only`, `unclassified`, `unregistered_verb`, … → veto → ask.
3. **Consequence:** a path-less gated sub-command flagged by the LLM is *already* suppressed today.
   The new mode's real delta is: the gated tier overrides the LLM **even when the path guard denies**,
   scoped by strictness setting, with a system-path-only exception.
4. **Whole-command redirects cannot override today**: their SubResult carries
   `MatchedPattern = 'redirection-target'` and is dropped from the LLM's numbered list; the prompt
   directs the model to flag them as **index 0**, which is never suppressible (P3).
5. **File tools (Write/Edit/… via `path_tool_mapping`) never reach the LLM at all** (no sub-commands →
   out of scope).
6. Consumers comparing strictness literals: guard `Resolver.ps1` ~59; AWS flag-stripping
   `Resolver.ps1` ~229 (`-eq 'normal'`); gated-tier stamps ~603–616 / ~1405–1418 (`-eq 'strict'`);
   unrecognized param value ~1477 (`-ne 'loose'`); path-policy fallback `Parser.ps1` ~1807–1812
   (`-eq 'loose'` / `-eq 'normal'`); tool gate `Classifier.ps1` ~143–145 (`-eq 'strict'`).

## 3. Interview record — questions, options, rationale, decisions

Each question was put to the user with a recommendation; the decision column is the user's ruling.

### Q1 — How far does the gated-tier override go when the LLM flags a `strictness_gated` sub?
- Options: (a) unconditional (≡ `strict_gate_override_llm=true`); (b) keep `Test-GatedInvocationSafe`
  (≡ no-op vs today); (c) override **except literal system-path targets** (reuse
  `Test-CommandTargetsSystemPaths`, same guard family as the editable tiers).
- Rationale: gated cmdlet file-writes are not path-checked anywhere else (config
  `_comment_all_gated`); the path guard is their only check. (c) removes the bothersome vetoes while
  keeping the one denial that guards destructive targets.
- **Decision D1: (c).** Under `normal_override_llm`, a flagged gated sub is suppressed unless its
  command text contains a literal path token canonicalizing into `system_paths` — then the veto
  stands and the denial is logged.

### Q2 — `trusted_program`: keep unconditional, or add the system-path exception?
- Options: (i) keep unconditional (status quo, Option B); (ii) add the system-path exception
  (a tightening).
- Rationale: the whitelist is an explicit user decision; removing a bad entry is the right lever, not
  a guard on top of it.
- **Decision D2: (i). Zero change** for `trusted_program` / `editable_path` / `editable_delete` — they
  already override today exactly as desired (editable = INV-3-guarded = (c)-shaped already).

### Q3 — Carve out index 0 for validated editable redirects?
- Facts: whole-command redirects are invisible to the numbered list; LLM flags them as index 0; index 0
  is never suppressible → guaranteed ask even though the redirect target passed local path policy.
- Options: (a1) targeted carve-out — suppress index 0 when local decision is allow AND ≥1
  `redirection-target` SubResult carries Tier `editable_path` AND the full command is clean of system
  paths; no-redirect commands keep P3; (a2) blanket index-0 suppression (guts P3); (b) do nothing.
- **Decision D3: (a1).** "Index 0 is attributed to a validated editable redirect when one exists."

### Q4 — Guard semantics: does global `normal_override_llm` force all domains?
- Current pattern (code): global `strict`/`loose` forces every domain; global `normal` defers
  (entry → domain → `normal`).
- User initially said "follow the existing pattern", then on seeing the current behavior ruled the
  opposite for this value:
- **Decision D4: `normal_override_llm` is normal-family — per-domain wins.** Strict/loose still force.
  Resolution: global strict/loose → global; else entry value; else domain value; else **inherit the
  global normal-family value** (today's final `return 'normal'` becomes "return the global"). Hence
  a domain with no key inherits override-ON from a `normal_override_llm` global; opting out requires
  an explicit `normal`/`strict`/`loose`. Documented as an amendment to `_readme_strictness_guard`.

### Q5 — Does `parameter_commands` entry-level `modifying_strictness` get the 4th value?
- **Decision D5: yes, uniform.** All three enum sites (`global_modifying_strictness`,
  `parameter_commands[].modifying_strictness`, `commands.<domain>.modifying_strictness`) accept the
  4th value; precedence unchanged. `tool_name_modifying_strictness` **stays 3-valued** and rejects the
  new value at load (user: the tool gate is unaffected).

### Q6 — LLM-down / LLM-unusable under the mode?
- Options: (d1) keep fail-closed ask; (d2) mode lets local allow stand.
- Rationale: down is an availability failure, not an authority question; it also covers the read_only
  audit channel the user wants to keep. User added: "we only honor the LLM only if it is enabled" —
  already true (`llm_second_opinion.enabled: false` skips everything).
- **Decision D6: (d1). No change** to down/unusable handling in any mode.

### Q7 — First rollout surface?
- **Decision D7: (r2).** Live config keeps global `normal`; the domains (or single
  `parameter_commands` entries) that annoy get flipped to `normal_override_llm` one at a time. Root
  `config.json` stays `normal`; this is a `config.local.json` policy. Test fixtures use their own
  configs (never the live one).

## 4. Consolidated decision ledger

| # | Decision |
|---|---|
| D1 | Gated tier under `normal_override_llm` overrides an LLM veto **except** literal system-path targets (INV-3-style, `Test-CommandTargetsSystemPaths`). |
| D2 | `trusted_program` (both list forms), `editable_path`, `editable_delete`: **unchanged** (already override; editable already INV-3-guarded). |
| D3 | Index-0 carve-out (a1): suppress an index-0 flag iff local decision = allow AND ≥1 `redirection-target` SubResult has Tier `editable_path` AND full command has no system-path literal AND the mode is active. No-redirect index-0 flags still ask (P3). |
| D4 | Guard: `normal_override_llm` is normal-family; per-domain wins; absent domain key **inherits** the global normal-family value (default-ON). Strict/loose still force. |
| D5 | 4th enum value valid at global, per-domain, and `parameter_commands` entry level. `tool_name_modifying_strictness` stays {normal, strict, loose}. |
| D6 | LLM-down / LLM-unusable → ask, unchanged, in every mode. Master switch `enabled: false` = whole feature skipped, unchanged. |
| D7 | Rollout (r2): per-domain/entry flips in `config.local.json`; root config value stays `normal`. |
| D8 | `read_only`-tier flag + LLM modify → ask in every mode (user's audit channel: decide whether the command should move to `strictness_gated`). |
| D9 | Locally-unknown tiers (`unclassified`, `unregistered_verb`, …) → local ask stands (LLM never rescues); unchanged. |
| D10 | `check_blindspot` never changes decisions; unchanged. Pair `enforce_disagree` orthogonal (user runs `false`); with `false`, LLM1 drives the merge where the new suppression arms apply. |
| D11 | Normalization: everywhere strictness semantics branch on the value, `normal_override_llm` behaves as `normal` EXCEPT the override arms. Two literal consumers must be normalized: AWS flag-stripping (`Resolver.ps1` ~229) and the path-policy foreign-path fallback (`Parser.ps1` ~1807–1812). All `-eq 'strict'` / `-ne 'loose'` consumers are already normal-like. |
| D12 | Semantics of the value itself: gated entries still allow (≠ strict), AWS flag-stripping active (≡ normal), unrecognized param values still ask (≠ loose), tool gate unaffected (global contribution normal-like), path-policy fallback normal-like. |

## 5. Acceptance gates

1. **Parity:** with no config using the new value anywhere, every existing suite passes byte-identically
   (zero flips) — validators, guard, stamps, and merge arms must be no-ops for the 3 legacy values.
2. **Validator matrix:** global/domain/entry accept `normal_override_llm`; `tool_name_modifying_strictness`
   rejects it with a load-time throw.
3. **D1 proof:** gated sub + `idx:N` modifying flag + mode on → allow with `effect=veto-suppressed-policy`;
   same command with a `C:\Windows\…` literal → ask, denial logged.
4. **D3 proof:** whole-command editable redirect + `idx:0` flag + mode on → allow; identical command
   without any redirect + `idx:0` → ask.
5. **D4 proof:** global `normal_override_llm` + domain `strict` → gated entries ask (domain wins);
   domain with no key → override inherited (allow).
6. **D8/D9/D6 proof:** read_only-tier flag asks; unknown-verb local ask stands; mock `down`/`garbage` ask.
7. **D11 proof:** `aws` flag-stripping and the foreign-path fallback behave identically under
   `normal` and `normal_override_llm`.
8. Full regression green via `pwsh -NoProfile -File src\Run-AllTests.ps1`.

## 6. Explicitly out of scope / unchanged

- `tool_name_modifying_strictness` and `Resolve-ToolGate` ( Classifier.ps1 ~121–170).
- `llm_second_opinion.strict_gate_override_llm` legacy flag (kept; OR-relation unnecessary — the new
  mode is a strict subset situation: both make gated suppressible, the flag globally and guard-free).
- `Test-GatedInvocationSafe` itself (still used for plain `normal` mode).
- check_blindspot, LLM-down/unusable, enforce_disagree, llm_scope/drilldown behavior.
- No new config keys: only a new enum value on three existing keys.
