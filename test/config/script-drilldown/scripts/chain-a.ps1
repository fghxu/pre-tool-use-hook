# chain-a.ps1 - dot-sources b; a->b->c stays under the cap of 3.
# NOTE: inner refs are CWD-anchored (engine resolves relative paths to $Config._cwd,
# which is the fixture dir under TestRunner -Cwd), so siblings in scripts\ are named
# 'scripts\<name>.ps1' here. This is the realistic form given CWD=fixtureDir.
. scripts\chain-b.ps1
Write-Host a
