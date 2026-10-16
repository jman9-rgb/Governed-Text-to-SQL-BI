/* =============================================================================
   TESTS: STEP 09 READ-ONLY USER (optional step)
   Requires step 09 in THIS database. In a test copy the server login may already exist: step 09 then only creates the database user and permissions.
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

DECLARE @sem NVARCHAR(10) = N'DENIED', @gold NVARCHAR(10) = N'ALLOWED', @err INT = NULL, @x INT;

IF DATABASE_PRINCIPAL_ID('genbi_reader') IS NOT NULL
BEGIN
    BEGIN TRY
        EXECUTE AS USER = 'genbi_reader';
        SELECT TOP (1) @x = 1 FROM semantic.vw_sales;
        SET @sem = N'ALLOWED';
        REVERT;
    END TRY
    BEGIN CATCH
        IF USER_NAME() = 'genbi_reader' REVERT;
    END CATCH;

    BEGIN TRY
        EXECUTE AS USER = 'genbi_reader';
        SELECT TOP (1) @x = 1 FROM gold.fact_sales;
        REVERT;                                   -- only reached when gold is readable (a problem)
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER();
        IF USER_NAME() = 'genbi_reader' REVERT;
        SET @gold = N'DENIED';
    END CATCH;
END;

INSERT #t (id, kind, test, expected, actual) VALUES ('P1', 'RULE', N'database user genbi_reader exists (run step 09 first)', N'1', CAST((SELECT COUNT(*) FROM sys.database_principals WHERE name = 'genbi_reader') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('P2', 'RULE', N'genbi_reader can read semantic.vw_sales', N'ALLOWED', CAST((SELECT @sem) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('P3', 'RULE', N'genbi_reader cannot read gold.fact_sales', N'DENIED', CAST((SELECT @gold) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('P4', 'RULE', N'the denial is permission error 229', N'229', CAST((SELECT @err) AS NVARCHAR(200)));

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
