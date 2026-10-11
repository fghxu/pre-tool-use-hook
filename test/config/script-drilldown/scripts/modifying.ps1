# modifying.ps1 - read-only lines, then a modifying Copy-Item (line pinned in the test).
Get-ChildItem C:\temp\drilldown
Write-Host "restoring..."
Get-Content C:\temp\log.txt
# the modifying statement below is what forces the ask
Copy-Item -Path C:\temp\a.txt -Destination C:\temp\b.txt
