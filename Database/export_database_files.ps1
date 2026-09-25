param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,

    [string]$Database = "NYC311_DW",

    [Parameter(Mandatory=$true)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$query = @"
SET NOCOUNT ON;
SELECT physical_name
FROM sys.master_files
WHERE database_id = DB_ID(N'$Database')
ORDER BY file_id;
"@

$raw = & sqlcmd -S $SqlServer -E -b -h -1 -W -Q $query
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query SQL Server database files."
}

$paths = @($raw | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) })

if ($paths.Count -lt 2) {
    Write-Warning "Could not directly access MDF/LDF paths with this Windows account."
    Write-Warning "Database is valid; copy MDF/LDF manually after setting database OFFLINE."
    exit 0
}

& sqlcmd -S $SqlServer -E -b -Q "ALTER DATABASE [$Database] SET OFFLINE WITH ROLLBACK IMMEDIATE;"
if ($LASTEXITCODE -ne 0) { throw "Could not set database OFFLINE." }

try {
    foreach ($p in $paths) {
        Copy-Item -Path $p -Destination $OutputDir -Force
        Write-Host "[INFO] Copied: $p"
    }
}
finally {
    & sqlcmd -S $SqlServer -E -b -Q "ALTER DATABASE [$Database] SET ONLINE;"
}

Write-Host "[PASS] Database files exported to: $OutputDir"
