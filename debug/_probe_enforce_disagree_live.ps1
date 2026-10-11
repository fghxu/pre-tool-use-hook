# Probe: does the LIVE config.local.json load with the new enforce_disagree switch?
# (debug/ probe convention - never the repo-root config.json in tests; this probe
# intentionally reads the live file to validate the rollout edit.)
. (Join-Path $PSScriptRoot '..\src\ConfigLoader.ps1')
try {
    $c = Load-Config -Path (Join-Path $PSScriptRoot '..\config.local.json')
    $t = $c._compiled.llmThirdOpinion
    if ($null -eq $t) { Write-Host 'FAIL: llmThirdOpinion compiled block is NULL'; exit 1 }
    Write-Host ("OK: Enabled={0} EnforceDisagree={1} Model={2} EffectiveTimeout={3}" -f $t.Enabled, $t.EnforceDisagree, $t.Model, $t.EffectiveTimeoutMs)
    if ($t.EnforceDisagree -eq $false) { Write-Host 'SWITCH ACTIVE: disagreement will NOT force ask'; exit 0 }
    else { Write-Host 'NOTE: EnforceDisagree is true (forced ask stays)'; exit 0 }
}
catch {
    Write-Host ("THROW: " + $_.Exception.Message)
    exit 1
}
