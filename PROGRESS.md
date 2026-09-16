## Goal
Maintenance mode: the PreToolUse safety hook (local classifier + llm_second_opinion cross-check) is feature-complete. Current work = fixing production mis-classifications and extending config coverage for new tools.

## Current Step
(none — rg read-only config fix applied to config.local.json; live config loads clean, all rg forms allow/read_only)

## rg (ripgrep) read-only: wrong-mechanism config entry fixed (2026-09-15, DONE, live config verified)
- User report: production log 2026-09-15 16:46:52 — `rg "stage\('|^###[0-9]+\." "c:\temp\file.txt" "c:\temp\file2.md"` forced ask (tier=unclassified, "unknown command"). LLM said read-only but check_blindspot kept the local ask.
- Clarified for user: the log's "Pipeline: rg … -> ^###[0-9]" text is a COSMETIC display fallback in Classifier.ps1 (~line 728) that naively splits the raw string on `|` for human-readable annotation only — it does NOT affect the decision. Split-Commands (quote-aware) correctly yields 1 segment, IsPipeline=False. Verified by feeding the exact command through Get-CommandDomain/Split-Commands/Resolve-Command (no rg executed).
- User's first attempt was WRONG and BROKE THE HOOK: added `parameter_commands.rg = { aliases:["rg.exe"], default:"read-only" }` to config.local.json. ConfigLoader.ps1:484 validates that every parameter_commands entry has a NON-EMPTY rules array and THROWS on load; Hook.ps1 exits 2 on any config error => EVERY command hard-blocks (not just rg). parameter_commands is the per-parameter mechanism (curl/python) and cannot express "always read-only".
- Fix (config.local.json, Linux domain): removed the broken parameter_commands.rg entry; added a read_only pattern `{ "name": "rg", "patterns": ["rg *","rg","rg.exe *","rg.exe"], "description": "ripgrep search (read-only)" }` next to grep.
- Verified: config.local.json loads+validates clean; exact production command + `rg pattern file` + `rg --version` + `rg.exe foo bar` all => allow/read_only; grep regression still allow. Temp diag/verify scripts removed.
- Note: this is a live-config-only change (no code, no test-suite impact). rg is read-only in ALL forms so a read_only pattern is the correct mechanism (not parameter_commands).

## LLM verdict parser: stray double-quote in prose -> unusable (2026-09-15, DONE, all suites green 1256/1256, +3 new)
- User report: production log 2026-09-15 14:00:24 — a purely read-only `Select-String ... | Select-Object` command was forced to ask. Local said allow (read_only ×2), LLM answered `{"modifying":[]}` (read-only), but the response parsed as verdict=unusable -> fail-closed ask.
- Root cause: ConvertFrom-BalancedJsonObject (src/LlmReview.ps1) tracks string state using DOUBLE quotes only. The LLM's analysis prose echoed a command containing `'rg "stage'` — a double-quote inside single-quoted text. That stray `"` flipped the scanner into permanent "inside string" mode, so the valid `{"modifying":[]}` glued at the end was treated as string content (depth never incremented) -> 0 candidate objects -> Layer 3.5a chatty-model rescue found nothing -> unusable. Probe confirmed: exact raw => 0 objects/unusable; same raw with the stray `"` removed => 1 object/read-only(recovered).
- Fix (src/LlmReview.ps1, ConvertFrom-BalancedJsonObject): when the quote-aware primary scan finds ZERO objects, run a second quote-blind balanced-brace scan (count {/} depth, ignore quotes) as fallback. Conservative: fires only on zero candidates, never overrides a successful quote-aware extraction. Candidates still pass ConvertFrom-Json + Test-ModifyingArray schema validation in Layer 3.5a, so prose fragments are rejected — the scanner only proposes, the JSON parser disposes. Rescued verdicts stay Recovered=$true.
- Tests: 3 new LlmParser-* cases in test/config/llm-review/Run-Tests.ps1 $parserCases — StrayDqProseGluedRO (read-only rescue), StrayDqProseGluedMod (modifying rescue idx 2), StrayDqNoJson (safety guard: stray `"` but no JSON/token must stay unusable). RED confirmed 2/3 failing pre-fix (the guard already passed); GREEN 38/38 post-fix.
- Full pass: 1256/1256 (all 15 suites, zero regressions).

## [pscustomobject]@{...} in Invoke-Command -ScriptBlock: phantom unclassified fix (2026-09-15, DONE, all suites green 1247/1247, +5 new)
- User report: production log from another machine (2026-09-03) showed a purely read-only command (`Invoke-Command -Session ... -ScriptBlock { [pscustomobject]@{ Test-Path ...; Get-Service ... } }`) decomposed into 8 sub-commands, two of which were `unclassified` (the raw `[pscustomobject]@{...}` text), forcing an unnecessary ask. LLM second-opinion said read-only but "LLM never downgrades" kept the local ask.
- Root cause: double-extraction. The AST walker (`Get-PowerShellCommands`) correctly decomposes the ScriptBlock into its constituent cmdlet invocations (Test-Path, Get-Service) and treats `[pscustomobject]@{...}` as a data expression (hashtable literal), NOT a command. But `Find-NestedCommands` (regex) ALSO matches `Invoke-Command ... -ScriptBlock { ... }` and dumps the entire ScriptBlock content as a raw "command" text, then re-splits it — producing phantom entries that fall through to "unknown command" (tier=unclassified).
- Fix (src/Classifier.ps1, Invoke-Classify combine step): when AST extraction succeeds (`$astCommands.Count -gt 0`), do NOT append `$nestedCommands`. The AST walker already handles all wrapper cases natively (Get-AstWrapperInnerCommands + ScriptBlockAst recursion). `Find-NestedCommands` is a regex fallback for when AST parsing is unavailable; when AST succeeds it only adds phantom entries from data expressions. Fallback paths (AST failed / safe-expressions / no-AST) unchanged.
- Tests: new suite test/config/live/test-cases.pscustomobject-scriptblock.xml (5 cases): exact log repro, simpler form, modifying-inside-hashtable (still asks), nested pwsh -Command inside [pscustomobject], [pscustomobject] + pipeline. RED confirmed 4/5 failing pre-fix; GREEN 5/5 post-fix.
- Full pass: 1247/1247 (all 15 suites, zero regressions).

## (Archived) Earlier history (pre-2026-09-15)
- All entries before 2026-09-15 (July-August: strictness_gated + per-domain strictness, tool-gate v2 / system_paths absolute, local-vs-generic config split, DSH wiring, ask_notification, check_blindspot, LLM second-opinion phases I-III, parser/verb/static-allowlist fixes, security audits) were removed from this file on 2026-09-15 to keep it current. Details live in the user's PROGRESS.md backup and in git history (PROGRESS.md was committed with each change).

## Next Steps
- (none pending — rg read-only config fix verified live; LLM-parser + pscustomobject fixes committed)
- Optional: pin `rg` read-only with a TDD case in the live suite (today it is covered only by the config.local.json entry).

## Blockers / Notes
- None. Live hook reads config.local.json via PRETOOLHOOK_CONFIG_PATH; it loads clean and all rg forms classify allow/read_only.
