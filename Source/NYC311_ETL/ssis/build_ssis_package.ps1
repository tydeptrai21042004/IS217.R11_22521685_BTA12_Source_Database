param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,

    [Parameter(Mandatory=$true)]
    [string]$OutputPackage,

    [string]$OleDbProvider = "MSOLEDBSQL"
)

$ErrorActionPreference = "Stop"

function Find-SsisAssembly([string]$FileName) {
    $roots = @(
        "C:\Program Files\Microsoft SQL Server\170\DTS\Binn",
        "C:\Program Files\Microsoft SQL Server\160\DTS\Binn",
        "C:\Program Files\Microsoft SQL Server\150\DTS\Binn",
        "C:\Program Files\Microsoft SQL Server\140\DTS\Binn",
        "C:\Program Files (x86)\Microsoft SQL Server\170\DTS\Binn",
        "C:\Program Files (x86)\Microsoft SQL Server\160\DTS\Binn",
        "C:\Program Files (x86)\Microsoft SQL Server\150\DTS\Binn",
        "C:\Program Files (x86)\Microsoft SQL Server\140\DTS\Binn"
    )
    foreach ($r in $roots) {
        $p = Join-Path $r $FileName
        if (Test-Path $p) { return $p }
    }
    $found = Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Filter $FileName -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
    return $found
}

$managedDts = Find-SsisAssembly "Microsoft.SqlServer.ManagedDTS.dll"
$sqlTaskDll = Find-SsisAssembly "Microsoft.SqlServer.SQLTask.dll"

if (-not $managedDts) {
    throw "Microsoft.SqlServer.ManagedDTS.dll not found. Install SQL Server Integration Services runtime."
}
if (-not $sqlTaskDll) {
    throw "Microsoft.SqlServer.SQLTask.dll not found. Install SQL Server Integration Services runtime."
}

Write-Host "[INFO] ManagedDTS: $managedDts"
Write-Host "[INFO] SQLTask:    $sqlTaskDll"

Add-Type -Path $managedDts
Add-Type -Path $sqlTaskDll

$pkg = New-Object Microsoft.SqlServer.Dts.Runtime.Package
$pkg.Name = "00_Master_NYC311_ETL"
$pkg.Description = "IS217 BTA12 - automated NYC 311 warehouse ETL"
$pkg.ProtectionLevel = [Microsoft.SqlServer.Dts.Runtime.DTSProtectionLevel]::DontSaveSensitive

$cm = $pkg.Connections.Add("OLEDB")
$cm.Name = "NYC311_DW"
$cm.Description = "OLE DB connection to NYC311_DW"
$cm.ConnectionString = "Provider=$OleDbProvider;Data Source=$SqlServer;Initial Catalog=NYC311_DW;Integrated Security=SSPI;TrustServerCertificate=True;"

function Add-SqlTask(
    [Microsoft.SqlServer.Dts.Runtime.Package]$Package,
    [Microsoft.SqlServer.Dts.Runtime.ConnectionManager]$Connection,
    [string]$Name,
    [string]$Sql
) {
    $exec = $Package.Executables.Add("STOCK:SQLTask")
    $host = [Microsoft.SqlServer.Dts.Runtime.TaskHost]$exec
    $host.Name = $Name

    $task = $host.InnerObject
    $task.Connection = $Connection.Name
    $task.SqlStatementSource = $Sql
    $task.BypassPrepare = $true
    return $exec
}

$t1 = Add-SqlTask $pkg $cm "01 - Begin ETL batch" "EXEC etl.usp_BeginBatch;"
$t2 = Add-SqlTask $pkg $cm "02 - Extract/load CSV to staging" "EXEC etl.usp_LoadStaging;"
$t3 = Add-SqlTask $pkg $cm "03 - Transform/load dimensions" "EXEC etl.usp_LoadDimensions;"
$t4 = Add-SqlTask $pkg $cm "04 - Transform/load fact" "EXEC etl.usp_LoadFact;"
$t5 = Add-SqlTask $pkg $cm "05 - Validate and close batch" "EXEC etl.usp_ValidateAndCloseBatch;"

foreach ($pair in @(@($t1,$t2),@($t2,$t3),@($t3,$t4),@($t4,$t5))) {
    $pc = $pkg.PrecedenceConstraints.Add($pair[0], $pair[1])
    $pc.EvalOp = [Microsoft.SqlServer.Dts.Runtime.DTSPrecedenceEvalOp]::Constraint
    $pc.Value = [Microsoft.SqlServer.Dts.Runtime.DTSExecResult]::Success
}

$outDir = Split-Path -Parent $OutputPackage
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$app = New-Object Microsoft.SqlServer.Dts.Runtime.Application
$app.SaveToXml($OutputPackage, $pkg, $null)

Write-Host "[PASS] SSIS package generated: $OutputPackage"
