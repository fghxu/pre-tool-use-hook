. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
$config = Load-Config -Path '.\config.json'

# Test 1: awk subshell detection
Write-Host '=== Test awk subshell ==='
$cmd = 'cat /var/log/auth.log | grep "Failed password" | awk ''{print $(NF-3)}'' | sort | uniq -c | sort -rn'
$subshells = Split-SubshellCommands -Command $cmd
Write-Host "Subshells: $($subshells.Count)"
foreach ($s in $subshells) { Write-Host "  subshell: $($s.CommandText)" }

# Test 2: awk pattern matching
Write-Host '=== Test awk pattern match ==='
$linuxReadOnly = $config.commands.Linux.read_only
foreach ($e in $linuxReadOnly) {
    if ($e.name -eq 'awk') {
        Write-Host "awk patterns: $($e._compiledPatterns -join ', ')"
        foreach ($rx in $e._compiledPatterns) {
            $test = "awk '{print `$(NF-3)}'"
            Write-Host "  matches '$test': $($rx.IsMatch($test))"
        }
    }
}

# Test 3: heredoc split
Write-Host '=== Test heredoc split ==='
$heredocCmd = @'
cat <<'SCRIPT' |
echo "===== System Health Report ====="
echo "Hostname: $(hostname)"
echo "Uptime:   $(uptime -p)"
df -h /
free -m
ps aux --sort=-%cpu | head -6
SCRIPT
bash
'@
$d = Get-CommandDomain -Command $heredocCmd
Write-Host "Domain: $d"
$splits = Split-Commands -Command $heredocCmd -Domain $d
Write-Host "Split count: $($splits.Count)"
foreach ($s in $splits) {
    Write-Host "  split: $($s.CommandText.Substring(0,[Math]::Min(80,$s.CommandText.Length))) domain=$($s.Domain)"
}

# Test 4: git status
Write-Host '=== Test git status ==='
$d = Get-CommandDomain -Command 'git status --porcelain'
Write-Host "Domain: $d"

# Test 5: PowerShell script detection
Write-Host '=== Test PowerShell script ==='
$psCmd = @'
$computers = Get-Content "C:\servers.txt"
foreach ($computer in $computers) {
    try {
        Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    } catch { }
}
'@
$d = Get-CommandDomain -Command $psCmd
Write-Host "Domain: $d"

# Test 6: Invoke-Command ScriptBlock
Write-Host '=== Test Invoke-Command ScriptBlock ==='
$sbCmd = 'Invoke-Command -ComputerName "DC01" -ScriptBlock { Get-CimInstance -ClassName Win32_LogicalDisk | Select-Object DeviceID | Format-Table }'
$d = Get-CommandDomain -Command $sbCmd
Write-Host "Domain: $d"
$nested = Find-NestedCommands -Command $sbCmd -ParentDomain $d
Write-Host "Nested count: $($nested.Count)"
foreach ($n in $nested) {
    Write-Host "  nested: $($n.CommandText.Substring(0,[Math]::Min(80,$n.CommandText.Length))) domain=$($n.Domain)"
}
