# calls-missing.ps1 - invokes a script that DOES NOT EXIST via nested -File.
# The collapsed bare path (scripts\no-such.ps1) is expanded by 9b; the engine's Test-Path
# fails -> FAILURE 'script file not found' -> ask.
pwsh -NoProfile -File scripts\no-such.ps1
Write-Host m
