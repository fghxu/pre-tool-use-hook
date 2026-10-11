# unknown-stmt.ps1 - contains an UNKNOWN statement (a .NET static call not on any allowlist).
# Pins RUL-3: unknown statements render 'script <basename> contains unknown command: ...'.
[Foo]::Bar()
