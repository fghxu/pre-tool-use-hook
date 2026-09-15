# Update — August 26, 2026: `tool_name_modifying_strictness` + `strictness_gated_tool_name` — `system_paths` Is Now Absolute

## Requirement / Spec

Two user requirements landed the same day (v1 then v2):

1. **v1 — a strictness-gated tool tier.** Add a third tool list alongside
   `intercept_tool_name` / `ignore_tool_name` so selected tools (e.g. `Write`, `Edit`,
   `create_file`) can be treated like the ignore list (silently skipped, no prompts) in
   everyday modes, and classified only in strict mode — the tool-level analogue of the
   per-domain `strictness_gated` command tier.

2. **v2 — `system_paths` must be absolute.** *"No tool can be an exception — always
   observe the rules of `system_paths`; nothing may bypass the forbidden-to-write
   `system_paths`."* The v1 design skipped gated tools **before** path policy ran, so a
   gated `create_file` writing to `C:\Windows\…` was silently allowed. That hole had to
   close: no tool — intercepted, gated, **or ignored** — may write to a `system_paths`
   target without an ask.

Design decisions (user-confirmed):

- A new knob **`tool_name_modifying_strictness`** (`strict | normal | loose`, default
  `normal`) governs gated tools — *not* the global value directly.
- **Inheritance:** effective gate mode = `strict` if **either** `global_modifying_strictness`
  **or** `tool_name_modifying_strictness` is `strict`, else the tool value. Global `loose`
  **never** loosens the tool gate.
- **Scope:** the absolute `system_paths` rule applies to gated tools **and** ignored tools.
- **Path sources:** exact extraction via `path_tool_mapping`; for `apply_patch` /
  `edit_files` (paths embedded in patch *text*, not a JSON field), best-effort extraction
  from the patch text. Tools with no extractable path (`run_task`, `kill_terminal`) pass
  in normal/loose and ask in strict (fail-closed).

Full spec: [docs/superpowers/specs/2026-08-26-tool-gate-system-paths-absolute-design.md](../superpowers/specs/2026-08-26-tool-gate-system-paths-absolute-design.md)

## Behavior

Effective gate mode (tool in `strictness_gated_tool_name`):

| global \ tool-name | strict | normal | loose  |
|--------------------|--------|--------|--------|
| **strict**         | strict | strict | strict |
| **normal**         | strict | normal | loose  |
| **loose**          | strict | normal | loose  |

Gate behavior by effective mode:

| Mode     | system_paths | foreign (not editable/CWD) | editable / CWD | path unextractable |
|----------|--------------|-----------------------------|----------------|--------------------|
| strict   | **ask**      | ask                         | allow          | ask (fail-closed)  |
| normal   | **ask**      | allow                       | allow          | allow              |
| loose    | **ask**      | allow                       | allow          | allow              |

`system_paths` → **ask in every mode, including loose** — this is the absolute rule.
Ignored tools stay skipped **except** when a payload path resolves into `system_paths` → ask.

## Design / Change on the Current Architecture

The tool gate (`Test-ToolNameFilter` in [src/Classifier.ps1](../../src/Classifier.ps1)) previously
returned a pure name verdict (`skip` / `classify` / `unknown`) and the gated list just mapped to
`skip` or `classify` on the **global** strictness — with no path inspection at all. The change
makes the gate **path-aware**:

- **`Test-ToolNameFilter`** — gated tools now return a new verdict `gated` (instead of
  `skip`/`classify`) so the caller can run the path-aware gate with the raw payload. Ignored
  tools still return `skip`, but `Invoke-Classify` re-checks their payload paths first.
- **New helpers in Classifier.ps1:**
  - `Get-ToolGatePaths` — candidate write-target paths: exact `path_tool_mapping` fields
    (incl. the `[*]` array form) + best-effort absolute-path scan of the patch text for
    `apply_patch` / `edit_files`.
  - `Test-SystemPathsOnly` — the **absolute** rule: canonicalize each candidate
    (`ConvertTo-CanonicalWritePath`) and match against `_systemPathRegex`; any hit → ask.
  - `Resolve-ToolGate` — the effective-mode ladder: computes the mode (global + tool
    strictness), enforces `system_paths` first, then per-mode: strict = full path policy
    (editable/CWD allow via `Test-EditableOrCwd`, foreign ask, unextractable asks);
    normal/loose = skip (allow) for non-system paths, unextractable allows.
- **`Invoke-Classify` STEP 0** — the `skip` branch now path-checks ignored tools before
  allowing; a new `gated` branch runs `Resolve-ToolGate`. Gated tools are decided
  **entirely by the gate** (`skip` / `ask` / strict-`allow`) — they never fall through to
  the command tiers or the generic file-tool path branch.
- **[src/ConfigLoader.ps1](../../src/ConfigLoader.ps1)** — validates
  `tool_name_modifying_strictness` (`strict|normal|loose`, throws on a bad value, defaults
  `normal` when absent). The existing `strictness_gated_tool_name` validation (array +
  no overlap with `intercept_tool_name` / `ignore_tool_name`) is unchanged.

### Path-policy reuse note

`Resolve-PathPolicy` itself is **not** reused directly because it reads the *global*
strictness for its fallbacks; the gate implements its own ladder on top of the shared
canonicalizer (`ConvertTo-CanonicalWritePath`), `_systemPathRegex`, and
`Test-EditableOrCwd`, using the **tool-name** strictness instead.

## Config

```jsonc
"tool_name_modifying_strictness": "normal",   // strict | normal | loose (default normal)
"strictness_gated_tool_name": [ "Write", "Edit", "MultiEdit", "NotebookEdit" ]
```

- Effective gate mode = `strict` if either the global or the tool value is `strict`.
- The `loose` value carries an **IMPORTANT** warning in `config.json`: it lets gated file
  tools write anywhere *except* `system_paths` (which still always asks).

## Testing

Extended [test/config/tool-gate/](../../test/config/tool-gate/Run-Tests.ps1) from 13 → **32**
checks: v1 validation/unit/fullpipe + v2 matrix — `system_paths` asks in every mode,
foreign/editable/unextractable per mode, ignored-tool `system_paths` ask, `apply_patch`
patch-text extraction, inheritance pinning (global-loose+tool-strict, global-strict+tool-loose),
bad-value + absent-key defaults. Fixtures gained `tool_name_modifying_strictness`, an ignored
path tool (`IgnorePathTool`), a no-path gated tool (`NoPathTool`), and `apply_patch`.

The two live suites that pinned the old file-tool behavior
([test-cases.trustedpattern.xml](../../test/config/live/test-cases.trustedpattern.xml),
[test-fullpipe.xml](../../test/config/live/test-fullpipe.xml)) were re-based onto the
still-intercepted Copilot file tools (`create_file`, `replace_string_in_file`, …) — same
`Resolve-PathPolicy` ladder, coverage preserved.

**Full pass: 1214/1214.**

## Related: local vs generic config split (same day)

To develop against a personal live config while keeping the tracked `config.json` generic,
the hook's existing `PRETOOLHOOK_CONFIG_PATH` env override (checked before the repo-root
`config.json` in [src/Hook.ps1](../../src/Hook.ps1#L73)) is used: personal settings live in a
git-ignored `config.local.json`. See [docs/INSTALL.md](../INSTALL.md) Step 3.
