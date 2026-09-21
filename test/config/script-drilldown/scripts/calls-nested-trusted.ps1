# Gap coverage (2026-09-21): a nested 'pwsh -File' whose target is TRUSTED.
# The walker collapses the statement to the bare path; engine step 9b recursion
# returns $null (trusted), so the KEPT statement must carry Domain='powershell'
# (F12 forced-domain fix) and resolve tier trusted_program => allow.
pwsh -NoProfile -File scripts\trusted.ps1
Write-Host after-nested-trusted
