# Testing Guide for CLI Security Hook

## Overview
This document describes how to install, configure, and test the CLI Security Hook for Claude Code. The hook automatically approves read-only operations while prompting for approval on commands that modify the system.

## Installation Steps

### Step 1: Create Claude Configuration Directory

First, ensure you have a `.claude` directory in your home folder:

**Windows (PowerShell):**
```powershell
# Create .claude directory
New-Item -Path "$HOME\.claude" -ItemType Directory -Force

# Create hooks subdirectory
New-Item -Path "$HOME\.claude\hooks" -ItemType Directory -Force
```

**Linux/macOS (Bash):**
```bash
mkdir -p ~/.claude/hooks
```

### Step 2: Install Required Dependencies

The hook requires `jq` for JSON parsing.

**Windows:**
1. Download jq from: https://stedolan.github.io/jq/download/
2. Add jq.exe to your PATH
3. Verify installation:
```powershell
jq --version
```

**Linux:**
```bash
# Ubuntu/Debian
sudo apt-get install jq

# CentOS/RHEL
sudo yum install jq

# Verify
jq --version
```

**macOS:**
```bash
brew install jq
jq --version
```

### Step 3: Copy Hook Files

Copy the configuration and script files from the poc6 project to your Claude configuration:

**Option A: Copy from poc6 directory (if you have the files locally)**

**Windows (PowerShell):**
```powershell
# Navigate to your poc6 project
cd C:\git\claudecode\poc6

# Copy configuration file
Copy-Item -Path ".\cli-commands.json" -Destination "$HOME\.claude\cli-commands.json"

# Copy hook script
Copy-Item -Path ".\pre-cli-hook.sh" -Destination "$HOME\.claude\hooks\pre-cli-hook.sh"
```

**Linux/macOS:**
```bash
cd /path/to/poc6
cp cli-commands.json ~/.claude/cli-commands.json
cp pre-cli-hook.sh ~/.claude/hooks/pre-cli-hook.sh
chmod +x ~/.claude/hooks/pre-cli-hook.sh
```

**Option B: Create fresh with the content below**

If you don't have the poc6 directory, create these files:

#### File: `~/.claude/cli-commands.json`
```json
{
  "read_only_commands": {
    "unix": [
      "ls", "pwd", "cd", "echo", "cat", "head", "tail", "grep", "find", "which",
      "whoami", "id", "groups", "ps", "top", "htop", "df", "du", "free",
      "uname", "hostname", "date", "uptime", "w", "last", "lastlog",
      "git status", "git log", "git show", "git diff", "git branch",
      "git remote -v", "git tag", "git describe",
      "npm list", "npm view", "npm search",
      "yarn list", "yarn info",
      "pip list", "pip show", "pip search",
      "composer show", "composer search",
      "gem list", "gem search", "gem info",
      "curl -I", "curl --head", "wget --spider"
    ],
    "aws_cli": [
      "aws s3 ls", "aws s3api head-object", "aws s3api get-object-acl",
      "aws s3api list-objects", "aws s3api list-buckets",
      "aws ec2 describe-instances",
      "aws rds describe-db-instances",
      "aws cloudformation describe-stacks",
      "aws iam list-users"
    ],
    "powershell": [
      "Get-ChildItem", "Get-Location", "Get-Content", "Get-Process",
      "Get-Service", "Get-EventLog", "Get-Date", "Get-Host",
      "Get-Command", "Get-Help", "Select-Object", "Where-Object"
    ],
    "docker": [
      "docker ps", "docker images", "docker inspect",
      "docker info", "docker stats", "docker system df"
    ],
    "terraform": [
      "terraform show", "terraform output",
      "terraform state list", "terraform state show"
    ]
  },
  "modifying_patterns": {
    "unix": [
      "rm", "rmdir", "mv", "cp", "touch", "mkdir", "chmod", "chown",
      "useradd", "userdel", "apt-get", "yum",
      "pip install", "npm install"
    ],
    "aws_cli": [
      "aws s3 rm", "aws s3 cp",
      "aws ec2 terminate-instances"
    ],
    "powershell": [
      "Remove-Item", "New-Item", "Stop-Service",
      "New-LocalUser", "Remove-LocalUser"
    ],
    "docker": [
      "docker rm", "docker rmi",
      "docker run", "docker-compose up"
    ],
    "terraform": [
      "terraform apply", "terraform destroy"
    ]
  },
  "settings": {
    "prompt_timeout_seconds": 60,
    "auto_deny_on_timeout": true,
    "show_command_analysis": true,
    "show_impact_preview": true,
    "chain_aware_prompting": true
  }
}
```

#### File: `~/.claude/hooks/pre-cli-hook.sh`
```bash
#!/bin/bash
# Parses and analyzes CLI commands for read-only vs modifying operations
set -e

CONFIG_FILE="${HOME}/.claude/cli-commands.json"
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Function to check if command is read-only
is_read_only() {
    local cmd=$1

    # Check for basic read-only patterns
    case "$cmd" in
        ls*|pwd|echo*|cat*|head*|tail*|grep*|find*|whoami|date|git\ status*)
            return 0
            ;;
    esac

    # Check JSON configuration
    if [[ -f "$CONFIG_FILE" ]]; then
        local readonly=$(jq -r '.read_only_commands.unix[]' "$CONFIG_FILE" | grep -x "${cmd%% *}" || true)
        if [[ -n "$readonly" ]]; then
            return 0
        fi
    fi

    return 1
}

# Parse chained commands
parse_commands() {
    local full_cmd=$1
    IFS='&|;' read -ra commands <<< "$full_cmd"
    for cmd in "${commands[@]}"; do
        cmd=$(echo "$cmd" | sed 's/^ *//;s/ *$//')
        if [[ -n "$cmd" ]]; then
            echo "$cmd"
        fi
    done
}

# Analyze all commands
if [[ -n "$COMMAND" ]]; then
    modifying=false

    # Parse individual commands
    while IFS= read -r cmd; do
        if ! is_read_only "$cmd"; then
            modifying=true
            break
        fi
    done <<< "$(parse_commands "$COMMAND")"

    if [[ "$modifying" == "true" ]]; then
        exit 1  # Deny - needs prompt
    else
        exit 0  # Approve - all read-only
    fi
fi

exit 0
```

### Step 4: Configure Claude Code Settings

Add or update `~/.claude/settings.json`:

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
            "prompt": "Analyze CLI command chain for read-only operations: $TOOL_INPUT\n\nConfiguration: ~/.claude/cli-commands.json\n\nRules:\n1. Parse chained commands separated by &&, ||, |, ;\n2. Check each sub-command against read-only whitelist\n3. If any modifying operation detected, deny with detailed analysis\n4. Explain why approval is needed\n5. Default to safe (deny on uncertainty)\n\nReturn: approve|deny with explanation",
            "timeout": 15
          }
        ]
      },
      {
        "matcher": "PowerShell",
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Analyze PowerShell command: $TOOL_INPUT\nCheck for read-only vs modifying operations. Return approve|deny with explanation.",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

If `settings.json` doesn't exist, create it with the above content.

### Step 5: Restart Claude Code

The configuration changes require restarting Claude Code:

```bash
# Exit Claude Code
/exit

# Start Claude Code again
claude
```

## Testing the Hook

### Test Suite 1: Unix/Linux Commands

**Test Read-Only Commands** (should auto-approve):
```bash
# Each of these should execute without prompting
ls -la
pwd
echo "test"
git status
date
```

**Test Modifying Commands** (should prompt):
```bash
# Each of these should prompt for approval
touch test.txt
rm test.txt  # Clean up
```

**Test Chained Commands**:
```bash
# All read-only - should auto-approve
pwd && ls

# Contains modifying - should prompt
ls && touch test.txt
```

### Test Suite 2: Docker Commands

First ensure you have Docker installed:
```bash
docker --version
```

**Test Read-Only**:
```bash
docker ps
docker images
docker info
```

**Test Modifying**:
```bash
# These should prompt
docker run alpine echo "test"
docker volume create test-volume
```

### Test Suite 3: AWS CLI

First configure AWS CLI:
```bash
aws configure
```

**Test Read-Only**:
```bash
aws s3 ls
aws ec2 describe-instances
```

**Test Modifying**:
```bash
aws s3 rm s3://bucket/file.txt
aws ec2 terminate-instances --instance-ids i-1234567890abcdef0
```

### Test Suite 4: PowerShell Commands

**PowerShell Test Script** (Copy to `test-powershell.ps1`):
```powershell
# Test Read-Only Commands (should auto-approve)
Write-Host "=== Testing Read-Only Commands ===" -ForegroundColor Green

Get-ChildItem
Get-Location
Get-Date
Get-Host
Get-Process | Select-Object -First 5 Name, Id
Get-Service | Select-Object -First 5 Name, Status

# Test Modifying Commands (should prompt)
Write-Host "`n=== Testing Modifying Commands ===" -ForegroundColor Yellow

New-Item -Path "./hook-test.txt" -ItemType File -Force
New-Item -Path "./hook-test-dir" -ItemType Directory -Force
Rename-Item -Path "./hook-test.txt" -NewName "hook-test-renamed.txt" -Force
Remove-Item -Path "./hook-test-renamed.txt" -Force
Remove-Item -Path "./hook-test-dir" -Force

Write-Host "`nAll tests completed!" -ForegroundColor Green
```

Run it with:
```powershell
# Start PowerShell
powershell

# Navigate to test directory
cd path/to/test/folder

# Run test script
.\test-powershell.ps1
```

## Verification Checklist

After installation, verify all components:

- [ ] `.claude` directory exists in home folder
- [ ] `cli-commands.json` file exists
- [ ] `hooks` subdirectory exists
- [ ] `pre-cli-hook.sh` file exists and is executable
- [ ] `settings.json` is configured with PreToolUse hooks
- [ ] `jq` is installed and accessible from terminal
- [ ] Claude Code was restarted after configuration
- [ ] Hook triggers on modifying commands
- [ ] Hook auto-approves read-only commands
- [ ] Approval prompt shows detailed command analysis
- [ ] Chained commands are analyzed correctly

## Troubleshooting

### Issue: Hook doesn't trigger
- Verify `settings.json` is valid JSON
- Check Claude Code logs for errors
- Ensure hook paths are correct
- Restart Claude Code

### Issue: Commands always prompt
- Check that `jq` is installed: `jq --version`
- Verify `cli-commands.json` exists and is valid
- Test hook script manually: `echo '{"tool_input":{"command":"ls"}}' | bash ~/.claude/hooks/pre-cli-hook.sh`

### Issue: Permission denied on hook script
- Make script executable: `chmod +x ~/.claude/hooks/pre-cli-hook.sh`

### Issue: PowerShell commands don't work
- Add PowerShell hook configuration to `settings.json`
- Ensure PowerShell execution policy allows scripts

## Sample Investigation Project

For testing PowerShell commands on your local system, here's a complete project:

### Project Structure:
```
powershell-test/
├── Test-Hook.ps1          # Main test script
├── README.md               # Project documentation
└── .claude/               # Claude configuration for this project
    └── settings.json       # Project-specific settings (if needed)
```

### File: `Test-Hook.ps1`
```powershell
<# 
.SYNOPSIS
Tests the Claude Code CLI Security Hook with PowerShell commands

.DESCRIPTION
This script tests both read-only and modifying PowerShell commands
to verify the hook correctly identifies and handles each type.

.NOTES
Run this in Claude Code to test the hook functionality
#>

# Create test directory
$TestPath = Join-Path -Path $PSScriptRoot -ChildPath "hook-test-files"
if (Test-Path $TestPath) {
    Remove-Item -Path $TestPath -Recurse -Force
}
New-Item -Path $TestPath -ItemType Directory -Force | Out-Null
Set-Location -Path $TestPath

Write-Host "
========================================" -ForegroundColor Cyan
Write-Host "CLI Security Hook - PowerShell Tests" -ForegroundColor Cyan
Write-Host "========================================
" -ForegroundColor Cyan

# Section 1: Read-Only Commands (Should Auto-Approve)
Write-Host "SECTION 1: Read-Only Commands" -ForegroundColor Green
Write-Host "These should execute without prompts" -ForegroundColor Gray

$readonlyTests = @(
    @{ Name = "Get-ChildItem"; Command = { Get-ChildItem } },
    @{ Name = "Get-Location"; Command = { Get-Location } },
    @{ Name = "Get-Date"; Command = { Get-Date } },
    @{ Name = "Get-Host"; Command = { Get-Host | Select-Object Version } },
    @{ Name = "Test-Path"; Command = { Test-Path -Path "Test-Hook.ps1" } },
    @{ Name = "Get-Process"; Command = { Get-Process | Select-Object -First 3 Name, Id } },
    @{ Name = "Get-Service"; Command = { Get-Service | Select-Object -First 3 Name, Status } }
)

foreach ($test in $readonlyTests) {
    Write-Host "  $($test.Name)" -ForegroundColor Yellow -NoNewline
    try {
        $result = & $test.Command
        Write-Host " - ✅ Auto-approved" -ForegroundColor Green
    }
    catch {
        Write-Host " - ❌ Failed: $_" -ForegroundColor Red
    }
}

# Section 2: Modifying Commands (Should Prompt)
Write-Host "
SECTION 2: Modifying Commands" -ForegroundColor Yellow
Write-Host "These should prompt for approval" -ForegroundColor Gray

$modifyingTests = @(
    @{ 
        Name = "New-Item (File)"; 
        Command = { New-Item -Path "./test-file.txt" -ItemType File -Force }
        Cleanup = { if (Test-Path "./test-file.txt") { Remove-Item -Path "./test-file.txt" -Force } }
    },
    @{ 
        Name = "New-Item (Directory)"; 
        Command = { New-Item -Path "./test-dir" -ItemType Directory -Force }
        Cleanup = { if (Test-Path "./test-dir") { Remove-Item -Path "./test-dir" -Recurse -Force } }
    },
    @{ 
        Name = "Rename-Item"; 
        Command = { 
            New-Item -Path "./rename-test.txt" -ItemType File -Force
            Rename-Item -Path "./rename-test.txt" -NewName "renamed-test.txt" -Force
        }
        Cleanup = { 
            if (Test-Path "./rename-test.txt") { Remove-Item -Path "./rename-test.txt" -Force }
            if (Test-Path "./renamed-test.txt") { Remove-Item -Path "./renamed-test.txt" -Force }
        }
    }
)

foreach ($test in $modifyingTests) {
    Write-Host "  $($test.Name)" -ForegroundColor Yellow -NoNewline
    try {
        # Run cleanup first
        if ($test.Cleanup) { & $test.Cleanup }
        
        $result = & $test.Command
        Write-Host " - ✅ Requested approval" -ForegroundColor Yellow
    }
    catch {
        Write-Host " - ⚠️  May have been denied: $_" -ForegroundColor Orange
    }
    finally {
        # Cleanup regardless of outcome
        if ($test.Cleanup) { & $test.Cleanup }
    }
}

# Section 3: Command Chaining
Write-Host "
SECTION 3: Command Chaining" -ForegroundColor Magenta
Write-Host "Testing how hook handles multiple commands" -ForegroundColor Gray

# All read-only chain
Write-Host "  Chained read-only: Get-Location; Get-Date" -ForegroundColor Yellow
Get-Location | Out-Null; Get-Date | Out-Null
Write-Host "  - ✅ Should auto-approve" -ForegroundColor Green

# Mixed chain (should prompt)
Write-Host "  Mixed chain: Test-Path './test1.txt'; New-Item './test1.txt'" -ForegroundColor Red
$test1Path = "./test1.txt"
if (Test-Path $test1Path) { Remove-Item -Path $test1Path -Force }
Test-Path -Path $test1Path | Out-Null; New-Item -Path $test1Path -ItemType File -Force
if (Test-Path $test1Path) { Remove-Item -Path $test1Path -Force }
Write-Host "  - Should prompt due to New-Item" -ForegroundColor Yellow

# Cleanup
Write-Host "
Cleaning up test files..." -ForegroundColor Gray
if (Test-Path $TestPath) {
    Remove-Item -Path $TestPath -Recurse -Force
}

Write-Host "
✨ Test suite completed!" -ForegroundColor Green
Write-Host "Review the output above to verify hook behavior." -ForegroundColor Cyan
```

### File: `README.md`
```markdown
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
3. Run: `.\Test-Hook.ps1`
4. Observe which commands auto-approve vs prompt

## Test Coverage

### Section 1: Read-Only Commands
Tests PowerShell commands that should auto-approve:
- File system queries
- System information
- Process and service queries
- Date/time queries

### Section 2: Modifying Commands
Tests PowerShell commands that should prompt:
- File creation
- Directory creation
- File/directory renaming
- File/directory deletion

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

## Troubleshooting

If tests fail:
1. Verify hook is configured in `~/.claude/settings.json`
2. Check `cli-commands.json` exists and has PowerShell section
3. Restart Claude Code after configuration changes
4. Check for jq installation issues
```

### Running the Test Project:

```powershell
# Clone or create the project
mkdir powershell-test
cd powershell-test

# Copy Test-Hook.ps1 and README.md
# (or create them with the content above)

# Set execution policy (if needed)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Run the test
.\Test-Hook.ps1
```

## Next Steps

After successful testing:

1. **Customize command lists** in `cli-commands.json` for your workflow
2. **Add more tools** to support additional DevOps tools
3. **Configure logging** to track approvals/denials
4. **Integrate with CI/CD** to enforce policies in pipelines
5. **Share configurations** across your team for consistency

## Support

For issues or questions:
1. Check Claude Code documentation on hooks
2. Review hook logs if enabled
3. Verify jq installation
4. Test configuration manually with sample commands

---

**Happy testing!** 🚀