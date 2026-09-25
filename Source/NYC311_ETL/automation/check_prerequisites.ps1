param(
    [string]$SqlServer = ".\SQLEXPRESS"
)

$ErrorActionPreference = "Continue"

$items = @()

function Add-Check($Name, $Ok, $Detail) {
    $script:items += [pscustomobject]@{
        Component = $Name
        OK = [bool]$Ok
        Detail = $Detail
    }
}

$py = Get-Command python -ErrorAction SilentlyContinue
Add-Check "Python" ($null -ne $py) $(if($py){$py.Source}else{"not found"})

$sc = Get-Command sqlcmd -ErrorAction SilentlyContinue
Add-Check "sqlcmd" ($null -ne $sc) $(if($sc){$sc.Source}else{"not found"})

$dt = Get-Command dtexec.exe -ErrorAction SilentlyContinue
if (-not $dt) {
    $cand = Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Filter DTExec.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Check "SSIS dtexec" ($null -ne $cand) $(if($cand){$cand.FullName}else{"not found"})
} else {
    Add-Check "SSIS dtexec" $true $dt.Source
}

if ($sc) {
    & sqlcmd -S $SqlServer -E -b -Q "SELECT @@VERSION;" *> $null
    Add-Check "SQL Server connection" ($LASTEXITCODE -eq 0) $SqlServer
} else {
    Add-Check "SQL Server connection" $false "sqlcmd unavailable"
}

$items | Format-Table -AutoSize

if ($items.OK -contains $false) {
    exit 1
}
exit 0
