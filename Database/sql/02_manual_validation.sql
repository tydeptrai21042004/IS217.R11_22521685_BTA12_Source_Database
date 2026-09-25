USE RetailDW;
GO
EXEC etl.usp_ReportValidation;
GO
SELECT BatchId,ExpectedRows,StagingRows,FactRows,RejectedRows,AccountedRows=FactRows+RejectedRows,
 IsComplete=CASE WHEN ExpectedRows=StagingRows AND StagingRows=FactRows+RejectedRows THEN 1 ELSE 0 END,
 Status,ValidationNote FROM etl.ETLBatch ORDER BY BatchId DESC;
GO
SELECT InvalidFKs=COUNT(*) FROM dw.FactSalesLine f
LEFT JOIN dw.DimDate d ON d.DateKey=f.DateKey
LEFT JOIN dw.DimProduct p ON p.ProductKey=f.ProductKey
LEFT JOIN dw.DimCustomer c ON c.CustomerKey=f.CustomerKey
LEFT JOIN dw.DimCountry co ON co.CountryKey=f.CountryKey
WHERE d.DateKey IS NULL OR p.ProductKey IS NULL OR c.CustomerKey IS NULL OR co.CountryKey IS NULL;
GO
SELECT CancellationLines=SUM(CASE WHEN IsCancellation=1 THEN 1 ELSE 0 END),
 ReturnLines=SUM(CASE WHEN Quantity<0 THEN 1 ELSE 0 END), NetRevenue=SUM(LineAmount)
FROM dw.FactSalesLine;
GO
