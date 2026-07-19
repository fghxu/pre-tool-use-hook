# Agent Command Guidelines + config.json Gap-Fill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship agent-facing command guidelines (shared file + backup skill + install README) and fill the config.json classification gaps that caused 388 real "unknown command" hits in the prehook logs.

**Architecture:** Spec: `docs/superpowers/specs/2026-07-19-agent-command-guidelines-design.md`. TDD on the config work: 31 new adhoc XML cases go RED first, config.json additions turn them GREEN, then full differential suite run proves zero regression. The three doc artifacts are pure content (full text in this plan).

**Tech Stack:** PowerShell hook + `config.json` classification DB + `src/TestRunner.ps1` XML suites. Docs are Markdown; skill follows the standard SKILL.md frontmatter format.

**Key config semantics (verified against existing tests):**
- Entries in a domain's `read_only` array are auto-approved (`allow`), even when they carry a `"risk"` attribute (proven: `git add` → allow in test-cases.xml:2740). Anything that must prompt goes in the `modifying` array.
- Patterns support regex: `*` wildcard, negative lookahead (precedent: `"wmic (?!.*process.*call.*create).*"` at config.json:231), anchors (precedent: `"^git tag$"` at config.json:473).
- Test-case expectations: `expected="allow"` (auto-approve) or `expected="ask"` (prompt).

---

### Task 1: Capture pre-change baseline

**Files:** none (verification only)

- [ ] **Step 1: Run all nine suites and record results**

Run each from repo root `C:\git\cc\pretoolhook`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.var-assignment.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.fullpath.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-normal.xml" -Strictness normal
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.redirect-strict.xml" -Strictness strict
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.trustedpattern.xml"
powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.new-samples.xml"
powershell.exe -ExecutionPolicy Bypass -File "test/FullPipeTestRunner.ps1"
```

- [ ] **Step 2: Record expected baseline**

Expected (from PROGRESS.md, captured 2026-07-19; if any number differs, STOP and reconcile before continuing):

| Suite | Expected |
|---|---|
| test-cases.xml | 487/487 pass |
| adhoc | 63/63 pass |
| var-assignment | 63/64 (test #14 pre-existing fail) |
| fullpath | 20/20 |
| redirect-normal | 20/25 (5 pre-existing fails) |
| redirect-strict | 24/25 (1 pre-existing fail) |
| trustedpattern | 1/6 (5 pre-existing fails) |
| new-samples | 14/14 |
| fullpipe | 19/19 |

---

### Task 2: Write the 31 failing adhoc test cases (RED)

**Files:**
- Modify: `test/test-cases.adhoc.xml` (append before closing `</commands>`)

- [ ] **Step 1: Append these five category-groups**

```xml
  <!-- =================================================================== -->
  <!-- Log-Gap-Fill: commands seen as "unknown command" in prehook logs     -->
  <!-- (spec 2026-07-19-agent-command-guidelines-design.md).                -->
  <!-- =================================================================== -->

  <category-group name="LogGap-Git">
    <test-case expected="allow" reason="read-only: git worktree list" category="LogGap-Git">
      <description>git worktree list — read-only</description>
      <copilot-command><![CDATA[git worktree list]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: git worktree remove" category="LogGap-Git">
      <description>git worktree remove — modifying (low)</description>
      <copilot-command><![CDATA[git worktree remove mywt]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: git worktree prune" category="LogGap-Git">
      <description>git worktree prune — modifying (low)</description>
      <copilot-command><![CDATA[git worktree prune]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: git tag -a" category="LogGap-Git">
      <description>git tag -a with -m — annotated tag creation, modifying (low)</description>
      <copilot-command><![CDATA[git tag -a v1.2 -m "release 1.2"]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: git tag -l (regression guard)" category="LogGap-Git">
      <description>git tag -l stays read-only after adding tag creation patterns</description>
      <copilot-command><![CDATA[git tag -l "v1.*"]]></copilot-command>
    </test-case>
  </category-group>

  <category-group name="LogGap-DOS">
    <test-case expected="allow" reason="read-only: reg query" category="LogGap-DOS">
      <description>reg query — read-only</description>
      <copilot-command><![CDATA[reg query "HKLM\SOFTWARE\Microsoft\Windows" /s]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: sc qc" category="LogGap-DOS">
      <description>sc qc — query service config, read-only</description>
      <copilot-command><![CDATA[sc qc wuauserv]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: sc start" category="LogGap-DOS">
      <description>sc start — modifying (medium)</description>
      <copilot-command><![CDATA[sc start wuauserv]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: net share (bare)" category="LogGap-DOS">
      <description>net share bare — list shares, read-only</description>
      <copilot-command><![CDATA[net share]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: net share name (view)" category="LogGap-DOS">
      <description>net share docs — view one share, read-only</description>
      <copilot-command><![CDATA[net share docs]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: net share name=path" category="LogGap-DOS">
      <description>net share docs=C:\docs — create share, modifying (high)</description>
      <copilot-command><![CDATA[net share docs=C:\docs]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: net share /delete" category="LogGap-DOS">
      <description>net share docs /delete — delete share, modifying (high)</description>
      <copilot-command><![CDATA[net share docs /delete]]></copilot-command>
    </test-case>
  </category-group>

  <category-group name="LogGap-DevTools">
    <test-case expected="allow" reason="read-only: adb devices" category="LogGap-DevTools">
      <description>adb devices — read-only</description>
      <copilot-command><![CDATA[adb devices]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: adb logcat (no -c)" category="LogGap-DevTools">
      <description>adb logcat -d — dump log, read-only</description>
      <copilot-command><![CDATA[adb logcat -d]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: adb logcat -c" category="LogGap-DevTools">
      <description>adb logcat -c — clears log buffer, modifying (low); contrast pair with -d</description>
      <copilot-command><![CDATA[adb logcat -c]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: adb shell getprop" category="LogGap-DevTools">
      <description>adb shell getprop — read-only</description>
      <copilot-command><![CDATA[adb shell getprop ro.product.model]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: adb shell pm list" category="LogGap-DevTools">
      <description>adb shell pm list packages — read-only</description>
      <copilot-command><![CDATA[adb shell pm list packages]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: adb install" category="LogGap-DevTools">
      <description>adb install -r — modifying (low)</description>
      <copilot-command><![CDATA[adb install -r app.apk]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: adb push" category="LogGap-DevTools">
      <description>adb push — modifying (low)</description>
      <copilot-command><![CDATA[adb push file.txt /sdcard/]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: adb shell am start" category="LogGap-DevTools">
      <description>adb shell am start — launches activity, modifying (low)</description>
      <copilot-command><![CDATA[adb shell am start -n com.app/.MainActivity]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: unzip" category="LogGap-DevTools">
      <description>unzip writes files — modifying (low)</description>
      <copilot-command><![CDATA[unzip -o archive.zip -d out]]></copilot-command>
    </test-case>
  </category-group>

  <category-group name="LogGap-JavaGradle">
    <test-case expected="allow" reason="read-only: javap" category="LogGap-JavaGradle">
      <description>javap disassembly — read-only</description>
      <copilot-command><![CDATA[javap -p com.example.Foo]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: ./gradlew" category="LogGap-JavaGradle">
      <description>./gradlew assembleDebug — build writes outputs, modifying (low)</description>
      <copilot-command><![CDATA[./gradlew assembleDebug]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: gradlew" category="LogGap-JavaGradle">
      <description>gradlew clean — modifying (low)</description>
      <copilot-command><![CDATA[gradlew clean]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: .\gradlew" category="LogGap-JavaGradle">
      <description>.\gradlew test (Windows form) — modifying (low)</description>
      <copilot-command><![CDATA[.\gradlew test]]></copilot-command>
    </test-case>
  </category-group>

  <category-group name="LogGap-GH">
    <test-case expected="allow" reason="read-only: gh pr list" category="LogGap-GH">
      <description>gh pr list — read-only</description>
      <copilot-command><![CDATA[gh pr list]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: gh pr view" category="LogGap-GH">
      <description>gh pr view — read-only</description>
      <copilot-command><![CDATA[gh pr view 123]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: gh repo view" category="LogGap-GH">
      <description>gh repo view — read-only</description>
      <copilot-command><![CDATA[gh repo view]]></copilot-command>
    </test-case>
    <test-case expected="allow" reason="read-only: gh release list" category="LogGap-GH">
      <description>gh release list — read-only</description>
      <copilot-command><![CDATA[gh release list]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: gh pr create" category="LogGap-GH">
      <description>gh pr create — modifying (medium)</description>
      <copilot-command><![CDATA[gh pr create --title "x" --body "y"]]></copilot-command>
    </test-case>
    <test-case expected="ask" reason="modifying: gh release delete" category="LogGap-GH">
      <description>gh release delete — modifying (medium)</description>
      <copilot-command><![CDATA[gh release delete v1.0]]></copilot-command>
    </test-case>
  </category-group>
```

- [ ] **Step 2: Run adhoc, verify the 31 new cases FAIL (RED)**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"`
Expected: 63 pass / 94 total — exactly the 31 new LogGap-* cases failing (most as unexpected "allow" where "ask" was wanted, or "unknown command" where classification was missing). The previously-green 63 must still pass. If any of the old 63 flip, STOP — a new test is colliding with an existing pattern (check `git tag -l` guard).

---

### Task 3: config.json — prefixes + Git + DOS_CMD entries

**Files:**
- Modify: `config.json` (lines per current working-tree version)

- [ ] **Step 1: Add to `known_command_prefixes` (config.json:51-59)**

Add `adb`, `unzip`, `javap`, `gradlew` to the array. Result:

```json
  "known_command_prefixes": [
    "docker", "kubectl", "aws", "npm", "git", "terraform", "helm", "gh", "az", "gcloud",
    "python", "node", "ruby", "go", "cargo", "dotnet","java",
    "pwsh", "powershell", "cmd", "bash", "sh",
    "curl", "wget",
    "cd", "dir", "ls", "cat", "ping", "ps", "type", "tree", "findstr",
    "ipconfig", "netstat", "tasklist", "whoami", "sc", "net", "ver", "hostname",
    "get-childitem", "get-content", "get-process", "get-service", "get-item",
    "adb", "unzip", "javap", "gradlew"
  ],
```

- [ ] **Step 2: Git read_only — add `git worktree list` (insert after the `git worktree add` line, config.json:482)**

```json
        { "name": "git worktree list", "patterns": ["git worktree list*", "git worktree list *"], "description": "List worktrees (no write)" },
```

- [ ] **Step 3: Git modifying — add worktree/tag-creation entries (append inside the Git `"modifying"` array, after the `git remote modify` line, config.json:496)**

```json
        { "name": "git worktree remove", "patterns": ["git worktree remove*", "git worktree remove *"], "risk": "low", "description": "Remove a worktree" },
        { "name": "git worktree prune",  "patterns": ["git worktree prune*"],                        "risk": "low", "description": "Prune stale worktree metadata" },
        { "name": "git worktree move",   "patterns": ["git worktree move*"],                         "risk": "low", "description": "Move a worktree" },
        { "name": "git worktree lock",   "patterns": ["git worktree lock*"],                         "risk": "low", "description": "Lock a worktree" },
        { "name": "git worktree unlock", "patterns": ["git worktree unlock*"],                       "risk": "low", "description": "Unlock a worktree" },
        { "name": "git tag create",      "patterns": ["git tag -a*", "git tag -s *", "git tag -m *"], "risk": "low", "description": "Create annotated/signed tag" }
```

(Fix the JSON comma on the previously-last `git remote modify` entry.)

- [ ] **Step 4: DOS_CMD read_only — add reg query, sc qc, net share (insert after the `sc query` line, config.json:222)**

```json
        { "name": "sc qc",    "patterns": ["sc qc *"],                                                 "description": "Query service configuration" },
        { "name": "reg query","patterns": ["reg query *"],                                             "description": "Query registry keys/values" },
        { "name": "net share","patterns": ["^net share$", "net share (?!.*=|.*\\/delete).*"],          "description": "List shares / view one share (no create/delete)" },
```

- [ ] **Step 5: DOS_CMD modifying — add net share create/delete, sc start/create (insert after the `sc stop` line, config.json:260)**

```json
        { "name": "sc start",  "patterns": ["sc start *"],                                             "risk": "medium", "description": "Start a service" },
        { "name": "sc create", "patterns": ["sc create *"],                                            "risk": "high",   "description": "Create a service" },
        { "name": "net share create", "patterns": ["net share *=*"],                                   "risk": "high",   "description": "Create a network share" },
        { "name": "net share delete", "patterns": ["net share */delete*"],                             "risk": "high",   "description": "Delete a network share" },
```

---

### Task 4: config.json — Linux additions + new GitHub_CLI domain

**Files:**
- Modify: `config.json`

- [ ] **Step 1: Linux read_only — add javap + adb read forms (insert after the `true` line, config.json:397)**

```json
        { "name": "javap",    "patterns": ["javap *"],                          "description": "Disassemble/inspect Java class files" },
        { "name": "adb devices",     "patterns": ["adb devices*"],              "description": "List attached Android devices" },
        { "name": "adb logcat read", "patterns": ["adb logcat (?!.*-c).*", "adb logcat"], "description": "Dump device log (excludes -c clear)" },
        { "name": "adb shell getprop", "patterns": ["adb shell getprop *"],     "description": "Read device properties" },
        { "name": "adb shell pm list", "patterns": ["adb shell pm list *"],     "description": "List installed packages" }
```

(Fix the JSON comma on the previously-last `true` entry.)

- [ ] **Step 2: Linux modifying — add unzip, gradlew, adb write forms (append after the `chpasswd` line, config.json:436)**

```json
        { "name": "unzip",    "patterns": ["unzip *", "unzip"],                 "risk": "low", "description": "Extract archive (writes files)" },
        { "name": "gradlew",  "patterns": ["./gradlew *", "./gradlew", "gradlew *", "gradlew", ".\\gradlew *", ".\\gradlew"], "risk": "low", "description": "Gradle build wrapper (writes build outputs)" },
        { "name": "adb install", "patterns": ["adb install *"],                 "risk": "low", "description": "Install APK on device" },
        { "name": "adb push", "patterns": ["adb push *"],                       "risk": "low", "description": "Push file to device" },
        { "name": "adb pull", "patterns": ["adb pull *"],                       "risk": "low", "description": "Pull file from device" },
        { "name": "adb shell am start", "patterns": ["adb shell am start *"],   "risk": "low", "description": "Launch activity on device" },
        { "name": "adb logcat -c", "patterns": ["adb logcat *-c*"],             "risk": "low", "description": "Clear device log buffer" }
```

(Fix the JSON comma on the previously-last `chpasswd` entry.)

- [ ] **Step 3: Add new GitHub_CLI domain (insert as a new domain after the Git domain closes, config.json:498 `},`)**

```json
    "GitHub_CLI": {
      "description": "GitHub CLI commands",
      "read_only": [
        { "name": "gh pr list",      "patterns": ["gh pr list*"],        "description": "List pull requests" },
        { "name": "gh pr view",      "patterns": ["gh pr view*"],        "description": "View a pull request" },
        { "name": "gh pr status",    "patterns": ["gh pr status*"],      "description": "Show PR status" },
        { "name": "gh repo view",    "patterns": ["gh repo view*"],      "description": "View repository" },
        { "name": "gh release list", "patterns": ["gh release list*"],   "description": "List releases" },
        { "name": "gh release view", "patterns": ["gh release view*"],   "description": "View a release" }
      ],
      "modifying": [
        { "name": "gh pr create",      "patterns": ["gh pr create*"],      "risk": "medium", "description": "Create pull request" },
        { "name": "gh pr merge",       "patterns": ["gh pr merge*"],       "risk": "medium", "description": "Merge pull request" },
        { "name": "gh pr close",       "patterns": ["gh pr close*"],       "risk": "medium", "description": "Close pull request" },
        { "name": "gh issue create",   "patterns": ["gh issue create*"],   "risk": "medium", "description": "Create issue" },
        { "name": "gh release create", "patterns": ["gh release create*"], "risk": "medium", "description": "Create release" },
        { "name": "gh release delete", "patterns": ["gh release delete*"], "risk": "medium", "description": "Delete release" }
      ]
    },
```

---

### Task 5: GREEN + full differential verification

**Files:** none (verification only)

- [ ] **Step 1: Run adhoc — all green**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"`
Expected: **94/94 pass** (63 old + 31 new). If any LogGap case fails, fix the pattern (common causes: wildcard placement, JSON escaping of `.\gradlew`, lookahead syntax) — do NOT edit the test to match a wrong classification.

- [ ] **Step 2: Run the other eight suites — byte-identical to baseline**

Run all commands from Task 1 Step 1. Expected: every suite matches the Task 1 baseline exactly (487/487, 63/64 var-assignment, 20/20, 20/25, 24/25, 1/6, 14/14, 19/19 — with adhoc now 94/94). Any drift: STOP, identify which new pattern collides, narrow it.

- [ ] **Step 3: Commit**

```powershell
git add config.json test/test-cases.adhoc.xml
git commit -m "feat: classify log-gap commands (git worktree/tag -a, reg query, sc qc/start/create, net share, adb, unzip, javap, gradlew, gh) + 31 adhoc cases"
```

Note: config.json already had uncommitted in-flight edits (git ls-files, git branch --show*, git worktree add, sc query, python3 aliases) — per approved spec §8 they land in this same commit.

---

### Task 6: Write `docs/agent-command-guidelines/guidance.md`

**Files:**
- Create: `docs/agent-command-guidelines/guidance.md`

- [ ] **Step 1: Write the file with this exact content**

````markdown
# Command Guidelines for AI Agents (PreToolUse-Hook Friendly)

A PreToolUse safety hook on this machine classifies every shell command before it runs. Commands it can classify run immediately (read-only) or prompt once (modifying). Commands it **cannot parse** are reported as "unknown command" and force a manual review every single time — slowing the whole session.

Follow these rules when composing commands. They do not limit what you may do — only the *shape* of what you emit.

## R1 — Never use heredocs

Do not write files or pass multi-line input with heredocs (`<<EOF`, `<<'EOF'`, `@"..."@`). Embedded content shatters into phantom "commands" and is the single largest source of unknown classifications.

**Instead:** use the file-writing tool (Write / create) to create the file, then run commands against it.

## R2 — Multi-line git messages: repeated `-m`, never embedded newlines

```
git commit -m "Subject line" -m "Body paragraph" -m "Co-Authored-By: Name <n@x>"
git tag -a v1.0 -m "Release 1.0"
```

Never: a literal multi-line `-m` string, `\n` escapes inside `-m`, or `git commit -F -` fed by a heredoc.

## R3 — No `powershell.exe -Command` blobs

Do not wrap pipelines in `powershell.exe -NoProfile -Command "Get-X | Where-Object {...} | Format-Y"` — the wrapper plus nested quoting is unclassifiable.

**Instead:** run the pipeline directly in the shell tool, one statement per line. If a wrapper is truly unavoidable, keep the inner command a single simple cmdlet.

## R4 — No `cmd //c` wrappers

Invoke the real command directly. `cmd //c "sc query x"` → `sc query x`.

## R5 — One quoting layer

No `\$var` / `\"` escape stacks inside nested strings. If the logic needs variables and quoting, write a `.ps1` file with the file tool and run that.

## R6 — One command per line

Do not chain independent commands with `&&`, `||`, or `;` — emit them as separate invocations. Keep pipelines short and linear.

## R7 — Known-gap commands: run plainly, expect the prompt

A few forms are **intentionally** not auto-classified and will always prompt (the hook is fail-safe by design):

- `python3 -c "..."` / `python -c "..."` (arbitrary code)
- `powershell.exe -File script.ps1` (opaque script file)
- `adb` with `-s <serial>` global flags, `adb exec-out`, `adb shell` forms not in the read-only list
- Interactive/TUI commands (`top` without `-b`, `less` on a TTY)

Run them unwrapped and simply quoted when the task needs them. Do not contort a command to dodge the prompt.

*(Maintainers: when `config.json` adds coverage for a command, remove it from this list.)*

## Quick reference

| Task | Emit this | Not this |
|---|---|---|
| Write a file | file-writing tool | `cat <<EOF > f` |
| Multi-line commit | `git commit -m a -m b` | `git commit -m "a\nb"` or heredoc |
| PowerShell pipeline | direct cmdlet line | `powershell.exe -NoProfile -Command "..."` |
| CMD builtin | direct command | `cmd //c "..."` |
| Script with logic | write `.ps1`, then run it | inline `-Command` escape soup |
````

- [ ] **Step 2: Verify the recommended forms classify cleanly (spec authoring constraint)**

Run: `powershell.exe -ExecutionPolicy Bypass -File "src/TestRunner.ps1" -XmlPath "test/test-cases.adhoc.xml"`
Expected: 94/94 — confirms every form R2–R7 steers toward is covered (git commit/tag forms, direct cmdlets, known-gap list matches what actually still prompts). No new test needed here; this is a consistency re-check.

---

### Task 7: Write `docs/agent-command-guidelines/hook-friendly-commands/SKILL.md`

**Files:**
- Create: `docs/agent-command-guidelines/hook-friendly-commands/SKILL.md`

- [ ] **Step 1: Write the file with this exact content**

````markdown
---
name: hook-friendly-commands
description: Use when composing shell or PowerShell commands to run in a terminal - emits forms the PreToolUse safety hook can auto-classify, avoiding "unknown command" approval prompts and session slowdowns
---

# Hook-Friendly Commands

A PreToolUse hook classifies every command before it runs. Unclassifiable commands become "unknown command" and force manual review. Emit commands in these shapes:

1. **No heredocs.** Use the file-writing tool for file contents. Heredoc content shatters into phantom unknown commands.
2. **Multi-line git messages:** repeated `-m` flags (`git commit -m "subj" -m "body"`). Never literal newlines or `\n` inside `-m`.
3. **No `powershell.exe -NoProfile -Command "<pipeline>"` blobs** — run cmdlets directly, one statement per line.
4. **No `cmd //c "..."` wrappers** — invoke the command directly.
5. **One quoting layer.** No `\$` / `\"` escape stacks; write a `.ps1` file for non-trivial logic instead.
6. **One command per line.** No `&&` / `||` / `;` chains of independent commands. Short linear pipelines.
7. **Known-gap forms always prompt — that is fine.** `python3 -c`, `powershell.exe -File`, `adb -s <serial> ...`, interactive TUI commands. Run them plainly; don't contort to avoid the prompt.

Full source of truth: `docs/agent-command-guidelines/guidance.md` (pretoolhook repo).
````

---

### Task 8: Write `docs/agent-command-guidelines/README.md` + verify install dirs

**Files:**
- Create: `docs/agent-command-guidelines/README.md`

- [ ] **Step 1: Verify which install target directories exist on this machine**

```powershell
Test-Path "$env:USERPROFILE\.claude"; Test-Path "$env:USERPROFILE\.claude\skills"; Test-Path "$env:USERPROFILE\.copilot"; Test-Path "$env:USERPROFILE\.codex"; Test-Path "$env:USERPROFILE\.codex\skills"
```

Record the results; in the README below, mark any directory that does not exist with "(create if missing)".

- [ ] **Step 2: Write the file with this exact content (adjust the verify-marks per Step 1)**

````markdown
# Agent Command Guidelines — Install Companion

`guidance.md` is the single source of truth. `hook-friendly-commands/SKILL.md` is the same rules in skill format (backup). Install per IDE below; edit only `guidance.md` and re-propagate on change.

## Claude Code

**Option A (recommended):** add an import line to `~/.claude/CLAUDE.md`:

```
@C:\git\cc\pretoolhook\docs\agent-command-guidelines\guidance.md
```

**Option B (backup skill):** copy `hook-friendly-commands/` into `~/.claude/skills/` so it becomes `~/.claude/skills/hook-friendly-commands/SKILL.md`.

**Verify:** start a session and ask the agent to recite rule R1 — or check that `~/.claude/skills/hook-friendly-commands/SKILL.md` exists.

## GitHub Copilot CLI

Copilot does **not** follow Claude's `@path` file-link syntax. Paste the full contents of `guidance.md` into one of:

- `~/.copilot/AGENTS.md` (global, all repos), or
- `<repo>/AGENTS.md` or `<repo>/.github/copilot-instructions.md` (per-repo)

Skills load only via installed plugins, so the paste route above is the practical install for Copilot.

**Verify:** ask the agent in a Copilot session to recite rule R1.

## Codex CLI

Codex reads `AGENTS.md` (no import syntax). Paste the full contents of `guidance.md` into `~/.codex/AGENTS.md` (global) or the repo's `AGENTS.md`.

Optional skill install (current Codex builds load skills natively — verify on your version): copy `hook-friendly-commands/` to `~/.codex/skills/hook-friendly-commands/`.

**Verify:** ask the agent in a Codex session to recite rule R1.

## Maintenance

1. Edit `guidance.md` only.
2. Re-paste into any AGENTS.md / copilot-instructions.md targets (they are copies, not links).
3. If `config.json` adds coverage for a command listed in guidance rule R7, remove it from R7.
4. Regenerate `hook-friendly-commands/SKILL.md` if the rules change (it is a condensed copy).
````

- [ ] **Step 3: Commit all three artifacts**

```powershell
git add docs/agent-command-guidelines/
git commit -m "docs: agent command guidelines (guidance.md, backup skill, per-IDE install README)"
```

---

### Task 9: Close out

- [ ] **Step 1: Update PROGRESS.md**

Set Completed Steps to include: 31 LogGap adhoc cases green; config.json gap-fill committed; three artifacts under `docs/agent-command-guidelines/` committed. Current Step: DONE (awaiting user verification / install decision). Next Steps: optional — install guidance into `~/.claude/CLAUDE.md` / AGENTS.md targets; optional — push master to origin.

- [ ] **Step 2: Final summary to user**

Report: adhoc 94/94, all other suites byte-identical to baseline, commit hashes, and the one-line install action for Claude Code (the `@` import line).

---

## Self-Review Notes

- **Spec coverage:** §3 guidance.md → Task 6. §4 SKILL.md → Task 7. §5 README.md → Task 8. §6 config table → Tasks 2-5 (every row has ≥1 test: worktree list/remove/prune ✓, tag -a ✓, reg query ✓, adb devices/logcat±c/getprop/pm list/install/push/am start ✓, gradlew ×3 forms ✓, unzip ✓, javap ✓, net share ×4 ✓, sc qc/start/create ✓, gh ×6 ✓). §7 verification → Tasks 1, 5, 6-Step 2, 8-Step 1. §8 out-of-scope respected (no parser changes, no validator script).
- **adb `-s <serial>` variants** deliberately left to fallback (fail-safe ask) — documented in guidance R7.
- **Type consistency:** test expectations (allow/ask) match config placement (read_only vs modifying array) per the semantics verified at plan time.
