. .\src\ConfigLoader.ps1
. .\src\Parser.ps1
. .\src\Resolver.ps1
. .\src\HookAdapter.ps1
. .\src\Classifier.ps1
$config = Load-Config -Path '.\config.json'

[xml]$xml = Get-Content .\test/test-cases.xml -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

# Failing test numbers (1-based): 35, 39, 58, 67, 68, 70, 72, 73, 189, 223
# 0-based XML indices:          34, 38, 57, 66, 67, 69, 71, 72, 188, 222
$indices = @(34, 38, 57, 66, 67, 69, 71, 72, 188, 222)
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
    Write-Host "Domain: $domain"

    # Check if AST extraction applies
    $astCommands = @()
    if ($domain -eq 'powershell') {
        $astCommands = @(Get-PowerShellCommands -Command $command)
        Write-Host "AST commands extracted: $($astCommands.Count)"
        foreach ($ac in $astCommands) {
            Write-Host "  AST: [$($ac.Domain)] $($ac.CommandText)"
        }
    }

    $subs = Split-Commands -Command $command -Domain $domain
    Write-Host "Split-Commands segments: $($subs.Count)"
    for ($i = 0; $i -lt [Math]::Min(12, $subs.Count); $i++) {
        $s = $subs[$i]
        $sc = ($s.CommandText.Substring(0, [Math]::Min(200, $s.CommandText.Length)) -replace "`n",' ')
        Write-Host "  Seg[$i]: [$($s.Domain)] $sc"
    }

    Write-Host '---'
    try {
        $ri = [PSCustomObject]@{ tool_name = 'run_in_terminal'; tool_input = $command }
        $result = Invoke-Classify -RawInput $ri -IDE 'ClaudeCode' -Config $config
        Write-Host "Decision: $($result.Decision)  Reason: $($result.Reason)"
        if ($result.SubResults -and $result.SubResults.Count -gt 0) {
            foreach ($sr in $result.SubResults) {
                $src = ($sr.Command.Substring(0, [Math]::Min(120, $sr.Command.Length)) -replace "`n",' ')
                Write-Host "  Sub: [$($sr.Decision)] $src -> $($sr.Reason)"
            }
        }
    } catch { Write-Host "ERROR: $($_.Exception.Message)" }
    Write-Host ''
}
