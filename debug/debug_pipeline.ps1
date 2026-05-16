. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

Write-Host "=== Test 195 (tee pipeline) ==="
$cmd = 'echo "server: 10.0.0.5:6379" | tee /etc/redis/sentinel.conf'
Write-Host "Command: $cmd"
$domain = Get-CommandDomain -Command $cmd
Write-Host "Domain: $domain"
$subs = Split-Commands -Command $cmd -Domain $domain
Write-Host "Split-Commands ($($subs.Count) parts):"
foreach ($s in $subs) {
    Write-Host "  [$($s.Domain)] $($s.CommandText) (Pipeline: $($s.IsPipeline))"
}
$nested = Find-NestedCommands -Command $cmd -ParentDomain $domain
Write-Host "NestedCommands ($($nested.Count) parts):"
foreach ($s in $nested) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
$subshells = Split-SubshellCommands -Command $cmd
Write-Host "SubshellCommands ($($subshells.Count) parts):"
foreach ($s in $subshells) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
Write-Host ""

Write-Host "=== Test 208 (chpasswd) ==="
$cmd2 = 'echo "deployer:P@ssw0rd!" | chpasswd'
Write-Host "Command: $cmd2"
$domain2 = Get-CommandDomain -Command $cmd2
Write-Host "Domain: $domain2"
$subs2 = Split-Commands -Command $cmd2 -Domain $domain2
Write-Host "Split-Commands ($($subs2.Count) parts):"
foreach ($s in $subs2) {
    Write-Host "  [$($s.Domain)] $($s.CommandText) (Pipeline: $($s.IsPipeline))"
}
$nested2 = Find-NestedCommands -Command $cmd2 -ParentDomain $domain2
Write-Host "NestedCommands ($($nested2.Count) parts):"
foreach ($s in $nested2) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
$subshells2 = Split-SubshellCommands -Command $cmd2
Write-Host "SubshellCommands ($($subshells2.Count) parts):"
foreach ($s in $subshells2) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
Write-Host ""

Write-Host "=== Test 229 (crontab) ==="
$cmd3 = 'echo "0 2 * * * /opt/scripts/backup.sh" | crontab -'
Write-Host "Command: $cmd3"
$domain3 = Get-CommandDomain -Command $cmd3
Write-Host "Domain: $domain3"
$subs3 = Split-Commands -Command $cmd3 -Domain $domain3
Write-Host "Split-Commands ($($subs3.Count) parts):"
foreach ($s in $subs3) {
    Write-Host "  [$($s.Domain)] $($s.CommandText) (Pipeline: $($s.IsPipeline))"
}
$nested3 = Find-NestedCommands -Command $cmd3 -ParentDomain $domain3
Write-Host "NestedCommands ($($nested3.Count) parts):"
foreach ($s in $nested3) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
$subshells3 = Split-SubshellCommands -Command $cmd3
Write-Host "SubshellCommands ($($subshells3.Count) parts):"
foreach ($s in $subshells3) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
Write-Host ""

Write-Host "=== Test 216 (subshell) ==="
$cmd4 = 'echo "Stopping service: $(systemctl stop postgresql)"'
Write-Host "Command: $cmd4"
$domain4 = Get-CommandDomain -Command $cmd4
Write-Host "Domain: $domain4"
$subs4 = Split-Commands -Command $cmd4 -Domain $domain4
Write-Host "Split-Commands ($($subs4.Count) parts):"
foreach ($s in $subs4) {
    Write-Host "  [$($s.Domain)] $($s.CommandText) (Pipeline: $($s.IsPipeline))"
}
$nested4 = Find-NestedCommands -Command $cmd4 -ParentDomain $domain4
Write-Host "NestedCommands ($($nested4.Count) parts):"
foreach ($s in $nested4) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}
$subshells4 = Split-SubshellCommands -Command $cmd4
Write-Host "SubshellCommands ($($subshells4.Count) parts):"
foreach ($s in $subshells4) {
    Write-Host "  [$($s.Domain)] $($s.CommandText)"
}

Write-Host ""
Write-Host "=== PATTERN DEBUG ==="
Write-Host ""

# Check if chpasswd pattern matches
Write-Host "--- chpasswd pattern check ---"
$chp = $config.commands.Linux.modifying | Where-Object { $_.name -eq 'chpasswd' }
if ($chp) {
    Write-Host "Found chpasswd entry"
    foreach ($rx in $chp._compiledPatterns) {
        Write-Host "  Regex: $rx"
        Write-Host "  Matches 'chpasswd': $($rx.IsMatch('chpasswd'))"
        Write-Host "  Matches 'chpasswd ': $($rx.IsMatch('chpasswd '))"
    }
} else {
    Write-Host "chpasswd entry NOT FOUND"
}

Write-Host "--- crontab pattern check ---"
$cr = $config.commands.Linux.modifying | Where-Object { $_.name -eq 'crontab' }
if ($cr) {
    Write-Host "Found crontab entry"
    foreach ($rx in $cr._compiledPatterns) {
        Write-Host "  Regex: $rx"
        Write-Host "  Matches 'crontab -': $($rx.IsMatch('crontab -'))"
    }
} else {
    Write-Host "crontab entry NOT FOUND"
}

Write-Host "--- tee pattern check ---"
$tee = $config.commands.Linux.modifying | Where-Object { $_.name -eq 'tee' }
if ($tee) {
    Write-Host "Found tee entry"
    foreach ($rx in $tee._compiledPatterns) {
        Write-Host "  Regex: $rx"
        Write-Host "  Matches 'tee /etc/redis/sentinel.conf': $($rx.IsMatch('tee /etc/redis/sentinel.conf'))"
    }
} else {
    Write-Host "tee entry NOT FOUND"
}

Write-Host "--- systemctl pattern check ---"
$sys = $config.commands.Linux.modifying | Where-Object { $_.name -eq 'systemctl' }
if ($sys) {
    Write-Host "Found systemctl entry"
    foreach ($rx in $sys._compiledPatterns) {
        Write-Host "  Regex: $rx"
        Write-Host "  Matches 'systemctl stop postgresql': $($rx.IsMatch('systemctl stop postgresql'))"
    }
} else {
    Write-Host "systemctl entry NOT FOUND"
}

Write-Host ""
Write-Host "=== FULL CLASSIFICATION ==="
Write-Host ""

Write-Host "--- Test 195 full classification ---"
$rawInput = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $cmd }
try {
    $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
    Write-Host "Decision: $($result.Decision)"
    Write-Host "Reason: $($result.Reason)"
    foreach ($sr in $result.SubResults) {
        Write-Host "  Sub: [$($sr.Decision)] $($sr.Command) -> $($sr.Reason)"
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}

Write-Host "--- Test 208 full classification ---"
$rawInput2 = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $cmd2 }
try {
    $result2 = Invoke-Classify -RawInput $rawInput2 -IDE "ClaudeCode" -Config $config
    Write-Host "Decision: $($result2.Decision)"
    Write-Host "Reason: $($result2.Reason)"
    foreach ($sr in $result2.SubResults) {
        Write-Host "  Sub: [$($sr.Decision)] $($sr.Command) -> $($sr.Reason)"
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}

Write-Host "--- Test 229 full classification ---"
$rawInput3 = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $cmd3 }
try {
    $result3 = Invoke-Classify -RawInput $rawInput3 -IDE "ClaudeCode" -Config $config
    Write-Host "Decision: $($result3.Decision)"
    Write-Host "Reason: $($result3.Reason)"
    foreach ($sr in $result3.SubResults) {
        Write-Host "  Sub: [$($sr.Decision)] $($sr.Command) -> $($sr.Reason)"
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}

Write-Host "--- Test 216 full classification ---"
$rawInput4 = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $cmd4 }
try {
    $result4 = Invoke-Classify -RawInput $rawInput4 -IDE "ClaudeCode" -Config $config
    Write-Host "Decision: $($result4.Decision)"
    Write-Host "Reason: $($result4.Reason)"
    foreach ($sr in $result4.SubResults) {
        Write-Host "  Sub: [$($sr.Decision)] $($sr.Command) -> $($sr.Reason)"
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}
