# trusted_pattern / untrusted_pattern — Deep Dive

**Companion to:** `docs/config-json-guide.md`. This document explains the trusted/untrusted gate: where it runs, how matching works, what each current entry achieves, and how to add entries safely.

**Important (post path-branch, 2026-07-25):** these two lists now gate **command text only**. File-tool writes (`Write`/`Edit`/Copilot file tools) are decided *earlier* by the path-branch (`path_tool_mapping` → `Resolve-PathPolicy`), which reads `system_paths`/`editable_paths`/CWD directly. The path-related regexes that used to live here (temp/git roots, catch-all, traversal guards) have been **retired** — see §6 for the history and §4 for the new way to add a writable root.

---

## 1. Where the gate runs

```
PreToolUse payload
  └─ 1. Tool gate        intercept_tool_name / ignore_tool_name        (Classifier.ps1)
  └─ 2. Extraction       tool_name_mapping / path_tool_mapping          (HookAdapter.ps1)
  └─ 2.5 PATH-BRANCH     if tool in path_tool_mapping → Resolve-PathPolicy  (Classifier.ps1 STEP 1.5)
                          (system_paths → ask; editable_paths/CWD → allow; default → ask)
                          RETURNS EARLY for file tools — never reaches step 3
  └─ 3. TRUSTED GATE     untrusted_pattern → ask; trusted_pattern → allow   ◄ THIS DOC
                          (sees the command text from step 2)
  └─ 4. Full pipeline    chunking, domains, verbs, command DB,
                         redirects, AST arbiter, zero-command fallback
```

For **command tools** (`Bash`, `PowerShell`, terminal tools), step 2 extracts the command text and the trusted gate (step 3) sees it. For **file tools** (in `path_tool_mapping`), step 2.5 decides on the file path and returns — the trusted gate never runs for them.

## 2. Matching semantics (read before touching anything)

- Matching is `$regex.IsMatch(wholeString)` — a **substring search over the ENTIRE command string**, executed **before** the script is chunked into sub-commands. Compilation options: `Compiled | Singleline` (`.` matches newlines), **no** `IgnoreCase`.
- Without `^`/`$` anchors, a pattern matches *anywhere* in a multi-line command.
  - **Unanchored trusted = fail-open disaster.** A trusted entry `temp` would match `"cd c:\temp\; remove-item a.txt"` and allow the *whole* command, `remove-item` included.
  - **Unanchored untrusted = noisy but safe** (over-prompts; cannot under-block).
- If neither list matches, the command falls through to the full pipeline, where chunking *does* happen: `"cd c:\temp\; remove-item a.txt"` → `cd c:\temp` (read-only) + `remove-item a.txt` (modifying high) → overall **ask**.
- Check order: **untrusted first, trusted second.** Untrusted wins on overlap.

## 3. Current entries (post-retirement)

### `untrusted_pattern` (any match → ask)

| # | Pattern (JSON-decoded) | Goal | Fires on | Does NOT fire on |
|---|---|---|---|---|
| 1 | `^untrusted_stuff.*$` | Legacy test scaffolding. | Nothing real. | Everything. |
| 2 | `^untrusted_stuff\s+$` | Legacy test scaffolding. | Nothing real. | Everything. |
| 3 | `^[A-Za-z]:[/\\](?!.*(?i:System32|Program Files)).*(?i:\.(exe|bat|cmd|com|msi|scr))\b.*$` | **Command-side unknown-executable asker.** A bare full-path executable outside the two known binary homes would otherwise hit the zero-command allow. *(File-tool exe writes are NOT affected — the path-branch decides those, location-only.)* | `Bash C:\temp\tool.exe`, `C:\git\repo\run.bat`. | `C:\Windows\System32\tasklist.exe`, `C:\Program Files\…\git.exe` (classify normally). |

### `trusted_pattern` (any match → allow)

| # | Pattern | Goal |
|---|---|---|
| 1 | `^trusted_stuff\s+$` | Legacy test scaffolding. |

That is the entire shipped trusted list. Real command shortcuts (e.g. an opt-in `docker exec comfyui` pattern) are added per-deployment; none ship by default.

## 4. How to add entries (with samples)

### 4.1 Add a command shortcut (trusted, command text)

Example — auto-allow any `docker exec comfyui ...` command:

```json
"trusted_pattern": [
  "^trusted_stuff\\s+$",
  "docker\\s+exec\\s+(?:-\\S+\\s+)?comfyui\\b"
]
```

**Rules you must not break:**
1. Anchor with `^` unless you deliberately want "matches anywhere" (and only ever for untrusted, never trusted).
2. **Never** a catch-all trusted pattern (`.*`, `^(?!…).*$`). Trusted short-circuits the entire classifier — `rm -rf /` would auto-approve.
3. Prefer anchoring + specificity; a loose trusted pattern is a security hole.

### 4.2 Add a blocked command pattern (untrusted)

Example — always prompt for `terraform destroy`:

```json
"untrusted_pattern": [
  "^untrusted_stuff.*$",
  "^untrusted_stuff\\s+$",
  "^terraform\\s+destroy\\b"
]
```

Untrusted additions are fail-safe (worst case = a prompt), but still anchor them or you'll prompt on harmless commands that merely *contain* the target text.

### 4.3 Add a writable root for file-tool writes — use `editable_paths`, NOT a trusted pattern

Pre-path-branch this required a regex in `trusted_pattern` plus matching `untrusted_pattern` edits. **Now it is one line** in `editable_paths`, honored by both redirects and file-tool writes:

```json
"editable_paths": {
  "windows": ["C:\\\\temp\\\\", "D:\\\\temp\\\\", "D:\\\\work\\\\"],
  "linux":   ["/tmp/"]
}
```

No `trusted_pattern`/`untrusted_pattern` change needed. The path-branch (`Resolve-PathPolicy`) checks `editable_paths` and the project CWD automatically.

JSON escaping: regex `\` (one literal backslash) = `\\\\` in JSON; regex classes `\b`, `\s` = `\\b`, `\\s`.

### 4.4 Verify a new entry

Add a test case to `test/test-cases.trustedpattern.xml` (the runner supports per-case tool payloads and `-Cwd`), then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml" -Cwd "C:\git\repo"
# plus the full 9-suite differential — all other suites must stay byte-identical
```

## 5. Why the path patterns were retired (history)

Before the path-branch (commits through `14212f2`), file-tool writes had to be gated by `trusted_pattern`/`untrusted_pattern` regexes because the hook had no other path-policy path for them. That config-only bridge worked but had three defects:

1. **Duplication/drift** — path policy lived twice (`system_paths`/`editable_paths` for redirects; trusted/untrusted regexes for file tools). Adding a root in one place left the other stale.
2. **Asymmetry** — `echo x > /home/f` prompted but `Write /home/f` allowed.
3. **Residual holes** — `/usr/bin` and `/home` writes allowed; relative paths allowed; `\\?\` prefixed paths allowed; traversal handled by regex not real canonicalization.

The path-branch (`Resolve-PathPolicy`, spec `docs/superpowers/specs/2026-07-25-path-branch-design.md`) fixed all three: file-tool paths are canonicalized and checked against `system_paths`/`editable_paths`/CWD directly, defaulting to ask for anything else. The regexes that duplicated this are gone.

## 6. Former residual holes — now fixed by the path-branch

| Former hole | Now |
|---|---|
| `.ps1`/`.sh`/`.py` writes inside/outside roots auto-allowed | Decided by location (editable/CWD → allow, else ask). Execution of such files by a command tool is still governed by the command-side exe pattern + classification. |
| `/usr/bin`, `/usr/sbin` writes allowed | **ask** — `system_paths` includes `/usr/`. |
| `/home/…` writes allowed | **ask** — default-ask for unlisted paths. |
| Relative paths (`notes.txt`) allowed | Resolved against CWD; under-CWD → allow, else ask. |
| `\\?\C:\…` extended prefix bypassed anchors | Prefix stripped during canonicalization → decided by real path. |
| `..` traversal (`C:\git\..\Windows\x`) | Collapsed by `GetFullPath` → `C:\Windows\x` → system → ask. |

The path-branch canonicalization (`ConvertTo-CanonicalWritePath`) and ladder (`Resolve-PathPolicy`) live in `src/Parser.ps1`; the branch is wired in `src/Classifier.ps1` STEP 1.5, gated by `path_tool_mapping` in `config.json`.
