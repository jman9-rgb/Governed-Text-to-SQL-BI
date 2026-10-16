/* =============================================================================
   TESTS: STEP 18 QUERY LOGGING
   Logging procedures, rule links, daily view and purge. Test rows are removed at the end.
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

DELETE FROM genbi.query_log WHERE agent_name = N'test_agent';          -- leftovers of an earlier failed run
DECLARE @ids TABLE (log_id INT);

INSERT @ids EXEC genbi.sp_log_query N'test_agent', N'TEST answered question',  N'Answer',  N'answered',  N'ok',
     N'SELECT 1 AS x FROM semantic.vw_data_range', N'PASS', NULL,
     1, 1, 40, 900, 0, 1, N'TEST-model', 100, 20, 0, NULL;
INSERT @ids EXEC genbi.sp_log_query N'test_agent', N'TEST blocked question',   N'Answer',  N'blocked',   N'blocked',
     N'SELECT * FROM gold.fact_sales', N'BLOCKED', N'V06,V07',
     0, NULL, NULL, 50, 0, 1, N'TEST-model', 100, 20, 0, NULL;
INSERT @ids EXEC genbi.sp_log_query N'test_agent', N'TEST sql error question', N'Answer',  N'sql_error', N'error',
     N'SELECT bad FROM semantic.vw_sales', N'PASS', NULL,
     1, NULL, 5000, 5200, 0, 1, N'TEST-model', 100, 20, 1, N'Invalid column name';

DECLARE @blocked_id INT = (SELECT MAX(log_id) FROM genbi.query_log WHERE question = N'TEST blocked question');
EXEC genbi.sp_log_query_rule @blocked_id, N'V06';
EXEC genbi.sp_log_query_rule @blocked_id, N'V07';
EXEC genbi.sp_log_query_rule @blocked_id, N'V07';          -- twice on purpose: must not duplicate

DECLARE @purged TABLE (rows_deleted INT);
INSERT @purged EXEC genbi.sp_purge_query_log 36500;

INSERT #t (id, kind, test, expected, actual) VALUES ('L1', 'RULE', N'logging objects exist (2 tables, 4 views, 3 procedures)', N'9', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND name IN ('query_log','query_log_rule','vw_query_log_recent','vw_query_log_daily','vw_rule_hits','vw_slow_queries','sp_log_query','sp_log_query_rule','sp_purge_query_log')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L2', 'RULE', N'sp_log_query returns a different log_id for each call', N'3', CAST((SELECT COUNT(DISTINCT log_id) FROM @ids) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L3', 'RULE', N'daily view: questions / answered / blocked / sql_errors / answered_pct', N'3/1/1/1/33.33', CAST((SELECT CONCAT(questions, '/', answered, '/', blocked, '/', sql_errors, '/', answered_pct) FROM genbi.vw_query_log_daily WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L4', 'RULE', N'rule codes stored for the blocked question (no duplicates)', N'V06,V07', CAST((SELECT STRING_AGG(rule_code, ',') WITHIN GROUP (ORDER BY rule_code) FROM genbi.query_log_rule WHERE log_id = @blocked_id) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L5', 'RULE', N'vw_rule_hits shows V06 and V07', N'2', CAST((SELECT COUNT(*) FROM genbi.vw_rule_hits WHERE rule_code IN ('V06','V07') AND hits >= 1) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L6', 'SEED', N'slow-query view lists the 5000 ms test query (a busy real log can push it out of the top 20)', N'1', CAST((SELECT COUNT(*) FROM genbi.vw_slow_queries WHERE question = N'TEST sql error question') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('L7', 'RULE', N'purge with 36500 days keeps the test rows (rows deleted = 0)', N'0', CAST((SELECT rows_deleted FROM @purged) AS NVARCHAR(200)));

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

DELETE FROM genbi.query_log WHERE agent_name = N'test_agent';         -- clean up (rule rows go with them)
GO
