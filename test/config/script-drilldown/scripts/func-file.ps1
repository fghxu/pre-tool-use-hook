# Gap coverage (2026-09-21): a nested -File invocation inside a FUNCTION BODY.
# The engine's own content walk must COLLAPSE it to the bare path (F11) so engine
# step 9b expands it exactly once (design 6.5 / I9b). A second expansion from the
# ScriptBlockAst recursion would hit the HT loop-check and mint a spurious
# 'recursive script invocation detected' ask.
function Refresh-Nested {
    pwsh -NoProfile -File scripts\nested-target.ps1
}
