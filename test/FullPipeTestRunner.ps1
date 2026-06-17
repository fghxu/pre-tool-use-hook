# FullPipeTestRunner.ps1 — Data-driven full-pipe integration test runner
#
# Spawns Hook.ps1 as a child process, pipes JSON to stdin, captures stdout +
# stderr + exit code, and validates the complete output.
#
# Usage: pwsh -NoProfile -File test/FullPipeTestRunner.ps1

param(
    [string]$XmlPath = "$PSScriptRoot\test-fullpipe.xml"
)

$ErrorActionPreference = "Stop"

$total = 0
$passed = 0
$failed = 0
$failures = [System.Collections.Generic.List[PSCustomObject]]::new()

$hookPath = "$PSScriptRoot\..\src\Hook.ps1"

[xml]$xml = Get-Content $XmlPath -Encoding UTF8
$groups = @($xml.commands.'category-group')

foreach ($group in $groups) {
    $ide = $group.ide
    $cases = @($group.'test-case')

    Write-Host ""
    Write-Host "=== $($group.name) (IDE: $ide) ===" -ForegroundColor Cyan

    foreach ($tc in $cases) {
        $total++

        $hookInputNode = $tc.'hook-input'
        if ($null -eq $hookInputNode) {
            $inputJson = ""
        }
        elseif ($hookInputNode -is [System.Xml.XmlElement]) {
            $inputJson = $hookInputNode.InnerText
        }
        else {
            $inputJson = $hookInputNode.ToString()
        }
        $inputJson = $inputJson.Trim()

        $expectedDecision = $tc.'expected-decision'
        $expectedExit = [int]$tc.'expected-exit'
        $expectedReason = $tc.'expected-reason'
        $description = $tc.description

        Write-Host -NoNewline "  [$total] $description ... "

        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = "pwsh"
            $psi.Arguments = "-NoProfile -NonInteractive -File `"$hookPath`""
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = "$PSScriptRoot\.."

            $process = [System.Diagnostics.Process]::Start($psi)
            $process.StandardInput.Write($inputJson)
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit(10000)
            $exitCode = $process.ExitCode

            $parsed = $null
            $decision = ""
            $reason = ""
            $parseOk = $false

            if ($stdout -and $stdout.Trim().Length -gt 0) {
                try {
                    $parsed = $stdout.Trim() | ConvertFrom-Json
                    if ($parsed.hookSpecificOutput) {
                        $decision = $parsed.hookSpecificOutput.permissionDecision
                        $reason = $parsed.hookSpecificOutput.permissionDecisionReason
                        $parseOk = $true
                    }
                }
                catch {
                    $reason = "JSON parse error: $($_.Exception.Message)"
                }
            }

            $failReasons = [System.Collections.Generic.List[string]]::new()

            if (-not $parseOk) {
                if ($expectedExit -eq 2) {
                    if ($exitCode -eq $expectedExit) {
                        $passed++
                        Write-Host "PASS (exit $exitCode)" -ForegroundColor Green
                        continue
                    }
                }
                $failReasons.Add("stdout not valid JSON")
            }

            if ($parseOk -and $decision -ne $expectedDecision) {
                $failReasons.Add("decision: expected '$expectedDecision', got '$decision'")
            }

            if ($exitCode -ne $expectedExit) {
                $failReasons.Add("exit: expected $expectedExit, got $exitCode")
            }

            if ($parseOk -and $expectedReason -and $reason -notmatch [regex]::Escape($expectedReason)) {
                $failReasons.Add("reason mismatch: '$reason'")
            }

            if ($failReasons.Count -gt 0) {
                $failed++
                $failures.Add([PSCustomObject]@{
                    Number = $total; IDE = $ide; Description = $description
                    Reasons = $failReasons -join "; "; ExitCode = $exitCode
                    Decision = $decision; Reason = $reason; Stderr = $stderr
                })
                Write-Host "FAIL" -ForegroundColor Red
                foreach ($fr in $failReasons) {
                    Write-Host "         $fr" -ForegroundColor Red
                }
            }
            else {
                $passed++
                Write-Host "PASS" -ForegroundColor Green
            }
        }
        catch {
            $failed++
            $failures.Add([PSCustomObject]@{
                Number = $total; IDE = $ide; Description = $description
                Reasons = $_.Exception.Message; ExitCode = -1
                Decision = ""; Reason = ""; Stderr = ""
            })
            Write-Host "FAIL (exception)" -ForegroundColor Red
            Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "Full-Pipe Integration Tests Complete"
Write-Host "========================================"
Write-Host "Total:    $total"
Write-Host "Passed:   $passed"
Write-Host "Failed:   $failed"
Write-Host ""

if ($failed -gt 0) {
    Write-Host "Failed Tests:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  [$($f.Number)] $($f.IDE): $($f.Description)" -ForegroundColor Red
        Write-Host "       $($f.Reasons)" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}

Write-Host "All full-pipe tests passed." -ForegroundColor Green
exit 0
