. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
$config = Load-Config -Path '.\config.json'

$ids = @(60,172,205,218,223,238,275)
[xml]$x = Get-Content .\test\test-cases.xml

foreach ($id in $ids) {
    $t = $x.SelectNodes("//test") | Where-Object { $_.id -eq "$id" }
    Write-Host "--- Test $($id): $($t.name) ---"
    Write-Host "Command:"
    Write-Host $t.command
    Write-Host "Expected: $($t.assessment)"
    Write-Host ""
}

# Test specific commands
Write-Host "=== Debug curl test 172 ==="
$t172 = $x.SelectNodes("//test") | Where-Object { $_.id -eq "172" }
# Try domain detection
$d = Get-CommandDomain -Command $t172.command
Write-Host "Domain: $d"

# Try wget test 205
Write-Host "=== Debug wget test 205 ==="
$t205 = $x.SelectNodes("//test") | Where-Object { $_.id -eq "205" }
$d = Get-CommandDomain -Command $t205.command
Write-Host "Domain: $d"

# Test curl pattern matching
Write-Host "=== Debug curl patterns ==="
$linuxReadOnly = $config.commands.Linux.read_only
foreach ($e in $linuxReadOnly) {
    if ($e.name -eq 'curl GET') {
        Write-Host "curl patterns:"
        foreach ($rx in $e._compiledPatterns) {
            Write-Host "  regex: $rx"
            Write-Host "  matches 'curl https://api.example.com/data': $($rx.IsMatch('curl https://api.example.com/data'))"
        }
    }
}

# Test wget pattern
Write-Host "=== Debug wget patterns ==="
$linuxModifying = $config.commands.Linux.modifying
foreach ($e in $linuxModifying) {
    if ($e.name -eq 'wget') {
        Write-Host "wget patterns:"
        foreach ($rx in $e._compiledPatterns) {
            Write-Host "  regex: $rx"
        }
    }
}
