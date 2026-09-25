SET NOCOUNT ON;
GO
IF DB_ID(N'ClickstreamDW') IS NULL CREATE DATABASE ClickstreamDW;
GO
USE ClickstreamDW;
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'stg') EXEC(N'CREATE SCHEMA stg AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'dw') EXEC(N'CREATE SCHEMA dw AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'etl') EXEC(N'CREATE SCHEMA etl AUTHORIZATION dbo');
GO

DROP TABLE IF EXISTS dw.FactClickstream;
DROP TABLE IF EXISTS dw.DimPage;
DROP TABLE IF EXISTS dw.DimProduct;
DROP TABLE IF EXISTS dw.DimCountry;
DROP TABLE IF EXISTS dw.DimDate;
DROP TABLE IF EXISTS etl.RejectedClickstream;
DROP TABLE IF EXISTS stg.ClickstreamRaw;
DROP TABLE IF EXISTS etl.ETLBatch;
DROP TABLE IF EXISTS etl.RuntimeConfig;
GO

CREATE TABLE etl.RuntimeConfig(
 ConfigKey nvarchar(100) NOT NULL CONSTRAINT PK_RuntimeConfig PRIMARY KEY,
 ConfigValue nvarchar(4000) NULL
);
INSERT INTO etl.RuntimeConfig VALUES
 (N'SourceCsvPath',NULL),(N'ExpectedSourceRows',N'165474'),
 (N'SourceSha256',NULL),(N'SourceBytes',N'0'),
 (N'DatasetName',N'UCI Clickstream Data for Online Shopping');
GO

CREATE TABLE etl.ETLBatch(
 BatchId int IDENTITY(1,1) PRIMARY KEY,
 StartTimeUtc datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
 EndTimeUtc datetime2(0) NULL,
 DatasetName nvarchar(200) NULL,
 SourceCsvPath nvarchar(4000) NULL,
 SourceSha256 char(64) NULL,
 SourceBytes bigint NULL,
 ExpectedRows int NULL,
 StagingRows int NULL,
 FactRows int NULL,
 RejectedRows int NULL,
 Status varchar(30) NOT NULL DEFAULT 'RUNNING',
 ValidationNote nvarchar(1000) NULL
);
GO

CREATE TABLE stg.ClickstreamRaw(
 [Year] nvarchar(20) NULL,
 [Month] nvarchar(20) NULL,
 [Day] nvarchar(20) NULL,
 ClickOrder nvarchar(30) NULL,
 CountryCode nvarchar(30) NULL,
 SessionID nvarchar(50) NULL,
 MainCategory nvarchar(100) NULL,
 ClothingModel nvarchar(100) NULL,
 Colour nvarchar(100) NULL,
 PhotoLocation nvarchar(100) NULL,
 ModelPhotography nvarchar(100) NULL,
 Price nvarchar(50) NULL,
 PriceAboveCategoryAvg nvarchar(30) NULL,
 PageNo nvarchar(30) NULL
);
GO

CREATE TABLE etl.RejectedClickstream(
 RejectId bigint IDENTITY(1,1) PRIMARY KEY,
 BatchId int NOT NULL,
 SessionID nvarchar(50) NULL,
 ClickOrder nvarchar(30) NULL,
 RejectReason nvarchar(500) NOT NULL,
 RejectedAtUtc datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dw.DimDate(
 DateKey int PRIMARY KEY,
 FullDate date NOT NULL UNIQUE,
 CalendarYear smallint NOT NULL,
 CalendarQuarter tinyint NOT NULL,
 CalendarMonth tinyint NOT NULL,
 MonthName nvarchar(20) NOT NULL,
 DayOfMonth tinyint NOT NULL,
 DayOfWeekIso tinyint NOT NULL,
 DayName nvarchar(20) NOT NULL,
 IsWeekend bit NOT NULL
);
GO

CREATE TABLE dw.DimCountry(
 CountryKey int IDENTITY(1,1) PRIMARY KEY,
 CountryCode nvarchar(30) NOT NULL UNIQUE
);
GO

CREATE TABLE dw.DimProduct(
 ProductKey int IDENTITY(1,1) PRIMARY KEY,
 NaturalHash varbinary(32) NOT NULL UNIQUE,
 MainCategory nvarchar(100) NOT NULL,
 ClothingModel nvarchar(100) NOT NULL,
 Colour nvarchar(100) NOT NULL,
 PhotoLocation nvarchar(100) NOT NULL,
 ModelPhotography nvarchar(100) NOT NULL
);
GO

CREATE TABLE dw.DimPage(
 PageKey int IDENTITY(1,1) PRIMARY KEY,
 PageNo int NOT NULL UNIQUE
);
GO

CREATE TABLE dw.FactClickstream(
 ClickEventKey bigint IDENTITY(1,1) PRIMARY KEY,
 SessionID bigint NOT NULL,
 ClickOrder int NOT NULL,
 DateKey int NOT NULL,
 CountryKey int NOT NULL,
 ProductKey int NOT NULL,
 PageKey int NOT NULL,
 Price decimal(19,4) NOT NULL,
 PriceAboveCategoryAvg bit NULL,
 ClickCount tinyint NOT NULL DEFAULT 1,
 LoadBatchId int NOT NULL,
 CONSTRAINT FK_Click_Date FOREIGN KEY(DateKey) REFERENCES dw.DimDate(DateKey),
 CONSTRAINT FK_Click_Country FOREIGN KEY(CountryKey) REFERENCES dw.DimCountry(CountryKey),
 CONSTRAINT FK_Click_Product FOREIGN KEY(ProductKey) REFERENCES dw.DimProduct(ProductKey),
 CONSTRAINT FK_Click_Page FOREIGN KEY(PageKey) REFERENCES dw.DimPage(PageKey)
);
CREATE INDEX IX_Click_Date ON dw.FactClickstream(DateKey);
CREATE INDEX IX_Click_Country ON dw.FactClickstream(CountryKey);
CREATE INDEX IX_Click_Product ON dw.FactClickstream(ProductKey);
CREATE INDEX IX_Click_Session ON dw.FactClickstream(SessionID);
GO
