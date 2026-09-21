# cmd-inside.ps1 - a modifying command hidden behind a nested -Command wrapper INSIDE a
# script. Pins the SkipRewalk SCOPE (I9b): plain statements stay re-walkable, so the
# walker's own -Command branch unwraps Remove-Item and it must still ask.
pwsh -NoProfile -Command "Remove-Item C:\temp\x"
Write-Host done
