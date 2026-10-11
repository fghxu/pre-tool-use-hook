# Gap coverage (2026-09-21): design I17 - script encoding.
# This file is BOM-less UTF-8 with non-ASCII characters (em dash, accents) in a
# comment. The engine reads content with [System.IO.File]::ReadAllText (BOM
# sniffing + UTF-8 default); under powershell.exe 5.1 a Get-Content without
# -Encoding would read these bytes as ANSI, mojibake the AST parse and turn this
# read-only script into a fail-closed ask.
# cafe — em dash + naïve ünïcodé
Get-ChildItem $env:TEMP
Write-Host "ok"
