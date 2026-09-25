# IS217.R11 - BTA12 - NYC 311 ETL / SSIS

**Sinh viên:** Bùi Võ Duy Vũ  
**MSSV:** 22521685  
**Lớp:** IS217.R11  
**Bài:** BTA12 - Thiết kế quá trình trích xuất, biến đổi và nạp dữ liệu bằng SSIS

## Phạm vi của gói này

Gói này chỉ tạo hai phần theo yêu cầu hiện tại:

- `Source/`: mã nguồn automation + SSIS package generator.
- `Database/`: SQL tạo kho dữ liệu, thủ tục ETL, kiểm tra và script xuất `.mdf/.ldf`.

**Không bao gồm**:
- `Video/`
- `Document/`

## Dataset

Nguồn chính thức: NYC Open Data - `311 Service Requests from 2020 to Present`  
Dataset ID: `erm2-nwe9`

Mặc định project lấy **toàn bộ service requests có Created Date trong ngày 2025-01-15**.
Đây là một lát cắt thời gian đầy đủ của nguồn thật, không phải random sample.

Các trường dùng:
`unique_key`, `created_date`, `closed_date`, `agency`, `agency_name`,
`complaint_type`, `descriptor`, `location_type`, `incident_zip`, `city`,
`borough`, `status`, `latitude`, `longitude`.

Downloader:
- gọi API count trước khi tải;
- tải phân trang;
- không bỏ dòng;
- đối chiếu `expected_rows == downloaded_rows`;
- tính SHA-256;
- từ chối file lớn hơn 49 MB.

## Yêu cầu máy

Windows 10/11, Python 3.10+, SQL Server 2019/2022 hoặc SQL Server Express,
SQL Server Integration Services (SSIS runtime), `sqlcmd`, và OLE DB Driver
`MSOLEDBSQL`.

Visual Studio + SSDT chỉ cần nếu muốn mở/chỉnh package bằng giao diện.
Luồng tự động có thể chạy bằng `dtexec`.

## Chạy nhanh

Mở PowerShell tại thư mục:

`Source\NYC311_ETL`

Chạy:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\run_all.ps1 -SqlServer ".\SQLEXPRESS"
```

Nếu SQL Server là default instance:

```powershell
.\run_all.ps1 -SqlServer "localhost"
```

Pipeline:

1. Tải dataset thật từ NYC Open Data.
2. Kiểm tra dataset < 49 MB và toàn vẹn row count.
3. Tạo/reset `NYC311_DW`.
4. Ghi runtime config vào database.
5. Tự sinh `00_Master_NYC311_ETL.dtsx`.
6. Chạy package bằng `dtexec`.
7. Kiểm tra source/staging/fact/rejected.
8. Xuất kết quả kiểm tra.
9. Cố gắng copy `.mdf` và `.ldf` vào `Database\generated`.

## Kiến trúc

```text
NYC Open Data API
      |
      v
download_nyc311.py
  - complete day
  - pagination
  - count check
  - SHA-256
      |
      v
CSV (<49 MB)
      |
      v
00_Master_NYC311_ETL.dtsx
      |
      +--> etl.usp_BeginBatch
      +--> etl.usp_LoadStaging
      +--> etl.usp_LoadDimensions
      +--> etl.usp_LoadFact
      +--> etl.usp_ValidateAndCloseBatch
      |
      v
NYC311_DW
  stg.NYC311Raw
  dw.DimDate
  dw.DimAgency
  dw.DimComplaint
  dw.DimLocation
  dw.Fact311Request
  etl.ETLBatch
  etl.Rejected311
```

## Lưu ý về BULK INSERT

SQL Server service phải đọc được file CSV. Project mặc định tải file vào:

`C:\Users\Public\Documents\NYC311_BTA12\`

để giảm lỗi quyền đọc so với file nằm trong thư mục user cá nhân.

Nếu SQL Server chạy trên máy khác, cần đặt CSV ở một UNC share mà SQL Server service có thể đọc.

## File database

`export_database_files.ps1` đưa database offline trong thời gian rất ngắn,
copy file `.mdf/.ldf` sang `Database\generated`, sau đó đưa database online lại.

Nếu SQL Server account hoặc tài khoản Windows không đủ quyền đọc thư mục
DATA của SQL Server, bước copy sẽ báo cảnh báo nhưng ETL vẫn hoàn tất.
