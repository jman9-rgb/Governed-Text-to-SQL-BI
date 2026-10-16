/* =============================================================================
   TESTS: STEP 08 WAREHOUSE AND SEMANTIC VIEWS
   Layers agree with each other and the semantic views reconcile to the fact table. (Reader permission test: t09.)
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

DECLARE @dated BIGINT = (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales WHERE order_date IS NOT NULL);
DECLARE @all   BIGINT = (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales);

INSERT #t (id, kind, test, expected, actual) VALUES ('W1', 'RULE', N'gold.fact_sales rows = silver.crm_sales_details rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.fact_sales) = (SELECT COUNT(*) FROM silver.crm_sales_details) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W2', 'RULE', N'gold.dim_customers rows = silver.crm_cust_info rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.dim_customers) = (SELECT COUNT(*) FROM silver.crm_cust_info) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W3', 'RULE', N'gold.dim_products rows = current silver products', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM gold.dim_products) = (SELECT COUNT(*) FROM silver.crm_prd_info WHERE prd_end_dt IS NULL) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W4', 'RULE', N'fact rows with no customer_key', N'0', CAST((SELECT COUNT(*) FROM gold.fact_sales WHERE customer_key IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W5', 'RULE', N'fact rows with no product_key', N'0', CAST((SELECT COUNT(*) FROM gold.fact_sales WHERE product_key IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W6', 'RULE', N'duplicate customer_key values', N'0', CAST((SELECT COUNT(*) FROM (SELECT customer_key FROM gold.dim_customers GROUP BY customer_key HAVING COUNT(*) > 1) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W7', 'RULE', N'duplicate product_key values', N'0', CAST((SELECT COUNT(*) FROM (SELECT product_key FROM gold.dim_products GROUP BY product_key HAVING COUNT(*) > 1) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W8', 'RULE', N'rows where sales_amount <> quantity x price', N'0', CAST((SELECT COUNT(*) FROM gold.fact_sales WHERE sales_amount <> quantity * price) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W9', 'RULE', N'hidden CR characters left in silver', N'0', CAST((SELECT (SELECT COUNT(*) FROM silver.erp_loc_a101 WHERE cntry LIKE '%' + CHAR(13) + '%') + (SELECT COUNT(*) FROM silver.erp_px_cat_g1v2 WHERE maintenance LIKE '%' + CHAR(13) + '%') + (SELECT COUNT(*) FROM silver.erp_cust_az12 WHERE gen LIKE '%' + CHAR(13) + '%')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W10', 'RULE', N'semantic.vw_sales dated total = fact dated total', N'1', CAST((SELECT CASE WHEN (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM semantic.vw_sales WHERE order_date IS NOT NULL) = (SELECT @dated) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W11', 'RULE', N'vw_monthly_sales total = fact dated total', N'1', CAST((SELECT CASE WHEN (SELECT CAST(SUM(total_sales) AS BIGINT) FROM semantic.vw_monthly_sales) = (SELECT @dated) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W12', 'RULE', N'vw_customer_metrics total = fact dated total', N'1', CAST((SELECT CASE WHEN (SELECT CAST(SUM(total_sales) AS BIGINT) FROM semantic.vw_customer_metrics) = (SELECT @dated) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W13', 'RULE', N'vw_product_metrics total = fact dated total', N'1', CAST((SELECT CASE WHEN (SELECT CAST(SUM(total_sales) AS BIGINT) FROM semantic.vw_product_metrics) = (SELECT @dated) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W14', 'RULE', N'vw_sales rows = fact rows', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM semantic.vw_sales) = (SELECT COUNT(*) FROM gold.fact_sales) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W15', 'RULE', N'number of semantic views', N'5', CAST((SELECT COUNT(*) FROM sys.views WHERE schema_id = SCHEMA_ID('semantic')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W16', 'RULE', N'vw_data_range last_order_date = latest order in the fact table', N'1', CAST((SELECT CASE WHEN (SELECT last_order_date FROM semantic.vw_data_range) = (SELECT MAX(order_date) FROM gold.fact_sales) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W17', 'RULE', N'all-time total - dated total = sales on undated lines', N'1', CAST((SELECT CASE WHEN (SELECT @all - @dated) = (SELECT ISNULL(SUM(CAST(sales_amount AS BIGINT)), 0) FROM gold.fact_sales WHERE order_date IS NULL) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W18', 'RULE', N'customer recency is never negative', N'1', CAST((SELECT CASE WHEN (SELECT MIN(recency) FROM semantic.vw_customer_metrics) >= 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W19', 'DATA', N'customer segments present (VIP, Regular, New)', N'3', CAST((SELECT COUNT(DISTINCT customer_segment) FROM semantic.vw_customer_metrics) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W20', 'DATA', N'order lines', N'60398', CAST((SELECT COUNT(*) FROM gold.fact_sales) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W21', 'DATA', N'all-time total sales', N'29356250', CAST((SELECT @all) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W22', 'DATA', N'dated total sales', N'29351258', CAST((SELECT @dated) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W23', 'DATA', N'distinct orders', N'27659', CAST((SELECT COUNT(DISTINCT order_number) FROM gold.fact_sales) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('W24', 'DATA', N'order lines with no order date', N'19', CAST((SELECT COUNT(*) FROM gold.fact_sales WHERE order_date IS NULL) AS NVARCHAR(200)));

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
