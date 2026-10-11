# Author-pass gap coverage (2026-09-21): design I17 - extension matching is
# case-insensitive everywhere -match is used ('.PS1' == '.ps1'), and the
# filesystem on Windows resolves the name regardless of case.
Get-ChildItem $env:TEMP
Write-Host upper
