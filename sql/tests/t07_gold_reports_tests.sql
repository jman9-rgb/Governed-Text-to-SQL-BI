/* =============================================================================
   TESTS: STEP 07 GOLD REPORT VIEWS
   The two report views exist and return rows. Step 08 builds on them.
   Prints a PASS / FAIL table, then one summary line.
     RULE  must always pass.
     SEED  true right after this step; a later step may change it legitimately.
     DATA  depends on the source data you loaded; DIFF only means your data differs.
   ============================================================================= */
USE DataWarehouse;
GO
SET NOCOUNT ON;
DROP TABLE IF EXISTS #t;
CREATE TABLE #t (
    n        INT IDENTITY(1,1),
    id       VARCHAR(12)   NOT NULL,
    kind     VARCHAR(4)    NOT NULL,
    test     NVARCHAR(200) NOT NULL,
    expected NVARCHAR(200) NOT NULL,
    actual   NVARCHAR(200) NULL,
    ok AS (CASE WHEN expected = ISNULL(actual, N'<NULL>') THEN 1 ELSE 0 END)
);
GO

INSERT #t (id, kind, test, expected, actual) VALUES ('R1', 'RULE', N'gold.report_customers is a view', N'V', CAST((SELECT TOP (1) type FROM sys.objects WHERE object_id = OBJECT_ID('gold.report_customers')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('R3', 'RULE', N'gold.report_customers has rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.report_customers) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('R2', 'RULE', N'gold.report_products is a view', N'V', CAST((SELECT TOP (1) type FROM sys.objects WHERE object_id = OBJECT_ID('gold.report_products')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('R4', 'RULE', N'gold.report_products has rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.report_products) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));

SELECT id, kind, test, expected, actual,
       CASE WHEN ok = 1 THEN 'PASS' WHEN kind = 'RULE' THEN 'FAIL' ELSE 'DIFF' END AS result
FROM #t ORDER BY n;

SELECT COUNT(*) AS tests, SUM(ok) AS passed,
       SUM(CASE WHEN ok = 0 AND kind = 'RULE' THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN ok = 0 AND kind <> 'RULE' THEN 1 ELSE 0 END) AS diffs
FROM #t;

IF EXISTS (SELECT 1 FROM #t WHERE ok = 0 AND kind = 'RULE')
    SELECT 'FAILED RULE TEST' AS problem, id, test, expected, actual FROM #t WHERE ok = 0 AND kind = 'RULE';

IF EXISTS (SELECT 1 FROM #t WHERE ok = 0 AND kind = 'RULE')
    RAISERROR(N'At least one RULE test failed: see the FAIL rows above.', 11, 1);
GO
