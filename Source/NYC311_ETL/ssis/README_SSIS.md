# SSIS automation

`build_ssis_package.ps1` creates `00_Master_NYC311_ETL.dtsx` by using the
installed Microsoft SSIS object model.

The package contains five SSIS Execute SQL Tasks connected by Success
precedence constraints:

1. `etl.usp_BeginBatch`
2. `etl.usp_LoadStaging`
3. `etl.usp_LoadDimensions`
4. `etl.usp_LoadFact`
5. `etl.usp_ValidateAndCloseBatch`

`run_ssis.ps1` locates `DTExec.exe` and executes the generated package.

This design keeps SSIS as the orchestration/execution layer while SQL Server
contains the deterministic transformation rules. The Python code only obtains
and verifies the external source dataset and writes runtime metadata.
