# Gap coverage (2026-09-21): I12 - a statement inside a script is classified in
# ITS OWN domain (here linux 'ls' => read_only in the fixture config), so a
# cross-domain read-only statement keeps the script allow.
ls -la
Write-Host done
