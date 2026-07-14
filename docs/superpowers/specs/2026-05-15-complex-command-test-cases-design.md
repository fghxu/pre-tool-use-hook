# Complex Command Test Cases — Design Spec

## 1. Overview

Expand `test-cases.xml` with 100+ complex command test cases across all 7 domains (DOS/CMD, PowerShell, Linux/Bash, Terraform, Docker, Kubernetes, AWS CLI), plus add the `reason` attribute to all existing and new entries.

## 2. Schema Change

Add a `reason` attribute to every `<test-case>` element:

| `expected` value | `reason` value |
|---|---|
| `"allow"` | `"read-only"` |
| `"ask"` | The specific modifying sub-command(s) that triggered the "ask" classification |

Example:
```xml
<test-case expected="ask" reason="rm -rf" category="Linux-FileOps">
  <description>...</description>
  <copilot-command><![CDATA[ls -la && rm -rf /tmp/cache]]></copilot-command>
</test-case>

<test-case expected="allow" reason="read-only" category="Linux-FileInspection">
  <description>...</description>
  <copilot-command><![CDATA[cat /etc/hosts]]></copilot-command>
</test-case>
```

## 3. Complex Command Focus Areas by Domain

### 3.1 DOS / Windows CMD
- Multi-line commands with `^` continuation
- `if`/`else` blocks in batch scripts
- `for` loops (`for /f`, `for /d`, nested loops)
- `setlocal`/`endlocal` with assignment
- Nested `cmd /c` calls
- `reg query` with conditional branching
- Piped chains with `|` and `&&`/`||`
- `wmic` queries with complex WHERE clauses

### 3.2 PowerShell (heavy remoting focus)
- `Invoke-Command` with `-ScriptBlock` and remote sessions
- `Enter-PSSession` / `New-PSSession` patterns
- `foreach`/`if`/`while`/`switch`/`try-catch-finally` blocks
- Multi-level bracket nesting (`$()`, `@()`, `{}`, `[]`)
- DSC (Desired State Configuration) commands
- `-ScriptBlock` parameters on cmdlets
- `Invoke-Expression` with dynamic commands
- Pipeline chaining with `|`, `%`, `?`
- Assignment combined with modifying cmdlets
- PowerShell remoting with `-ComputerName`, `-Session`, `-FilePath`
- `Start-Job` / `Receive-Job` with remote execution

### 3.3 Linux / Bash (heavy SSH remoting focus)
- SSH remoting: `ssh user@host 'command chain'`
- `ssh` with heredocs: `ssh user@host << 'EOF' ... EOF`
- `ssh` with port forwarding + remote execution
- `scp` and `rsync` over SSH
- Nested subshells: `$(...)` inside `$(...)`
- `if`/`case`/`for`/`while`/`until` constructs
- Process substitution: `<()`, `>()`
- Heredocs with embedded command substitution
- `find -exec` with multi-level nesting
- `xargs` with complex transformations
- `sudo` elevation combined with modifying commands
- `tee` for split output (read-only cmd + file write)
- Awk/sed embedded in command chains with `-i` flag

### 3.4 Terraform (flag-separated subcommands)
- `terraform -chdir="..." init/plan/apply/destroy`
- `terraform -chdir="..." apply -auto-approve`
- `terraform -chdir="..." state mv` with target resources
- `terraform workspace` with `-chdir` prefix
- `terraform plan -out=FILE` + `terraform apply FILE`
- `terraform import` with `-var`/`-var-file`
- `terraform state rm` with chained resources
- `terraform output -json` piped to `jq`
- `terraform providers mirror` with filesystem paths

### 3.5 Docker
- Multi-stage builds in a single `docker build` command
- `docker exec` with nested shell commands
- Docker Compose with `extends` / `profiles`
- `docker run` with complex networking + volume mounts + env
- `docker build --build-arg` chains
- `docker stack deploy` with compose files
- `docker container prune` with filter chains
- `docker save`/`docker load` pipelines

### 3.6 Kubernetes
- `kubectl exec -it POD -- /bin/bash -c '...'`
- `kubectl patch` with strategic merge / JSON patch
- Multi-resource `kubectl apply -f` with kustomize overlays
- `kubectl get -o jsonpath`/`go-template` expressions
- `kubectl rollout restart` with status checks
- `kubectl drain` with `--force`/`--ignore-daemonsets`
- `kubectl port-forward` with multi-port chains
- `kubectl auth can-i --list` chained with filtering

### 3.7 AWS CLI
- `aws ec2 run-instances` with complex `--user-data` and `--tag-specifications`
- `aws s3 sync` with `--exclude`/`--include` filter chains
- `aws cloudformation create-change-set` + `execute-change-set`
- `aws ec2 describe-instances` with `--query` JMESPath multi-level filters
- `aws rds modify-db-instance` with multi-option flags
- `aws iam create-policy` with complex policy documents
- STS assume-role + chained API calls

## 4. Test Case Format

```xml
<test-case expected="allow|ask" reason="<read-only|specific-trigger>" category="DOMAIN-Subcategory">
  <description>What this test exercises</description>
  <copilot-command><![CDATA[
the actual command text, possibly multi-line
  ]]></copilot-command>
</test-case>
```

Multi-line commands use CDATA sections. Special characters (backslashes, quotes, newlines) require no escaping within CDATA.

## 5. Integration into test-cases.xml

- New entries are appended into the matching `<category-group>` sections
- A `<!-- COMPLEX COMMANDS -->` separator comment identifies new blocks
- Existing entries get the `reason` attribute retrofitted
- Total target: 100+ new complex test cases
  - PowerShell: 15+ (heavy remoting focus)
  - Linux/Bash: 15+ (heavy SSH remoting focus)
  - DOS/CMD: 12+
  - Terraform: 12+ (flag-separated subcommand focus)
  - Docker: 12+
  - Kubernetes: 12+
  - AWS CLI: 12+
  - Remainder assigned to domains with richest research findings

## 6. Research Method

Research via web search (brave-search MCP), searching for:
- Most complex real-world command patterns per domain
- Advanced remoting techniques (PowerShell WinRM/SSH, Linux SSH)
- Complex chained/nested constructs
- Terraform flag-separated subcommand patterns

## 7. JSON Runtime Config File

In addition to `test-cases.xml` (test cases), a `commands.json` runtime file is generated for the hook script to load at startup.

### 7.1 Structure

```json
{
  "version": "1.0",
  "dry_run_flags": { "<command>": "read-only" },
  "risk_legend": { "low": "...", "medium": "...", "high": "..." },
  "commands": {
    "<DOMAIN>": {
      "description": "...",
      "read_only":  [{ "name": "...", "patterns": ["..."], "description": "..." }],
      "modifying":  [{ "name": "...", "patterns": ["..."], "risk": "low|medium|high", "description": "..." }]
    }
  }
}
```

### 7.2 Pattern matching

Each entry has a `patterns` array of glob-style strings (e.g., `docker ps*`, `kubectl get *`, `terraform *apply*`). The hook matches the intercepted command against these patterns in order. First match wins.

### 7.3 Verb-based classification (PowerShell + AWS CLI)

- **PowerShell**: `read_only_verbs` and `modifying_verbs` arrays allow classification by cmdlet verb without listing every `Get-*` variant. Unknown verbs fall through to explicit entries.
- **AWS CLI**: Commands follow `aws <service> <verb-*>` pattern. Classification is driven by the verb position (e.g., `describe-*`, `list-*`, `get-*` → read-only; `delete-*`, `create-*`, `update-*` → modifying). Non-standard verbs (`s3 ls`, `s3 cp`, `s3 sync`, `s3 rm`, `s3 mv`, `ec2 run-instances`, `ec2 reboot-instances`, `<service> wait`, `configure`) require explicit entries.

### 7.4 Terraform flag-separated subcommands

Patterns use wildcard globs to match flag-separated commands: `terraform *apply*` matches `terraform -chdir="./test/" apply -auto-approve`.

## 8. Completion Criteria

- 100+ new `<test-case>` entries added to `test-cases.xml`
- Every existing and new entry has a `reason` attribute
- `reason="read-only"` on all `expected="allow"` entries
- `reason` contains specific modifying sub-command on `expected="ask"` entries
- New entries follow the schema and format of existing entries
- PowerShell remoting and SSH remoting receive extra coverage
