# file-loop-b.ps1 - completes the nested -File loop (a -> b -> a).
pwsh -NoProfile -File scripts\file-loop-a.ps1
Write-Host b
