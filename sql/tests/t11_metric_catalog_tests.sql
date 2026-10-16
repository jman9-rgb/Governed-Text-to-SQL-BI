/* =============================================================================
   TESTS: STEP 11 METRIC CATALOG
   The catalog documents every column, and the views obey their own definitions.
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

INSERT #t (id, kind, test, expected, actual) VALUES ('M1', 'RULE', N'semantic columns with no catalog row', N'0', CAST((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS c LEFT JOIN genbi.metric_catalog m ON m.view_name = c.TABLE_NAME COLLATE DATABASE_DEFAULT AND m.column_name = c.COLUMN_NAME COLLATE DATABASE_DEFAULT WHERE c.TABLE_SCHEMA = 'semantic' AND m.catalog_id IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M2', 'RULE', N'catalog rows that point to a missing column', N'0', CAST((SELECT COUNT(*) FROM genbi.metric_catalog m LEFT JOIN INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_SCHEMA = 'semantic' AND c.TABLE_NAME COLLATE DATABASE_DEFAULT = m.view_name AND c.COLUMN_NAME COLLATE DATABASE_DEFAULT = m.column_name WHERE c.COLUMN_NAME IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M3', 'RULE', N'sales_amount = quantity x price violations', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_sales WHERE CAST(sales_amount AS BIGINT) <> CAST(quantity AS BIGINT) * price) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M4', 'RULE', N'customer segment rule violations', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_customer_metrics WHERE customer_segment <> CASE WHEN lifespan >= 12 AND total_sales > 5000 THEN 'VIP' WHEN lifespan >= 12 THEN 'Regular' ELSE 'New' END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M5', 'RULE', N'product segment rule violations', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_product_metrics WHERE product_segment <> CASE WHEN total_sales > 50000 THEN 'High-Performer' WHEN total_sales >= 10000 THEN 'Mid-Range' ELSE 'Low-Performer' END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M6', 'RULE', N'customer recency rule violations', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_customer_metrics WHERE recency <> DATEDIFF(MONTH, last_order_date, (SELECT last_order_date FROM semantic.vw_data_range))) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M7', 'RULE', N'product recency rule violations', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_product_metrics WHERE recency_in_months <> DATEDIFF(MONTH, last_sale_date, (SELECT last_order_date FROM semantic.vw_data_range))) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M8', 'RULE', N'customer avg order value = sales / orders (violations)', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_customer_metrics WHERE ABS(avg_order_value - CAST(total_sales AS DECIMAL(18,2)) / NULLIF(total_orders, 0)) > 0.01) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M9', 'RULE', N'product avg order revenue = sales / orders (violations)', N'0', CAST((SELECT COUNT(*) FROM semantic.vw_product_metrics WHERE ABS(avg_order_revenue - CAST(total_sales AS DECIMAL(18,2)) / NULLIF(total_orders, 0)) > 0.01) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M10', 'RULE', N'trusted total_sales on vw_sales = fact table total', N'1', CAST((SELECT CASE WHEN (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM semantic.vw_sales) = (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M11', 'RULE', N'metric definitions whose preferred_view is not a semantic view', N'0', CAST((SELECT COUNT(*) FROM genbi.metric_definition d WHERE d.preferred_view IS NOT NULL AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.VIEWS v WHERE v.TABLE_SCHEMA = 'semantic' AND v.TABLE_NAME COLLATE DATABASE_DEFAULT = d.preferred_view)) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('M12', 'SEED', N'documented columns per view', N'vw_customer_metrics=15; vw_data_range=3; vw_monthly_sales=5; vw_product_metrics=16; vw_sales=19', CAST((SELECT STRING_AGG(CAST(view_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY view_name) FROM (SELECT view_name, COUNT(*) AS n FROM genbi.metric_catalog GROUP BY view_name) x) AS NVARCHAR(200)));

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

/* ---------- Reference (not a test): which columns can safely be summed? ----------
   Run it by hand. A summed value that differs from the true distinct count means "do not add this column up". */
SELECT 'orders: SUM(vw_monthly_sales) vs distinct' AS check_name,
       (SELECT SUM(total_orders) FROM semantic.vw_monthly_sales) AS summed,
       (SELECT COUNT(DISTINCT order_number) FROM semantic.vw_sales WHERE order_date IS NOT NULL) AS true_distinct
UNION ALL SELECT 'customers: SUM(vw_monthly_sales) vs distinct',
       (SELECT SUM(purchasing_customers) FROM semantic.vw_monthly_sales),
       (SELECT COUNT(DISTINCT customer_key) FROM semantic.vw_sales WHERE order_date IS NOT NULL)
UNION ALL SELECT 'orders: SUM(vw_product_metrics) vs distinct',
       (SELECT SUM(total_orders) FROM semantic.vw_product_metrics),
       (SELECT COUNT(DISTINCT order_number) FROM semantic.vw_sales WHERE order_date IS NOT NULL);
GO
