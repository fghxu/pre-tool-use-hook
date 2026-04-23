#!/usr/bin/env pwsh
<#
.SYNOPSIS
Test runner for pre-cli-hook.ps1

.DESCRIPTION
Reads test commands from test-commands.txt and verifies hook decisions
with detailed output and summary statistics.

Format: Y/N;Category;Command;Description
Y = Expected auto-approve, N = Expected manual approval

.EXAMPLE
pwsh test-runner.ps1

.EXAMPLE
pwsh test-runner.ps1 -Verbose (shows all test details)
#>

param(
    [switch]$Verbose
)

# Test state tracking
$TestResults = @{
    Total = 0
    Passed = 0
    Failed = 0
    ByCategory = @{}
}

# Test file path
$TestFile = Join-Path (Split-Path -Parent $PSCommandPath) "test-commands.txt"
$HookScript = Join-Path (Split-Path -Parent $PSCommandPath) "pre-cli-hook.ps1"

echo ""
echo "=========================================="
echo "  Pre-CLI Hook Test Runner"
echo "=========================================="
echo ""

function Parse-ExpectedDecision {
    param($ExpectedFlag)
    switch ($ExpectedFlag.Trim().ToUpper()) {
        "Y" { return "approve" }
        "N" { return "prompt" }
        default { return $null }
    }
}

function Run-HookTest {
    param($Command)
    try {
        # Call the hook script and capture output
        $output = & pwsh -Command "& '$HookScript' '$Command'" 2>&1
        $exitCode = $LASTEXITCODE

        # Parse JSON output if present
        $jsonMatch = $output | Select-String -Pattern '\{\"action\".*\"reason\".*\}'
        if ($jsonMatch) {
            $jsonStr = $jsonMatch.Matches[0].Value
            $result = $jsonStr | ConvertFrom-Json
            return @{
                Action = $result.action
                Reason = $result.reason
                ExitCode = $exitCode
                Output = $output
            }
        }
        # Fallback to exit code
        return @{
            Action = if ($exitCode -eq 0) { "approve" } else { "prompt" }
            Reason = "Exit code: $exitCode"
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

# Read and process test file
$lines = Get-Content $TestFile | Where-Object { $_ -and $_ -notmatch '^#' }
$lineNumber = 0

foreach ($line in $lines) {
    $lineNumber++

    # Parse test line: Expected;Category;Command;Description
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

    # Parse expected decision
    $expectedAction = Parse-ExpectedDecision $expectedFlag
    if (-not $expectedAction) {
        Write-Warning "Invalid expected flag at line ${lineNumber}: $expectedFlag"
        continue
    }

    # Run the test
    echo "-----------------------------------------------------------------"
    echo "Test #$lineNumber [$category]: $description"
    echo "Command: $command"
    echo ""

    $hookResult = Run-HookTest $command
    if (-not $hookResult) {
        Write-Error "Failed to run test $lineNumber"
        continue
    }

    # Compare results
    $actualAction = $hookResult.Action

    if ($actualAction -eq $expectedAction) {
        $TestResults.Passed++
        $TestResults.ByCategory[$category].Passed++
        echo "✅ PASS"
    } else {
        $TestResults.Failed++
        $TestResults.ByCategory[$category].Failed++
        echo "❌ FAIL"
    }

    echo "Expected: $expectedAction"
    echo "Actual: $actualAction"
    echo "Reason: $($hookResult.Reason)"

    if ($Verbose) {
        echo "Full output: $($hookResult.Output)"
    }
    echo ""
}

# Display final statistics
echo ""
echo "================================================================="
echo "                    TEST SUMMARY"
echo "================================================================="
echo "Total Tests: $($TestResults.Total)"
echo "✅ Passed: $($TestResults.Passed)"
echo "❌ Failed: $($TestResults.Failed)"
if ($TestResults.total -gt 0) {
    $rate = [math]::Round(($TestResults.Passed / $TestResults.Total * 100), 2)
    echo "Success Rate: $rate%"
}
echo ""

# Category breakdown
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
} else {
    echo "Some tests failed."
    exit 1
}
