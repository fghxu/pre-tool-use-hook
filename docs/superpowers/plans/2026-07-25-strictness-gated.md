# `strictness_gated` Section + Per-Domain Strictness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third per-domain config tier (`strictness_gated`) that allows in normal/loose but asks in strict, plus optional per-domain `modifying_strictness` with a global guard rule.

**Architecture:** Per approved spec `docs/superpowers/specs/2026-07-25-strictness-gated-design.md` (commit 5b27112). A new `Get-EffectiveStrictness` helper in Resolver.ps1 implements the guard (global strict/loose forces all domains; global normal defers to per-domain). A new match step 1a.5 in `Resolve-Command` sits between read_only (1a) and modifying (1b). AWS flag-strip (Resolver.ps1:180) and parameter_commands unrecognized-value (Resolver.ps1:890) switch from raw global strictness to effective strictness. Path policy (Parser.ps1) stays on global strictness — untouched. Testing uses fixtures under `test/config/` via a new TestRunner `-ConfigPath` param; the live `config.json` is never modified by feature tests.

**Tech Stack:** PowerShell 5.1-compatible scripts (hook runtime), XML test suites run by `src/TestRunner.ps1`, JSON config.

**Key invariants (verify after EVERY task):**
- Normal-mode behavior byte-identical: `test-cases.xml` stays **684/690** (6 pre-existing fails: #521 git-add var-assignment, #666-669 + #685 redirect-non-system).
- The hook in this session loads the live `config.json` — an invalid config deadlocks the session (fail-closed). Every `config.json` edit must leave valid JSON.
- Hook self-protection when executing this plan (avoids prompts):
  - Branch with `git switch -c` (read_only → allow), NOT `git checkout -b` (modifying → ask).
  - Create fixtures with Read+Write tools, NOT `Copy-Item` (modifying → ask).
  - Test runs match the `src.TestRunner.ps1` trusted_pattern → allow.
  - The fullpipe runner (`test\FullPipeTestRunner.ps1`) is NOT trusted — expect one prompt; approve it. It MUST be run with `pwsh -NoProfile`, not `powershell.exe`.

---

### Task 1: Create feature branch

**Files:** none

- [ ] **Step 1: Branch from master**

```powershell
git switch -c strictness-gated
```

Expected: `Switched to a new branch 'strictness-gated'` (master is at e78df01).

---

### Task 2: TestRunner `-ConfigPath` param

**Files:**
- Modify: `src/TestRunner.ps1` (param block lines 1-7, config load line 25, summary line 183)

- [ ] **Step 1: Add the param**

Edit `src/TestRunner.ps1` lines 1-7:

```powershell
param(
    [string]$XmlPath = "$PSScriptRoot\..\test\test-cases.adhoc.xml",
    [string]$Filter = "",
    [string]$Strictness = "",
    [string]$Cwd = "",
    [string]$EditablePaths = "",
    [string]$ConfigPath = ""
)
```

- [ ] **Step 2: Use it at config load + report it in the summary**

Replace line 25:

```powershell
$config = Load-Config -Path "$PSScriptRoot\..\config.json"
```

with:

```powershell
$configFile = if ($ConfigPath) { $ConfigPath } else { "$PSScriptRoot\..\config.json" }
$config = Load-Config -Path $configFile
```

Replace line 183 `Write-Host "Config:   config.json"` with:

```powershell
Write-Host "Config:   $configFile"
```

- [ ] **Step 3: Verify default behavior unchanged**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" | Select-Object -Last 12`
Expected: `Total: 690`, `Passed: 684 (99.1%)`, `Failed: 6`, `Config:   <abs path>\config.json`; same 6 pre-existing fails (#521, #666-669, #685).

- [ ] **Step 4: Verify explicit -ConfigPath gives identical results**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" -ConfigPath "config.json" | Select-Object -Last 12`
Expected: identical 684/690.

- [ ] **Step 5: Commit**

```powershell
git add src/TestRunner.ps1
git commit -m "feat: TestRunner -ConfigPath param for fixture-based config testing"
```

---

### Task 3: ConfigLoader — compile + validate `strictness_gated`, validate per-domain `modifying_strictness`

**Files:**
- Modify: `src/ConfigLoader.ps1` (validation loop ~lines 259-273; compile loop ~lines 397-412)

This code is dormant until config domains gain `strictness_gated` sections (Task 6). Style note: the pattern-compile block is deliberately duplicated a third time (read_only and modifying already duplicate it) — consistent with the existing file style; do not refactor into a helper in this plan.

- [ ] **Step 1: Add validation (inside the `foreach ($domainKey in $commandKeys)` validation loop, immediately after the "Validate modifying entry patterns compile" block, i.e. after the closing `}` of `if ($hasModifying) { ... }` and before the `# Validate parameter_commands` comment)**

```powershell
        # Validate optional per-domain modifying_strictness (guard: only consulted
        # when the global modifying_strictness is 'normal' — see Get-EffectiveStrictness)
        if (Get-Member -InputObject $domain -Name 'modifying_strictness' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            if ($domain.modifying_strictness -notin @('strict', 'normal', 'loose')) {
                throw "Configuration validation failed: domain '$domainKey' modifying_strictness must be 'strict', 'normal', or 'loose', got '$($domain.modifying_strictness)'"
            }
        }

        # Validate strictness_gated entry patterns compile (optional middle tier)
        $hasGated = Get-Member -InputObject $domain -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($hasGated) {
            foreach ($entry in $domain.strictness_gated) {
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        try {
                            $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
                        }
                        catch {
                            throw "Invalid regex pattern in config (domain '$domainKey', strictness_gated entry '$($entry.name)'): $pattern"
                        }
                    }
                }
            }
        }
```

- [ ] **Step 2: Add compilation (inside the `foreach ($domainKey in $commandKeys)` compile loop, immediately after the "Compile modifying entry patterns" block and before the `# Build parameter_commands lookup` comment)**

```powershell
        # Compile strictness_gated entry patterns
        if (Get-Member -InputObject $domain -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            foreach ($entry in $domain.strictness_gated) {
                $compiledPatterns = @()
                if (Get-Member -InputObject $entry -Name 'patterns' -MemberType NoteProperty) {
                    foreach ($pattern in $entry.patterns) {
                        # Auto-anchor with ^ to prevent substring false positives
                        $anchoredPattern = if ($pattern.StartsWith('^')) { $pattern } else { '^' + $pattern }
                        # Convert glob * to .* only when * follows a non-special character
                        $anchoredPattern = $anchoredPattern -replace '(?<![.*\\])\*(?!\?|\*|\{)', '.*'
                        $compiledPatterns += [regex]::new($anchoredPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
                    }
                }
                $entry | Add-Member -MemberType NoteProperty -Name '_compiledPatterns' -Value $compiledPatterns -Force
            }
        }
```

- [ ] **Step 3: Verify live config still loads and classifies identically**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" | Select-Object -Last 12`
Expected: 684/690, same 6 fails.

- [ ] **Step 4: Negative validation tests (bad fixtures must throw)**

Create `C:\temp\sg-test\bad-strictness.json` with the Write tool: Read `config.json`, Write the full content to that path, then Edit the top-level `"modifying_strictness": "normal",` line to `"modifying_strictness": "bogus",`.

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" -ConfigPath "C:\temp\sg-test\bad-strictness.json"`
Expected: immediate throw containing `Configuration validation failed: 'modifying_strictness' must be 'normal', 'strict', or 'loose'` (pre-existing global validation — sanity that the harness surfaces config errors).

Create `C:\temp\sg-test\bad-gated.json` the same way, but this Edit: in the `Git` domain, after the `"_comment_planned": ...` line insert:

```json
      "modifying_strictness": "bogus",
```

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" -ConfigPath "C:\temp\sg-test\bad-gated.json"`
Expected: immediate throw containing `domain 'Git' modifying_strictness must be 'strict', 'normal', or 'loose'` (proves the new Step-1 validation fires).

- [ ] **Step 5: Commit**

```powershell
git add src/ConfigLoader.ps1
git commit -m "feat: compile + validate strictness_gated tier and per-domain modifying_strictness"
```

---

### Task 4: Resolver — `Get-EffectiveStrictness`, match step 1a.5, effective-strictness at the two reach points

**Files:**
- Modify: `src/Resolver.ps1` (header comment lines 12-16; new function before line 19; step 1a.5 between lines 344 and 346; call site line 324; condition line 180; `Evaluate-ParameterRules` signature line 849-856 and condition line 890)

All changes are dormant until Task 6 adds `strictness_gated` sections to config.json: with no per-domain strictness keys anywhere, `Get-EffectiveStrictness` returns the global value, so :180/:890 behave exactly as before.

- [ ] **Step 1: Add `Get-EffectiveStrictness` (script level, between the header comment block ending at line 17 and `function Resolve-Command {` at line 19)**

```powershell
function Get-EffectiveStrictness {
    <#
    .SYNOPSIS
        Resolve the effective modifying_strictness for a command domain.
    .DESCRIPTION
        Guard rule: a global 'strict' or 'loose' forces ALL domains. Only when the
        global value is 'normal' does a domain's own modifying_strictness apply;
        domains without one inherit 'normal'. Used by the strictness_gated tier,
        AWS flag-stripping, and parameter_commands unrecognized-value handling.
        Path policy (Parser.ps1) intentionally stays on the global value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    if ($Config.modifying_strictness -ne 'normal') { return $Config.modifying_strictness }

    foreach ($key in $Config.commands.PSObject.Properties.Name) {
        if ($key.ToLowerInvariant() -eq $Domain.ToLowerInvariant()) {
            $dom = $Config.commands.$key
            if (Get-Member -InputObject $dom -Name 'modifying_strictness' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                return $dom.modifying_strictness
            }
            break
        }
    }
    return 'normal'
}
```

(ConfigLoader validation from Task 3 guarantees a present value is one of strict/normal/loose, so no re-validation here.)

- [ ] **Step 2: Insert match step 1a.5 (after the read_only block ends at line 344 `}`, before the `# Step 1b` comment at line 346)**

```powershell
    # -------------------------------------------------
    # Step 1a.5: Check strictness_gated entries
    #   Middle tier: allow in normal/loose, ask when the EFFECTIVE
    #   strictness for this domain is strict (Get-EffectiveStrictness).
    # -------------------------------------------------
    $hasGated = Get-Member -InputObject $domainConfig -Name 'strictness_gated' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasGated) {
        foreach ($entry in $domainConfig.strictness_gated) {
            if (Get-Member -InputObject $entry -Name '_compiledPatterns' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                foreach ($regex in $entry._compiledPatterns) {
                    if ($regex.IsMatch($Command)) {
                        $effective = Get-EffectiveStrictness -Config $Config -Domain $domainKey
                        if ($effective -eq 'strict') {
                            $risk = "unknown"
                            if (Get-Member -InputObject $entry -Name 'risk' -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                                $risk = $entry.risk
                            }
                            return New-ResolutionResult -Decision "ask" -Reason "$($entry.name)" -MatchedPattern $entry.name -Risk $risk
                        }
                        return New-ResolutionResult -Decision "allow" -Reason "$($entry.name) (strictness-gated)" -MatchedPattern $entry.name -Risk "none"
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: AWS flag-strip uses effective strictness (line 180)**

Replace:

```powershell
    if ($domainLower -eq 'aws_cli' -and $Config.modifying_strictness -eq 'normal' -and $Command -match '^aws\s') {
```

with:

```powershell
    if ($domainLower -eq 'aws_cli' -and (Get-EffectiveStrictness -Config $Config -Domain $domainKey) -eq 'normal' -and $Command -match '^aws\s') {
```

- [ ] **Step 4: parameter_commands unrecognized-value uses effective strictness**

First verify `Evaluate-ParameterRules` has exactly one call site:
Run: `grep -n "Evaluate-ParameterRules" src/Resolver.ps1` (use the Grep tool)
Expected: line 324 (call) and line 849 (definition).

Change the signature (lines 849-856) from:

```powershell
function Evaluate-ParameterRules {
    param(
        $Entry,
        $ParamMap,
        $Config,
        [string]$Command,
        [string]$DisplayName
    )
```

to:

```powershell
function Evaluate-ParameterRules {
    param(
        $Entry,
        $ParamMap,
        $Config,
        [string]$Command,
        [string]$DisplayName,
        [string]$Domain
    )
```

Change line 890 from:

```powershell
    if ($unrecognized -and $Config.modifying_strictness -ne 'loose') {
```

to:

```powershell
    if ($unrecognized -and (Get-EffectiveStrictness -Config $Config -Domain $Domain) -ne 'loose') {
```

Change the call site (line 324) from:

```powershell
                $pResult = Evaluate-ParameterRules -Entry $entry -ParamMap $paramMap -Config $Config -Command $Command -DisplayName $firstToken
```

to (the entry can come from the PowerShell domain's lookup via the alias fallback, so pass the OWNING domain):

```powershell
                $owningDomain = if ($asPowerShell) { 'PowerShell' } else { $domainKey }
                $pResult = Evaluate-ParameterRules -Entry $entry -ParamMap $paramMap -Config $Config -Command $Command -DisplayName $firstToken -Domain $owningDomain
```

- [ ] **Step 5: Update the header comment match-order (lines 12-16)**

Replace:

```
    Match order per domain:
      1. Explicit "read_only" entries (compiled regex)
      2. Explicit "modifying" entries (compiled regex)
      3. Verb-based classification (PowerShell / AWS domains only)
      4. Fallback: ask with reason "unknown command"
```

with:

```
    Match order per domain:
      1. Explicit "read_only" entries (compiled regex)
      1a.5. Explicit "strictness_gated" entries (allow in normal/loose, ask in strict
            per Get-EffectiveStrictness)
      2. Explicit "modifying" entries (compiled regex)
      3. Verb-based classification (PowerShell / AWS domains only)
      4. Fallback: ask with reason "unknown command"
```

- [ ] **Step 6: Dormant-code regression — must be byte-identical**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" | Select-Object -Last 12`
Expected: 684/690, same 6 fails. (No domain has strictness_gated yet, so 1a.5 never fires; :180/:890 get effective == global.)

- [ ] **Step 7: Commit**

```powershell
git add src/Resolver.ps1
git commit -m "feat: Get-EffectiveStrictness + strictness_gated match step 1a.5 + effective-strictness reach"
```

---

### Task 5: Fixtures + three new suites (RED)

**Files:**
- Create: `test/config/config.git-strict.json`, `test/config/config.strict.json` (copies of CURRENT pre-migration config.json + one strictness flip each)
- Create: `test/test-cases.strictness-gated.normal.xml`, `test/test-cases.strictness-gated.strict.xml`, `test/test-cases.strictness-gated.git-strict.xml`

The strict and git-strict suites FAIL at this point (RED) because the Git/Linux entries are still in `read_only`; Task 6 migrates them and both suites go GREEN. The normal suite passes now and must keep passing — it is the byte-identical guard.

- [ ] **Step 1: Create `test/config/config.git-strict.json`**

Read `config.json`, Write its full content to `test/config/config.git-strict.json` (Write creates the `test/config/` directory). Then Edit: replace the unique anchor `      "description": "Git version control commands",` with:

```json
      "description": "Git version control commands",
      "_comment_fixture": "TEST FIXTURE - copy of config.json with the Git domain forced to strict. Used by test-cases.strictness-gated.git-strict.xml. Regenerate from config.json whenever it changes.",
      "modifying_strictness": "strict",
```

- [ ] **Step 2: Create `test/config/config.strict.json`**

Read `config.json`, Write its full content to `test/config/config.strict.json`. Then Edit: replace the unique top-level `  "modifying_strictness": "normal",` with:

```json
  "_comment_fixture": "TEST FIXTURE - copy of config.json with global strictness forced to strict. Drives test-cases.redirect-strict.xml without -Strictness. Regenerate from config.json whenever it changes.",
  "modifying_strictness": "strict",
```

(The top-level key is unique — no per-domain `modifying_strictness` exists yet; the Git-domain one is inside the other fixture's file, not this one.)

- [ ] **Step 3: Write `test/test-cases.strictness-gated.normal.xml`** (24 cases; run with default config, no extra params)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  strictness_gated suite — NORMAL mode (default config.json).
  Every gated entry must ALLOW; read_only and modifying controls unchanged.
  This suite must pass both before and after the config migration (byte-identical guard).
-->
<commands>
  <category-group name="SG-Normal">

    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git add stages (gated)</description>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git add -A stages all (gated)</description>
      <copilot-command><![CDATA[git add -A]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git pull (gated)</description>
      <copilot-command><![CDATA[git pull]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git pull --rebase (gated)</description>
      <copilot-command><![CDATA[git pull --rebase]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git commit single -m (gated)</description>
      <copilot-command><![CDATA[git commit -m "test message"]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git commit repeated -m for multi-line body (gated)</description>
      <copilot-command><![CDATA[git commit -m "subject" -m "body line"]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git switch branch (gated)</description>
      <copilot-command><![CDATA[git switch main]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git init (gated)</description>
      <copilot-command><![CDATA[git init]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git clone (gated)</description>
      <copilot-command><![CDATA[git clone https://github.com/user/repo.git]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git tag -d (gated)</description>
      <copilot-command><![CDATA[git tag -d v1.0]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git tag --delete (gated)</description>
      <copilot-command><![CDATA[git tag --delete v1.0]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git worktree add (gated)</description>
      <copilot-command><![CDATA[git worktree add ../wt feature]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git rev-parse (gated, medium risk shown when it asks in strict)</description>
      <copilot-command><![CDATA[git rev-parse HEAD]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git stash (gated)</description>
      <copilot-command><![CDATA[git stash]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Git-Gated">
      <description>git stash push with message (gated)</description>
      <copilot-command><![CDATA[git stash push -m "wip"]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Linux-Gated">
      <description>printf simple (gated)</description>
      <copilot-command><![CDATA[printf "hello world"]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="gated allow in normal" category="SG-Normal-Linux-Gated">
      <description>printf with format string (gated)</description>
      <copilot-command><![CDATA[printf '%s\n' one two]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read_only unaffected" category="SG-Normal-Controls">
      <description>git status stays read_only allow</description>
      <copilot-command><![CDATA[git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read_only unaffected" category="SG-Normal-Controls">
      <description>git log stays read_only allow</description>
      <copilot-command><![CDATA[git log --oneline -5]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read_only unaffected" category="SG-Normal-Controls">
      <description>git fetch stays read_only allow</description>
      <copilot-command><![CDATA[git fetch origin]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying unaffected" category="SG-Normal-Controls">
      <description>git push still asks</description>
      <copilot-command><![CDATA[git push origin main]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying unaffected" category="SG-Normal-Controls">
      <description>git reset --hard still asks</description>
      <copilot-command><![CDATA[git reset --hard HEAD]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying unaffected" category="SG-Normal-Controls">
      <description>rm -rf still asks</description>
      <copilot-command><![CDATA[rm -rf /tmp/junk]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="gated allow in normal (var-assignment strip)" category="SG-Normal-VarAssignment">
      <description>$x = git add . allows in normal (documents pre-existing #521 behavior)</description>
      <copilot-command><![CDATA[$x = git add .]]></copilot-command>
    </test-case>

  </category-group>
</commands>
```

- [ ] **Step 4: Write `test/test-cases.strictness-gated.strict.xml`** (24 cases; run with `-Strictness strict`)

Identical command set to the normal suite; flips: the 15 Git-gated cases → `expected="ask"`, the 2 printf cases → `expected="ask"` (global strict forces ALL domains, Linux included), the var-assignment case → `expected="ask"`. The 6 control cases keep identical expectations (git status/log/fetch allow; push/reset/rm ask). Category names `SG-Strict-*`; header comment:

```xml
<!--
  strictness_gated suite — STRICT mode (-Strictness strict, default config.json).
  Every gated entry must ASK (global strict forces all domains, incl. Linux printf).
  read_only controls still allow; modifying controls still ask.
-->
```

- [ ] **Step 5: Write `test/test-cases.strictness-gated.git-strict.xml`** (12 cases; run with `-ConfigPath "test/config/config.git-strict.json"`, NO -Strictness)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  strictness_gated suite — PER-DOMAIN strict (fixture: commands.Git.modifying_strictness=strict,
  global normal). Git gated entries ASK; Linux gated printf ALLOWS (per-domain isolation);
  AWS flag-strip still active (AWS domain inherits normal — effective-strictness reach).
-->
<commands>
  <category-group name="SG-GitStrict">

    <test-case expected="ask" reason="gated ask: Git domain strict" category="SG-GitStrict-Gated">
      <description>git add . asks when Git domain is strict</description>
      <copilot-command><![CDATA[git add .]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="gated ask: Git domain strict" category="SG-GitStrict-Gated">
      <description>git commit asks when Git domain is strict</description>
      <copilot-command><![CDATA[git commit -m "x"]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="gated ask: Git domain strict" category="SG-GitStrict-Gated">
      <description>git pull asks when Git domain is strict</description>
      <copilot-command><![CDATA[git pull]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="gated ask: Git domain strict" category="SG-GitStrict-Gated">
      <description>git worktree add asks when Git domain is strict</description>
      <copilot-command><![CDATA[git worktree add ../wt feature]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="gated ask: Git domain strict (medium risk)" category="SG-GitStrict-Gated">
      <description>git rev-parse asks when Git domain is strict</description>
      <copilot-command><![CDATA[git rev-parse HEAD]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="gated ask: Git domain strict" category="SG-GitStrict-Gated">
      <description>git stash asks when Git domain is strict</description>
      <copilot-command><![CDATA[git stash]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="isolation: Linux inherits normal" category="SG-GitStrict-Isolation">
      <description>printf still allows (Linux domain not strict — per-domain isolation)</description>
      <copilot-command><![CDATA[printf "hello world"]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read_only unaffected" category="SG-GitStrict-Isolation">
      <description>git status still allows (read_only, not gated)</description>
      <copilot-command><![CDATA[git status]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read_only unaffected" category="SG-GitStrict-Isolation">
      <description>git log still allows</description>
      <copilot-command><![CDATA[git log --oneline -5]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying unaffected" category="SG-GitStrict-Isolation">
      <description>git push still asks (modifying, independent of strictness)</description>
      <copilot-command><![CDATA[git push origin main]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying unaffected" category="SG-GitStrict-Isolation">
      <description>rm -rf still asks (Linux modifying)</description>
      <copilot-command><![CDATA[rm -rf /tmp/junk]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="AWS flag-strip active: AWS domain inherits normal" category="SG-GitStrict-AWS-Reach">
      <description>aws describe with --flags allows (flag-strip uses EFFECTIVE strictness, AWS=normal)</description>
      <copilot-command><![CDATA[aws ec2 describe-instances --profile prod --region us-west-2]]></copilot-command>
    </test-case>

  </category-group>
</commands>
```

- [ ] **Step 6: Run the three suites — record the RED state**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.normal.xml" | Select-Object -Last 8`
Expected NOW: **24/24 pass** (entries still read_only → allow).

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.strict.xml" -Strictness strict | Select-Object -Last 25`
Expected NOW (RED): **6/24 pass** — the 6 control cases; 18 fail (15 Git-gated + 2 printf + 1 var-assignment all allow because entries are still read_only).

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.git-strict.xml" -ConfigPath "test/config/config.git-strict.json" | Select-Object -Last 15`
Expected NOW (RED): **6/12 pass** — isolation + AWS cases pass; 6 Git-gated fail (allow, still read_only).

- [ ] **Step 7: Commit**

```powershell
git add test/config test/test-cases.strictness-gated.normal.xml test/test-cases.strictness-gated.strict.xml test/test-cases.strictness-gated.git-strict.xml
git commit -m "test: strictness_gated fixtures + 3 suites (strict/git-strict RED until config migration)"
```

---

### Task 6: config.json migration — move 11 entries to `strictness_gated` (GREEN)

**Files:**
- Modify: `config.json` (Git domain lines 543-566 read_only → new strictness_gated array; Linux domain line 403 printf → new strictness_gated array between lines 462 and 463; comment-key touch-ups)
- Modify: `test/config/config.git-strict.json`, `test/config/config.strict.json` (regenerate from migrated config)

Ordering note: this task is safe only because Tasks 3-4 already shipped — ConfigLoader compiles the new tier and Resolver matches it. In normal mode the moved entries still allow, so the live hook and all normal-mode suites stay byte-identical.

- [ ] **Step 1: Git domain — remove the 10 entries from `read_only`**

Delete these lines from the Git `read_only` array (lines 555-565 region): `git pull`, `git switch`, `git init`, `git clone`, `git tag -d`, `git add`, `git worktree add`, `git commit`, `git rev-parse`, `git stash`. Keep: status, log, ls-remote, ls-files, diff, check-ignore, show, branch, tag (list), remote, fetch, worktree list.

- [ ] **Step 2: Git domain — insert the `strictness_gated` array between `read_only` and `modifying`**

Note: `git switch` had no `risk` in read_only — it gets `"risk": "low"` here (risk is what the prompt shows when the entry asks in strict).

```json
      "strictness_gated": [
        { "name": "git pull",      "patterns": ["git pull*", "git pull *"],                      "risk": "low", "description": "Fetch and integrate (may modify working tree)" },
        { "name": "git switch",    "patterns": ["git switch$", "git switch *"],                  "risk": "low", "description": "Switch to a branch (modifies working tree)" },
        { "name": "git init",      "patterns": ["git init*", "git init *"],                      "risk": "low",    "description": "Create empty repository" },
        { "name": "git clone",     "patterns": ["git clone*", "git clone *"],                    "risk": "low",    "description": "Clone repository" },
        { "name": "git tag -d",    "patterns": ["git tag -d*", "git tag --delete*"],             "risk": "low",    "description": "Delete tag" },
        { "name": "git add",       "patterns": ["git add*", "git add *"],                        "risk": "low",    "description": "Stage file changes" },
        { "name": "git worktree add", "patterns": ["git worktree add*", "git worktree add *"], "risk": "low",    "description": "Add a linked worktree" },
        { "name": "git commit",    "patterns": ["git commit*", "git commit *"],                  "risk": "low",    "description": "Record changes to repository" },
        { "name": "git rev-parse",   "patterns": ["git rev-parse*", "git rev-parse *"],                "risk": "medium", "description": "rev-parse working tree files" },
        { "name": "git stash",     "patterns": ["git stash*", "git stash *"],                    "risk": "low",    "description": "Stash changes" }
      ],
```

- [ ] **Step 3: Linux domain — move `printf`**

Delete line 403 (`printf` entry) from Linux `read_only`. Insert between the `read_only` closing `],` (line 462) and `"modifying": [` (line 463), anchoring on the unique `gh release view` tail:

```json
        { "name": "gh release view", "patterns": ["gh release view*"],   "description": "View a release" }
      ],
      "strictness_gated": [
        { "name": "printf",   "patterns": ["printf *"],      "risk": "low",    "description": "Print Out" }
      ],
      "modifying": [
```

- [ ] **Step 4: Comment-key touch-ups (the tier is live now, not "planned")**

- Top-level `"_readme_tiers"`: change `strictness_gated (planned) =>` to `strictness_gated =>`.
- Top-level `"_comment_modifying_strictness"`: change `(planned strictness_gated entries ask;` to `(strictness_gated entries ask;`.
- In each of the 8 domain `"_comment_tiers"` keys: change `strictness_gated (planned) =>` to `strictness_gated =>` (6 pattern domains), and for PowerShell change `strictness_gated (planned) covers` to `strictness_gated covers`.
- Git domain: replace the `"_comment_planned"` key with:

```json
      "_comment_gated": "strictness_gated below: git add, pull, commit, switch, init, clone, tag -d, worktree add, rev-parse, stash — allow in normal/loose, ask in strict.",
```

- [ ] **Step 5: Normal-mode regression — THE byte-identical gate**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" | Select-Object -Last 12`
Expected: **684/690, same 6 fails.** (#521 `$var = git add .` still allows in normal → still fails; spec §4 acknowledges. It passes under strict — proven by the strict suite.)

If anything else changed: a moved entry was dropped/misplaced (e.g. left out of both arrays → falls to unknown-command ask). Fix before continuing.

- [ ] **Step 6: Regenerate both fixtures from the migrated config**

Re-Read `config.json`; re-Write `test/config/config.git-strict.json` with its full content; re-apply the Task 5 Step 1 Edit (`_comment_fixture` + `"modifying_strictness": "strict",` after the Git description). Same for `test/config/config.strict.json` (re-Write + re-apply the global-strict Edit from Task 5 Step 2). This is required — the fixtures must contain the new `strictness_gated` sections.

- [ ] **Step 7: Run the three suites — GREEN**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.normal.xml" | Select-Object -Last 8`
Expected: **24/24**.

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.strict.xml" -Strictness strict | Select-Object -Last 8`
Expected: **24/24** (was 6/24 in Task 5 — the RED→GREEN proof).

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.git-strict.xml" -ConfigPath "test/config/config.git-strict.json" | Select-Object -Last 8`
Expected: **12/12** (was 6/12).

- [ ] **Step 8: Commit**

```powershell
git add config.json test/config test/test-cases.strictness-gated.normal.xml test/test-cases.strictness-gated.strict.xml test/test-cases.strictness-gated.git-strict.xml
git commit -m "feat: migrate git x10 + linux printf to strictness_gated tier"
```

---

### Task 7: redirect-strict becomes fixture-driven

**Files:** none (invocation change only; documents the new capability)

- [ ] **Step 1: Run redirect-strict against the strict fixture instead of -Strictness**

Old invocation: `-XmlPath "test/test-cases.redirect-strict.xml" -Strictness strict`
New invocation: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-strict.xml" -ConfigPath "test/config/config.strict.json" | Select-Object -Last 12`
Expected: **24/25**, same single pre-existing failure as the `-Strictness strict` run (the suite is decoupled from the live config from now on).

- [ ] **Step 2: Commit (if any run-script/docs reference the old invocation, update them; otherwise nothing to commit)**

---

### Task 8: Docs + full regression + merge prep

**Files:**
- Modify: `docs/config-json-guide.md` (insert new section after `## 9. commands — the classification database` content, before `## 10. Editing checklist`)
- Modify: `PROGRESS.md`

- [ ] **Step 1: Add the strictness_gated section to `docs/config-json-guide.md`**

Insert before `## 10. Editing checklist (any config change)` (renumber section 10 to 11):

```markdown
## 10. `strictness_gated` — the strictness-dependent middle tier

Each domain may carry a `strictness_gated` array between `read_only` and `modifying`.
Entry shape is identical (`name` / `patterns` / `risk` / `description`); `risk` is what
the prompt shows when the entry asks.

Decision: **allow** when the effective strictness is `normal` or `loose`, **ask** when
it is `strict`. Use it for commands that are technically modifying but safe enough to
auto-approve day-to-day (e.g. `git add`) while still prompting under strict.

### Per-domain `modifying_strictness` + the global guard

Any domain may set its own `"modifying_strictness": "strict" | "normal" | "loose"`.
The effective strictness for a domain is resolved by `Get-EffectiveStrictness`:

1. Global `modifying_strictness` is `strict` or `loose` → that value **forces every domain**.
2. Global is `normal` → the domain's own value (absent → `normal`).

Effective strictness drives three things: the `strictness_gated` tier, AWS CLI
flag-stripping (active only when the AWS domain is effectively normal), and
parameter_commands unrecognized-value handling (asks unless effectively loose).
Path policy (`system_paths` / `editable_paths` / CWD) is cross-domain and always
uses the **global** value.

Shipped config sets no per-domain strictness (everything inherits normal), so
default behavior only changes when you opt a domain in. To force one domain,
add e.g. `"modifying_strictness": "strict"` inside `commands.Git` — see the fixture
`test/config/config.git-strict.json` for a working example.
```

- [ ] **Step 2: Update `PROGRESS.md`** — mark the feature implemented; record branch, suites, and regression numbers.

- [ ] **Step 3: Full regression battery**

Run each (expected after `|`):

- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml" | Select-Object -Last 12` → **684/690**
- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.normal.xml" | Select-Object -Last 8` → **24/24**
- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.strict.xml" -Strictness strict | Select-Object -Last 8` → **24/24**
- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.strictness-gated.git-strict.xml" -ConfigPath "test/config/config.git-strict.json" | Select-Object -Last 8` → **12/12**
- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-strict.xml" -ConfigPath "test/config/config.strict.json" | Select-Object -Last 12` → **24/25**
- `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml" -Cwd "C:\git\repo" | Select-Object -Last 12` → **69/74** (5 pre-existing docker-comfyui fails)
- `pwsh -NoProfile -File "test/FullPipeTestRunner.ps1"` → **19/19** (may prompt once for the runner itself; approve it)

- [ ] **Step 4: Commit**

```powershell
git add docs/config-json-guide.md PROGRESS.md
git commit -m "docs: strictness_gated + per-domain strictness in config guide; progress update"
```

- [ ] **Step 5: Hand back for merge decision** — do NOT merge to master without explicit user approval.

---

## Self-Review Notes (already applied)

- **Spec coverage:** L1 name (Tasks 3/4/6), L2 scope (per-domain strictness: Tasks 3/4, fixtures Task 5), L3 guard (`Get-EffectiveStrictness` Task 4 Step 1), L4 reach (:180 Task 4 Step 3, :890 Task 4 Step 4, path policy untouched — asserted by the 684/690 + 24/25 regression gates), L5 fixtures (Tasks 2/5). Move list Git×10 + printf (Task 6). `git switch` gains `"risk": "low"` (spec requires risk on gated entries; it had none in read_only). Docs (Task 8). Out-of-scope items (verb tiers, per-domain path policy, loose reverse-tier) are not implemented anywhere.
- **Ordering constraint caught and encoded:** config migration (Task 6) MUST come after ConfigLoader+Resolver support (Tasks 3-4) — otherwise `git add` would fall to unknown-command ask in normal mode, breaking the live hook.
- **Fixture drift:** fixtures are full copies; Task 6 Step 6 regenerates them post-migration and their `_comment_fixture` says to regenerate on any config change.
- **redirect-strict reconciliation:** verified it contains zero moved Git entries (grep), so the strict run stays 24/25 (spec §5.4).
- **Case #521:** stays a pre-existing normal-mode fail by design (spec §4); the strict suite proves it asks under strict.
