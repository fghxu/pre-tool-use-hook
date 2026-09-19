# Implementation review: static-method broad patterns + denylist (2026-09-19)

- **Reviewer**: second-agent code review (GitHub Copilot), 2026-09-19
- **Scope**: commits `2e4af9f` (implementation), `db783c3` (audit-pass tests), `72e1327` (record-key cleanup) against design `docs/superpowers/specs/2026-09-19-static-method-broad-patterns-denylist-design.md`
- **Method**: line-by-line diff review vs design §4/§7/§8/§14; independent re-runs of the fixture suite and full regression; 13 custom edge-case probes (`temp/review-denylist-probes.ps1`); independent collapse re-proof (`temp/review-collapse-proof.ps1`); live-config forensics
- **Verdict**: **engine implementation is faithful and defect-free — no code bugs found.** One **critical operational finding** (live rollout never happened, contradicting the commit/PROGRESS claims), two cosmetic nits.

## 1. What was verified (all PASS)

| Area | Evidence |
|---|---|
| `ConfigLoader.ps1` deny compile | Mirrors design §14.2 exactly: HashSet OrdinalIgnoreCase (Type::Method or bare Method), compiled IgnoreCase regex array, non-array → throw, invalid pattern → fail-fast throw naming `dotnet_static_method_denylist_regex`, optional keys → empty = byte-identical. Placed in scope right after the allow-regex block. |
| `Parser.ps1` deny gate | Inside the `$isStaticCall` branch only (instance calls untouched — probe P2), inserted as (2-pre) before (2a): exact deny on written key / bare name / reflected key, then deny regex on all three; any hit → `return $false`. Matches design §14.3 verbatim. `Classifier.ps1` untouched per design. |
| Root `config.json` | 16 anchored allow rows exactly per design §4 (File row uses the corrected `read\w*`; R3 row retained incl. `replace`); exact list = 1 entry (`guid::NewGuid`); deny entries `gettempfilename`/`getobject`/`intern` (Q4); deny regexes use the TDD-fixed **optional** leading segment `^[\w.]*…` on BOTH Marshal and IsolatedStorage. Loads cleanly. |
| Fixture suite | `test/config/safe-expr-regex`: D1–D11 deny cases (incl. the exact-allow-trap), StaticGreen group (7), nodeny parity (5 + writer control), SDEN-Anchoring pre-flight (thoughtfully documents that Class-C families legitimately match any type's `Get*`/`Parse*` per threat model), SDEN-BadDenyRegex pre-flight. |
| Independent suite run | `pwsh -NoProfile -File test/config/safe-expr-regex/Run-Tests.ps1` → **6/6 PASS**. |
| Independent full regression | `powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1` → **1360/1360, 0 failures** — coder's claim reproduced. |
| Independent collapse re-proof | `temp/review-collapse-proof.ps1` recovered the 249-entry record key from `2e4af9f:config.json` and re-checked each against the shipped rows: **all 248 truly-removed entries match ≥1 allow row and no deny entry.** The single flag, `guid::NewGuid`, is the deliberately-retained exact entry (see F2). |
| Docs | `docs/config-json-guide.md` §3 rewritten correctly (rows, three classes, deny keys, bare form, optional leading segment, parity statement). Design doc status updated, specs relocated to `docs/superpowers/specs/`. |

## 2. Custom edge-case probes (13/13 PASS — `temp/review-denylist-probes.ps1`)

| # | Probe | Expect | Result |
|---|---|---|---|
| P1 | `[IsolatedStorageFile]::GetUserStoreForDomain()` — bare written key, no reflected key | ask | PASS (deny regex optional-prefix works) |
| P2 | `$s.GetTempFileName()` — instance call carrying a denylisted name (custom config with it instance-allowlisted) | allow | PASS (gate is static-only; no spillover — Q6 honored) |
| P3 | `[SYSTEM.IO.PATH]::GETTEMPFILENAME()` | ask | PASS (case-insensitive deny) |
| P4 | `[Foo.Bar]::GetTempFileName()` — unresolvable type | ask | PASS (bare deny on written key) |
| P5 | `[math]::Abs(1)+[System.IO.Path]::GetTempFileName().Length` | ask | PASS (deny propagates through composite) |
| P6 | `[regex]::Replace(...)` | allow | PASS (intended flip from broadened row) |
| P7/P7b | `[guid]::NewGuid()` / `[System.Guid]::NewGuid()` | allow | PASS (exact straggler, both spellings) |
| P8 | `[string]::Intern("x")` | ask | PASS (Q4 explicit deny) |
| P9 | `[System.IO.File]::WriteAllText(...)` | ask | PASS (writer fail-closed, specific reason) |
| P10 | `[int]::Max(3,5)` on root config | allow | PASS (.NET 9+ primitive static, Class-A row) |
| P11 | `[System.IO.Path]::GetTempFileName()` as bare statement (Layer-2 atomic path) | ask | PASS |
| P12 | `[System.Diagnostics.Process]::GetProcesses()` | allow | PASS (deny regex does not over-deny pure neighbors) |

## 3. Findings

### F1 — CRITICAL (operational, not code): the LIVE config was never rolled out

The commit message ("config.local.json (live, gitignored): same collapse + R1 backport") and
PROGRESS.md ("Live rollout (3 files)… LIVE config.local.json got the same PLUS R1…") are **false for
the live file**. Forensics:

- `PRETOOLHOOK_CONFIG_PATH` (User) = `C:\git\cc\pretoolhook\config.local.json` (verified earlier this session)
- That file's `LastWriteTime` = **2026-09-17 23:38** — before all three implementation commits (09-19 05:05/05:28/14:41)
- Still contains the old **256-entry** exact list; grep shows **no** `dotnet_static_method_denylist`, no `dotnet_static_method_allowlist_regex`, no `trusted_programs_regex` (so R1/R3 are *still* not live either — the second time this drift class has appeared)

**Impact**: no safety regression (old config = old conservative behavior; `GetTempFileName` was never
on the old allowlist, writers were never allowed) — but production receives **none** of the new
coverage and the denylist does not exist in production.

**Remediation**: perform the design §8 step 2 rollout on the real `config.local.json` (16 rows + deny
keys + R1 backport; its 256-entry list has ~7 live-only entries vs root's 249 — re-run a collapse
proof against THAT list, e.g. adapt `temp/review-collapse-proof.ps1`), smoke-test via
`temp/Classify.ps1 -ConfigPath <live>`, then correct the PROGRESS/commit-message record. Being
gitignored, this file's state cannot be verified from git — claims about it need a probe, not prose.

### F2 — Minor (bookkeeping): the inert record key over-listed by one

`dotnet_static_method_allowlist_removed` (commit `2e4af9f`, later removed by `72e1327`) contained
**249** entries including `guid::NewGuid` — which was *retained* as the single exact entry, not
removed. Harmless (key was never loaded; now deleted; recoverable from `2e4af9f`), but anyone
re-running a collapse proof against that key will get one false alarm. The PROGRESS wording
"248 of 249 pruned" is the accurate version.

### F3 — Minor (referenced artifact missing): `temp/collapse-proof.ps1` does not exist

Both the root config comment and PROGRESS cite `temp/collapse-proof.ps1` as the preservation proof,
but the file is absent (temp/ is gitignored; it was not preserved). The claim itself is TRUE — this
review re-proved it independently (`temp/review-collapse-proof.ps1`, all 248 covered, none denied) —
but the cited evidence is not reproducible from the repo. Either commit the proof script somewhere
tracked or re-point the references.

### F4 — Cosmetic: stale regex text in one test's `reason` attribute

`test-cases.xml` category `SDeny-RegexWrittenSpelling` (D5) still quotes the pre-fix pattern
`^\w[\w.]*marshal::get\w*$`; the config and design doc correctly use `^[\w.]*…`. Display-only
(assertions are decision-based). One-line fix whenever convenient.

### F5 — Cosmetic (by design, worth knowing): denied statics render the generic ask reason

When a denied static appears in the certifier path, the ask reason is "unsafe PowerShell expression
(fail-closed)" rather than "static method not on allowlist", because the allow regex *does* match
(the truthfulness guard in Classifier only knows allowlisted-or-not, not denied-vs-unlisted).
Decision is correct in all cases; the design explicitly scoped Classifier out. A future enhancement
could surface "denied by static denylist" wording — requires a small design amendment + Classifier
change, not a bug.

## 4. Security posture of the new gate (positive findings)

- **Precedence is real**: deny-exact > deny-regex > exact-allow > allow-regex, proven by D1 (same
  key exact-allowed AND denied → ask) and the nodeny parity suite (absent keys = pre-deny behavior).
- **Scope discipline**: static calls only; instance side untouched (P2).
- **Fail-closed everywhere**: unresolvable types still caught via written key/bare name (P1/P4);
  invalid deny regex kills the config at load (outage-visible, not silent).
- **No new injection surface**: keys are built from AST type/method names; all regexes compiled once
  at load with IgnoreCase; anchored rows cannot substring-match (`SDEN-Anchoring` + design D1).
- **Writers/mutators unaffected**: `File::Write*`/`OpenWrite`, `Array::Sort`, `Directory::Create`,
  `Environment::Set*`, `Process::Start`, `Assembly::Load`, `Task::Run` all still ask (suite + P9).

## 5. Recommended actions (priority order)

1. **Do F1's live rollout now** (manual, gitignored file) + fix the PROGRESS/commit record. Until
   then, production has neither the new coverage nor the denylist.
2. Commit or re-point the collapse proof (F3); optionally note F2's off-by-one in PROGRESS.
3. Optional polish: D5 reason text (F4); denied-specific ask wording (F5, needs design amendment).
4. Continue the soak on `feature_fix` per policy; merge to master only after the live rollout is
   verified by probe.

## 6. Artifacts produced by this review

- `temp/review-denylist-probes.ps1` — 13 edge-case probes (all PASS)
- `temp/review-collapse-proof.ps1` — independent collapse re-proof (248/248 covered, 0 denied; 1 expected flag = retained `guid::NewGuid`)
- This report.

## 7. Post-review resolution (2026-09-19, same day)

- **F1 RESOLVED (+ one incident)**: the user applied the live rollout to `config.local.json` (16 rows + deny keys + R1 backport + exact list → `guid::NewGuid`, verified by key-inventory probe). **However, that edit initially introduced a literal `".*"` into `trusted_pattern` — a full production bypass** (any command auto-allowed; caught by this review's smoke probe: `Remove-Item -Recurse -Force C:\temp\important-stuff` → `allow / matched trusted pattern: .*`; a non-editable-path delete would also have been allowed). The user removed the entry; post-fix verification against the live config: non-editable delete → **ask (high)**; `GetTempFileName()` → **ask** (denylist live); `[math]::Sqrt(2)` → **allow** (rows live). Note: deletes under `C:\temp` allow — that is R2 editable-delete working as designed (`editable_paths`), not a bypass.
- **F2 WONTFIX (user decision)**: `guid::NewGuid` stays as the single exact entry; the tombstone off-by-one is moot (tombstone deleted in `72e1327`).
- **F3 RESOLVED**: the "restored" `temp/collapse-proof.ps1` was not on disk (global `*collapse*` search found only the review prober). The review prover was installed under the cited path, upgraded to skip still-retained exact entries: now reports **249 checked, 0 problems, exit 0**. Replace with the original if a copy surfaces.
- **F4/F5 RESOLVED (2026-09-19, red/green TDD by the reviewer)**: F4 — D5 `reason` text now quotes the shipped `^[\w.]*marshal…` form. F5 — denied statics now get deny-specific ask wording (`static method denied by denylist: [Type]::Method (see safe_expressions.dotnet_static_method_denylist)`) at both sites: Classifier.ps1 Layer-2 atomic path (new priority: denied > not-on-allowlist > generic fail-closed) and Resolver.ps1 Step-3 static fallback, via the new `Test-StaticDeniedByText` helper (Parser.ps1, text-based: written key + bare name — no AST at those sites). New suite cases D12/D13 (`reason-contains="denied by denylist"`); RED confirmed exactly 2 failures, then GREEN; full regression 1360/1360, zero flips. **The red/green run caught a real latent bug**: the pre-existing allow-regex loop clobbers `$Matches` (groupless Class-C rows null out `$Matches[1]`), which crashed the first F5 implementation on 5 deny cases — fixed by capturing type/method into locals immediately after the outer `-match`; wording-only change, decisions untouched.
- Lesson recorded: live-config claims need probe verification (this session caught two separate live-config incidents — the missing rollout and the `.*` bypass — that were both believed done).
