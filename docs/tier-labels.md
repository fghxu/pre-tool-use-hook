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

In `LlmReview.ps1` attributed-verdict merge, only one tier has special treatment:

| Tier | LLM flags this sub-command? | Effect |
|---|---|---|
| `strictness_gated` | yes | **Suppressed** (`veto-suppressed-policy`) — the user already accepted gated risk at normal strictness |
| All others | yes | **Veto** — LLM disagreement in the dangerous direction forces `ask` |

Flags on sub-commands that are already `ask` locally (modifying, unregistered_verb, unregistered_static, unregistered, unclassified, unknown_domain) cannot cause a veto because `LLM never downgrades` — the local decision is already `ask`, so LLM agreement is moot.

## AST Arbiter Tier Stamp-Back

When the AST arbiter (`Classifier.ps1` G5 gate) proves that every sub-command in a `;`-chain is safe, it stamps the resolved tier back onto the pre-arbitration sub-results via `TierMap`. The arbiter uses `Merge-WorstTier` (strictness_gated > read_only > '') to compute the tier of wrapper commands from their inner children. Existing non-empty tiers are never overwritten.
