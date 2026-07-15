# Parameter-Value-Aware Classification & editable_paths — Design Spec

**Date:** 2026-07-13
**Status:** Draft — pending user review
**Depends on:** `2026-05-15-architecture-design.md`, `2026-06-06-redirect-strictness-design.md`

---

## 1. Problem

The classifier today decides read-only vs. modifying from a command's **name** and (for PowerShell) its **verb**. It never inspects a **parameter value**, and its DOS/Linux regex patterns are brittle to **argument position, spacing, and quoting**. Two concrete gaps:

1. **`Invoke-RestMethod -Method Post` vs `-Method Get`** classify identically (both fall to "unknown → ask"), because `Invoke-*` is not a known verb and no parameter value is read. The same applies to `Invoke-WebRequest`, and the rule must hold inside embedded PowerShell (`Invoke-Command -ScriptBlock { … }`, `pwsh -Command "…"`, remoting).
2. **`curl -d '{…}' https://x`** and **`curl https://x -d '{…}'`** must both be caught as modifying regardless of where the `-d` flag sits. The current regex (`curl .*-d *`, `curl .*-X POST*`) misses attached forms (`-XDELETE`), `--data=…`, and is exactly the position-brittleness we want to eliminate.

A second, independent request:

3. Add an **`editable_paths`** whitelist so file writes are auto-allowed only inside the current working directory (CWD) or declared editable locations — the inverse of the existing `system_paths` blacklist — with the CWD **always editable** in every strictness mode.

## 2. Goals / Non-Goals

**Goals**
- Config-driven, forward-compatible: adding `Invoke-WebRequest`, `python`, or any future command requires **zero code changes** — only a config entry.
- Position-independent, quote-safe parameter detection for PowerShell (via AST) and Linux/DOS (via a shell tokenizer).
- Works inside embedded/remoting PowerShell by reusing the existing per-sub-command AST extraction.
- `editable_paths` + CWD gating on redirect targets, governed by `modifying_strictness`.
- All existing tests in `test/test-cases.xml` and the redirect/var/fullpath suites continue to pass.

**Non-Goals (this change)**
- Path-gating *file-write commands* (`Set-Content`, `Out-File`, `del`, `copy`, …). `editable_paths`/`system_paths` continue to apply only where they do today: `>` / `>>` redirect targets (see §7, future work).
- PowerShell free-form parameter abbreviation (`-Meth` for `-Method`). Ambiguous and unsafe; not supported. Configured `aliases` are supported instead.
- Glob-to-regex auto-conversion for `editable_paths` (they are regex, like `system_paths.windows`).

## 3. Feature A — Parameter-Value-Aware Classification

### 3.1 Config schema

A new optional **`parameter_commands`** object inside each domain (`commands.PowerShell`, `commands.Linux`, …). A command listed here is classified **solely** by its parameter rules — it becomes a single source of truth, and any old regex entries for that command name should be retired (see §3.5, curl migration).

```jsonc
"PowerShell": {
  // …existing read_only / modifying / read_only_verbs / modifying_verbs…
  "parameter_commands": {
    "Invoke-RestMethod": {
      "aliases": ["irm"],                 // optional: other spellings of the same command
      "rules": [
        {
          "param": "Method",              // string, OR array of synonyms, e.g. ["-d","--data"]
          "match": "values",              // "present" | "values"
          "values": ["Get","Head","Options"],  // required when match=="values"; case-insensitive
          "decision": "read-only",        // "read-only" | "modifying"
          "risk": "medium"                // optional; only meaningful for "modifying"
        }
      ],
      "default": "read-only",             // decision when NO rule matches (e.g. param absent)
      "default_risk": "medium"            // optional
    }
  }
}
```

**Rule fields**
| Field | Required | Meaning |
|---|---|---|
| `param` | yes | Parameter/flag name. For PowerShell: **without** leading `-` (e.g. `"Method"`). For shells: **with** leading marker (`"-d"`, `"--data"`, `"/flag"`). Array form = synonyms. |
| `match` | yes | `present` = flag exists (any/no value); `values` = flag's value ∈ `values`. |
| `values` | only for `values` | List of accepted values, compared case-insensitively. |
| `decision` | yes | `read-only` (→ allow) or `modifying` (→ ask). |
| `risk` | optional | `low`/`medium`/`high`; reported with modifying decisions. |

**Match order inside a command (fail-safe):** modifying rules first → read-only rules → `default`. If *any* modifying rule matches, the command asks (e.g. `curl -X GET -d '{…}'` → ask). This preserves the project's least-privilege invariant.

**Switch / boolean parameters** are handled by `match: "present"` — the detector checks for the flag's *existence* and ignores any value. This covers `-d`, `--force`, `--dry-run`, `-Verbose`, and DOS `/q`. The shell tokenizer splits combined short-switch clusters (e.g. `-sv` → `-s` + `-v`) so individual declared switches are recognized even when smashed together; if a char in a cluster is a declared value-taking flag, the remainder of the cluster is its value (getopt-style, e.g. `-XPOST`).

**No-match resolution (strictness-governed):** When no rule matches, the outcome depends on *why* it didn't match and on `modifying_strictness`:
- Declared parameter **absent** (e.g. `Invoke-RestMethod -Uri X` with no `-Method`) → the command's natural behavior via `default`, in **all** modes. This preserves existing expectations (no `-Method` ⇒ GET ⇒ allow; no `--version` ⇒ python runs a script ⇒ ask) regardless of strictness.
- Declared parameter **present with an unrecognized value** (e.g. `-Method Custom`, `-X FROG`) → **strict/normal: `ask`** (conservative — forces explicit config, so rules are added deliberately over time); **loose: use `default`**.

This makes `modifying_strictness` the single knob for "how lenient with unrecognized input," consistent with its role for `editable_paths` (§4). `default` is always honored for the *absent* case so no-mode surprises the `Invoke-RestMethod -Uri X ⇒ allow` requirement.

### 3.2 Sample config (will be added to `config.json` during implementation)

```jsonc
// commands.PowerShell.parameter_commands
"Invoke-RestMethod": {
  "aliases": ["irm"],
  "rules": [
    { "param": "Method", "match": "values", "values": ["Get","Head","Options"], "decision": "read-only" },
    { "param": "Method", "match": "values", "values": ["Post","Put","Patch"],  "decision": "modifying", "risk": "medium" },
    { "param": "Method", "match": "values", "values": ["Delete"],              "decision": "modifying", "risk": "high" }
  ],
  "default": "read-only"
},
"Invoke-WebRequest": {
  "aliases": ["iwr"],
  "rules": [ /* same three Method rules as above */ ],
  "default": "read-only"
}

// commands.Linux.parameter_commands
"curl": {
  "rules": [
    { "param": "-X", "match": "values", "values": ["GET","HEAD","OPTIONS"], "decision": "read-only" },
    { "param": "-X", "match": "values", "values": ["POST","PUT","PATCH"],   "decision": "modifying", "risk": "medium" },
    { "param": "-X", "match": "values", "values": ["DELETE"],               "decision": "modifying", "risk": "high" },
    { "param": ["-d","--data","--data-raw","--data-binary","--data-urlencode"], "match": "present", "decision": "modifying", "risk": "medium" },
    { "param": ["-F","--form"],         "match": "present", "decision": "modifying", "risk": "medium" },
    { "param": ["-T","--upload-file"],  "match": "present", "decision": "modifying", "risk": "medium" }
  ],
  "default": "read-only"
},
"python": {
  "aliases": ["python3","py"],
  "rules": [
    { "param": ["--version","-V"], "match": "present", "decision": "read-only" },
    { "param": ["--help","-h"],    "match": "present", "decision": "read-only" }
  ],
  "default": "modifying",
  "default_risk": "medium"
}
```

Behavior this produces:
- `Invoke-RestMethod -Uri "…" -Method Get` → **allow**; `-Method Post` / `-Method DELETE -Uri X` → **ask**; no `-Method` → **allow** (default GET).
- `curl -d '{…}' https://x` and `curl https://x -d '{…}'` → **ask** (flag found anywhere); `curl -s https://x` → **allow**.
- `python --version 2>&1` → **allow** (`--version` read-only + `2>&1` read-only); `python gen_t4.py` → **ask** (no rule → default modifying).

### 3.3 Where it runs in `Resolve-Command`

A new **Step 7**, inserted after the existing prefix-stripping steps (var-assignment, sudo, git `-C`, AWS flags, full-path) and **before** explicit `read_only`/`modifying` entries:

```
0  domain normalize
0b var-assignment strip
0c sudo strip
0d git -C strip
0e AWS flag strip
0f full-path strip
7  ★ parameter_commands check   ← NEW
1a explicit read_only entries
1b explicit modifying entries
2  verb-based (PS / AWS)
2.5 shell flow keywords
3  fallback ask
```

Rationale: prefix-stripping must happen first (so `C:\Python\python.exe` → `python`, `$r = Invoke-RestMethod …` → `Invoke-RestMethod …`). A command that has a `parameter_commands` entry is then classified exclusively by its rules; explicit regex entries for that command are skipped (and should be removed — §3.5).

### 3.4 Two parsers (one per shell family)

The config is identical in shape; the engine picks the parser from the domain. Both build a **`flag → value` map** (value may be `$null` for boolean/present flags), then evaluate rules identically.

#### 3.4.1 PowerShell — AST-based (domain `powershell`)

Re-parse the sub-command string (the existing architecture already hands `Resolve-Command` the inner command text, so embedded/remoting works for free):

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
```
- On parse error → **fall through** to normal classification (never block on a parse failure — fail-safe).
- Find the target `CommandAst` (first `CommandAst` whose element 0 matches the command name/alias).
- Walk `CommandAst.CommandElements`:
  - `CommandParameterAst` → name = `.ParameterName`; value = `.Argument` (covers `-Method:Post`) **or**, if `.Argument` is null, the next non-parameter element's value (covers `-Method Post`).
  - Build map `paramNameLower → value` (value `$null` if the flag is boolean / has no argument).

#### 3.4.2 Linux / DOS — shell tokenizer (other domains)

A config-driven tokenizer: the set of **value-taking flag names** is derived from the command's `values`-match rules, so the tokenizer knows which flags consume a following value. Tokenize respecting single/double quotes (mirroring the quote-tracking already in `Parser.ps1`), then for each arg:

| Form | Flag name | Value |
|---|---|---|
| `--data=payload` | `--data` | `payload` |
| `--data payload` | `--data` | next token (unless it starts with `-`/`--`) |
| `-X POST` | `-X` | next token |
| `-XPOST` | `-X` | `POST` (remainder attached) |
| `-d=payload` | `-d` | `payload` |
| `/flag:value` (DOS) | `/flag` | `value` |
| `-d` (no value, or boolean rule) | `-d` | `$null` (present) |

Non-flag tokens (URLs, `2>&1`, positional args) are ignored by the detector. `2>&1` is not a flag and is separately handled by `Test-RedirectionTarget`.

### 3.5 curl migration

The current `commands.Linux` has brittle `curl` regex entries in both `read_only` (`curl http*`, the negative-lookahead patterns) and `modifying` (`curl .*-X POST*`, `curl .*-d *`, etc.). Once `curl` has a `parameter_commands` entry, **Step 7 classifies it exclusively**; the old regex entries become dead config and are removed. The existing curl tests in `test/test-cases.xml` (e.g. `curl -s https://httpbin.org/ip` → allow, `curl -X POST … -d '{…}'` → ask) must remain green under the new rule — verified in the test plan.

## 4. Feature B — `editable_paths` + CWD

### 4.1 Config schema

Mirrors `system_paths`, split as `{linux, windows}` — but with one upgrade: **both sides are raw
regex** (unlike `system_paths`, the `linux` list is not escaped to a literal, so regex works on
Linux paths too).

```jsonc
"editable_paths": {
  "description": "Regex path patterns whose writes are auto-allowed. CWD is always editable. system_paths always asks.",
  "linux":   ["/tmp/", "/home/[^/]+/workspace/.*"],
  "windows": ["c:\\\\temp\\\\.*", "D:\\\\temp\\\\"]
}
```

- `linux` and `windows` are each arrays of **regex** strings, compiled into one alternation (`^(lx1|lx2|wx1|…)`) and matched case-insensitively against the resolved target path. Path separators are normalized before matching, so `/` and `\` both work.
- Optional; defaults to `{linux:[], windows:[]}` (no extra editable locations beyond CWD/temp).

### 4.2 `modifying_strictness` gains a third value: `loose`

| strictness | target ∈ temp/discard | target ∈ system_paths | target ∈ editable_paths ∪ CWD | everything else |
|---|---|---|---|---|
| **strict** | allow | ask | allow | **ask** |
| **normal** | allow | ask | allow | **ask** (when `editable_paths` non-empty) / allow (when empty — current behavior) |
| **loose** | allow | ask | allow | **allow** (additive; `editable_paths`/CWD guaranteed safe, nothing else restricted) |

**CWD is always editable in all three modes.** `system_paths` always asks (wins over everything, including CWD/editable).

`ConfigLoader` validation: `modifying_strictness ∈ {normal, strict, loose}`.

### 4.3 Decision logic in `Test-RedirectionTarget` (applies to `>` and `>>`)

```
normalize target path (resolve relative against CWD; unify separators; lowercase)
if target matches temp/discard  → allow
elif target matches system_paths → ask
elif target matches editable_paths OR target is under CWD → allow
else:
    if strictness == 'loose'  → allow
    if strictness == 'strict' → ask
    if strictness == 'normal' → editable_paths non-empty ? ask : allow
```

### 4.4 CWD source

- The hook runs with CWD = the agent's project directory. Captured once as `$Config._cwd = (Get-Location).Path` during `Load-Config`, normalized (unify separators, add trailing separator, lowercase).
- `TestRunner` can override `$config._cwd` for deterministic redirect tests (mirrors the existing `-Strictness` override).
- "Under CWD" = normalized target path starts with normalized CWD prefix.

### 4.5 `ConfigLoader` compilation

- Compile `editable_paths` (`linux` + `windows`, both raw regex) into `$Config._editablePathRegex = '^(pat1|pat2|…)'`. Set `_editablePathsEnabled` when non-empty. Validate the combined regex compiles.
- Capture `$Config._cwd`.
- Allow `loose` in strictness validation.
- Keep existing `_systemPathRegex` unchanged.

## 5. Affected Files

| File | Change |
|---|---|
| `config.json` | Add `parameter_commands` to `PowerShell` (Invoke-RestMethod, Invoke-WebRequest) and `Linux` (curl, python). Add `editable_paths`. Remove retired `curl` regex entries from `Linux.read_only`/`modifying`. (Optionally set `modifying_strictness`.) |
| `src/ConfigLoader.ps1` | Allow `loose`; validate + compile `editable_paths` → `_editablePathRegex`; capture `_cwd`; validate `parameter_commands` shape; per-domain pre-build `_parameterCommandLookup` (lowercased name+aliases → entry) for O(1) resolve. |
| `src/Resolver.ps1` | New Step 7 `parameter_commands` check + helpers: `Get-PowerShellParameterMap` (AST) and `Get-ShellParameterMap` (tokenizer), unified evaluator. |
| `src/Parser.ps1` (`Test-RedirectionTarget`) | New `editable_paths`/CWD/strictness decision logic; use `$Config._editablePathRegex` and `$Config._cwd`. |
| `src/TestRunner.ps1` | `-Strictness` accepts `loose`; allow `_cwd` override. |
| `test/test-cases.adhoc.xml` | New cases (§6). |
| `test/test-cases.parameter-*.xml` (new) | Dedicated editable_paths mode-matrix files (normal/strict/loose) with `_cwd` override — created during implementation. |

## 6. Test Plan

**Regression (must stay green):** full `test/test-cases.xml`, plus `redirect-normal/strict`, `var-assignment`, `fullpath`, `trustedpattern` suites. The curl migration is verified by the existing curl cases passing under the new rule.

**New cases added to `test/test-cases.adhoc.xml`** (TDD red until implemented):

*PowerShell — random param positions (Invoke-RestMethod / Invoke-WebRequest / aliases)*
- `-Uri "…" -Method Get` → allow · no `-Method` → allow · `-Method Head` → allow
- `-Method Post -Uri "…"` (Method first) → ask · `-Uri "…" -Method Put` (Method last) → ask · `-Method Patch` → ask · `-Method DELETE -Uri X` → ask · `-Method:Post` (colon form) → ask
- `irm -Uri "…" -Method Post` → ask · `iwr -Method Get -Uri "…"` → allow (alias + reorder)
- `$r = Invoke-RestMethod -Uri "…" -Method Post` → ask (var assignment stripped, then rule)

*Embedded / remoting PowerShell*
- `Invoke-Command -ComputerName SRV1 -ScriptBlock { Invoke-RestMethod -Uri "…" -Method Get }` → allow
- `Invoke-Command -ComputerName SRV1 -ScriptBlock { Invoke-RestMethod -Uri "…" -Method Post }` → ask
- `pwsh -Command "Invoke-RestMethod -Method Delete -Uri https://example.com"` → ask
- `$r = Invoke-RestMethod -Method Post -Uri x; Get-Process` → ask (chained)

*curl — random flag positions (Linux)*
- `curl -H "Content-Type: application/json" -d '{"name":"John","age":30}' https://example.com` → ask
- `curl https://example.com -H "Content-Type: application/json" -d '{"name":"John","age":30}'` → ask (flags after URL)
- `curl -X POST https://x` → ask · `curl -X GET https://x` → allow · `curl -s https://httpbin.org/ip` → allow · `curl https://example.com` → allow
- `curl --data '{"a":1}' https://x` → ask · `curl -XDELETE https://x` → ask (attached — **red today**, demonstrates the fix) · `curl -X DELETE https://x` → ask · `curl -F 'file=@x' https://x` → ask · `curl -T file.zip https://x` → ask

*python (Linux)*
- `python --version 2>&1` → allow · `python -V` → allow · `python --help` → allow · `python3 --version` → allow (alias)
- `python gen_t4.py` → ask · `python3 train.py --epochs 10` → ask · `py script.py` → ask (alias)

*editable_paths / CWD (dedicated mode files; a few in adhoc under the configured mode)*
- normal + editable set: `echo hi > out.txt` → allow (CWD) · `echo hi > c:\temp\out.txt` → allow (editable) · `echo hi > ..\sibling\out.txt` → ask (outside CWD/editable)
- any mode: `echo hi > C:\Windows\sys.bat` → ask (system path)
- loose: `echo hi > ..\sibling\out.txt` → allow · strict: `echo hi > out.txt` → allow (CWD editable even in strict)

## 7. Backward Compatibility & Performance

- `parameter_commands` and `editable_paths` are both **optional**. Existing configs without them behave exactly as today.
- Step 7 is gated on an O(1) `_parameterCommandLookup` hit for the command's first token — zero overhead for the vast majority of commands. AST re-parse and tokenization run **only** when a command has an entry.
- `editable_paths` evaluation is a single compiled-regex test plus a CWD prefix check — negligible.
- All parse/tokenize failures **fall through** to the existing pipeline (fail-safe → never silently allow).

## 8. Future Work (out of scope)

- Extend `editable_paths`/`system_paths` gating to file-write commands (`Set-Content`, `Out-File`, `Add-Content`, `New-Item`, `Copy-Item`, `Move-Item`, `del`/`Remove-Item`) by extracting each command's path argument.
- Optional `match: "absent"` / `value_regex` rule kinds if a command ever needs them.
- PowerShell `[Alias()]` resolution for parameter names (currently config-supplied `aliases` only).
