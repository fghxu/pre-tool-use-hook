# Design: consolidate `dotnet_static_method_allowlist` into regex rows + static denylist

**Date:** 2026-09-19
**Status:** IMPLEMENTED (2026-09-19). Q1–Q8 approved as recommended; red/green TDD complete. Two deviations from the original text, both recorded inline: (a) D5's deny regex leading segment is `[\w.]*` not `\w[\w.]*` — the original form required a non-empty prefix and missed the bare `[Marshal]` written key (caught by RED case D5); (b) Q4's `"intern"` deny entry added an 11th fixture case (D11), so the RED count is 7, not 6. Rollout done: root `config.json` pruned 248→1 exact (`guid::NewGuid`) + 16 rows + deny keys; live `config.local.json` got the same plus the R1/R3 backport; `test/config/live/` re-synced. **Audit pass (2026-09-19, second day):** line-by-line re-check of every section against the implementation found §7/§8/§9/§4 all implemented verbatim, but §10's GREEN acceptance cases G1/G2/G3/G5/G6/G8/G9 and the G10 no-deny-keys parity check were never added to the fixture suite — now implemented (new `StaticGreen` group in test-cases.xml + `config.nodeny.json`/`test-cases.nodeny.xml` + `SDEN-NoDenyParity` runner block). No code change was needed: G3's `[ref]$y` argument is already certifier-safe because PowerShell parses it as a `ConvertExpressionAst` (handled, ~line 2236), not a bare `ReferenceExpressionAst`. Full regression after the audit pass: **1360/1360 passed, zero flips**.
**Supersedes (both):**
- `Update-2026-09-19-static-allowlist-regex-consolidation.md` ("draft A v2 MERGED" — contributed the Class A/B/C structure, D1 anchoring, `getobject` deny, blanket Marshal/IsolatedStorage denies, and the `serialize` question; its config example still had the File-row writer bug, dropped the R3 row, and used type-anchored deny regexes that miss alias spellings — all fixed here)
- v1/v2 of this file (broad cross-type families only; subsumed by draft A's richer structure)

**Follows:** R3 (2026-09-18) which introduced `dotnet_static_method_allowlist_regex` (`2026-09-18-regex-allowlists-and-editable-delete-design.md`).

---

## 1. Motivation & threat model

The exact `dotnet_static_method_allowlist` keeps growing: every new official BCL static the LLM emits must be hand-added. Most entries follow repetitive shapes (`math::Abs`, `int::Parse`, …) that collapse into a handful of regex rows; outliers of a broad rule (`Path::GetTempFileName` creates a file) go into a NEW **static denylist** that takes precedence over all allow rules.

- **Driver:** "I am tired of keep adding the new command into this list."
- **Threat model (load-bearing assumption, user-stated):** commands are LLM-generated → LLMs only use official Microsoft classes/functions → a curated set of method-name families is safe; rare outliers go into the denylist.
- **Consequence accepted:** broad patterns also match *third-party* types (`[Newtonsoft.Json.Linq.JObject]::GetValues()` would be allowed). The denylist is an escape hatch, not a general boundary (§11 Risk 1).

Scope: static-side `safe_expressions` keys + the two new deny keys. The instance-side `dotnet_method_allowlist(_regex)` allowlists are untouched (Q6).

## 2. Current mechanism (verified in code)

Decision path for `[Type]::Method(...)` in expression position — `Test-SafeAst`, `src/Parser.ps1` ~2243–2310 (`InvokeMemberExpressionAst` branch `(2)`):

1. Builds **two candidate keys** per call:
   - **written key** — type as written: `math::Abs`, `int::Parse`, `io.path::Combine`
   - **reflected key** — `$Ast.Expression.TypeName.GetReflectionType().FullName` + `::` + method: `system.math::abs`, `system.int32::parse`, `system.io.path::combine`; `$refl = $null` when the type cannot be resolved (then only the written key exists).
2. Exact `HashSet` `_dotnetStaticMethodAllowlist` (OrdinalIgnoreCase) tried against both keys.
3. On miss, R3 regex array `_dotnetStaticMethodAllowlistRegex` (Compiled + IgnoreCase, **unanchored** `-match`) tried against both keys, first hit wins.
4. Miss → `return $false` → fail-closed → ask.

`src/Classifier.ps1` ~634–640 (Layer-2 atomic-unknown path) reuses the same sets only to decide the ask REASON wording ("static method not on allowlist" vs generic fail-closed). Decision is already `ask` there; a denylisted method is definitionally "not on allowlist", so the message stays truthful — **no change needed in Classifier.ps1** (verified: those are the only two references to the static sets outside Parser/ConfigLoader).

### 2.1 Verified consequences that shape the design

- **Unanchored matching is a footgun.** An unanchored `(int|long|byte|bool|guid|enum)::.*` would match `system.drawing.point::x` and `printqueue::…` because `int::` is a literal substring of `point::`. Likewise `file::read` ⊂ `profile::read`. → **Decision D1: every allow AND deny regex row is anchored `^…$`.** With `^` anchoring the alternation must match at the segment start, so the substring hazard disappears by construction (proven by the runner-level assertions in §10).
- **The dual-key match makes substring tricks unnecessary.** An anchored `^(system\.)?math::` matches BOTH the written (`math::Abs`) and reflected (`system.math::abs`) keys. Rows may list both spellings via optional prefixes (`^(system\.io\.)?path::`).
- **Alias ≠ full-name for primitives.** `[int]` reflects to `system.int32`, so a single `(system\.)?` prefix cannot cover both the written alias (`int::abs`) and the reflected full name (`system.int32::abs`). Primitive rows must list **both** spellings in the alternation (§4).
- **Lazy vs greedy is a no-op here.** `.*::Get(.*?)$` ≡ `.*::Get.*` for boolean `-match` (we never read capture groups). Greedy form used throughout.

## 3. Rule classes

Not every type can be wildcarded the `math` way, because some types mix pure and mutating statics. The governing principle: **if a type is provably all-pure, make it Class A (whole-type); only use Class B (prefix) for types that genuinely mix pure and mutating; Class C families are the cross-type net so we never have to enumerate every type.**

| Class | Meaning | Types |
|---|---|---|
| **A — whole-type wildcard** | every public static provably read-only | `math`, `convert`, `bitconverter`, `string`*, `path`†, `uri`, `datetime`, `datetimeoffset`, `timespan`, `version`, `guid`, `enum`, `ipaddress`, all primitives‡, `text.encoding`, `linq.enumerable` |
| **B — type + method-prefix** | type HAS mutating statics; allow only pure prefixes | `file`, `directory`, `environment`, `array`, `console` |
| **C — cross-type method-name family** | method name alone implies pure, on any type (the "never enumerate" net) | `::Parse*` (incl. Try/Exact), `::Get*`, `::Is*`, `::To*`, `::From*` |
| **D — denylist (NEW)** | overrides every allow rule; checked FIRST. Exact entries may be `Type::Method` OR **bare `Method`** (any type) | `gettempfilename`, `getobject`, IsolatedStorage/Marshal `Get*` regexes |

\* `string` newly allows `Intern` + `Create` — see Q4. † `path` is the showcase for D: every `Path` static is pure **except** `GetTempFileName` (creates a zero-byte file); `GetRandomFileName` is PURE (returns a name string, no file) and stays allowed. ‡ Primitives are Class A because **all** their statics are pure math/conversion — see Q7 (draft A deleted these rows on the theory that families cover them; families only cover `Parse/TryParse` + the `Is*`/`To*` predicates, leaving REAL stragglers asking: `Decimal::Add/Subtract/Multiply/Divide/Round/Truncate/Negate/Remainder`, `Char::ConvertFromUtf32/ConvertToUtf32`, `Double::Sin/Abs/Max`, `Int32::Max/Min/Abs` — all verified by actual invocation on .NET 10, 2026-09-19. Correction to the review fix: only `Compare`/`Format` from the earlier example list were wrong (those live on `Math`/`String`/`Enum`); `Abs/Max/Min/Sin` ARE real primitive statics).

**Why all three classes earn their place:**
- Class C alone would miss non-family members of pure types (`math::Abs`, `convert::ChangeType`, `string::Format`, `uri::CheckHostName`, `datetime::Compare/DaysInMonth`, `enum::Format`) — Class A covers those.
- Class A alone would require enumerating every type the LLM might call (`Dns::GetHostEntry`, `DriveInfo::GetDrives`, `GC::GetTotalMemory`, third-party) — Class C covers those without enumeration.
- Class B is required for mixed types where a whole-type wildcard would allow writers (`file::OpenWrite`, `array::Sort`).

## 4. Proposed config

```jsonc
"dotnet_static_method_allowlist_regex": [
  // R3 row — RETAINED. (Draft A's example dropped it; that regresses regex::Matches/Replace/Split back to ask.)
  "^(regex|system\\.text\\.regularexpressions\\.regex)::(match(es)?|ismatch|replace|split|escape|unescape)$",

  // Class A — whole-type (every public static provably read-only; reflection-verified 2026-09-19)
  "^(system\\.)?(math|convert|bitconverter|string)::\\w+$",
  "^(system\\.io\\.)?path::\\w+$",                                  // minus denied GetTempFileName
  "^system\\.(uri|datetime|datetimeoffset|timespan|version|guid|enum|net\\.ipaddress)::\\w+$",
  "^system\\.(text\\.encoding|linq\\.enumerable)::\\w+$",
  // Class A — primitives (all statics pure; BOTH alias + full-name spellings, because [int] reflects to system.int32)
  "^(system\\.)?(int32|int|int64|long|int16|short|uint32|uint|uint64|ulong|uint16|ushort|single|float|double|decimal|byte|sbyte|char|boolean|bool)::\\w+$",

  // Class B — type + method prefix (type has mutating statics; ALL pure prefixes listed, incl. family-covered ones, for explicitness)
  "^(system\\.io\\.)?file::(read\\w*|openread|opentext|exists|get\\w*)$",   // FIXED twice: draft A's bare 'open' allowed OpenWrite/OpenHandle/bare Open (writers); review fix — 'readall' missed ReadLines; 'read\w*' is safe: NO File writer starts with 'Read'
  "^(system\\.io\\.)?directory::(get|enumerate|exists)\\w*$",
  "^(system\\.)?environment::(get|expand)\\w*$",
  "^(system\\.)?array::(binarysearch|indexof|lastindexof|find\\w*|exists|trueforall|convertall|empty|asreadonly)$",
  "^(system\\.)?console::read\\w*$",

  // Class C — cross-type method-name families (any type; the user's original ask + Tier-2)
  "^\\w[\\w.]*::(try)?parse\\w*$",
  "^\\w[\\w.]*::get\\w*$",
  "^\\w[\\w.]*::is\\w*$",
  "^\\w[\\w.]*::to\\w*$",
  "^\\w[\\w.]*::from\\w*$"
],
"dotnet_static_method_denylist": [
  // bare-name form: matches the method on ANY type, any spelling — closes the
  // unresolvable-type gap ([path]::GetTempFileName() produces no reflected key)
  "gettempfilename",   // only Path has it — creates a zero-byte file
  "getobject"          // Microsoft.VisualBasic.Interaction::GetObject — COM launch from moniker
],
"dotnet_static_method_denylist_regex": [
  // TAIL-anchored (not type-head-anchored) so they catch BOTH the reflected full name
  // AND non-canonical written spellings ([IsolatedStorageFile]::GetStore() -> written key
  // 'isolatedstoragefile::getstore', no reflected key when the assembly isn't loaded).
  // Leading segment is OPTIONAL ([\w.]*, not \w[\w.]*) so a BARE spelling like [Marshal]
  // (written key 'marshal::getactiveobject', no reflected key) is still denied — TDD fix
  // 2026-09-19: the original ^\w[\w.]* form required a non-empty prefix and missed D5.
  "^[\\w.]*isolatedstoragefile::get\\w*$",   // GetStore/GetUserStoreFor*/GetMachineStoreFor* — create stores on disk
  "^[\\w.]*marshal::get\\w*$"                // interop Gets: GetActiveObject, GetTypeFromCLSID, RCW wrappers
]
```

Notes:
- **D1 anchoring** on every row, allow and deny (draft A's own `isolatedstorage.*::…` deny entry was missing its leading `^` — fixed above).
- Class C uses `^\w[\w.]*::` instead of `^.*::` — same coverage for real type names, but it cannot match a key with an empty type part (defensive; `-match` is already case-insensitive via the compiled options).
- The denylist_regex entries are the resilient forms of the exact entries: they also catch non-canonical written spellings such as `[io.path]::GetTempFileName()` whose written key would miss a type-qualified exact entry. Belt-and-braces — fail-closed holds regardless.
- **Bare-name deny form** (Q3): an exact deny entry without `::` (e.g. `"gettempfilename"`) matches the method-name portion of ANY type. Closes the alias-spelling gap where a type can't be reflection-resolved and only the written key exists.

## 5. Row-by-row rationale (reflection-verified 2026-09-19, local BCL scan)

| Row | Covers | Why safe / what it excludes |
|---|---|---|
| R3 row | `regex::Match/Matches/IsMatch/Replace/Split/Escape/Unescape` | retained from 2026-09-18; pure string ops |
| `(math\|convert\|bitconverter\|string)::` | all statics of four purely computational types. `convert` stays whole-type because `ChangeType` (pure) is reached by NO family | `math` pure (`DivRem` out-param, `BigMul`, `Clamp`, `SinCos`); `BitConverter::DoubleToInt64Bits`/`TryWriteBytes` pure (the latter writes into a caller-supplied span — in-process only, acceptable under the threat model); `Convert::To*`/`From*`/`ChangeType` pure; `string` statics incl. **`Intern`**, **`Create`** (callback arg recursively AST-walked by `Test-SafeAst` — verified: `ScriptBlockAst`/`ScriptBlockExpressionAst` recurse, so a malicious scriptblock arg still fails closed) — previously excluded by caution, now deliberately allowed (Q4) |
| `path::` | `Combine`, `GetFullPath`, `GetRandomFileName`, `GetTempPath`, … | all pure except denylisted `GetTempFileName`; also newly covers the 4 safe gaps found by the scan (`Exists`, `TryJoin`, `EndsInDirectorySeparator`, `IsPathFullyQualified`) |
| `system.(uri\|datetime…)` | `uri`: TryCreate/Escape*/Unescape*/Hex*/Check*; `datetime(offset)`/`timespan`: immutable, From*/Parse*/Compare; `version`, `guid` (`NewGuid` pure), `enum` (`GetNames`/`Format` etc.), `ipaddress` | all in-memory. `DateTime` is immutable — `AddMinutes` returns a new instance, touches nothing (user: "in memory only, don't change the computer system" — agreed) |
| primitive row | `[int]::Parse`, `[long]::TryParse`, `[decimal]::Add/Divide/Round`, `[char]::ConvertToUtf32`, `[double]::Sin`, `[int]::Max` (BOTH spellings) | all primitive statics are pure math/conversion. Anchored `^` prevents the `Point::`/`printqueue::` substring bug; `\w+` tail covers Try/Exact forms. See Q7 for why whole-type beats families-only here. (Correction 2026-09-19: `[double]::Sin` and `[int]::Max` DO exist as real static methods — verified by actual invocation on .NET 10; the review fix that claimed otherwise was itself wrong.) |
| `(text.encoding\|linq.enumerable)::` | `Encoding::GetEncoding/Convert` (statics only); all 74 `Enumerable::*` (lazy, pure) | pure |
| `file::(read\|openread\|opentext\|exists\|get)` | `ReadAllText/Bytes/Lines`, `ReadLines`, `OpenRead`, `OpenText`, `Exists`, `GetAttributes`, `Get*Time*` | **FIXED vs draft A:** its `(read\|open\|exists\|get)\w*` matched `OpenWrite`, `OpenHandle`, and bare `Open` (defaults to Read/Write) — verified by test. Review fix (2026-09-19): the first correction `readall\w*` missed `ReadLines` (pure, exact-allowed today); `read\w*` restores it and is safe because NO `File` writer starts with `Read` (writers are `Write*/Append*/Create*/Copy/Move/Delete/Replace/OpenWrite/SetAttributes/Encrypt/Decrypt`) |
| `directory::(get\|enumerate\|exists)` | `GetFiles/Directories/…`, `Enumerate*`, `Exists`, `GetLogicalDrives`, `GetCurrentDirectory` | excludes `Create*`/`Delete`/`Move`/`SetCurrentDirectory`/`Set*Time` |
| `environment::(get\|expand)` | `GetEnvironmentVariable(s)`, `GetFolderPath`, `GetCommandLineArgs`, `ExpandEnvironmentVariables`, `GetLogicalDrives` | excludes `SetEnvironmentVariable`/`Exit`/`FailFast` |
| `array::(…)` | `BinarySearch`, `IndexOf`/`LastIndexOf`, `Find*`, `Exists`, `TrueForAll`, `ConvertAll`, `Empty`, `AsReadOnly` | **`Array` must NOT be type-wildcarded**: `Sort`/`Reverse`/`Clear`/`Copy`/`Resize`/`Fill` mutate in place |
| `console::read` | `Read`, `ReadLine`, `ReadKey` | consistent with `Read-Host` (read_only verb). `ReadKey` blocks interactively — same posture as existing read-only cmdlets. Excludes `Write*`/`Beep`/`Set*`/`Clear` |
| `::(try)?parse\w*` | any `Parse`/`ParseExact`/`TryParse`/`TryParseExact` + suffixed parses (`Language.Parser::ParseInput/ParseFile`) on any type (`JsonDocument`, `XDocument`, …) | no known BCL static `Parse*` mutates. The `\w*` tail is REQUIRED — plain `.*::parse` would miss `TryParse` (no `::parse` substring in `int::tryparse`), and `(try)?parse(exact)?$` would miss `ParseInput`/`ParseFile` (verified by test) |
| `::get\w*` | any Get-prefixed static on any type — subsumes `Process::GetProcesses*`, `ServiceController::GetServices/GetDevices`, `DriveInfo::GetDrives`, `Dns::GetHost*`, `GC::GetTotalMemory`, `Registry::GetValue` | outliers → denylist (§4). This is the user's original `.*::Get(.*?)$` ask, in greedy form (lazy ≡ greedy for `-match`) |
| `::is\w*` | predicates: `IsNullOrEmpty`, `IsDefined`, `IsLeapYear`, `IsLoopback`, `IsComObject`, `IsPathRooted`, … | pure by definition; probe found no non-pure `Is*` static on the risky non-allowlist types either |
| `::to\w*` | conversions: `ToInt32`, `ToBase64String`, `ToObject`, `ToString`, … also `PSParser::Tokenize` ("To…" prefix) | pure. (Covers `PSParser::Tokenize` and `Language.Parser` is covered by the parse family — so no separate SMA row is needed.) |
| `::from\w*` | representation-ctors: `FromBinary`, `FromUnixTimeSeconds`, `FromBase64String`, `FromFileTime`, … | pure, in-memory — covers `DateTimeOffset`/`TimeSpan` statics wholesale (user's DateTime reasoning: in-memory only, never touches the system — agreed) |

**Dropped from the wishlist:**
- `::search` — no BCL static *starts* with `Search` (`Regex` uses `Match/Matches`; search methods are named `BinarySearch`, `IndexOf`, `Find*`; `DirectorySearcher` is instance-only). Dead weight (Q5: drop, confirmed by both reflection scans).
- `::(serialize\|deserialize)` — **rejected** (Q8): `Serialize` is NOT uniformly pure — `JsonSerializer.SerializeToStream/SerializeAsync` and `XmlSerializer.Serialize(stream, obj)` write to streams. A blanket `serialize` family would allow I/O writers. `deserialize` is safe but low-value; if wanted later, add it as its own row.

**Families deliberately NOT broadened** (traps found by the scan): `Set*` (`Environment::SetEnvironmentVariable`, `File::SetAttributes/Set*Time`, `Directory::SetCurrentDirectory`, `Console::Set*`), `Write*/Append*/Create*/Delete*/Move*/Copy*/Replace*`, `Start*` (`Process::Start`), `Sort*/Clear*/Fill*/Reverse*/Resize*`, `Exit/FailFast`. These stay exact-list-only or simply unlisted (fail-closed).

## 6. What deliberately still asks (unchanged fail-closed posture)

`File::Write*` / `OpenWrite` / `OpenHandle` / `Delete` / `Copy` / `Move`, `Directory::Create*/Delete/Move/SetCurrentDirectory`, `Environment::SetEnvironmentVariable/Exit/FailFast`, `Array::Sort/Reverse/Clear/Copy/Resize/Fill`, `Assembly::Load`, `Task::Run`, `Activator::CreateInstance`, `RandomNumberGenerator::Create`, `GC::Collect`, `Process::Start`, `[scriptblock]::Create`, `Console::Write*/Beep/Set*`, `JsonSerializer.SerializeToStream` — none start with a Class-C family prefix on a Class-A type, so they keep asking.

## 7. Code changes (small, two files)

### `src/ConfigLoader.ps1` (~25 lines, mirrors the existing R3 block at ~line 430)
- `dotnet_static_method_denylist` → `_dotnetStaticMethodDenylist`: `HashSet[string]`, OrdinalIgnoreCase; entries lowercased verbatim (both `Type::Method` and bare `Method` forms stored as-is). Must be an array or throw.
- `dotnet_static_method_denylist_regex` → `_dotnetStaticMethodDenylistRegex`: compiled `[regex][]`, IgnoreCase|Compiled; **invalid pattern throws at load** (fail-fast, consistent with R3 — remember: config load failure = total hook outage).
- Both optional; absent = empty = byte-identical behavior to before this change.

### `src/Parser.ps1` (~20 lines in `InvokeMemberExpressionAst`)
- Compute `$writtenKey` / `$refl` slightly earlier (currently built inside the allow branch).
- New **(2-pre) deny gate BEFORE (2a)**:
  ```
  if static call:
      denied = exact set hit on written key OR reflected key OR bare method name
             OR any deny regex matches written key OR reflected key OR bare method name
      if denied: return $false        # deny always wins over exact AND regex allow
  ```
- Allow ladder (2a)/(2b) unchanged.

### `src/Classifier.ps1` — ~~no change~~ AMENDED (F5, 2026-09-19 post-implementation): the Layer-2 atomic-unknown reason now says `static method denied by denylist: [Type]::Method` when the matched static is denied (wording only; decision stays ask). The same wording was added to the Resolver Step-3 static fallback. Shared helper `Test-StaticDeniedByText` in Parser.ps1 (text-based: written key + bare method name — those sites have no AST/reflection). The TDD red/green run also caught and fixed a latent `$Matches`-clobber bug: the allow-regex loop re-runs `-match` and can null out `$Matches[1]` (groupless Class-C rows), so the atomic path now captures the type/method into locals immediately after the outer match.

## 8. Config rollout (three files, not one)

**Discovery (2026-09-19):** the LIVE hook reads `config.local.json`, NOT the tracked root `config.json` — verified: `PRETOOLHOOK_CONFIG_PATH` (User scope) = `C:\git\cc\pretoolhook\config.local.json`. That file currently has **256 exact entries and none of yesterday's keys** (no `trusted_programs_regex`, no `dotnet_static_method_allowlist_regex`) — i.e. the production hook has not actually received the R1/R3 work; yesterday's "live proof" only touched the tracked generic config + test fixtures.

Rollout order:
1. `config.json` (tracked, generic default) — apply §4 rows + deny keys + exact-list prune (§9).
2. `config.local.json` (LIVE) — apply the SAME changes, preserving its machine-specific extras (log paths, gateway/model, local trusted programs). **Includes backporting R1 (`trusted_programs_regex`) and R3 (the regex row)** so production actually gets them.
3. `test/config/live/` via `Sync-Fixtures.ps1` (syncs from root; guard requires `llm_second_opinion.enabled=false` + strictness=normal — verify first).

**Mechanical collapse-preservation proof (mandatory, not optional):** before re-syncing, run a smoke script that for every removed exact entry E asserts (a) E matches at least one allow row and (b) E matches no deny entry. Precedent: `C:\temp\verify-regex-collapse.ps1` (R1/R3).

## 9. Exact-list collapse (behavior-preserving)

Once the rows land, these exact entries become redundant and are **removed** (the maintenance burden this work exists to kill):
- all Class-A-type entries: `math::*` (29), `Convert::*` (15), `BitConverter::*` (16), `string::*` (9), `Path::*` (17), `Uri::*` (10), `DateTime/DateTimeOffset/TimeSpan/Version/Guid/Enum/IPAddress::*`, all primitive Parse/TryParse entries
- all Class-B-covered entries: `File::Read*/OpenRead/Exists/Get*` (13), `Directory::*` (14), `Environment::*` (4), `Array::*` (13), `Console::ReadLine`
- the 7 `regex::*` entries are ALREADY gone (R3 collapse, 2026-09-18) — the R3 row in §4 keeps them covered

Everything not matched by a row stays. Net: ~183 exact entries → roughly **5–10 exact + 20 regex rows**.

## 10. Test plan (red/green; fixture = `test/config/safe-expr-regex/`)

**TDD structure note:** the allow rows are *config-only* — they work immediately via the existing R3 regex mechanism, so the "allow" cases go green as soon as the rows are added to the fixture config (no code needed). The only **code** being implemented is the denylist (ConfigLoader + Parser gate). Therefore the RED phase = add allow rows + deny entries to the fixture config; the deny cases fail because the code doesn't support deny yet. GREEN phase = implement the code → deny cases pass.

Fixture config gains: the §4 rows, one exact allow entry (`system.io.path::gettempfilename` — deliberately ALSO denied), the denylist + deny regexes.

**RED cases (fail before code, pass after) — all deny-related:**

| # | Command | Expect | Why red now / green after |
|---|---|---|---|
| R1 | `$z=@(); $f=[System.IO.Path]::GetTempFileName()` | **ask** | Now: exact entry + `path::` row + `get` family all allow it. After: bare deny `gettempfilename` wins → ask. Proves **deny-exact beats exact-allow + family**. |
| R2 | `$z=@(); $f=[io.path]::GetTempFileName()` | **ask** | Now: `get` family matches written key `io.path::gettempfilename` (unresolvable type → no reflected key) → allowed. After: deny catches the alias spelling → ask. Proves **deny works on non-canonical written spellings**. |
| R3 | `$z=@(); $s=[System.IO.IsolatedStorage.IsolatedStorageFile]::GetStore()` | **ask** | Now: `get` family allows it (no bare deny for `getstore`). After: tail-anchored deny regex `^\w[\w.]*isolatedstoragefile::get\w*$` blocks → ask. Proves the **type-scoped deny REGEX** specifically (the only mechanism that denies this). |
| R4 | config with an invalid deny regex | `Load-Config` throws | Now: unknown key ignored → no throw. After: fail-fast parity with R3 → throw. |

**GREEN cases (pass before AND after — acceptance + guards):**

| # | Command | Expect | Notes |
|---|---|---|---|
| G1 | `$z=@(); $null=[System.IO.File]::GetAttributes("c:\temp\x")` | allow | `get` family / file Class B |
| G2 | `$z=@(); $x=[int]::Parse("42")` | allow | parse family / primitive Class A |
| G3 | `$z=@(); [void][int]::TryParse("42",[ref]$y)` | allow | `\w*` tail proof (plain `.*::parse` would miss this) |
| G4 | `$z=@(); $n=[System.IO.Path]::GetRandomFileName()` | allow | pure, contrast with R1/R2 |
| G5 | `$z=@(); $s=[math]::Sqrt(2)` | allow | math Class A whole-type |
| G6 | `$z=@(); $r=[System.Linq.Enumerable]::Range(1,10)` | allow | enumerable Class A (new coverage) |
| G7 | `$z=@(); [void][System.IO.File]::OpenWrite("c:\temp\x")` | **ask** | file Class B excludes writers; NOT a `get` family match either — guards the §4 File-row fix |
| G8 | `$z=@(); [void][Array]::Sort($a)` | **ask** | Array not wildcarded |
| G9 | `$z=@(); $t=[System.IO.File]::ReadAllText('c:\temp\x')` | allow | file Class B `read` |
| G9b | `$z=@(); $l=[System.IO.File]::ReadLines('c:\temp\x')` | allow | `read\w*` tail proof — v3's first correction `readall\w*` missed this (review fix 2026-09-19) |
| G10 | config WITHOUT deny keys | byte-identical behavior | optional-key parity |

**Runner-level assertions (not end-to-end commands):** for every Class A/B/C row, assert it does NOT match a set of known-bad keys (`system.drawing.point::x`, `printqueue::foo`, `profile::read`) — the D1 anchoring proof. Plus the 5 existing fixture cases must stay green.

**Red count = exactly 4** (R1–R4). Then: §8 rollout → full regression (expect 1357 + new fixture cases; zero flips). One explicit check during that phase: grep live XML for any case expecting **ask** on a `::Get*`/`::Parse*` static — if one exists it is an intended flip and gets retargeted (same procedure as the R1 `src\other.ps1` case).

Optional hardening: extend `C:\temp\verify-static-list.ps1` to assert per Class-A type that EVERY public static matches at least one allow row (guards against future .NET additions slipping into a wildcarded type unnoticed).

## 11. Risks (approved-with-eyes-open)

1. **The threat model IS the safety case.** `^\w[\w.]*::get\w*$` also matches third-party types (`[Newtonsoft.Json.Linq.JObject]::GetValues()` would be allowed). Accepted because LLMs emit official MS classes; the denylist is the escape hatch, not a general boundary.
2. **Future BCL versions:** a future `Path::GetSomethingThatCreates` would slip through until a deny entry is added. Mitigation: doc note — "re-run the reflection scan when upgrading .NET" + the optional Class-A completeness assertion (§10).
3. **Deny regexes are `-match` (compiled IgnoreCase)** — D1 says we anchor them, but a future sloppy deny pattern could over-deny; that is fail-*closed* (safe direction), just annoying.
4. **`config.local.json` divergence:** the live config has drifted from the tracked one (256 vs 183 entries, no R1/R3 keys). This change reconciles them for the static-allowlist surface; other drift (machine-specific extras) is preserved, not normalized.

## 12. Decision points (pending user approval)

- **Q1:** Anchoring — D1 (anchor every row `^…$`) vs short unanchored rows accepting rare substring over-matches? Recommendation: **D1** (the `Point::`/`printqueue::` footgun is real and the cost is zero).
- **Q2:** Exact-list fate — prune to just the regex rows (recommended; it IS the maintenance burden being killed) vs keep both (exact = O(1) belt-and-suspenders)? Recommendation: **prune**, with the §8 mechanical preservation proof.
- **Q3:** Bare-name deny entry form (`gettempfilename` = any type) — include? Recommendation: **yes** (closes the alias-spelling gap; one `split '::'`).
- **Q4:** `string::` whole-type now allows `Intern` + `Create` (both pure; `Create`'s callback is AST-walked) — previously excluded by caution. Recommendation: **allow both, but add `"intern"` to the denylist** so the long-documented exclusion becomes an explicit, auditable decision rather than a silent policy flip (one-line change to allow if you later disagree).
- **Q5:** `::search` row — drop (recommended; no BCL static starts with `Search`) vs keep as future-proofing? Recommendation: **drop**.
- **Q6:** Instance-side denylist (`dotnet_method_denylist`) for symmetry — add now or defer? Recommendation: **defer** (no known instance-method outlier today; the key can be added later without breaking anything).
- **Q7:** Primitives + value-types (`datetimeoffset/timespan/version/enum/ipaddress`) as **Class A whole-type** (recommended — all statics provably pure, maximizes coverage per your goal) vs **families-only** (draft A's choice — only `Parse/TryParse/From/Get/Is/To` covered)? Recommendation: **Class A** — the "families cover them" premise is false for the real non-family stragglers (`Decimal::Add/Subtract/Multiply/Divide/Round/Truncate/Negate/Remainder`, `Char::ConvertFromUtf32/ConvertToUtf32`, `Double::Sin/Abs/Max`, `Int32::Max/Min/Abs` — all verified by actual invocation on .NET 10, 2026-09-19), and whole-type is strictly more coverage at one line each. (Correction: the review fix that claimed `Abs/Max/Min/Sin` were "Math members, not primitive statics" was itself wrong — only `Compare`/`Format` from the original example list were non-primitive.)
- **Q8:** `::(serialize|deserialize)` row — include? Recommendation: **no** for `serialize` (`JsonSerializer.SerializeToStream/Async`, `XmlSerializer.Serialize(stream,…)` write to streams — a blanket family would allow I/O writers); `deserialize` is safe but low-value, add later as its own row if ever needed.

## 13. Out of scope

- Instance-call (`$obj.Method()`) allow patterns — separate name-only lists, unchanged (except optional Q6 deny extension).
- `dotnet_method_allowlist` (instance) broadening.
- Any change to the LLM second-opinion layer — this is purely local-classifier config + certifier plumbing.

## 14. Cold-start appendix: everything an implementing agent needs (no other reading required)

### 14.0 Independent verification note (2026-09-19, second reviewer)

The primitive-statics claim in §3/Q7 was independently re-verified by reflection on the local
runtime (.NET 10): `Int32` public statics = `Abs,BigMul,Clamp,CopySign,Create*,DivRem,Is*,Log2,Max,
MaxMagnitude,Min,MinMagnitude,Parse,PopCount,Rotate*,Sign,TryParse,...`; `Double` additionally has
`Sin,SinCos,Sqrt,Pow,Tan,Cbrt,Hypot,Round,...`; `Decimal` has `Add/Subtract/Multiply/Divide/Round/
Truncate/Negate/Remainder/FromOACurrency/GetBits/To*`; `Char` has `Convert*Utf32/Is*/To*/Parse`.
**Concession: the earlier review fix claiming `[double]::Sin`/`[int]::Max` "do not exist" was wrong
for .NET 10** (true only for .NET ≤ 8; .NET 9 added static math members to primitives). Every
listed static is pure — the primitive Class-A row is safe on this runtime.

### 14.1 Edit map (exact anchors)

| File | Where | What |
|---|---|---|
| `src/ConfigLoader.ps1` | Immediately AFTER the block that compiles `_dotnetStaticMethodAllowlistRegex` (~line 437–453, ends with `Add-Member -Name '_dotnetStaticMethodAllowlistRegex'`) | Compile the two deny structures (sketch in 14.2) |
| `src/Parser.ps1` | `Test-SafeAst`, `'InvokeMemberExpressionAst'` branch, static-call section: hoist `$writtenKey`/`$refl` above the `(2a)` exact-allow check, add the deny gate (sketch in 14.3) | Deny-first gate |
| `test/config/safe-expr-regex/config.json` | `safe_expressions` | Add the §4 regex rows, the deny keys, AND one deliberate exact allow entry `"System.IO.Path::GetTempFileName"` (it must still be denied — precedence proof) |
| `test/config/safe-expr-regex/test-cases.xml` | New `<category-group name="StaticDeny">` | The 10 cases in 14.5 |
| `test/config/safe-expr-regex/Run-Tests.ps1` | New pre-flight after `SER-BadRegex` | `SDEN-BadDenyRegex`: `Load-Config` on a new `config.baddenylregex.json` must throw with a message matching `dotnet_static_method_denylist_regex` (mirror the SER-BadRegex block; also create that fixture file with `"dotnet_static_method_denylist_regex": ["^("]`) |
| `config.json` + `config.local.json` + `Sync-Fixtures.ps1` | Per §8, ONLY after the suite is green | Rollout (live file needs the R1/R3 backport too) |

Keep `Run-Tests.ps1` pure ASCII (powershell.exe 5.1 misreads UTF-8 punctuation).

### 14.2 ConfigLoader sketch (paste-adapt)

```powershell
# safe_expressions: STATIC denylist (exact, Type::Method or bare Method) + regex.
# Deny is checked FIRST in Test-SafeAst and outranks every allow path.
$denySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$denyRegexes = @()
if ($hasSafeExprs -and $Config.safe_expressions -and
    (Get-Member -InputObject $Config.safe_expressions -Name 'dotnet_static_method_denylist' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
    $Config.safe_expressions.dotnet_static_method_denylist) {
    if ($Config.safe_expressions.dotnet_static_method_denylist -isnot [array]) {
        throw "Configuration validation failed: 'safe_expressions.dotnet_static_method_denylist' must be an array"
    }
    foreach ($d in $Config.safe_expressions.dotnet_static_method_denylist) { [void]$denySet.Add(("$d").ToLowerInvariant()) }
}
if ($hasSafeExprs -and $Config.safe_expressions -and
    (Get-Member -InputObject $Config.safe_expressions -Name 'dotnet_static_method_denylist_regex' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and
    $Config.safe_expressions.dotnet_static_method_denylist_regex) {
    if ($Config.safe_expressions.dotnet_static_method_denylist_regex -isnot [array]) {
        throw "Configuration validation failed: 'safe_expressions.dotnet_static_method_denylist_regex' must be an array"
    }
    foreach ($p in $Config.safe_expressions.dotnet_static_method_denylist_regex) {
        try {
            $denyRegexes += [regex]::new("$($p)", [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        catch { throw "Invalid regex in safe_expressions.dotnet_static_method_denylist_regex: $($p)" }
    }
}
$Config | Add-Member -MemberType NoteProperty -Name '_dotnetStaticMethodDenylist' -Value $denySet -Force
$Config | Add-Member -MemberType NoteProperty -Name '_dotnetStaticMethodDenylistRegex' -Value $denyRegexes -Force
```

### 14.3 Parser deny-gate sketch (paste-adapt, insert BEFORE the (2a) exact-allow check)

```powershell
$writtenKey = "$($Ast.Expression.TypeName.FullName)::$methodName"
$refl = $null
try { $refl = $Ast.Expression.TypeName.GetReflectionType() } catch { $refl = $null }
$reflKey = if ($refl) { "$($refl.FullName)::$methodName" } else { $null }
$bareName = "$methodName"
$denySet = $null; $denyRegexes = @()
if ($Config) {
    if (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylist' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $denySet = $Config._dotnetStaticMethodDenylist }
    if (Get-Member -InputObject $Config -Name '_dotnetStaticMethodDenylistRegex' -MemberType NoteProperty -ErrorAction SilentlyContinue) { $denyRegexes = @($Config._dotnetStaticMethodDenylistRegex) }
}
$denied = $false
if ($denySet -and ($denySet.Contains($writtenKey) -or $denySet.Contains($bareName) -or ($reflKey -and $denySet.Contains($reflKey)))) { $denied = $true }
if (-not $denied) {
    foreach ($re in $denyRegexes) {
        if ($null -eq $re) { continue }
        if ($writtenKey -match $re -or $bareName -match $re -or ($reflKey -and $reflKey -match $re)) { $denied = $true; break }
    }
}
if ($denied) { return $false }
# ...existing (2a) exact allow / (2b) regex allow continue unchanged below...
```

### 14.4 Commands (from repo root)

```
pwsh -NoProfile -File test/config/safe-expr-regex/Run-Tests.ps1        # suite; exit 0 = green
powershell.exe -ExecutionPolicy Bypass -File src/Run-AllTests.ps1      # full regression (suite auto-discovered)
```
RED phase expectation: exactly **6** failures — the 5 deny XML cases (D1–D5 below) + `SDEN-BadDenyRegex`
(deny keys not yet compiled → no throw). GREEN: all pass; full regression zero flips (baseline 1357
+ new cases). TDD rule (project): red first, then code, then green — no skipping.

### 14.5 The 10 test cases (paste into `test/config/safe-expr-regex/test-cases.xml`)

D1–D5 are RED pre-code (deny not implemented → they currently allow); D6–D10 are GREEN guards
(config-only, pass once the fixture rows land). `$z = @();` is REQUIRED — it is the PowerShell-domain
marker that routes zero-cmdlet statements through the safe-expression certifier.

```xml
<category-group name="StaticDeny">

  <!-- D1 RED: bare-name deny outranks EXACT allow + Class-A path row + get family (fixture deliberately exact-allows this key too) -->
  <test-case expected="ask" reason="deny (bare gettempfilename) beats exact allow + path row + get family" category="SDeny-ExactBeatsAllAllows">
    <description>$z = @(); $f=[System.IO.Path]::GetTempFileName() - also in fixture exact allowlist; deny must win</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $f=[System.IO.Path]::GetTempFileName()]]></copilot-command>
  </test-case>

  <!-- D2 RED: bare-name deny catches a non-canonical written spelling ([io.path] short form) -->
  <test-case expected="ask" reason="bare-name deny catches alias spelling io.path::GetTempFileName" category="SDeny-BareAliasSpelling">
    <description>$z = @(); $f=[io.path]::GetTempFileName() - written key io.path::gettempfilename; bare deny fires on the method name</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $f=[io.path]::GetTempFileName()]]></copilot-command>
  </test-case>

  <!-- D3 RED: type-scoped deny REGEX (the only mechanism that denies this) -->
  <test-case expected="ask" reason="tail-anchored deny regex isolatedstoragefile::get*" category="SDeny-TypeScopedRegex">
    <description>$z = @(); $s=[System.IO.IsolatedStorage.IsolatedStorageFile]::GetUserStoreForDomain() - creates store on disk</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $s=[System.IO.IsolatedStorage.IsolatedStorageFile]::GetUserStoreForDomain()]]></copilot-command>
  </test-case>

  <!-- D4 RED: bare-name deny for the COM-launcher GetObject (Microsoft.VisualBasic.Interaction) -->
  <test-case expected="ask" reason="bare-name deny getobject (Interaction::GetObject launches COM via moniker)" category="SDeny-BareGetObject">
    <description>$z = @(); $o=[Microsoft.VisualBasic.Interaction]::GetObject('C:\temp\x.xlsx') - COM server launch</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $o=[Microsoft.VisualBasic.Interaction]::GetObject('C:\temp\x.xlsx')]]></copilot-command>
  </test-case>

    <!-- D5 RED: deny regex matches the SHORT written spelling of Marshal (unresolvable without namespace).
         TDD fix 2026-09-19: pattern is ^[\w.]*marshal::get\w*$ (optional leading segment) — the original
         ^\w[\w.]* form required a non-empty prefix and missed this bare-spelling case. -->
    <test-case expected="ask" reason="deny regex ^[\w.]*marshal::get\w*$ matches written key marshal::getactiveobject" category="SDeny-RegexWrittenSpelling">
    <description>$z = @(); $o=[Marshal]::GetActiveObject('Excel.Application') - interop Get denied on any spelling</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $o=[Marshal]::GetActiveObject('Excel.Application')]]></copilot-command>
  </test-case>

  <!-- D6 GREEN: get family matches the WRITTEN key of an unresolvable type (third-party accepted per threat model) -->
  <test-case expected="allow" reason="Class-C get family on written key of unresolvable type" category="SAllow-FamilyWrittenKeyOnly">
    <description>$z = @(); $v=[Foo.Bar]::GetValues('x') - written key foo.bar::getvalues; no reflected key</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $v=[Foo.Bar]::GetValues('x')]]></copilot-command>
  </test-case>

  <!-- D7 GREEN: primitive Class-A row covers .NET 9+ static math members (pins the corrected Q7 evidence) -->
  <test-case expected="allow" reason="primitive whole-type row covers int::Max (.NET 9+ static)" category="SAllow-PrimitiveNet10Math">
    <description>$z = @(); $m=[int]::Max(3, 5) - Int32 static math member, pure</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $m=[int]::Max(3, 5)]]></copilot-command>
  </test-case>

  <!-- D8 GREEN: file Class-B row read\w* tail covers ReadLines (the readall\w* regression guard) -->
  <test-case expected="allow" reason="file row read\w* covers ReadLines" category="SAllow-FileReadLines">
    <description>$z = @(); $l=[System.IO.File]::ReadLines('c:\temp\x') - streaming reader, pure</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $l=[System.IO.File]::ReadLines('c:\temp\x')]]></copilot-command>
  </test-case>

  <!-- D9 GREEN: contrast with D1 - same type, neighbor method stays allowed -->
  <test-case expected="allow" reason="path row + get family allow GetRandomFileName (pure, no file created)" category="SAllow-GetRandomFileName">
    <description>$z = @(); $n=[System.IO.Path]::GetRandomFileName() - returns a name string only</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); $n=[System.IO.Path]::GetRandomFileName()]]></copilot-command>
  </test-case>

  <!-- D10 GREEN guard: file writer stays ask (OpenWrite not matched by any row or family) -->
  <test-case expected="ask" reason="file Class B excludes writers; openwrite matches no row/family" category="SAsk-FileOpenWrite">
    <description>$z = @(); [void][System.IO.File]::OpenWrite('c:\temp\x') - writer, fail-closed</description>
    <tool-name>Bash</tool-name>
    <copilot-command><![CDATA[$z = @(); [void][System.IO.File]::OpenWrite('c:\temp\x')]]></copilot-command>
  </test-case>

</category-group>
```

Precedence order proven by this set: **deny exact (bare/type-qualified) > deny regex > exact allow >
allow regex** (D1 pins the strongest pair: deny-exact vs exact-allow + row + family simultaneously).
