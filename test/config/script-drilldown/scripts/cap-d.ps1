# cap-d.ps1 - fourth in the chain; the cap (3) is hit when trying to expand this one.
# It must EXIST on disk (the engine's Test-Path runs before the cap check), but its
# content is never read because step 5 (cap) fires first.
Write-Host d
