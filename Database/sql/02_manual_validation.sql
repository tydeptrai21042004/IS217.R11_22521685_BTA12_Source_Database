USE ClickstreamDW;
GO
EXEC etl.usp_ReportValidation;
GO
SELECT BatchId,ExpectedRows,StagingRows,FactRows,RejectedRows,
       AccountedRows=FactRows+RejectedRows,
       IsComplete=CASE WHEN ExpectedRows=StagingRows AND StagingRows=FactRows+RejectedRows THEN 1 ELSE 0 END,
       Status,ValidationNote
FROM etl.ETLBatch
ORDER BY BatchId DESC;
GO
