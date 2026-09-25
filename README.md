# IS217.R11 — 22521685 — BTA12 Fast Linux/WSL

**Sinh viên:** Bùi Võ Duy Vũ — **MSSV:** 22521685  
**Lớp:** IS217.R11

Bản này dùng **UCI Clickstream Data for Online Shopping** thay cho NYC311/Online Retail XLSX để tránh API 403 và giảm thời gian tải.

## Dataset

Nguồn chính thức: UCI Machine Learning Repository — Clickstream Data for Online Shopping (ID 553).

- 165,474 dòng thật.
- 14 biến.
- File dữ liệu CSV gốc khoảng 6.4 MB.
- UCI download archive chỉ khoảng 776 KB.
- Không sampling.
- Không truncate.
- Hard cap 50,000,000 bytes.
- Có cache: chạy lại sẽ không download nếu dataset đã được kiểm chứng.

## Warehouse

**Grain:** 1 row trong FactClickstream = 1 click event trong một session.

Dimensions:
- `dw.DimDate`
- `dw.DimCountry`
- `dw.DimProduct`
- `dw.DimPage`

Fact:
- `dw.FactClickstream`

Measures / degenerate attributes:
- SessionID
- ClickOrder
- Price
- PriceAboveCategoryAvg
- ClickCount = 1

## Chạy

SQL Server 2022 + SSIS của bạn đã được cài rồi, nên **không cần `--install` nữa**.

```bash
cd Source/Clickstream_ETL
chmod +x *.sh automation/*.sh ssis/*.sh ../../Database/*.sh
./run_all.sh
```

Chỉ dùng `--install` khi bạn thật sự cài lại môi trường:

```bash
./run_all.sh --install
```

Ép tải lại dataset:

```bash
./run_all.sh --refresh-data
```

## Output

```text
Database/generated/
├── ClickstreamDW.mdf
├── ClickstreamDW_log.ldf
├── validation_output.txt
└── source_manifest.json
```

## Lưu ý

- Password `sa` đọc từ `MSSQL_SA_PASSWORD`, hoặc từ `~/.config/bta12/sa_password`.
- Sudo password không được hard-code vào project.
- Dataset cache nằm trong `Source/Clickstream_ETL/data/`.
