USE ClickstreamDW;
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
 IF @Path IS NULL OR LTRIM(RTRIM(@Path))=N'' THROW 50001,'SourceCsvPath not configured.',1;
 TRUNCATE TABLE stg.ClickstreamRaw;
 DECLARE @sql nvarchar(max)=N'BULK INSERT stg.ClickstreamRaw FROM '''+REPLACE(@Path,'''','''''')+
 N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', CODEPAGE=''65001'', ROWTERMINATOR=''0x0a'', TABLOCK);';
 EXEC sys.sp_executesql @sql;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadDimensions AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;

 ;WITH D AS(
   SELECT DISTINCT
    FullDate=TRY_CONVERT(date,CONCAT(
      RIGHT('0000'+LTRIM(RTRIM([Year])),4),'-',
      RIGHT('00'+LTRIM(RTRIM([Month])),2),'-',
      RIGHT('00'+LTRIM(RTRIM([Day])),2)
    ))
   FROM stg.ClickstreamRaw
 )
 INSERT INTO dw.DimDate(DateKey,FullDate,CalendarYear,CalendarQuarter,CalendarMonth,MonthName,DayOfMonth,DayOfWeekIso,DayName,IsWeekend)
 SELECT
  CONVERT(int,CONVERT(char(8),FullDate,112)), FullDate, YEAR(FullDate),
  DATEPART(QUARTER,FullDate), MONTH(FullDate), DATENAME(MONTH,FullDate), DAY(FullDate),
  ((DATEDIFF(day,CONVERT(date,'19000101'),FullDate)%7)+1), DATENAME(WEEKDAY,FullDate),
  CASE WHEN ((DATEDIFF(day,CONVERT(date,'19000101'),FullDate)%7)+1) IN(6,7) THEN 1 ELSE 0 END
 FROM D
 WHERE FullDate IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM dw.DimDate x WHERE x.FullDate=D.FullDate);

 INSERT INTO dw.DimCountry(CountryCode)
 SELECT DISTINCT COALESCE(NULLIF(LTRIM(RTRIM(CountryCode)),N''),N'UNKNOWN')
 FROM stg.ClickstreamRaw s
 WHERE NOT EXISTS(
   SELECT 1 FROM dw.DimCountry d
   WHERE d.CountryCode=COALESCE(NULLIF(LTRIM(RTRIM(s.CountryCode)),N''),N'UNKNOWN')
 );

 ;WITH P AS(
  SELECT DISTINCT
   MainCategory=COALESCE(NULLIF(LTRIM(RTRIM(MainCategory)),N''),N'UNKNOWN'),
   ClothingModel=COALESCE(NULLIF(LTRIM(RTRIM(ClothingModel)),N''),N'UNKNOWN'),
   Colour=COALESCE(NULLIF(LTRIM(RTRIM(Colour)),N''),N'UNKNOWN'),
   PhotoLocation=COALESCE(NULLIF(LTRIM(RTRIM(PhotoLocation)),N''),N'UNKNOWN'),
   ModelPhotography=COALESCE(NULLIF(LTRIM(RTRIM(ModelPhotography)),N''),N'UNKNOWN')
  FROM stg.ClickstreamRaw
 ), H AS(
  SELECT *,
   NaturalHash=HASHBYTES('SHA2_256',CONVERT(varbinary(max),
     MainCategory+N'|'+ClothingModel+N'|'+Colour+N'|'+PhotoLocation+N'|'+ModelPhotography))
  FROM P
 )
 INSERT INTO dw.DimProduct(NaturalHash,MainCategory,ClothingModel,Colour,PhotoLocation,ModelPhotography)
 SELECT h.NaturalHash,h.MainCategory,h.ClothingModel,h.Colour,h.PhotoLocation,h.ModelPhotography
 FROM H h
 WHERE NOT EXISTS(SELECT 1 FROM dw.DimProduct d WHERE d.NaturalHash=h.NaturalHash);

 INSERT INTO dw.DimPage(PageNo)
 SELECT DISTINCT TRY_CONVERT(int,NULLIF(PageNo,N''))
 FROM stg.ClickstreamRaw s
 WHERE TRY_CONVERT(int,NULLIF(PageNo,N'')) IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM dw.DimPage d WHERE d.PageNo=TRY_CONVERT(int,NULLIF(s.PageNo,N'')));
END
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadFact AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @BatchId int=(SELECT MAX(BatchId) FROM etl.ETLBatch);
 DELETE FROM etl.RejectedClickstream WHERE BatchId=@BatchId;

 ;WITH P AS(
  SELECT s.*,
   FullDate=TRY_CONVERT(date,CONCAT(
      RIGHT('0000'+LTRIM(RTRIM([Year])),4),'-',
      RIGHT('00'+LTRIM(RTRIM([Month])),2),'-',
      RIGHT('00'+LTRIM(RTRIM([Day])),2))),
   SessionN=TRY_CONVERT(bigint,NULLIF(SessionID,N'')),
   OrderN=TRY_CONVERT(int,NULLIF(ClickOrder,N'')),
   PriceN=TRY_CONVERT(decimal(19,4),NULLIF(Price,N'')),
   PageN=TRY_CONVERT(int,NULLIF(PageNo,N''))
  FROM stg.ClickstreamRaw s
 )
 INSERT INTO etl.RejectedClickstream(BatchId,SessionID,ClickOrder,RejectReason)
 SELECT @BatchId,SessionID,ClickOrder,
  CONCAT(
   CASE WHEN FullDate IS NULL THEN N'Invalid date; ' ELSE N'' END,
   CASE WHEN SessionN IS NULL THEN N'Invalid SessionID; ' ELSE N'' END,
   CASE WHEN OrderN IS NULL THEN N'Invalid ClickOrder; ' ELSE N'' END,
   CASE WHEN PriceN IS NULL THEN N'Invalid Price; ' ELSE N'' END,
   CASE WHEN PageN IS NULL THEN N'Invalid PageNo; ' ELSE N'' END
  )
 FROM P
 WHERE FullDate IS NULL OR SessionN IS NULL OR OrderN IS NULL OR PriceN IS NULL OR PageN IS NULL;

 ;WITH P AS(
  SELECT s.*,
   FullDate=TRY_CONVERT(date,CONCAT(
      RIGHT('0000'+LTRIM(RTRIM([Year])),4),'-',
      RIGHT('00'+LTRIM(RTRIM([Month])),2),'-',
      RIGHT('00'+LTRIM(RTRIM([Day])),2))),
   SessionN=TRY_CONVERT(bigint,NULLIF(SessionID,N'')),
   OrderN=TRY_CONVERT(int,NULLIF(ClickOrder,N'')),
   PriceN=TRY_CONVERT(decimal(19,4),NULLIF(Price,N'')),
   Price2N=TRY_CONVERT(int,NULLIF(PriceAboveCategoryAvg,N'')),
   PageN=TRY_CONVERT(int,NULLIF(PageNo,N'')),
   CountryN=COALESCE(NULLIF(LTRIM(RTRIM(CountryCode)),N''),N'UNKNOWN'),
   MainCategoryN=COALESCE(NULLIF(LTRIM(RTRIM(MainCategory)),N''),N'UNKNOWN'),
   ClothingModelN=COALESCE(NULLIF(LTRIM(RTRIM(ClothingModel)),N''),N'UNKNOWN'),
   ColourN=COALESCE(NULLIF(LTRIM(RTRIM(Colour)),N''),N'UNKNOWN'),
   PhotoLocationN=COALESCE(NULLIF(LTRIM(RTRIM(PhotoLocation)),N''),N'UNKNOWN'),
   ModelPhotographyN=COALESCE(NULLIF(LTRIM(RTRIM(ModelPhotography)),N''),N'UNKNOWN')
  FROM stg.ClickstreamRaw s
 ), H AS(
   SELECT *,
    ProductHash=HASHBYTES('SHA2_256',CONVERT(varbinary(max),
      MainCategoryN+N'|'+ClothingModelN+N'|'+ColourN+N'|'+PhotoLocationN+N'|'+ModelPhotographyN))
   FROM P
   WHERE FullDate IS NOT NULL AND SessionN IS NOT NULL AND OrderN IS NOT NULL AND PriceN IS NOT NULL AND PageN IS NOT NULL
 )
 INSERT INTO dw.FactClickstream(SessionID,ClickOrder,DateKey,CountryKey,ProductKey,PageKey,Price,PriceAboveCategoryAvg,ClickCount,LoadBatchId)
 SELECT
  h.SessionN,h.OrderN,CONVERT(int,CONVERT(char(8),h.FullDate,112)),
  c.CountryKey,p.ProductKey,pg.PageKey,h.PriceN,
  CASE WHEN h.Price2N IN(0,1) THEN CONVERT(bit,h.Price2N) ELSE NULL END,
  1,@BatchId
 FROM H h
 JOIN dw.DimCountry c ON c.CountryCode=h.CountryN
 JOIN dw.DimProduct p ON p.NaturalHash=h.ProductHash
 JOIN dw.DimPage pg ON pg.PageNo=h.PageN;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateAndCloseBatch AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @BatchId int=(SELECT MAX(BatchId) FROM etl.ETLBatch),@Expected int,@Staging int,@Rejected int,@Fact int;
 SELECT @Expected=ExpectedRows FROM etl.ETLBatch WHERE BatchId=@BatchId;
 SELECT @Staging=COUNT(*) FROM stg.ClickstreamRaw;
 SELECT @Rejected=COUNT(*) FROM etl.RejectedClickstream WHERE BatchId=@BatchId;
 SELECT @Fact=COUNT(*) FROM dw.FactClickstream WHERE LoadBatchId=@BatchId;

 DECLARE @Status varchar(30),@Note nvarchar(1000);
 IF @Staging<>@Expected BEGIN
  SET @Status='FAILED'; SET @Note=CONCAT('Staging mismatch expected=',@Expected,', staging=',@Staging);
 END
 ELSE IF @Fact+@Rejected<>@Staging BEGIN
  SET @Status='FAILED'; SET @Note=CONCAT('Accounting mismatch staging=',@Staging,', fact=',@Fact,', rejected=',@Rejected);
 END
 ELSE BEGIN
  SET @Status='SUCCEEDED'; SET @Note=CONCAT('PASS expected=',@Expected,', staging=',@Staging,', fact=',@Fact,', rejected=',@Rejected);
 END

 UPDATE etl.ETLBatch SET EndTimeUtc=SYSUTCDATETIME(),StagingRows=@Staging,FactRows=@Fact,
 RejectedRows=@Rejected,Status=@Status,ValidationNote=@Note WHERE BatchId=@BatchId;
 SELECT * FROM etl.ETLBatch WHERE BatchId=@BatchId;
 IF @Status<>'SUCCEEDED' THROW 50010,@Note,1;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ReportValidation AS
BEGIN
 SET NOCOUNT ON;
 SELECT TOP(1) * FROM etl.ETLBatch ORDER BY BatchId DESC;
 SELECT
  StagingRows=(SELECT COUNT(*) FROM stg.ClickstreamRaw),
  DimDateRows=(SELECT COUNT(*) FROM dw.DimDate),
  DimCountryRows=(SELECT COUNT(*) FROM dw.DimCountry),
  DimProductRows=(SELECT COUNT(*) FROM dw.DimProduct),
  DimPageRows=(SELECT COUNT(*) FROM dw.DimPage),
  FactRows=(SELECT COUNT(*) FROM dw.FactClickstream),
  RejectedRows=(SELECT COUNT(*) FROM etl.RejectedClickstream);

 SELECT TOP(15) c.CountryCode,Clicks=COUNT_BIG(*),AveragePrice=AVG(f.Price)
 FROM dw.FactClickstream f JOIN dw.DimCountry c ON c.CountryKey=f.CountryKey
 GROUP BY c.CountryCode ORDER BY COUNT_BIG(*) DESC;

 SELECT TOP(15) p.ClothingModel,Clicks=COUNT_BIG(*),AveragePrice=AVG(f.Price)
 FROM dw.FactClickstream f JOIN dw.DimProduct p ON p.ProductKey=f.ProductKey
 GROUP BY p.ClothingModel ORDER BY COUNT_BIG(*) DESC;
END
GO
