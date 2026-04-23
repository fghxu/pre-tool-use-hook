# PowerShell Hook Test Project

This project tests the Claude Code CLI Security Hook with PowerShell commands.

## Overview

The test suite verifies that the hook correctly:
- Auto-approves read-only commands
- Prompts for approval on modifying commands
- Handles command chaining correctly

## Requirements

- Windows with PowerShell 5.1 or higher
- Claude Code CLI installed
- Hook configuration in `~/.claude/settings.json`

## Usage

1. Open PowerShell
2. Navigate to this directory
3. Run: `\.\Test-Hook.ps1`
4. Observe which commands auto-approve vs prompt

## Test Coverage

### Section 1: Read-Only Commands
Tests PowerShell commands that should auto-approve:
- File system queries：`Get-ChildItem`
- System information：`Get-Host`, `Get-Date`
- Process and service queries：`Get-Process`, `Get-Service`
- Date/time queries：`Get-Date`

### Section 2: Modifying Commands
Tests PowerShell commands that should prompt:
- File creation：`New-Item`
- Directory creation：`New-Item -ItemType Directory`
- File/directory renaming：`Rename-Item`
- File/directory deletion：`Remove-Item`

### Section 3: Command Chaining
Tests chained command behavior:
- All read-only chains (auto-approve)
- Mixed chains (prompt for modifying parts)

## Verification

After running tests, verify:
- Read-only tests show ✅
- Modifying tests show prompts or ✅ with approval
- Chained commands analyzed correctly
- Cleanup removes all test files

## Sample Commands

### Read-Only (Should Auto-Approve)
```powershell
Get-ChildItem
Get-Location
Get-Date
Get-Host
Get-Process | Select-Object -First 5 Name, Id
Get-Service | Select-Object -First 5 Name, Status
Test-Path './README.md'
```

### Modifying (Should Prompt)
```powershell
New-Item -Path './test.txt' -ItemType File
New-Item -Path './test-dir' -ItemType Directory
Rename-Item -Path './test.txt' -NewName 'renamed.txt'
Remove-Item -Path './renamed.txt'
Remove-Item -Path './test-dir'
```

## Configuration

If hook doesn't work as expected, verify your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-cli-hook.sh",
            "timeout": 5
          },
          {
            "type": "prompt",
            "prompt": "Analyze CLI command: $TOOL_INPUT",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

## Next Steps

After successful testing:
1. Customize command lists in `cli-commands.json` for your workflow
2. Add more DevOps tools (Kubernetes, Terraform, etc.)
3. Configure logging to track approvals
4. Share configurations across your team

---

**For questions or issues, check the main tests.md documentation.**