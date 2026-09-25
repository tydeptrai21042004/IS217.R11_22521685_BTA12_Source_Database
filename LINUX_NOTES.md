# Linux execution notes

This project intentionally targets **Ubuntu 20.04 + SQL Server 2022 + mssql-server-is** for the full native SSIS path.

Why:

- Microsoft supports `mssql-server-is` on Ubuntu/RHEL, not SLES.
- The current SQL Server 2022 SSIS install instructions use the Ubuntu 20.04 repository.
- SSIS on Linux does not support Windows Authentication, SSIS Catalog/SSISDB, SQL Agent package scheduling, or third-party components.
- This project therefore uses SQL Authentication, file-system package execution (`dtexec /F`), built-in Execute SQL Tasks, and no SSISDB dependency.
- SSIS in containers is not supported by Microsoft, so this project does not try to make Kaggle/Docker execute SSIS.

The package is deliberately simple and Linux-compatible: all five control-flow nodes are built-in Execute SQL Tasks.
