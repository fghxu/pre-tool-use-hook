# calls-nested.ps1 - invokes another script via nested -File (walker COLLAPSES it to the
# bare path per F11; engine step 9b expands that path per RUL-1). nested-target is read-only.
pwsh -NoProfile -File scripts\nested-target.ps1
Write-Host n
