# trusted_pattern / untrusted_pattern — Deep Dive

**Companion to:** `docs/config-json-guide.md`. This document explains the trusted/untrusted gate in full: where it runs, how matching works, what each current entry achieves, how to add entries safely, and the known limits.

---

## 1. Where the gate runs

```
PreToolUse payload
  └─ 1. Tool gate        intercept_tool_name / ignore_tool_name   (Classifier.ps1)
  └─ 2. Extraction       tool_name_mapping, else heuristic walk   (HookAdapter.ps1)
  └─ 3. TRUSTED GATE     untrusted_pattern → ask; trusted_pattern → allow   ◄ THIS DOC
  └─ 4. Full pipeline    chunking, domains, verbs, command DB,
                         redirects (editable_paths/system_paths),
                         AST arbiter, zero-command fallback
```

The gate receives **whatever step 2 extracted**:
- `Bash` / `PowerShell` / terminal tools → the **command text**.
- `Write` / `Edit` / `MultiEdit` / `NotebookEdit` / Copilot file tools → the **file path** (because `tool_name_mapping` points at `file_path` / `notebook_path` / `filePath`).

One mechanism therefore serves both command gating and file-write gating.

## 2. Matching semantics (read this before touching anything)

- Matching is `$regex.IsMatch(wholeString)` — a **substring search over the ENTIRE extracted string**, executed **before** the script is chunked into sub-commands. Compilation options: `Compiled | Singleline` (`.` matches newlines), **no** `IgnoreCase`.
- Consequence: without `^`/`$` anchors, a pattern matches *anywhere* in a multi-line script.
  - **Unanchored trusted = fail-open disaster.** A trusted entry `temp` would match `"cd c:\temp\; remove-item a.txt"` and allow the *whole* script, `remove-item` included.
  - **Unanchored untrusted = noisy but safe.** It over-prompts; it cannot under-block.
- If no pattern matches either list, the string falls through to the full pipeline, where chunking *does* happen: `"cd c:\temp\; remove-item a.txt"` → `cd c:\temp` (read-only) + `remove-item a.txt` (modifying high) → overall **ask**.
- Check order: **untrusted first, trusted second.** Untrusted always wins on overlap.

### The zero-command fallback — why the untrusted catch-all is mandatory

The classifier's zero-command/string-constant fallback auto-**allows** a string in which no command is recognized. A **bare file path is such a string**. Therefore, for file-tool writes:

| Path matches… | Decision |
|---|---|
| `trusted_pattern` | allow |
| `untrusted_pattern` | ask |
| **neither** | **allow** (zero-command fallback — *not* ask!) |

This is the reverse of the usual "unknown → ask" intuition and the single most important fact in this document. The untrusted catch-all is what turns "writes outside your writable roots" into prompts.

## 3. Current entries, entry by entry

### `untrusted_pattern` (any match → ask)

| # | Pattern (JSON-decoded) | Goal | Fires on | Deliberately does NOT fire on |
|---|---|---|---|---|
| 1–2 | `^untrusted_stuff.*$`, `^untrusted_stuff\s+$` | Legacy test scaffolding from the trusted-pattern suite design. | Nothing real. | Everything. |
| 3 | `^[A-Za-z]:[/\\].*\.\.[/\\]` | **Windows traversal guard** — stop `C:\git\..\Windows\evil.txt` from inheriting the `C:\git` trust. | Any absolute Windows path with a `..` segment. | Relative paths (`cd ..`). |
| 4 | `^/.*\.\.[/\\]` | **Linux traversal guard** — same for `/` paths. | `/tmp/../etc/x`. | Relative paths. |
| 5 | `^(?!<drive>:\temp\ or C:\git\)[A-Za-z]:[/\\](?!.*(?i:\.(exe|bat|cmd|com|msi|scr))\b).*$` | **Windows catch-all** — any absolute path outside the writable roots asks. Needed because of the zero-command fallback (§2). The exe-extension exclusion lets real binary invocations pass through to normal classification. | `C:\Windows\evil.dll`, `D:\work\notes.txt`, `C:\Users\…` | Trusted roots; exe paths (handled by #6). |
| 6 | `^[A-Za-z]:[/\\](?!.*(?i:System32|Program Files)).*(?i:\.(exe|bat|cmd|com|msi|scr))\b.*$` | **Unknown-executable asker** — closes the hole #5 leaves: unknown exe/bat/cmd paths outside the two known binary homes would otherwise hit the zero-command allow. | `C:\temp\tool.exe`, `C:\git\repo\run.bat`, Write `C:\Windows\notepad.exe`. | `C:\Windows\System32\*.exe`, `C:\Program Files\…\git.exe` — these classify normally (e.g. tasklist → read-only). |
| 7 | `^/(etc|var|boot|sys|proc|opt)/` | **Linux system dirs.** | Writes to `/etc/cron.d/evil`; `/etc/init.d/nginx start`. | `/usr`, `/home` (see residuals). |
| 8 | `^/usr/(?!bin/|sbin/)` | **/usr minus binary dirs.** | `/usr/share/…` writes. | `/usr/bin/grep` executions (so they classify read-only); leaves the `/usr/bin` write hole. |

### `trusted_pattern` (any match → allow)

| # | Pattern | Goal | Fires on | Deliberately does NOT fire on |
|---|---|---|---|---|
| 1 | `^trusted_stuff\s+$` | Legacy test scaffolding. | Nothing real. | Everything. |
| 2 | `^[A-Za-z]:[/\\][Tt][Ee][Mm][Pp][/\\](?!.*(?i:\.(exe|bat|cmd|ps1|msi|dll|com|scr|sh|py|pl|rb|js|jar))\b).*$` | **Windows temp root (any drive)** — file-tool writes into scratch space skip the prompt. Case-tolerant (`C:\TEMP`), slash-tolerant (`C:/temp`). | `Write C:\temp\notes.txt`, `D:\Temp\log.md`. | Executable/script-looking paths — the guard blocks the shortcut so they fall to normal classification (and pattern #6 above asks for real exes). |
| 3 | `^/[Tt][Mm][Pp]/(?!…same guard…).*$` | **Linux `/tmp` root** — same idea. | `Write /tmp/scratch.txt`. | `/tmp/evil.py`. |
| 4 | `^[Cc]:[/\\][Gg][Ii][Tt][/\\](?!…same guard…).*$` | **Project root `C:\git\`** — writes into any repo skip the prompt. | `Write C:\git\repo\file.md`. | `C:\git\repo\run.bat` (guard → normal path → #6 asks). |

Design shape to notice: trusted = a **small explicit whitelist of writable roots**; untrusted = a **catch-all over the infinite remainder** plus targeted executable/traversal askers. You never enumerate all folders — you enumerate only the roots you trust, and the catch-all defaults everything else to ask.

## 4. How to add entries (with samples)

### 4.1 Add a writable root (example: `D:\work`)

Copy the temp-root shape exactly, changing only the drive and folder name — **keep the executable guard verbatim**:

```json
"^[Dd]:[/\\\\][Ww][Oo][Rr][Kk][/\\\\](?!.*(?i:\\.(exe|bat|cmd|ps1|msi|dll|com|scr|sh|py|pl|rb|js|jar))\\b).*$"
```

Also update the untrusted catch-all's exclusion lookahead so the new root isn't asked:

```
(?![A-Za-z]:[/\\][Tt][Ee][Mm][Pp][/\\]|[Cc]:[/\\][Gg][Ii][Tt][/\\]|[Dd]:[/\\][Ww][Oo][Rr][Kk][/\\])
```

JSON escaping cheatsheet: regex `\` (one literal backslash) = `\\\\` in JSON; character class `[/\\]` = `"[/\\\\]"`; regex classes like `\b`, `\s` = `\\b`, `\\s`; case-insensitive group = `(?i:…)`.

### 4.2 Add a blocked system dir (example: `C:\Secrets`)

Add to `untrusted_pattern` (no guard needed — it's an ask):

```json
"^[A-Za-z]:[/\\\\][Ss][Ee][Cc][Rr][Ee][Tt][Ss][/\\\\]"
```

### 4.3 Rules you must not break

1. **Anchor everything** with `^` (and usually `.*$`). No bare substrings.
2. **Never** a catch-all *trusted* pattern (`.*`, `^(?!…).*$` on the trusted side). Trusted short-circuits the entire classifier — `rm -rf /` would auto-approve.
3. Every new **trusted root** keeps the full executable-extension guard.
4. Untrusted additions are safe by default (worst case = prompts) but still anchor them, or you'll prompt on harmless commands that merely *contain* the path (`cat /etc/passwd`).

### 4.4 Verify a new entry

Add a test case to `test/test-cases.trustedpattern.xml` (the runner supports per-case tool payloads):

```xml
<test-case expected="allow" reason="trusted: D:\work root" category="TP-Write-Windows">
  <description>Write D:\work\notes.txt — trusted work root</description>
  <tool-name>Write</tool-name>
  <tool-input-json>{"file_path":"D:\\work\\notes.txt"}</tool-input-json>
</test-case>
```

Then:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml"
# plus the full 9-suite differential — all other suites must stay byte-identical
```

## 5. Known residual holes (pinned as `[RESIDUAL]` tests in the suite)

| Hole | Why it exists | Fix |
|---|---|---|
| `.ps1`/`.sh`/`.py` paths (write or exec) inside/outside roots auto-allow | Script extensions aren't in the untrusted exe list (they're source files — writes to them inside roots must stay allowed for daily work) | Code change: distinguish Write-tool from exec in a path-branch |
| `/usr/bin`, `/usr/sbin` writes allow | Those dirs are excluded from untrusted so full-path binary execution classifies read-only | Code change |
| `/home/…` writes allow | Not in the untrusted linux list | Add `^/home/` to untrusted if unwanted |
| Relative paths (`notes.txt`) allow | Patterns are anchored to absolute paths; agent tools send absolute in practice | Code change (canonicalization) |
| `\\?\C:\…` extended prefix bypasses anchors | Prefix doesn't match `[A-Za-z]:` | Code change (canonicalization) |

**The structural fix** for all residuals: a small path-branch in the classifier for file tools — canonicalize the path, check against `system_paths`/`editable_paths` directly (single source of truth, no regex duplication), default non-listed to ask. That's the planned next spec; the patterns in this document are the config-only bridge.
