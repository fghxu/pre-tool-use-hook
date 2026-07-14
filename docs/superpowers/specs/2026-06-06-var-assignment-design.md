# $var = <executable> Pattern Detection — Design Doc

Date: 2026-06-06

## Problem

Commands like `$creds = aws sts assume-role --role-arn "arn:something"` are classified as `unknown command` (ask). The `$var =` prefix causes domain detection to miss the actual executable, and variable assignment stripping only runs for the `powershell` domain — but the command is detected as `linux` because bare `$var` is not a PowerShell marker (it is valid bash syntax too).

## Solution

Three coordinated changes, all in existing files:

### 1. Domain Detection: `Get-CommandDomain` (Parser.ps1)

Add Step 0 — before all existing checks — that strips the first `$var =` from anywhere in the string and re-detects the domain from the remainder.

- Regex: `\$[\w:]+\s*=\s*` — matches `$identifier =` (no `^` anchor, handles mid-segment)
- Only the first occurrence is stripped; chained assignments (`$a = $b = cmd`) are handled by recursion
- Safe from false positives: comparison operators (`-eq`, `-ne`, `-like`) start with `-`, not `$`
- Re-detection is recursive: strip → trim → call `Get-CommandDomain` on remainder

### 2. Resolver Stripping: `Resolve-Command` Step 0b (Resolver.ps1)

Expand Step 0b from powershell-only to domain-agnostic.

- Any domain: if command matches `\$[\w:]+\s*=\s*`, strip the first `$var =` prefix
- After stripping, re-detect domain via `Get-CommandDomain`
- Recurse: `Resolve-Command strippedCmd newDomain Config`

### 3. Nested Contexts

No changes needed. `Find-NestedCommands` and `Get-AstWrapperInnerCommands` already extract inner commands and route them through the full pipeline. The fixes above apply automatically to:
- SSH wrappers: `ssh user@host "pwsh -Command '$creds = aws ...'"`
- PowerShell remoting: `Invoke-Command -ScriptBlock { $x = git ... }`
- bash -c: `bash -c '...'`
- Combined nesting: `pwsh -Command "ssh host '...'"`

Bash `var=$(aws sts ...)` subshells are already handled by `Split-SubshellCommands` (Parser.ps1). No change needed.

### Interaction with Existing Stripping

Step order in `Resolve-Command`:
1. Step 0b: `$var =` strip (domain-agnostic) — **NEW**
2. Step 0c: sudo strip (linux/dos) — existing
3. Step 0d: git option strip — existing
4. Step 0e: AWS flag strip — existing
5. Step 1a/1b: read_only/modifying pattern matching — existing

This order means `$creds = sudo git -C /path status` → strip `$creds = ` → `sudo git -C /path status` → sudo strip → `git -C /path status` → git strip → `git status` → read-only → allow.

## Test Plan

New file: `test/test-cases.var-assignment.xml` with 50+ test cases covering:

| Category | Count | Scenarios |
|----------|-------|-----------|
| Basic AWS | 6 | get-caller-identity, assume-role, describe-instances, terminate-instances, s3 ls, s3 rm |
| Basic Git | 5 | status, log, push, add, -C flag |
| Basic Docker | 3 | ps, stop, exec |
| Basic Kubernetes | 3 | get pods, delete pod, describe |
| Basic Terraform | 2 | plan, apply |
| Basic PowerShell | 4 | Get-ChildItem, Stop-Process, Get-Service, Remove-Item |
| Comparison (not stripped) | 3 | -eq, -ne inside if/while conditions |
| Chained assignments | 2 | $a = $b = cmd (recursive strip) |
| Mid-segment | 3 | After ; or && operator |
| Pipeline | 3 | $var = cmd1 | cmd2 mixed read-only/modifying |
| Multi-line | 3 | Multi-line scripts with mixed decisions |
| SSH nesting | 5 | ssh wrapping $var=, ssh nesting pwsh, SSH nesting bash subshell |
| PowerShell remoting | 4 | Invoke-Command, pwsh -Command, ForEach-Object -Parallel |
| Nested PowerShell+SSH | 3 | pwsh wrapping ssh, double nesting |
| Bash subshell via SSH | 3 | ssh host "var=$(cmd)" patterns |

## Files Changed

| File | Change |
|------|--------|
| `src/Parser.ps1` | `Get-CommandDomain`: add Step 0 `$var =` strip and re-detect |
| `src/Resolver.ps1` | `Resolve-Command` Step 0b: domain-agnostic `$var =` strip |
| `test/test-cases.var-assignment.xml` | New file: 50+ test cases |
