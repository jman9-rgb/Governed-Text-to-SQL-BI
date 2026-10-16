/* =============================================================================
   TESTS: STEP 16 SQL VALIDATOR (database side)
   The dry run accepts valid SQL and refuses bad columns, other agents' views and unknown agents.
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

CREATE TABLE #d (is_ok BIT, column_count INT, error_number INT, error_message NVARCHAR(2048));

INSERT #d EXEC genbi.sp_dry_run N'sales_agent', N'SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM semantic.vw_sales';
INSERT #t (id, kind, test, expected, actual)
SELECT 'D1', 'RULE', N'valid query: is_ok / columns / error', N'1/1/0',
       CONCAT(CAST(is_ok AS INT), '/', column_count, '/', error_number) FROM #d;
TRUNCATE TABLE #d;

INSERT #d EXEC genbi.sp_dry_run N'sales_agent', N'SELECT no_such_column FROM semantic.vw_sales';
INSERT #t (id, kind, test, expected, actual)
SELECT 'D2', 'RULE', N'unknown column: is_ok / error 207', N'0/207', CONCAT(CAST(is_ok AS INT), '/', error_number) FROM #d;
TRUNCATE TABLE #d;

INSERT #d EXEC genbi.sp_dry_run N'sales_agent', N'SELECT customer_key FROM gold.fact_sales';
INSERT #t (id, kind, test, expected, actual)
SELECT 'D3', 'RULE', N'object outside the agent scope is refused', N'0/1',
       CONCAT(CAST(is_ok AS INT), '/', CASE WHEN error_number = 229 OR error_message LIKE N'%denied%' THEN 1 ELSE 0 END) FROM #d;
TRUNCATE TABLE #d;

INSERT #d EXEC genbi.sp_dry_run N'customer_agent', N'SELECT order_number FROM semantic.vw_sales';
INSERT #t (id, kind, test, expected, actual)
SELECT 'D4', 'RULE', N'customer_agent cannot read vw_sales (another agent view)', N'0/1',
       CONCAT(CAST(is_ok AS INT), '/', CASE WHEN error_number = 229 OR error_message LIKE N'%denied%' THEN 1 ELSE 0 END) FROM #d;
TRUNCATE TABLE #d;

INSERT #d EXEC genbi.sp_dry_run N'no_such_agent', N'SELECT 1 AS x';
INSERT #t (id, kind, test, expected, actual)
SELECT 'D5', 'RULE', N'unknown agent', N'0/Unknown or inactive agent', CONCAT(CAST(is_ok AS INT), '/', error_message) FROM #d;
DROP TABLE #d;

INSERT #t (id, kind, test, expected, actual) VALUES ('D6', 'SEED', N'rules in the catalog (V01 to V11)', N'11', CAST((SELECT COUNT(*) FROM genbi.sql_rule) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('D7', 'RULE', N'blocking rules are BLOCK, the SELECT * and TOP rules are WARN', N'V07,V09', CAST((SELECT STRING_AGG(rule_code, ',') WITHIN GROUP (ORDER BY rule_code) FROM genbi.sql_rule WHERE severity = 'WARN') AS NVARCHAR(200)));

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
