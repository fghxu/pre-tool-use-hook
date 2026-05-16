[xml]$xml = Get-Content '.\test/test-cases.xml' -Encoding UTF8
$tests = @($xml.commands.'category-group'.'test-case')
$indices = @(94,95,96,98,99,184)
foreach ($idx in $indices) {
    $tc = $tests[$idx]
    $num = $idx + 1
    $cmd = $tc.'copilot-command'
    if ($cmd -is [System.Xml.XmlElement]) { $text = $cmd.InnerText }
    elseif ($cmd -is [string]) { $text = $cmd }
    else { $text = $cmd.'#cdata-section'; if ($null -eq $text) { $text = $cmd.ToString() } }
    Write-Host "=== Test $num (index=$idx): expected=$($tc.expected), category=$($tc.category) ==="
    Write-Host 'COMMAND:'
    Write-Host $text.Substring(0, [Math]::Min(500, $text.Length))
    Write-Host ''
}
