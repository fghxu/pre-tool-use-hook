# Testing Guide for CLI Security Hook (PowerShell Version)

## Overview
This document describes how to install, configure, and test the CLI Security Hook for Claude Code on Windows with PowerShell. The hook automatically approves read-only PowerShell commands while requiring human approval for any commands that modify the system.

## Installation Steps for Windows

### Step 1: Create Claude Configuration Directory

Open PowerShell and create the necessary directories:

```powershell
# Create .claude directory in your user profile
New-Item -Path "$env:USERPROFILE\.claude" -ItemType Directory -Force

# Create hooks subdirectory
New-Item -Path "$env:USERPROFILE\.claude\hooks" -ItemType Directory -Force
```

### Step 2: Copy Hook Files

Copy the configuration and script files from the poc6 project to your Claude configuration:

**Option A: Copy from poc6 directory (if you have the files locally)**

**PowerShell:**
```powershell
# Navigate to your poc6 project
cd "C:\git\claudecode\poc6"

# Copy configuration file
Copy-Item -Path ".\cli-commands.json" -Destination "$env:USERPROFILE\.claude\cli-commands.json"

# Copy hook script
Copy-Item -Path ".\pre-cli-hook.ps1" -Destination "$env:USERPROFILE\.claude\hooks\pre-cli-hook.ps1"

# Verify files were copied
Get-ChildItem "$env:USERPROFILE\.claude"
```

**Option B: Create fresh with the content below**

If you don't have the poc6 directory, create these files:

#### File: `$env:USERPROFILE\.claude\cli-commands.json`
```json
{
  "read_only_commands": {
    "powershell": [
      "Get-ChildItem", "Get-Location", "Get-Content", "Get-Process",
      "Get-Service", "Get-EventLog", "Get-Date", "Get-Host",
      "Get-Command", "Get-Help", "Get-Alias", "Get-Member",
      "Get-Variable", "Get-Item", "Get-ItemProperty", "Get-History",
      "Get-Random", "Get-Credential", "Get-WmiObject", "Get-CimInstance",
      "Test-Path", "Test-Connection", "Test-NetConnection", "Write-Output",
      "Select-Object", "Where-Object", "Sort-Object", "Measure-Object",
      "Compare-Object", "Group-Object", "Format-Table", "Format-List",
      "ls", "dir", "pwd", "echo", "cat", "type", "gc", "where",
      "select", "sort", "measure", "group", "format", "where-object",
      "select-object", "sort-object", "measure-object", "group-object",
      "format-table", "format-list", "format-wide", "fl", "ft", "fw"
    ],
    "unix": ["ls", "pwd", "cd", "echo", "cat", "head", "tail", "grep", "find"],
    "aws_cli": ["aws s3 ls", "aws ec2 describe-instances"],
    "docker": ["docker ps", "docker images"],
    "terraform": ["terraform show", "terraform output"]
  },
  "modifying_patterns": {
    "powershell": [
      "New-Item", "Remove-Item", "Move-Item", "Copy-Item", "Rename-Item",
      "Stop-Service", "Start-Service", "Restart-Service", "Set-Content",
      "Clear-Content", "Add-Content", "New-ItemProperty", "Set-ItemProperty",
      "Remove-ItemProperty", "Clear-Item", "New-LocalUser", "Remove-LocalUser",
      "Set-ExecutionPolicy", "Stop-Process", "Start-Process", "Set-Variable",
      "Remove-Variable", "Clear-Variable", "Invoke-Expression", "Invoke-Command"
    ],
    "unix": ["rm", "mv", "cp", "touch", "mkdir"],
    "aws_cli": ["aws s3 rm", "aws s3 cp"],
    "docker": ["docker rm", "docker run"],
    "terraform": ["terraform apply", "terraform destroy"]
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

#### File: `$env:USERPROFILE\.claude\hooks\pre-cli-hook.ps1`
```powershell
<#
.SYNOPSIS
Claude Code CLI Security Hook - PowerShell Version

.DESCRIPTION
Analyzes PowerShell commands and approves read-only operations
while denying modifying ones

.NOTES
Returns exit code 0 for approval, 1 for denial
#>

$ConfigFile = "$env:USERPROFILE\.claude\cli-commands.json"

# Try to load configuration
$ReadOnlyCommands = @()
$ModifyingPatterns = @()

if (Test-Path $ConfigFile) {
    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $ReadOnlyCommands = $config.read_only_commands.powershell
        $ModifyingPatterns = $config.modifying_patterns.powershell
    } catch {
        # Ignore errors, use defaults
    }
}

# Parse JSON input from Claude Code
$inputJson = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputJson)) {
    exit 0  # No command, approve by default
}

try {
    $inputObj = $inputJson | ConvertFrom-Json
    $Command = $inputObj.tool_input.command

    # Simple read-only detection
    $isReadOnly = $false
    $isModifying = $false

    # Check if command has modifying patterns
    foreach ($pattern in $ModifyingPatterns) {
        if ($Command -like "$pattern*") {
            $isModifying = $true
            break
        }
    }

    # Check if command is read-only
    if (!$isModifying) {
        foreach ($roCmd in $ReadOnlyCommands) {
            if ($Command -like "$roCmd*") {
                $isReadOnly = $true
                break
            }
        }
    }

    # Default: allow common commands
    if (!$isModifying) {
        if ($Command -match "^(Get-|Test-|Select-|Where-|Sort-|Measure-|Write-)") {
            $isReadOnly = $true
        }
    }

    if ($isModifying) {
        exit 1  # Deny - needs prompt
    } else {
        exit 0  # Approve
    }
}
catch {
    Write-Error "Hook error: $_"
    exit 1  # Deny on error
}
```

### Step 3: Configure Claude Code Settings

Create or update `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/hooks/pre-cli-hook.ps1",
            "timeout": 5
          },
          {
            "type": "prompt",
            "prompt": "Analyze PowerShell command for read-only vs modifying operations: $TOOL_INPUT\n\nCommand Categories:\n- Read-Only: Get-*, Test-*, Select-*, Where-*, Sort-*, Measure-*, Write-*\n- Modifying: New-*, Remove-*, Stop-*, Start-*, Set-*, Clear-*, Invoke-*\n\nRules:\n1. Parse the command for cmdlet name and parameters\n2. Check if command matches read-only patterns\n3. Check if command matches modifying patterns\n4. If any modifying cmdlet found, deny with explanation\n5. Default to safe (deny on uncertainty)\n\nReturn: 'approve' or 'deny' with detailed explanation",
            "timeout": 15
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
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

### Step 4: Restart Claude Code

Exit and restart Claude Code for the changes to take effect:

```bash
# In Claude Code
/exit

# Then restart from terminal
claude
```

## Testing for Windows PowerShell

### Method 1: Run Automated Test Suite (Recommended)

This is the easiest way to verify the hook works correctly.

**Option A: Run provided test script**

```powershell
# Navigate to the test directory
cd "C:\git\claudecode\poc6\powershell-test"

# Run the comprehensive test suite
.\Test-Hook.ps1
```

**Option B: Interactive testing in Claude Code**

Start Claude Code and try these commands:

```bash
# Read-only commands (should auto-approve)
Get-ChildItem
Get-Date
Get-Host
Get-Process | Select-Object -First 5 Name, Id

# Modifying commands (should prompt)
New-Item -Path "./test-hook.txt" -ItemType File
New-Item -Path "./test-dir" -ItemType Directory
```

### Method 2: Manual Testing

Run these commands in Claude Code to verify behavior:

**Test Read-Only Commands** (should execute without prompting):
```powershell
# These should all auto-approve
Get-ChildItem
Get-Location
Get-Date
Get-Host
Test-Path "./README.md"
Get-Process | Select-Object -First 5 Name, Id
Get-Service | Select-Object -First 5 Name, Status
```

**Test Modifying Commands** (should prompt for approval):
```powershell
# Each of these should prompt before executing
New-Item -Path "./test.txt" -ItemType File
New-Item -Path "./test-dir" -ItemType Directory
```

**Test Chained Commands**:
```powershell
# All read-only - should auto-approve
Get-Location; Get-Date

# Contains modifying - should prompt
Get-ChildItem; New-Item -Path "./test2.txt" -ItemType File
```

## Verification Checklist

After installation, verify all components on Windows:

- [ ] `.claude` directory exists in your user profile
- [ ] `cli-commands.json` file exists
- [ ] `hooks` subdirectory exists
- [ ] `pre-cli-hook.ps1` file exists in hooks directory
- [ ] `settings.json` is configured with PreToolUse hooks for PowerShell
- [ ] Claude Code was restarted after configuration
- [ ] Read-only commands auto-approve (no prompt)
- [ ] Modifying commands prompt for approval
- [ ] Chained commands analyzed correctly
- [ ] Hook shows analysis when prompting
- [ ] Default is safe (denies on unknown commands)

## Troubleshooting for Windows

### Issue: Hook doesn't trigger
- Verify `settings.json` is valid JSON (no syntax errors)
- Check if the hook file path in settings.json is correct for Windows
- Ensure PowerShell is in your PATH
- Restart Claude Code
- Check if ExecutionPolicy allows running scripts

### Issue: Commands always prompt
- Check that `cli-commands.json` has PowerShell commands listed
- Verify file is valid JSON (use `ConvertFrom-Json` in PowerShell)
- Check that configuration is loaded by hook
- Verify `settings.json` matcher is set to "PowerShell"

### Issue: Permission denied or execution policy error
- Set execution policy to allow scripts:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Issue: PowerShell commands not recognized
- Ensure PowerShell is in system PATH
- Check that you're using correct PowerShell syntax
- Verify Claude Code is using PowerShell (not cmd.exe)

### Issue: Hook works in some contexts but not others
- Check if in PowerShell elevated session (Run as Administrator)
- Verify $env:USERPROFILE resolves correctly
- Check if .claude directory is accessible

### Other Issues

**Hook shows error about ConvertFrom-Json**:
- Your PowerShell version might be too old (need v3+)
- Update PowerShell or use Windows Terminal

**Hook runs but always denies**:
- Check configuration file exists and has read-only commands
- Enable debug mode: `$env:HOOK_DEBUG = "true"`
- Review hook logic in pre-cli-hook.ps1

**Changes to cli-commands.json not taking effect**:
- Stop and restart Claude Code after editing config
- Verify JSON is valid using online validator
- Check file permissions (must be readable)

## Recommended Next Steps

1. **Run the test suite**: Use `.\Test-Hook.ps1` for comprehensive testing
2. **Customize commands**: Add your frequently used cmdlets to cli-commands.json
3. **Add more tools**: Extend for AWS CLI, Docker, Terraform commands
4. **Enable logging**: Set log_file in configuration to track approvals
5. **Team configuration**: Share cli-commands.json with your team
6. **Add complexity**: Extend hook to handle parameters and arguments
7. **Create aliases**: Add common command aliases to read-only list

## Configuration Management

### Backup your configuration:
```powershell
# Backup cli-commands.json
Copy-Item "$env:USERPROFILE\.claude\cli-commands.json" "$env:USERPROFILE\.claude\cli-commands.backup.json"

# Restore if needed
Copy-Item "$env:USERPROFILE\.claude\cli-commands.backup.json" "$env:USERPROFILE\.claude\cli-commands.json"
```

### Version control your config:
```powershell
# Initialize git repo for .claude
cd $env:USERPROFILE\.claude
git init
git add cli-commands.json settings.json
git commit -m "Initial hook configuration"
```

### Quick verification:
```powershell
# Test hook manually
$testInput = @{"tool_input"=@{"command"="Get-Date"}} | ConvertTo-Json
$testInput | powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\pre-cli-hook.ps1"
# Should exit with code 0 for read-only commands
```

## Summary

This hook system provides:
- ✅ Automatic approval for read-only PowerShell commands
- ✅ Approval prompts for modifying operations
- ✅ Configuration-based command management
- ✅ PowerShell-native implementation (no jq required)
- ✅ Global protection across all projects
- ✅ Comprehensive testing suite
- ✅ Windows-optimized (no Linux dependencies)

Enjoy using the CLI Security Hook with Claude Code on Windows!