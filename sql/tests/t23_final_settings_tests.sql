/* =============================================================================
   TESTS: STEP 23 FINAL SETTINGS
   The daily call limit matches the free-tier quota. Raise it on evaluation days, then set it back to 20.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('Z1', 'SEED', N'daily AI call limit (free tier)', N'20', CAST((SELECT limit_value FROM genbi.guardrail WHERE guardrail_name = N'daily_ai_calls') AS NVARCHAR(200)));

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
