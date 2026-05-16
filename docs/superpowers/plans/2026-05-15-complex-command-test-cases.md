# Complex Command Test Cases & JSON Config — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand `test-cases.xml` with 100+ complex command test cases across all 7 domains (heavy on PowerShell remoting + Linux SSH remoting), retrofit the `reason` attribute on all existing entries, and generate `commands.json` runtime config.

**Architecture:** Pure content authoring — no code to write. `test-cases.xml` gets a `reason` attribute retrofitted on all 228 existing entries, then 100+ new complex entries appended. `commands.json` is authored as a standalone runtime config with verb-based classification for PowerShell and AWS CLI, plus explicit pattern entries for all 7 domains. Both files live alongside each other at repo root.

**Tech Stack:** XML 1.0 (CDATA sections for multi-line), JSON (UTF-8, 2-space indent)

**Source spec:** `docs/superpowers/specs/2026-05-15-complex-command-test-cases-design.md`

---

### Task 1: Research complex command patterns across all domains

**Files:** None (research only)

- [ ] **Step 1: Search for complex PowerShell remoting commands**

Search brave-search for: "PowerShell Invoke-Command complex examples ScriptBlock nested brackets remoting"

- [ ] **Step 2: Search for complex Linux SSH remoting commands**

Search brave-search for: "ssh remote execution complex examples heredoc subshell nested commands"

- [ ] **Step 3: Search for complex DOS multi-line and chained commands**

Search brave-search for: "DOS batch script complex for loop if else setlocal nested cmd commands"

- [ ] **Step 4: Search for complex Terraform flag-separated subcommands**

Search brave-search for: "terraform -chdir complex apply import state mv command examples 2024"

- [ ] **Step 5: Search for complex Docker and Docker Compose commands**

Search brave-search for: "docker build multi-stage complex docker run networking volumes docker compose profiles extends"

- [ ] **Step 6: Search for complex kubectl commands**

Search brave-search for: "kubectl patch json strategic merge exec complex jsonpath go-template examples"

- [ ] **Step 7: Search for complex AWS CLI commands**

Search brave-search for: "aws ec2 run-instances user-data complex tag-specifications JMESPath query filter examples"

---

### Task 2: Retrofit `reason` attribute on existing DOS_CMD entries (30 allow, 29 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `DOS_CMD` category group

- [ ] **Step 1: Verify current state of DOS_CMD section**

```bash
awk '/category-group name="DOS_CMD"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
```

- [ ] **Step 2: Add `reason="read-only"` to all `expected="allow"` DOS_CMD entries**

For each `expected="allow"` entry in DOS_CMD, insert `reason="read-only"` between `expected="allow"` and `category=`.

Pattern to match:
```
<test-case expected="allow" category="DOS-
```
Replace with:
```
<test-case expected="allow" reason="read-only" category="DOS-
```

- [ ] **Step 3: Add reason attribute to all `expected="ask"` DOS_CMD entries**

For each `expected="ask"` entry in DOS_CMD, insert `reason="<specific-modifying-command>"` between `expected="ask"` and `category=`.

Map of reasons by entry type (check description to identify):
| Description contains | reason value |
|---|---|
| del / erase | `del` |
| rmdir | `rmdir` |
| copy / xcopy / robocopy | `copy` / `xcopy` / `robocopy` |
| move / rename | `move` |
| mkdir / md | `mkdir` |
| taskkill | `taskkill` |
| shutdown | `shutdown` |
| net start | `net start` |
| net stop | `net stop` |
| reg add/delete/import | `reg add` / `reg delete` / `reg import` |
| sc config/delete/stop | `sc config` / `sc delete` / `sc stop` |
| netsh | `netsh advfirewall` |
| format | `format` |
| diskpart | `diskpart` |
| icacls / cacls | `icacls` |
| takeown | `takeown` |
| bcdedit | `bcdedit` |
| setx | `setx` |
| assoc / ftype | `assoc` / `ftype` |

- [ ] **Step 4: Validate — count reasons in DOS_CMD section**

```bash
awk '/category-group name="DOS_CMD"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Expected: 59 (one per test-case in DOS_CMD)

---

### Task 3: Retrofit `reason` attribute on existing PowerShell entries (26 allow, 28 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `PowerShell` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` PowerShell entries**

```bash
# Replace all allow entries in PowerShell group
# Pattern: expected="allow" category="PowerShell-
# Replace:  expected="allow" reason="read-only" category="PowerShell-
```

- [ ] **Step 2: Add reason to all `expected="ask"` PowerShell entries**

Reason value = the specific modifying verb/cmdlet from the description (e.g., `Remove-Item`, `Stop-Process`, `Invoke-Expression`, `Set-ExecutionPolicy`, `Enable-PSRemoting`, `Invoke-Command`, `Enter-PSSession`, `Set-Content`, `Add-Content`, `Out-File`, `New-Item`, `Copy-Item`, `Move-Item`, `Rename-Item`, `Stop-Service`, `Start-Service`, `Restart-Service`, `Set-Service`, `Register-PSSessionConfiguration`)

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="PowerShell"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="PowerShell"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 4: Retrofit `reason` attribute on existing Linux entries (38 allow, 25 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `Linux` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` Linux entries**

```bash
# Pattern: expected="allow" category="Linux-
# Replace:  expected="allow" reason="read-only" category="Linux-
```

- [ ] **Step 2: Add reason to all `expected="ask"` Linux entries**

Reason values extracted from description: `rm`, `mv`, `cp`, `chmod`, `chown`, `sed -i`, `mkdir`, `rmdir`, `ln`, `systemctl start`, `systemctl stop`, `systemctl restart`, `systemctl enable`, `systemctl disable`, `systemctl mask`, `systemctl daemon-reload`, `useradd`, `userdel`, `usermod`, `passwd`, `apt install`, `apt remove`, `apt purge`, `apt autoremove`, `iptables`, `mount`, `umount`, `dd`, `shutdown`, `reboot`, `modprobe`, `crontab`

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="Linux"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="Linux"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 5: Retrofit `reason` attribute on existing Terraform entries (6 allow, 5 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `Terraform` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` Terraform entries**

```bash
# Pattern: expected="allow" category="Terraform-
# Replace:  expected="allow" reason="read-only" category="Terraform-
```

- [ ] **Step 2: Add reason to all `expected="ask"` Terraform entries**

Reason values: `terraform apply`, `terraform destroy`, `terraform state rm`, `terraform state mv`, `terraform import`, `terraform workspace new`, `terraform workspace delete`, `terraform init`, `terraform fmt`, `terraform taint`, `terraform untaint`

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="Terraform"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="Terraform"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 6: Retrofit `reason` attribute on existing Docker entries (8 allow, 8 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `Docker` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` Docker entries**

```bash
# Pattern: expected="allow" category="Docker-
# Replace:  expected="allow" reason="read-only" category="Docker-
```

- [ ] **Step 2: Add reason to all `expected="ask"` Docker entries**

Reason values: `docker rm`, `docker stop`, `docker kill`, `docker volume rm`, `docker system prune`, `docker run`, `docker start`, `docker restart`, `docker exec`, `docker build`, `docker push`, `docker rmi`, `docker compose up`, `docker compose down`, `docker compose build`, `docker compose restart`, `docker compose rm`, `docker container prune`, `docker volume prune`, `docker network prune`, `docker buildx build`, `docker buildx prune`

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="Docker"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="Docker"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 7: Retrofit `reason` attribute on existing Kubernetes entries (7 allow, 6 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `Kubernetes` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` Kubernetes entries**

```bash
# Pattern: expected="allow" category="Kube-
# Replace:  expected="allow" reason="read-only" category="Kube-
```

- [ ] **Step 2: Add reason to all `expected="ask"` Kubernetes entries**

Reason values: `kubectl delete`, `kubectl apply`, `kubectl create`, `kubectl patch`, `kubectl scale`, `kubectl expose`, `kubectl exec`, `kubectl rollout undo`, `kubectl rollout restart`, `kubectl drain`, `kubectl cordon`, `kubectl uncordon`, `kubectl replace`, `kubectl edit`

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="Kubernetes"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="Kubernetes"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 8: Retrofit `reason` attribute on existing AWS_CLI entries (6 allow, 6 ask)

**Files:**
- Modify: `test-cases.xml` — every `<test-case>` in the `AWS_CLI` category group

- [ ] **Step 1: Add `reason="read-only"` to all `expected="allow"` AWS_CLI entries**

```bash
# Pattern: expected="allow" category="AWS-
# Replace:  expected="allow" reason="read-only" category="AWS-
```

- [ ] **Step 2: Add reason to all `expected="ask"` AWS_CLI entries**

Reason values: `aws s3 rm`, `aws s3 rb`, `aws ec2 terminate-instances`, `aws lambda update-function-code`, `aws iam create-user`, `aws ec2 reboot-instances`

- [ ] **Step 3: Validate**

```bash
awk '/category-group name="AWS_CLI"/,/<\/category-group>/' test-cases.xml | grep -c '<test-case'
awk '/category-group name="AWS_CLI"/,/<\/category-group>/' test-cases.xml | grep -c 'reason='
```
Both counts must match.

---

### Task 9: Add new complex DOS_CMD test cases (12+ entries)

**Files:**
- Modify: `test-cases.xml` — append into `DOS_CMD` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of DOS_CMD**

- [ ] **Step 2: Append the following complex DOS_CMD test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="del" category="DOS-ComplexModify">
      <description>Multi-line batch with if/else branching that deletes temp files conditionally</description>
      <copilot-command><![CDATA[if exist C:\temp\*.tmp (
    del /q C:\temp\*.tmp
    echo Temp files cleaned
) else (
    echo No temp files found
)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="del" category="DOS-ComplexModify">
      <description>for loop iterating over dir output and deleting matching files</description>
      <copilot-command><![CDATA[for /f "tokens=*" %%i in ('dir /b /s C:\logs\*.old') do del /q "%%i"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="del" category="DOS-ComplexModify">
      <description>Piped chain with findstr filtering then delete on matching results</description>
      <copilot-command><![CDATA[dir /b C:\temp\*.log | findstr /i "error" && del /q C:\temp\*error*.log]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="taskkill" category="DOS-ComplexModify">
      <description>for loop finding and killing processes by memory usage threshold</description>
      <copilot-command><![CDATA[for /f "tokens=2" %%i in ('tasklist /fi "MEMUSAGE gt 500000" /fo csv ^| findstr /i "exe"') do taskkill /pid %%i /f]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="taskkill" category="DOS-ComplexModify">
      <description>Multi-line batch with setlocal, assignment, if/else, and taskkill</description>
      <copilot-command><![CDATA[setlocal enabledelayedexpansion
set THRESHOLD=200000
for /f "skip=3 tokens=2,5" %%a in ('tasklist /fi "STATUS eq running"') do (
    if %%b gtr !THRESHOLD! (
        echo Killing %%a (%%b KB)
        taskkill /f /pid %%a
    )
)
endlocal]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="sc config" category="DOS-ComplexModify">
      <description>Multi-line service configuration with conditional check before modifying</description>
      <copilot-command><![CDATA[sc query "Spooler" | findstr /i "RUNNING"
if %errorlevel% equ 0 (
    sc config "Spooler" start= auto
    echo Configured Spooler for auto-start
) else (
    sc config "Spooler" start= disabled
)]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="DOS-ComplexRead">
      <description>Multi-line for loop reading registry and filtering with findstr</description>
      <copilot-command><![CDATA[for /f "tokens=*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /s ^| findstr /i "DisplayName DisplayVersion Publisher"') do @echo %%a]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="DOS-ComplexRead">
      <description>Complex wmic query with multi-condition WHERE clause and formatting</description>
      <copilot-command><![CDATA[wmic process where "name='svchost.exe' and WorkingSetSize > 100000000" get ProcessId,Name,WorkingSetSize,CommandLine /format:csv]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="DOS-ComplexRead">
      <description>findstr with multiple patterns, case-insensitive, recursive directory search</description>
      <copilot-command><![CDATA[findstr /s /i /n /r "ERROR\|WARN\|FATAL\|CRITICAL" C:\logs\*.log C:\app\*.log]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="reg add" category="DOS-ComplexModify">
      <description>Registry add inside nested if/else branching on system architecture check</description>
      <copilot-command><![CDATA[wmic os get osarchitecture | findstr /i "64"
if %errorlevel% equ 0 (
    reg add "HKLM\SOFTWARE\WOW6432Node\MyApp" /v InstallPath /t REG_SZ /d "C:\Program Files (x86)\MyApp" /f
) else (
    reg add "HKLM\SOFTWARE\MyApp" /v InstallPath /t REG_SZ /d "C:\Program Files\MyApp" /f
)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="netsh advfirewall" category="DOS-ComplexModify">
      <description>netsh firewall rule creation with multi-line rule specification</description>
      <copilot-command><![CDATA[netsh advfirewall firewall add rule name="Allow HTTP" ^
    dir=in action=allow ^
    protocol=TCP localport=80,443 ^
    remoteip=192.168.1.0/24 ^
    profile=domain,private]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="diskpart" category="DOS-ComplexModify">
      <description>diskpart script with multi-step partition creation</description>
      <copilot-command><![CDATA[echo select disk 1 > diskpart.txt && echo clean >> diskpart.txt && echo create partition primary size=102400 >> diskpart.txt && echo format fs=ntfs quick >> diskpart.txt && echo assign letter=E >> diskpart.txt && diskpart /s diskpart.txt]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="DOS_CMD"/,/<\/category-group>/' test-cases.xml | grep -c 'DOS-Complex'
```
Expected: 12

---

### Task 10: Add new complex PowerShell test cases (18+ entries, heavy remoting)

**Files:**
- Modify: `test-cases.xml` — append into `PowerShell` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of PowerShell**

- [ ] **Step 2: Append the following complex PowerShell test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>Invoke-Command with remote session and ScriptBlock containing if/else and file modification</description>
      <copilot-command><![CDATA[$session = New-PSSession -ComputerName "SRV01", "SRV02" -Credential $cred
Invoke-Command -Session $session -ScriptBlock {
    $patches = Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date).AddDays(-30) }
    if ($patches.Count -gt 0) {
        $patches | Export-Csv -Path "C:\Reports\patches.csv" -NoTypeInformation
        Write-Host "Exported $($patches.Count) patches"
    } else {
        Write-Warning "No recent patches found"
    }
}
Remove-PSSession $session]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Remove-Item" category="PowerShell-ComplexModify">
      <description>foreach loop with nested if/else conditionally deleting files with multi-level bracket nesting</description>
      <copilot-command><![CDATA[$paths = @("C:\temp\cache", "C:\temp\logs", "C:\temp\downloads")
foreach ($path in $paths) {
    $age = (Get-Date).AddDays(-7)
    $files = Get-ChildItem -Path $path -Recurse -File | Where-Object { $_.LastWriteTime -lt $age }
    if ($files.Count -gt 0) {
        $files | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host ("Removed: {0} (age: {1} days)" -f $_.Name, [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays, 1))
        }
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>PowerShell remoting with Invoke-Command -FilePath executing complex remote script</description>
      <copilot-command><![CDATA[Invoke-Command -ComputerName (Get-Content "C:\scripts\serverlist.txt") -FilePath "C:\scripts\RemoteAudit.ps1" -ArgumentList @{
    TargetPath = "D:\data"
    ExportPath = "\\fileserver\audit\"
    MaxAgeDays = 90
    IncludeSubdirs = $true
} -ThrottleLimit 10 -AsJob]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>New-PSSession + Invoke-Command across multiple computers with error handling and modifying operations</description>
      <copilot-command><![CDATA[$computers = @("DC01", "DC02", "EXCH01", "SQL01")
$cred = Get-Credential "CONTOSO\Admin"
$results = foreach ($computer in $computers) {
    try {
        $session = New-PSSession -ComputerName $computer -Credential $cred -ErrorAction Stop
        Invoke-Command -Session $session -ScriptBlock {
            Restart-Service -Name "W3SVC" -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\MyApp" -Name "LastRestart" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Get-Service -Name "W3SVC" | Select-Object MachineName, Name, Status
        }
    }
    catch { Write-Warning "$computer : $_" }
    finally { if ($session) { Remove-PSSession $session } }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Expression" category="PowerShell-ComplexModify">
      <description>Invoke-Expression with dynamic script containing foreach, if/else, try/catch/finally, and service control</description>
      <copilot-command><![CDATA[@@amIEai -Source "https://source/ComplexDeploy.ps1" -Arguments @{
    Targets    = @("APP01", "APP02", "APP03")
    Service    = "MyAppService"
    Action     = "Restart"
    BackupPath = "D:\backups\config"
    Force      = $true
} -OutputPath $results -Verb error]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Enable-PSRemoting" category="PowerShell-ComplexModify">
      <description>Enable-PSRemoting with confirmation suppression and firewall rule configuration</description>
      <copilot-command><![CDATA[Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*.contoso.com" -Force
Set-NetFirewallRule -DisplayGroup "Windows Remote Management" -Enabled True -PassThru | Select-Object DisplayName, Enabled]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>Enter-PSSession style command using Invoke-Command with deeply nested script including DSC resource check and state modification</description>
      <copilot-command><![CDATA[Invoke-Command -ComputerName "SRV01", "SRV02" -ScriptBlock {
    $config = @{
        Name = "WebServerCheck"
        ModuleName = "PSDesiredStateConfiguration"
        Property = @{
            WindowsFeature = @(
                @{ Name = "Web-Server"; Ensure = "Present" }
                @{ Name = "Web-Asp-Net45"; Ensure = "Present" }
            )
            Service = @(
                @{ Name = "W3SVC"; State = "Running"; StartupType = "Automatic" }
            )
        }
    }
    $current = Get-DscConfiguration | ConvertTo-Json -Depth 5
    Write-Host "Current DSC config: $current"
    if ((Get-Service "W3SVC").Status -ne "Running") {
        Start-Service "W3SVC"
        Write-Host "Started W3SVC"
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Set-ExecutionPolicy" category="PowerShell-ComplexModify">
      <description>Set-ExecutionPolicy for multiple scopes with conditional logic</description>
      <copilot-command><![CDATA[$scopes = @("Process", "CurrentUser", "LocalMachine")
foreach ($scope in $scopes) {
    $current = Get-ExecutionPolicy -Scope $scope
    Write-Host "Current policy for $scope : $current"
    if ($current -ne "RemoteSigned") {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope $scope -Force
        Write-Host "Updated $scope to RemoteSigned"
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Start-Job" category="PowerShell-ComplexModify">
      <description>Start-Job with remote execution script containing while loop and file operations</description>
      <copilot-command><![CDATA[$jobs = @("SRV01", "SRV02", "SRV03") | ForEach-Object {
    Start-Job -Name "Deploy-$_" -ScriptBlock {
        param($computer, $cred)
        $session = New-PSSession -ComputerName $computer -Credential $cred
        Invoke-Command -Session $session -ScriptBlock {
            $count = 0
            while ($count -lt 5) {
                $count++
                Copy-Item "\\fileserver\deploy\app.zip" -Destination "C:\app\temp\app.zip" -Force
                if (Test-Path "C:\app\temp\app.zip") {
                    Expand-Archive -Path "C:\app\temp\app.zip" -DestinationPath "C:\app\live\" -Force
                    break
                }
                Start-Sleep -Seconds 10
            }
        }
        Remove-PSSession $session
    } -ArgumentList $_, $cred
}
$jobs | Wait-Job | Receive-Job]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="PowerShell-ComplexRead">
      <description>Complex Invoke-Command remotely querying WMI with calculated properties and filtered output</description>
      <copilot-command><![CDATA[Invoke-Command -ComputerName "SRV01", "SRV02" -ScriptBlock {
    Get-CimInstance -ClassName Win32_Service -Filter "State='Running' AND StartMode='Auto'" |
        Select-Object @{N='Computer';E={$env:COMPUTERNAME}}, Name, DisplayName,
                      @{N='ProcessId';E={$_.ProcessId}},
                      @{N='MemoryMB';E={[math]::Round((Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).WorkingSet64/1MB, 1)}} |
        Sort-Object MemoryMB -Descending |
        Format-Table -AutoSize
}]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="PowerShell-ComplexRead">
      <description>PowerShell while loop with try/catch polling remote registry and event log</description>
      <copilot-command><![CDATA[while ($true) {
    try {
        $events = Get-WinEvent -ComputerName "DC01" -LogName Security -MaxEvents 10 -FilterXPath "*[System[EventID=4625]]" |
            Select-Object TimeCreated, @{N='User';E={$_.Properties[5].Value}},
                          @{N='SourceIP';E={$_.Properties[18].Value}}
        if ($events.Count -gt 0) {
            $events | Format-Table -AutoSize
        }
    } catch {
        Write-Warning "Connection lost: $_"
    }
    Start-Sleep -Seconds 30
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>Multi-hop remoting: Invoke-Command from local -> jump host -> target server</description>
      <copilot-command><![CDATA[Invoke-Command -ComputerName "JUMPHOST" -Credential $cred -ScriptBlock {
    Invoke-Command -ComputerName "TARGET-DB01" -ScriptBlock {
        Stop-Service "MSSQLSERVER" -Force
        Copy-Item "\\backupserver\sql\*.bak" -Destination "D:\SQL\Data\" -Force
        Start-Service "MSSQLSERVER"
        Get-Service "MSSQLSERVER" | Select-Object MachineName, Name, Status
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="New-Item" category="PowerShell-ComplexModify">
      <description>Combined read queries with New-Item creating directory and Out-File writing report</description>
      <copilot-command><![CDATA[$servers = Get-ADComputer -Filter "OperatingSystem -like '*Server*'" -Properties OperatingSystem | Select-Object -ExpandProperty Name
$report = @()
foreach ($server in $servers) {
    $info = Invoke-Command -ComputerName $server -ScriptBlock {
        [PSCustomObject]@{
            Server      = $env:COMPUTERNAME
            CPU         = (Get-Counter "\Processor(_Total)\% Processor Time").CounterSamples.CookedValue
            MemoryGB    = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB, 2)
            DiskFreeGB  = [math]::Round((Get-PSDrive C).Free/1GB, 2)
            Services    = (Get-Service | Where-Object Status -eq "Stopped" | Select-Object -ExpandProperty Name) -join ", "
        }
    } -ErrorAction SilentlyContinue
    $report += $info
}
New-Item -Path "C:\Reports\ServerHealth" -ItemType Directory -Force | Out-Null
$report | Export-Csv "C:\Reports\ServerHealth\health-$(Get-Date -Format 'yyyyMMdd-HHmm').csv" -NoTypeInformation]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Invoke-Command" category="PowerShell-ComplexModify">
      <description>Invoke-Command using SSH transport (PowerShell 6+) with nested loops and system modifications</description>
      <copilot-command><![CDATA[Invoke-Command -HostName "linux01.contoso.com" -UserName "admin" -SSHConnection (New-PSSession -HostName "linux01.contoso.com" -UserName "admin" -KeyFilePath "$env:USERPROFILE\.ssh\id_rsa") -ScriptBlock {
    $services = @("nginx", "postgresql", "redis")
    foreach ($svc in $services) {
        $status = systemctl is-active $svc 2>$null
        if ($status -ne "active") {
            systemctl start $svc
            Write-Host "Started $svc"
        }
        $ver = systemctl show $svc -p Version 2>$null
        Write-Host "$svc version: $ver"
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="Set-ItemProperty" category="PowerShell-ComplexModify">
      <description>Complex registry modification with nested property iteration and error recovery</description>
      <copilot-command><![CDATA[$registryPath = "HKLM:\SOFTWARE\MyApp\Config"
$settings = @{
    "LogLevel"     = "Verbose"
    "MaxRetries"   = 5
    "TimeoutSec"   = 30
    "EndpointUrl"  = "https://api.contoso.com/v2"
    "EnableTracing" = 1
}
if (-not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
foreach ($key in $settings.Keys) {
    try {
        Set-ItemProperty -Path $registryPath -Name $key -Value $settings[$key] -Type (
            if ($settings[$key] -is [int]) { "DWord" } else { "String" }
        ) -ErrorAction Stop
    } catch {
        Write-Error "Failed to set $key : $_"
    }
}]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="PowerShell-ComplexRead">
      <description>Complex pipeline with ForEach-Object, Where-Object, Select-Object, calculated properties on remote session query</description>
      <copilot-command><![CDATA[Invoke-Command -ComputerName "DC01" -ScriptBlock {
    Get-ADUser -Filter * -Properties LastLogonDate, PasswordLastSet, PasswordNeverExpires, Enabled |
        Where-Object { $_.Enabled -and -not $_.PasswordNeverExpires } |
        ForEach-Object {
            $daysSinceLogon = if ($_.LastLogonDate) { ((Get-Date) - $_.LastLogonDate).Days } else { 999 }
            $daysSincePwdSet = ((Get-Date) - $_.PasswordLastSet).Days
            [PSCustomObject]@{
                SamAccountName  = $_.SamAccountName
                Name            = $_.Name
                DaysSinceLogon  = $daysSinceLogon
                DaysSincePwdSet = $daysSincePwdSet
                RiskScore       = if ($daysSinceLogon -gt 90 -or $daysSincePwdSet -gt 180) { "HIGH" }
                                  elseif ($daysSinceLogon -gt 30 -or $daysSincePwdSet -gt 90) { "MEDIUM" } else { "LOW" }
            }
        } | Sort-Object RiskScore -Descending | Select-Object -First 50 | Format-Table -AutoSize
}]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="PowerShell"/,/<\/category-group>/' test-cases.xml | grep -c 'PowerShell-Complex'
```
Expected: 18 (more than the 15 minimum)

---

### Task 11: Add new complex Linux test cases (18+ entries, heavy SSH remoting)

**Files:**
- Modify: `test-cases.xml` — append into `Linux` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of Linux**

- [ ] **Step 2: Append the following complex Linux test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="ssh" category="Linux-ComplexModify">
      <description>SSH remote execution with command chain containing modifying operations</description>
      <copilot-command><![CDATA[ssh user@prod-server-01 "cd /opt/app && git pull origin main && systemctl restart app-service && systemctl status app-service"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="ssh" category="Linux-ComplexModify">
      <description>SSH with heredoc executing multi-line script with if/else and file operations on remote host</description>
      <copilot-command><![CDATA[ssh user@db-cluster-01 << 'ENDSSH'
    if [ -d /var/lib/postgresql/wal_archive ]; then
        find /var/lib/postgresql/wal_archive -name "*.gz" -mtime +7 -delete
        echo "Cleaned WAL archives older than 7 days"
    else
        mkdir -p /var/lib/postgresql/wal_archive
        chown postgres:postgres /var/lib/postgresql/wal_archive
    fi
ENDSSH]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="ssh" category="Linux-ComplexModify">
      <description>SSH with port forwarding, remote command execution, and nested subshells</description>
      <copilot-command><![CDATA[ssh -L 5432:localhost:5432 -L 6379:localhost:6379 user@bastion-host " \
    docker exec postgres pg_dump -U app mydb | gzip > /backups/mydb-\$(date +%Y%m%d-%H%M).sql.gz && \
    redis-cli BGSAVE && \
    aws s3 cp /backups/ s3://my-backups/databases/ --recursive --exclude '*' --include '*.gz'"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="ssh" category="Linux-ComplexModify">
      <description>SSH with rsync over tunnel for remote file synchronization</description>
      <copilot-command><![CDATA[ssh -R 8730:localhost:873 admin@staging-server "rsync -avz --delete --exclude='.git' --exclude='node_modules' rsync://app@localhost:8730/deploy/ /var/www/app/"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="ssh" category="Linux-ComplexModify">
      <description>SSH executing remote for loop that iterates over docker containers and restarts selective ones</description>
      <copilot-command><![CDATA[ssh deploy@k8s-node-0[1-4] "for c in \$(docker ps -q --filter 'name=app-' --filter 'status=running'); do \
    memory=\$(docker stats --no-stream --format '{{.MemPerc}}' \$c | tr -d '%'); \
    if (( \$(echo \"\$memory > 85\" | bc -l) )); then \
        echo \"Restarting \$c (memory: \$memory%)\"; \
        docker restart \$c; \
    fi; \
done"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="rsync" category="Linux-ComplexModify">
      <description>rsync over SSH with complex include/exclude patterns and multi-level filter rules</description>
      <copilot-command><![CDATA[rsync -avz --progress \
    --include='*.conf' \
    --include='*.yaml' \
    --include='*.json' \
    --include='*.key' \
    --exclude='*.log' \
    --exclude='*.tmp' \
    --exclude='.git/' \
    --exclude='node_modules/' \
    --filter='merge .rsync-filter' \
    /etc/myapp/ user@backup-server:/backups/myapp-config/]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="rm" category="Linux-ComplexModify">
      <description>find -exec with multi-level nesting, conditional delete based on size and age</description>
      <copilot-command><![CDATA[find /var/log -type f \( -name "*.log" -o -name "*.log.gz" \) -mtime +30 -size +100M \
    -exec sh -c 'echo "Removing large old log: $1 ($(du -h "$1" | cut -f1))"; rm -f "$1"' _ {} \;]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="rm" category="Linux-ComplexModify">
      <description>Complex piped chain with awk filtering, xargs, and conditional rm</description>
      <copilot-command><![CDATA[ls -la /tmp/*.tmp /tmp/*.cache 2>/dev/null | \
    awk '$5 > 1048576 {print $NF}' | \
    xargs -I {} sh -c 'echo "Removing {} ($(stat -c%s "{}") bytes)"; rm -f "{}"' ]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Linux-ComplexRead">
      <description>SSH remote read-only: querying system health with nested commands and awk processing</description>
      <copilot-command><![CDATA[ssh user@web-server-01 "echo '=== DISK ===' && df -h | awk '\$5+0 > 80 {print \$1, \$5, \$6}' && \
    echo '=== MEMORY ===' && free -h | awk 'NR==2 {print \"Total:\", \$2, \"Used:\", \$3, \"Free:\", \$4}' && \
    echo '=== LOAD ===' && uptime | awk -F'load average:' '{print \$2}' && \
    echo '=== TOP CPU ===' && ps aux --sort=-%cpu | head -6 | tail -5 | awk '{print \$2, \$3\"%\", \$11}'"]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Linux-ComplexRead">
      <description>Complex find with nested grep, wc, sort pipeline for log pattern analysis</description>
      <copilot-command><![CDATA[find /var/log/nginx -name "access.log*" -exec sh -c '
    echo "=== $1 ===" && \
    grep -oP "\"GET [^\"]+\"" "$1" | sort | uniq -c | sort -rn | head -20 && \
    echo "Total requests: $(wc -l < "$1")" && \
    echo "Unique IPs: $(awk "{print \$1}" "$1" | sort -u | wc -l)" && \
    echo ""
' _ {} \;]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="sed -i" category="Linux-ComplexModify">
      <description>find with sed -i in-place editing across multiple files with regex replacement chain</description>
      <copilot-command><![CDATA[find /etc/nginx -name "*.conf" -exec sed -i \
    -e 's/server_name _;/server_name app.contoso.com;/g' \
    -e 's/proxy_pass http:\/\/localhost:8000/proxy_pass http:\/\/backend:9090/g' \
    -e 's/keepalive_timeout 65/keepalive_timeout 120/g' \
    -e '/server_tokens on/d' {} \;]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="systemctl restart" category="Linux-ComplexModify">
      <description>sudo with conditional service restart based on file content check</description>
      <copilot-command><![CDATA[sudo sh -c '
    if grep -q "reload=true" /etc/myapp/config.yaml; then
        systemctl daemon-reload
    fi
    for svc in nginx postgresql redis-server; do
        if systemctl is-active --quiet $svc; then
            systemctl restart $svc
            echo "Restarted $svc: $(systemctl is-active $svc)"
        fi
    done
']]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="iptables" category="Linux-ComplexModify">
      <description>iptables with complex rule manipulation including save and restore</description>
      <copilot-command><![CDATA[sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j REDIRECT --to-port 8080 && \
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j REDIRECT --to-port 8443 && \
sudo iptables -A INPUT -p tcp --dport 8080 -s 10.0.0.0/8 -j ACCEPT && \
sudo iptables -A INPUT -p tcp --dport 8443 -s 10.0.0.0/8 -j ACCEPT && \
sudo iptables -A INPUT -p tcp --dport 8080 -j DROP && \
sudo iptables -A INPUT -p tcp --dport 8443 -j DROP && \
sudo iptables-save > /etc/iptables/rules.v4]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Linux-ComplexRead">
      <description>Nested subshells with process substitution diffing remote vs local config</description>
      <copilot-command><![CDATA[diff <(ssh user@app-server "cat /etc/app/config.yaml | grep -v '^#' | grep -v '^$' | sort") \
     <(grep -v '^#' /etc/app/config.yaml | grep -v '^$' | sort)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="dd" category="Linux-ComplexModify">
      <description>dd with progress monitoring, block device write for USB imaging</description>
      <copilot-command><![CDATA[sudo dd if=ubuntu-24.04-server.iso of=/dev/sdb bs=4M status=progress && sync]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="userdel" category="Linux-ComplexModify">
      <description>userdel with home directory removal and conditional checks on process ownership</description>
      <copilot-command><![CDATA[sudo sh -c 'user="temp-worker"; \
    if id "$user" &>/dev/null; then \
        if pgrep -u "$user" > /dev/null; then \
            pkill -u "$user"; \
            echo "Killed processes owned by $user"; \
        fi; \
        userdel -r "$user"; \
        echo "Removed user $user and home directory"; \
    fi']]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Linux-ComplexRead">
      <description>Complex awk processing of multiple remote files via SSH with computed fields</description>
      <copilot-command><![CDATA[ssh user@log-server "for f in /var/log/app/app-*.log; do \
    awk -F'|' '
        /ERROR/ {errors++; err_bytes[\$3] += \$5}
        /WARN/  {warns++}
        END {
            printf \"File: %s | Errors: %d | Warnings: %d\\n\", FILENAME, errors, warns
            for (ep in err_bytes) printf \"  Endpoint %s: %d bytes\\n\", ep, err_bytes[ep]
        }
    ' \"\$f\"; \
done"]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="Linux"/,/<\/category-group>/' test-cases.xml | grep -c 'Linux-Complex'
```
Expected: 18

---

### Task 12: Add new complex Terraform test cases (12+ entries)

**Files:**
- Modify: `test-cases.xml` — append into `Terraform` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of Terraform**

- [ ] **Step 2: Append the following complex Terraform test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="terraform apply" category="Terraform-ComplexModify">
      <description>terraform apply with -chdir flag-separated subcommand and --auto-approve</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" apply -auto-approve -var-file="prod.tfvars" -var="region=us-east-1" -var="cluster_size=5"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform apply" category="Terraform-ComplexModify">
      <description>terraform plan saving to file then applying from named plan file</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\staging\" plan -out=tfplan -var-file="staging.tfvars" -target=module.eks && terraform -chdir=".\environments\staging\" apply tfplan]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform destroy" category="Terraform-ComplexModify">
      <description>terraform destroy with -chdir, targeted resources, and auto-approve</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\dev\" destroy -auto-approve -target=module.redis -target=module.opensearch -var-file="dev.tfvars"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform state mv" category="Terraform-ComplexModify">
      <description>terraform state mv with -chdir flag separation and complex resource addressing</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" state mv "module.app_cluster.aws_ecs_service.api[0]" "module.app_cluster.aws_ecs_service.api[\"primary\"]"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform state rm" category="Terraform-ComplexModify">
      <description>terraform state rm with multiple resource addresses in one command</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" state rm module.vpc.aws_subnet.public[0] module.vpc.aws_subnet.public[1] module.vpc.aws_subnet.private[0] module.vpc.aws_route_table.private]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform import" category="Terraform-ComplexModify">
      <description>terraform import with -chdir and multiple variable files for complex resource</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" import -var-file="prod.tfvars" -var-file="secrets.tfvars" aws_rds_cluster_instance.main my-rds-cluster/read-write-instance-01]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform init" category="Terraform-ComplexModify">
      <description>terraform init with -chdir, backend-config, and upgrade flag</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" init -reconfigure -upgrade -backend-config="backend-prod.hcl" -backend-config="key=prod/terraform.tfstate"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform workspace new" category="Terraform-ComplexModify">
      <description>terraform workspace creation with -chdir then select in sequence</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" workspace new us-west-2 && terraform -chdir=".\environments\prod\" workspace select us-west-2]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform force-unlock" category="Terraform-ComplexModify">
      <description>terraform force-unlock with specific lock ID</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" force-unlock -force "8b8b456a-1234-5678-9abc-def012345678"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform taint" category="Terraform-ComplexModify">
      <description>terraform taint with -chdir for specific module resource</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\staging\" taint "module.compute.aws_instance.bastion[\"primary\"]"]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Terraform-ComplexRead">
      <description>terraform plan read-only with -json piped to jq for structured analysis</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" plan -json -out=/dev/null | jq '.resource_changes[] | select(.change.actions[] | contains("delete")) | {address: .address, name: .name, actions: .change.actions}' ]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Terraform-ComplexRead">
      <description>terraform output with -json and jq filtering for nested values</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" output -json | jq '{cluster_endpoint: .cluster_endpoint.value, node_groups: [.node_groups.value[] | {name: .node_group_name, status: .status, scaling: .scaling_config}]}' ]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="terraform state mv" category="Terraform-ComplexModify">
      <description>terraform state mv with -chdir and backup file specification</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" state mv -backup=state-backups/pre-refactor.tfstate -state-out=terraform.tfstate module.old_network.aws_vpc.main module.networking.aws_vpc.main]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Terraform-ComplexRead">
      <description>terraform console with -chdir and expression evaluation (interactive but read-only evaluation)</description>
      <copilot-command><![CDATA[terraform -chdir=".\environments\prod\" console -var-file="prod.tfvars" <<< "module.vpc.vpc_id"]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="Terraform"/,/<\/category-group>/' test-cases.xml | grep -c 'Terraform-Complex'
```
Expected: 14

---

### Task 13: Add new complex Docker test cases (14+ entries)

**Files:**
- Modify: `test-cases.xml` — append into `Docker` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of Docker**

- [ ] **Step 2: Append the following complex Docker test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="docker build" category="Docker-ComplexModify">
      <description>Multi-stage Docker build with multiple --build-arg and --secret and complex tagging</description>
      <copilot-command><![CDATA[docker build \
    --build-arg BASE_IMAGE=node:22-alpine \
    --build-arg APP_VERSION=$(git describe --tags --always) \
    --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --build-arg VCS_REF=$(git rev-parse --short HEAD) \
    --secret id=npmrc,src=$HOME/.npmrc \
    --tag myapp:$(git describe --tags --always) \
    --tag myapp:latest \
    --tag registry.contoso.com/myapp:$(git describe --tags --always) \
    --file Dockerfile.multi .]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker exec" category="Docker-ComplexModify">
      <description>docker exec running complex nested shell commands inside container</description>
      <copilot-command><![CDATA[docker exec my-postgres sh -c "
    psql -U postgres -d mydb << 'SQL'
        BEGIN;
        DELETE FROM sessions WHERE last_active < now() - interval '30 days';
        VACUUM ANALYZE sessions;
        SELECT count(*) AS active_sessions FROM sessions WHERE last_active >= now() - interval '1 hour';
        COMMIT;
SQL
"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker run" category="Docker-ComplexModify">
      <description>docker run with complex networking, multiple volume mounts, environment, and resource limits</description>
      <copilot-command><![CDATA[docker run -d --name app-prod \
    --network=app-net --ip=172.20.0.50 \
    --add-host=db.internal:172.20.0.10 \
    --add-host=cache.internal:172.20.0.20 \
    -p 8080:8080 -p 8443:8443 \
    -v app-data:/opt/app/data:rw \
    -v app-config:/opt/app/config:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e APP_ENV=production \
    -e DB_URL=jdbc:postgresql://db.internal:5432/mydb \
    -e REDIS_URL=redis://cache.internal:6379 \
    -e JAVA_OPTS="-Xms512m -Xmx2048m -XX:+UseG1GC" \
    --cpus=2 --memory=4g --memory-swap=4g \
    --restart=unless-stopped \
    --health-cmd="curl -f http://localhost:8080/health || exit 1" \
    --health-interval=30s --health-retries=3 --health-timeout=5s \
    myapp:2.4.1]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker compose up" category="Docker-ComplexModify">
      <description>docker compose with profiles, multiple files, build args, and detached mode</description>
      <copilot-command><![CDATA[docker compose \
    -f docker-compose.yml \
    -f docker-compose.prod.yml \
    -f docker-compose.observability.yml \
    --profile production \
    --profile monitoring \
    up -d --build --force-recreate --remove-orphans app db redis nginx prometheus grafana]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker compose down" category="Docker-ComplexModify">
      <description>docker compose down with volume removal, timeout, and profile specification</description>
      <copilot-command><![CDATA[docker compose \
    -f docker-compose.yml \
    -f docker-compose.prod.yml \
    --profile production \
    down -v --remove-orphans --timeout 30]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker stack deploy" category="Docker-ComplexModify">
      <description>Docker Swarm stack deploy with compose file and pruning</description>
      <copilot-command><![CDATA[docker stack deploy \
    --compose-file docker-compose.swarm.yml \
    --compose-file docker-compose.swarm-secrets.yml \
    --prune \
    --with-registry-auth \
    --resolve-image always \
    my-production-stack]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker system prune" category="Docker-ComplexModify">
      <description>docker system prune with filters targeting specific age and label conditions</description>
      <copilot-command><![CDATA[docker system prune -a -f \
    --filter "until=168h" \
    --filter "label!=persist=true" \
    --filter "label!=environment=production" \
    --volumes]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker container prune" category="Docker-ComplexModify">
      <description>docker container prune with complex label and status filters</description>
      <copilot-command><![CDATA[docker container prune -f \
    --filter "label=auto-cleanup=true" \
    --filter "status=exited" \
    --filter "label!=environment=production"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker save" category="Docker-ComplexModify">
      <description>docker save piped to gzip with multi-image bundle</description>
      <copilot-command><![CDATA[docker save myapp:2.4.1 myapp:2.4.0 myapp:latest | gzip > myapp-images-2.4.1.tar.gz]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker load" category="Docker-ComplexModify">
      <description>docker load from compressed image archive with decompression</description>
      <copilot-command><![CDATA[gunzip -c myapp-images-2.4.1.tar.gz | docker load]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Docker-ComplexRead">
      <description>docker inspect with complex go-template extracting multi-level nested data</description>
      <copilot-command><![CDATA[docker inspect --format '
{{range .NetworkSettings.Networks}}
Network: {{.NetworkID}}
  IP: {{.IPAddress}} GW: {{.Gateway}} MAC: {{.MacAddress}}
{{end}}
{{range .Mounts}}
Mount: {{.Source}} -> {{.Destination}} ({{.Type}}:{{if .RW}}rw{{else}}ro{{end}})
{{end}}' $(docker ps -q)]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Docker-ComplexRead">
      <description>docker stats with complex formatting extracting specific metrics from all running containers</description>
      <copilot-command><![CDATA[docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}" $(docker ps -q)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker rmi" category="Docker-ComplexModify">
      <description>docker rmi with tag filter and forced removal of multiple images</description>
      <copilot-command><![CDATA[docker rmi -f $(docker images --filter "dangling=true" --filter "before=myapp:2.3.0" -q)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="docker volume rm" category="Docker-ComplexModify">
      <description>docker volume rm with dynamic query for unused volumes matching label</description>
      <copilot-command><![CDATA[docker volume rm $(docker volume ls --filter "label=auto-cleanup=true" --filter "dangling=true" -q)]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="Docker"/,/<\/category-group>/' test-cases.xml | grep -c 'Docker-Complex'
```
Expected: 14

---

### Task 14: Add new complex Kubernetes test cases (14+ entries)

**Files:**
- Modify: `test-cases.xml` — append into `Kubernetes` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of Kubernetes**

- [ ] **Step 2: Append the following complex Kubernetes test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="kubectl exec" category="Kubernetes-ComplexModify">
      <description>kubectl exec with nested shell pipeline running commands inside pod</description>
      <copilot-command><![CDATA[kubectl exec -it my-pod-7d4f8b9c-abcde -n production -- sh -c "
    cd /opt/app/data && \
    for f in *.json; do
        count=\$(jq '.records | length' \"\$f\")
        echo \"\$f: \$count records, \$(du -h \"\$f\" | cut -f1)\"
    done
"]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl patch" category="Kubernetes-ComplexModify">
      <description>kubectl patch with strategic merge patch containing multi-level nested configuration</description>
      <copilot-command><![CDATA[kubectl patch deployment my-app -n production --type='strategic' -p '
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "app",
            "resources": {
              "requests": { "cpu": "500m", "memory": "512Mi" },
              "limits": { "cpu": "2000m", "memory": "2Gi" }
            },
            "env": [
              { "name": "LOG_LEVEL", "value": "debug" },
              { "name": "FEATURE_FLAGS", "value": "enable-v2-api,enable-cache" },
              { "name": "DB_POOL_SIZE", "value": "25" }
            ],
            "livenessProbe": {
              "httpGet": { "path": "/healthz", "port": 8080 },
              "initialDelaySeconds": 30,
              "periodSeconds": 10,
              "timeoutSeconds": 5,
              "failureThreshold": 5
            }
          }
        ]
      }
    }
  }
}' ]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl patch" category="Kubernetes-ComplexModify">
      <description>kubectl patch with JSON patch format making multiple atomic changes</description>
      <copilot-command><![CDATA[kubectl patch service my-service -n staging --type='json' -p='[
  {"op": "replace", "path": "/spec/selector/version", "value": "v2.4.1"},
  {"op": "add", "path": "/spec/ports/-", "value": {"name": "metrics", "port": 9090, "protocol": "TCP"}},
  {"op": "remove", "path": "/metadata/annotations/deprecated"},
  {"op": "add", "path": "/metadata/annotations/last-patched", "value": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}
]' ]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl apply" category="Kubernetes-ComplexModify">
      <description>kubectl apply with kustomize overlays and prune</description>
      <copilot-command><![CDATA[kubectl apply -k ./overlays/production/ \
    --prune \
    --all \
    --prune-whitelist=apps/v1/Deployment \
    --prune-whitelist=/v1/Service \
    --prune-whitelist=networking.k8s.io/v1/Ingress \
    --prune-whitelist=/v1/ConfigMap \
    -n production]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl delete" category="Kubernetes-ComplexModify">
      <description>kubectl delete with label selector, force, and grace period for multiple resource types</description>
      <copilot-command><![CDATA[kubectl delete deployments,services,configmaps,ingress \
    -l app=old-api,version!=v2 \
    -n production \
    --force --grace-period=0 \
    --wait=true]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl drain" category="Kubernetes-ComplexModify">
      <description>kubectl drain with force, ignore-daemonsets, delete-emptydir-data, and timeout</description>
      <copilot-command><![CDATA[kubectl drain node-04 \
    --force \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=120 \
    --timeout=300s \
    --pod-selector='app notin (critical-infra,monitoring)' ]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl rollout restart" category="Kubernetes-ComplexModify">
      <description>kubectl rollout restart with status watching across multiple deployments</description>
      <copilot-command><![CDATA[kubectl rollout restart deployment/api-gateway deployment/user-service deployment/order-service -n production && \
kubectl rollout status deployment/api-gateway -n production --timeout=120s && \
kubectl rollout status deployment/user-service -n production --timeout=120s && \
kubectl rollout status deployment/order-service -n production --timeout=120s]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Kubernetes-ComplexRead">
      <description>kubectl get with jsonpath extracting nested data across multiple resources</description>
      <copilot-command><![CDATA[kubectl get pods -n production -l app=my-api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[0].resources.requests.cpu}{"\t"}{.spec.containers[0].resources.requests.memory}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' ]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Kubernetes-ComplexRead">
      <description>kubectl get with go-template producing structured output from multiple API objects</description>
      <copilot-command><![CDATA[kubectl get nodes -o go-template='
{{range .items}}
Node: {{.metadata.name}}
  Arch:   {{.status.nodeInfo.architecture}}
  Kernel: {{.status.nodeInfo.kernelVersion}}
  Kubelet:{{.status.nodeInfo.kubeletVersion}}
  Pods:   {{.status.allocatable.pods}}
  CPU:    {{.status.allocatable.cpu}}
  Memory: {{.status.allocatable.memory}}
  Conditions:
  {{range .status.conditions}}
    {{.type}}: {{.status}} ({{.reason}})
  {{end}}
{{end}}' ]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl scale" category="Kubernetes-ComplexModify">
      <description>kubectl scale with conditional logic wrapper in bash for HPA management</description>
      <copilot-command><![CDATA[kubectl scale deployment api-gateway -n production --replicas=6 && \
kubectl scale deployment user-service -n production --replicas=4 && \
kubectl scale deployment order-service -n production --replicas=4 && \
kubectl scale deployment notification-worker -n production --replicas=2]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="Kubernetes-ComplexRead">
      <description>kubectl auth can-i with list flag querying permissions across multiple verbs</description>
      <copilot-command><![CDATA[kubectl auth can-i --list \
    --as=system:serviceaccount:production:deploy-bot \
    -n production 2>/dev/null | \
    awk 'NR>1 {print $2, $1, $6}' | sort | column -t]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl taint" category="Kubernetes-ComplexModify">
      <description>kubectl taint nodes with effect and condition</description>
      <copilot-command><![CDATA[kubectl taint nodes node-03 node-04 node-05 \
    dedicated=high-memory:NoSchedule \
    --overwrite]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl port-forward" category="Kubernetes-ComplexModify">
      <description>kubectl port-forward with multiple ports to deployment and backgrounding</description>
      <copilot-command><![CDATA[kubectl port-forward deployment/my-app -n staging 8080:8080 9090:9090 5005:5005 \
    --address=0.0.0.0 &]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="kubectl create" category="Kubernetes-ComplexModify">
      <description>kubectl create secret with multi-key from-file and from-literal combinations</description>
      <copilot-command><![CDATA[kubectl create secret generic app-secrets -n production \
    --from-literal=DB_PASSWORD='P@ssw0rd!2024' \
    --from-literal=API_KEY='sk-abc123def456' \
    --from-literal=REDIS_PASSWORD='redis-secret' \
    --from-file=tls.crt=./certs/prod.crt \
    --from-file=tls.key=./certs/prod.key \
    --from-file=ca.crt=./certs/ca-bundle.crt]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="Kubernetes"/,/<\/category-group>/' test-cases.xml | grep -c 'Kubernetes-Complex'
```
Expected: 14

---

### Task 15: Add new complex AWS CLI test cases (12+ entries)

**Files:**
- Modify: `test-cases.xml` — append into `AWS_CLI` category group before `</category-group>`

- [ ] **Step 1: Insert `<!-- COMPLEX COMMANDS -->` separator before the closing `</category-group>` of AWS_CLI**

- [ ] **Step 2: Append the following complex AWS CLI test cases**

```xml
    <!-- COMPLEX COMMANDS -->

    <test-case expected="ask" reason="aws ec2 run-instances" category="AWS-ComplexModify">
      <description>aws ec2 run-instances with complex user-data, tag-specifications, and multi-network interface</description>
      <copilot-command><![CDATA[aws ec2 run-instances \
    --image-id ami-0abcdef1234567890 \
    --instance-type t3.large \
    --key-name prod-key-pair \
    --security-group-ids sg-12345 sg-67890 \
    --subnet-id subnet-abc123 \
    --user-data file://user-data.sh \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Iops":3000,"DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":500,"VolumeType":"st1","DeleteOnTermination":false}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=prod-app-server-04},{Key=Environment,Value=production},{Key=Team,Value=platform},{Key=CostCenter,Value=CC-1234}]' \
    --iam-instance-profile Name=app-server-role \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --count 1]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws s3 sync" category="AWS-ComplexModify">
      <description>aws s3 sync with complex include/exclude filter chains and storage class</description>
      <copilot-command><![CDATA[aws s3 sync /data/exports/ s3://company-data-bucket/exports/ \
    --storage-class STANDARD_IA \
    --exclude "*.tmp" \
    --exclude "*.lock" \
    --include "*.csv" \
    --include "*.json" \
    --include "*.parquet" \
    --exclude "test-*" \
    --exclude "*draft*" \
    --exclude "temp/*" \
    --delete \
    --metadata "Source=DataPipeline,Retention=90d" \
    --no-follow-symlinks]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws s3 cp" category="AWS-ComplexModify">
      <description>aws s3 cp with recursive, ACL, and complex exclusion filters</description>
      <copilot-command><![CDATA[aws s3 cp s3://source-bucket/logs/2026/05/ /local/logs/ \
    --recursive \
    --exclude "*" \
    --include "app-server-*access*.log" \
    --include "error-report-*.log" \
    --acl bucket-owner-full-control]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws s3 rm" category="AWS-ComplexModify">
      <description>aws s3 rm with recursive, complex exclude/include, and dry-run verification</description>
      <copilot-command><![CDATA[aws s3 rm s3://logs-bucket/archived/ \
    --recursive \
    --exclude "*" \
    --include "*.log.gz" \
    --include "*.log.bz2" \
    --exclude "2026*" \
    --dryrun]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws cloudformation create-change-set" category="AWS-ComplexModify">
      <description>aws cloudformation create-change-set with nested stack parameters and capabilities</description>
      <copilot-command><![CDATA[aws cloudformation create-change-set \
    --stack-name prod-app-stack \
    --change-set-name update-v2.4.1 \
    --template-body file://cfn-template.yaml \
    --parameters \
        ParameterKey=Environment,ParameterValue=production \
        ParameterKey=InstanceType,ParameterValue=t3.large \
        ParameterKey=MinSize,ParameterValue=3 \
        ParameterKey=MaxSize,ParameterValue=12 \
        ParameterKey=DesiredCapacity,ParameterValue=5 \
        ParameterKey=DBPassword,ParameterValue='CHANGEME!2024' \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --tags Key=Version,Value=2.4.1 Key=Approver,Value=platform-team \
    --notification-arns arn:aws:sns:us-east-1:123456789012:cfn-notifications]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws rds modify-db-instance" category="AWS-ComplexModify">
      <description>aws rds modify-db-instance with multi-option modification, monitoring, and backup settings</description>
      <copilot-command><![CDATA[aws rds modify-db-instance \
    --db-instance-identifier prod-db-01 \
    --db-instance-class db.r6g.xlarge \
    --allocated-storage 500 \
    --storage-type gp3 \
    --iops 12000 \
    --backup-retention-period 14 \
    --preferred-backup-window "03:00-04:00" \
    --preferred-maintenance-window "sun:05:00-sun:06:00" \
    --monitoring-interval 60 \
    --monitoring-role-arn arn:aws:iam::123456789012:role/rds-monitoring \
    --enable-performance-insights \
    --performance-insights-retention-period 7 \
    --deletion-protection \
    --enable-cloudwatch-logs-exports '["postgresql","upgrade"]' \
    --apply-immediately]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws iam create-policy" category="AWS-ComplexModify">
      <description>aws iam create-policy with complex multi-statement inline JSON policy document</description>
      <copilot-command><![CDATA[aws iam create-policy \
    --policy-name AppDeployerPolicy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
                "Resource": ["arn:aws:s3:::deploy-artifacts-*", "arn:aws:s3:::deploy-artifacts-*/*"],
                "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
            },
            {
                "Effect": "Allow",
                "Action": ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"],
                "Resource": "*"
            },
            {
                "Effect": "Allow",
                "Action": ["ecs:UpdateService", "ecs:DescribeServices", "ecs:DescribeTaskDefinition"],
                "Resource": "arn:aws:ecs:us-east-1:123456789012:service/prod-cluster/*"
            }
        ]
    }' \
    --tags Key=ManagedBy,Value=Terraform Key=Environment,Value=production]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="AWS-ComplexRead">
      <description>aws ec2 describe-instances with complex JMESPath query filtering and multi-level projection</description>
      <copilot-command><![CDATA[aws ec2 describe-instances \
    --filters "Name=tag:Environment,Values=production" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[
        InstanceId,
        InstanceType,
        Tags[?Key==`Name`].Value | [0],
        Placement.AvailabilityZone,
        State.Name,
        PrivateIpAddress,
        PublicIpAddress,
        VpcId,
        LaunchTime
    ]' \
    --output table]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws sts assume-role" category="AWS-ComplexModify">
      <description>aws sts assume-role with session token chaining for cross-account access</description>
      <copilot-command><![CDATA[aws sts assume-role \
    --role-arn arn:aws:iam::123456789012:role/CrossAccountAdmin \
    --role-session-name "deploy-session-$(date +%s)" \
    --duration-seconds 3600 \
    --external-id "deploy-pipeline-abc123" \
    --output json > /tmp/assume-role-output.json && \
export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' /tmp/assume-role-output.json) && \
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' /tmp/assume-role-output.json) && \
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' /tmp/assume-role-output.json)]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws lambda invoke" category="AWS-ComplexModify">
      <description>aws lambda invoke with payload file and output to file for processing</description>
      <copilot-command><![CDATA[aws lambda invoke \
    --function-name process-batch-data \
    --invocation-type RequestResponse \
    --payload '{"batchId":"batch-2026-05-15-001","source":"s3://data-bucket/incoming/","format":"parquet","transformations":["normalize","deduplicate","enrich"]}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda-response.json]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="AWS-ComplexRead">
      <description>aws cloudwatch get-metric-data with complex metric math expressions and multiple queries</description>
      <copilot-command><![CDATA[aws cloudwatch get-metric-data \
    --metric-data-queries '[
        {"Id": "cpu", "MetricStat": {"Metric": {"Namespace": "AWS/EC2", "MetricName": "CPUUtilization", "Dimensions": [{"Name":"InstanceId","Value":"i-12345"}]}, "Period": 300, "Stat": "Average"}},
        {"Id": "mem", "MetricStat": {"Metric": {"Namespace": "CWAgent", "MetricName": "mem_used_percent", "Dimensions": [{"Name":"InstanceId","Value":"i-12345"}]}, "Period": 300, "Stat": "Average"}},
        {"Id": "health_score", "Expression": "100 - (cpu/100 * 0.4 + FILL(mem, 0)/100 * 0.6) * 100", "Label": "HealthScore"}
    ]' \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --output table]]></copilot-command>
    </test-case>

    <test-case expected="allow" reason="read-only" category="AWS-ComplexRead">
      <description>aws organizations list-accounts with pagination and complex JMESPath filter</description>
      <copilot-command><![CDATA[aws organizations list-accounts \
    --query 'Accounts[?Status==`ACTIVE` && contains(Email, `@company.com`)].[Id,Name,Email,JoinedTimestamp]' \
    --output table \
    --max-items 100]]></copilot-command>
    </test-case>

    <test-case expected="ask" reason="aws ec2 terminate-instances" category="AWS-ComplexModify">
      <description>aws ec2 terminate-instances across multiple instance IDs in one command</description>
      <copilot-command><![CDATA[aws ec2 terminate-instances \
    --instance-ids i-0abc123def456 i-0def789abc012 i-0123abcd4567ef8 \
    --output json | jq '.TerminatingInstances[] | {InstanceId, CurrentState: .CurrentState.Name, PreviousState: .PreviousState.Name}' ]]></copilot-command>
    </test-case>
```

- [ ] **Step 3: Validate count**

```bash
awk '/category-group name="AWS_CLI"/,/<\/category-group>/' test-cases.xml | grep -c 'AWS-Complex'
```
Expected: 13

---

### Task 16: Generate commands.json runtime config

**Files:**
- Create: `commands.json`

- [ ] **Step 1: Generate commands.json using commands.sample.json as the template**

Use the already-created `commands.sample.json` file as the template. Produce the final `commands.json` by:

1. Copy the structure from `commands.sample.json` (version, dry_run_flags, risk_legend, commands with 7 domain objects)
2. For each domain, populate `read_only` and `modifying` arrays with ALL entries from both the existing `test-cases.xml` entries and the new complex entries added in Tasks 9-15
3. Each JSON entry includes: `name`, `patterns` (glob-style, e.g., `"terraform *apply*"` for flag-separated), `description`, and `risk` (low/medium/high, modifying only)
4. PowerShell section: keep `read_only_verbs` and `modifying_verbs` arrays for verb-based classification
5. AWS CLI section: keep `read_only_prefixes` (`describe-*`, `list-*`, `get-*`) and `modifying_prefixes` (`delete-*`, `create-*`, `update-*`, etc.) for verb-based classification. Add explicit entries for non-standard verbs: `s3 ls`, `s3 cp`, `s3 sync`, `s3 rm`, `s3 mv`, `ec2 run-instances`, `ec2 reboot-instances`, `<service> wait`, `configure`
6. Remove `commands.sample.json` after generating `commands.json`

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -c "import json; json.load(open('commands.json')); print('Valid JSON')"
```
Expected: `Valid JSON`

- [ ] **Step 3: Verify JSON reflects the same classification as test-cases.xml**

Spot-check at least 10 read-only entries and 10 modifying entries across all 7 domains to ensure `commands.json` correctly classifies the same commands.

---

### Task 17: Global validation and final audit

**Files:**
- Validate: `test-cases.xml`, `commands.json`

- [ ] **Step 1: Count new complex test cases per domain**

```bash
for domain in DOS_CMD PowerShell Linux Terraform Docker Kubernetes AWS_CLI; do
    echo -n "$domain complex: "
    awk '/category-group name="'$domain'"/,/<\/category-group>/' test-cases.xml | grep -c "$domain-Complex"
done
```
Expected: DOS_CMD 12, PowerShell 18, Linux 18, Terraform 14, Docker 14, Kubernetes 14, AWS_CLI 13

- [ ] **Step 2: Count total new complex test cases**

```bash
grep -c '<test-case expected.*category=".*-Complex"' test-cases.xml
```
Expected: 103

- [ ] **Step 3: Verify EVERY test-case has a reason attribute**

```bash
total=$(grep -c '<test-case' test-cases.xml)
with_reason=$(grep -c '<test-case.*reason=' test-cases.xml)
echo "Total: $total, With reason: $with_reason"
```
Expected: Both numbers must be equal.

- [ ] **Step 4: Verify no reason="read-only" on ask entries**

```bash
grep -c 'expected="ask".*reason="read-only"' test-cases.xml
```
Expected: 0

- [ ] **Step 5: Verify no empty or missing reason values**

```bash
grep -c 'reason=""' test-cases.xml
```
Expected: 0

- [ ] **Step 6: Validate XML structure**

```bash
xmllint --noout test-cases.xml 2>&1
```
Expected: No errors.

- [ ] **Step 7: Full count summary**

```bash
echo "=== Allow entries ==="
grep -c 'expected="allow"' test-cases.xml
echo "=== Ask entries ==="
grep -c 'expected="ask"' test-cases.xml
echo "=== Total test cases ==="
grep -c '<test-case' test-cases.xml
```
Expected: Allow > 125, Ask > 200, Total > 330

---

### Task 18: Commit

**Files:**
- Modified: `test-cases.xml`
- Created: `commands.json`
- Created: `docs/superpowers/specs/2026-05-15-complex-command-test-cases-design.md`
- Created: `docs/superpowers/plans/2026-05-15-complex-command-test-cases.md`

- [ ] **Step 1: Stage and commit all changes**

```bash
git add test-cases.xml commands.json docs/superpowers/
git commit -m "$(cat <<'EOF'
feat: add 100+ complex command test cases and reason attribute, generate commands.json

- Retrofit reason attribute on all 228 existing test cases across 7 domains
- Add 103 new complex test cases with heavy PowerShell remoting and SSH remoting coverage
- Add commands.json runtime config for hook script classification
- Design spec and implementation plan in docs/superpowers/

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Verify commit**

```bash
git log --oneline -1
git diff --stat HEAD~1..HEAD
```
