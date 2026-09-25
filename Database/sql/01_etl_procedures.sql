USE RetailDW;
GO
CREATE OR ALTER PROCEDURE etl.usp_BeginBatch AS
BEGIN
 SET NOCOUNT ON;
 INSERT INTO etl.ETLBatch(DatasetName,SourceCsvPath,SourceSha256,SourceBytes,ExpectedRows,Status)
 SELECT
  MAX(CASE WHEN ConfigKey=N'DatasetName' THEN ConfigValue END),
  MAX(CASE WHEN ConfigKey=N'SourceCsvPath' THEN ConfigValue END),
  MAX(CASE WHEN ConfigKey=N'SourceSha256' THEN ConfigValue END),
  TRY_CONVERT(bigint,MAX(CASE WHEN ConfigKey=N'SourceBytes' THEN ConfigValue END)),
  TRY_CONVERT(int,MAX(CASE WHEN ConfigKey=N'ExpectedSourceRows' THEN ConfigValue END)),
  'RUNNING'
 FROM etl.RuntimeConfig;
END
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadStaging AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @Path nvarchar(4000)=(SELECT ConfigValue FROM etl.RuntimeConfig WHERE ConfigKey=N'SourceCsvPath');
 IF @Path IS NULL OR LTRIM(RTRIM(@Path))=N'' THROW 50001,'SourceCsvPath is not configured.',1;
 TRUNCATE TABLE stg.OnlineRetailRaw;
 DECLARE @sql nvarchar(max)=N'BULK INSERT stg.OnlineRetailRaw FROM '''+REPLACE(@Path,'''','''''')+N''' WITH ('+
   N'FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE='''+'"'+N''', CODEPAGE=''65001'', ROWTERMINATOR=''0x0a'', TABLOCK);';
 EXEC sys.sp_executesql @sql;
END
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadDimensions AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 ;WITH D AS(
  SELECT DISTINCT CONVERT(date,TRY_CONVERT(datetime2(0),NULLIF(InvoiceDate,N''),120)) FullDate
  FROM stg.OnlineRetailRaw WHERE TRY_CONVERT(datetime2(0),NULLIF(InvoiceDate,N''),120) IS NOT NULL
 )
 INSERT INTO dw.DimDate(DateKey,FullDate,CalendarYear,CalendarQuarter,CalendarMonth,MonthName,DayOfMonth,DayOfWeekIso,DayName,IsWeekend)
 SELECT CONVERT(int,CONVERT(char(8),FullDate,112)),FullDate,YEAR(FullDate),DATEPART(QUARTER,FullDate),MONTH(FullDate),
        DATENAME(MONTH,FullDate),DAY(FullDate),((DATEDIFF(day,CONVERT(date,'19000101'),FullDate)%7)+1),
        DATENAME(WEEKDAY,FullDate),CASE WHEN ((DATEDIFF(day,CONVERT(date,'19000101'),FullDate)%7)+1) IN(6,7) THEN 1 ELSE 0 END
 FROM D WHERE NOT EXISTS(SELECT 1 FROM dw.DimDate x WHERE x.FullDate=D.FullDate);
 ;WITH P AS(
  SELECT StockCode=LTRIM(RTRIM(StockCode)), ProductName=MAX(COALESCE(NULLIF(LTRIM(RTRIM(Description)),N''),N'UNKNOWN'))
  FROM stg.OnlineRetailRaw WHERE NULLIF(LTRIM(RTRIM(StockCode)),N'') IS NOT NULL GROUP BY LTRIM(RTRIM(StockCode))
 )
 INSERT INTO dw.DimProduct(StockCode,ProductName)
 SELECT P.StockCode,P.ProductName FROM P WHERE NOT EXISTS(SELECT 1 FROM dw.DimProduct d WHERE d.StockCode=P.StockCode);
 IF NOT EXISTS(SELECT 1 FROM dw.DimCustomer WHERE CustomerID=N'UNKNOWN')
  INSERT INTO dw.DimCustomer(CustomerID,IsKnownCustomer) VALUES(N'UNKNOWN',0);
 INSERT INTO dw.DimCustomer(CustomerID,IsKnownCustomer)
 SELECT DISTINCT LTRIM(RTRIM(CustomerID)),1 FROM stg.OnlineRetailRaw s
 WHERE NULLIF(LTRIM(RTRIM(CustomerID)),N'') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM dw.DimCustomer d WHERE d.CustomerID=LTRIM(RTRIM(s.CustomerID)));
 INSERT INTO dw.DimCountry(CountryName)
 SELECT DISTINCT COALESCE(NULLIF(LTRIM(RTRIM(Country)),N''),N'UNKNOWN') FROM stg.OnlineRetailRaw s
 WHERE NOT EXISTS(SELECT 1 FROM dw.DimCountry d WHERE d.CountryName=COALESCE(NULLIF(LTRIM(RTRIM(s.Country)),N''),N'UNKNOWN'));
END
GO
CREATE OR ALTER PROCEDURE etl.usp_LoadFact AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @BatchId int=(SELECT MAX(BatchId) FROM etl.ETLBatch);
 DELETE FROM etl.RejectedRetail WHERE BatchId=@BatchId;
 ;WITH P AS(
  SELECT s.*, InvoiceDT=TRY_CONVERT(datetime2(0),NULLIF(InvoiceDate,N''),120),
   Qty=TRY_CONVERT(int,NULLIF(Quantity,N'')), Price=TRY_CONVERT(decimal(19,4),NULLIF(UnitPrice,N''))
  FROM stg.OnlineRetailRaw s
 )
 INSERT INTO etl.RejectedRetail(BatchId,InvoiceNo,StockCode,InvoiceDateRaw,RejectReason)
 SELECT @BatchId,InvoiceNo,StockCode,InvoiceDate,
  CONCAT(CASE WHEN NULLIF(LTRIM(RTRIM(InvoiceNo)),N'') IS NULL THEN N'Missing InvoiceNo; ' ELSE N'' END,
         CASE WHEN NULLIF(LTRIM(RTRIM(StockCode)),N'') IS NULL THEN N'Missing StockCode; ' ELSE N'' END,
         CASE WHEN InvoiceDT IS NULL THEN N'Invalid InvoiceDate; ' ELSE N'' END,
         CASE WHEN Qty IS NULL THEN N'Invalid Quantity; ' ELSE N'' END,
         CASE WHEN Price IS NULL THEN N'Invalid UnitPrice; ' ELSE N'' END)
 FROM P
 WHERE NULLIF(LTRIM(RTRIM(InvoiceNo)),N'') IS NULL OR NULLIF(LTRIM(RTRIM(StockCode)),N'') IS NULL
    OR InvoiceDT IS NULL OR Qty IS NULL OR Price IS NULL;
 ;WITH P AS(
  SELECT s.*, InvoiceDT=TRY_CONVERT(datetime2(0),NULLIF(InvoiceDate,N''),120),
   Qty=TRY_CONVERT(int,NULLIF(Quantity,N'')), Price=TRY_CONVERT(decimal(19,4),NULLIF(UnitPrice,N'')),
   InvoiceNoN=LTRIM(RTRIM(InvoiceNo)), StockCodeN=LTRIM(RTRIM(StockCode)),
   CustomerIDN=COALESCE(NULLIF(LTRIM(RTRIM(CustomerID)),N''),N'UNKNOWN'),
   CountryN=COALESCE(NULLIF(LTRIM(RTRIM(Country)),N''),N'UNKNOWN')
  FROM stg.OnlineRetailRaw s
 )
 INSERT INTO dw.FactSalesLine(InvoiceNo,DateKey,ProductKey,CustomerKey,CountryKey,InvoiceDateTime,Quantity,UnitPrice,LineAmount,IsCancellation,LineCount,LoadBatchId)
 SELECT p.InvoiceNoN,CONVERT(int,CONVERT(char(8),CONVERT(date,p.InvoiceDT),112)),pr.ProductKey,cu.CustomerKey,co.CountryKey,
        p.InvoiceDT,p.Qty,p.Price,CONVERT(decimal(19,4),p.Qty*p.Price),
        CASE WHEN UPPER(LEFT(p.InvoiceNoN,1))='C' THEN 1 ELSE 0 END,1,@BatchId
 FROM P p
 INNER JOIN dw.DimProduct pr ON pr.StockCode=p.StockCodeN
 INNER JOIN dw.DimCustomer cu ON cu.CustomerID=p.CustomerIDN
 INNER JOIN dw.DimCountry co ON co.CountryName=p.CountryN
 WHERE p.InvoiceNoN<>N'' AND p.StockCodeN<>N'' AND p.InvoiceDT IS NOT NULL AND p.Qty IS NOT NULL AND p.Price IS NOT NULL;
END
GO
CREATE OR ALTER PROCEDURE etl.usp_ValidateAndCloseBatch AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @BatchId int=(SELECT MAX(BatchId) FROM etl.ETLBatch), @Expected int, @Staging int, @Rejected int, @Fact int;
 SELECT @Expected=ExpectedRows FROM etl.ETLBatch WHERE BatchId=@BatchId;
 SELECT @Staging=COUNT(*) FROM stg.OnlineRetailRaw;
 SELECT @Rejected=COUNT(*) FROM etl.RejectedRetail WHERE BatchId=@BatchId;
 SELECT @Fact=COUNT(*) FROM dw.FactSalesLine WHERE LoadBatchId=@BatchId;
 DECLARE @Status varchar(30),@Note nvarchar(1000);
 IF @Staging<>@Expected BEGIN SET @Status='FAILED'; SET @Note=CONCAT('Staging mismatch expected=',@Expected,', staging=',@Staging); END
 ELSE IF @Fact+@Rejected<>@Staging BEGIN SET @Status='FAILED'; SET @Note=CONCAT('Accounting mismatch staging=',@Staging,', fact=',@Fact,', rejected=',@Rejected); END
 ELSE BEGIN SET @Status='SUCCEEDED'; SET @Note=CONCAT('PASS expected=',@Expected,', staging=',@Staging,', fact=',@Fact,', rejected=',@Rejected); END
 UPDATE etl.ETLBatch SET EndTimeUtc=SYSUTCDATETIME(),StagingRows=@Staging,FactRows=@Fact,RejectedRows=@Rejected,Status=@Status,ValidationNote=@Note WHERE BatchId=@BatchId;
 SELECT * FROM etl.ETLBatch WHERE BatchId=@BatchId;
 IF @Status<>'SUCCEEDED' THROW 50010,@Note,1;
END
GO
CREATE OR ALTER PROCEDURE etl.usp_ReportValidation AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(1) * FROM etl.ETLBatch ORDER BY BatchId DESC;
 SELECT StagingRows=(SELECT COUNT(*) FROM stg.OnlineRetailRaw), DimDateRows=(SELECT COUNT(*) FROM dw.DimDate),
  DimProductRows=(SELECT COUNT(*) FROM dw.DimProduct), DimCustomerRows=(SELECT COUNT(*) FROM dw.DimCustomer),
  DimCountryRows=(SELECT COUNT(*) FROM dw.DimCountry), FactRows=(SELECT COUNT(*) FROM dw.FactSalesLine),
  RejectedRows=(SELECT COUNT(*) FROM etl.RejectedRetail);
 SELECT TOP(15) c.CountryName, Lines=COUNT_BIG(*), NetRevenue=SUM(f.LineAmount), CancellationLines=SUM(CASE WHEN f.IsCancellation=1 THEN 1 ELSE 0 END)
 FROM dw.FactSalesLine f JOIN dw.DimCountry c ON c.CountryKey=f.CountryKey GROUP BY c.CountryName ORDER BY SUM(f.LineAmount) DESC;
 SELECT TOP(15) p.StockCode,p.ProductName,Units=SUM(CONVERT(bigint,f.Quantity)),NetRevenue=SUM(f.LineAmount)
 FROM dw.FactSalesLine f JOIN dw.DimProduct p ON p.ProductKey=f.ProductKey GROUP BY p.StockCode,p.ProductName ORDER BY SUM(f.LineAmount) DESC;
END
GO
