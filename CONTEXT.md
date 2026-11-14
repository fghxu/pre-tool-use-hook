# PreToolUse Hook

A cross-harness command-classification hook: it inspects every tool call an
agent is about to execute and answers allow / ask / deny. One script serves
several agent harnesses, each with its own wire contract.

## Language

### The agent side

**Harness**:
The agent runtime that executes tools and invokes our hook; VS Code hosts
several (Local, Copilot, Claude, Codex). One harness can arrive from several
clients (VS Code window, CLI, app).
_Avoid_: IDE, runtime, engine

**IDE (legacy)**:
The code-level spelling of harness detection (`Detect-IDE`, `$ide`, log
suffixes). Means Harness; kept for compatibility, not for new code.
_Avoid_: using it in new names

**Contract**:
The agreed input-payload shape, output envelope, and exit-code meaning between
one harness and our hook. Four exist today (Local, Copilot, Claude, Codex).
_Avoid_: protocol, format, dialect

**Registration**:
A harness-specific configuration entry that points one harness at our hook
script (e.g. a `.github/hooks` file, a `.claude/settings` block). Registrations
combine within a harness; they are not interchangeable across harnesses.
_Avoid_: hook config, wiring

### The verdict side

**Decision**:
Our verdict for one tool call: `allow`, `ask`, or `deny`. Carried in JSON on
stdout; never in the exit code. An unrecognized tool name yields `ask`.
_Avoid_: permission, verdict, ruling

**Fatal failure**:
A condition where no Decision can be produced (unparseable input, bad config,
no extractable command). Signalled with exit code 2; every harness treats it as
block/deny.
_Avoid_: error exit, hard block

**Answer deadline**:
The hook-enforced time by which a Decision must be emitted for a given
harness, kept below that harness's own kill timer so the verdict is never
discarded. Lives in the local config, never in registration files.
_Avoid_: timeout (that's the harness's timer)

**Workspace root**:
An extra VS Code workspace folder adopted at runtime and treated exactly
like the CWD by path policy. A VS Code-origin concept; other callers keep a
single CWD.
_Avoid_: workspace folder (ambiguous), extra root
