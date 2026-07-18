# AST-as-Arbiter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify legitimate read-only commands that today fall through to "unknown command" — quoted regex strings, pure PowerShell expressions, call-operator scriptblocks, AWS bare verbs — via an AST-as-arbiter architecture, with zero behavior change for all currently-passing tests.

**Architecture:** Keep the existing pipeline untouched. Add an arbiter gate in `Classifier.ps1` that activates only when the final decision is `ask` AND every blocker is the unknown-command fallback; it re-parses the whole line with the PowerShell AST and allows only under complete per-statement accounting (hardened `Test-SafeAst` + known-allow command resolution). Retain the primary-path fixes (string heuristic, call-operator, zero-command safe expressions) for powershell-detected lines.

**Spec:** `docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md` (commit `897f9f8`). Read it first.

**Base branch:** `fix-var-assignment-detection` ONLY. Never `ClaudeCode-v1`.

**Tech Stack:** PowerShell 7, `System.Management.Automation.Language.Parser`, XML test cases, custom `src/TestRunner.ps1`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/Classifier.ps1` | Pipeline orchestration | Arbiter gate + `Invoke-PowerShellArbitration` + `Resolve-AsArbiter`; zero-command safe-expression integration |
| `src/Parser.ps1` | AST parsing/extraction | `Test-SafeAst` (hardened, shared); `Get-PowerShellSafeExpressions`; string-heuristic fix; call-operator skip + wrapper safety-net |
| `src/Resolver.ps1` | Per-command classification | `'(safe expression)'` marker early-allow; Step 0e ≥2-token guard |
| `src/ConfigLoader.ps1` | Config validation/compilation | `_dotnetMethodAllowlist` (config `safe_expressions.dotnet_method_allowlist` or built-in default) |
| `config.json` | Runtime config | `aws configure get/list` read_only; `safe_expressions` block |
| `test/test-cases.adhoc.xml` | Regression tests | Merge 14 canonical cases + `AST-Arbiter-Guard` negative tests |
| `test/test-cases.new-samples.xml` | Canonical empirical set | Already committed (`897f9f8`); no change |

---

## Task 1: Worktree + baseline capture

**Files:** none modified

- [ ] **Step 1: Create a fresh worktree from `fix-var-assignment-detection`**

```bash
mkdir -p ~/.config/superpowers/worktrees/pretoolhook
git worktree add ~/.config/superpowers/worktrees/pretoolhook/ast-arbiter -b ast-arbiter fix-var-assignment-detection
```

If the hook blocks `cd`-based tool calls into the worktree, run all commands with `cd ~/.config/superpowers/worktrees/pretoolhook/ast-arbiter && <cmd>` inside Bash. All paths below are relative to the worktree root.

- [ ] **Step 2: Capture baseline results for EVERY suite and save them**

```powershell
cd ~/.config/superpowers/worktrees/pretoolhook/ast-arbiter
foreach ($f in @('test-cases.xml','test-cases.adhoc.xml','test-cases.redirect-normal.xml','test-cases.redirect-strict.xml','test-cases.var-assignment.xml','test-cases.fullpath.xml','test-cases.trustedpattern.xml','test-cases.new-samples.xml')) {
  Write-Host "=== $f ==="
  pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/$f" 2>&1 | Select-String -Pattern '^(Total|Passed|Failed):'
}
pwsh -NoProfile -File test/FullPipeTestRunner.ps1 2>&1 | Select-String -Pattern '^(Total|Passed|Failed):'
```

Record the `Total/Passed/Failed` triple per suite as **BASELINE**. Expected: all existing suites 100% pass; `test-cases.new-samples.xml` currently has 1 pass / 13 fail (only `aws configure get` may already pass on this branch — record the actual numbers).

- [ ] **Step 3: Commit the baseline note**

Append the recorded numbers to `PROGRESS.md` under `## Baseline (pre-change)`, then:

```bash
git add PROGRESS.md
git commit -m "chore: record pre-change baseline suite results" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Config — AWS configure entries + safe_expressions block

**Files:**
- Modify: `config.json` (AWS_CLI `read_only` array; top level)

- [ ] **Step 1: Add AWS configure read_only entries**

In `config.json`, inside `commands.AWS_CLI.read_only`, add (near the `aws s3 ls` entries):

```json
        { "name": "aws configure get",            "patterns": ["^aws\\s+configure\\s+get\\b"],            "description": "Read an AWS configure value" },
        { "name": "aws configure list",           "patterns": ["^aws\\s+configure\\s+list\\b"],           "description": "List AWS configure values" },
```

- [ ] **Step 2: Add the `safe_expressions` top-level block**

In `config.json`, after the `system_paths` block, add:

```json
  "safe_expressions": {
    "description": "Allowlist for the safe-expression certifier (AST arbiter + zero-command fallback). Method names matched case-insensitively.",
    "dotnet_method_allowlist": [
      "ReadAllText", "ReadAllLines", "ReadLines", "OpenRead",
      "Substring", "Split", "Replace", "ToString", "ToUpper", "ToLower",
      "Trim", "TrimStart", "TrimEnd", "Contains", "StartsWith", "EndsWith",
      "IndexOf", "LastIndexOf", "PadLeft", "PadRight",
      "Max", "Min", "Abs", "Round", "Floor", "Ceiling", "Sqrt", "Pow",
      "Compare", "Equals", "GetHashCode", "GetType"
    ]
  },
```

- [ ] **Step 3: Add ConfigLoader support**

In `src/ConfigLoader.ps1`, inside `Test-ConfigSchema`, after the `system_paths` compilation block (after `_systemPathRegex` is set), add:

```powershell
    # safe_expressions: .NET method allowlist for the safe-expression certifier.
    # Optional; defaults to a built-in conservative list when absent.
    $defaultDotNetMethods = @(
        'readalltext','readalllines','readlines','openread',
        'substring','split','replace','tostring','toupper','tolower',
        'trim','trimstart','trimend','contains','startswith','endswith',
        'indexof','lastindexof','padleft','padright',
        'max','min','abs','round','floor','ceiling','sqrt','pow',
        'compare','equals','gethashcode','gettype'
    )
    $methodNames = $defaultDotNetMethods
    $hasSafeExprs = Get-Member -InputObject $Config -Name 'safe_expressions' -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($hasSafeExprs -and $Config.safe_expressions -and
        (Get-Member -InputObject $Config.safe_expressions -Name 'dotnet_method_allowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
        $Config.safe_expressions.dotnet_method_allowlist) {
        $methodNames = @($Config.safe_expressions.dotnet_method_allowlist | ForEach-Object { "$_".ToLowerInvariant() })
    }
    $methodSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $methodNames) { [void]$methodSet.Add($m) }
    $Config | Add-Member -MemberType NoteProperty -Name '_dotnetMethodAllowlist' -Value $methodSet -Force
```

- [ ] **Step 4: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: new-samples `aws configure get` case now **passes** (2 pass / 12 fail or better); `test-cases.xml` matches BASELINE exactly.

- [ ] **Step 5: Commit**

```bash
git add config.json src/ConfigLoader.ps1
git commit -m "config: aws configure get/list + safe_expressions dotnet method allowlist" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Hardened shared `Test-SafeAst` + zero-command safe-expression fallback

**Files:**
- Modify: `src/Parser.ps1` (append helpers)
- Modify: `src/Classifier.ps1` (zero-command integration, ~line 313)
- Modify: `src/Resolver.ps1` (marker early-allow, before Step 0)

- [ ] **Step 1: Add `Test-SafeAst` and `Get-PowerShellSafeExpressions` to `src/Parser.ps1`**

Append at the end of `src/Parser.ps1`:

```powershell
# =============================================================================
# Test-SafeAst
#
# Shared safe-expression certifier. Used by:
#   - Get-PowerShellSafeExpressions (primary path, zero-command lines)
#   - Invoke-PowerShellArbitration   (arbiter gate in Classifier.ps1)
#
# A node is SAFE when it provably has no side effects:
#   - no command invocations except those already resolved ALLOW
#     (their text is in $AllowedCommands)
#   - no .NET method calls outside the config allowlist
#     ($Config._dotnetMethodAllowlist)
#   - no property SETs (assignment LHS must be a variable / index / array)
#   - no redirections anywhere in the subtree
# Anything unrecognized is unsafe (fail closed).
# =============================================================================

function Test-SafeAst {
    param(
        $Ast,
        [System.Collections.Generic.HashSet[string]]$AllowedCommands,
        [PSCustomObject]$Config
    )

    if ($null -eq $Ast) { return $true }

    # Redirections anywhere in the subtree are never safe (they write files).
    if ($Ast -is [System.Management.Automation.Language.RedirectionAst]) { return $false }

    $typeName = $Ast.GetType().Name

    switch ($typeName) {
        'AssignmentStatementAst' {
            $lhs = $Ast.Left
            $lhsOk = ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) -or
                     ($lhs -is [System.Management.Automation.Language.IndexExpressionAst]) -or
                     ($lhs -is [System.Management.Automation.Language.ArrayLiteralAst])
            if (-not $lhsOk) { return $false }
            return (Test-SafeAst -Ast $Ast.Left -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Right -AllowedCommands $AllowedCommands -Config $Config)
        }
        'PipelineAst' {
            foreach ($elem in $Ast.PipelineElements) {
                if (-not (Test-SafeAst -Ast $elem -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'StatementBlockAst' {
            foreach ($stmt in $Ast.Statements) {
                if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'HashtableAst' {
            foreach ($kvp in $Ast.KeyValuePairs) {
                if (-not (Test-SafeAst -Ast $kvp.Item1 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
                if (-not (Test-SafeAst -Ast $kvp.Item2 -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ArrayLiteralAst' {
            foreach ($elem in $Ast.Elements) {
                if (-not (Test-SafeAst -Ast $elem -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ParenExpressionAst'   { return Test-SafeAst -Ast $Ast.Pipeline -AllowedCommands $AllowedCommands -Config $Config }
        'ArrayExpressionAst'   { return Test-SafeAst -Ast $Ast.SubExpression -AllowedCommands $AllowedCommands -Config $Config }
        'SubExpressionAst'     { return Test-SafeAst -Ast $Ast.SubExpression -AllowedCommands $AllowedCommands -Config $Config }
        'StringConstantExpressionAst' { return $true }
        'ExpandableStringExpressionAst' {
            foreach ($nest in $Ast.NestedExpressions) {
                if (-not (Test-SafeAst -Ast $nest -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'VariableExpressionAst' { return $true }
        'ConstantExpressionAst' { return $true }
        'TypeExpressionAst'     { return $true }
        'MemberExpressionAst' {
            return Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config
        }
        'InvokeMemberExpressionAst' {
            $methodName = $null
            if ($Ast.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $methodName = $Ast.Member.Value
            }
            if (-not $methodName) { return $false }
            $allowSet = $null
            if ($Config -and (Get-Member -InputObject $Config -Name '_dotnetMethodAllowlist' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $allowSet = $Config._dotnetMethodAllowlist
            }
            if (-not $allowSet -or -not $allowSet.Contains($methodName)) { return $false }
            if (-not (Test-SafeAst -Ast $Ast.Expression -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            foreach ($arg in $Ast.Arguments) {
                if (-not (Test-SafeAst -Ast $arg -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'IndexExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Target -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Index -AllowedCommands $AllowedCommands -Config $Config)
        }
        'BinaryExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Left -AllowedCommands $AllowedCommands -Config $Config) -and
                   (Test-SafeAst -Ast $Ast.Right -AllowedCommands $AllowedCommands -Config $Config)
        }
        'UnaryExpressionAst' {
            return Test-SafeAst -Ast $Ast.Child -AllowedCommands $AllowedCommands -Config $Config
        }
        'CommandAst' {
            return ($null -ne $AllowedCommands) -and $AllowedCommands.Contains($Ast.Extent.Text.Trim())
        }
        'ScriptBlockAst' {
            $blocks = @($Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) | Where-Object { $_ }
            foreach ($b in $blocks) {
                if (-not (Test-SafeAst -Ast $b -AllowedCommands $AllowedCommands -Config $Config)) { return $false }
            }
            return $true
        }
        'ScriptBlockExpressionAst' {
            return Test-SafeAst -Ast $Ast.ScriptBlock -AllowedCommands $AllowedCommands -Config $Config
        }
        default {
            return $false
        }
    }
}

# =============================================================================
# Get-PowerShellSafeExpressions
#
# When a powershell-domain command string contains no cmdlet invocations but
# only safe expressions, return one synthetic '(safe expression)' command per
# input so the classifier can allow it instead of falling back to regex
# splitting. Returns @() if ANY top-level statement is unsafe.
# =============================================================================

function Get-PowerShellSafeExpressions {
    param(
        [string]$Command,
        [PSCustomObject]$Config = $null
    )

    $results = @()
    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $results }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $results }
    if ($errors -and $errors.Count -gt 0) { return $results }
    if (-not $ast -or -not $ast.EndBlock) { return $results }

    $statements = $ast.EndBlock.Statements
    if ($statements.Count -eq 0) { return $results }

    $emptySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($stmt in $statements) {
        if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $emptySet -Config $Config)) {
            return @()   # any unsafe statement -> no fallback, regex path stays
        }
    }

    $results += [PSCustomObject]@{
        CommandText   = '(safe expression)'
        Domain        = 'powershell'
        IsPipeline    = $false
        ParentCommand = $null
    }
    return $results
}
```

- [ ] **Step 2: Add the marker early-allow in `src/Resolver.ps1`**

In `Resolve-Command`, immediately before `Step 0: Normalize domain name`, add:

```powershell
    # -------------------------------------------------
    # Safe-expression synthetic marker from Parser.ps1
    # -------------------------------------------------
    if ($Command -eq '(safe expression)') {
        return New-ResolutionResult -Decision "allow" -Reason "safe expression" -MatchedPattern $null -Risk "none"
    }
```

- [ ] **Step 3: Integrate the zero-command fallback in `src/Classifier.ps1`**

Find the block:

```powershell
    $astCommands = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
    }
```

Replace with:

```powershell
    $astCommands = @()
    $safeExpressions = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
        # Zero cmdlet invocations but a successful parse: the line may be pure
        # safe expressions (assignments, hashtables, .NET reads). Certify it so
        # we don't fall back to regex splitting.
        if ($astCommands.Count -eq 0) {
            $safeExpressions = @(Get-PowerShellSafeExpressions -Command $command -Config $Config)
        }
    }
```

In the aggregation block, change the first branch to prefer AST, then safe expressions:

```powershell
    if ($astCommands.Count -gt 0) {
        $allCommands = $astCommands
    }
    elseif ($safeExpressions.Count -gt 0) {
        $allCommands = $safeExpressions
    }
    elseif ($nestedCommands.Count -gt 0) {
```

(leave the rest of the block unchanged)

- [ ] **Step 4: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml" -Filter "PS-Safe-Expressions"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: no new-samples regressions; `test-cases.xml` matches BASELINE exactly. (Most canonical cases still fail — they need the arbiter in Task 7.)

- [ ] **Step 5: Commit**

```bash
git add src/Parser.ps1 src/Classifier.ps1 src/Resolver.ps1
git commit -m "feat(parser): hardened Test-SafeAst + zero-command safe-expression fallback" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: String-constant heuristic fix

**Files:**
- Modify: `src/Parser.ps1` (`Get-AstCommands`, section 4 `StringConstantExpressionAst` loop)

- [ ] **Step 1: Replace the heuristic**

Find:

```powershell
        $isCommandLike = $false
        if ($strValue -and $strValue.Trim()) {
            # Must have at least one space-separated word pair AND contain a
            # shell metacharacter (;, |, &, newline) OR start with a known
            # binary prefix — otherwise it's probably prose / a path.
            if ($strValue.Trim() -match '[;&|]' -or $strValue.Trim() -match "`n") {
                if ($strValue.Trim() -match '\S\s+\S') {
                    $isCommandLike = $true
                }
            }
            elseif ($strValue.Trim() -match '^(aws|docker|kubectl|helm|terraform|git|npm|yarn|python|node|pwsh|powershell|bash|sh|cmd|ssh|scp|make|go|cargo|dotnet|java|perl|ruby|php)\s') {
                $isCommandLike = $true
            }
        }
```

Replace with:

```powershell
        $isCommandLike = $false
        if ($strValue -and $strValue.Trim()) {
            $trimmedStr = $strValue.Trim()
            # Only treat a string constant as a command-like literal if it is a
            # top-level statement (its CommandExpressionAst parent is a direct
            # child of the pipeline or named block) AND has a separator/newline
            # AND a word pair; or if it starts with a known command prefix.
            # Strings that are cmdlet/operator arguments (e.g., -Pattern 'a|b',
            # -replace 'x|y') must NOT be extracted as standalone commands.
            $parentType = if ($str.Parent) { $str.Parent.GetType().Name } else { '' }
            $grandParentType = if ($str.Parent -and $str.Parent.Parent) { $str.Parent.Parent.GetType().Name } else { '' }
            $isTopLevel = ($parentType -eq 'CommandExpressionAst' -and $grandParentType -in @('PipelineAst', 'NamedBlockAst'))
            if ($isTopLevel -and ($trimmedStr -match '[;&|]' -or $trimmedStr -match "`n") -and ($trimmedStr -match '\S\s+\S')) {
                $isCommandLike = $true
            }
            elseif ($trimmedStr -match '^(aws|docker|kubectl|helm|terraform|git|npm|yarn|python|node|pwsh|powershell|bash|sh|cmd|ssh|scp|make|go|cargo|dotnet|java|perl|ruby|php)\s') {
                $isCommandLike = $true
            }
        }
```

- [ ] **Step 2: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: the two `Select-String` regex new-samples cases now **pass**; `test-cases.xml` matches BASELINE exactly.

- [ ] **Step 3: Commit**

```bash
git add src/Parser.ps1
git commit -m "fix(parser): stop extracting quoted regex strings as commands" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Call-operator `& { ... }` handling

**Files:**
- Modify: `src/Parser.ps1` (`Get-AstCommands` CommandAst loop; `Get-AstWrapperInnerCommands`)

- [ ] **Step 1: Add caller-side skip in `Get-AstCommands`**

In the `foreach ($cmd in $commandAsts)` loop, immediately after `$commandName` is computed and BEFORE the wrapper-detection `if`, add:

```powershell
        # --------------------------------------------
        # Call operator: & { <scriptblock> } or . { <scriptblock> }
        # The invocation itself is not a command to classify; the inner
        # commands are already found by the ScriptBlockAst recursion below.
        # --------------------------------------------
        if (($cmd.InvocationOperator -eq 'Ampersand' -or $cmd.InvocationOperator -eq 'Dot') -and
            $commandElements.Count -eq 1 -and
            $commandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            continue
        }
```

- [ ] **Step 2: Add the safety net in `Get-AstWrapperInnerCommands`**

Immediately after the `$commandElements.Count -lt 2` guard, add:

```powershell
    # Safety net: any CommandAst whose first element is a scriptblock literal
    # (e.g., "& { ... } arg1") is an invocation of that scriptblock — surface
    # the body as an inner PowerShell command.
    if ($commandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $sbExpr = $commandElements[0]
        if ($sbExpr.ScriptBlock -and $sbExpr.ScriptBlock.EndBlock) {
            $innerCommand = $sbExpr.ScriptBlock.EndBlock.Extent.Text
            if ($innerCommand) {
                $null = $results.Add([PSCustomObject]@{
                    CommandText = $innerCommand
                    Domain      = 'powershell'
                    IsPipeline  = $false
                })
            }
        }
        return $results.ToArray()
    }
```

- [ ] **Step 3: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: `test-cases.xml` matches BASELINE exactly. (The new-samples `& { ... }` case still fails here — the line routes to `linux`; the arbiter in Task 7 resolves it.)

- [ ] **Step 4: Commit**

```bash
git add src/Parser.ps1
git commit -m "feat(parser): handle call-operator & { scriptblock } extraction" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Resolver Step 0e — `aws --version` ≥2-token guard

**Files:**
- Modify: `src/Resolver.ps1` (Step 0e, end of the AWS flag-stripping block)

- [ ] **Step 1: Apply the guard**

Find:

```powershell
        $awsNormalized = ($awsFiltered -join ' ').Trim()
        if ($awsNormalized -ne $Command.Trim()) {
            return Resolve-Command -Command $awsNormalized -Domain $Domain -Config $Config
        }
```

Replace with:

```powershell
        $awsNormalized = ($awsFiltered -join ' ').Trim()
        # Guard: stripping must leave at least a service + operation (2+ tokens).
        # If it would leave bare "aws" (e.g., "aws --version"), keep the original
        # command so explicit read_only entries like "aws --version" can match.
        if ($awsNormalized -ne $Command.Trim() -and ($awsNormalized -split '\s+').Count -ge 2) {
            return Resolve-Command -Command $awsNormalized -Domain $Domain -Config $Config
        }
```

- [ ] **Step 2: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.adhoc.xml"
```

Expected: both match BASELINE exactly. Verify manually that `aws --version` now allows:

```powershell
pwsh -NoProfile -Command ". src/ConfigLoader.ps1; . src/Parser.ps1; . src/Resolver.ps1; \$c = Load-Config config.json; (Resolve-Command -Command 'aws --version' -Domain 'aws_cli' -Config \$c).Decision"
```

Expected output: `allow`

- [ ] **Step 3: Commit**

```bash
git add src/Resolver.ps1
git commit -m "fix(resolver): keep bare aws when flag-strip leaves no service (aws --version)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: The arbiter gate

**Files:**
- Modify: `src/Classifier.ps1` (add `Invoke-PowerShellArbitration`, `Resolve-AsArbiter`, and the activation gate in `Invoke-Classify`)

- [ ] **Step 1: Add the arbiter functions to `src/Classifier.ps1`**

Append after `Invoke-Classify`:

```powershell
# =============================================================================
# Invoke-PowerShellArbitration  (AST-as-arbiter)
#
# Activated ONLY when the primary pipeline's final decision is ask AND every
# blocking sub-result is the unknown-command fallback (MatchedPattern = null).
# Re-parses the whole original line with the PowerShell AST and returns
# CONCLUSIVE-ALLOW only when every top-level statement is fully accounted for:
#   - every CommandAst resolves to a KNOWN allow (directly, or as a wrapper
#     whose extracted inner commands all allow), and
#   - every remaining node passes Test-SafeAst with those allowed commands.
# Any gap => NOT conclusive => caller keeps the original ask unchanged.
# =============================================================================

function Invoke-PowerShellArbitration {
    param(
        [string]$Command,
        [PSCustomObject]$Config
    )

    $result = [PSCustomObject]@{ Conclusive = $false }

    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $result }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $result }
    if ($errors -and $errors.Count -gt 0) { return $result }
    if (-not $ast -or -not $ast.EndBlock) { return $result }
    if ($ast.BeginBlock -and $ast.BeginBlock.Statements.Count -gt 0) { return $result }
    if ($ast.ProcessBlock -and $ast.ProcessBlock.Statements.Count -gt 0) { return $result }

    $statements = $ast.EndBlock.Statements
    if ($statements.Count -eq 0) { return $result }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Pass 1: every embedded command must resolve ALLOW.
    foreach ($stmt in $statements) {
        $cmdAsts = $stmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmdAsts) {
            $verdict = Resolve-AsArbiter -CommandAst $c -Config $Config -Depth 0
            if ($verdict -ne 'ALLOW') { return $result }
            [void]$allowed.Add($c.Extent.Text.Trim())
        }
    }

    # Pass 2: every statement must certify as a safe expression (commands in
    # $allowed are treated as pre-approved leaves).
    foreach ($stmt in $statements) {
        if (-not (Test-SafeAst -Ast $stmt -AllowedCommands $allowed -Config $Config)) { return $result }
    }

    $result.Conclusive = $true
    return $result
}

function Resolve-AsArbiter {
    param(
        $CommandAst,
        [PSCustomObject]$Config,
        [int]$Depth
    )

    if ($Depth -gt 5) { return 'NO' }

    # Call-operator scriptblock: recurse into the scriptblock body.
    if (($CommandAst.InvocationOperator -eq 'Ampersand' -or $CommandAst.InvocationOperator -eq 'Dot') -and
        $CommandAst.CommandElements.Count -eq 1 -and
        $CommandAst.CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $sb = $CommandAst.CommandElements[0].ScriptBlock
        if (-not $sb -or -not $sb.EndBlock) { return 'NO' }
        $innerAllowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($istmt in $sb.EndBlock.Statements) {
            $icmds = $istmt.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($ic in $icmds) {
                if ((Resolve-AsArbiter -CommandAst $ic -Config $Config -Depth ($Depth + 1)) -ne 'ALLOW') { return 'NO' }
                [void]$innerAllowed.Add($ic.Extent.Text.Trim())
            }
        }
        foreach ($istmt in $sb.EndBlock.Statements) {
            if (-not (Test-SafeAst -Ast $istmt -AllowedCommands $innerAllowed -Config $Config)) { return 'NO' }
        }
        return 'ALLOW'
    }

    $text = $CommandAst.Extent.Text.Trim()
    if (-not $text) { return 'NO' }
    $dom = Get-CommandDomain -Command $text
    $r = Resolve-Command -Command $text -Domain $dom -Config $Config
    if ($r.Decision -eq 'allow') { return 'ALLOW' }

    # Wrapper / nested extraction: a wrapper is explained by its inner commands.
    $nested = @()
    $nested += @(Find-NestedCommands -Command $text -ParentDomain $dom)
    $cmdName = ''
    if ($CommandAst.CommandElements.Count -gt 0) { $cmdName = $CommandAst.CommandElements[0].Extent.Text }
    if ($cmdName) {
        $nested += @(Get-AstWrapperInnerCommands -CommandAst $CommandAst -CommandText $text -CommandName $cmdName)
    }
    if ($nested.Count -eq 0) { return 'NO' }

    foreach ($n in $nested) {
        $nr = Resolve-Command -Command $n.CommandText -Domain $n.Domain -Config $Config
        if ($nr.Decision -eq 'allow') { continue }
        # Try finer decomposition of the nested text.
        $leaves = @(Split-Commands -Command $n.CommandText -Domain $n.Domain)
        $leafOk = $true
        foreach ($leaf in $leaves) {
            $lr = Resolve-Command -Command $leaf.CommandText -Domain $leaf.Domain -Config $Config
            if ($lr.Decision -ne 'allow') { $leafOk = $false; break }
        }
        if (-not $leafOk) { return 'NO' }
    }
    return 'ALLOW'
}
```

- [ ] **Step 2: Add the activation gate in `Invoke-Classify`**

Find the aggregation block that starts with `if ($blockingCommands.Count -gt 0) {`. Insert immediately after that opening brace (before the reason-building code):

```powershell
        # -------------------------------------------------
        # AST-as-arbiter gate: only when EVERY blocker is the unknown-command
        # fallback. Known modifying matches and redirection blocks (both have
        # a MatchedPattern) bypass arbitration entirely.
        # -------------------------------------------------
        $knownBlockers = @($blockingCommands | Where-Object { $_.MatchedPattern })
        if ($knownBlockers.Count -eq 0) {
            $arbiterResult = Invoke-PowerShellArbitration -Command $command -Config $Config
            if ($arbiterResult.Conclusive) {
                return (Repair-ResultProperties ([PSCustomObject]@{
                    Decision    = "allow"
                    Reason      = "read-only (PowerShell AST arbitration)"
                    ExitCode    = 0
                    IDE         = $IDE
                    ToolName    = $toolName
                    Command     = $command
                    SubResults  = $subResults.ToArray()
                    IsSkipped   = $false
                    IsUnknown   = $false
                }))
            }
        }
```

- [ ] **Step 3: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.adhoc.xml"
```

Expected: **new-samples 14/14 pass** (the git tag case stays `ask` because `git tag -a` resolves unknown ⇒ arbiter inconclusive); `test-cases.xml` and `test-cases.adhoc.xml` match BASELINE exactly.

If any canonical case still fails, diagnose per the spec's §4.5 traceability matrix before proceeding. If any baseline suite diffs, STOP — that is a bug in the gate.

- [ ] **Step 4: Commit**

```bash
git add src/Classifier.ps1
git commit -m "feat(classifier): AST-as-arbiter fallback for unknown-command lines" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Arbiter-guard negative tests + adhoc merge

**Files:**
- Modify: `test/test-cases.adhoc.xml`

- [ ] **Step 1: Add the `AST-Arbiter-Guard` group**

Insert before the closing `</commands>` tag in `test/test-cases.adhoc.xml`:

```xml
  <category-group name="AST-Arbiter-Guard">

    <test-case expected="ask" reason="git" category="AST-Arbiter-Guard">
      <description>Unknown git subcommand stays ask (arbiter inconclusive)</description>
      <copilot-command><![CDATA[git --online -3]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>Unknown cmdlet stays ask</description>
      <copilot-command><![CDATA[Some-UnknownCmdlet -Foo]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>One unknown element poisons a pipeline</description>
      <copilot-command><![CDATA[weirdcmd -x | Get-Process]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Expression" category="AST-Arbiter-Guard">
      <description>Command inside an assignment is never a safe expression</description>
      <copilot-command><![CDATA[$x = Invoke-Expression 'evil']]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>Bash for-loop with unknown command: PS parse error, arbiter aborts</description>
      <copilot-command><![CDATA[for f in /etc/*; do weirdcmd $f; done]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>.NET Delete is not in the method allowlist</description>
      <copilot-command><![CDATA[$x = [System.IO.File]::Delete('c:\temp\x.txt')]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>Instance method Kill is not in the method allowlist</description>
      <copilot-command><![CDATA[$proc.Kill()]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="unknown command" category="AST-Arbiter-Guard">
      <description>Property SET on a type is a side effect</description>
      <copilot-command><![CDATA[[Console]::Title = 'x']]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="redirection-target" category="AST-Arbiter-Guard">
      <description>Redirect outside CWD/editable blocks; redirect blockers bypass the arbiter</description>
      <copilot-command><![CDATA[echo hi > ..\outside\file.txt]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="rm" category="AST-Arbiter-Guard">
      <description>Known-modifying inner command: arbiter never runs</description>
      <copilot-command><![CDATA[ssh user@host 'rm -rf /tmp/x']]></copilot-command>
    </test-case>

  </category-group>
```

Also merge the 14 canonical cases (from `test/test-cases.new-samples.xml`, groups `PS-Safe-Expressions` and `New-Samples-Regex-Confusion`) into `test/test-cases.adhoc.xml` before the `AST-Arbiter-Guard` group, keeping their CDATA verbatim.

- [ ] **Step 2: Run tests**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.adhoc.xml"
```

Expected: all adhoc cases pass, including the 14 canonical cases and the 10 guard cases.

- [ ] **Step 3: Commit**

```bash
git add test/test-cases.adhoc.xml
git commit -m "test: merge canonical cases + AST-arbiter guard tests into adhoc" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: Full differential verification

**Files:** none modified

- [ ] **Step 1: Re-run the complete suite matrix and compare against BASELINE**

```powershell
cd ~/.config/superpowers/worktrees/pretoolhook/ast-arbiter
foreach ($f in @('test-cases.xml','test-cases.adhoc.xml','test-cases.redirect-normal.xml','test-cases.redirect-strict.xml','test-cases.var-assignment.xml','test-cases.fullpath.xml','test-cases.trustedpattern.xml','test-cases.new-samples.xml')) {
  Write-Host "=== $f ==="
  pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/$f" 2>&1 | Select-String -Pattern '^(Total|Passed|Failed):'
}
pwsh -NoProfile -File test/FullPipeTestRunner.ps1 2>&1 | Select-String -Pattern '^(Total|Passed|Failed):'
```

Expected:
- Every pre-existing suite: **byte-identical Total/Passed/Failed to BASELINE**.
- `test-cases.adhoc.xml`: grew by exactly +24 tests (14 canonical + 10 guard), all passing.
- `test-cases.new-samples.xml`: **14/14**.
- FullPipe: matches BASELINE.

Any other diff = STOP, it is a bug, not a judgment call.

- [ ] **Step 2: Commit the verification note**

Append final numbers to `PROGRESS.md` under `## Final verification`, then:

```bash
git add PROGRESS.md
git commit -m "test: full differential verification vs baseline" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: Finalize documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md`

- [ ] **Step 1: Mark the spec Approved**

Change `**Status:** Draft — pending user review` to `**Status:** Approved — implemented`.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md
git commit -m "docs: mark AST-as-arbiter spec approved" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

### Spec coverage

| Spec section | Task |
|---|---|
| §3.0 arbiter gate + Resolve-AsArbiter | Task 7 |
| §3.0.2 Test-SafeAst (hardened, shared) | Task 3 |
| §3.1 string-constant heuristic | Task 4 |
| §3.2 call-operator | Task 5 |
| §3.3 zero-command safe-expression fallback | Task 3 |
| §3.4 Step 0e aws --version guard | Task 6 |
| §3.5 aws configure config | Task 2 |
| §3.6 safe_expressions config | Task 2 |
| §4.3 guard tests + §6.1 adhoc merge | Task 8 |
| §4.4 differential acceptance | Tasks 1, 9 |
| §1.3 base branch requirement | Task 1 |

### Placeholder scan
No TBD/TODO. All code steps contain complete code; all test steps contain exact commands and expected results.

### Type consistency
- `Test-SafeAst -Ast -AllowedCommands -Config` used identically in Parser (`Get-PowerShellSafeExpressions`, empty set) and Classifier (`Invoke-PowerShellArbitration`, populated set).
- `Config._dotnetMethodAllowlist` is a `HashSet[string]` (OrdinalIgnoreCase) built in ConfigLoader; consumed with `.Contains($methodName)` in Test-SafeAst.
- `Invoke-PowerShellArbitration` returns `[PSCustomObject]@{ Conclusive }`; the gate checks `.Conclusive` only.
- Synthetic marker `'(safe expression)'` is produced in Parser and matched verbatim in Resolver.
