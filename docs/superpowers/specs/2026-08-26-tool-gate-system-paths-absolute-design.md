# strictness_gated_tool_name v2 + tool_name_modifying_strictness — design
<!-- 2026-08-26. Status: AGREED (user-confirmed), not yet implemented. -->

## Problem

`strictness_gated_tool_name` (2026-08-26 v1) lets a tool skip classification entirely
in normal/loose global mode. The skip happens in `Test-ToolNameFilter` (Classifier.ps1,
STEP 0), BEFORE any path policy runs — so a gated file tool writing to a `system_paths`
target (`C:\Windows\…`, `/etc/…`) is silently allowed. Same hole exists for
`ignore_tool_name`: an ignored tool carrying a path payload is never path-checked.

**Requirement (user, 2026-08-26): `system_paths` is absolute. No tool — intercepted,
gated, or ignored — may write to a `system_paths` target without an ask. No exceptions.**

## Decisions (user-confirmed)

1. **Scope:** the never-bypass-`system_paths` rule applies to BOTH
   `strictness_gated_tool_name` and `ignore_tool_name`. Any tool whose payload yields a
   target path is checked against `system_paths` regardless of which list it sits in.
2. **New knob:** `tool_name_modifying_strictness` = `strict | normal | loose`,
   governs gated tools. Default `normal`. The `loose` value carries an IMPORTANT
   eye-catching warning in config (allows all non-system writes).
3. **Inheritance:** the effective gate mode =
   `strict` if EITHER `global_modifying_strictness` OR `tool_name_modifying_strictness`
   is `strict`; otherwise the value of `tool_name_modifying_strictness`.
   Global `loose` NEVER loosens the tool gate (it falls back to whatever
   `tool_name_modifying_strictness` says).

   | global \ tool-name | strict | normal | loose  |
   |--------------------|--------|--------|--------|
   | **strict**         | strict | strict | strict |
   | **normal**         | strict | normal | loose  |
   | **loose**          | strict | normal | loose  |

4. **Gate behavior by effective mode** (for a tool in `strictness_gated_tool_name`):

   | Mode     | system_paths | foreign (not editable, not CWD) | editable / CWD | path unextractable |
   |----------|--------------|----------------------------------|----------------|--------------------|
   | strict   | ask          | ask                              | allow          | ask (fail-closed)  |
   | normal   | ask          | allow                            | allow          | allow (fail-open)  |
   | loose    | ask          | allow                            | allow          | allow (fail-open)  |

   `system_paths` → ask in EVERY mode, including loose. This is the absolute rule.
   Note the difference from v1: in strict mode a gated tool now behaves like an
   intercepted path tool (path policy decides), but using the tool-name strictness
   rather than the global one.

5. **ignore_tool_name:** tools stay fully skipped EXCEPT that any payload path that
   resolves into `system_paths` → ask. Non-system paths stay skipped (allow) in every
   mode — ignored tools are an explicit allow-list for non-system writes.

6. **Path sources:** paths come from `path_tool_mapping` (exact dot-path extraction,
   incl. the `[*]` array form). For `apply_patch` and `edit_files`, whose payloads embed
   paths in patch TEXT rather than a JSON field, do BEST-EFFORT extraction: scan the
   patch text for absolute-path-looking tokens and check each against `system_paths`.
   If NO path can be extracted (tools like `run_task`, `kill_terminal`,
   `create_and_run_task` — no file target in the payload), the rule above applies:
   strict → ask, normal/loose → allow. ("if no absolute path can be matched, then we
   can pass it" — user, qualified by the unextractable row above.)

## Implementation sketch

- `ConfigLoader.ps1` / `Test-ConfigSchema`:
  - validate optional `tool_name_modifying_strictness` ∈ {strict, normal, loose};
    default `normal` (Add-Member when absent).
  - existing `strictness_gated_tool_name` validation (array + no overlap with
    intercept/ignore) unchanged.
- `Classifier.ps1`:
  - `Test-ToolNameFilter` v1 semantics (pure skip) replaced: gated tools no longer
    return `skip` blindly. STEP 0 becomes:
    - ignored tool with extractable path(s) → `system_paths` check → ask or skip.
    - ignored tool without extractable path → skip (unchanged).
    - gated tool → new `Resolve-ToolGate` helper (below) → ask / skip / classify.
  - New helper `Resolve-ToolGate -ToolName -RawInput -Config`:
    - compute effective mode (table above).
    - extract path(s): `path_tool_mapping` exact fields; patch-text scan for
      `apply_patch`/`edit_files`; none → unextractable row.
    - for each path: canonicalize (existing `ConvertTo-CanonicalWritePath`) then
      `$resolved -match $Config._systemPathRegex` → ask.
    - strict mode additionally: editable/CWD check (existing `Test-EditableOrCwd`);
      anything else → ask.
    - any ask → return ask result (worst-case-wins, like the path branch); else
      skip (allow) for gated tools in normal/loose, or classify in strict when the
      tool is NOT a path tool (command tools in the gated list still classify).
- Path-policy reuse: `Resolve-PathPolicy` itself is NOT reused directly because it
  reads the GLOBAL strictness; the gate implements its own ladder using the shared
  canonicalizer + `_systemPathRegex` + `Test-EditableOrCwd`.

## Testing

Extend `test/config/tool-gate/` (Run-Tests.ps1 + fixtures):
- per-mode × path-type matrix for gated tools (system/foreign/editable/CWD/unextractable).
- ignored tool with a `system_paths` path payload → ask (add a fixture tool name with a
  path mapping that sits in `ignore_tool_name`).
- `tool_name_modifying_strictness` validation: bad value throws; absent defaults normal.
- `apply_patch`/`edit_files` patch-text path extraction: system path in patch → ask.
- global loose + tool normal ⇒ normal behavior (inheritance pinning); global strict +
  tool loose ⇒ strict.
- Regression: existing live suites must stay green. NOTE: with the absolute
  `system_paths` rule, some v1-era expectations change — a gated file tool to a
  system path now ASKS in every mode. The trustedpattern/fullpipe suites were
  re-based onto Copilot file tools (create_file/replace_string_in_file) in v1 and
  keep passing ONLY if those Copilot tools keep their intercept behavior; if the live
  config moves them into the gated list (it currently does), the suites' fixtures must
  keep at least one intercepted path tool or the system-path cases need re-pointing at
  a still-intercepted path tool.

## Docs to update

- `docs/config-json-guide.md` §6 (tool gate section).
- `README.md` (key table + intercept/ignore/gated section).
- `config.json` comments (`_comment_strictness_gated_tool_name`, new
  `_comment_tool_name_modifying_strictness` with the IMPORTANT loose warning).
- `PROGRESS.md`.
