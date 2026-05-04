## Goal
Implement a VS Code Copilot PreToolUse hook that intercepts CLI commands, auto-approves read-only operations, and prompts for approval on modifying operations across PowerShell, AWS CLI, Docker, Terraform, Git, kubectl, Linux/Unix, DOS, and SSH.

## Completed Steps

### Core Implementation
- Hook script `pre-cli-hook-copilot.ps1` (~1300 lines): receives JSON via stdin from Copilot's PreToolUse event, analyzes command, outputs allow/ask decision
- Configuration in `cli-commands.json` (v2.9.0): all patterns externalized — PowerShell verbs, AWS patterns, Linux commands, Docker/Terraform/Git/kubectl subcommands, DOS commands, SSH patterns, script patterns, trusted scripts
- Decision pipeline: empty check → redirect detection → trusted scripts → script execution → SSH → PowerShell blocks → chained commands → single commands → safe default

### PowerShell Block Extraction Algorithm
- Stack-based `Extract-CmdletsFromScriptBlocks` (v2.4.0): non-recursive 4-phase algorithm finds ALL `{ }` pairs, processes innermost first, extracts contents without doubling
- Multi-line block support (v2.5.0): block extraction runs on FULL command before `n` splitting; handles `{ }` blocks spanning lines
- `Remove-ControlFlowPrefix`: strips `if (...)`, `while (...)`, `foreach (...)`, `else`, `do`, `}` remnants after block removal
- Segment trimming fix (v2.7.0): trims `;`-split segments before control flow stripping (prevents leading-space regex misses)
- `originalHadBlocks` check (v2.7.0): PowerShell commands with `{ }` blocks trigger block analysis even if only 1 cmdlet remains
- Pipe/chain handling in `Test-IsPowerShellModifying` (v2.8.0/v2.9.0): splits on `|`, `&&`, `||` and checks each segment independently

### Chain Operator Coverage
- `|` (pipeline) — split in `Test-IsPowerShellModifying` for PowerShell, in `Split-ChainedCommands` for Linux
- `&&` (AND) — split in both PowerShell and Linux paths
- `||` (OR) — split in both PowerShell and Linux paths
- `;` (statement separator) — split in `Extract-PowerShellCommands` for PowerShell, in `Split-ChainedCommands` for Linux
- `&` — NOT split for PowerShell (it's the call operator, not a chain operator); split in Linux path only

### Trusted Script Files (v2.6.0)
- `trusted_script_files` array in `cli-commands.json`
- Trusted scripts bypass script execution check → auto-approve
- Disable by removing `trusted_script_files` from config

### Test Framework
- `test-commands.txt`: 132 test cases, format `Y/N;Category;Command;Description`
- `test-runner-copilot.ps1`: automated runner — builds Copilot-format JSON, pipes to hook, compares expected vs actual
- `debug-input.json`: sample payload for `-DebugInputFile` debugging

### Test Results: 132/132 PASSING (100%)
All 48 categories at 100%:

| Category | Tests | Status |
|----------|-------|--------|
| PowerShell Read-Only | 4 | 100% |
| PowerShell Modifying | 3 | 100% |
| PS Block Modifying (MultiLine, Nested, IfElse, Simple, etc.) | 22 | 100% |
| PS Block Read-Only | 12 | 100% |
| PS MultiLine (ReadOnly + Modifying) | 4 | 100% |
| PS Inline Command | 2 | 100% |
| PS Chain Operators (&&, \|\|) | 4 | 100% |
| Linux Read-Only | 7 | 100% |
| Linux Modifying | 8 | 100% |
| AWS Read-Only | 6 | 100% |
| AWS Modifying | 6 | 100% |
| SSH Read-Only | 3 | 100% |
| SSH Chained Read-Only | 2 | 100% |
| SSH Modifying | 2 | 100% |
| Script Execution | 8 | 100% |
| Chained Commands (ReadOnly + Modifying) | 6 | 100% |
| Complex (ReadOnly + Modifying + Pipe) | 4 | 100% |
| kubectl Read-Only | 5 | 100% |
| kubectl Modifying | 4 | 100% |
| DOS Read-Only | 5 | 100% |
| DOS Modifying | 6 | 100% |
| DOS cmd /c Wrapper | 4 | 100% |
| Dollar-Substitution $() | 3 | 100% |
| Trusted/Untrusted Scripts | 4 | 100% |

## Current Step
All 132 tests passing. Hook is feature-complete for all supported tool categories.

## Next Steps
- Consider edge cases for `Remove-ControlFlowPrefix` with deeply nested parens
- Add more real-world multi-line PowerShell script examples
- Performance optimization for large command strings

## Blockers / Notes
- `cli-commands.json` regex patterns require double-escaped backslashes (JSON format: `\\s` not `\s`)
- Copilot passes PowerShell multiline with `n` (backtick-n), not `\r\n`
- Hook expects `tool_name` field to be `run_in_terminal`, `Bash`, `bash`, `terminal`, or `execute_command`
