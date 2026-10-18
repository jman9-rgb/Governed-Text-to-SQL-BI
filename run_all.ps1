<#
Runs every file in sql\build in number order with sqlcmd and stops at the first error.

Usage (PowerShell, from this folder):
    .\run_all.ps1 -Server "localhost"
    .\run_all.ps1 -Server ".\SQLEXPRESS" -From 10        # start at step 10
    .\run_all.ps1 -Server "localhost" -Tests             # also run the matching test file after each step
    .\run_all.ps1 -Server "localhost" -OnlyTests         # run only the test files (no build); step 09 test is skipped
    .\run_all.ps1 -Server "localhost" -From 24 -To 24 -Tests   # build and test a single step

WARNING: step 01 DROPS the DataWarehouse database. Edit the path in sql\build\03_load_bronze.sql first.
The -C flag below trusts the server certificate. It is needed for a local SQL Server and is meant for local use only.
#>
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$From = 1,
    [int]$To = 99,
    [switch]$Tests,
    [switch]$OnlyTests
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = Get-ChildItem (Join-Path $root "sql\build\*.sql") | Sort-Object Name

foreach ($f in $files) {
    $n = [int]$f.Name.Substring(0, 2)

    if ($n -lt $From -or $n -gt $To) { continue }

    if ($OnlyTests) {
        if ($n -eq 9) { continue }

        $testFiles = Get-ChildItem `
            (Join-Path $root ("sql\tests\t{0:00}_*.sql" -f $n)) `
            -ErrorAction SilentlyContinue

        foreach ($x in $testFiles) {
            Write-Host ("---- test " + $x.Name) -ForegroundColor Yellow
            sqlcmd -S $Server -E -C -b -I -f 65001 -i $x.FullName

            if ($LASTEXITCODE -ne 0) {
                throw "A RULE test failed in $($x.Name) (see the FAIL rows above)."
            }
        }
        continue
    }

    if ($n -eq 3 -and
        (Select-String -Path $f.FullName -Pattern 'C:\\path\\to\\your\\datasets' -Quiet)) {
        throw "Edit the folder path in $($f.Name) first (the line marked EDIT THIS LINE)."
    }

    if ($n -eq 9) {
        Write-Host "Skipping $($f.Name) (optional; run it by hand after changing the password)."
        continue
    }

    Write-Host ("==== " + $f.Name) -ForegroundColor Cyan
    sqlcmd -S $Server -E -C -b -I -f 65001 -i $f.FullName

    if ($LASTEXITCODE -ne 0) {
        throw "Stopped: $($f.Name) failed. Fix it, then run: .\run_all.ps1 -Server $Server -From $n"
    }

    if ($Tests) {
        $testFiles = Get-ChildItem `
            (Join-Path $root ("sql\tests\t{0:00}_*.sql" -f $n)) `
            -ErrorAction SilentlyContinue

        foreach ($x in $testFiles) {
            Write-Host ("---- test " + $x.Name) -ForegroundColor Yellow
            sqlcmd -S $Server -E -C -b -I -f 65001 -i $x.FullName

            if ($LASTEXITCODE -ne 0) {
                throw "A RULE test failed in $($x.Name) (see the FAIL rows above). Fix the cause, then run: .\run_all.ps1 -Server $Server -From $n -Tests"
            }
        }
    }
}

Write-Host "Done." -ForegroundColor Green
