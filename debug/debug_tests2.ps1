. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
. .\src\Logger.ps1

$config = Load-Config -Path '.\config.json'

# Test full pipeline for awk
Write-Host '=== Full pipeline: awk test ==='
$awkCmd = "cat /var/log/auth.log | grep 'Failed password' | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn"
$mockInput = [PSCustomObject]@{
    tool_name = "run_in_terminal"
    tool_input = $awkCmd
    hook_event_name = "PreToolUse"
    timestamp = "2026-05-15T12:00:00.000Z"
    tool_use_id = "test-001"
}
$result = Invoke-Classify -RawInput $mockInput -IDE "ClaudeCode" -Config $config
Write-Host "Decision: $($result.Decision)"
Write-Host "Reason: $($result.Reason)"
foreach ($sr in $result.SubResults) {
    Write-Host "  sub: $($sr.MatchedPattern) -> $($sr.Decision): $($sr.Reason)"
}

# Test xargs
Write-Host '=== Test xargs detection ==='
$xargsCmd = 'docker ps -a --format "{{.ID}}" | xargs docker rm'
$d = Get-CommandDomain -Command $xargsCmd
Write-Host "Domain: $d"
$nested = Find-NestedCommands -Command $xargsCmd -ParentDomain $d
Write-Host "Nested commands found: $($nested.Count)"
foreach ($n in $nested) {
    Write-Host "  nested: $($n.CommandText) domain=$($n.Domain)"
}

# Test ScriptBlock
Write-Host '=== Test ScriptBlock ==='
$sbCmd = @'
Invoke-Command -ComputerName "DC01", "DC02" -ScriptBlock {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" |
        Select-Object DeviceID, VolumeName, @{
            Name="FreeSpaceGB"
            Expression={[math]::Round($_.FreeSpace/1GB, 2)}
        }, @{
            Name="TotalSpaceGB"
            Expression={[math]::Round($_.Size/1GB, 2)}
        } |
        Format-Table -AutoSize
}
'@
$d = Get-CommandDomain -Command $sbCmd
Write-Host "Domain: $d"
$splits = Split-Commands -Command $sbCmd -Domain $d
Write-Host "Split commands: $($splits.Count)"
foreach ($s in $splits) {
    Write-Host "  split: $($s.CommandText.Substring(0,[Math]::Min(80,$s.CommandText.Length))) domain=$($s.Domain)"
}
$nested = Find-NestedCommands -Command $sbCmd -ParentDomain $d
Write-Host "Nested commands: $($nested.Count)"
foreach ($n in $nested) {
    Write-Host "  nested: $($n.CommandText.Substring(0,[Math]::Min(80,$n.CommandText.Length))) domain=$($n.Domain)"
}

# Test modifying ScriptBlock
Write-Host '=== Test ScriptBlock modifying ==='
$sbModCmd = @'
Invoke-Command -ComputerName (Get-Content "C:\serverlist.txt") -ScriptBlock {
    $packagePath = "\\fileserver\installs\app.msi"
    if (Test-Path $packagePath) {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $packagePath /quiet" -Wait
    }
}
'@
$d = Get-CommandDomain -Command $sbModCmd
Write-Host "Domain: $d"
$nested = Find-NestedCommands -Command $sbModCmd -ParentDomain $d
Write-Host "Nested commands: $($nested.Count)"
foreach ($n in $nested) {
    Write-Host "  nested: $($n.CommandText.Substring(0,[Math]::Min(80,$n.CommandText.Length))) domain=$($n.Domain)"
}
$splits = Split-Commands -Command $sbModCmd -Domain $d
Write-Host "Split commands: $($splits.Count)"
foreach ($s in $splits) {
    Write-Host "  split: $($s.CommandText.Substring(0,[Math]::Min(80,$s.CommandText.Length))) domain=$($s.Domain)"
}
