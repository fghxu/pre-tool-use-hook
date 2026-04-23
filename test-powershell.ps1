# Test the hook with PowerShell commands on Windows

# Test Read-Only Commands (Should Auto-Approve)
Write-Host "Testing Read-Only Commands..." -ForegroundColor Green

Write-Host "1. Get current directory: Get-Location" -ForegroundColor Cyan
Get-Location

Write-Host "2. List items in current directory: Get-ChildItem" -ForegroundColor Cyan
Get-ChildItem | Select-Object Name, Mode, LastWriteTime

Write-Host "3. Get process information: Get-Process -Name 'lsass'" -ForegroundColor Cyan
Get-Process -Name "lsass" | Select-Object ProcessName, Id, CPU

Write-Host "4. Get service information: Get-Service -Name 'w32time'" -ForegroundColor Cyan
Get-Service -Name "w32time" | Select-Object Name, Status, StartType

Write-Host "5. Test network connection: Test-NetConnection -ComputerName localhost" -ForegroundColor Cyan
Test-NetConnection -ComputerName "localhost" | Select-Object ComputerName, TcpTestSucceeded

Write-Host "6. Get command information: Get-Command -Name 'Get-Location'" -ForegroundColor Cyan
Get-Command -Name "Get-Location" | Select-Object Name, CommandType

Write-Host "7. Get environment variable: $env:USERNAME" -ForegroundColor Cyan
$env:USERNAME

Write-Host "8. List .NET types: [System.Environment]::OSVersion" -ForegroundColor Cyan
[System.Environment]::OSVersion

Write-Host "9. Get date: Get-Date" -ForegroundColor Cyan
Get-Date

Write-Host "10. Get host information: Get-Host" -ForegroundColor Cyan
Get-Host | Select-Object Name, Version

Write-Host "All read-only commands completed successfully!" -ForegroundColor Green

Write-Host "`n`nTesting Modifying Commands (Should Prompt)..." -ForegroundColor Yellow

# These should trigger approval prompts
Write-Host "1. Create test file: New-Item -Path './test-hook.txt' -ItemType File" -ForegroundColor Red
New-Item -Path "./test-hook.txt" -ItemType File -Force

Write-Host "2. Create directory: New-Item -Path './test-hook-dir' -ItemType Directory" -ForegroundColor Red
New-Item -Path "./test-hook-dir" -ItemType Directory -Force

Write-Host "3. Rename item: Rename-Item -Path './test-hook.txt' -NewName 'renamed-test.txt'" -ForegroundColor Red
Rename-Item -Path "./test-hook.txt" -NewName "renamed-test.txt" -Force

Write-Host "4. Remove item: Remove-Item -Path './renamed-test.txt'" -ForegroundColor Red
Remove-Item -Path "./renamed-test.txt" -Force

Write-Host "5. Remove directory: Remove-Item -Path './test-hook-dir'" -ForegroundColor Red
Remove-Item -Path "./test-hook-dir" -Force

Write-Host "Modifying commands test completed!" -ForegroundColor Yellow

Write-Host "`n`nTesting Chained Commands..." -ForegroundColor Magenta

# Test chained commands with all read-only
Write-Host "1. Chained read-only: Get-Location && Get-Host" -ForegroundColor Cyan
Get-Location ; Get-Host | Select-Object Version

# Test chained with modifying
Write-Host "2. Mixed chain (should prompt): Get-Date ; New-Item -Path './mixed-test.txt'" -ForegroundColor Red
Get-Date ; New-Item -Path "./mixed-test.txt" -ItemType File -Force

# Clean up
Write-Host "Cleaning up test files..." -ForegroundColor Green
if (Test-Path "./mixed-test.txt") {
    Remove-Item -Path "./mixed-test.txt" -Force
    Write-Host "Removed mixed-test.txt" -ForegroundColor Green
}

Write-Host "`nAll PowerShell hook tests completed!" -ForegroundColor Green