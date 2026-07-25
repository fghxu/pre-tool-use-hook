# Path-Branch: File-Tool Writes Observe system_paths / editable_paths — Design

**Date:** 2026-07-25
**Status:** Approved (user sign-off in brainstorming session)
**Branching:** implementation branches from `master` (which now contains the agent-command-guidelines work).

## 1. Background and Problem

File-tool gating was built config-only (commits through `14212f2`): `Write`/`Edit`/`MultiEdit`/`NotebookEdit` + Copilot file tools are intercepted, `tool_name_mapping` extracts the file path, and `trusted_pattern`/`untrusted_pattern` decide. It works (60 pinned cases, suite 61/66) but has three structural defects:

1. **Duplication / drift** — path policy lives twice: `system_paths`/`editable_paths` (redirects) and trusted/untrusted regexes (file tools). Add a writable root in one place, the other silently disagrees.
2. **Asymmetry** — `echo x > /home/f` prompts (redirect policy) while `Write /home/user/f` allows (zero-command fallback). Same target, different verdict.
3. **Residual holes** (pinned `[RESIDUAL]` in test-cases.trustedpattern.xml): `/usr/bin` and `/home` writes allow; relative paths allow; `\\?\` prefixed paths allow; traversal handled by regex rather than real canonicalization.

Root cause: `system_paths`/`editable_paths` are only consulted by the Parser's **redirect** analysis. File-tool paths never reach them.

## 2. Locked Decisions (from brainstorming)

| # | Decision | Choice |
|---|---|---|
| D1 | Default for file-tool writes matching neither list | **ask** (fail-safe; closes the holes) |
| D2 | Redirect analysis refactor | **share** the canonicalize+check function (one implementation, two call sites) |
| D3 | Path entries in trusted/untrusted_pattern | **retire** once the branch is green (trusted/untrusted return to command-text shortcuts) |
| D4 | Executable-extension writes inside editable roots | **location-only** — no exe guard on the write side; execution is guarded command-side |
| D5 | **No `C:\git` in editable_paths** | writability = `editable_paths` + **CWD subtree** — the pre-existing rule (`Test-EditableOrCwd`: "under the current working directory — always editable, every strictness mode"). Writes to *other* projects ask. |
| D6 | `modifying_strictness` | preserved verbatim — the path-branch reuses the existing helper and ladder ordering (CWD always editable in every mode; loose/normal fallbacks unchanged) |

## 3. Design

### 3.1 New shared function: `Resolve-PathPolicy`

Extracted from today's redirect ladder (`Test-RedirectionTarget` steps 4a–4d + `Test-EditableOrCwd`), generalized:

```
Resolve-PathPolicy(path, cwd, config) → { Decision, Risk, Reason }
  1. Canonicalize (see 3.2)
  2. discard targets (/dev/null, NUL)        → allow (none)     [redirect-only case]
  3. temp paths (/tmp, %TEMP%, …)            → allow (low)      [existing ladder]
  4. system_paths match                      → ask  (high)
  5. under CWD                               → allow (low)  — every strictness mode
  6. editable_paths match                    → allow (low)  — per existing strictness semantics
  7. loose mode                              → allow (low)
  8. normal mode (editable not enabled)      → allow (low)
  9. default                                 → ask  (medium)  ← D1: was zero-command allow for file tools
```

Steps 2–8 are today's exact redirect ladder, so **redirect behavior is byte-identical by construction**; step 9 is the only behavior change, and it applies where file tools previously fell through to the zero-command allow.

### 3.2 Canonicalization

`Test-EditableOrCwd` already does most of it (relative→CWD anchor, `GetFullPath` `..` collapse, separator unify, case-fold, `~` home special-case). `Resolve-PathPolicy` adds:

- `\\?\` extended-length prefix strip (kills the anchor-bypass residual)
- applied to **all** inputs (file-tool paths and redirect targets), unifying today's two slight variants

### 3.3 Classifier integration (new step)

In `Invoke-Classify`, after extraction, before the trusted gate:

```
if tool_name ∈ config.path_tool_mapping:
    paths = extract via mapped field (all of them for list payloads: edit_files, apply_patch)
    extraction failure → ask ("file-tool path not extractable")   # fail-safe, no heuristic on content
    decisions = paths | Resolve-PathPolicy
    any ask → ask (worst-case wins, same as chained commands); else allow
```

Command tools (`Bash`, `PowerShell`, …) skip this entirely — their flow is unchanged.

### 3.4 Config changes

**Add:**

```json
"path_tool_mapping": {
  "Write": "tool_input.file_path",
  "Edit": "tool_input.file_path",
  "MultiEdit": "tool_input.file_path",
  "NotebookEdit": "tool_input.notebook_path",
  "create_file": "tool_input.filePath",
  "replace_string_in_file": "tool_input.filePath",
  "multi_replace_string_in_file": "tool_input.filePath",
  "insert_edit_into_file": "tool_input.filePath",
  "edit_notebook_file": "tool_input.filePath",
  "create_new_jupyter_notebook": "tool_input.filePath",
  "create_directory": "tool_input.dirPath"
}
```

- Those 11 entries are **moved out of `tool_name_mapping`** (a path is not a command).
- `edit_files` / `apply_patch` stay in `intercept_tool_name`; their payloads carry path lists — the branch iterates all paths.
- **No change to `editable_paths`/`system_paths`** (D5 — no `C:\git`).

**Retire (D3):**
- `trusted_pattern`: the 3 root patterns (`[Tt][Ee][Mm][Pp]`, `/[Tt][Mm][Pp]/`, `C:\git`) — replaced by editable_paths + CWD.
- `untrusted_pattern`: Windows catch-all, both traversal guards (canonicalization supersedes), both linux system-dir patterns (`system_paths` covers them — including fixing the `/usr/bin` write residual, since `system_paths` has `/usr/`).

**Keep:**
- `trusted_stuff`/`untrusted_stuff` legacy scaffolding.
- The **untrusted exe pattern** (`exe|bat|cmd|com|msi|scr` outside System32/Program Files): it is a *command-side* guard (`Bash C:\temp\tool.exe` never touches the path-branch; without it, zero-command would allow).

### 3.5 Behavior changes (intended)

| Input | Before | After |
|---|---|---|
| `Write <under CWD>` | allow (trusted git root) | allow (CWD rule) |
| `Write C:\git\other-project\x` | allow (trusted git root) | **ask** (D5 — other projects) |
| `Write C:\temp\x` | allow (trusted temp) | allow (editable_paths) |
| `Write C:\Windows\x` | ask (untrusted) | ask (system_paths) |
| `Write /usr/bin/evil` | allow `[RESIDUAL]` | **ask** (system_paths `/usr/`) |
| `Write /home/user/x` | allow `[RESIDUAL]` | **ask** (default) |
| `Write notes.txt` (relative) | allow `[RESIDUAL]` | resolved vs CWD → typically allow |
| `Write \\?\C:\Windows\x` | allow `[RESIDUAL]` | **ask** (canonicalized → system_paths) |
| `Write C:\git\..\Windows\x` | ask (traversal regex) | ask (canonicalized → system_paths) |
| `Write C:\temp\evil.exe` | ask (exe pattern) | **allow** (D4 — location-only; execution stays guarded command-side) |
| `Bash C:\temp\tool.exe` | ask (exe pattern) | ask (unchanged — exe pattern kept) |
| redirects (`>`/`>>`) | today's ladder | **byte-identical** (shared ladder) |

### 3.6 Tests

- The 60 trustedpattern cases migrate to the new policy. `C:\git` expectations re-key from "trusted root" to "under CWD": the suite runs with `-Cwd` pinned (TestRunner already supports `-Cwd`), documented in the suite header. Cases for *other*-project paths flip to ask (D5); `[RESIDUAL]` cases flip allow→ask and become the remediation proof; `C:\temp\evil.exe` flips ask→allow (D4).
- New cases: canonicalization set (`..`, `\\?\`, relative-vs-CWD, forward slashes, `~`), `edit_files`/`apply_patch` multi-path (one bad → ask), `create_new_workspace`.
- Full 9-suite differential: redirect-normal/strict and all others **byte-identical** (the refactor must not move redirect behavior); trustedpattern changes only by the table in 3.5.

## 4. Risks

- **Redirect refactor blast radius** — mitigated by reusing the exact ladder and the byte-identical differential requirement.
- **Default-ask UX change** — first write to a new location prompts; workflow is "approve once, or add the root to editable_paths." Deliberate (D1).
- **Multi-path Copilot payloads** (`edit_files`, `apply_patch`) — real payload shapes must be captured from logs and pinned in fullpipe-style tests; mappings are best-guess until then.

## 5. Out of Scope

- Hard **deny** (vs ask) for system paths.
- Changing the zero-command fallback itself (command-side behavior stays).
- Command-side executable handling beyond keeping the untrusted exe pattern.
- Removing the `C:\git`-is-repo assumption from anywhere outside the CWD rule.

## 6. Success Criteria

1. File-tool writes are decided solely by `system_paths`/`editable_paths`/CWD/strictness — no path regexes remain in trusted/untrusted except the legacy scaffolding and the command-side exe pattern.
2. All `[RESIDUAL]` holes in §1 ask (proven by flipped tests).
3. Redirect behavior byte-identical across all suites; full differential green.
4. `docs/config-json-guide.md` and `docs/trusted-untrusted-patterns.md` updated to match the unified policy.
