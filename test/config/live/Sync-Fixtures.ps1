# Sync-Fixtures.ps1 - refresh this folder's test configs from the repo-root config.json.
#
# Suites in this folder run against config.json IN THIS FOLDER (a test copy), so
# edits to the repo-root config.json do not affect them until you run this script.
#
# Produces:
#   config.json        = copy of repo-root config.json + _comment_test_copy marker
#   config.strict.json = same + global_modifying_strictness = strict and
#                        editable_paths.linux reduced to /tmp/ (redirect suite)
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File test/config/live/Sync-Fixtures.ps1
#
# NOTE: keep this file pure ASCII - powershell.exe 5.1 misreads UTF-8
# punctuation (em-dash etc.) as smart quotes and fails to parse.

$ErrorActionPreference = "Stop"

$repoRoot  = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$src       = Join-Path $repoRoot 'config.json'
$dstNormal = Join-Path $PSScriptRoot 'config.json'
$dstStrict = Join-Path $PSScriptRoot 'config.strict.json'

# --- 0) safety guard: refuse to sync while the root config is in the phase-I ---
# --- LLM-test state. Test fixtures must never make network calls, and the     ---
# --- suites' baselines assume a normal-mode root config.                      ---
$rootObj = Get-Content $src -Raw | ConvertFrom-Json
if ($rootObj.llm_second_opinion -and $rootObj.llm_second_opinion.enabled -eq $true) {
    throw "Sync-Fixtures: REFUSED - root config.json has llm_second_opinion.enabled=true. The test copy must stay disabled, otherwise fullpipe suites would make REAL LLM calls (quota burn + non-deterministic verdicts). Set enabled back to false before syncing. See docs/config-json-guide.md section 10.5."
}
if ($rootObj.global_modifying_strictness -ne 'normal') {
    throw "Sync-Fixtures: REFUSED - root config.json has global_modifying_strictness='$($rootObj.global_modifying_strictness)' (expected 'normal'). The live suites' baselines assume a normal-mode root; syncing now would flip hundreds of expectations. If you are in the phase-I LLM-test window (strict is recommended there), revert to normal before syncing; if the change is permanent, the suites need re-baselining first."
}

# --- 1) normal test copy: copy + insert marker after the description line -----
Copy-Item $src $dstNormal -Force
$lines = Get-Content $dstNormal
$out = foreach ($line in $lines) {
    $line
    if ($line -match '^  "description": "PreToolUse Hook command classification database') {
        '  "_comment_test_copy": "TEST COPY of the repo-root config.json - refresh with Sync-Fixtures.ps1 after editing the root config. Suites in this folder run against THIS file, not the root config.",'
    }
}
$out | Set-Content $dstNormal -Encoding UTF8

# --- 2) strict fixture: copy the marked normal file, force strict, reduce -----
# --- editable_paths.linux to /tmp/ only, swap marker for fixture comment    ---
Copy-Item $dstNormal $dstStrict -Force
$lines = Get-Content $dstStrict
$out = foreach ($line in $lines) {
    if ($line -match '"_comment_linux"') { continue }
    if ($line -match '^\s+"\(\[A-Za-z\]:\)\?\[/') { continue }   # /home pattern line
    if ($line -match '^\s+"~\[/') { continue }                    # ~ pattern line
    if ($line -match '^\s+"/tmp/",$') {
        '      "/tmp/"'                                            # drop trailing comma (siblings removed)
        continue
    }
    if ($line -match '^  "global_modifying_strictness": "normal",$') {
        '  "global_modifying_strictness": "strict",'
        continue
    }
    if ($line -match '^  "_comment_test_copy"') {
        '  "_comment_fixture": "TEST FIXTURE - copy of this folder''s config.json with global strictness forced to strict and editable_paths.linux reduced to /tmp/ (redirect suite). Regenerate with Sync-Fixtures.ps1.",'
        continue
    }
    $line
}
$out | Set-Content $dstStrict -Encoding UTF8

# --- verify both load ----------------------------------------------------------
. (Join-Path $repoRoot 'src\ConfigLoader.ps1')
$null = Load-Config -Path $dstNormal
$null = Load-Config -Path $dstStrict
Write-Host "Synced + validated: $dstNormal"
Write-Host "Synced + validated: $dstStrict"
