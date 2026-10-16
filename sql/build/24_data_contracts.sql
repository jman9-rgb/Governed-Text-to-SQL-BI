/* =============================================================================
   24 DATA CONTRACTS
   A written promise for each semantic view: its grain, its key, and every column with its type.
   The AI, the dashboards and the golden questions all depend on these five views, so a silent change
   (a column dropped, renamed or retyped) must be caught before it breaks them.

   tables      genbi.data_contract_view     one row per semantic view: grain, key, source, expected rows
               genbi.data_contract_column   one row per column: name, position, data type
   view        genbi.vw_contract_drift      every difference between the contract and the live views (empty = healthy)
   procedures  genbi.sp_contract_check      drift + duplicate keys + row count rule; returns the problems (empty = healthy)
               genbi.sp_contract_rebaseline accept a deliberate change: rewrite one view's columns from the live view

   The first run takes the CURRENT columns as the agreed contract (run it right after the semantic views are final).
   Re-running never overwrites an existing contract. To accept a change on purpose:
       EXEC genbi.sp_contract_rebaseline @view_name = N'vw_sales';
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. Tables ---------- */
IF OBJECT_ID(N'genbi.data_contract_view', N'U') IS NULL
BEGIN
    CREATE TABLE genbi.data_contract_view (
        view_name     NVARCHAR(128) NOT NULL CONSTRAINT PK_data_contract_view PRIMARY KEY,
        grain         NVARCHAR(300) NOT NULL,           -- what one row means
        key_columns   NVARCHAR(200) NULL,               -- comma-separated columns that must be unique; NULL = no unique key
        expected_rows INT           NULL,               -- exact row count the view must return; NULL = no rule
        source_objects NVARCHAR(300) NOT NULL,          -- where the data comes from
        created_at    DATETIME2(0)  NOT NULL CONSTRAINT DF_data_contract_view_created DEFAULT SYSDATETIME()
    );
END;
GO

IF OBJECT_ID(N'genbi.data_contract_column', N'U') IS NULL
BEGIN
    CREATE TABLE genbi.data_contract_column (
        view_name   NVARCHAR(128) NOT NULL,
        column_name NVARCHAR(128) NOT NULL,
        ordinal     INT           NOT NULL,
        data_type   NVARCHAR(60)  NOT NULL,             -- for example int, nvarchar(50), decimal(18,2)
        CONSTRAINT PK_data_contract_column PRIMARY KEY (view_name, column_name),
        CONSTRAINT FK_data_contract_column_view FOREIGN KEY (view_name) REFERENCES genbi.data_contract_view (view_name)
    );
END;
GO

/* ---------- 2. The live columns of the semantic views, in the same shape as the contract ---------- */
CREATE OR ALTER VIEW genbi.vw_contract_live
AS
SELECT  CAST(c.TABLE_NAME  AS NVARCHAR(128)) COLLATE DATABASE_DEFAULT AS view_name,
        CAST(c.COLUMN_NAME AS NVARCHAR(128)) COLLATE DATABASE_DEFAULT AS column_name,
        c.ORDINAL_POSITION                                             AS ordinal,
        CAST(c.DATA_TYPE
             + CASE WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
                    THEN N'(' + CASE WHEN c.CHARACTER_MAXIMUM_LENGTH = -1 THEN N'max'
                                     ELSE CAST(c.CHARACTER_MAXIMUM_LENGTH AS NVARCHAR(10)) END + N')'
                    WHEN c.DATA_TYPE IN (N'decimal', N'numeric')
                    THEN N'(' + CAST(c.NUMERIC_PRECISION AS NVARCHAR(10)) + N',' + CAST(c.NUMERIC_SCALE AS NVARCHAR(10)) + N')'
                    ELSE N'' END AS NVARCHAR(60)) COLLATE DATABASE_DEFAULT AS data_type
FROM    INFORMATION_SCHEMA.COLUMNS c
WHERE   c.TABLE_SCHEMA = N'semantic';
GO

/* ---------- 3. The contract for each view (what the author agreed to) ---------- */
INSERT INTO genbi.data_contract_view (view_name, grain, key_columns, expected_rows, source_objects)
SELECT v.view_name, v.grain, v.key_columns, v.expected_rows, v.source_objects
FROM (VALUES
    (N'vw_sales',
     N'One row = one sales transaction (order line). Count orders and customers with COUNT(DISTINCT).',
     CAST(NULL AS NVARCHAR(200)), CAST(NULL AS INT),
     N'gold.fact_sales joined to gold.dim_products and gold.dim_customers'),
    (N'vw_monthly_sales',
     N'One row = one calendar month that has dated orders.',
     N'sales_month', NULL,
     N'gold.fact_sales (rows with an order date)'),
    (N'vw_customer_metrics',
     N'One row = one customer.',
     N'customer_key', NULL,
     N'gold.report_customers'),
    (N'vw_product_metrics',
     N'One row = one product.',
     N'product_key', NULL,
     N'gold.report_products'),
    (N'vw_data_range',
     N'One single row: first order date, last order date and the latest month of the data.',
     NULL, 1,
     N'gold.fact_sales (rows with an order date)')
) AS v (view_name, grain, key_columns, expected_rows, source_objects)
WHERE NOT EXISTS (SELECT 1 FROM genbi.data_contract_view x WHERE x.view_name = v.view_name);
GO

/* ---------- 4. Take the current columns as the agreed contract (only for views that have none yet) ---------- */
INSERT INTO genbi.data_contract_column (view_name, column_name, ordinal, data_type)
SELECT l.view_name, l.column_name, l.ordinal, l.data_type
FROM   genbi.vw_contract_live l
JOIN   genbi.data_contract_view v ON v.view_name = l.view_name
WHERE  NOT EXISTS (SELECT 1 FROM genbi.data_contract_column x WHERE x.view_name = l.view_name);
GO

/* ---------- 5. Drift: every difference between the contract and the live views ---------- */
CREATE OR ALTER VIEW genbi.vw_contract_drift
AS
SELECT v.view_name, CAST(N'missing_view' AS NVARCHAR(30)) AS problem,
       CAST(N'The contract lists this view but it does not exist in the semantic schema.' AS NVARCHAR(400)) AS detail
FROM   genbi.data_contract_view v
WHERE  NOT EXISTS (SELECT 1 FROM sys.views sv WHERE sv.schema_id = SCHEMA_ID(N'semantic') AND sv.name = v.view_name COLLATE DATABASE_DEFAULT)
UNION ALL
SELECT CAST(sv.name AS NVARCHAR(128)), N'new_view',
       N'This semantic view has no contract. Add it to genbi.data_contract_view and rebaseline it.'
FROM   sys.views sv
WHERE  sv.schema_id = SCHEMA_ID(N'semantic')
  AND  NOT EXISTS (SELECT 1 FROM genbi.data_contract_view v WHERE v.view_name = sv.name COLLATE DATABASE_DEFAULT)
UNION ALL
SELECT k.view_name, N'missing_column', N'Column ' + k.column_name + N' (' + k.data_type + N') is in the contract but not in the view.'
FROM   genbi.data_contract_column k
WHERE  EXISTS (SELECT 1 FROM genbi.vw_contract_live l WHERE l.view_name = k.view_name)
  AND  NOT EXISTS (SELECT 1 FROM genbi.vw_contract_live l WHERE l.view_name = k.view_name AND l.column_name = k.column_name)
UNION ALL
SELECT l.view_name, N'new_column', N'Column ' + l.column_name + N' (' + l.data_type + N') is in the view but not in the contract.'
FROM   genbi.vw_contract_live l
WHERE  EXISTS (SELECT 1 FROM genbi.data_contract_view v WHERE v.view_name = l.view_name)
  AND  NOT EXISTS (SELECT 1 FROM genbi.data_contract_column k WHERE k.view_name = l.view_name AND k.column_name = l.column_name)
UNION ALL
SELECT k.view_name, N'type_changed',
       N'Column ' + k.column_name + N': contract says ' + k.data_type + N', the view returns ' + l.data_type + N'.'
FROM   genbi.data_contract_column k
JOIN   genbi.vw_contract_live l ON l.view_name = k.view_name AND l.column_name = k.column_name
WHERE  l.data_type <> k.data_type;
GO

/* ---------- 6. Full check: drift + duplicate keys + row count rule ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_contract_check
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @r TABLE (view_name NVARCHAR(128), problem NVARCHAR(30), detail NVARCHAR(400));
    INSERT @r (view_name, problem, detail) SELECT view_name, problem, detail FROM genbi.vw_contract_drift;

    DECLARE @v NVARCHAR(128), @k NVARCHAR(200), @n INT, @cols NVARCHAR(MAX), @sql NVARCHAR(MAX), @count INT;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT v.view_name, v.key_columns, v.expected_rows
        FROM   genbi.data_contract_view v
        WHERE  EXISTS (SELECT 1 FROM sys.views sv WHERE sv.schema_id = SCHEMA_ID(N'semantic') AND sv.name = v.view_name COLLATE DATABASE_DEFAULT);
    OPEN c;
    FETCH NEXT FROM c INTO @v, @k, @n;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            IF @k IS NOT NULL
            BEGIN
                SELECT @cols = STRING_AGG(QUOTENAME(LTRIM(RTRIM(value))), N', ') FROM STRING_SPLIT(@k, N',');
                SET @sql = N'SELECT @cnt = COUNT(*) FROM (SELECT 1 AS x FROM semantic.' + QUOTENAME(@v)
                         + N' GROUP BY ' + @cols + N' HAVING COUNT(*) > 1) q;';
                EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @count OUTPUT;
                IF @count > 0
                    INSERT @r VALUES (@v, N'duplicate_key', CAST(@count AS NVARCHAR(20)) + N' key value(s) appear more than once in (' + @k + N').');
            END;

            IF @n IS NOT NULL
            BEGIN
                SET @sql = N'SELECT @cnt = COUNT(*) FROM semantic.' + QUOTENAME(@v) + N';';
                EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @count OUTPUT;
                IF @count <> @n
                    INSERT @r VALUES (@v, N'row_count', N'The contract expects ' + CAST(@n AS NVARCHAR(20)) + N' row(s), the view returns ' + CAST(@count AS NVARCHAR(20)) + N'.');
            END;
        END TRY
        BEGIN CATCH
            INSERT @r VALUES (@v, N'check_failed', LEFT(ERROR_MESSAGE(), 400));
        END CATCH;

        FETCH NEXT FROM c INTO @v, @k, @n;
    END;
    CLOSE c;
    DEALLOCATE c;

    SELECT view_name, problem, detail FROM @r ORDER BY view_name, problem, detail;
END;
GO

/* ---------- 7. Accept a deliberate change ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_contract_rebaseline
    @view_name NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM genbi.data_contract_view WHERE view_name = @view_name)
        THROW 50030, N'No contract row for this view. Add it to genbi.data_contract_view first.', 1;
    IF NOT EXISTS (SELECT 1 FROM genbi.vw_contract_live WHERE view_name = @view_name)
        THROW 50031, N'This view does not exist in the semantic schema.', 1;

    BEGIN TRANSACTION;
        DELETE FROM genbi.data_contract_column WHERE view_name = @view_name;
        INSERT INTO genbi.data_contract_column (view_name, column_name, ordinal, data_type)
        SELECT view_name, column_name, ordinal, data_type FROM genbi.vw_contract_live WHERE view_name = @view_name;
    COMMIT TRANSACTION;

    SELECT view_name, COUNT(*) AS columns_in_contract FROM genbi.data_contract_column WHERE view_name = @view_name GROUP BY view_name;
END;
GO

/* ---------- 8. Result ---------- */
SELECT view_name, key_columns, expected_rows, grain FROM genbi.data_contract_view ORDER BY view_name;
EXEC genbi.sp_contract_check;     -- expect: no rows
GO
