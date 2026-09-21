# func-body.ps1 - a modifying command hidden inside a function body (R11: classified as-if-run).
function Clean {
    Remove-Item C:\temp\x
}
Clean
