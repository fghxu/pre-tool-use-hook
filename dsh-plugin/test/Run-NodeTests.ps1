# Run-NodeTests.ps1 — wrapper so src/Run-AllTests.ps1 can drive the node-based
# dsh-plugin test suite (run-tests.mjs). Propagates the node exit code.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
node (Join-Path $here "run-tests.mjs")
exit $LASTEXITCODE
