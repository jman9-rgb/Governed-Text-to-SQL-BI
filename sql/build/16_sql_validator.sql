/* =============================================================================
   16 SQL VALIDATOR
   Run once in SSMS. Safe to re-run.

   Layer 1  genbi_validator.py   text rules in the app (before anything touches the database)
   Layer 2  genbi.sp_dry_run     SQL Server compiles the query AS THE AGENT USER, without running it
   Layer 3  agent permissions    Phase 4: the final wall inside the database

   Nothing here invents names: it only uses genbi.agent (agent_name, db_user, is_active),
   which already exists from Phase 4.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. Rule catalog (the same rule codes the app uses; later logged in Phase 9) ---------- */
IF OBJECT_ID('genbi.sql_rule') IS NULL
    CREATE TABLE genbi.sql_rule (
        rule_code    NVARCHAR(10)  NOT NULL PRIMARY KEY,
        severity     NVARCHAR(10)  NOT NULL CHECK (severity IN (N'BLOCK', N'WARN')),
        description  NVARCHAR(300) NOT NULL
    );
GO

MERGE genbi.sql_rule AS t
USING (VALUES
    (N'V01', N'BLOCK', N'SQL is empty or longer than the allowed size'),
    (N'V02', N'BLOCK', N'Query must start with SELECT or WITH'),
    (N'V03', N'BLOCK', N'Only one statement is allowed'),
    (N'V04', N'BLOCK', N'Comments are not allowed in generated SQL'),
    (N'V05', N'BLOCK', N'Forbidden keyword (data change, DDL, EXEC, permissions, external access)'),
    (N'V06', N'BLOCK', N'Object is not one of the views this agent may use (write it as semantic.<view>)'),
    (N'V07', N'WARN', N'SELECT * used; list the columns instead'),
    (N'V08', N'BLOCK', N'Current-date function used; relative dates must come from semantic.vw_data_range'),
    (N'V09', N'WARN', N'TOP without ORDER BY gives a different result on each run'),
    (N'V10', N'BLOCK', N'Unbalanced quote in the SQL text'),
    (N'V11', N'BLOCK', N'SQL Server dry run failed (does not compile for this agent)')
) AS s (rule_code, severity, description)
ON t.rule_code = s.rule_code
WHEN MATCHED THEN UPDATE SET severity = s.severity, description = s.description
WHEN NOT MATCHED THEN INSERT (rule_code, severity, description) VALUES (s.rule_code, s.severity, s.description);
GO

/* ---------- 2. Dry run: does this SQL compile for this agent? Nothing is executed. ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_dry_run
    @agent_name NVARCHAR(100),
    @sql        NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @db_user SYSNAME =
        (SELECT TOP (1) db_user FROM genbi.agent WHERE agent_name = @agent_name AND is_active = 1);

    DECLARE @err_no INT = NULL, @err_msg NVARCHAR(2048) = NULL, @cols INT = 0;

    IF @db_user IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS is_ok, 0 AS column_count, 0 AS error_number,
               N'Unknown or inactive agent' AS error_message;
        RETURN;
    END;

    BEGIN TRY
        EXECUTE AS USER = @db_user;          -- from here on, SQL Server applies the agent's permissions

        SELECT @err_no  = MAX(error_number),
               @err_msg = MAX(error_message),
               @cols    = SUM(CASE WHEN error_number IS NULL AND ISNULL(is_hidden, 0) = 0 THEN 1 ELSE 0 END)
        FROM sys.dm_exec_describe_first_result_set(@sql, NULL, 0);

        REVERT;
    END TRY
    BEGIN CATCH
        IF USER_NAME() = @db_user REVERT;
        SET @err_no  = ERROR_NUMBER();
        SET @err_msg = ERROR_MESSAGE();
    END CATCH;

    SELECT CAST(CASE WHEN @err_no IS NULL AND ISNULL(@cols, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS is_ok,
           ISNULL(@cols, 0)    AS column_count,
           ISNULL(@err_no, 0)  AS error_number,
           ISNULL(@err_msg, N'') AS error_message;
END;
GO
