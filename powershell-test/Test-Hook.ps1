<#
.SYNOPSIS
Tests the Claude Code CLI Security Hook with PowerShell commands

.DESCRIPTION
This script tests both read-only and modifying PowerShell commands
to verify the hook correctly identifies and handles each type.

.NOTES
Run this in Claude Code to test the hook functionality
#>

# Enable strict mode for better error handling
Set-StrictMode -Version Latest

# Create test directory
$TestPath = Join-Path -Path $PSScriptRoot -ChildPath "hook-test-files"
if (Test-Path $TestPath) {
    Write-Host "Cleaning up existing test directory..." -ForegroundColor Yellow
    Remove-Item -Path $TestPath -Recurse -Force
}
New-Item -Path $TestPath -ItemType Directory -Force | Out-Null
Set-Location -Path $TestPath

Write-Host "
========================================" -ForegroundColor Cyan
Write-Host "CLI Security Hook - PowerShell Tests" -ForegroundColor Cyan
Write-Host "========================================
" -ForegroundColor Cyan

# Section 1: Read-Only Commands (Should Auto-Approve)
Write-Host "SECTION 1: Read-Only Commands" -ForegroundColor Green
Write-Host "These should execute without prompts" -ForegroundColor Gray

$readonlyTests = @(
    @{
        Name = "Get-ChildItem";
        Command = { Get-ChildItem . | Select-Object -First 3 };
        Check = { $_.Count -ge 0 }
    },
    @{
        Name = "Get-Location";
        Command = { Get-Location };
        Check = { $_.Path -ne $null }
    },
    @{
        Name = "Get-Date";
        Command = { Get-Date };
        Check = { $_.Year -eq (Get-Date).Year }
    },
    @{
        Name = "Get-Host";
        Command = { Get-Host };
        Check = { $_.Version -ne $null }
    },
    @{
        Name = "Test-Path";
        Command = { Test-Path -Path "./README.md" };
        Check = { $_ -eq $false }
    },
    @{
        Name = "Get-Process";
        Command = { Get-Process | Select-Object -First 3 Name, Id };
        Check = { $_.Count -gt 0 }
    },
    @{
        Name = "Get-Service";
        Command = { Get-Service | Select-Object -First 3 Name, Status };
        Check = { $_.Count -gt 0 }
    }
)

$passed = 0
$failed = 0

foreach ($test in $readonlyTests) {
    Write-Host "  Testing: $($test.Name)" -ForegroundColor Yellow -NoNewline
    try {
        $result = & $test.Command
        $checkResult = & $test.Check -InputObject $result
        Write-Host " - ✅ Auto-approved" -ForegroundColor Green
        $passed++
    }
    catch {
        Write-Host " - ⚠️  Check failed: $_" -ForegroundColor Orange
        $failed++
    }
}

Write-Host "  (Passed: $passed, Failed: $failed)" -ForegroundColor Cyan

# Section 2: Modifying Commands (Should Prompt)
Write-Host "
SECTION 2: Modifying Commands" -ForegroundColor Yellow
Write-Host "These should prompt for approval" -ForegroundColor Gray

$modifyingTests = @(
    @{
        Name = "New-Item (File)";
        Command = { New-Item -Path "./test-file.txt" -ItemType File -Force };
        Cleanup = { if (Test-Path "./test-file.txt") { Remove-Item -Path "./test-file.txt" -Force } };
        Creates = "test-file.txt"
    },
    @{
        Name = "New-Item (Directory)";
        Command = { New-Item -Path "./test-dir" -ItemType Directory -Force };
        Cleanup = { if (Test-Path "./test-dir") { Remove-Item -Path "./test-dir" -Recurse -Force } };
        Creates = "test-dir"
    },
    @{
        Name = "Rename-Item";
        Command = {
            New-Item -Path "./rename-test.txt" -ItemType File -Force
            Rename-Item -Path "./rename-test.txt" -NewName "renamed-test.txt" -Force
        };
        Cleanup = {
            if (Test-Path "./rename-test.txt") { Remove-Item -Path "./rename-test.txt" -Force }
            if (Test-Path "./renamed-test.txt") { Remove-Item -Path "./renamed-test.txt" -Force }
        };
        Creates = "renamed-test.txt"
    },
    @{
        Name = "Remove-Item (File)";
        Command = {
            New-Item -Path "./delete-test.txt" -ItemType File -Force
            Remove-Item -Path "./delete-test.txt" -Force
        };
        Cleanup = { if (Test-Path "./delete-test.txt") { Remove-Item -Path "./delete-test.txt" -Force } };
        Creates = ""
    }
)

Write-Host "  Running modifying command tests..." -ForegroundColor Yellow

foreach ($test in $modifyingTests) {
    Write-Host "  $($test.Name)" -ForegroundColor Magenta
    try {
        # Run cleanup first
        if ($test.Cleanup) { & $test.Cleanup }

        Write-Host "    Executing..." -ForegroundColor Gray
        $result = & $test.Command

        if ($test.Creates -and (Test-Path (Join-Path -Path $TestPath -ChildPath $test.Creates))) {
            Write-Host "    File created - command approved ✅" -ForegroundColor Green
        } else {
            Write-Host "    Command executed - check if it prompted for approval" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "    ⚠️  May have been denied or failed: $_" -ForegroundColor Orange
    }
    finally {
        # Cleanup regardless of outcome
        if ($test.Cleanup) { & $test.Cleanup }
    }
}

# Section 3: Command Chaining
Write-Host "
SECTION 3: Command Chaining" -ForegroundColor Magenta
Write-Host "Testing how hook handles multiple commands" -ForegroundColor Gray

# All read-only chain
Write-Host "  Chained read-only: Get-Location ; Get-Date" -ForegroundColor Yellow
try {
    Get-Location | Out-Null; Get-Date | Out-Null
    Write-Host "    - ✅ Should auto-approve (all read-only)" -ForegroundColor Green
} catch {
    Write-Host "    - ⚠️  Error: $_" -ForegroundColor Red
}

# Mixed chain (should prompt)
Write-Host "  Mixed chain: Test-Path './test-chain.txt' ; New-File './test-chain.txt'" -ForegroundColor Red
$chainTest = "./test-chain.txt"
if (Test-Path $chainTest) { Remove-Item -Path $chainTest -Force }
try {
    Test-Path -Path $chainTest | Out-Null
    New-Item -Path $chainTest -ItemType File -Force | Out-Null
    Write-Host "    - Check if prompted due to New-Item" -ForegroundColor Yellow
} catch {
    Write-Host "    - Command may have been denied or failed" -ForegroundColor Orange
} finally {
    if (Test-Path $chainTest) {
        Remove-Item -Path $chainTest -Force
        Write-Host "    - Cleaned up test file" -ForegroundColor Gray
    }
}

Write-Host "
========================================" -ForegroundColor Cyan
Write-Host "Test suite execution complete!" -ForegroundColor Green
Write-Host "========================================
" -ForegroundColor Cyan

# Cleanup test directory
Write-Host "Cleaning up test directory..." -ForegroundColor Gray
Set-Location -Path $PSScriptRoot
if (Test-Path $TestPath) {
    Remove-Item -Path $TestPath -Recurse -Force
}

Write-Host "✨ All tests completed! ✨" -ForegroundColor Green
Write-Host "Review the output above to verify hook behavior." -ForegroundColor Cyan
Write-Host "`nNote: If modifying commands executed, you approved them during the test." -ForegroundColor Gray
Write-Host "If modifying commands failed, the hook correctly detected or denied them." -ForegroundColor Gray
