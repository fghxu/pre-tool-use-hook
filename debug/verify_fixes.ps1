. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

$tests = @(
    @{Id=195; Cmd='echo "server: 10.0.0.5:6379" | tee /etc/redis/sentinel.conf'; Expected='ask'},
    @{Id=208; Cmd='echo "deployer:P@ssw0rd!" | chpasswd'; Expected='ask'},
    @{Id=229; Cmd='echo "0 2 * * * /opt/scripts/backup.sh" | crontab -'; Expected='ask'},
    @{Id=216; Cmd='echo "Stopping service: $(systemctl stop postgresql)"'; Expected='ask'}
)

$passed = 0
$failed = 0

foreach ($test in $tests) {
    Write-Host "--- Test $($test.Id) ---"
    Write-Host "Command: $($test.Cmd)"
    Write-Host "Expected: $($test.Expected)"

    try {
        $rawInput = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $test.Cmd }
        $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        Write-Host "Got: $($result.Decision)"
        Write-Host "Reason: $($result.Reason)"

        if ($result.SubResults.Count -gt 0) {
            Write-Host "Sub-results:"
            foreach ($sr in $result.SubResults) {
                Write-Host "  [$($sr.Decision)] Command='$($sr.Command)' Reason='$($sr.Reason)'"
            }
        }

        if ($result.Decision -eq $test.Expected) {
            Write-Host "PASS"
            $passed++
        } else {
            Write-Host "FAIL: expected $($test.Expected), got $($result.Decision)"
            $failed++
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        $failed++
    }
    Write-Host ""
}

Write-Host "================"
Write-Host "Passed: $passed"
Write-Host "Failed: $failed"
Write-Host "================"
