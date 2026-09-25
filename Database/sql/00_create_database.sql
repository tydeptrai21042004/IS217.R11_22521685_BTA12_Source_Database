SET NOCOUNT ON;
GO
IF DB_ID(N'RetailDW') IS NULL CREATE DATABASE RetailDW;
GO
USE RetailDW;
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'stg') EXEC(N'CREATE SCHEMA stg AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'dw') EXEC(N'CREATE SCHEMA dw AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'etl') EXEC(N'CREATE SCHEMA etl AUTHORIZATION dbo');
GO
DROP TABLE IF EXISTS dw.FactSalesLine;
DROP TABLE IF EXISTS dw.DimCountry;
DROP TABLE IF EXISTS dw.DimCustomer;
DROP TABLE IF EXISTS dw.DimProduct;
DROP TABLE IF EXISTS dw.DimDate;
DROP TABLE IF EXISTS etl.RejectedRetail;
DROP TABLE IF EXISTS stg.OnlineRetailRaw;
DROP TABLE IF EXISTS etl.ETLBatch;
DROP TABLE IF EXISTS etl.RuntimeConfig;
GO
CREATE TABLE etl.RuntimeConfig(
 ConfigKey nvarchar(100) NOT NULL CONSTRAINT PK_RuntimeConfig PRIMARY KEY,
 ConfigValue nvarchar(4000) NULL
);
INSERT INTO etl.RuntimeConfig VALUES
 (N'SourceCsvPath',NULL),(N'ExpectedSourceRows',N'0'),(N'SourceSha256',NULL),
 (N'SourceBytes',N'0'),(N'DatasetName',N'UCI Online Retail');
GO
CREATE TABLE etl.ETLBatch(
 BatchId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ETLBatch PRIMARY KEY,
 StartTimeUtc datetime2(0) NOT NULL CONSTRAINT DF_ETLBatch_Start DEFAULT SYSUTCDATETIME(),
 EndTimeUtc datetime2(0) NULL, DatasetName nvarchar(200) NULL,
 SourceCsvPath nvarchar(4000) NULL, SourceSha256 char(64) NULL, SourceBytes bigint NULL,
 ExpectedRows int NULL, StagingRows int NULL, FactRows int NULL, RejectedRows int NULL,
 Status varchar(30) NOT NULL CONSTRAINT DF_ETLBatch_Status DEFAULT 'RUNNING',
 ValidationNote nvarchar(1000) NULL
);
GO
CREATE TABLE stg.OnlineRetailRaw(
 InvoiceNo nvarchar(40) NULL, StockCode nvarchar(80) NULL, Description nvarchar(500) NULL,
 Quantity nvarchar(50) NULL, InvoiceDate nvarchar(80) NULL, UnitPrice nvarchar(80) NULL,
 CustomerID nvarchar(80) NULL, Country nvarchar(200) NULL
);
GO
CREATE TABLE etl.RejectedRetail(
 RejectId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RejectedRetail PRIMARY KEY,
 BatchId int NOT NULL, InvoiceNo nvarchar(40) NULL, StockCode nvarchar(80) NULL,
 InvoiceDateRaw nvarchar(80) NULL, RejectReason nvarchar(500) NOT NULL,
 RejectedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_RejectedRetail_Time DEFAULT SYSUTCDATETIME()
);
GO
CREATE TABLE dw.DimDate(
 DateKey int NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY, FullDate date NOT NULL CONSTRAINT UQ_DimDate UNIQUE,
 CalendarYear smallint NOT NULL, CalendarQuarter tinyint NOT NULL, CalendarMonth tinyint NOT NULL,
 MonthName nvarchar(20) NOT NULL, DayOfMonth tinyint NOT NULL, DayOfWeekIso tinyint NOT NULL,
 DayName nvarchar(20) NOT NULL, IsWeekend bit NOT NULL
);
GO
CREATE TABLE dw.DimProduct(
 ProductKey int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimProduct PRIMARY KEY,
 StockCode nvarchar(80) NOT NULL CONSTRAINT UQ_DimProduct_StockCode UNIQUE,
 ProductName nvarchar(500) NOT NULL
);
GO
CREATE TABLE dw.DimCustomer(
 CustomerKey int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCustomer PRIMARY KEY,
 CustomerID nvarchar(80) NOT NULL CONSTRAINT UQ_DimCustomer_CustomerID UNIQUE,
 IsKnownCustomer bit NOT NULL
);
GO
CREATE TABLE dw.DimCountry(
 CountryKey int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCountry PRIMARY KEY,
 CountryName nvarchar(200) NOT NULL CONSTRAINT UQ_DimCountry_CountryName UNIQUE
);
GO
CREATE TABLE dw.FactSalesLine(
 SalesLineKey bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactSalesLine PRIMARY KEY,
 InvoiceNo nvarchar(40) NOT NULL,
 DateKey int NOT NULL, ProductKey int NOT NULL, CustomerKey int NOT NULL, CountryKey int NOT NULL,
 InvoiceDateTime datetime2(0) NOT NULL, Quantity int NOT NULL, UnitPrice decimal(19,4) NOT NULL,
 LineAmount decimal(19,4) NOT NULL, IsCancellation bit NOT NULL,
 LineCount tinyint NOT NULL CONSTRAINT DF_Fact_LineCount DEFAULT 1,
 LoadBatchId int NOT NULL,
 CONSTRAINT FK_Fact_Date FOREIGN KEY(DateKey) REFERENCES dw.DimDate(DateKey),
 CONSTRAINT FK_Fact_Product FOREIGN KEY(ProductKey) REFERENCES dw.DimProduct(ProductKey),
 CONSTRAINT FK_Fact_Customer FOREIGN KEY(CustomerKey) REFERENCES dw.DimCustomer(CustomerKey),
 CONSTRAINT FK_Fact_Country FOREIGN KEY(CountryKey) REFERENCES dw.DimCountry(CountryKey)
);
CREATE INDEX IX_Fact_Date ON dw.FactSalesLine(DateKey);
CREATE INDEX IX_Fact_Product ON dw.FactSalesLine(ProductKey);
CREATE INDEX IX_Fact_Customer ON dw.FactSalesLine(CustomerKey);
CREATE INDEX IX_Fact_Country ON dw.FactSalesLine(CountryKey);
CREATE INDEX IX_Fact_InvoiceNo ON dw.FactSalesLine(InvoiceNo);
GO
