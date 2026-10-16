/* =============================================================================
   TESTS: STEP 15 ANSWER KEY
   Every answerable question has a validated trusted SQL and a stored result snapshot.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('A1', 'RULE', N'golden questions whose trusted SQL fails', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND validation_status = 'Error') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A2', 'RULE', N'golden questions never validated', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND validation_status = 'Not run') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A3', 'RULE', N'answerable questions without an answer key', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND expected_sql IS NOT NULL AND expected_result_json IS NULL AND ISNULL(expected_row_count, -1) <> 0) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A4', 'RULE', N'snapshots without a SQL hash (cannot detect a later change)', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE expected_result_json IS NOT NULL AND snapshot_sql_hash IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A5', 'SEED', N'validated OK / No SQL (Clarify, Decline, Redirect)', N'38/8', CAST((SELECT CAST(SUM(CASE WHEN validation_status = 'OK' THEN 1 ELSE 0 END) AS VARCHAR(5)) + '/' + CAST(SUM(CASE WHEN validation_status = 'No SQL' THEN 1 ELSE 0 END) AS VARCHAR(5)) FROM genbi.golden_question WHERE is_active = 1) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A6', 'SEED', N'questions with a stored snapshot', N'38', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND expected_result_json IS NOT NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('A7', 'RULE', N'active questions not Approved (the evaluation skips them)', N'0', CAST((SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND review_status <> 'Approved') AS NVARCHAR(200)));

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

/* ---------- Optional behaviour check (not part of the table above) ----------
   Changing a question's SQL must rebuild ONLY that snapshot. Remove the comment marks to try it; it restores golden 1.
UPDATE genbi.golden_question SET expected_sql = expected_sql + N' ' WHERE golden_id = 1;
EXEC genbi.sp_validate_golden @create_snapshot = 1;
UPDATE genbi.golden_question SET expected_sql = RTRIM(expected_sql) WHERE golden_id = 1;
EXEC genbi.sp_validate_golden @create_snapshot = 1;
*/
