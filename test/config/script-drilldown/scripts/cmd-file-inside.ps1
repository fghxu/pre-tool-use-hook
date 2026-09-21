# Gap coverage (2026-09-21): design 3.2 'bonus' / 5 GUARD - a '-Command' that
# WRAPS a '-File' invocation. The matcher must refuse to treat the inner '-File'
# as its own (guard: -Command/-c precedes -File), the walker's own -Command branch
# then routes 'pwsh -File scripts\nested-target.ps1' into SITE A, and the target
# expands through the LEGITIMATE recursion (design 3.2) => allow. Without the
# guard the regex's (\S+) arm grabs a garbage path => fail-closed ask.
pwsh -NoProfile -Command "pwsh -NoProfile -File scripts\nested-target.ps1"
Write-Host done
