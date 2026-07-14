. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
. .\src\Logger.ps1

$config = Load-Config -Path '.\config.json'

# Test 1: ping
Write-Host '=== Test ping ==='
$d = Get-CommandDomain -Command 'ping -t 10.0.0.1'
Write-Host "Domain: $d"

# Test 2: systemctl restart
Write-Host '=== Test systemctl restart ==='
$d = Get-CommandDomain -Command 'systemctl restart sshd'
Write-Host "Domain: $d"
$r = Resolve-Command -Command 'systemctl restart sshd' -Domain $d -Config $config
Write-Host "Decision: $($r.Decision), Reason: $($r.Reason), Matched: $($r.MatchedPattern)"

# Check what's in Linux modifying for systemctl
$linuxMod = $config.commands.Linux.modifying
Write-Host "Linux modifying entries: $($linuxMod.Count)"
foreach ($e in $linuxMod) {
    if ($e.name -match 'systemctl|curl') {
        Write-Host "  entry: $($e.name) -> patterns: $($e.patterns -join ', ')"
        if ($e._compiledPatterns) {
            Write-Host "    compiled: $($e._compiledPatterns.Count) regex(es)"
        }
    }
}

# Test 3: curl POST
Write-Host '=== Test curl POST ==='
$curlCmd = 'curl -X POST http://localhost:8080/api/restart -H "Content-Type: application/json" -d "{\"service\":\"nginx\"}"'
$d = Get-CommandDomain -Command $curlCmd
Write-Host "Domain: $d"
$r = Resolve-Command -Command $curlCmd -Domain $d -Config $config
Write-Host "Decision: $($r.Decision), Reason: $($r.Reason)"

# Test 4: Sort-Object false positive
Write-Host '=== Test Sort-Object ==='
$soCmd = 'Sort-Object CPU -Descending'
$d = Get-CommandDomain -Command $soCmd
Write-Host "Domain: $d"
$r = Resolve-Command -Command $soCmd -Domain $d -Config $config
Write-Host "Decision: $($r.Decision), Reason: $($r.Reason), Matched: $($r.MatchedPattern)"

# Test 5: Check if 'sc *' regex matches Sort-Object
$scRegex = [regex]::new('sc *', [System.Text.RegularExpressions.RegexOptions]::Compiled)
Write-Host "sc * matches Sort-Object CPU -Descending: $($scRegex.IsMatch($soCmd))"
Write-Host "sc * matches Set-Content: $($scRegex.IsMatch('Set-Content test'))"

# Check PowerShell modifying entries for sc
$psMod = $config.commands.PowerShell.modifying
foreach ($e in $psMod) {
    if ($e.name -match 'Set-Content|sc') {
        Write-Host "  PS entry: $($e.name) -> patterns: $($e.patterns -join ', ')"
        if ($e._compiledPatterns) {
            foreach ($rx in $e._compiledPatterns) {
                $testMatch = $rx.IsMatch($soCmd)
                Write-Host "    regex '$rx' matches Sort-Object: $testMatch"
                if ($testMatch) {
                    Write-Host "    MATCH FOUND at: $($rx.Match($soCmd).Value)"
                }
            }
        }
    }
}

# Test 6: Check all PS modifying compiled patterns against Sort-Object
Write-Host '=== All PS patterns vs Sort-Object ==='
foreach ($e in $psMod) {
    if ($e._compiledPatterns) {
        foreach ($rx in $e._compiledPatterns) {
            if ($rx.IsMatch($soCmd)) {
                Write-Host "MATCH: $($e.name) -> $rx"
            }
        }
    }
}

# Test 7: awk pipeline subshell
Write-Host '=== Test awk subshell ==='
$awkCmd = "cat /var/log/auth.log | grep `"Failed password`" | awk '{print `$(NF-3)}' | sort | uniq -c | sort -rn"
Write-Host "Command: $awkCmd"
$subshells = Split-SubshellCommands -Command $awkCmd
Write-Host "Subshells found: $($subshells.Count)"
foreach ($s in $subshells) {
    Write-Host "  subshell: $($s.CommandText) domain=$($s.Domain)"
}
