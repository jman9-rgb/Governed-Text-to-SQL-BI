/* =============================================================================
   TESTS: STEP 21 MONITORING VIEWS
   The Power BI views agree with their source tables, and the monitor role sees only the views.
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

IF DATABASE_PRINCIPAL_ID('monitor_test') IS NOT NULL
BEGIN
    BEGIN TRY ALTER ROLE genbi_monitor DROP MEMBER monitor_test; END TRY BEGIN CATCH END CATCH;
    DROP USER monitor_test;
END;
CREATE USER monitor_test WITHOUT LOGIN;
ALTER ROLE genbi_monitor ADD MEMBER monitor_test;

DECLARE @views NVARCHAR(10) = N'DENIED', @raw NVARCHAR(10) = N'ALLOWED', @err INT = NULL, @x INT;
BEGIN TRY
    EXECUTE AS USER = 'monitor_test';
    SELECT @x = COUNT(*) FROM genbi.vw_mon_scorecard;
    SET @views = N'ALLOWED';
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'monitor_test' REVERT;
END CATCH;
BEGIN TRY
    EXECUTE AS USER = 'monitor_test';
    SELECT TOP (1) @x = 1 FROM genbi.query_log;
    REVERT;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    IF USER_NAME() = 'monitor_test' REVERT;
    SET @raw = N'DENIED';
END CATCH;

ALTER ROLE genbi_monitor DROP MEMBER monitor_test;
DROP USER monitor_test;

INSERT #t (id, kind, test, expected, actual) VALUES ('N1', 'RULE', N'monitoring views exist', N'8', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND type = 'V' AND name IN ('vw_mon_date','vw_mon_agent','vw_mon_questions','vw_mon_ai_usage','vw_mon_rules','vw_mon_eval','vw_mon_golden','vw_mon_scorecard')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N2', 'RULE', N'vw_mon_questions rows = query_log rows (test rows excluded)', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_mon_questions) = (SELECT COUNT(*) FROM genbi.query_log WHERE ISNULL(agent_name, N'') <> N'test_agent') THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N3', 'RULE', N'vw_mon_eval rows = eval_result rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_mon_eval) = (SELECT COUNT(*) FROM genbi.eval_result) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N4', 'RULE', N'runs where the dashboard pass_pct differs from the evaluation pass_pct', N'0', CAST((SELECT COUNT(*) FROM (SELECT s.run_id FROM genbi.vw_eval_summary s JOIN genbi.vw_mon_eval e ON e.run_id = s.run_id GROUP BY s.run_id, s.pass_pct HAVING s.pass_pct <> CAST(100.0 * SUM(e.passed_n) / COUNT(*) AS DECIMAL(5,2))) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N5', 'RULE', N'dates missing from the calendar (questions + usage + evaluation)', N'0', CAST((SELECT (SELECT COUNT(*) FROM genbi.vw_mon_questions q WHERE NOT EXISTS (SELECT 1 FROM genbi.vw_mon_date d WHERE d.date_value = q.log_date)) + (SELECT COUNT(*) FROM genbi.vw_mon_ai_usage u WHERE NOT EXISTS (SELECT 1 FROM genbi.vw_mon_date d WHERE d.date_value = u.usage_date)) + (SELECT COUNT(*) FROM genbi.vw_mon_eval e WHERE NOT EXISTS (SELECT 1 FROM genbi.vw_mon_date d WHERE d.date_value = e.run_date))) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N6', 'RULE', N'the scorecard is exactly one row', N'1', CAST((SELECT COUNT(*) FROM genbi.vw_mon_scorecard) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N7', 'SEED', N'golden questions per agent in vw_mon_golden', N'customer_agent=16; product_agent=12; sales_agent=18', CAST((SELECT STRING_AGG(CAST(agent_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY agent_name) FROM (SELECT agent_name, COUNT(*) AS n FROM genbi.vw_mon_golden GROUP BY agent_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N8', 'RULE', N'monitor role can read the monitoring views', N'ALLOWED', CAST((SELECT @views) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N9', 'RULE', N'monitor role cannot read the raw query_log', N'DENIED', CAST((SELECT @raw) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('N10', 'RULE', N'the denial is permission error 229', N'229', CAST((SELECT @err) AS NVARCHAR(200)));

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
