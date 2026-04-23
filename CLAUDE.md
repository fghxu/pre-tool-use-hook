## Goal
We will write a hook for the pre tool use, which will intercept the claude code run any CLI (PowerShell/AWS CLI/Unix)
the hook will only allow read only operations to be auto executed. if the command will update/modify the system, then it will prompts for approval before executing.

## scope
this is mainly for DevOps developer, so research for all CLI commands (PowerShell/AWS CLI/Unix/Terraform/docker) that my required by Devops engineer.

## requirement
if the CLI command are chained,   from ||, | , && , $ etc,  we need to check each of the sub commands,  if any of them are not Read-Only, then need human approval. otherwise (all sub commands are read only), then auto approval and run. 