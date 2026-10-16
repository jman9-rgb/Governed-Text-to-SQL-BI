/* =============================================================================
   17 COST GUARDRAILS
   Run once in SSMS. Safe to re-run (nothing is dropped; existing data is kept).

   What it adds
     genbi.guardrail     the limits, editable with a simple UPDATE (no code change)
     genbi.ai_usage      one row per AI call (or per cache hit): the cost ledger
     genbi.answer_cache  remembers AI replies, so a repeated question costs no AI call
     views               vw_budget_today (budget left), vw_usage_daily (for Power BI later)
     procedures          sp_log_ai_call, sp_cache_get, sp_cache_put, sp_cache_clear

   Uses only what exists already: nothing here touches your Gold, semantic or agent tables.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. The limits ---------- */
IF OBJECT_ID('genbi.guardrail') IS NULL
    CREATE TABLE genbi.guardrail (
        guardrail_name NVARCHAR(50)  NOT NULL PRIMARY KEY,
        limit_value    INT           NOT NULL CHECK (limit_value >= 0),
        description    NVARCHAR(300) NOT NULL
    );
GO

MERGE genbi.guardrail AS t
USING (VALUES
    (N'daily_ai_calls',            100,  N'Maximum AI (Gemini) calls per day. Set it BELOW your real free-tier quota.'),
    (N'max_ai_calls_per_question', 3,    N'Maximum AI calls for one question (retries and fallback models count).'),
    (N'max_rows',                  1000, N'Maximum result rows pulled into the app.'),
    (N'query_timeout_sec',         120,  N'A SQL query running longer than this is cancelled.'),
    (N'max_output_tokens',         4096, N'Maximum tokens the AI may write in one reply.'),
    (N'max_prompt_chars',          60000,N'Maximum size of the prompt (business context, views, metrics, glossary) in characters.'),
    (N'max_question_chars',        500,  N'Maximum length of a user question in characters.'),
    (N'cache_ttl_minutes',         60,   N'How long a cached AI reply may be reused.')
) AS s (guardrail_name, limit_value, description)
ON t.guardrail_name = s.guardrail_name
WHEN NOT MATCHED THEN                       -- never overwrites a value you changed on purpose
    INSERT (guardrail_name, limit_value, description) VALUES (s.guardrail_name, s.limit_value, s.description);
GO

/* ---------- 2. The cost ledger: one row per AI call, and one per cache hit ---------- */
IF OBJECT_ID('genbi.ai_usage') IS NULL
BEGIN
    CREATE TABLE genbi.ai_usage (
        usage_id    INT IDENTITY(1,1) PRIMARY KEY,
        called_at   DATETIME2(0)  NOT NULL CONSTRAINT DF_ai_usage_called_at DEFAULT SYSDATETIME(),
        agent_name  NVARCHAR(100) NULL,
        model       NVARCHAR(100) NULL,
        source      NVARCHAR(10)  NOT NULL CHECK (source IN (N'api', N'cache')),
        in_tokens   INT           NOT NULL DEFAULT 0,
        out_tokens  INT           NOT NULL DEFAULT 0,
        status      NVARCHAR(10)  NOT NULL CHECK (status IN (N'ok', N'error')),
        error_text  NVARCHAR(400) NULL
    );
    CREATE INDEX IX_ai_usage_called_at ON genbi.ai_usage(called_at);
END;
GO

/* ---------- 3. The answer cache (stores the AI reply only; the SQL is always re-validated and re-run) ---------- */
IF OBJECT_ID('genbi.answer_cache') IS NULL
    CREATE TABLE genbi.answer_cache (
        cache_key    CHAR(64)       NOT NULL PRIMARY KEY,   -- SHA-256 of agent + prompt + normalised question
        agent_name   NVARCHAR(100)  NOT NULL,
        question     NVARCHAR(500)  NOT NULL,
        behavior     NVARCHAR(40)   NOT NULL,
        sql_text     NVARCHAR(MAX)  NULL,
        note         NVARCHAR(MAX)  NULL,
        created_at   DATETIME2(0)   NOT NULL,
        last_hit_at  DATETIME2(0)   NULL,
        hit_count    INT            NOT NULL DEFAULT 0
    );
GO

/* ---------- 4. Views ---------- */
CREATE OR ALTER VIEW genbi.vw_budget_today
AS
SELECT  ISNULL(SUM(CASE WHEN u.source = N'api' THEN 1 ELSE 0 END), 0)                      AS api_calls_today,
        g.limit_value                                                                      AS daily_limit,
        g.limit_value - ISNULL(SUM(CASE WHEN u.source = N'api' THEN 1 ELSE 0 END), 0)      AS remaining
FROM    genbi.guardrail g
LEFT JOIN genbi.ai_usage u
       ON u.called_at >= CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0))
      AND u.called_at <  DATEADD(DAY, 1, CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0)))
WHERE   g.guardrail_name = N'daily_ai_calls'
GROUP BY g.limit_value;
GO

CREATE OR ALTER VIEW genbi.vw_usage_daily
AS
SELECT  CAST(called_at AS DATE)                                              AS usage_date,
        agent_name,
        SUM(CASE WHEN source = N'api'   THEN 1 ELSE 0 END)                   AS api_calls,
        SUM(CASE WHEN source = N'cache' THEN 1 ELSE 0 END)                   AS cache_hits,
        SUM(CASE WHEN source = N'api' AND status = N'error' THEN 1 ELSE 0 END) AS failed_calls,
        SUM(in_tokens)                                                       AS in_tokens,
        SUM(out_tokens)                                                      AS out_tokens,
        CAST(100.0 * SUM(CASE WHEN source = N'cache' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                          AS cache_hit_pct
FROM    genbi.ai_usage
GROUP BY CAST(called_at AS DATE), agent_name;
GO

/* ---------- 5. Procedures ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_log_ai_call
    @agent_name NVARCHAR(100), @model NVARCHAR(100), @source NVARCHAR(10),
    @in_tokens INT, @out_tokens INT, @status NVARCHAR(10), @error_text NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT genbi.ai_usage (agent_name, model, source, in_tokens, out_tokens, status, error_text)
    VALUES (@agent_name, @model, @source, ISNULL(@in_tokens, 0), ISNULL(@out_tokens, 0), @status, LEFT(@error_text, 400));
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_cache_get
    @cache_key CHAR(64), @ttl_minutes INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT behavior, sql_text, note
    FROM   genbi.answer_cache
    WHERE  cache_key = @cache_key
      AND  created_at >= DATEADD(MINUTE, -@ttl_minutes, SYSDATETIME());

    IF @@ROWCOUNT > 0
        UPDATE genbi.answer_cache
        SET    hit_count = hit_count + 1, last_hit_at = SYSDATETIME()
        WHERE  cache_key = @cache_key;
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_cache_put
    @cache_key CHAR(64), @agent_name NVARCHAR(100), @question NVARCHAR(500),
    @behavior NVARCHAR(40), @sql_text NVARCHAR(MAX), @note NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    MERGE genbi.answer_cache AS t
    USING (SELECT @cache_key AS cache_key) AS s ON t.cache_key = s.cache_key
    WHEN MATCHED THEN
        UPDATE SET behavior = @behavior, sql_text = @sql_text, note = @note,
                   created_at = SYSDATETIME(), hit_count = 0, last_hit_at = NULL
    WHEN NOT MATCHED THEN
        INSERT (cache_key, agent_name, question, behavior, sql_text, note, created_at)
        VALUES (@cache_key, @agent_name, LEFT(@question, 500), @behavior, @sql_text, @note, SYSDATETIME());
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_cache_clear      -- use after you change the glossary, metrics or scope
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM genbi.answer_cache;
END;
GO
