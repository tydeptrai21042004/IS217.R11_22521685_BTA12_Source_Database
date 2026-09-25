# IS217.R11 — BTA12 — NYC 311 ETL / SSIS (Linux-ready)

**Sinh viên:** Bùi Võ Duy Vũ  
**MSSV:** 22521685  
**Lớp:** IS217.R11

## Mục tiêu

Project hiện thực quy trình **Extract → Transform → Load bằng SSIS** trên Linux và SQL Server 2022. Bản này đã bỏ các phụ thuộc Windows (`.ps1`, `.cmd`, SSPI, `C:\...`).

> Full native SSIS setup is pinned to **Ubuntu 20.04** because Microsoft's current Linux SSIS installation guidance for SQL Server 2022 uses the Ubuntu 20.04 repository. SSIS-in-container is not supported by Microsoft.

## Dataset thật, giới hạn cứng 50 MB

Nguồn: NYC Open Data — `311 Service Requests from 2020 to Present`, dataset ID `erm2-nwe9`.

`download_nyc311.py` tự động:

1. Bắt đầu từ `2025-01-15` và quét lùi tối đa 45 ngày.
2. Với mỗi ngày, gọi API `COUNT(*)` và lấy mẫu nhỏ chỉ để **ước lượng kích thước**.
3. Ưu tiên ngày đầy đủ lớn nhất có ước lượng an toàn dưới giới hạn.
4. Tải **toàn bộ ngày đã chọn**, theo `unique_key ASC`.
5. Không random sampling, không `head()`, không cắt bớt record.
6. Kiểm tra từng dòng trước khi ghi: **không bao giờ giữ file > 50,000,000 bytes**.
7. Nếu một ngày thực tế vượt 50 MB, xóa file tạm và thử ngày khác.
8. Đối chiếu API row count = CSV row count, kiểm tra duplicate key, tính SHA-256.
9. Chỉ giữ một file CSV cuối cùng của ngày được chọn.

Giới hạn mặc định là **50.00 MB decimal = 50,000,000 bytes**, nghiêm ngặt hơn cách tính 50 MiB.

## Cấu trúc

```text
Database/
├── export_database_files.sh
├── generated/
└── sql/
    ├── 00_create_database.sql
    ├── 01_etl_procedures.sql
    └── 02_manual_validation.sql

Source/NYC311_ETL/
├── run_all.sh
├── setup_linux.sh
├── check_prerequisites.sh
├── automation/
│   ├── download_nyc311.py
│   └── configure_runtime.py
├── config/
│   └── project_config.json
└── ssis/
    ├── build_ssis_package.py
    ├── run_ssis.py
    └── README_SSIS.md
```

Không bao gồm `Video/` và `Document/` theo yêu cầu hiện tại.

## Yêu cầu

- Ubuntu 20.04 x86_64
- Python 3
- SQL Server 2022 Developer/Express
- SQL Server Integration Services package `mssql-server-is`
- `sqlcmd` (`mssql-tools18`)
- `sudo` để đưa CSV vào `/var/opt/mssql/import` và sao chép `.mdf/.ldf`

## Cách chạy nhanh

### 1. Đặt mật khẩu SQL Server

```bash
export MSSQL_SA_PASSWORD='Your_Strong_Password_Here'
```

### 2. Nếu máy chưa có SQL Server/SSIS

```bash
cd Source/NYC311_ETL
./run_all.sh --install
```

Hoặc cài riêng:

```bash
./setup_linux.sh
./run_all.sh
```

### 3. Nếu đã cài đủ dependencies

```bash
cd Source/NYC311_ETL
./run_all.sh
```

Có thể đổi ngày bắt đầu tìm:

```bash
./run_all.sh --start-date 2025-02-01 --lookback-days 60
```

**Không nên tăng `--max-bytes`** nếu bài yêu cầu dữ liệu không quá 50 MB.

## `run_all.sh` làm gì?

```text
NYC Open Data API
      ↓
Auto-select complete real day <= 50 MB
      ↓
Verify rows + size + SHA-256
      ↓
Copy CSV to /var/opt/mssql/import/nyc311_bta12
      ↓
Create NYC311_DW
      ↓
Create ETL stored procedures
      ↓
Generate 00_Master_NYC311_ETL.dtsx
      ↓
dtexec (SQL Authentication)
      ↓
Staging → Dimensions → Fact
      ↓
Validation
      ↓
Database/generated/*.mdf + *.ldf
```

## SSIS package

Package được sinh bằng Python để không cần SSDT/Visual Studio trên Linux. Package chứa 5 Execute SQL Tasks nối bằng Success precedence constraints:

1. Begin ETL batch
2. Extract/load CSV to staging
3. Transform/load dimensions
4. Transform/load fact
5. Validate and close batch

`dtexec` nhận connection string tại runtime qua `/CONNECTION`. Mật khẩu SQL **không được lưu vào DTSX**.

## Warehouse

- `stg.NYC311Raw`
- `dw.DimDate`
- `dw.DimAgency`
- `dw.DimComplaint`
- `dw.DimLocation`
- `dw.Fact311Request`
- `etl.RuntimeConfig`
- `etl.ETLBatch`
- `etl.Rejected311`

## Kiểm tra toàn vẹn

Pipeline bắt buộc:

```text
API expected rows = staging rows
staging rows = fact rows + rejected rows
Fact UniqueKey không trùng
Fact foreign keys đều tồn tại
source CSV <= 50,000,000 bytes
```

Nếu một invariant thất bại, script dừng với exit code khác 0.

## MDF/LDF

Cuối pipeline, database được đặt OFFLINE trong thời gian ngắn, `.mdf/.ldf` được copy nhất quán sang `Database/generated/`, sau đó database được đưa ONLINE lại ngay cả khi copy lỗi.

## Bảo mật

- Không commit mật khẩu vào source.
- `MSSQL_SA_PASSWORD` chỉ lấy từ environment/prompt.
- DTSX chứa dummy password không hợp lệ và được override lúc chạy.
- Với bài thực tế hơn, có thể tạo login ETL riêng thay vì dùng `sa`.
