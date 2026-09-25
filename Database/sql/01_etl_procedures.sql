USE NYC311_DW;
GO

CREATE OR ALTER PROCEDURE etl.usp_BeginBatch
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.ETLBatch
    (
        DatasetDate, SourceCsvPath, SourceSha256, ExpectedRows, Status
    )
    SELECT
        TRY_CONVERT(date, MAX(CASE WHEN ConfigKey=N'DatasetDate' THEN ConfigValue END)),
        MAX(CASE WHEN ConfigKey=N'SourceCsvPath' THEN ConfigValue END),
        MAX(CASE WHEN ConfigKey=N'SourceSha256' THEN ConfigValue END),
        TRY_CONVERT(int, MAX(CASE WHEN ConfigKey=N'ExpectedSourceRows' THEN ConfigValue END)),
        'RUNNING'
    FROM etl.RuntimeConfig;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadStaging
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Path nvarchar(4000) =
        (SELECT ConfigValue FROM etl.RuntimeConfig WHERE ConfigKey=N'SourceCsvPath');

    IF @Path IS NULL OR LTRIM(RTRIM(@Path)) = N''
        THROW 50001, 'SourceCsvPath is not configured.', 1;

    TRUNCATE TABLE stg.NYC311Raw;

    DECLARE @sql nvarchar(max) =
        N'BULK INSERT stg.NYC311Raw FROM ''' +
        REPLACE(@Path,'''','''''') +
        N''' WITH (' +
        N'FORMAT = ''CSV'', ' +
        N'FIRSTROW = 2, ' +
        N'FIELDQUOTE = ''"'', ' +
        N'CODEPAGE = ''65001'', ' +
        N'ROWTERMINATOR = ''0x0a'', ' +
        N'TABLOCK' +
        N');';

    EXEC sys.sp_executesql @sql;

    -- Strip UTF-8 BOM if it survived in first field.
    UPDATE stg.NYC311Raw
    SET UniqueKey = REPLACE(UniqueKey, NCHAR(65279), N'')
    WHERE UniqueKey LIKE N'%' + NCHAR(65279) + N'%';
END
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadDimensions
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BatchId int = (SELECT MAX(BatchId) FROM etl.ETLBatch);

    ;WITH Parsed AS
    (
        SELECT
            TRY_CONVERT(datetime2(0), NULLIF(CreatedDate,N''), 126) CreatedDT,
            TRY_CONVERT(datetime2(0), NULLIF(ClosedDate,N''), 126) ClosedDT
        FROM stg.NYC311Raw
    ),
    Dates AS
    (
        SELECT CONVERT(date, CreatedDT) FullDate FROM Parsed WHERE CreatedDT IS NOT NULL
        UNION
        SELECT CONVERT(date, ClosedDT) FROM Parsed WHERE ClosedDT IS NOT NULL
    )
    INSERT INTO dw.DimDate
    (
        DateKey, FullDate, CalendarYear, CalendarQuarter, CalendarMonth,
        MonthName, DayOfMonth, DayOfWeekIso, DayName, IsWeekend
    )
    SELECT
        CONVERT(int, CONVERT(char(8), d.FullDate, 112)),
        d.FullDate,
        YEAR(d.FullDate),
        DATEPART(QUARTER, d.FullDate),
        MONTH(d.FullDate),
        DATENAME(MONTH, d.FullDate),
        DAY(d.FullDate),
        ((DATEDIFF(day, CONVERT(date,'19000101'), d.FullDate) % 7) + 1),
        DATENAME(WEEKDAY, d.FullDate),
        CASE WHEN ((DATEDIFF(day, CONVERT(date,'19000101'), d.FullDate) % 7) + 1) IN (6,7)
             THEN 1 ELSE 0 END
    FROM Dates d
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimDate x WHERE x.FullDate=d.FullDate);

    INSERT INTO dw.DimAgency(AgencyCode, AgencyName)
    SELECT DISTINCT
        COALESCE(NULLIF(LTRIM(RTRIM(Agency)),N''), N'UNKNOWN'),
        COALESCE(NULLIF(LTRIM(RTRIM(AgencyName)),N''), N'UNKNOWN')
    FROM stg.NYC311Raw s
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dw.DimAgency d
        WHERE d.AgencyCode = COALESCE(NULLIF(LTRIM(RTRIM(s.Agency)),N''), N'UNKNOWN')
          AND d.AgencyName = COALESCE(NULLIF(LTRIM(RTRIM(s.AgencyName)),N''), N'UNKNOWN')
    );

    ;WITH C AS
    (
        SELECT DISTINCT
            ComplaintType = COALESCE(NULLIF(LTRIM(RTRIM(ComplaintType)),N''), N'UNKNOWN'),
            Descriptor    = COALESCE(NULLIF(LTRIM(RTRIM(Descriptor)),N''), N'UNKNOWN')
        FROM stg.NYC311Raw
    ),
    H AS
    (
        SELECT *,
            NaturalHash = HASHBYTES(
                'SHA2_256',
                CONVERT(varbinary(max), ComplaintType + N'|' + Descriptor)
            )
        FROM C
    )
    INSERT INTO dw.DimComplaint(NaturalHash, ComplaintType, Descriptor)
    SELECT h.NaturalHash, h.ComplaintType, h.Descriptor
    FROM H h
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dw.DimComplaint d WHERE d.NaturalHash=h.NaturalHash
    );

    ;WITH L AS
    (
        SELECT DISTINCT
            IncidentZip  = COALESCE(NULLIF(LTRIM(RTRIM(IncidentZip)),N''), N'UNKNOWN'),
            City         = COALESCE(NULLIF(LTRIM(RTRIM(City)),N''), N'UNKNOWN'),
            Borough      = COALESCE(NULLIF(LTRIM(RTRIM(Borough)),N''), N'UNKNOWN'),
            LocationType = COALESCE(NULLIF(LTRIM(RTRIM(LocationType)),N''), N'UNKNOWN'),
            Latitude     = TRY_CONVERT(decimal(10,7), NULLIF(Latitude,N'')),
            Longitude    = TRY_CONVERT(decimal(10,7), NULLIF(Longitude,N''))
        FROM stg.NYC311Raw
    ),
    H AS
    (
        SELECT *,
            NaturalHash = HASHBYTES(
                'SHA2_256',
                CONVERT(
                    varbinary(max),
                    IncidentZip + N'|' + City + N'|' + Borough + N'|' + LocationType + N'|' +
                    COALESCE(CONVERT(nvarchar(40),Latitude),N'') + N'|' +
                    COALESCE(CONVERT(nvarchar(40),Longitude),N'')
                )
            )
        FROM L
    )
    INSERT INTO dw.DimLocation
    (
        NaturalHash, IncidentZip, City, Borough, LocationType, Latitude, Longitude
    )
    SELECT
        h.NaturalHash, h.IncidentZip, h.City, h.Borough, h.LocationType, h.Latitude, h.Longitude
    FROM H h
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dw.DimLocation d WHERE d.NaturalHash=h.NaturalHash
    );
END
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadFact
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BatchId int = (SELECT MAX(BatchId) FROM etl.ETLBatch);

    DELETE FROM etl.Rejected311 WHERE BatchId=@BatchId;

    ;WITH P AS
    (
        SELECT
            s.*,
            CreatedDT = TRY_CONVERT(datetime2(0), NULLIF(s.CreatedDate,N''), 126),
            ClosedDT  = TRY_CONVERT(datetime2(0), NULLIF(s.ClosedDate,N''), 126)
        FROM stg.NYC311Raw s
    )
    INSERT INTO etl.Rejected311
    (
        BatchId, UniqueKey, RejectReason, CreatedDateRaw, ClosedDateRaw
    )
    SELECT
        @BatchId,
        UniqueKey,
        CONCAT(
            CASE WHEN NULLIF(LTRIM(RTRIM(UniqueKey)),N'') IS NULL
                 THEN N'Missing UniqueKey; ' ELSE N'' END,
            CASE WHEN CreatedDT IS NULL
                 THEN N'Invalid/missing CreatedDate; ' ELSE N'' END
        ),
        CreatedDate,
        ClosedDate
    FROM P
    WHERE NULLIF(LTRIM(RTRIM(UniqueKey)),N'') IS NULL
       OR CreatedDT IS NULL;

    ;WITH P AS
    (
        SELECT
            s.*,
            CreatedDT = TRY_CONVERT(datetime2(0), NULLIF(s.CreatedDate,N''), 126),
            ClosedDT  = TRY_CONVERT(datetime2(0), NULLIF(s.ClosedDate,N''), 126),
            AgencyCodeN = COALESCE(NULLIF(LTRIM(RTRIM(s.Agency)),N''), N'UNKNOWN'),
            AgencyNameN = COALESCE(NULLIF(LTRIM(RTRIM(s.AgencyName)),N''), N'UNKNOWN'),
            ComplaintTypeN = COALESCE(NULLIF(LTRIM(RTRIM(s.ComplaintType)),N''), N'UNKNOWN'),
            DescriptorN = COALESCE(NULLIF(LTRIM(RTRIM(s.Descriptor)),N''), N'UNKNOWN'),
            IncidentZipN = COALESCE(NULLIF(LTRIM(RTRIM(s.IncidentZip)),N''), N'UNKNOWN'),
            CityN = COALESCE(NULLIF(LTRIM(RTRIM(s.City)),N''), N'UNKNOWN'),
            BoroughN = COALESCE(NULLIF(LTRIM(RTRIM(s.Borough)),N''), N'UNKNOWN'),
            LocationTypeN = COALESCE(NULLIF(LTRIM(RTRIM(s.LocationType)),N''), N'UNKNOWN'),
            LatitudeN = TRY_CONVERT(decimal(10,7), NULLIF(s.Latitude,N'')),
            LongitudeN = TRY_CONVERT(decimal(10,7), NULLIF(s.Longitude,N''))
        FROM stg.NYC311Raw s
    ),
    K AS
    (
        SELECT *,
            ComplaintHash = HASHBYTES(
                'SHA2_256',
                CONVERT(varbinary(max), ComplaintTypeN + N'|' + DescriptorN)
            ),
            LocationHash = HASHBYTES(
                'SHA2_256',
                CONVERT(
                    varbinary(max),
                    IncidentZipN + N'|' + CityN + N'|' + BoroughN + N'|' + LocationTypeN + N'|' +
                    COALESCE(CONVERT(nvarchar(40),LatitudeN),N'') + N'|' +
                    COALESCE(CONVERT(nvarchar(40),LongitudeN),N'')
                )
            )
        FROM P
        WHERE NULLIF(LTRIM(RTRIM(UniqueKey)),N'') IS NOT NULL
          AND CreatedDT IS NOT NULL
    )
    INSERT INTO dw.Fact311Request
    (
        UniqueKey, CreatedDateKey, ClosedDateKey,
        AgencyKey, ComplaintKey, LocationKey,
        CreatedDateTime, ClosedDateTime, Status,
        ResolutionMinutes, RequestCount, LoadBatchId
    )
    SELECT
        k.UniqueKey,
        CONVERT(int, CONVERT(char(8), CONVERT(date,k.CreatedDT),112)),
        CASE WHEN k.ClosedDT IS NULL THEN NULL
             ELSE CONVERT(int, CONVERT(char(8), CONVERT(date,k.ClosedDT),112)) END,
        a.AgencyKey,
        c.ComplaintKey,
        l.LocationKey,
        k.CreatedDT,
        k.ClosedDT,
        COALESCE(NULLIF(LTRIM(RTRIM(k.Status)),N''),N'UNKNOWN'),
        CASE
            WHEN k.ClosedDT IS NULL OR k.ClosedDT < k.CreatedDT THEN NULL
            ELSE DATEDIFF(MINUTE, k.CreatedDT, k.ClosedDT)
        END,
        1,
        @BatchId
    FROM K k
    INNER JOIN dw.DimAgency a
        ON a.AgencyCode=k.AgencyCodeN AND a.AgencyName=k.AgencyNameN
    INNER JOIN dw.DimComplaint c
        ON c.NaturalHash=k.ComplaintHash
    INNER JOIN dw.DimLocation l
        ON l.NaturalHash=k.LocationHash
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dw.Fact311Request f WHERE f.UniqueKey=k.UniqueKey
    );
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateAndCloseBatch
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BatchId int = (SELECT MAX(BatchId) FROM etl.ETLBatch);
    DECLARE @Expected int = (SELECT ExpectedRows FROM etl.ETLBatch WHERE BatchId=@BatchId);
    DECLARE @Staging int = (SELECT COUNT(*) FROM stg.NYC311Raw);
    DECLARE @Rejected int = (SELECT COUNT(*) FROM etl.Rejected311 WHERE BatchId=@BatchId);
    DECLARE @FactForBatch int = (SELECT COUNT(*) FROM dw.Fact311Request WHERE LoadBatchId=@BatchId);

    DECLARE @Status varchar(30);
    DECLARE @Note nvarchar(1000);

    IF @Staging <> @Expected
    BEGIN
        SET @Status='FAILED';
        SET @Note=CONCAT('Staging row mismatch. expected=',@Expected,', staging=',@Staging);
    END
    ELSE IF (@FactForBatch + @Rejected) <> @Staging
    BEGIN
        SET @Status='FAILED';
        SET @Note=CONCAT(
            'Accounting mismatch. staging=',@Staging,
            ', fact_for_batch=',@FactForBatch,
            ', rejected=',@Rejected
        );
    END
    ELSE
    BEGIN
        SET @Status='SUCCEEDED';
        SET @Note=CONCAT(
            'PASS. expected=',@Expected,
            ', staging=',@Staging,
            ', fact_for_batch=',@FactForBatch,
            ', rejected=',@Rejected
        );
    END

    UPDATE etl.ETLBatch
    SET EndTimeUtc=SYSUTCDATETIME(),
        StagingRows=@Staging,
        FactRows=@FactForBatch,
        RejectedRows=@Rejected,
        Status=@Status,
        ValidationNote=@Note
    WHERE BatchId=@BatchId;

    SELECT * FROM etl.ETLBatch WHERE BatchId=@BatchId;

    IF @Status <> 'SUCCEEDED'
        THROW 50010, @Note, 1;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ReportValidation
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) *
    FROM etl.ETLBatch
    ORDER BY BatchId DESC;

    SELECT
        StagingRows = (SELECT COUNT(*) FROM stg.NYC311Raw),
        DimDateRows = (SELECT COUNT(*) FROM dw.DimDate),
        DimAgencyRows = (SELECT COUNT(*) FROM dw.DimAgency),
        DimComplaintRows = (SELECT COUNT(*) FROM dw.DimComplaint),
        DimLocationRows = (SELECT COUNT(*) FROM dw.DimLocation),
        FactRows = (SELECT COUNT(*) FROM dw.Fact311Request),
        RejectedRows = (SELECT COUNT(*) FROM etl.Rejected311);

    SELECT TOP (15)
        a.AgencyCode,
        RequestCount = COUNT_BIG(*),
        AvgResolutionMinutes = AVG(CONVERT(bigint,f.ResolutionMinutes))
    FROM dw.Fact311Request f
    INNER JOIN dw.DimAgency a ON a.AgencyKey=f.AgencyKey
    GROUP BY a.AgencyCode
    ORDER BY COUNT_BIG(*) DESC;

    SELECT TOP (15)
        c.ComplaintType,
        RequestCount = COUNT_BIG(*)
    FROM dw.Fact311Request f
    INNER JOIN dw.DimComplaint c ON c.ComplaintKey=f.ComplaintKey
    GROUP BY c.ComplaintType
    ORDER BY COUNT_BIG(*) DESC;
END
GO
