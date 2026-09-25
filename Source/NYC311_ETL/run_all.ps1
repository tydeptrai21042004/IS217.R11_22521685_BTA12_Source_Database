param(
    [string]$SqlServer = ".\SQLEXPRESS",
    [string]$DatasetDate = "2025-01-15",
    [double]$MaxMB = 49.0,
    [string]$OleDbProvider = "MSOLEDBSQL"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ProjectRoot "..\..")).Path
$DbRoot = Join-Path $RepoRoot "Database"
$DataRoot = Join-Path $env:PUBLIC "Documents\NYC311_BTA12"
$DataFile = Join-Path $DataRoot ("nyc311_{0}.csv" -f $DatasetDate)
$ManifestJson = Join-Path $DataRoot "manifest.json"
$ManifestCsv = Join-Path $DataRoot "manifest.csv"
$Package = Join-Path $ProjectRoot "ssis\00_Master_NYC311_ETL.dtsx"
$ValidationOut = Join-Path $DbRoot "generated\validation_output.txt"
$DbFilesOut = Join-Path $DbRoot "generated"

Write-Host "============================================================"
Write-Host " IS217.R11 - 22521685 - BTA12 automated ETL"
Write-Host " SQL Server : $SqlServer"
Write-Host " Dataset day: $DatasetDate"
Write-Host " Max file   : $MaxMB MB"
Write-Host "============================================================"

foreach ($cmd in @("python","sqlcmd")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $cmd"
    }
}

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DbFilesOut | Out-Null

Write-Host "`n[1/8] Download complete real-data day from NYC Open Data"
python (Join-Path $ProjectRoot "automation\download_nyc311.py") `
    --date $DatasetDate `
    --output $DataFile `
    --manifest-json $ManifestJson `
    --manifest-csv $ManifestCsv `
    --max-mb $MaxMB
if ($LASTEXITCODE -ne 0) { throw "Download/verification failed." }

Write-Host "`n[2/8] Create/reset warehouse schema"
sqlcmd -S $SqlServer -E -b -i (Join-Path $DbRoot "sql\00_create_database.sql")
if ($LASTEXITCODE -ne 0) { throw "Database creation failed." }

sqlcmd -S $SqlServer -E -b -i (Join-Path $DbRoot "sql\01_etl_procedures.sql")
if ($LASTEXITCODE -ne 0) { throw "ETL procedure creation failed." }

Write-Host "`n[3/8] Configure runtime from verified manifest"
python (Join-Path $ProjectRoot "automation\configure_runtime.py") `
    --server $SqlServer `
    --manifest $ManifestJson
if ($LASTEXITCODE -ne 0) { throw "Runtime configuration failed." }

Write-Host "`n[4/8] Generate SSIS package programmatically"
& (Join-Path $ProjectRoot "ssis\build_ssis_package.ps1") `
    -SqlServer $SqlServer `
    -OutputPackage $Package `
    -OleDbProvider $OleDbProvider

Write-Host "`n[5/8] Execute SSIS package"
& (Join-Path $ProjectRoot "ssis\run_ssis.ps1") -Package $Package

Write-Host "`n[6/8] Run warehouse validation report"
sqlcmd -S $SqlServer -E -b -d NYC311_DW `
    -Q "EXEC etl.usp_ReportValidation;" `
    -o $ValidationOut
if ($LASTEXITCODE -ne 0) { throw "Validation report failed." }
Get-Content $ValidationOut

Write-Host "`n[7/8] Export MDF/LDF where local permissions allow"
& (Join-Path $DbRoot "export_database_files.ps1") `
    -SqlServer $SqlServer `
    -OutputDir $DbFilesOut

Write-Host "`n[8/8] Finished"
Write-Host "[PASS] Dataset: $DataFile"
Write-Host "[PASS] Manifest: $ManifestJson"
Write-Host "[PASS] SSIS: $Package"
Write-Host "[PASS] Validation: $ValidationOut"
Write-Host "[PASS] Database output: $DbFilesOut"
