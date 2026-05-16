. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

[xml]$xml = Get-Content .\test/test-cases.xml -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# 1-based test numbers from test runner: 93, 95, 96, 97, 99, 100, 146, 185
# 0-based XML indices:             92, 94, 95, 96, 98, 99, 145, 184
$indices = @(92, 94, 95, 96, 98, 99, 145, 184)
foreach ($idx in $indices) {
    $tc = $testCases[$idx]
    $num = $idx + 1
    $command = ''
    $cc = $tc.'copilot-command'
    if ($cc -is [System.Xml.XmlElement]) { $command = $cc.InnerText } else { $command = $cc.ToString() }
    $command = $command.Trim()

    Write-Host ('=' * 80)
    Write-Host "TEST $($num): $($tc.category) - $($tc.description)"
    Write-Host "Expected: $($tc.expected)"
    Write-Host "Command:"
    Write-Host $command
    Write-Host '---'

    $domain = Get-CommandDomain -Command $command
    $subs = Split-Commands -Command $command -Domain $domain
    Write-Host "Domain: $domain  Segments: $($subs.Count)"
    for ($i = 0; $i -lt [Math]::Min(12, $subs.Count); $i++) {
        $s = $subs[$i]
        $sc = ($s.CommandText.Substring(0, [Math]::Min(150, $s.CommandText.Length)) -replace "`n",' ')
        Write-Host "  Seg[$i]: [$($s.Domain)] $sc"
    }
    Write-Host '---'
    try {
        $ri = [PSCustomObject]@{ tool_name = 'run_in_terminal'; tool_input = $command }
        $result = Invoke-Classify -RawInput $ri -IDE 'ClaudeCode' -Config $config
        Write-Host "Decision: $($result.Decision)  Reason: $($result.Reason)"
        if ($result.SubResults -and $result.SubResults.Count -gt 0) {
            foreach ($sr in $result.SubResults) {
                $src = ($sr.Command.Substring(0, [Math]::Min(100, $sr.Command.Length)) -replace "`n",' ')
                Write-Host "  Sub: [$($sr.Decision)] $src -> $($sr.Reason)"
            }
        }
    } catch { Write-Host "ERROR: $($_.Exception.Message)" }
    Write-Host ''
}
