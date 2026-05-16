. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

[xml]$xml = Get-Content .\test/test-cases.xml -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# 0-based indices for failing tests
$indices = @(93, 94, 95, 96, 98, 99, 132, 178, 179, 180, 181, 182, 183, 184, 185, 186)

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

    Write-Host "=== Test $($num): $($tc.category) - $($tc.description) ==="
    Write-Host "Expected: $($tc.expected)"
    Write-Host "Command (first 300 chars): $($command.Substring(0, [Math]::Min(300, $command.Length)))"

    # Show domain
    $domain = Get-CommandDomain -Command $command
    Write-Host "Domain: $domain"

    # Show Split-Commands
    $subs = Split-Commands -Command $command -Domain $domain
    Write-Host "Split into $($subs.Count) segments"

    # Show all segments
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $s = $subs[$i]
        Write-Host "  Segment $($i): [$($s.Domain)] $($s.CommandText.Substring(0, [Math]::Min(150, $s.CommandText.Length)))"
    }

    # Full classification
    try {
        $rawInput = [PSCustomObject]@{ tool_name = "run_in_terminal"; tool_input = $command }
        $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        Write-Host "Decision: $($result.Decision)"
        Write-Host "Reason: $($result.Reason)"
        if ($result.SubResults -and $result.SubResults.Count -gt 0) {
            foreach ($sr in $result.SubResults) {
                Write-Host "  Sub: [$($sr.Decision)] $($sr.Command.Substring(0, [Math]::Min(100, $sr.Command.Length))) -> $($sr.Reason)"
            }
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}
