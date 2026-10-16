/* =============================================================================
   TESTS: STEP 24 DATA CONTRACTS
   The semantic views still match their written contract, and the contract check really catches a change.
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

DROP TABLE IF EXISTS #c;
CREATE TABLE #c (view_name NVARCHAR(128), problem NVARCHAR(30), detail NVARCHAR(400));
INSERT #c EXEC genbi.sp_contract_check;
INSERT #t (id, kind, test, expected, actual) VALUES ('C1', 'RULE', N'contract objects exist (2 tables, 2 views, 2 procedures)', N'6', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND name IN ('data_contract_view','data_contract_column','vw_contract_live','vw_contract_drift','sp_contract_check','sp_contract_rebaseline')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C2', 'RULE', N'semantic views without a contract, and contracts without a view', N'0', CAST((SELECT COUNT(*) FROM genbi.vw_contract_drift WHERE problem IN ('new_view','missing_view')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C3', 'RULE', N'contract columns = live columns of the semantic views', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.data_contract_column) = (SELECT COUNT(*) FROM genbi.vw_contract_live) THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C4', 'RULE', N'drift between the contract and the live views', N'0', CAST((SELECT COUNT(*) FROM genbi.vw_contract_drift) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C5', 'RULE', N'every contract column also has a catalog row (structure and meaning agree)', N'0', CAST((SELECT COUNT(*) FROM genbi.data_contract_column k LEFT JOIN genbi.metric_catalog m ON m.view_name = k.view_name COLLATE DATABASE_DEFAULT AND m.column_name = k.column_name COLLATE DATABASE_DEFAULT WHERE m.column_name IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C6', 'RULE', N'key rules declared (monthly, customer, product)', N'3', CAST((SELECT COUNT(*) FROM genbi.data_contract_view WHERE key_columns IS NOT NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C7', 'SEED', N'columns in the contract per view', N'vw_customer_metrics=15; vw_data_range=3; vw_monthly_sales=5; vw_product_metrics=16; vw_sales=19', CAST((SELECT STRING_AGG(CAST(view_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY view_name) FROM (SELECT view_name, COUNT(*) AS n FROM genbi.data_contract_column GROUP BY view_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C8', 'RULE', N'full contract check (drift, duplicate keys, row counts): problems found', N'0', CAST((SELECT COUNT(*) FROM #c) AS NVARCHAR(200)));

-- The check must really catch a change. Edit the contract inside a transaction, count what the check sees, roll back.
DECLARE @type_changed INT, @new_column INT, @missing_column INT;
BEGIN TRANSACTION;
    UPDATE genbi.data_contract_column SET data_type = N'xx_test' WHERE view_name = N'vw_customer_metrics' AND column_name = N'customer_key';
    DELETE FROM genbi.data_contract_column WHERE view_name = N'vw_data_range' AND column_name = N'latest_month';
    INSERT genbi.data_contract_column (view_name, column_name, ordinal, data_type) VALUES (N'vw_data_range', N'ghost_column', 99, N'int');
    SELECT @type_changed    = COUNT(*) FROM genbi.vw_contract_drift WHERE problem = 'type_changed'    AND view_name = N'vw_customer_metrics';
    SELECT @new_column      = COUNT(*) FROM genbi.vw_contract_drift WHERE problem = 'new_column'      AND view_name = N'vw_data_range';
    SELECT @missing_column  = COUNT(*) FROM genbi.vw_contract_drift WHERE problem = 'missing_column'  AND view_name = N'vw_data_range';
ROLLBACK TRANSACTION;
INSERT #t (id, kind, test, expected, actual) VALUES ('C9', 'RULE', N'a changed type, a new column and a missing column are all detected', N'1/1/1', CAST((SELECT CONCAT(@type_changed, '/', @new_column, '/', @missing_column)) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('C10', 'RULE', N'the test changes were rolled back (drift is 0 again)', N'0', CAST((SELECT COUNT(*) FROM genbi.vw_contract_drift) AS NVARCHAR(200)));
DROP TABLE #c;

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
