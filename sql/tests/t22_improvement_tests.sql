/* =============================================================================
   TESTS: STEP 22 IMPROVEMENTS (three cycles)
   The fixes are in place, visible to the right agents and recorded in the change log.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('I1', 'RULE', N'AUTO_CLOSE is off (it caused timeouts)', N'0', CAST((SELECT is_auto_close_on FROM sys.databases WHERE name = DB_NAME()) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I2', 'RULE', N'change-log objects exist (2 tables, 1 view)', N'3', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND name IN ('change_log','change_log_golden','vw_change_effect')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I3', 'SEED', N'change-log rows after the three cycles', N'9', CAST((SELECT COUNT(*) FROM genbi.change_log) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I4', 'SEED', N'changes linked to golden questions', N'12', CAST((SELECT COUNT(*) FROM genbi.change_log_golden) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I5', 'RULE', N'changes listed twice (re-running the step must not duplicate)', N'0', CAST((SELECT COUNT(*) FROM (SELECT change_area, target FROM genbi.change_log GROUP BY change_area, target HAVING COUNT(*) > 1) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I6', 'RULE', N'changes with no eval_run_before', N'0', CAST((SELECT COUNT(*) FROM genbi.change_log WHERE eval_run_before IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I7', 'RULE', N'avg_selling_price_weighted is visible to product_agent only', N'product_agent=1', CAST((SELECT STRING_AGG(CAST(agent_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY agent_name) FROM (SELECT agent_name, COUNT(*) AS n FROM genbi.vw_agent_prompt WHERE sec = 4 AND item = N'avg_selling_price_weighted' GROUP BY agent_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I8', 'RULE', N'product glossary maps "average selling price" to the weighted metric', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_agent_prompt WHERE agent_name = N'product_agent' AND sec = 5 AND item = N'avg_selling_price_weighted' AND line_text LIKE N'%"average selling price"%') >= 1 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I9', 'RULE', N'inactive products: ask-the-user / old default', N'1/0', CAST((SELECT CONCAT(MAX(CASE WHEN line_text LIKE N'%ask the user%' THEN 1 ELSE 0 END), '/', MAX(CASE WHEN line_text LIKE N'%sort by recency%' THEN 1 ELSE 0 END)) FROM genbi.vw_agent_prompt WHERE agent_name = N'product_agent' AND item = N'inactive products') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I10', 'RULE', N'mom_growth_pct tells sales_agent to leave out the partial month', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_agent_prompt WHERE agent_name = N'sales_agent' AND sec = 4 AND item = N'mom_growth_pct' AND line_text LIKE N'%Leave out the partial latest month%') >= 1 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I11', 'RULE', N'avg_order_value_customers is visible to customer_agent only', N'customer_agent=1', CAST((SELECT STRING_AGG(CAST(agent_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY agent_name) FROM (SELECT agent_name, COUNT(*) AS n FROM genbi.vw_agent_prompt WHERE sec = 4 AND item = N'avg_order_value_customers' GROUP BY agent_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I12', 'RULE', N'inactive customers: ask-the-user / old default', N'1/0', CAST((SELECT CONCAT(MAX(CASE WHEN line_text LIKE N'%ask the user%' THEN 1 ELSE 0 END), '/', MAX(CASE WHEN line_text LIKE N'%sort by recency%' THEN 1 ELSE 0 END)) FROM genbi.vw_agent_prompt WHERE agent_name = N'customer_agent' AND item = N'inactive customers') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I13', 'RULE', N'customer_name rule (customer_agent): never group by name', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_agent_prompt WHERE agent_name = N'customer_agent' AND sec = 3 AND item = N'vw_customer_metrics.customer_name' AND line_text LIKE N'%Never GROUP BY customer_name%') >= 1 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I14', 'RULE', N'customer_name rule (sales_agent): group by customer_key', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_agent_prompt WHERE agent_name = N'sales_agent' AND sec = 3 AND item = N'vw_sales.customer_name' AND line_text LIKE N'%GROUP BY customer_key%') >= 1 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I15', 'DATA', N'weighted price by category: categories / NULL results', N'3/0', CAST((SELECT CONCAT(COUNT(*), '/', SUM(CASE WHEN asp IS NULL THEN 1 ELSE 0 END)) FROM (SELECT category, CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(CAST(total_quantity AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS asp FROM semantic.vw_product_metrics GROUP BY category) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I16', 'DATA', N'average order value of VIP customers', N'2554.11', CAST((SELECT CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(CAST(total_orders AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) FROM semantic.vw_customer_metrics WHERE customer_segment = 'VIP') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I17', 'DATA', N'"Jordan Turner": rows / distinct customer_key', N'2/2', CAST((SELECT CONCAT(COUNT(*), '/', COUNT(DISTINCT customer_key)) FROM semantic.vw_customer_metrics WHERE customer_name = 'Jordan Turner') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('I18', 'DATA', N'top 10 customers: rows with the merged 15998 total', N'0', CAST((SELECT COUNT(*) FROM (SELECT TOP (10) total_sales FROM semantic.vw_customer_metrics ORDER BY total_sales DESC, customer_key) x WHERE total_sales = 15998) AS NVARCHAR(200)));

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
