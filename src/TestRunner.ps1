param(
    [string]$XmlPath = "$PSScriptRoot\..\test\test-cases.adhoc.xml",
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

# Dot-source dependencies
. "$PSScriptRoot\ConfigLoader.ps1"
. "$PSScriptRoot\Parser.ps1"
. "$PSScriptRoot\Resolver.ps1"
. "$PSScriptRoot\HookAdapter.ps1"

# Classifier.ps1 doesn't exist yet -- gracefully handle if missing
$ClassifierLoaded = $false
if (Test-Path "$PSScriptRoot\Classifier.ps1") {
    . "$PSScriptRoot\Classifier.ps1"
    $ClassifierLoaded = $true
}

# Load config
$config = Load-Config -Path "$PSScriptRoot\..\config.json"

# Parse XML
[xml]$xml = Get-Content $XmlPath -Encoding UTF8
$testCases = @($xml.commands.'category-group'.'test-case')

if ($Filter) {
    $testCases = @($testCases | Where-Object { $_.category -like "*$Filter*" })
}

$total = $testCases.Count
$passed = 0
$failed = 0
$failures = @()
$startTime = Get-Date

for ($i = 0; $i -lt $total; $i++) {
    $tc = $testCases[$i]
    $num = $i + 1
    $pct = [math]::Floor($num / $total * 100)
    $name = "$($tc.category) - $($tc.description)"

    # Resolve command text from XML (handles CDATA)
    $copilotCmd = $tc.'copilot-command'
    if ($null -eq $copilotCmd) {
        $command = ""
    }
    elseif ($copilotCmd -is [System.Xml.XmlElement]) {
        $command = $copilotCmd.InnerText
    }
    elseif ($copilotCmd -is [string]) {
        $command = $copilotCmd
    }
    else {
        $command = $copilotCmd.'#cdata-section'
        if ($null -eq $command) { $command = $copilotCmd.ToString() }
    }
    $command = $command.Trim()

    # Draw progress line
    Write-Host -NoNewline "`r[$num/$total $pct% - $name]                    "

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($ClassifierLoaded) {
            # Build a mock $rawInput PSCustomObject
            $rawInput = [PSCustomObject]@{
                tool_name  = "run_in_terminal"
                tool_input = $command
            }
            $result = Invoke-Classify -RawInput $rawInput -IDE "ClaudeCode" -Config $config
        }
        else {
            # Auto-fail: Classifier.ps1 not loaded (TDD red phase)
            $result = [PSCustomObject]@{
                Decision = "fail"
                Reason   = "Classifier.ps1 not loaded -- all tests expected to fail in TDD red phase"
            }
        }
    }
    catch {
        $result = [PSCustomObject]@{
            Decision = "error"
            Reason   = $_.Exception.Message
        }
    }

    $sw.Stop()
    $elapsed = $sw.ElapsedMilliseconds

    if ($result.Decision -eq $tc.expected) {
        $passed++
    }
    else {
        $failed++
        $fail = [PSCustomObject]@{
            Number   = $num
            Name     = $name
            Command  = $command
            Expected = $tc.expected
            Got      = $result.Decision
            Reason   = $result.Reason
            Time     = $elapsed
        }
        $failures += $fail

        # Print failure below progress line
        Write-Host ""
        Write-Host "FAIL [$num/$total $pct% - $name]  Time: ${elapsed}ms" -ForegroundColor Red
        Write-Host "  Command: $($fail.Command.Substring(0, [Math]::Min(200, $fail.Command.Length)))"
        Write-Host "  Expected: $($fail.Expected)  Got: $($fail.Got)"
        Write-Host "  Classifier said: $($fail.Reason)"
        Write-Host ""
    }

    # Hard timeout check per test
    if ($elapsed -gt 1000) {
        Write-Host "  WARNING: Classification exceeded 1000ms hard cap (${elapsed}ms)" -ForegroundColor Yellow
    }
}

# Summary
$totalTime = (Get-Date) - $startTime
$pctPassed = if ($total -gt 0) { [math]::Round($passed / $total * 100, 1) } else { 0 }

Write-Host ""
Write-Host "========================================"
Write-Host "Test Run Complete"
Write-Host "========================================"
Write-Host "Total:    $total"
Write-Host "Passed:   $passed ($pctPassed%)"
Write-Host "Failed:   $failed"
Write-Host "Duration: $([math]::Round($totalTime.TotalSeconds, 1))s"
Write-Host "Config:   config.json"
Write-Host ""

if ($failures.Count -gt 0) {
    Write-Host "Failed Tests:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host ("  [{0,4}] {1}" -f $f.Number, $f.Name) -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "========================================"

if ($failed -gt 0) {
    exit 1
}
else {
    exit 0
}
