/* =============================================================================
   TESTS: STEP 20 EVALUATION
   A fake 3-question run proves the scoring views and the resume-safe save. The test run is removed at the end.
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

DELETE FROM genbi.eval_run WHERE label = N'TEST';                       -- leftovers (results go with the run)

DECLARE @run INT;
DECLARE @rid TABLE (run_id INT);
INSERT @rid EXEC genbi.sp_eval_start N'TEST', NULL, N'Step 20 test';
SELECT @run = run_id FROM @rid;

DECLARE @g1 INT = (SELECT MIN(golden_id) FROM genbi.golden_question WHERE is_active = 1);   -- any three active questions: this test does not depend on approval
DECLARE @g2 INT = (SELECT MIN(golden_id) FROM genbi.golden_question WHERE golden_id > @g1 AND is_active = 1);
DECLARE @g3 INT = (SELECT MIN(golden_id) FROM genbi.golden_question WHERE golden_id > @g2 AND is_active = 1);

IF @g3 IS NULL THROW 50020, N'Need at least 3 active golden questions: run steps 14 and 15 first.', 1;

--                       run  golden expected   got      b_ok f_ok assum res  pass failure_type      detail           exp got sql   note  verdict   codes model     calls cache in  out run total
EXEC genbi.sp_eval_save @run, @g1, N'Answer', N'Answer', 1,   1,   NULL, 1,   1,   N'none',         NULL,            1,  1,  NULL, NULL, N'PASS',   NULL, N'TEST',   1,    0,    100, 20, 40,  900;
EXEC genbi.sp_eval_save @run, @g2, N'Answer', N'Answer', 1,   1,   NULL, 0,   0,   N'wrong_result', N'rows 5 vs 6', 5,  6,  NULL, NULL, N'PASS',   NULL, N'TEST',   1,    0,    100, 20, 60,  1100;
EXEC genbi.sp_eval_save @run, @g3, N'Answer', N'Answer', 0,   0,   NULL, NULL,0,   N'blocked',      N'V06',          NULL, NULL, NULL, NULL, N'BLOCKED', N'V06', N'TEST', 1,    0,    100, 20, NULL, 500;
EXEC genbi.sp_eval_finish @run;

-- saving the same question again must replace the row (resume safe)
EXEC genbi.sp_eval_save @run, @g1, N'Answer', N'Answer', 1, 1, NULL, 1, 1, N'none', NULL, 1, 1, NULL, NULL, N'PASS', NULL, N'TEST', 1, 0, 100, 20, 40, 900;

INSERT #t (id, kind, test, expected, actual) VALUES ('E1', 'RULE', N'evaluation objects exist (2 tables, 6 views, 3 procedures)', N'11', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND name IN ('eval_run','eval_result','vw_eval_summary','vw_eval_by_agent','vw_eval_by_type','vw_eval_failures','vw_eval_changes','vw_eval_detail','sp_eval_start','sp_eval_save','sp_eval_finish')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E2', 'SEED', N'active approved questions / answerable / with answer key', N'46/38/38', CAST((SELECT CONCAT(COUNT(*), '/', SUM(CASE WHEN expected_sql IS NOT NULL THEN 1 ELSE 0 END), '/', SUM(CASE WHEN expected_sql IS NOT NULL AND (expected_result_json IS NOT NULL OR expected_row_count = 0) THEN 1 ELSE 0 END)) FROM genbi.golden_question WHERE is_active = 1 AND review_status = 'Approved') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E3', 'RULE', N'summary: questions / passed / pass_pct / behavior_ok_pct / result_ok_pct / blocked / status', N'3/1/33.33/66.67/50.00/1/partial', CAST((SELECT CONCAT(questions, '/', passed, '/', pass_pct, '/', behavior_ok_pct, '/', result_ok_pct, '/', blocked, '/', status) FROM genbi.vw_eval_summary WHERE run_id = @run) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E4', 'RULE', N'failures listed for the run', N'blocked,wrong_result', CAST((SELECT STRING_AGG(failure_type, ',') WITHIN GROUP (ORDER BY failure_type) FROM genbi.vw_eval_failures WHERE run_id = @run) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E5', 'RULE', N'saving a question twice keeps 3 rows in the run', N'3', CAST((SELECT COUNT(*) FROM genbi.eval_result WHERE run_id = @run) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E6', 'RULE', N'by-agent view: rows exist and pass_pct is 0..100', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_eval_by_agent WHERE run_id = @run) > 0 AND (SELECT COUNT(*) FROM genbi.vw_eval_by_agent WHERE run_id = @run AND pass_pct NOT BETWEEN 0 AND 100) = 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('E7', 'RULE', N'by-type view: rows exist and pass_pct is 0..100', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_eval_by_type WHERE run_id = @run) > 0 AND (SELECT COUNT(*) FROM genbi.vw_eval_by_type WHERE run_id = @run AND pass_pct NOT BETWEEN 0 AND 100) = 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));

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

DELETE FROM genbi.eval_run WHERE label = N'TEST';                      -- clean up (its results go with it)
GO
