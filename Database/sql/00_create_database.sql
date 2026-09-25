SET NOCOUNT ON;
GO

IF DB_ID(N'NYC311_DW') IS NULL
BEGIN
    CREATE DATABASE NYC311_DW;
END
GO

USE NYC311_DW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'stg')
    EXEC(N'CREATE SCHEMA stg AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dw')
    EXEC(N'CREATE SCHEMA dw AUTHORIZATION dbo');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'etl')
    EXEC(N'CREATE SCHEMA etl AUTHORIZATION dbo');
GO

-- Recreate assignment objects for a deterministic rerun.
DROP TABLE IF EXISTS dw.Fact311Request;
DROP TABLE IF EXISTS dw.DimLocation;
DROP TABLE IF EXISTS dw.DimComplaint;
DROP TABLE IF EXISTS dw.DimAgency;
DROP TABLE IF EXISTS dw.DimDate;
DROP TABLE IF EXISTS etl.Rejected311;
DROP TABLE IF EXISTS stg.NYC311Raw;
DROP TABLE IF EXISTS etl.ETLBatch;
DROP TABLE IF EXISTS etl.RuntimeConfig;
GO

CREATE TABLE etl.RuntimeConfig
(
    ConfigKey   nvarchar(100)  NOT NULL CONSTRAINT PK_RuntimeConfig PRIMARY KEY,
    ConfigValue nvarchar(4000) NULL
);
GO

INSERT INTO etl.RuntimeConfig(ConfigKey, ConfigValue)
VALUES
(N'SourceCsvPath', NULL),
(N'ExpectedSourceRows', N'0'),
(N'SourceSha256', NULL),
(N'DatasetDate', NULL);
GO

CREATE TABLE etl.ETLBatch
(
    BatchId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ETLBatch PRIMARY KEY,
    StartTimeUtc     datetime2(0) NOT NULL CONSTRAINT DF_ETLBatch_Start DEFAULT SYSUTCDATETIME(),
    EndTimeUtc       datetime2(0) NULL,
    DatasetDate      date NULL,
    SourceCsvPath    nvarchar(4000) NULL,
    SourceSha256     char(64) NULL,
    ExpectedRows     int NULL,
    StagingRows      int NULL,
    FactRows         int NULL,
    RejectedRows     int NULL,
    Status           varchar(30) NOT NULL CONSTRAINT DF_ETLBatch_Status DEFAULT 'RUNNING',
    ValidationNote   nvarchar(1000) NULL
);
GO

CREATE TABLE stg.NYC311Raw
(
    UniqueKey       nvarchar(64)  NULL,
    CreatedDate     nvarchar(64)  NULL,
    ClosedDate      nvarchar(64)  NULL,
    Agency          nvarchar(50)  NULL,
    AgencyName      nvarchar(300) NULL,
    ComplaintType   nvarchar(300) NULL,
    Descriptor      nvarchar(500) NULL,
    LocationType    nvarchar(300) NULL,
    IncidentZip     nvarchar(20)  NULL,
    City            nvarchar(200) NULL,
    Borough         nvarchar(100) NULL,
    Status          nvarchar(100) NULL,
    Latitude        nvarchar(64)  NULL,
    Longitude       nvarchar(64)  NULL
);
GO

CREATE TABLE etl.Rejected311
(
    RejectId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Rejected311 PRIMARY KEY,
    BatchId        int NOT NULL,
    UniqueKey      nvarchar(64) NULL,
    RejectReason   nvarchar(500) NOT NULL,
    CreatedDateRaw nvarchar(64) NULL,
    ClosedDateRaw  nvarchar(64) NULL,
    RejectedAtUtc  datetime2(0) NOT NULL CONSTRAINT DF_Rejected311_Time DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dw.DimDate
(
    DateKey       int NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,
    FullDate      date NOT NULL CONSTRAINT UQ_DimDate_FullDate UNIQUE,
    CalendarYear  smallint NOT NULL,
    CalendarQuarter tinyint NOT NULL,
    CalendarMonth tinyint NOT NULL,
    MonthName     nvarchar(20) NOT NULL,
    DayOfMonth    tinyint NOT NULL,
    DayOfWeekIso  tinyint NOT NULL,
    DayName       nvarchar(20) NOT NULL,
    IsWeekend     bit NOT NULL
);
GO

CREATE TABLE dw.DimAgency
(
    AgencyKey   int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimAgency PRIMARY KEY,
    AgencyCode  nvarchar(50) NOT NULL,
    AgencyName  nvarchar(300) NOT NULL,
    CONSTRAINT UQ_DimAgency UNIQUE (AgencyCode, AgencyName)
);
GO

CREATE TABLE dw.DimComplaint
(
    ComplaintKey  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimComplaint PRIMARY KEY,
    NaturalHash   varbinary(32) NOT NULL,
    ComplaintType nvarchar(300) NOT NULL,
    Descriptor    nvarchar(500) NOT NULL,
    CONSTRAINT UQ_DimComplaint_Hash UNIQUE (NaturalHash)
);
GO

CREATE TABLE dw.DimLocation
(
    LocationKey  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimLocation PRIMARY KEY,
    NaturalHash  varbinary(32) NOT NULL,
    IncidentZip  nvarchar(20) NOT NULL,
    City         nvarchar(200) NOT NULL,
    Borough      nvarchar(100) NOT NULL,
    LocationType nvarchar(300) NOT NULL,
    Latitude     decimal(10,7) NULL,
    Longitude    decimal(10,7) NULL,
    CONSTRAINT UQ_DimLocation_Hash UNIQUE (NaturalHash)
);
GO

CREATE TABLE dw.Fact311Request
(
    RequestKey         bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Fact311Request PRIMARY KEY,
    UniqueKey          nvarchar(64) NOT NULL CONSTRAINT UQ_Fact311Request_UniqueKey UNIQUE,
    CreatedDateKey     int NOT NULL,
    ClosedDateKey      int NULL,
    AgencyKey          int NOT NULL,
    ComplaintKey       int NOT NULL,
    LocationKey        int NOT NULL,
    CreatedDateTime    datetime2(0) NOT NULL,
    ClosedDateTime     datetime2(0) NULL,
    Status             nvarchar(100) NOT NULL,
    ResolutionMinutes  int NULL,
    RequestCount       tinyint NOT NULL CONSTRAINT DF_Fact311Request_Count DEFAULT 1,
    LoadBatchId        int NOT NULL,
    CONSTRAINT FK_Fact_CreatedDate FOREIGN KEY (CreatedDateKey) REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_Fact_ClosedDate FOREIGN KEY (ClosedDateKey) REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_Fact_Agency FOREIGN KEY (AgencyKey) REFERENCES dw.DimAgency(AgencyKey),
    CONSTRAINT FK_Fact_Complaint FOREIGN KEY (ComplaintKey) REFERENCES dw.DimComplaint(ComplaintKey),
    CONSTRAINT FK_Fact_Location FOREIGN KEY (LocationKey) REFERENCES dw.DimLocation(LocationKey)
);
GO

CREATE INDEX IX_Fact311_CreatedDateKey ON dw.Fact311Request(CreatedDateKey);
CREATE INDEX IX_Fact311_AgencyKey ON dw.Fact311Request(AgencyKey);
CREATE INDEX IX_Fact311_ComplaintKey ON dw.Fact311Request(ComplaintKey);
CREATE INDEX IX_Fact311_LocationKey ON dw.Fact311Request(LocationKey);
GO
