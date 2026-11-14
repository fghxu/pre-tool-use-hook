# AGENT TASK — Implement the quad-contract harness migration (F1–F4)

You are implementing an already-decided design. Do not re-design; the decision
ledger is final. Your job: make the committed RED suite green using strict
red/green TDD, without breaking any pin.

## Where you are

- Repo: `c:\git\cc\pretoolhook`, branch **`feature/quad-contract`**
  (cut from `origin/feature/workspace-roots` @ 8bf7f2f).
- The design docs and the failing tests are already committed.

## Read first, in this order

1. `docs/Updates/Update-2026-11-14-copilot-harness-migration.md` — the whole
   file: incident, contract matrix (section 2), decision ledger (section 3),
   planned slices (section 4), and especially **section 7 Implementer brief**
   **+ 7.3 base-branch amendments**.
2. `docs/adr/0001-quad-contract-harness-adapter.md` — the architecture decision.
3. `CONTEXT.md` — glossary (Harness, Contract, Registration, Decision, Fatal
   failure, Answer deadline, Workspace root). Use these words.
4. `PROGRESS.md` — top two sections (migration design + RED-suite record).
5. Code you will touch: `src/HookAdapter.ps1` (Detect-IDE,
   Get-CommandFromInput, Format-Output, Add-WorkspaceRoots), `src/Hook.ps1`
   (steps 3–14), `src/Logger.ps1` ($ideSuffix), `src/ConfigLoader.ps1`
   (Test-ConfigSchema + compile section), `src/Classifier.ps1` (unknown-tool
   exit code), `src/LlmReview.ps1` (LLM wait path for the deadline).

## The loop (strict TDD — red is already committed)

```
pwsh -NoProfile -File test\config\harness-contracts\Run-Tests.ps1
```

RED record at start: **39 checks / 15 pass / 24 fail**. Implement in slices
F1 -> F2 -> F3 -> F4 (section 4 of the Update doc), minimal code per slice,
rerun the suite after each change, commit per slice:

- **F1** detection + normalizer: decisive `toolName` signal (must outrank the
  snake_case vote — see HC-01b), `__vscode-` -> `Local` (+ `.local.log`
  suffix in Logger), `ConvertTo-CanonicalPayload` (camel->snake fields,
  raw tool name preserved), `ConvertTo-ToolNameLookupKey` (camel->snake
  kebabing, lookup only), widen `Add-WorkspaceRoots` gate to
  `$IDE -notin @('Copilot','Local')` (amendment 7.3.1).
- **F2** output: `Format-Output` emits BOTH envelopes (top-level
  `permissionDecision`/`permissionDecisionReason` AND nested
  `hookSpecificOutput`); Codex `ask`->`deny` + `systemMessage`
  (exact templates in section 7.3/7 of the Update doc — the tests pin them);
  unknown tool returns Decision `ask` with ExitCode 0 (was exit 2 — update
  the pinned fixtures that assert the old behavior; this flip is intended).
- **F3** `answer_deadline_ms`: validate in Test-ConfigSchema (ints only;
  Copilot/Local entries must be < 30000), compile to `_answerDeadlines`,
  enforce per detected harness with the existing runspace-abandon mechanism;
  on deadline-before-verdict return ask with the pinned reason template.
- **F4** fullpipe: the four payload spawns already in the suite; make Hook.ps1
  accept all four shapes end-to-end (normalizer runs right after JSON parse).

## Definition of done

1. `test\config\harness-contracts\Run-Tests.ps1` → **39/39 pass** (all 15 pins
   still green — a pin flipping is a regression, not progress).
2. `src\Run-AllTests.ps1` grand total green again (the `harness-contracts`
   entry currently makes it red by design).
3. Zero behavior changes outside the spec (the other suites are your
   regression net).
4. Fix the mojibake `8bf7f2f` left in `src/HookAdapter.ps1` comments
   (em-dashes became `?`) — in passing, don't propagate it. Keep files you
   touch ASCII-safe for powershell.exe 5.1.
5. Update `PROGRESS.md`: flip the migration section to GREEN with the counts,
   and note any micro-choice you pinned.

## Do NOT touch (rollout is user-owned, AFTER green)

- Anything under `~/.copilot/`, `~/.claude/`, `~/.codex/`, VS Code user
  settings, `config.local.json` (test fixtures in `test/config/**` only).
- Do NOT delete `.github/hooks/pre-cli-hook.json` or the repo
  `.claude/settings.local.json` hooks block — those are post-green rollout
  checklist items (Update doc section 5).
- Do not "improve" the design (no per-harness front-ends, no timeout keys in
  registrations, no exit codes other than 0=Decision / 2=Fatal).

## Ambiguity rule

If something is genuinely unclear: choose the **fail-closed** option, pin it
with a test, record the choice in `PROGRESS.md`. Do not block on questions.

## Out of scope (do not do)

Section 5 rollout checklist, the cutover gate, registration rewrites, trust
steps, VS Code settings changes — all user-owned and documented already.
