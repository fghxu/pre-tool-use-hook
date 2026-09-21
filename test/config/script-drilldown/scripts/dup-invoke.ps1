# Author-pass gap coverage (2026-09-21): the SAME target invoked TWICE inside one
# script with DIFFERENT wrapper texts (so the walker's AddResult dedup key
# text<<|>>parent does NOT collapse them, design I10). The first invocation
# expands and claims the HT slot; the second is a re-representation of the same
# file, whose statements are already emitted.
pwsh -NoProfile -File scripts\nested-target.ps1
pwsh -File scripts\nested-target.ps1
