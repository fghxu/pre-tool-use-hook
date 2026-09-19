# Design: consolidate `dotnet_static_method_allowlist` into regex rows + static denylist

> **SUPERSEDED (2026-09-19):** consolidated into `2026-09-19-static-method-broad-patterns-denylist-design.md` (v3), which keeps this doc's Class A/B/C structure, D1 anchoring, `getobject` deny, and blanket Marshal/IsolatedStorage denies, but fixes three issues in this draft's config example: (1) the Class-B `file` row `(read|open|exists|get)\w*` matches the writers `OpenWrite`/`OpenHandle`/bare `Open` (verified by test); (2) the proposed regex array dropped the existing R3 row, which would regress `regex::Matches/Replace/Split` back to ask; (3) the type-head-anchored deny regexes (`^system\.io\.isolatedstorage\..*::get\w*$`) miss non-canonical written spellings like `[IsolatedStorageFile]::GetStore()` (written key `isolatedstoragefile::getstore`, no reflected key when the assembly isn't loaded) — v3 uses tail-anchored forms. It also adds the `config.local.json` live-config rollout (§8 there) and restores primitives as Class A (this draft's families-only deletion would leave `Abs/Max/Sin/Compare/Format` asking). Do NOT implement from this file.

- **Date**: 2026-09-19
- **Status**: SUPERSEDED — see banner above. **No code written yet.**
- **Follows**: R3 (2026-09-18) which introduced `dotnet_static_method_allowlist_regex` (see `docs/superpowers/specs/2026-09-18-regex-allowlists-and-editable-delete-design.md`).

## 1. Motivation

The exact `dotnet_static_method_allowlist` (183 entries, verified by reflection 2026-07-31) keeps growing:
every new official BCL static the LLM emits must be hand-added. Most entries follow repetitive shapes
(`math::Abs`, `math::Acos`, …, `int::Parse`, `long::Parse`, …) that collapse into a handful of regex rows.
Outliers of a broad rule (e.g. `Path::GetTempFileName` creates a file) are handled by a NEW
**static denylist** that takes precedence over all allow rules.

Scope: static-side `safe_expressions` keys + the new denylist. The instance-side
`dotnet_method_allowlist(_regex)` allowlists are untouched; an optional instance-side bare-name
DENY extension is §9 Q6.

## 2. Current mechanism (verified in code)

Decision path for `[Type]::Method(...)` in expression position — `Test-SafeAst`,
`src/Parser.ps1` ~2270–2310 (branch `(2)` of `InvokeMemberExpressionAst`):

1. Builds **two candidate keys** per call:
   - **written key** — type as written: `math::Abs`, `int::Parse`, `io.path::Combine`
   - **reflected key** — `$Ast.Expression.TypeName.GetReflectionType().FullName` + `::` + method:
     `system.math::abs`, `system.int32::parse`, `system.io.path::combine`
2. Exact `HashSet` `_dotnetStaticMethodAllowlist` (OrdinalIgnoreCase) tried against both keys.
3. On miss, R3 regex array `_dotnetStaticMethodAllowlistRegex` (Compiled + IgnoreCase, **unanchored**
   `-match`) tried against both keys, first hit wins.

`src/Classifier.ps1` ~634–655 (Layer-2 atomic-unknown truthfulness path) reuses the same sets only to
decide the ask REASON wording ("static method not on allowlist" vs generic fail-closed). Decision is
already `ask` there; a denylisted method is definitionally "not on allowlist", so the message stays
truthful — **no change needed in Classifier.ps1**.

### 2.1 Two verified consequences that shape the design

- **Unanchored matching is a footgun.** Proposed-by-user row `(int|long|byte|bool|guid|enum)::.*`
  would match `System.Drawing.Point::X` and `PrintQueue::…` because `int::` is a literal substring
  of `point::`. Likewise `file::read` ⊂ `profile::read`. → **Decision D1: every regex row is anchored
  `^…$`.**
- **The dual-key match makes substring tricks unnecessary.** An anchored `^(system\.)?math::` already
  matches BOTH the written (`math::Abs`) and reflected (`system.math::abs`) keys. Rows may therefore
  list both spellings via optional prefixes (`^(system\.io\.)?path::`) or rely on the reflected key
  when the written spelling is uncommon (`io.path::…` fails written, matches reflected).

## 3. Rule classes

Not every type can be wildcarded the `math` way, because some types mix pure and mutating statics.

| Class | Meaning | Examples |
|---|---|---|
| **A — whole-type wildcard** | every static member provably read-only | `math`, `bitconverter`, `convert`, `string`, `uri`, `datetime`, `guid`, `path`* |
| **B — type + method-prefix** | type HAS mutating statics; allow only pure prefixes | `file`, `directory`, `environment`, `array`, `console` |
| **C — cross-type method-name families** | method name alone implies pure, on any type | `::Parse*`, `::Get*`, `::Is*`, `::To*`, `::From*` (last three borrowed Tier-2) |
| **D — denylist (NEW)** | overrides every allow rule; checked FIRST. Exact entries may be `Type::Method` OR **bare `Method`** (any type) | `gettempfilename`, `getobject`, IsolatedStorage/Marshal deny regexes |

\* `path` is the showcase for D: every `Path` static is pure **except** `GetTempFileName` (creates a
zero-byte file). `GetRandomFileName` is PURE — it only returns a name string, no file — and stays allowed.

Merge note (v2): the Tier-2 families `Is*/To*/From*` and the bare-name deny form are borrowed from
the sibling doc `2026-09-19-static-method-broad-patterns-denylist-design.md`. The families make
several v1 rows redundant (primitives, `datetimeoffset`, `timespan`, `version`, `enum`,
`ipaddress`, SMA parsers — see §5).

## 4. Proposed config (v2 merged)

```jsonc
"dotnet_static_method_allowlist_regex": [
  // Class A — whole-type (every static provably read-only; families don't reach all members)
  "^(system\\.)?(math|bitconverter|convert|string)::\\w*$",
  "^(system\\.io\\.)?path::\\w*$",                                    // minus denied Get* (see denylist)
  "^system\\.(uri|datetime|guid)::\\w*$",
  "^system\\.(text\\.encoding|linq\\.enumerable)::\\w*$",
  // Class B — type + method prefix (type has mutating statics)
  "^(system\\.io\\.)?file::(read|open|exists|get)\\w*$",
  "^(system\\.io\\.)?directory::(get|enumerate|exists)\\w*$",
  "^(system\\.)?environment::(get|expand)\\w*$",
  "^(system\\.)?array::(binarysearch|indexof|lastindexof|find\\w*|exists|trueforall|convertall|empty|asreadonly)\\w*$",
  "^(system\\.)?console::read\\w*$",
  // Class C — cross-type method-name families (any type; Is/To/From borrowed from sibling doc)
  "^[\\w.]+::(try)?parse\\w*$",
  "^[\\w.]+::get\\w*$",
  "^[\\w.]+::is\\w*$",
  "^[\\w.]+::to\\w*$",
  "^[\\w.]+::from\\w*$"
],
"dotnet_static_method_denylist": [
  // bare-name form: matches the method on ANY type, any spelling — closes the
  // unresolvable-type gap ([path]::GetTempFileName() produces no reflected key)
  "gettempfilename",   // only Path has it — creates a zero-byte file
  "getobject"          // Microsoft.VisualBasic.Interaction::GetObject — moniker COM launch
],
"dotnet_static_method_denylist_regex": [
  "^system\\.io\\.isolatedstorage\\..*::get\\w*$",           // GetStore/GetUserStoreFor*/GetMachineStoreFor* — create stores on disk
  "^system\\.runtime\\.interopservices\\.marshal::get\\w*$"  // interop Gets: RCW wrappers, GetTypeFromCLSID, PS5.1 GetActiveObject (Q7)
]
```

Type-qualified exact deny entries (`Type::Method`) remain supported for a method that is unsafe on
ONE type only; none are needed in the seed set — the bare-name + type-scoped regex forms above
cover all known outliers (probe evidence in §10).

## 5. Row-by-row rationale

| Row | Covers (reflection-verified or reasoned) | Why safe |
|---|---|---|
| `(math\|bitconverter\|convert\|string)::` | all statics of four purely computational types. `convert` stays whole-type because `ChangeType` (pure) is reached by NO family | `math` pure (`DivRem` out-param, `BigMul`, `Clamp`); `BitConverter::DoubleToInt64Bits` pure; `Convert::To*`/`From*`/`ChangeType` pure; `string` statics incl. **`Intern`**, **`Create`** (callback arg recursively AST-walked by `Test-SafeAst`) — previously excluded by caution, now deliberately allowed (§9 Q4) |
| `path::` | `Combine`, `GetFullPath`, `GetRandomFileName`, `GetTempPath`, … | all pure except denylisted `GetTempFileName` |
| `system.(uri\|datetime\|guid)::` | `uri`: TryCreate/Escape*/Unescape*/Hex*/Check*; `datetime`: DaysInMonth/Compare/SpecifyKind; `guid`: NewGuid | in-memory; written keys like `datetime::DaysInMonth` miss the anchor but the REFLECTED key (`system.datetime::daysinmonth`) matches |
| `(text.encoding\|linq.enumerable)::` | `Encoding::Convert` (static), `Enumerable::Range/Chunk/…` (all 76, lazy) | pure |
| `file::(read\|open\|exists\|get)` | `ReadAllText/Bytes/Lines`, `OpenRead`, `Exists`, `GetAttributes`, `Get*Time*` | `open`+`\w*` covers `OpenRead`; excludes `Write*`/`Append*`/`Delete`/`Copy`/`Move`/`Create`/`SetAttributes` |
| `directory::(get\|enumerate\|exists)` | `GetFiles/Directories/…`, `Enumerate*`, `Exists`, `GetLogicalDrives`, `GetCurrentDirectory` | excludes `Create`/`Delete`/`Move`/`SetCurrentDirectory` |
| `environment::(get\|expand)` | `GetEnvironmentVariable`, `GetFolderPath`, `GetCommandLineArgs`, `ExpandEnvironmentVariables` | excludes `SetEnvironmentVariable`/`Exit`/`FailFast` |
| `array::(…)` | `BinarySearch`, `IndexOf`/`LastIndexOf`, `Find*`, `Exists`, `TrueForAll`, `ConvertAll`, `Empty`, `AsReadOnly` | **`Array` must NOT be type-wildcarded**: `Sort`/`Reverse`/`Clear`/`Copy`/`Resize`/`Fill`/`Initialize` mutate |
| `console::read` | `Read`, `ReadLine`, `ReadKey` | consistent with `Read-Host` (read_only verb). `ReadKey` blocks interactively — same posture as existing read-only cmdlets |
| `::(try)?parse\w*` | any `Parse`/`ParseExact`/`TryParse(Exact)` + suffixed parses (`Language.Parser::ParseInput/ParseFile`) on any type (`JsonDocument`, `XDocument`, …) | no known BCL static `Parse*` mutates. The `\w*` tail is REQUIRED — the sibling doc's `(try)?parse(exact)?$` misses `ParseInput`/`ParseFile`; plain `.*::Parse` would also miss `TryParse` |
| `::get\w*` | any Get-prefixed static on any type — subsumes `Process::GetProcesses*`, `ServiceController::GetServices`, `DriveInfo::GetDrives`, `Dns::GetHost*`, `GC::GetTotalMemory`, `Registry::GetValue` | outliers → denylist; probe-verified exceptions: IsolatedStorage store-Gets, `Interaction::GetObject`, Marshal interop Gets (§10). The user's original `.*::Get(.*?)$` non-greedy form is a **no-op**: lazy vs greedy only affects capture groups, not boolean `-match` |
| `::is\w*` (borrowed Tier-2) | predicates: `IsNullOrEmpty`, `IsDefined`, `IsLeapYear`, `IsLoopback`, `IsComObject`, `IsPathRooted`, … | pure by definition; probe found no non-pure `Is*` static on the risky non-allowlist types either |
| `::to\w*` (borrowed Tier-2) | conversions: `ToInt32`, `ToBase64String`, `ToObject`, `ToString`… also `PSParser::Tokenize` ("To…" prefix) | pure |
| `::from\w*` (borrowed Tier-2) | representation-ctors: `FromBinary`, `FromUnixTimeSeconds`, `FromBase64String`, `FromFileTime`, … | pure, in-memory — covers `DateTimeOffset`/`TimeSpan` statics wholesale (user's DateTime reasoning: in-memory only, never touches the system — agreed, `DateTime` is immutable) |

### Rows DELETED vs v1 (now covered by Class-C families)

| v1 row | Now covered by |
|---|---|
| primitive alias row + `system.(int32\|int64\|…)` row | primitives' only statics are `Parse`/`TryParse` → parse family (anchored `\w.]+::` families have no type-substring hazard) |
| `datetimeoffset`/`timespan`/`version`/`enum`/`net.ipaddress` in the system.* row | `Parse*`/`From*`/`Is*`/`To*`/`Get*` families (e.g. `[timespan]::FromDays`, `[enum]::GetNames`, `[datetimeoffset]::FromUnixTimeSeconds`) |
| SMA `(psparser\|language.parser)` row | `PSParser::Tokenize` → to family; `Parser::ParseInput`/`ParseFile` → parse family (`\w*` tail) |

Dropped from the user's wishlist: `::search` — BCL statics named `Search*` are essentially
nonexistent (`Regex` uses `Match`/`Matches`; `DirectorySearcher` is instance-only). The sibling doc
keeps it as future-proofing; this design drops it (§9 Q3).

## 6. What deliberately still asks (unchanged fail-closed posture)

`File::Write*` / `Delete` / `Copy`, `Directory::Create/Delete/Move`, `Environment::SetEnvironmentVariable`,
`Array::Sort/Reverse/Clear/Copy/Resize/Fill`, `Assembly::Load`, `Task::Run`, `Activator::CreateInstance`,
`RandomNumberGenerator::Create`, `GC::Collect`, `Process::Start`, `[scriptblock]::Create`,
`String::Intern`-class surprises — none start with Get/Parse or sit on a Class-A type, so they keep asking.

## 7. Implementation surface (after approval; strict red/green TDD)

1. `src/ConfigLoader.ps1` — compile two new optional siblings, mirroring the existing allow side
   (array validation; invalid regex THROWS at load — remember: config load failure = total hook outage,
   always re-run `Load-Config` after editing):
   - `dotnet_static_method_denylist` → `_dotnetStaticMethodDenylist` (HashSet, OrdinalIgnoreCase)
   - `dotnet_static_method_denylist_regex` → `_dotnetStaticMethodDenylistRegex` (Compiled + IgnoreCase array)
2. `src/Parser.ps1` `Test-SafeAst` static branch — insert **(2-pre) deny check BEFORE (2a)**:
   deny-exact against written+reflected keys, then deny-regex against both; any hit ⇒ `return $false`
   immediately (deny always wins over exact AND regex allow).
3. `src/Classifier.ps1` — no change (§2).
4. Config rewrite — `config.json` (tracked) AND `config.local.json` (LIVE, read via
   `PRETOOLHOOK_CONFIG_PATH`) + re-sync fixtures (`live\Sync-Fixtures.ps1`) per repo conventions;
   exact list pruned to §9-Q2 decision.
5. `docs/config-json-guide.md` — new §on denylist + consolidated regex semantics (anchored rows,
   dual-key matching, precedence deny > exact > regex).
6. Tests — extend `test/config/safe-expr-regex/` (own `config.json` in the test dir, per CLAUDE.md).

## 8. Test plan / acceptance cases (red phase list)

| Case | Expected |
|---|---|
| `[System.IO.Path]::GetTempFileName()` | **ask** — denylist outranks `path::` wildcard |
| `[io.path]::GetTempFileName()` | **ask** — deny regex `::gettempfilename$` (written key is `io.path::GetTempFileName`) |
| `[System.IO.Path]::GetRandomFileName()` | **allow** — pure, contrast with the above |
| `[math]::Sqrt(2)` / `[System.Math]::Clamp(1,2,3)` | allow |
| `[int]::TryParse('42',[ref]$x)` / `[decimal]::Parse('1.5')` | allow (TryParse proof for the `\w*` tail) |
| `[System.Linq.Enumerable]::Range(1,10)` | allow (new whole-type) |
| `[System.Drawing.Point]::X`-style written key `point::…` | NOT matched by alias row (anchoring proof) |
| `[System.IO.File]::WriteAllText(…)` | **ask** (Class-B prefix excludes it) |
| `[Array]::Sort($a)` | **ask** (Array not wildcarded) |
| `[System.IO.File]::ReadAllText('x')` | allow |
| denylist + invalid regex in config | `Load-Config` throws (fail-fast parity) |
| config WITHOUT denylist keys | byte-identical behavior (optional-key parity) |

Optional hardening: extend `temp/verify-static-list.ps1` to assert per Class-A type that EVERY public
static method matches at least one allow row (guards against future .NET additions).

## 9. Open questions (blocking implementation)

1. **Anchoring**: anchor everything with `^(system\.)?type::` forms (recommended) vs short unanchored
   `math::.*` accepting rare substring over-matches?
2. **Exact list fate**: prune the 183 exact entries to just the regex rows (recommended — it is the
   maintenance burden being killed) vs keep both (exact = O(1) belt-and-suspenders)?
3. **`::search` row**: drop (recommended) vs keep?
4. **`string::`** now allows `Intern` + `Create` (both pure) — previously excluded by caution. OK?
5. **Optional extra row** `^[\\w.]+::(serialize|deserialize)\\w*$` (`JsonSerializer` etc., pure) — include?
6. **Instance-side denylist** (`dotnet_method_denylist`) for symmetry — add now or defer?
