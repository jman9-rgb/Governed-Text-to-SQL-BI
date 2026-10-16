/* =============================================================================
   TESTS: STEP 14 GOLDEN QUESTIONS
   The test set is complete, approved and covers the glossary. (The answer key is built and tested in step 15.)
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

INSERT #t (id, kind, test, expected, actual) VALUES ('Q1', 'SEED', N'active golden questions', N'46', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('Q2', 'SEED', N'golden questions per agent', N'customer_agent=16; product_agent=12; sales_agent=18', CAST((SELECT STRING_AGG(CAST(agent_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY agent_name) FROM (SELECT agent_name, COUNT(*) AS n FROM genbi.golden_question WHERE is_active = 1 GROUP BY agent_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('Q3', 'SEED', N'active questions still Draft (they are approved in step 15, after validation)', N'46', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND review_status = 'Draft') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('Q4', 'SEED', N'glossary terms that need an assumption but have no golden question', N'0', CAST((SELECT COUNT(*) FROM genbi.vw_golden_coverage) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('Q5', 'RULE', N'answerable questions (Answer) without SQL', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE expected_behavior IN ('Answer','Answer with stated assumption') AND expected_sql IS NULL) AS NVARCHAR(200)));

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
