#!/usr/bin/env pwsh
<#
.SYNOPSIS
Test runner for pre-cli-hook-copilot.ps1 (VS Code Copilot version)

.DESCRIPTION
Reads test commands from test-commands.txt and verifies hook decisions.
Sends commands via stdin as Copilot-formatted JSON:
  {"toolName":"bash","toolArgs":"{\"command\":\"ls -la\"}"}

Copilot API:
  - Approve: exit 0
  - Deny:   exit 1 + stdout {"status":"denied","reason":"..."}

Format: Y/N;Category;Command;Description
Y = Expected auto-approve, N = Expected manual approval
#>

param(
    [switch]$Verbose
)

$TestResults = @{
    Total = 0
    Passed = 0
    Failed = 0
    ByCategory = @{}
}

$TestFile = Join-Path (Split-Path -Parent $PSCommandPath) "test-commands.txt"
$HookScript = Join-Path (Split-Path -Parent $PSCommandPath) "pre-cli-hook-copilot.ps1"

echo ""
echo "=========================================="
echo " Copilot Hook Test Runner"
echo "=========================================="
echo ""

function Parse-ExpectedDecision {
    param($ExpectedFlag)
    switch ($ExpectedFlag.Trim().ToUpper()) {
        "Y" { return "approved" }
        "N" { return "denied" }
        default { return $null }
    }
}

function Run-HookTest {
    param($Command)

    try {
        # Build hook stdin JSON format (matches Copilot PreToolUse API)
        $toolInput = @{ command = $Command }
        $stdinJson = @{ tool_name = "run_in_terminal"; tool_input = $toolInput } | ConvertTo-Json -Compress

        # Write stdin to temp file, pipe it through Get-Content to the hook
        $tempStdin = [System.IO.Path]::GetTempFileName()
        $stdinJson | Set-Content -Path $tempStdin -Encoding UTF8

        $output = pwsh -Command "Get-Content '$tempStdin' | pwsh -File '$HookScript'" 2>&1
        $exitCode = $LASTEXITCODE

        Remove-Item $tempStdin -Force -ErrorAction SilentlyContinue

        # Parse hook output for permissionDecision
        # Hook outputs: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|ask","permissionDecisionReason":"..."}}
        $jsonMatch = $output | Select-String -Pattern 'permissionDecision["\s:]+([a-z]+)' -AllMatches
        if ($jsonMatch) {
            $decision = $jsonMatch.Matches[0].Groups[1].Value
            if ($decision -eq "allow") {
                return @{
                    Status = "approved"
                    Reason = "allow"
                    ExitCode = $exitCode
                    Output = $output
                }
            } elseif ($decision -eq "ask") {
                # Extract reason
                $reasonMatch = $output | Select-String -Pattern 'permissionDecisionReason["\s:]+([^"]+)"' -AllMatches
                $reason = if ($reasonMatch) { $reasonMatch.Matches[0].Groups[1].Value } else { "ask" }
                return @{
                    Status = "denied"
                    Reason = $reason
                    ExitCode = $exitCode
                    Output = $output
                }
            }
        }

        # Fallback: check exit code
        return @{
            Status = if ($exitCode -eq 0) { "approved" } else { "denied" }
            Reason = if ($exitCode -eq 0) { "Exit code: 0" } else { "Exit code: $exitCode" }
            ExitCode = $exitCode
            Output = $output
        }
    }
    catch {
        Write-Error "Failed to run hook test: $($_.Exception.Message)"
        return $null
    }
}

# ==================================================
# Main Test Execution
# ==================================================

if (-not (Test-Path $TestFile)) {
    Write-Error "Test file not found: $TestFile"
    exit 1
}

if (-not (Test-Path $HookScript)) {
    Write-Error "Hook script not found: $HookScript"
    exit 1
}

echo "Loading test file: $(Split-Path -Leaf $TestFile)"
echo "Hook script: $(Split-Path -Leaf $HookScript)"
echo ""

$lines = Get-Content $TestFile | Where-Object { $_ -and $_ -notmatch '^#' }
$lineNumber = 0

foreach ($line in $lines) {
    $lineNumber++

    $parts = $line -split ';'
    if ($parts.Count -lt 3) {
        Write-Warning "Invalid test line format at line ${lineNumber}: $line"
        continue
    }

    $expectedFlag = $parts[0]
    $category = $parts[1]
    $command = $parts[2]
    $description = if ($parts.Count -ge 4) { $parts[3] } else { "" }

    $TestResults.Total++

    if (-not $TestResults.ByCategory.ContainsKey($category)) {
        $TestResults.ByCategory[$category] = @{ Total = 0; Passed = 0; Failed = 0 }
    }
    $TestResults.ByCategory[$category].Total++

    $expectedStatus = Parse-ExpectedDecision $expectedFlag
    if (-not $expectedStatus) {
        Write-Warning "Invalid expected flag at line ${lineNumber}: $expectedFlag"
        continue
    }

    echo "-----------------------------------------------------------------"
    echo "Test #$lineNumber [$category]: $description"
    echo "Command: $command"
    echo ""

    $hookResult = Run-HookTest $command
    if (-not $hookResult) {
        Write-Error "Failed to run test $lineNumber"
        continue
    }

    $actualStatus = $hookResult.Status

    if ($actualStatus -eq $expectedStatus) {
        $TestResults.Passed++
        $TestResults.ByCategory[$category].Passed++
        echo "PASS"
    }
    else {
        $TestResults.Failed++
        $TestResults.ByCategory[$category].Failed++
        echo "FAIL"
    }

    echo "Expected: $expectedStatus"
    echo "Actual: $actualStatus"
    echo "Reason: $($hookResult.Reason)"

    if ($Verbose) {
        echo "Full output: $($hookResult.Output)"
    }
    echo ""
}

# Display final statistics
echo ""
echo "================================================================="
echo " TEST SUMMARY"
echo "================================================================="
echo "Total Tests: $($TestResults.Total)"
echo "Passed: $($TestResults.Passed)"
echo "Failed: $($TestResults.Failed)"
if ($TestResults.Total -gt 0) {
    $rate = [math]::Round(($TestResults.Passed / $TestResults.Total * 100), 2)
    echo "Success Rate: $rate%"
}
echo ""

if ($TestResults.ByCategory.Count -gt 0) {
    echo "Breakdown by Category:"
    echo "-----------------------------------------------------------------"
    $categories = $TestResults.ByCategory.Keys | Sort-Object
    foreach ($cat in $categories) {
        $total = $TestResults.ByCategory[$cat].Total
        $passed = $TestResults.ByCategory[$cat].Passed
        $failed = $TestResults.ByCategory[$cat].Failed
        $rate = [math]::Round(($passed / $total * 100), 1)
        echo "$cat`: total=$total, passed=$passed, failed=$failed, rate=$rate%"
    }
    echo ""
}

echo "================================================================="
echo ""

if ($TestResults.Failed -eq 0) {
    echo "All tests passed!"
    exit 0
}
else {
    echo "Some tests failed."
    exit 1
}
