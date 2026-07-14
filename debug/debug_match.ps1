. .\src\ConfigLoader.ps1
$config = Load-Config -Path '.\config.json'
$linux = $config.commands.linux
Write-Host '=== Linux read_only entries matching shutdown ==='
foreach ($entry in $linux.read_only) {
    if ($entry._compiledPatterns) {
        foreach ($cp in $entry._compiledPatterns) {
            if ($cp.IsMatch('shutdown /s /t 60')) {
                Write-Host "$($entry.name): $cp MATCHES shutdown /s /t 60"
            }
        }
    }
}
Write-Host '=== Linux modifying entries ==='
foreach ($entry in $linux.modifying) {
    if ($entry.name -match 'shut|bash') {
        Write-Host "$($entry.name): patterns=[$($entry.patterns -join ', ')]"
        if ($entry._compiledPatterns) {
            foreach ($cp in $entry._compiledPatterns) {
                Write-Host "  Compiled: $cp"
                if ($cp.IsMatch('shutdown /s /t 60')) {
                    Write-Host '  MATCH!'
                }
            }
        }
    }
}
