/* =============================================================================
   TESTS: STEP 10 BUSINESS CONTEXT
   Context tables are filled and agree with the data.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('C1', 'RULE', N'business context has active items', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.business_context WHERE is_active = 1) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C2', 'SEED', N'open "<<CONFIRM" items still in the context', N'0', CAST((SELECT COUNT(*) FROM genbi.business_context WHERE context_value LIKE '%<<CONFIRM%') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C3', 'RULE', N'semantic views without a view_context row', N'0', CAST((SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS v LEFT JOIN genbi.view_context c ON c.view_name = v.TABLE_NAME COLLATE DATABASE_DEFAULT WHERE v.TABLE_SCHEMA = 'semantic' AND c.view_name IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C4', 'RULE', N'vw_data_range.last_order_date = latest date in vw_sales', N'1', CAST((SELECT CASE WHEN (SELECT last_order_date FROM semantic.vw_data_range) = (SELECT MAX(order_date) FROM semantic.vw_sales) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C5', 'RULE', N'the business-context prompt block is not empty', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_prompt_business_context) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));

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
