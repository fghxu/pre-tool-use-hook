# Author-pass gap coverage (2026-09-21): DIRECT self-recursion (design 6.2 step 4,
# the a->a shape, vs the mutual loop-a<->loop-b fixture). The engine claims the
# HT slot when expanding this file, so the dot-source statement hits the loop
# check on re-entry => fail-closed ask.
# NOTE on path semantics: in-script relative paths are anchored to the WORKSPACE
# ROOT ($Config._cwd), mirroring PowerShell's own cwd-relative resolution of
# dot-source/call arguments (pwsh -File does NOT chdir to the script's folder).
# A literal '. .\self-loop.ps1' would resolve NEXT TO THE CWD (not this folder)
# and yield 'script file not found' - which is also the correct runtime outcome.
. scripts\self-loop.ps1
Write-Host self
