# Gap coverage (2026-09-21): design 6.5 documented edge - a QUOTED nested -File
# path containing SPACES. The walker collapses the statement to the unquoted VALUE
# 'scripts\my script.ps1', which does NOT match 9b's no-space unquoted arm, so the
# statement stays plain => unknown => ask (fail-closed over-ask, accepted v1 edge).
pwsh -NoProfile -File "scripts\my script.ps1"
Write-Host done
