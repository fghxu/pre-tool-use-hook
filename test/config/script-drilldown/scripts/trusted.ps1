# trusted.ps1 - D9 short-circuit target. Trusted via trusted_programs basename;
# the engine must return $null at step 1 and NEVER read this file.
Get-ChildItem C:\temp
