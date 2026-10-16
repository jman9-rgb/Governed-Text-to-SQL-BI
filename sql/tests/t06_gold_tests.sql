/* =============================================================================
   TESTS: STEP 06 GOLD STAR SCHEMA
   Gold is stored as physical tables and is filled.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('G1', 'RULE', N'gold.dim_customers is a physical table (not a view)', N'U', CAST((SELECT TOP (1) type FROM sys.objects WHERE object_id = OBJECT_ID('gold.dim_customers')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G4', 'RULE', N'gold.dim_customers has rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.dim_customers) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G2', 'RULE', N'gold.dim_products is a physical table (not a view)', N'U', CAST((SELECT TOP (1) type FROM sys.objects WHERE object_id = OBJECT_ID('gold.dim_products')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G5', 'RULE', N'gold.dim_products has rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.dim_products) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G3', 'RULE', N'gold.fact_sales is a physical table (not a view)', N'U', CAST((SELECT TOP (1) type FROM sys.objects WHERE object_id = OBJECT_ID('gold.fact_sales')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G6', 'RULE', N'gold.fact_sales has rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.fact_sales) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G7', 'RULE', N'gold.sp_load_gold exists', N'1', CAST((SELECT CASE WHEN OBJECT_ID('gold.sp_load_gold') IS NOT NULL THEN 1 ELSE 0 END) AS NVARCHAR(200)));

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
