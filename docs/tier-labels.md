# Tier Labels Reference

**Audience:** maintainers of the PreToolUse hook. This document describes every `Tier` label assigned to sub-commands during classification and displayed in the `LLM-LOCAL tiers:` log line.

**Where tiers appear:**
- `LLM-LOCAL` log line: `tiers: [1]=read_only [2]=param_rule`
- `Classifier.ps1` AST arbiter gate (determines which sub-results carry which tier)
- `LlmReview.ps1` attributed-verdict merge (only `strictness_gated` affects behavior — see §LLM Merge below)

---

## Tier Labels

### `read_only`

**Decision:** allow  
**Set by:** `Resolver.ps1` Step 1a (explicit `read_only` pattern match), Step 2 (PowerShell `read_only_verbs`), Step 2 (AWS `read_only_prefixes`)  

The sub-command matched an explicit read-only pattern or a registered read-only verb/prefix. It is allowed in every strictness mode.

**Sample command:**
```
Get-ChildItem c:\temp
```
→ `tiers: [1]=read_only`

---

### `strictness_gated`

**Decision:** allow (normal/loose) or ask (strict)  
**Set by:** `Resolver.ps1` Step 1a.5 (explicit `strictness_gated` pattern match)  

The sub-command matched a strictness-gated pattern. It auto-allows in `normal` and `loose` modes, but prompts in `strict` mode. This is the ONLY tier that gets special treatment in the LLM merge: LLM flags on `strictness_gated` sub-commands are **suppressed** as policy (veto-suppressed-policy) instead of vetoed.

**Sample command (allows in normal mode):**
```
Set-Content C:\temp\notes.txt "hello"
```
→ `tiers: [1]=strictness_gated`

---

### `modifying`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 1b (explicit `modifying` pattern match), Step 2 (PowerShell `modifying_verbs`), Step 2 (AWS `modifying_prefixes`), `Evaluate-ParameterRules` (parameter rule: modifying, default modifying)  

The sub-command matched a modifying pattern, verb, prefix, or parameter rule. It always prompts (`ask`).

**Sample command:**
```
Remove-Item c:\temp\file.txt
```
→ `tiers: [1]=modifying`

---

### `param_rule`

**Decision:** allow (read-only rule) or ask (unrecognized value)  
**Set by:** `Evaluate-ParameterRules` in `Resolver.ps1` (parameter_commands classification — Step 7)  

The sub-command was classified via `parameter_commands`, not via tier patterns. The `Invoke-RestMethod`, `Invoke-WebRequest`, `curl.exe`, `git`, etc. entries in config.json carry parameter rules (`-Method Get` → read-only, `-Method Post` → modifying, etc.). When a rule matches (or the default kicks in), the tier is `param_rule`. The `Reason` field carries the detail (`parameter rule: read-only`, `parameter rule: modifying`, etc.).

**Sample command (read-only via parameter rule):**
```
Invoke-RestMethod -Method Get -Uri "https://example.com/api"
```
→ `tiers: [1]=param_rule` (reason: `Invoke-RestMethod (parameter rule: read-only)`)

**Sample command (ask — unrecognized parameter value):**
```
Invoke-RestMethod -Method Delete -Uri "https://example.com/api"
```
→ `tiers: [1]=param_rule` (reason: `Invoke-RestMethod (unrecognized parameter value)`)

---

### `trusted_program`

**Decision:** allow (or ask if modifying arg found)  
**Set by:** `Resolver.ps1` Step 0f-trust  

The sub-command's first token (program name/path) matched an entry in `trusted_programs`. Allowed unless a modifying command appears in its arguments (Option B: arg-scan).

**Sample command (allow):**
```
. 'C:\git\cc\pretoolhook\src\Classifier.ps1'
```
→ `tiers: [1]=trusted_program` (reason: `trusted program: src\classifier.ps1`)

**Sample command (ask — modifying arg):**
```
& src\Classifier.ps1 Remove-Item c:\temp
```
→ `tiers: [1]=trusted_program` (reason: `trusted program 'src\classifier.ps1' invoked with modifying arg 'Remove-Item'`)

---

### `safe_expr`

**Decision:** allow  
**Set by:** `Resolver.ps1` (synthetic marker for Parser-emitted safe expressions)  

The sub-command is a synthetic `(safe expression)` marker emitted by the Parser when a static .NET method call is certified via the AST arbiter or zero-command certifier. These are pure-expression scripts like `@([math]::Sqrt(4))` or `$null = [regex]::Matches(...)` with no command invocations.

**Sample command:**
```
$null = [math]::Sqrt(4)
```
→ `tiers: [1]=safe_expr`

---

### `editable_delete`

**Decision:** allow (low risk)  
**Set by:** `Resolver.ps1` Step 0g-delete (R2, 2026-09-18)  

A deletion command (`remove-item`, `rm`, `del`, `ri`, `erase`, `rd`, `rmdir`, `unlink`,
`clear-content`) whose **every** extracted target canonicalizes under an `editable_paths`
folder, the current working directory subtree, or a temp form (`/tmp/`, `%TEMP%`,
`$env:TEMP`, …). The path-policy ladder (system → fail-closed → editable/CWD/temp allow →
foreign ask) decides; this tier is the allow outcome. Recursion and wildcards are covered
(`c:\temp\1\2\a.txt`, `c:\temp\*.tmp`). Applies in **every** global strictness mode
(OQ-2: editable folders are trusted territory). System-path, drive-root, UNC-root,
unresolvable, variable-only, or foreign targets do NOT get this tier — they stay `modifying`
(ask).

**Sample command (allow):**
```
Remove-Item c:\temp\1\2\a.txt
```
→ `tiers: [1]=editable_delete` (reason: `delete under editable path: c:\temp\1\2\a.txt`)

**Sample command (NOT this tier — system target stays modifying/ask):**
```
Remove-Item c:\windows\system32\x.dll
```
→ `tiers: [1]=modifying` (reason: `delete of system path: c:\windows\system32\x.dll (high risk)`)

---

### `editable_path`

**Decision:** allow (low risk)  
**Set by:** `Classifier.ps1` STEP 4e per-segment stamp + STEP 4e-2 redirect sub-result (R2, 2026-09-18)  

Two distinct uses, both for **writes** (redirects), not deletions:

1. **Underlying segment (merge-relevant):** when a sub-command segment resolves to `allow`
   and its text contains a redirect whose target is editable/CWD/temp, the segment's tier is
   stamped `editable_path` (upgrading an empty or plain `read_only` tier; never overwriting a
   meaningful tier like `trusted_program`/`safe_expr`). This is the entry the LLM's flagged
   index points at, so it is what makes INV-2-for-writes work: an LLM veto on that segment is
   suppressed as policy.
2. **Redirect sub-result (display/logging only):** the dedicated `redirection-target`
   sub-result carries `editable_path` when its target is editable/CWD/temp (or `modifying`
   when ask). This entry is EXCLUDED from the LLM's indexed list, so this stamp changes
   nothing in the merge — it makes logs, `subresult-tier` assertions, and check_blindspot
   tier display truthful.

**Sample command (allow; segment stamped editable_path):**
```
Get-Date ; Write-Host hi > c:\temp\o.txt
```
→ `tiers: [1]=read_only [2]=editable_path` (the redirect target is under an editable path)

---

### `unregistered_verb`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 2 (PowerShell: Verb-Noun shape with unregistered verb), Step 2 (AWS: recognized service+verb but verb not in any prefix list)  

The command looks like a valid PowerShell cmdlet (Verb-Noun shape) or AWS CLI call (service + operation), but the verb/operation prefix is not registered in `read_only_verbs`, `modifying_verbs`, or the AWS prefix lists. Fail-closed: prompts the user.

**Sample command (PowerShell):**
```
Load-Config -Path config.json
```
→ `tiers: [1]=unregistered_verb` (reason: `Load-Config (unregistered PowerShell verb: Load- - fail-closed)`)

**Sample command (AWS):**
```
aws sso-admin provision-permission-set --instance-arn ...
```
→ `tiers: [1]=unregistered_verb` (reason: `aws sso-admin provision-permission-set (unregistered AWS verb - fail-closed)`)

---

### `unregistered_static`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 3 fallback (static .NET method call detected but not on the allowlist)  

A `[Type]::Method(...)` call was recognized as a static .NET invocation, but the specific method is not in `safe_expressions.dotnet_static_method_allowlist`. The Reason points the user to the allowlist for remediation.

**Sample command:**
```
[System.IO.File]::ReadAllText("C:\temp\file.txt")
```
→ `tiers: [1]=unregistered_static` (reason: `static method not on allowlist: [System.IO.File]::ReadAllText (see safe_expressions.dotnet_static_method_allowlist)`)

---

### `unregistered`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 3 fallback (known first-token tool with unregistered subcommand)  

The command starts with a known tool (docker, kubectl, terraform, git) but its subcommand is not registered in the config's read_only/modifying/strictness_gated lists. Fail-closed: prompts.

**Sample command:**
```
docker frobnicate my-container
```
→ `tiers: [1]=unregistered` (reason: `docker subcommand 'frobnicate' not registered (fail-closed)`)

---

### `unclassified`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 3 fallback (genuinely unknown — no pattern, verb, prefix, tool, or static method matched)  

The classifier could not match the command to any known pattern, verb, prefix, tool table, or static method. This is the true "unknown command" catch-all. The Reason line contains `unknown command: <truncated command>`.

**Sample command:**
```
some_obscure_tool --flag value
```
→ `tiers: [1]=unclassified` (reason: `unknown command: some_obscure_tool --flag value`)

---

### `unknown_domain`

**Decision:** ask  
**Set by:** `Resolver.ps1` Step 0 (domain name not recognized)  

The domain tag passed to `Resolve-Command` did not match any domain in the config's `commands` section. This is extremely rare — it means the Parser emitted a domain string that has no matching config block.

---

### `unlabeled`

**Decision:** (varies — logger safety net)  
**Set by:** `Logger.ps1` — displayed when a sub-result's `Tier` property is empty/null  

A safety-net fallback in the log formatter. Under normal operation this should never appear (every resolution path now sets an explicit Tier). If it does appear, it indicates a code path that produces a resolution result without setting a `Tier` property.

---

## LLM Merge Behavior

In `LlmReview.ps1` attributed-verdict merge, several tiers get special treatment:

| Tier | LLM flags this sub-command? | Effect |
|---|---|---|
| `trusted_program` | yes | **Suppressed** (`veto-suppressed-policy`) — the user explicitly whitelisted the program; no path guard applied (the trust IS the safety decision) |
| `editable_path`, `editable_delete` | yes | **Suppressed** (`veto-suppressed-policy`) — R2: editable folders are trusted territory and the local engine already validated every target via the path-policy ladder. INV-2: this authority trumps a remote LLM veto. Subject to the belt-and-braces INV-3 guard below |
| `strictness_gated` | yes | **Suppressed** (`veto-suppressed-policy`) — the user already accepted gated risk at normal strictness (or via `strict_gate_override_llm`) |
| All others | yes | **Veto** — LLM disagreement in the dangerous direction forces `ask` |

**INV-3 belt-and-braces guard (R2):** before suppressing an `editable_path`/`editable_delete`
flag, the sub-command text is run through `Test-CommandTargetsSystemPaths` (tokenize,
canonicalize each literal absolute-path token, match `_systemPathRegex`). If ANY path token
targets a system path, suppression is DENIED — the veto stands and the index is recorded in
`path_guard_denied`. By construction the Step 0g-delete ladder can never produce an allow tier
for a system target, so this guard only defends against future regressions; it makes INV-3
auditable in the merge (mirrors how the 2026-08-26 tool-gate spec made `system_paths` absolute
for tools).

**LLM-call skip for fully trusted/editable blocks (R2, OQ-1):** when EVERY in-scope
sub-command tier is in `{trusted_program, editable_path, editable_delete}`, the remote LLM call
is skipped entirely — no HTTP call, no LLM-DOWN/UNUSABLE check, `verdict=not_called`,
`effect=llm-skipped-trusted-editable`. Those tiers are locally authoritative AND unconditionally
veto-suppressed, so the LLM's answer cannot change the decision either way; skipping makes such
blocks immune to gateway outages. Mixed blocks (any other tier present) keep today's behavior:
the LLM is consulted and an LLM-DOWN still forces `ask`.

Flags on sub-commands that are already `ask` locally (modifying, unregistered_verb, unregistered_static, unregistered, unclassified, unknown_domain) cannot cause a veto because `LLM never downgrades` — the local decision is already `ask`, so LLM agreement is moot.

## AST Arbiter Tier Stamp-Back

When the AST arbiter (`Classifier.ps1` G5 gate) proves that every sub-command in a `;`-chain is safe, it stamps the resolved tier back onto the pre-arbitration sub-results via `TierMap`. The arbiter uses `Merge-WorstTier` (strictness_gated > read_only > '') to compute the tier of wrapper commands from their inner children. Existing non-empty tiers are never overwritten.
