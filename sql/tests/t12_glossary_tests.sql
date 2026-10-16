/* =============================================================================
   TESTS: STEP 12 BUSINESS GLOSSARY
   Every glossary pointer is valid and every Filter rule really runs.
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

DECLARE @res TABLE (term NVARCHAR(100), rows_matched INT, error_message NVARCHAR(400));
DECLARE @term NVARCHAR(100), @view SYSNAME, @expr NVARCHAR(500), @sql NVARCHAR(MAX), @n INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT term, maps_to_view, filter_expression
    FROM genbi.business_glossary WHERE maps_to_type = 'Filter' AND is_active = 1;
OPEN c; FETCH NEXT FROM c INTO @term, @view, @expr;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @n = NULL;
        SET @sql = N'SELECT @n = COUNT(*) FROM semantic.' + QUOTENAME(@view) + N' WHERE ' + @expr;
        EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @n OUTPUT;
        INSERT @res VALUES (@term, @n, NULL);
    END TRY
    BEGIN CATCH
        INSERT @res VALUES (@term, NULL, ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM c INTO @term, @view, @expr;
END
CLOSE c; DEALLOCATE c;

INSERT #t (id, kind, test, expected, actual) VALUES ('G1', 'SEED', N'glossary terms (26 Metric, 16 Column, 8 Filter, 10 TimeRule, 9 Ambiguous, 8 Unsupported)', N'77', CAST((SELECT COUNT(*) FROM genbi.business_glossary) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G2', 'SEED', N'trusted KPIs with no glossary term', N'0', CAST((SELECT COUNT(*) FROM genbi.metric_definition d LEFT JOIN genbi.business_glossary g ON g.maps_to_metric_code = d.metric_code WHERE g.glossary_id IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G3', 'RULE', N'glossary pointers to a missing catalog column', N'0', CAST((SELECT COUNT(*) FROM genbi.business_glossary g LEFT JOIN genbi.metric_catalog m ON m.view_name = g.maps_to_view AND m.column_name = g.maps_to_column WHERE g.maps_to_view IS NOT NULL AND g.maps_to_column IS NOT NULL AND m.catalog_id IS NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G4', 'RULE', N'Filter rules that fail when run on the real views', N'0', CAST((SELECT COUNT(*) FROM @res WHERE error_message IS NOT NULL) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G5', 'DATA', N'Filter rules that match no rows in your data', N'0', CAST((SELECT COUNT(*) FROM @res WHERE error_message IS NULL AND ISNULL(rows_matched, 0) = 0) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('G6', 'RULE', N'the glossary prompt block is not empty', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.vw_prompt_glossary) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));

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

/* ---------- Reference (not a test): what do the time words mean in YOUR data? ---------- */
SELECT r.last_order_date                                AS today_in_data,
       r.latest_month                                   AS this_month,
       DATEADD(MONTH, -1, r.latest_month)               AS last_month,
       DATEFROMPARTS(YEAR(r.last_order_date), 1, 1)     AS this_year_starts,
       DATEFROMPARTS(YEAR(r.last_order_date) - 1, 1, 1) AS last_year_starts,
       DATEADD(MONTH, -12, r.latest_month)              AS last_12_months_start
FROM semantic.vw_data_range r;
GO
