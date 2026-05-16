. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

[xml]$xml = Get-Content .\test\test-cases.xml -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# Test indices (0-based from test numbers)
$indices = @(59, 171, 204, 217, 222, 237, 274)

foreach ($idx in $indices) {
    $tc = $testCases[$idx]
    $num = $idx + 1
    $command = ""
    $copilotCmd = $tc.'copilot-command'
    if ($copilotCmd -is [System.Xml.XmlElement]) { $command = $copilotCmd.InnerText }
    elseif ($copilotCmd -is [string]) { $command = $copilotCmd }
    else {
        $command = $copilotCmd.'#cdata-section'
        if ($null -eq $command) { $command = $copilotCmd.ToString() }
    }
    $command = $command.Trim()

    Write-Host "--- Test $($num): $($tc.category) - $($tc.description) ---"
    Write-Host "Command (first 200 chars): $($command.Substring(0, [Math]::Min(200, $command.Length)))"
    Write-Host "Expected: $($tc.expected)"

    # Run classification
    try {
        $rawInput = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $command }
        $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        Write-Host "Got: $($result.Decision) - Reason: $($result.Reason)"
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}
