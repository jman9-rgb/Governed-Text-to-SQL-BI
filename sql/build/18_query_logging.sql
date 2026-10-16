/* =============================================================================
   18 QUERY LOGGING
   Run once in SSMS. Safe to re-run (nothing is dropped; existing log rows are kept).

   Phase 8 (genbi.ai_usage) records AI calls = COST.
   Phase 9 records every QUESTION = what users ask, what the system did, and how well.

     genbi.query_log        one row per question (answered, declined, blocked, failed, stopped)
     genbi.query_log_rule   the validator rule codes (V01..V11) hit by each question
     views                  vw_query_log_recent, vw_query_log_daily, vw_rule_hits, vw_slow_queries
     procedures             sp_log_query, sp_log_query_rule, sp_purge_query_log

   Phase 10 (feedback) will point at query_log.log_id. Phase 12 (Power BI) reads these views.
   Needs Phase 7 (genbi.sql_rule) only for the rule descriptions in vw_rule_hits.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. The question log ---------- */
IF OBJECT_ID('genbi.query_log') IS NULL
    CREATE TABLE genbi.query_log (
        log_id            INT IDENTITY(1,1) PRIMARY KEY,
        asked_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_query_log_asked_at DEFAULT SYSDATETIME(),
        agent_name        NVARCHAR(100)  NULL,
        question          NVARCHAR(500)  NOT NULL,
        behavior          NVARCHAR(40)   NULL,     -- what the AI decided: Answer, Decline, Redirect, ...
        outcome           NVARCHAR(20)   NOT NULL, -- what happened overall (see CHECK)
        note              NVARCHAR(1000) NULL,     -- the AI's note / assumption shown to the user
        sql_text          NVARCHAR(MAX)  NULL,
        validator_verdict NVARCHAR(30)   NULL,     -- PASS, PASS WITH WARNINGS, BLOCKED
        rule_codes        NVARCHAR(100)  NULL,     -- for reading; the analysable copy is query_log_rule
        executed          BIT            NOT NULL DEFAULT 0,   -- was the SQL sent to the database?
        row_count         INT            NULL,
        run_ms            INT            NULL,     -- SQL run time
        total_ms          INT            NULL,     -- whole question, end to end
        from_cache        BIT            NOT NULL DEFAULT 0,
        ai_calls          INT            NULL,
        model             NVARCHAR(100)  NULL,
        in_tokens         INT            NULL,
        out_tokens        INT            NULL,
        retried           BIT            NOT NULL DEFAULT 0,   -- retried once after a SQL timeout
        error_text        NVARCHAR(600)  NULL,
        CONSTRAINT CK_query_log_outcome CHECK (outcome IN
            (N'answered', N'not_answered', N'blocked', N'sql_error', N'guardrail', N'ai_error', N'unreadable'))
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_query_log_asked_at' AND object_id = OBJECT_ID('genbi.query_log'))
    CREATE INDEX IX_query_log_asked_at ON genbi.query_log(asked_at);
GO

IF OBJECT_ID('genbi.query_log_rule') IS NULL
    CREATE TABLE genbi.query_log_rule (
        log_id    INT          NOT NULL REFERENCES genbi.query_log(log_id) ON DELETE CASCADE,
        rule_code NVARCHAR(10) NOT NULL,
        PRIMARY KEY (log_id, rule_code)
    );
GO

/* ---------- 2. Procedures ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_log_query
    @agent_name NVARCHAR(100), @question NVARCHAR(500), @behavior NVARCHAR(40), @outcome NVARCHAR(20),
    @note NVARCHAR(1000), @sql_text NVARCHAR(MAX), @validator_verdict NVARCHAR(30), @rule_codes NVARCHAR(100),
    @executed BIT, @row_count INT, @run_ms INT, @total_ms INT, @from_cache BIT, @ai_calls INT,
    @model NVARCHAR(100), @in_tokens INT, @out_tokens INT, @retried BIT, @error_text NVARCHAR(600)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT genbi.query_log
        (agent_name, question, behavior, outcome, note, sql_text, validator_verdict, rule_codes,
         executed, row_count, run_ms, total_ms, from_cache, ai_calls, model, in_tokens, out_tokens, retried, error_text)
    VALUES
        (@agent_name, LEFT(@question, 500), @behavior, @outcome, LEFT(@note, 1000), @sql_text, @validator_verdict, @rule_codes,
         ISNULL(@executed, 0), @row_count, @run_ms, @total_ms, ISNULL(@from_cache, 0), @ai_calls, @model,
         @in_tokens, @out_tokens, ISNULL(@retried, 0), LEFT(@error_text, 600));

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS log_id;       -- the app shows it, Phase 10 feedback uses it
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_log_query_rule
    @log_id INT, @rule_code NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM genbi.query_log_rule WHERE log_id = @log_id AND rule_code = @rule_code)
        INSERT genbi.query_log_rule (log_id, rule_code) VALUES (@log_id, @rule_code);
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_purge_query_log     -- retention: keep the log small and private
    @keep_days INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM genbi.query_log WHERE asked_at < DATEADD(DAY, -@keep_days, SYSDATETIME());
    SELECT @@ROWCOUNT AS rows_deleted;                  -- rule rows are removed with them (CASCADE)
END;
GO

/* ---------- 3. Views ---------- */
CREATE OR ALTER VIEW genbi.vw_query_log_recent
AS
SELECT TOP (100)
       log_id, asked_at, agent_name, question, behavior, outcome, validator_verdict, rule_codes,
       row_count, run_ms, total_ms, from_cache, model, error_text
FROM   genbi.query_log
ORDER BY log_id DESC;
GO

CREATE OR ALTER VIEW genbi.vw_query_log_daily
AS
SELECT  CAST(asked_at AS DATE)                                                    AS log_date,
        agent_name,
        COUNT(*)                                                                  AS questions,
        SUM(CASE WHEN outcome = N'answered'     THEN 1 ELSE 0 END)                AS answered,
        SUM(CASE WHEN outcome = N'not_answered' THEN 1 ELSE 0 END)                AS not_answered,
        SUM(CASE WHEN outcome = N'blocked'      THEN 1 ELSE 0 END)                AS blocked,
        SUM(CASE WHEN outcome = N'sql_error'    THEN 1 ELSE 0 END)                AS sql_errors,
        SUM(CASE WHEN outcome = N'guardrail'    THEN 1 ELSE 0 END)                AS guardrail_stops,
        SUM(CASE WHEN outcome IN (N'ai_error', N'unreadable') THEN 1 ELSE 0 END)  AS ai_failures,
        SUM(CAST(from_cache AS INT))                                              AS cache_hits,
        AVG(total_ms)                                                             AS avg_total_ms,
        AVG(run_ms)                                                               AS avg_sql_ms,
        CAST(100.0 * SUM(CASE WHEN outcome = N'answered' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                               AS answered_pct
FROM    genbi.query_log
GROUP BY CAST(asked_at AS DATE), agent_name;
GO

CREATE OR ALTER VIEW genbi.vw_rule_hits
AS
SELECT  r.rule_code, s.severity, s.description,
        COUNT(*)         AS hits,
        MAX(l.asked_at)  AS last_seen
FROM    genbi.query_log_rule r
JOIN    genbi.query_log l ON l.log_id = r.log_id
LEFT JOIN genbi.sql_rule s ON s.rule_code = r.rule_code
GROUP BY r.rule_code, s.severity, s.description;
GO

CREATE OR ALTER VIEW genbi.vw_slow_queries
AS
SELECT TOP (20)
       log_id, asked_at, agent_name, question, run_ms, row_count, retried, sql_text
FROM   genbi.query_log
WHERE  executed = 1 AND run_ms IS NOT NULL
ORDER BY run_ms DESC;
GO
