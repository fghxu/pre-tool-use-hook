# file-loop-a.ps1 - loop via nested -File (walker collapses each to bare path -> 9b recursion).
pwsh -NoProfile -File scripts\file-loop-b.ps1
Write-Host a
