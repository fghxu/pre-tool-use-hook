# Gap coverage (2026-09-21): I7 - a DYNAMIC invocation (& $p) must fail closed.
# The 9b invocation regex excludes '$', so the statement stays plain => unknown => ask.
& $p
Write-Host done
