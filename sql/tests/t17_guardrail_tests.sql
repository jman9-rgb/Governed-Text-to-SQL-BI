/* =============================================================================
   TESTS: STEP 17 COST GUARDRAILS
   Budget arithmetic, usage ledger and answer cache behave. Test rows are removed at the end.
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

DELETE FROM genbi.ai_usage     WHERE model = N'TEST';                    -- leftovers of an earlier failed run
DELETE FROM genbi.answer_cache WHERE cache_key = REPLICATE('0', 64);

DECLARE @before INT = (SELECT api_calls_today FROM genbi.vw_budget_today);
EXEC genbi.sp_log_ai_call N'test_agent', N'TEST', N'api',   100, 20, N'ok',    NULL;
EXEC genbi.sp_log_ai_call N'test_agent', N'TEST', N'api',   0,   0,  N'error', N'429 test';
EXEC genbi.sp_log_ai_call N'test_agent', N'TEST', N'cache', 0,   0,  N'ok',    NULL;
DECLARE @after INT = (SELECT api_calls_today FROM genbi.vw_budget_today);

DECLARE @k CHAR(64) = REPLICATE('0', 64);
DECLARE @c TABLE (behavior NVARCHAR(40), sql_text NVARCHAR(MAX), note NVARCHAR(MAX));
EXEC genbi.sp_cache_put @k, N'test_agent', N'test question', N'Answer', N'SELECT 1 AS x FROM semantic.vw_data_range', N'test';
INSERT @c EXEC genbi.sp_cache_get @k, 60;
DECLARE @found INT = (SELECT COUNT(*) FROM @c);
DECLARE @hits  INT = (SELECT hit_count FROM genbi.answer_cache WHERE cache_key = @k);
DELETE FROM @c;
INSERT @c EXEC genbi.sp_cache_get @k, -1;                -- ttl -1: everything counts as expired
DECLARE @expired INT = (SELECT COUNT(*) FROM @c);

DECLARE @cleared INT;                                    -- sp_cache_clear deletes the whole cache: test it, then roll back
BEGIN TRAN;
    EXEC genbi.sp_cache_clear;
    SET @cleared = (SELECT COUNT(*) FROM genbi.answer_cache);
ROLLBACK;

INSERT #t (id, kind, test, expected, actual) VALUES ('U1', 'SEED', N'guardrail rows', N'8', CAST((SELECT COUNT(*) FROM genbi.guardrail) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U2', 'RULE', N'vw_budget_today returns exactly one row', N'1', CAST((SELECT COUNT(*) FROM genbi.vw_budget_today) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U3', 'RULE', N'remaining = daily_limit - api_calls_today', N'1', CAST((SELECT CASE WHEN (SELECT remaining FROM genbi.vw_budget_today) = (SELECT daily_limit - api_calls_today FROM genbi.vw_budget_today) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U4', 'RULE', N'2 api calls + 1 cache hit raise api_calls_today by exactly 2', N'2', CAST((SELECT @after - @before) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U5', 'RULE', N'usage view for test_agent: api / cache / failed / cache_hit_pct', N'2/1/1/33.33', CAST((SELECT CONCAT(api_calls, '/', cache_hits, '/', failed_calls, '/', cache_hit_pct) FROM genbi.vw_usage_daily WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U6', 'RULE', N'cache: a stored answer is found', N'1', CAST((SELECT @found) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U7', 'RULE', N'cache: a hit is counted', N'1', CAST((SELECT @hits) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U8', 'RULE', N'cache: an expired answer is not returned', N'0', CAST((SELECT @expired) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U9', 'RULE', N'cache: sp_cache_clear empties the cache', N'0', CAST((SELECT @cleared) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('U10', 'RULE', N'longest agent prompt fits max_prompt_chars', N'1', CAST((SELECT CASE WHEN (SELECT MAX(chars) FROM (SELECT SUM(LEN(line_text)) AS chars FROM genbi.vw_agent_prompt GROUP BY agent_name) x) <= (SELECT limit_value FROM genbi.guardrail WHERE guardrail_name = N'max_prompt_chars') THEN 1 ELSE 0 END) AS NVARCHAR(200)));

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

DELETE FROM genbi.ai_usage     WHERE model = N'TEST';                   -- clean up (real usage data stays)
DELETE FROM genbi.answer_cache WHERE cache_key = REPLICATE('0', 64);
GO
