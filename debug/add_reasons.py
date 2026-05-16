#!/usr/bin/env python3
"""
Retrofit reason attributes to all existing test-case elements in test-cases.xml.
"""
import re

XML_PATH = r"C:\git\cc\pretoolhook\test\test-cases.xml"

with open(XML_PATH, "r", encoding="utf-8") as f:
    content = f.read()

def extract_command_text(test_case_block):
    """Extract the actual command text from a test case CDATA block."""
    m = re.search(r'<copilot-command>\s*<!\[CDATA\[(.*?)\]\]>\s*</copilot-command>', test_case_block, re.DOTALL)
    if m:
        return m.group(1).strip()
    return ""

def extract_description(test_case_block):
    """Extract description text from a test case."""
    m = re.search(r'<description>(.*?)</description>', test_case_block, re.DOTALL)
    if m:
        return m.group(1).strip()
    return ""

def get_reason(expected, command_text, description, category):
    """Determine reason attribute for a test case."""
    cl = command_text.lower()
    dl = description.lower()

    if expected == "allow":
        # Specific read-only reasons
        if re.search(r'\bGet-ChildItem\b', command_text, re.IGNORECASE):
            return "read-only: Get-ChildItem"
        if re.search(r'\bGet-Content\b', command_text, re.IGNORECASE):
            return "read-only: Get-Content"
        if re.search(r'\bSelect-String\b', command_text, re.IGNORECASE):
            return "read-only: Select-String"
        if re.search(r'\bTest-Path\b', command_text, re.IGNORECASE):
            return "read-only: Test-Path"
        if re.search(r'\bTest-Connection\b', command_text, re.IGNORECASE):
            return "read-only: Test-Connection"
        if re.search(r'\bGet-Process\b', command_text, re.IGNORECASE):
            return "read-only: Get-Process"
        if re.search(r'\bGet-Service\b', command_text, re.IGNORECASE):
            return "read-only: Get-Service"
        if re.search(r'\bGet-EventLog\b', command_text, re.IGNORECASE):
            return "read-only: Get-EventLog"
        if re.search(r'\bGet-WinEvent\b', command_text, re.IGNORECASE):
            return "read-only: Get-WinEvent"
        if re.search(r'\bGet-CimInstance\b', command_text, re.IGNORECASE):
            return "read-only: Get-CimInstance"
        if re.search(r'\bGet-WmiObject\b', command_text, re.IGNORECASE):
            return "read-only: Get-WmiObject"
        if re.search(r'\bGet-NetAdapter\b', command_text, re.IGNORECASE):
            return "read-only: Get-NetAdapter"
        if re.search(r'\bGet-NetIPAddress\b', command_text, re.IGNORECASE):
            return "read-only: Get-NetIPAddress"
        if re.search(r'\bGet-NetTCPConnection\b', command_text, re.IGNORECASE):
            return "read-only: Get-NetTCPConnection"
        if re.search(r'\bSelect-Object\b', command_text, re.IGNORECASE):
            return "read-only: Select-Object"
        if re.search(r'\bWhere-Object\b', command_text, re.IGNORECASE):
            return "read-only: Where-Object"
        if re.search(r'\bSort-Object\b', command_text, re.IGNORECASE):
            return "read-only: Sort-Object"
        if re.search(r'\bMeasure-Object\b', command_text, re.IGNORECASE):
            return "read-only: Measure-Object"
        if re.search(r'\bWrite-Host\b', command_text, re.IGNORECASE):
            return "read-only: Write-Host"
        if re.search(r'\bWrite-Warning\b', command_text, re.IGNORECASE):
            return "read-only: Write-Warning"
        if re.search(r'\bInvoke-Command\b', command_text, re.IGNORECASE):
            return "read-only: Invoke-Command with read-only ScriptBlock"
        if re.search(r'\bGet-ItemProperty\b', command_text, re.IGNORECASE):
            return "read-only: Get-ItemProperty"
        if re.search(r'\bFormat-Table\b', command_text, re.IGNORECASE):
            return "read-only: Format-Table"
        if re.search(r'\bFormat-List\b', command_text, re.IGNORECASE):
            return "read-only: Format-List"

        # Docker read-only
        if re.search(r'\bdocker ps\b', cl):
            return "read-only: docker ps"
        if re.search(r'\bdocker images\b', cl):
            return "read-only: docker images"
        if re.search(r'\bdocker logs\b', cl):
            return "read-only: docker logs"
        if re.search(r'\bdocker inspect\b', cl):
            return "read-only: docker inspect"
        if re.search(r'\bdocker stats\b', cl):
            return "read-only: docker stats"
        if re.search(r'\bdocker network ls\b', cl):
            return "read-only: docker network ls"
        if re.search(r'\bdocker volume ls\b', cl):
            return "read-only: docker volume ls"
        if re.search(r'\bdocker compose config\b', cl):
            return "read-only: docker compose config"

        # Kubernetes read-only
        if re.search(r'\bkubectl get\b', cl):
            return "read-only: kubectl get"
        if re.search(r'\bkubectl describe\b', cl):
            return "read-only: kubectl describe"
        if re.search(r'\bkubectl logs\b', cl):
            return "read-only: kubectl logs"
        if re.search(r'\bkubectl top\b', cl):
            return "read-only: kubectl top"
        if re.search(r'\bkubectl config view\b', cl):
            return "read-only: kubectl config view"

        # Terraform read-only
        if re.search(r'\bterraform plan\b', cl):
            return "read-only: terraform plan"
        if re.search(r'\bterraform show\b', cl):
            return "read-only: terraform show"
        if re.search(r'\bterraform state list\b', cl):
            return "read-only: terraform state list"
        if re.search(r'\bterraform output\b', cl):
            return "read-only: terraform output"
        if re.search(r'\bterraform fmt -check\b', cl):
            return "read-only: terraform fmt -check"
        if re.search(r'\bterraform validate\b', cl):
            return "read-only: terraform validate"

        # AWS read-only
        if re.search(r'\baws s3 ls\b', cl):
            return "read-only: aws s3 ls"
        if re.search(r'\baws ec2 describe-\b', cl):
            return "read-only: aws ec2 describe-"
        if re.search(r'\baws lambda list-\b', cl):
            return "read-only: aws lambda list-"
        if re.search(r'\baws cloudwatch get-\b', cl):
            return "read-only: aws cloudwatch get-"
        if re.search(r'\baws iam list-\b', cl):
            return "read-only: aws iam list-"
        if re.search(r'\baws rds describe-\b', cl):
            return "read-only: aws rds describe-"

        # DOS read-only
        if re.search(r'\bdir\b', cl) and "DOS" in category:
            return "read-only: dir"
        if re.search(r'\btype\b', cl) and "DOS" in category:
            return "read-only: type"
        if re.search(r'\btree\b', cl):
            return "read-only: tree"
        if re.search(r'\bfindstr\b', cl):
            return "read-only: findstr"
        if re.search(r'\bwhere\b', cl) and "DOS" in category:
            return "read-only: where"
        if re.search(r'\bwmic\b', cl):
            return "read-only: wmic"
        if re.search(r'\bipconfig\b', cl):
            return "read-only: ipconfig"
        if re.search(r'\bnetstat\b', cl):
            return "read-only: netstat"
        if re.search(r'\bnbtstat\b', cl):
            return "read-only: nbtstat"
        if re.search(r'\bping\b', cl):
            return "read-only: ping"
        if re.search(r'\btracert\b', cl):
            return "read-only: tracert"
        if re.search(r'\bpathping\b', cl):
            return "read-only: pathping"
        if re.search(r'\bnslookup\b', cl):
            return "read-only: nslookup"
        if re.search(r'\bsysteminfo\b', cl):
            return "read-only: systeminfo"
        if re.search(r'\bver\b', cl):
            return "read-only: ver"
        if re.search(r'\bhostname\b', cl):
            return "read-only: hostname"
        if re.search(r'\btasklist\b', cl):
            return "read-only: tasklist"
        if re.search(r'\bsc query\b', cl):
            return "read-only: sc query"
        if re.search(r'\bwhoami\b', cl):
            return "read-only: whoami"
        if re.search(r'\bwevtutil\b', cl):
            return "read-only: wevtutil"
        if re.search(r'\bnet view\b', cl):
            return "read-only: net view"
        if re.search(r'\barp\b', cl):
            return "read-only: arp"
        if re.search(r'\bdriverquery\b', cl):
            return "read-only: driverquery"

        # Linux read-only
        if re.search(r'\bls\b', cl) and "Linux" in category:
            if "Linux-Chained" in category:
                return "read-only: chained read-only"
            return "read-only: ls"
        if re.search(r'\bcat\b', cl) and "Linux" in category:
            return "read-only: cat"
        if re.search(r'\bhead\b', cl):
            return "read-only: head"
        if re.search(r'\btail\b', cl):
            return "read-only: tail"
        if re.search(r'\bless\b', cl):
            return "read-only: less"
        if re.search(r'\bfind\b', cl) and "/" in command_text:
            return "read-only: find"
        if re.search(r'\blocate\b', cl):
            return "read-only: locate"
        if re.search(r'\bstat\b', cl):
            return "read-only: stat"
        if re.search(r'\bwc\b', cl):
            return "read-only: wc"
        if re.search(r'\bfile\b', cl):
            return "read-only: file"
        if re.search(r'\bdf\b', cl):
            return "read-only: df"
        if re.search(r'\bfree\b', cl):
            return "read-only: free"
        if re.search(r'\buptime\b', cl):
            return "read-only: uptime"
        if re.search(r'\buname\b', cl):
            return "read-only: uname"
        if re.search(r'\bid\b', cl):
            return "read-only: id"
        if re.search(r'\bps\b', cl) and "aux" in cl:
            return "read-only: ps"
        if re.search(r'\btop\b', cl):
            return "read-only: top"
        if re.search(r'\bpgrep\b', cl):
            return "read-only: pgrep"
        if re.search(r'\bss\b', cl) and "-tl" in cl:
            return "read-only: ss"
        if re.search(r'\bip addr\b', cl):
            return "read-only: ip addr"
        if re.search(r'\bcurl -s\b', cl):
            return "read-only: curl GET"
        if re.search(r'\bwget -qo-\b', cl):
            return "read-only: wget to stdout"
        if re.search(r'\bdig\b', cl):
            return "read-only: dig"
        if re.search(r'\bgrep\b', cl):
            return "read-only: grep"
        if re.search(r'\bawk\b', cl):
            return "read-only: awk"
        if re.search(r'\bsed\b', cl) and "-i" not in cl:
            return "read-only: sed (stream)"
        if re.search(r'\bsort\b', cl):
            return "read-only: sort/uniq"
        if re.search(r'\becho\b', cl):
            return "read-only: echo"
        if re.search(r'\bgit\b', cl):
            return "read-only: git"

        # Complex multi-line read-only
        if "ComplexRead" in category:
            return "read-only: complex inspection pipeline"
        if "for " in cl and "do" in cl and "echo" in cl:
            return "read-only: for loop inspection"
        if "while" in cl and "read" in cl:
            return "read-only: while read loop"
        if "case " in cl and "esac" in cl:
            return "read-only: case statement"
        if "if " in cl and "fi" in cl:
            return "read-only: conditional check"

        return "read-only"

    elif expected == "ask":
        # DOS modifying
        if "del " in cl:
            return "modifying: del"
        if "copy " in cl:
            return "modifying: copy"
        if "xcopy " in cl:
            return "modifying: xcopy"
        if "robocopy " in cl:
            return "modifying: robocopy"
        if "move " in cl:
            return "modifying: move"
        if "ren " in cl:
            return "modifying: ren"
        if "mkdir " in cl:
            return "modifying: mkdir"
        if "rmdir " in cl:
            return "modifying: rmdir"
        if "mklink " in cl:
            return "modifying: mklink"
        if "taskkill " in cl:
            return "modifying: taskkill"
        if "tskill " in cl:
            return "modifying: tskill"
        if "setx " in cl:
            return "modifying: setx"
        if "set path" in cl:
            return "modifying: set PATH"
        if "shutdown " in cl:
            return "modifying: shutdown"
        if "net stop " in cl:
            return "modifying: net stop"
        if "net start " in cl:
            return "modifying: net start"
        if "sc config " in cl:
            return "modifying: sc config"
        if "sc delete " in cl:
            return "modifying: sc delete"
        if "net user " in cl:
            return "modifying: net user"
        if "net localgroup " in cl:
            return "modifying: net localgroup"
        if "reg add " in cl:
            return "modifying: reg add"
        if "reg delete " in cl:
            return "modifying: reg delete"
        if "netsh " in cl:
            return "modifying: netsh advfirewall"
        if "format " in cl:
            return "modifying: format"
        if "icacls " in cl:
            return "modifying: icacls"
        if "cipher " in cl:
            return "modifying: cipher"
        if "dism " in cl:
            return "modifying: dism"

        # PowerShell modifying
        if "New-Item" in command_text:
            if "HKLM" in command_text:
                return "modifying: New-Item (registry)"
            return "modifying: New-Item"
        if "Set-Content" in command_text:
            return "modifying: Set-Content"
        if "Add-Content" in command_text:
            return "modifying: Add-Content"
        if "Remove-Item" in command_text:
            if "HKLM" in command_text:
                return "modifying: Remove-Item (registry)"
            return "modifying: Remove-Item"
        if "Copy-Item" in command_text:
            return "modifying: Copy-Item"
        if "Move-Item" in command_text:
            return "modifying: Move-Item"
        if "Rename-Item" in command_text:
            return "modifying: Rename-Item"
        if "Compress-Archive" in command_text:
            return "modifying: Compress-Archive"
        if "Stop-Service" in command_text:
            return "modifying: Stop-Service"
        if "Start-Service" in command_text:
            return "modifying: Start-Service"
        if "Restart-Service" in command_text:
            return "modifying: Restart-Service"
        if "Set-Service" in command_text:
            return "modifying: Set-Service"
        if "New-ItemProperty" in command_text:
            return "modifying: New-ItemProperty"
        if "Stop-Process" in command_text:
            return "modifying: Stop-Process"
        if "Start-Process" in command_text:
            return "modifying: Start-Process"
        if "New-NetFirewallRule" in command_text:
            return "modifying: New-NetFirewallRule"
        if "Remove-NetFirewallRule" in command_text:
            return "modifying: Remove-NetFirewallRule"
        if "Set-DnsClientNrptRule" in command_text:
            return "modifying: Set-DnsClientNrptRule"
        if "Add-LocalGroupMember" in command_text:
            return "modifying: Add-LocalGroupMember"
        if "New-LocalUser" in command_text:
            return "modifying: New-LocalUser"
        if "Restart-Computer" in command_text:
            return "modifying: Restart-Computer"
        if "Shutdown-Computer" in command_text:
            return "modifying: Shutdown-Computer"

        # PS Complex modifying
        if "ComplexModifying" in category:
            if "Invoke-Command" in command_text and "Start-Process" in command_text:
                return "modifying: Invoke-Command wrapping Start-Process (msiexec install)"
            if "Copy-Item" in command_text and "Remove-Item" in command_text and "Restart-Service" in command_text:
                return "modifying: Copy-Item, Remove-Item, Restart-Service (deployment)"
            if "Remove-Item" in command_text and ("foreach" in cl or "ForEach-Object" in command_text):
                return "modifying: Remove-Item in loop"
            if "Stop-Service" in command_text and "foreach" in cl:
                return "modifying: Stop-Service in loop"
            if "docker rm" in cl:
                return "modifying: docker rm in PowerShell pipeline"
            return "modifying: complex PowerShell script"

        # Linux modifying
        if "mkdir " in cl:
            return "modifying: mkdir"
        if "touch " in cl:
            return "modifying: touch"
        if "cp " in cl and ("-r " in cl or " -r " in cl):
            return "modifying: cp -r"
        if "cp " in cl:
            return "modifying: cp"
        if "mv " in cl:
            return "modifying: mv"
        if "rm -rf" in cl or "rm -f" in cl:
            return "modifying: rm -f"
        if "sed -i" in cl:
            return "modifying: sed -i"
        if "echo" in cl and (">>" in command_text or ">" in command_text) and "/etc/" in command_text:
            return "modifying: echo redirect to system file"
        if "tee " in cl:
            return "modifying: tee"
        if "systemctl stop" in cl:
            return "modifying: systemctl stop"
        if "systemctl start" in cl:
            return "modifying: systemctl start"
        if "systemctl restart" in cl:
            return "modifying: systemctl restart"
        if "systemctl enable" in cl:
            return "modifying: systemctl enable"
        if "yum install" in cl:
            return "modifying: yum install"
        if "apt-get install" in cl or "apt-get update" in cl:
            return "modifying: apt-get install"
        if "chmod " in cl:
            return "modifying: chmod"
        if "chown " in cl:
            return "modifying: chown"
        if "curl -x post" in cl or "curl -xpost" in cl:
            return "modifying: curl POST"
        if "wget " in cl and ("-O " in command_text or "-o " in cl):
            return "modifying: wget download"
        if "useradd " in cl:
            return "modifying: useradd"
        if "usermod " in cl:
            return "modifying: usermod"
        if "chpasswd" in cl:
            return "modifying: chpasswd"

        # Linux complex modifying
        if "ComplexModifying" in category:
            if "rm -rf" in cl and "cp -r" in cl and "systemctl restart" in cl:
                return "modifying: cp, rm, systemctl restart (deployment)"
            if "rm -f" in cl and "find" in cl:
                return "modifying: find with rm -f"
            if "sed -i" in cl and "systemctl reload" in cl:
                return "modifying: sed -i, systemctl reload"
            if "apt-get install" in cl:
                return "modifying: apt-get install in function"
            return "modifying: complex bash script"

        # Docker modifying
        if "docker stop" in cl:
            return "modifying: docker stop"
        if "docker rm" in cl:
            return "modifying: docker rm"
        if "docker rmi" in cl:
            return "modifying: docker rmi"
        if "docker run" in cl:
            return "modifying: docker run"
        if "docker build" in cl:
            return "modifying: docker build"
        if "docker push" in cl:
            return "modifying: docker push"
        if "docker compose up" in cl:
            return "modifying: docker compose up"
        if "docker compose down" in cl:
            return "modifying: docker compose down"

        # Kubernetes modifying
        if "kubectl delete" in cl:
            return "modifying: kubectl delete"
        if "kubectl apply" in cl:
            return "modifying: kubectl apply"
        if "kubectl scale" in cl:
            return "modifying: kubectl scale"
        if "kubectl set image" in cl:
            return "modifying: kubectl set image"
        if "kubectl rollout undo" in cl:
            return "modifying: kubectl rollout undo"
        if "kubectl exec" in cl:
            return "modifying: kubectl exec"

        # Terraform modifying
        if "terraform apply" in cl:
            return "modifying: terraform apply"
        if "terraform destroy" in cl:
            return "modifying: terraform destroy"
        if "terraform state rm" in cl:
            return "modifying: terraform state rm"
        if "terraform import" in cl:
            return "modifying: terraform import"
        if "terraform fmt" in cl:
            return "modifying: terraform fmt"

        # AWS modifying
        if "aws s3 cp" in cl:
            return "modifying: aws s3 cp"
        if "aws s3 rb" in cl:
            return "modifying: aws s3 rb"
        if "terminate-instances" in cl:
            return "modifying: aws ec2 terminate-instances"
        if "update-function-code" in cl:
            return "modifying: aws lambda update-function-code"
        if "create-user" in cl:
            return "modifying: aws iam create-user"
        if "reboot-instances" in cl:
            return "modifying: aws ec2 reboot-instances"

        return "modifying"

    return "read-only"


# Process the XML - find each test case block and add reason attribute
# Pattern for test case opening tag
tc_pattern = re.compile(
    r'(<test-case expected="(allow|ask)")(\s+category="([^"]*)")?\s*>',
    re.IGNORECASE
)

# Process blocks
def process_block(match):
    """Process each test-case opening tag."""
    full_tag = match.group(0)
    expected = match.group(2)
    category = match.group(4) if match.group(4) else ""

    # We need to find the full test case block to extract command
    # But we can only do that after matching... let's use a different approach
    return full_tag  # placeholder

# Better approach: find all test-case blocks with their full content
block_pattern = re.compile(
    r'<test-case\s+expected="(?P<expected>allow|ask)"\s+category="(?P<category>[^"]*)"\s*>\s*'
    r'<description>(?P<description>.*?)</description>\s*'
    r'<copilot-command><!\[CDATA\[(?P<command>.*?)\]\]></copilot-command>\s*'
    r'</test-case>',
    re.DOTALL
)

def replace_test_case(match):
    expected = match.group("expected")
    category = match.group("category")
    description = match.group("description")
    command = match.group("command")

    reason = get_reason(expected, command, description, category)

    return (
        f'<test-case expected="{expected}" reason="{reason}" category="{category}">\n'
        f'      <description>{description}</description>\n'
        f'      <copilot-command><![CDATA[{command}]]></copilot-command>\n'
        f'    </test-case>'
    )

result = block_pattern.sub(replace_test_case, content)

# Count
old_count = content.count('<test-case expected=')
new_count = result.count('<test-case expected=')
reason_count = result.count(' reason="')

print(f"Old test cases: {old_count}")
print(f"New test cases: {new_count}")
print(f"Reason attributes added: {reason_count}")

# Write back
with open(XML_PATH, "w", encoding="utf-8") as f:
    f.write(result)

print("Done retrofitting reason attributes!")
