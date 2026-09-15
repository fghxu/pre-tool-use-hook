# tool-gate test suite — strictness_gated_tool_name
#
# Tests the strictness-gated tool-name gate (2026-08-26 feature):
#
#   config key:  strictness_gated_tool_name  (array of tool names, OPTIONAL)
#
#   Semantics (mirrors the per-domain strictness_gated command tier):
#     global_modifying_strictness = normal | loose -> gated tools are treated
#         like ignore_tool_name (skipped, silently allowed, IsSkipped=true)
#     global_modifying_strictness = strict         -> gated tools are treated
#         like intercept_tool_name (classified normally: command tiers for
#         command tools, path policy for file tools)
#
#   Source of strictness: global_modifying_strictness ONLY. Tool gating happens
#   before domain routing, so per-domain commands.<domain>.modifying_strictness
#   never applies here.
#
#   Validation:
#     - key present but not an array -> Load-Config throws
#     - name in BOTH intercept_tool_name and strictness_gated_tool_name
#       -> Load-Config throws (overlap error; keep the lists disjoint)
#     - name in BOTH ignore_tool_name and strictness_gated_tool_name
#       -> Load-Config throws (overlap error)
#
# Fixtures (same folder, per CLAUDE.md: never the live config.json):
#   config.normal.json   global_modifying_strictness = normal, gated list = [Write]
#   config.loose.json    global_modifying_strictness = loose,  gated list = [Write]
#   config.strict.json   global_modifying_strictness = strict, gated list = [Write]
#   config.badtype.json  strictness_gated_tool_name = "Write" (string)  -> must throw
#   config.overlap.json  Write in intercept AND gated lists             -> must throw
#   config.ignoreoverlap.json  Write in ignore AND gated lists          -> must throw
#
# Run:
#   pwsh -NoProfile -File test/config/tool-gate/Run-Tests.ps1
# Exit code 0 = all green, 1 = at least one failure.
