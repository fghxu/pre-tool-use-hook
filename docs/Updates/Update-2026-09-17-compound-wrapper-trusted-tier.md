# Compound `cd ...; pwsh -File <trusted>` lost its trusted_program tier (2026-09-17)

## Incident

Production log 2026-09-17 23:31:

```
LLM-SENT   : [ 2 subcommand ] | [1] cd c:\git\cc\pretoolhook | [2] pwsh -NoProfile -File src/Run-AllTests.ps1
LLM-RECV   : verdict=modifying indices=[2]
LLM-LOCAL  : decision=allow (read-only); tiers: [1]=read_only [2]=read_only
LLM-RECONCILE: flagged=[2] veto=[2] -> FINAL: ask
```

`src/Run-AllTests.ps1` **is** in `trusted_programs`. The user expected sub-command [2] to carry
tier=`trusted_program`, which Option B (the LLM merge) suppresses unconditionally — so the final
decision should have been **allow**. Instead [2] showed tier=`read_only`, the LLM's "modifying"
verdict stood, and the run was forced to ask.

The user noted: "I thought we fixed a similar issue not long ago in this branch." That fix was
**Option A** (the `pwsh -File` collapse), but it only lives in the **AST walker**, which is gated on
`domain -eq 'powershell'`. The compound form never reaches it.

## Root cause (verified by probe)

| Form | Domain | Path taken | Result |
|------|--------|-----------|--------|
| `pwsh -NoProfile -File src/Run-AllTests.ps1` (standalone) | powershell | AST walker → Option A collapse | `[src/Run-AllTests.ps1]` tier=**trusted_program** ✅ |
| `cd ...; pwsh -NoProfile -File src/Run-AllTests.ps1` (compound) | **linux** | regex path | `[pwsh -NoProfile -File ...]` tier=**read_only** ❌ |

The compound form's domain is **linux** because the leading `cd` decides it (no Verb-Noun / PS
marker). On the regex path, STEP 4c called `Find-NestedCommands` on the **full command string**, but
every wrapper pattern inside that function is **start-anchored** (`^pwsh...`, `^ssh...`, ...). A
string that starts with `cd` matches none of them → no `-File` unwrapping → the whole
`pwsh -NoProfile -File src/Run-AllTests.ps1` segment fell to the generic `pwsh` read_only pattern.

Two consequences:

1. **Cosmetic (the reported symptom):** the script path never got tier=`trusted_program`, so Option B
   could not suppress the LLM flag on it → veto → ask.
2. **Safety hole (worse, found during diagnosis):** `cd ...; pwsh -NoProfile -File C:\temp\untrusted.ps1`
   was **allowed** (generic `pwsh` pattern) instead of asked. An untrusted script slipped through
   precisely because the wrapper was not the first segment.

The existing Option A / Option B tests all used the wrapper as the **first** segment
(`pwsh -File ... ; git status`), where the anchored `^pwsh` pattern matched on the full string even
pre-fix — which is why this gap went unnoticed.

## Fix

**`src/Classifier.ps1`, STEP 4c:** call `Find-NestedCommands` **per sub-command segment** (from
`$subCommands`) instead of on the full command string.

```powershell
# before
$nestedCommands = @(Find-NestedCommands -Command $command -ParentDomain $domain)

# after
$nestedCommands = @()
foreach ($seg in $subCommands) {
    $nestedCommands += @(Find-NestedCommands -Command $seg.CommandText -ParentDomain $seg.Domain)
}
```

- For **single-segment** commands this is identical to the old full-string call (one segment == the
  whole string), so no existing behavior changes.
- For **compound** commands the anchored patterns now match the wrapper **segment** itself, so the
  `-File` path is unwrapped and routed to `Test-TrustedProgram`.
- Each nested entry's `ParentCommand` is the **segment** text (not the full command), so the existing
  `parentTexts` filtering in the combination step suppresses exactly that segment — the other
  segments (`cd`, `curl`, ...) survive as their own sub-commands.
- `$ParentDomain` was declared and passed recursively inside `Find-NestedCommands` but **never read**
  (all domain detection uses `Get-CommandDomain`), so passing the per-segment domain is safe.

## TestRunner enhancement

**`src/TestRunner.ps1`:** optional per-case `subresult-tier` XML attribute. When present, the case
passes only if some SubResult carries that Tier. Absent on all pre-existing cases → decision-only
behavior unchanged. This was needed because the trusted compound case produces
`Decision=allow` + `Reason="read-only"` **both** broken and fixed — only the per-sub-command tier
differs, and the tier is what drives the Option B suppression.

## Tests (4 new)

`test/config/live/test-cases.xml` — new `PSWrapper-Compound` group:

| Case | Command | Expected | Why |
|------|---------|----------|-----|
| 1 | `cd c:\git\cc\pretoolhook; pwsh -NoProfile -File src/Run-AllTests.ps1` | allow + `subresult-tier=trusted_program` | the incident: per-segment unwrap grants the trusted tier |
| 2 | `cd c:\git\cc\pretoolhook; pwsh -NoProfile -File C:\temp\untrusted.ps1` | ask | safety hole: untrusted script must not fall to generic pwsh read_only |
| 3 | `cd c:\git\cc\pretoolhook; powershell -NoProfile -Command "Remove-Item C:\temp\x"` | ask | per-segment unwrap must still catch a modifying inner |

`test/config/llm-review/test-cases.p2.small.xml` — new `P2-TrustedProgramCompoundSuppressed`:

- `ls /tmp; pwsh -NoProfile -File src/Run-AllTests.ps1; curl http://h/y`, LLM flags the script
  (idx **3** — nested/unwrapped commands are appended after the regex-split segments), suppressed by
  Option B policy → allow. Uses `ls` as the first segment because the fixture's minimal config
  recognizes `ls` but not `cd`.

RED confirmed: all 4 failing pre-fix; GREEN post-fix.

## Regression

Full `src/Run-AllTests.ps1`: **1315/1315** (baseline was 1311/1311 at `1c8ca67`; +4 = new cases).
Zero regressions across all suites.

## Files changed

- `src/Classifier.ps1` — STEP 4c per-segment `Find-NestedCommands`.
- `src/TestRunner.ps1` — optional `subresult-tier` assertion.
- `test/config/live/test-cases.xml` — 3 new `PSWrapper-Compound` cases.
- `test/config/llm-review/test-cases.p2.small.xml` — 1 new compound Option B case.
- `PROGRESS.md`, this doc.
