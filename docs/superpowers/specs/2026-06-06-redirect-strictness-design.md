# Redirect Allowance in Normal Mode — Design Doc

Date: 2026-06-06

## Problem

When `modifying_strictness = "normal"`, non-system file creation via `>` and `>>`
should be allowed. Currently all file-creating redirects ask for approval.

## Solution

### 1. `config.json` — new `system_paths` block

Extract hardcoded system path regex into config. Paths are parent prefixes —
all subdirectories under them are also blocked.

```json
"system_paths": {
  "description": "Parent directories where file writes always require approval...",
  "linux":  ["/etc/", "/var/", "/usr/", "/boot/", "/sys/", "/proc/", "/opt/"],
  "windows": ["[A-Za-z]:\\Windows\\", "[A-Za-z]:\\Program Files\\",
              "[A-Za-z]:\\Program Files (x86)\\",
              "%SystemRoot%\\", "%ProgramFiles%\\", "%ProgramFiles(x86)%\\"]
}
```

### 2. `ConfigLoader.ps1` — compile `_systemPathRegex` at load time

Escape linux paths, keep windows patterns as-is (they are already regex),
join with `|`, store under `$Config._systemPathRegex`.

### 3. `Parser.ps1` — `Test-RedirectionTarget`

- Add `[PSCustomObject]$Config` parameter (optional, defaults to `$null` for backward compat)
- Replace hardcoded system-path regex with `$Config._systemPathRegex`
- In normal mode: `>>` to non-system → allow, `>` to non-system → allow
- In strict mode or no Config: original behavior (all non-temp, non-discard → ask)

### 4. `Classifier.ps1` — pass Config

Pass `$Config` to `Test-RedirectionTarget` call.

### 5. `TestRunner.ps1` — add `-Strictness` param

Optional param to override config at runtime for strict-mode testing.

### 6. Test files

- `test/test-cases.redirect-normal.xml` — 22 tests (normal mode)
- `test/test-cases.redirect-strict.xml` — 22 tests (strict mode)

## Test Matrix

| Condition | Normal | Strict |
|-----------|--------|--------|
| `>` to /home/... | allow | ask |
| `>>` to /home/... | allow | ask |
| `>` to /tmp/... | allow | allow |
| `>` to /dev/null, NUL | allow | allow |
| `>` to /etc/... | ask | ask |
| `>>` to /etc/... | ask | ask |
| `>` to C:\Windows\... | ask | ask |
| `2>&1`, `<`, `<<` | allow | allow |
| SSH + `>` non-system | allow | ask |
| SSH + `>` system | ask | ask |
| PowerShell Out-File | ask | ask |
| PowerShell Set-Content | ask | ask |
