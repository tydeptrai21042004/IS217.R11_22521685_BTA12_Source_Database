# IS217.R11 BTA12 — Linux/WSL automatic SSIS
Bùi Võ Duy Vũ — 22521685

Works on Ubuntu 20.04/22.04 (including WSL2 development) with SQL Server 2022 and native `mssql-server-is`.

## Fully automatic sudo without putting your password in the submitted ZIP
Use either:
```bash
export BTA12_SUDO_PASSWORD='YOUR_UBUNTU_PASSWORD'
cd Source/NYC311_ETL
./run_all.sh --install
```
or save it once outside the project:
```bash
cd Source/NYC311_ETL
./save_sudo_password.sh
./run_all.sh --install
```
The local secret file is `~/.config/bta12/sudo_password` (mode 600). The assignment ZIP never contains that password.

If `MSSQL_SA_PASSWORD` is unset, a strong SQL Server `sa` password is generated to `~/.config/bta12/sa_password` (mode 600).

## Dataset
Official NYC Open Data dataset `erm2-nwe9`. The downloader searches complete calendar days and retains only a full day whose exact serialized CSV is <= **50,000,000 bytes**. No sampling and no truncation. API count must equal verified CSV row count.

## Output
`Database/generated/NYC311_DW.mdf`, `NYC311_DW_log.ldf`, and `validation_output.txt`.
