param(
    [Parameter(Mandatory=$true)]
    [string]$Package
)

$ErrorActionPreference = "Stop"

function Find-Dtexec {
    $cmd = Get-Command dtexec.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "C:\Program Files\Microsoft SQL Server\170\DTS\Binn\DTExec.exe",
        "C:\Program Files\Microsoft SQL Server\160\DTS\Binn\DTExec.exe",
        "C:\Program Files\Microsoft SQL Server\150\DTS\Binn\DTExec.exe",
        "C:\Program Files\Microsoft SQL Server\140\DTS\Binn\DTExec.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$dtexec = Find-Dtexec
if (-not $dtexec) {
    throw "DTExec.exe not found. Install SQL Server Integration Services runtime."
}

Write-Host "[INFO] Using DTExec: $dtexec"
& $dtexec /FILE $Package /REPORTING E
if ($LASTEXITCODE -ne 0) {
    throw "SSIS execution failed. DTExec exit code: $LASTEXITCODE"
}

Write-Host "[PASS] SSIS package execution completed."
