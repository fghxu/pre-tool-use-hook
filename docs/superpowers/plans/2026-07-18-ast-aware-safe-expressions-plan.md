# AST-Aware Safe PowerShell Expression Handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix PowerShell parsing misclassifications where quoted regex strings, pure expressions, call-operator scriptblocks, and AWS bare verbs are wrongly reported as unknown commands.

**Architecture:** Tighten the PowerShell AST string-constant heuristic so parameter values are not extracted as fake commands, add handling for the `& { ... }` call-operator scriptblock, add a safe-expression fallback for pure PowerShell expressions, and add explicit AWS configure read-only entries. All changes are additive; the existing regex fallback remains for parse failures.

**Tech Stack:** PowerShell 7, `System.Management.Automation.Language.Parser`, XML test cases, custom `TestRunner.ps1`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/Parser.ps1` | PowerShell AST parsing, command extraction, string-constant heuristic, safe-expression detection, call-operator handling. |
| `src/Classifier.ps1` | Orchestrates parsing results; decides when to use AST commands, safe expressions, or regex fallback. |
| `src/Resolver.ps1` | Classifies individual sub-commands; needs a trivial allow path for synthetic safe-expression markers. |
| `config.json` | Runtime command configuration; add `aws configure get` / `aws configure list` read-only entries. |
| `test/test-cases.adhoc.xml` | Regression test cases for safe expressions and AWS configure. |
| `test/test-cases.new-samples.xml` | Temporary empirical test file (already created). Cases will be merged into `test-cases.adhoc.xml`. |

---

## Task 1: Reproduce current failures with the empirical test file

**Files:**
- Read: `test/test-cases.new-samples.xml` (already exists)
- Run: `src/TestRunner.ps1`

- [ ] **Step 1: Run the new-samples test file to confirm failures**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
```

Expected: 6 failures, 1 pass (the git tag case).

- [ ] **Step 2: Commit the empirical test file**

```bash
git add test/test-cases.new-samples.xml
git commit -m "test: add empirical regression cases for PS safe expressions"
```

---

## Task 2: Add `aws configure get` / `aws configure list` read-only entries

**Files:**
- Modify: `config.json:627-653` (AWS_CLI read_only array)
- Test: `test/test-cases.new-samples.xml`

- [ ] **Step 1: Add AWS configure read-only entries**

Insert after the existing `aws sso login` entry (around line 655) in `config.json`:

```json
        { "name": "aws configure get",       "patterns": ["^aws\\s+configure\\s+get\\b"],       "description": "Read an AWS configure value" },
        { "name": "aws configure list",      "patterns": ["^aws\\s+configure\\s+list\\b"],      "description": "List AWS configure values" },
```

- [ ] **Step 2: Run the new-samples test file**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
```

Expected: The `aws configure get sso_role_name` case now passes. 5 failures remain.

- [ ] **Step 3: Commit**

```bash
git add config.json
git commit -m "config: add aws configure get/list as read-only"
```

---

## Task 3: Tighten string-constant extraction heuristic in `Parser.ps1`

**Files:**
- Modify: `src/Parser.ps1:1507-1559` (`StringConstantExpressionAst` loop in `Get-AstCommands`)
- Test: `test/test-cases.new-samples.xml`

- [ ] **Step 1: Replace the string-constant heuristic**

Current code in `Get-AstCommands` section 4:

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
            # top-level statement (parent is the pipeline or named block) or if
            # it starts with a known command prefix. Strings that are arguments
            # to cmdlets/operators (e.g., -Pattern 'a|b', -replace 'x|y') must
            # NOT be extracted as standalone commands.
            $parentType = if ($str.Parent) { $str.Parent.GetType().Name } else { '' }
            $isTopLevel = $parentType -in @('PipelineAst', 'NamedBlockAst')
            if ($isTopLevel -and ($trimmedStr -match '[;&|]' -or $trimmedStr -match "`n" -or $trimmedStr -match '\S\s+\S')) {
                $isCommandLike = $true
            }
            elseif ($trimmedStr -match '^(aws|docker|kubectl|helm|terraform|git|npm|yarn|python|node|pwsh|powershell|bash|sh|cmd|ssh|scp|make|go|cargo|dotnet|java|perl|ruby|php)\s') {
                $isCommandLike = $true
            }
        }
```

- [ ] **Step 2: Run the new-samples test file**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
```

Expected: The two `Select-String` regex cases and the `-replace` regex case now pass. 2 failures remain (call operator and pure .NET expression).

- [ ] **Step 3: Run full regression suite**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: All existing tests still pass. If any fail, investigate before committing.

- [ ] **Step 4: Commit**

```bash
git add src/Parser.ps1
git commit -m "fix(parser): stop extracting quoted regex strings as commands"
```

---

## Task 4: Add call-operator `& { ... }` handling

**Files:**
- Modify: `src/Parser.ps1:1579-1827` (`Get-AstWrapperInnerCommands`)
- Test: `test/test-cases.new-samples.xml`

- [ ] **Step 1: Detect call-operator scriptblock in `Get-AstWrapperInnerCommands`**

At the top of `Get-AstWrapperInnerCommands`, after collecting `$commandElements` and checking `$elementCount -lt 2`, add:

```powershell
    # =========================================================================
    # Call operator: & { <scriptblock> }
    # In the AST this is a CommandAst whose only element is a
    # ScriptBlockExpressionAst. We extract and classify the scriptblock body.
    # =========================================================================
    if ($CommandName -eq '&' -and $elementCount -eq 1) {
        $sbExpr = $commandElements[0]
        if ($sbExpr -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            $sbExpr.ScriptBlock -and $sbExpr.ScriptBlock.EndBlock) {
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

Note: In the AST the call operator `&` may appear as the command name with the literal string `'&'`. If it does not, also handle the case where the `CommandAst`'s first element is a `ScriptBlockExpressionAst` directly (add the same check before the existing wrapper checks).

- [ ] **Step 2: Run the new-samples test file**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
```

Expected: The `& { ... }` call-operator case now passes. 1 failure remains (pure .NET expression).

- [ ] **Step 3: Run full regression suite**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: All existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add src/Parser.ps1
git commit -m "feat(parser): handle call-operator & { scriptblock } extraction"
```

---

## Task 5: Add safe-expression fallback

**Files:**
- Modify: `src/Parser.ps1` (add helpers)
- Modify: `src/Classifier.ps1:308-346` (command aggregation)
- Modify: `src/Resolver.ps1:96-110` (early allow for safe-expression marker)
- Test: `test/test-cases.new-samples.xml`

- [ ] **Step 1: Add safe-expression helpers to `Parser.ps1`**

Append to `Parser.ps1` after `Get-AstWrapperInnerCommands`:

```powershell
# =============================================================================
# Get-PowerShellSafeExpressions
#
# When a PowerShell command string contains no cmdlet invocations but only safe
# expressions (assignments, hashtables, array literals, .NET method calls,
# member expressions, binary expressions on safe operands, etc.), this helper
# returns synthetic command objects so the classifier can treat the whole line
# as read-only instead of falling back to regex splitting.
#
# Returns: [PSCustomObject[]] with: CommandText, Domain, IsPipeline, ParentCommand
# =============================================================================

function Get-PowerShellSafeExpressions {
    param(
        [string]$Command
    )

    $results = New-Object System.Collections.ArrayList

    $astType = 'System.Management.Automation.Language.Parser' -as [type]
    if (-not $astType) { return $results.ToArray() }

    $tokens = $null
    $errors = $null
    try {
        $ast = $astType::ParseInput($Command, [ref]$tokens, [ref]$errors)
    }
    catch { return $results.ToArray() }

    if ($errors -and $errors.Count -gt 0) { return $results.ToArray() }
    if (-not $ast) { return $results.ToArray() }

    # Walk top-level statements in the scriptblock's end block
    $statements = @()
    if ($ast.EndBlock) {
        $statements = $ast.EndBlock.Statements
    }

    foreach ($stmt in $statements) {
        if (Test-SafeAst -Ast $stmt) {
            $null = $results.Add([PSCustomObject]@{
                CommandText   = '(safe expression)'
                Domain        = 'powershell'
                IsPipeline    = $false
                ParentCommand = $null
            })
        }
    }

    return $results.ToArray()
}

# =============================================================================
# Test-SafeAst
#
# Recursively tests whether an AST node represents a pure, non-command
# expression. Safe nodes include assignments, hashtables, array literals,
# strings, variables, constants, type/member expressions, and binary/unary
# expressions whose operands are also safe.
#
# Anything containing a CommandAst is unsafe.
# =============================================================================

function Test-SafeAst {
    param($Ast)

    if ($null -eq $Ast) { return $true }

    $typeName = $Ast.GetType().Name

    switch ($typeName) {
        # Statements
        'AssignmentStatementAst' {
            return (Test-SafeAst -Ast $Ast.Left) -and (Test-SafeAst -Ast $Ast.Right)
        }
        'PipelineAst' {
            foreach ($elem in $Ast.PipelineElements) {
                if (-not (Test-SafeAst -Ast $elem)) { return $false }
            }
            return $true
        }

        # Expressions that are leaf-like or container-like
        'HashtableAst' {
            foreach ($kvp in $Ast.KeyValuePairs) {
                if (-not (Test-SafeAst -Ast $kvp.Item1) -or -not (Test-SafeAst -Ast $kvp.Item2)) {
                    return $false
                }
            }
            return $true
        }
        'ArrayLiteralAst' {
            foreach ($elem in $Ast.Elements) {
                if (-not (Test-SafeAst -Ast $elem)) { return $false }
            }
            return $true
        }
        'ParenExpressionAst' {
            return Test-SafeAst -Ast $Ast.Pipeline
        }
        'StringConstantExpressionAst' { return $true }
        'ExpandableStringExpressionAst' {
            foreach ($nest in $Ast.NestedExpressions) {
                if (-not (Test-SafeAst -Ast $nest)) { return $false }
            }
            return $true
        }
        'VariableExpressionAst' { return $true }
        'ConstantExpressionAst' { return $true }
        'TypeExpressionAst' { return $true }
        'AttributeAst' { return $true }
        'NamedAttributeArgumentAst' { return $true }

        # Member/invoke expressions
        'MemberExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Expression) -and (Test-SafeAst -Ast $Ast.Member)
        }
        'InvokeMemberExpressionAst' {
            if (-not (Test-SafeAst -Ast $Ast.Expression)) { return $false }
            foreach ($arg in $Ast.Arguments) {
                if (-not (Test-SafeAst -Ast $arg)) { return $false }
            }
            return $true
        }
        'IndexExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Target) -and (Test-SafeAst -Ast $Ast.Index)
        }
        'ArrayExpressionAst' {
            return Test-SafeAst -Ast $Ast.SubExpression
        }
        'SubExpressionAst' {
            return Test-SafeAst -Ast $Ast.SubExpression
        }
        'TypeConstraintAst' { return $true }
        'MergingRedirectionAst' { return $true }
        'ErrorExpressionAst' { return $false }

        # Binary / unary expressions
        'BinaryExpressionAst' {
            return (Test-SafeAst -Ast $Ast.Left) -and (Test-SafeAst -Ast $Ast.Right)
        }
        'UnaryExpressionAst' {
            return Test-SafeAst -Ast $Ast.Child
        }

        # Anything else: be conservative
        default {
            # If it's a command, definitely unsafe
            if ($Ast -is [System.Management.Automation.Language.CommandAst]) {
                return $false
            }
            # ScriptBlock and related constructs are unsafe unless handled separately
            if ($Ast -is [System.Management.Automation.Language.ScriptBlockAst]) {
                return $false
            }
            # Unknown node type: fail safe
            return $false
        }
    }
}
```

- [ ] **Step 2: Integrate safe expressions into `Classifier.ps1`**

Modify `Classifier.ps1` around lines 313-346. Current code:

```powershell
    $astCommands = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
    }
```

Change to:

```powershell
    $astCommands = @()
    $safeExpressions = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
        # If the AST parser found no cmdlet invocations, check for pure safe
        # expressions so we don't fall back to regex splitting of assignments,
        # hashtables, .NET method calls, etc.
        if ($astCommands.Count -eq 0) {
            $safeExpressions = @(Get-PowerShellSafeExpressions -Command $command)
        }
    }
```

Then update the aggregation block:

```powershell
    # Combine all commands to classify.
    # Prefer AST-extracted commands for PowerShell; fall back to regex split.
    if ($astCommands.Count -gt 0) {
        $allCommands = $astCommands
    }
    elseif ($safeExpressions.Count -gt 0) {
        $allCommands = $safeExpressions
    }
    elseif ($nestedCommands.Count -gt 0) {
        ...
```

Full replacement for that block:

```powershell
    # Combine all commands to classify.
    # Prefer AST-extracted commands for PowerShell; fall back to safe-expression
    # markers, then to regex split.
    if ($astCommands.Count -gt 0) {
        $allCommands = $astCommands
    }
    elseif ($safeExpressions.Count -gt 0) {
        $allCommands = $safeExpressions
    }
    elseif ($nestedCommands.Count -gt 0) {
        $parentTexts = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($nc in $nestedCommands) {
            if ($nc.ParentCommand) {
                [void]$parentTexts.Add($nc.ParentCommand)
            }
        }
        $filteredSubCommands = @($subCommands | Where-Object {
            -not $parentTexts.Contains($_.CommandText)
        })
        $allCommands = $filteredSubCommands + $nestedCommands + $subshellCommands
    }
    else {
        $allCommands = $subCommands + $nestedCommands + $subshellCommands
    }
```

- [ ] **Step 3: Add early allow for safe-expression marker in `Resolver.ps1`**

In `Resolve-Command`, immediately after the `New-ResolutionResult` helper and before Step 0 (domain lookup), add:

```powershell
    # -------------------------------------------------
    # Safe-expression synthetic marker from Parser.ps1
    # -------------------------------------------------
    if ($Command -eq '(safe expression)') {
        return New-ResolutionResult -Decision "allow" -Reason "safe expression" -MatchedPattern $null -Risk "none"
    }
```

- [ ] **Step 4: Run the new-samples test file**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.new-samples.xml"
```

Expected: All 7 tests pass.

- [ ] **Step 5: Run full regression suite**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
```

Expected: All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/Parser.ps1 src/Classifier.ps1 src/Resolver.ps1
git commit -m "feat(parser): add safe-expression fallback for pure PS expressions"
```

---

## Task 6: Merge regression tests into `test/test-cases.adhoc.xml`

**Files:**
- Modify: `test/test-cases.adhoc.xml`
- Delete: `test/test-cases.new-samples.xml` (optional; keep if you want a separate file)

- [ ] **Step 1: Add `PS-Safe-Expressions` and `AWS-Configure` groups to `test-cases.adhoc.xml`**

Insert before the closing `</commands>` tag:

```xml
  <category-group name="PS-Safe-Expressions">

    <test-case expected="allow" reason="read-only: hashtable assignment" category="PS-Safe-Expressions">
      <description>Hashtable assignment with typo key</description>
      <copilot-command><![CDATA[$headers = @{'provate-token' = $gittoken}]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: string split pipeline" category="PS-Safe-Expressions">
      <description>String split piped to Select-Object</description>
      <copilot-command><![CDATA[$log -split "`n" | Select-Object -First 40]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: GET rest call + read-only pipeline" category="PS-Safe-Expressions">
      <description>Invoke-RestMethod GET followed by regex filter pipeline</description>
      <copilot-command><![CDATA[Invoke-RestMethod -Method Get -Headers $hdr -Uri 'https://server/text'; ($b801log -split "`n" | Select-String -Pattern 'Error:|Exception out|failure|pass:' | Select-Object -First 20)]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: SSH remote read-only commands" category="PS-Safe-Expressions">
      <description>SSH with key and read-only remote commands</description>
      <copilot-command><![CDATA[$key='c:	emp	hepath	he.pem'; ssh -i $key -o StrictHostKeyChecking=accept-new -o BatchMode=yes user@server 'whoami;hostname']]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: aws version + Get-Content" category="PS-Safe-Expressions">
      <description>AWS version and Get-Content in same line</description>
      <copilot-command><![CDATA[aws --version; Get-Content $file]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: bare hashtable" category="PS-Safe-Expressions">
      <description>Bare hashtable expression</description>
      <copilot-command><![CDATA[@{ authorization = "Basice $encoded" }]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: JSON string assignment" category="PS-Safe-Expressions">
      <description>Malformed-ish JSON string assignment</description>
      <copilot-command><![CDATA[$body = '{"id": "1", "name": "2" "context":{"id": "1"} }']]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: array literal assignment" category="PS-Safe-Expressions">
      <description>Array literal assignment</description>
      <copilot-command><![CDATA[$arr = 1, 2, @(3, 4)]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: parenthesized expression" category="PS-Safe-Expressions">
      <description>Parenthesized binary expression</description>
      <copilot-command><![CDATA[($x + $y)]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: bare variable" category="PS-Safe-Expressions">
      <description>Bare variable reference</description>
      <copilot-command><![CDATA[$headers]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: Select-String regex with pipes" category="PS-Safe-Expressions">
      <description>Select-String regex containing pipes and brackets, piped to ForEach/Where</description>
      <copilot-command><![CDATA[Select-String -Path "$env:tempuild.log" -Pattern "server.*not ready|server is healthy" | ForEach-Object { $_.Line } | Where-Object { $_ -match "step|18:" -or $_ -notmatch "^
" }]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: Select-String simple regex" category="PS-Safe-Expressions">
      <description>Select-String simple regex with anchors and pipes</description>
      <copilot-command><![CDATA[Select-String -Pattern '^## | ^### ']]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: variable assignment with -replace regex" category="PS-Safe-Expressions">
      <description>Variable assignment using -replace with regex string and scriptblock</description>
      <copilot-command><![CDATA[$line = $line -replace 'deploy BC|Deploy BC|Summary \(BC\)', { $_.Value -replace 'BC', 'PC' -replace 'bc', 'pc' }]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: call operator scriptblock" category="PS-Safe-Expressions">
      <description>Call operator & with scriptblock containing Get-Content and ConvertFrom-Json</description>
      <copilot-command><![CDATA[& { $json = Get-Content -Path 'jenkinsuild.json' -Raw; $buildinfo = $json | ConvertFrom-Json; }]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: .NET file read + substring" category="PS-Safe-Expressions">
      <description>.NET file read and substring with Math::Max</description>
      <copilot-command><![CDATA[$raw = [System.IO.File]::ReadAllText("c:	hefile.txt"); $tail = $raw.Substring([Math]::Max(0, $raw.Length));]]></copilot-command>
    </test-case>

  </category-group>

  <category-group name="AWS-Configure">

    <test-case expected="allow" reason="read-only: aws configure get" category="AWS-Configure">
      <description>AWS configure get is a read-only lookup</description>
      <copilot-command><![CDATA[aws configure get sso_role_name]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only: aws configure list" category="AWS-Configure">
      <description>AWS configure list is read-only</description>
      <copilot-command><![CDATA[aws configure list]]></copilot-command>
    </test-case>

  </category-group>
```

Note: Replace `c:	emp	hepath	he.pem` and `c:	hefile.txt` with `c:	emp	hepath	he.pem` if you want to keep the original path style; adjust to valid ASCII with no Unicode. The important part is spaces in paths are preserved.

- [ ] **Step 2: Run the adhoc test file**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.adhoc.xml"
```

Expected: All new tests pass along with existing adhoc tests.

- [ ] **Step 3: Remove the temporary `test/test-cases.new-samples.xml` if desired**

```bash
git rm test/test-cases.new-samples.xml
```

- [ ] **Step 4: Commit**

```bash
git add test/test-cases.adhoc.xml
git commit -m "test: merge PS safe-expression and AWS configure regression cases"
```

---

## Task 7: Full regression verification

**Files:**
- All test XML files

- [ ] **Step 1: Run all available test suites**

```powershell
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.adhoc.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.redirect-normal.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.redirect-strict.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.var-assignment.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.fullpath.xml"
pwsh -NoProfile -File src/TestRunner.ps1 -XmlPath "test/test-cases.trustedpattern.xml"
```

Expected: All suites pass.

- [ ] **Step 2: Run full-pipe integration tests**

```powershell
pwsh -NoProfile -File test/FullPipeTestRunner.ps1
```

Expected: All full-pipe tests pass.

- [ ] **Step 3: Commit**

```bash
git commit -m "test: verify full regression suite passes"
```

---

## Task 8: Finalize documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md`
- Modify: `PROGRESS.md`

- [ ] **Step 1: Update spec status to Approved**

Change the spec header from:

```markdown
**Status:** Draft — pending user review
```

to:

```markdown
**Status:** Approved
```

- [ ] **Step 2: Update PROGRESS.md**

Replace contents with:

```markdown
## Goal
Fix PowerShell parsing misclassifications where quoted regex strings, pure expressions, call-operator scriptblocks, and AWS bare verbs are wrongly reported as unknown commands.

## Completed Steps
- Approved design spec at `docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md`.
- Implemented plan in `docs/superpowers/plans/2026-07-18-ast-aware-safe-expressions-plan.md`.

## Current Step
Implement the plan task-by-task.

## Next Steps
- Execute Task 1 through Task 8 from the implementation plan.
- Verify all regression suites pass.

## Blockers / Notes
- None yet.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-18-ast-aware-safe-expressions-design.md PROGRESS.md
git commit -m "docs: mark safe-expression spec approved and update progress"
```

---

## Self-Review

### Spec coverage

| Spec section | Implementing task |
|---|---|
| 3.1 Fix string-constant extraction heuristic | Task 3 |
| 3.2 Handle call-operator scriptblock | Task 4 |
| 3.3 Safe-expression fallback | Task 5 |
| 3.4 Classifier integration | Task 5 |
| 3.5 AWS configure get | Task 2 |
| 5 Test plan | Task 6 |

### Placeholder scan

- No TBD/TODO placeholders.
- All code steps include actual code.
- All test steps include exact commands and expected outcomes.
- File paths are exact.

### Type consistency

- `Get-PowerShellSafeExpressions` returns the same shape as `Get-PowerShellCommands`.
- Synthetic marker `'(safe expression)'` is matched in `Resolver.ps1`.
- `Test-SafeAst` handles the AST node types referenced in the spec.
