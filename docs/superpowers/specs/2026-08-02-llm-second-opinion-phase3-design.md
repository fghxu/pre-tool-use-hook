# LLM Second-Opinion — Phase III Design: Stage-2 Path-Guard

**Date:** 2026-08-02
**Status:** Implemented (branch `llm-second-opinion`)
**Builds on:** `2026-08-02-llm-second-opinion-phase2-design.md` (attributed verdicts; P4 reserved this hook)

---

## 1. The hole

Phase II suppresses LLM flags on `strictness_gated` sub-commands — the flood-killer
that makes the feature usable at `normal` strictness. But the gated tier contains
**writable cmdlets whose path arguments are never path-checked by the local engine**
(`Resolve-PathPolicy` only covers redirect targets and file-tool paths; pinned by
TP-CmdPaths as a documented trade-off of the all-gated config).

Consequence (traced through phase II as shipped):

```
Set-Content -Path C:\Windows\x.txt -Value x ; git status        (normal strictness)
  1. local:  Set-Content * gated -> allow (argument never inspected)
  2. LLM:    {"modifying":[1]}   (correct — it sees the semantics)
  3. merge:  tier=strictness_gated -> stage-1 guard always-safe -> SUPPRESSED
  4. FINAL:  allow. Nobody asks. The write to C:\Windows sails through.
```

The one case where the local engine is blind AND the LLM is right gets discarded
by the suppression. Phase III closes exactly that subset — nothing else.

## 2. Decisions (user-approved 2026-08-02)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Guard, not removal.** Keep suppression; gate it on a path check. | Removing suppression brings back the phase-I git flood. |
| D2 | **Writer name-list scope: PS writable family + DOS/Linux basics** (user pick) | The name-list drives only the variable rule (§3.4). The path scan (§3.3) is command-agnostic — git/terraform destinations get checked opportunistically for free; no positional extraction is attempted anywhere, so their fuzziness objection is moot. |
| D3 | **Reuse `Resolve-PathPolicy` verbatim** (user pick) | Protected = whatever the user's own path policy already asks on: system always; temp/CWD/editable suppressible; foreign only when it would ask locally; loose mode untouched. Zero new policy surface. |
| D4 | **Generic token scan, no positional table** (user pick, over option-1 AST table and option-3 config table) | Interleaved flags (`rm /tmp/x -rf`) break positional maps. Hardened with three refinements below. |
| D5 | **Class-B noise accepted** (user pick) | Source-vs-destination is not distinguished: `Copy-Item FROM C:\Windows` vetoes although it only reads. ~0–2 prompts/month, each naming the path. The mirror (skip-listing Copy-Item) would open the copy-INTO-system32 hole — rejected. |
| D6 | **No `trusted_pattern` remedies** | trusted_pattern is a whole-command gate that bypasses decomposition AND redirect classification; using it to carve exceptions re-opens the H1/H2 class. Exceptions live inside the guard (skip-list). |
| D7 | **trusted_pattern LLM coverage dropped; H1–H6 parked** (user ruling) | trusted/untrusted lists are exception-only and normally empty; fast-path gate hits never reach the LLM (no SubResults) — accepted, documented. H1/H2 remediated by the user in config. |

## 3. The guard algorithm (`Test-GatedInvocationSafe`, src/LlmReview.ps1)

Input: the flagged gated sub-command **text** (raw string). Returns `$true` =
safe to suppress, `$false` = deny (the merge's existing veto path fires).

1. **Tokenize** quote-aware (`Split-GuardTokens`): `"C:\Windows\my file.txt"`
   stays ONE token, quotes stripped — no quote-smuggling. Unbalanced quotes keep
   the remainder as one token (fail-safe direction).
2. **Skip-list** (`printf`, `setx`; path/`.exe`-insensitive basename): arguments
   are data, never write targets → always safe.
3. **Path-shape scan**: every token matching drive-absolute (`C:\…`),
   UNC (`\\…`), or POSIX-absolute (`/…`) goes through `Resolve-PathPolicy`;
   any `ask` → **deny**. Relative paths are not scanned (CWD-relative =
   writable in every mode).
4. **Fail-closed variable rule** (H5 class): a **known writer** (name-list of
   content/out-file/export/item cmdlets + aliases + `mkdir`/`move`/`ren`/`ln`/
   `unzip`) with an unresolved `$var`/`%VAR%` argument AND **no literal path
   token** → **deny** (`%TEMP%`/`%TMP%`/`$env:TEMP`/`$env:TMP` excepted).
   Rationale for the literal-path escape: `Set-Content C:\temp\a.txt $content`
   (variable in the VALUE) is an everyday shape and must not prompt;
   `Set-Content $reportPath x` (variable IS the target) cannot be proven safe.

Gated commands with no path tokens and no writer variables (git, terraform,
New-Object, …) behave exactly as stage-1 — the flood stays suppressed.

## 4. Reconciliation

- Merge records `$log.path_guard_denied = [indices]` — gated flags the guard
  REFUSED to suppress (distinct from tier-vetoes).
- `.log` RECONCILE line: `... veto=[N] path-guard denied: [N] -> FINAL: ...`.
- JSONL `llm` object gains `path_guard_denied`.

## 5. Accepted residuals (documented, not fixed)

- **Class-B source noise:** `Copy-Item C:\Windows\System32\calc.exe C:\temp\`
  vetoes (read mistaken for write; conservative by D5).
- **Writer + literal safe path + variable TARGET slips:**
  `Copy-Item C:\temp\a.dll $dest` suppresses even if `$dest` is `C:\Windows`
  (rule 4 only fires when NO literal path token exists — the price of keeping
  `Set-Content <file> $value` quiet).
- **POSIX system paths on Windows:** `/etc/x` canonicalizes to `C:\etc\x`
  before matching, so POSIX `system_paths` entries do not protect at normal —
  pre-existing engine behavior, unchanged.
- **Lone single-command blocks** stay out of LLM scope at `complex_*` levels;
  the guard only sees in-scope blocks.
- **git/terraform destination dirs** (`git clone x C:\Windows\y`,
  `terraform providers mirror <dir>`): scanned like any token by rule 3 —
  they get the check for free; extraction fuzziness was the reason D2 excluded
  them from a positional table, the generic scan has no such problem.

## 6. Tests (fixture `test/config/llm-review/`, mock `idx:` — zero quota)

Fixture config gained `system_paths` (without it the compiled regex matches
NOTHING and the guard could never deny — quadruple-backslash Windows entries)
and gated entries Copy-Item / printf / mkdir (mirroring live).

G7 group in `test-cases.p2.large.xml` (12 cases): system-path veto · quoted
spaced path veto · variable-target veto · variable-value suppressed ·
`$env:TEMP` suppressed · `%SystemRoot%` veto · Copy-Item source veto (noise
pin) · Copy-Item dest veto · printf skip · mkdir system veto · relative-path
suppressed · `path-guard denied: [1]` log marker.

Verified: large 78/78, small 24/24, phase-I 32/32, http 27/27,
Run-AllTests 962/962, sandbox 938/938, codex 17/17.
