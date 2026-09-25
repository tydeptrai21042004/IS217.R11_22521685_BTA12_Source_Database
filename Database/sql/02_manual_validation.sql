USE NYC311_DW;
GO

EXEC etl.usp_ReportValidation;
GO

-- Completeness: staging must equal API expected count.
SELECT
    b.BatchId,
    b.ExpectedRows,
    b.StagingRows,
    b.FactRows,
    b.RejectedRows,
    AccountedRows = b.FactRows + b.RejectedRows,
    IsComplete =
        CASE
            WHEN b.ExpectedRows = b.StagingRows
             AND b.StagingRows = b.FactRows + b.RejectedRows
            THEN 1 ELSE 0
        END,
    b.Status,
    b.ValidationNote
FROM etl.ETLBatch b
ORDER BY b.BatchId DESC;
GO

-- Fact grain must be one row per source UniqueKey.
SELECT UniqueKey, COUNT(*) DuplicateCount
FROM dw.Fact311Request
GROUP BY UniqueKey
HAVING COUNT(*) > 1;
GO

-- Foreign key lookup should be complete for all facts.
SELECT
    MissingCreatedDate = SUM(CASE WHEN cd.DateKey IS NULL THEN 1 ELSE 0 END),
    MissingAgency = SUM(CASE WHEN a.AgencyKey IS NULL THEN 1 ELSE 0 END),
    MissingComplaint = SUM(CASE WHEN c.ComplaintKey IS NULL THEN 1 ELSE 0 END),
    MissingLocation = SUM(CASE WHEN l.LocationKey IS NULL THEN 1 ELSE 0 END)
FROM dw.Fact311Request f
LEFT JOIN dw.DimDate cd ON cd.DateKey=f.CreatedDateKey
LEFT JOIN dw.DimAgency a ON a.AgencyKey=f.AgencyKey
LEFT JOIN dw.DimComplaint c ON c.ComplaintKey=f.ComplaintKey
LEFT JOIN dw.DimLocation l ON l.LocationKey=f.LocationKey;
GO
