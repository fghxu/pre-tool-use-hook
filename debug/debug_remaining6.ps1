. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

[xml]$xml = Get-Content .\test/test-cases.xml -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

$indices = @(93, 94, 178, 179, 180, 181)
foreach ($idx in $indices) {
    $tc = $testCases[$idx]
    $num = $idx + 1
    $command = ''
    $cc = $tc.'copilot-command'
    if ($cc -is [System.Xml.XmlElement]) { $command = $cc.InnerText } else { $command = $cc.ToString() }
    $command = $command.Trim()
    $short = ($command.Substring(0, [Math]::Min(200, $command.Length)) -replace "`n",' ')
    Write-Host "=== Test $($num): $($tc.category) - $($tc.description) ==="
    Write-Host "Expected: $($tc.expected)"
    Write-Host "Command: $short"
    $domain = Get-CommandDomain -Command $command
    $subs = Split-Commands -Command $command -Domain $domain
    Write-Host "Domain: $domain  Segments: $($subs.Count)"
    for ($i = 0; $i -lt [Math]::Min(3, $subs.Count); $i++) {
        $s = $subs[$i]
        $sc = ($s.CommandText.Substring(0, [Math]::Min(120, $s.CommandText.Length)) -replace "`n",' ')
        Write-Host "  Seg[$i]: [$($s.Domain)] $sc"
    }
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
