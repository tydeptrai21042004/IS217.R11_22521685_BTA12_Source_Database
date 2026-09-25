# IS217.R11 - 22521685 - BTA12 - UCI Online Retail / SSIS on Linux

**Sinh viên:** Bùi Võ Duy Vũ  
**MSSV:** 22521685  
**Lớp:** IS217.R11

This version replaces NYC 311 because its Socrata API returned repeated HTTP 403 responses in WSL.

## Dataset

- UCI Machine Learning Repository: **Online Retail**, dataset **352**
- DOI: **10.24432/C5BW33**
- Whole real dataset: **541,909 transaction lines**
- Period: **01/12/2010 - 09/12/2011**
- Official XLSX: about **22.6 MB**
- No sampling, no truncation, no simulated rows
- The downloaded ZIP, extracted XLSX, and generated CSV are each hard-limited to **50,000,000 bytes**

Columns: `InvoiceNo`, `StockCode`, `Description`, `Quantity`, `InvoiceDate`, `UnitPrice`, `CustomerID`, `Country`.
Invoices starting with `C` are preserved as cancellations; negative quantities are preserved as returns.

## Warehouse

```text
                    DimDate
                       |
DimProduct --- FactSalesLine --- DimCustomer
                       |
                   DimCountry
```

`InvoiceNo` is a degenerate dimension. Measures include Quantity, UnitPrice, LineAmount and LineCount.

## Run

```bash
cd Source/OnlineRetail_ETL
chmod +x *.sh automation/*.sh ssis/*.sh ../../Database/*.sh
./run_all.sh --install
```

Since your SQL Server/SSIS are already installed, normally you can now use:

```bash
./run_all.sh
```

## Output

```text
Database/generated/
  RetailDW.mdf
  RetailDW_log.ldf
  validation_output.txt
  source_manifest.json
```
