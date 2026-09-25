# SSIS on Linux

This project is designed for **native SQL Server 2022 SSIS on Ubuntu 20.04**.

- `build_ssis_package.py` generates a package-format-version 8 `.dtsx` containing five **Execute SQL Tasks**.
- The DTSX contains a dummy OLE DB password only.
- `run_ssis.py` calls Linux `dtexec` and overrides `NYC311_DW` at runtime with `/CONNECTION`.
- SQL Authentication is used because Windows Authentication is not supported by SSIS on Linux.

Control flow:

1. `etl.usp_BeginBatch`
2. `etl.usp_LoadStaging`
3. `etl.usp_LoadDimensions`
4. `etl.usp_LoadFact`
5. `etl.usp_ValidateAndCloseBatch`

The SSIS layer remains the package/control-flow execution engine, while deterministic warehouse transformation logic is implemented in SQL Server stored procedures.
