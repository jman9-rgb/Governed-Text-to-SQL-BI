/* =============================================================================
   20 EVALUATION
   Run once in SSMS. Safe to re-run (nothing is dropped; existing runs are kept).
   Needs Phases 5 (genbi.golden_question), 7 (genbi.sql_rule not required) and the app from Phase 11.

   What an evaluation is
     Every ACTIVE + APPROVED golden question is sent through the real pipeline
     (guardrails -> AI -> validator -> SQL as the agent user).  The reply is then compared with
     your answer key:
        behavior   did the AI answer / decline / redirect / clarify as expected?
        result     for answerable questions: do the returned numbers match the stored snapshot
                   (genbi.golden_question.expected_result_json)?
     Question passes when:  behavior is right  AND  (if it should answer) the result is right.

     genbi.eval_run      one row per evaluation run (label, prompt fingerprint, status)
     genbi.eval_result   one row per golden question per run
     views               vw_eval_summary, vw_eval_by_agent, vw_eval_by_type, vw_eval_failures,
                         vw_eval_changes (regressions and fixes vs the previous run), vw_eval_detail
     procedures          sp_eval_start, sp_eval_save, sp_eval_finish

   Evaluation runs do NOT write to genbi.query_log, so they never pollute real-usage monitoring.
   (Their AI calls still count in genbi.ai_usage, because they cost quota.)
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. Tables ---------- */
IF OBJECT_ID('genbi.eval_run') IS NULL
    CREATE TABLE genbi.eval_run (
        run_id       INT IDENTITY(1,1) PRIMARY KEY,
        started_at   DATETIME2(0)  NOT NULL CONSTRAINT DF_eval_run_started DEFAULT SYSDATETIME(),
        finished_at  DATETIME2(0)  NULL,
        label        NVARCHAR(100) NOT NULL,              -- e.g. 'baseline', 'after rule 12'
        status       NVARCHAR(10)  NOT NULL CONSTRAINT DF_eval_run_status DEFAULT N'running'
                     CHECK (status IN (N'running', N'partial', N'complete')),
        prompt_hash  CHAR(64)      NULL,                  -- fingerprint of the prompts used: tells you WHAT changed between runs
        note         NVARCHAR(300) NULL
    );
GO

IF OBJECT_ID('genbi.eval_result') IS NULL
    CREATE TABLE genbi.eval_result (
        run_id              INT           NOT NULL REFERENCES genbi.eval_run(run_id) ON DELETE CASCADE,
        golden_id           INT           NOT NULL REFERENCES genbi.golden_question(golden_id),
        evaluated_at        DATETIME2(0)  NOT NULL CONSTRAINT DF_eval_result_at DEFAULT SYSDATETIME(),
        expected_behavior   NVARCHAR(30)  NOT NULL,
        got_behavior        NVARCHAR(30)  NULL,
        behavior_ok         BIT           NOT NULL,      -- exact match
        behavior_family_ok  BIT           NOT NULL,      -- Answer and Answer-with-assumption count as the same family
        assumption_ok       BIT           NULL,          -- only when an assumption was expected
        result_ok           BIT           NULL,          -- only when an answer was expected
        passed              BIT           NOT NULL,
        failure_type        NVARCHAR(20)  NOT NULL
                            CHECK (failure_type IN (N'none', N'wrong_behavior', N'wrong_result', N'blocked',
                                                    N'sql_error', N'unreadable', N'guardrail', N'ai_error')),
        detail              NVARCHAR(400) NULL,
        expected_rows       INT           NULL,
        got_rows            INT           NULL,
        got_sql             NVARCHAR(MAX) NULL,
        got_note            NVARCHAR(1000) NULL,
        validator_verdict   NVARCHAR(30)  NULL,
        rule_codes          NVARCHAR(100) NULL,
        model               NVARCHAR(100) NULL,
        ai_calls            INT           NULL,
        from_cache          BIT           NOT NULL DEFAULT 0,
        in_tokens           INT           NULL,
        out_tokens          INT           NULL,
        run_ms              INT           NULL,          -- SQL run time
        total_ms            INT           NULL,          -- whole question
        CONSTRAINT PK_eval_result PRIMARY KEY (run_id, golden_id)
    );
GO

/* ---------- 2. Procedures ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_eval_start
    @label NVARCHAR(100), @prompt_hash CHAR(64) = NULL, @note NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT genbi.eval_run (label, prompt_hash, note) VALUES (LEFT(@label, 100), @prompt_hash, LEFT(@note, 300));
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS run_id;
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_eval_save       -- safe to call twice for the same question (resume / re-run)
    @run_id INT, @golden_id INT, @expected_behavior NVARCHAR(30), @got_behavior NVARCHAR(30),
    @behavior_ok BIT, @behavior_family_ok BIT, @assumption_ok BIT, @result_ok BIT, @passed BIT,
    @failure_type NVARCHAR(20), @detail NVARCHAR(400), @expected_rows INT, @got_rows INT,
    @got_sql NVARCHAR(MAX), @got_note NVARCHAR(1000), @validator_verdict NVARCHAR(30), @rule_codes NVARCHAR(100),
    @model NVARCHAR(100), @ai_calls INT, @from_cache BIT, @in_tokens INT, @out_tokens INT,
    @run_ms INT, @total_ms INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM genbi.eval_result WHERE run_id = @run_id AND golden_id = @golden_id;

    INSERT genbi.eval_result
        (run_id, golden_id, expected_behavior, got_behavior, behavior_ok, behavior_family_ok, assumption_ok,
         result_ok, passed, failure_type, detail, expected_rows, got_rows, got_sql, got_note,
         validator_verdict, rule_codes, model, ai_calls, from_cache, in_tokens, out_tokens, run_ms, total_ms)
    VALUES
        (@run_id, @golden_id, @expected_behavior, @got_behavior, @behavior_ok, @behavior_family_ok, @assumption_ok,
         @result_ok, @passed, @failure_type, LEFT(@detail, 400), @expected_rows, @got_rows, @got_sql, LEFT(@got_note, 1000),
         @validator_verdict, @rule_codes, @model, @ai_calls, ISNULL(@from_cache, 0), @in_tokens, @out_tokens, @run_ms, @total_ms);
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_eval_finish    -- complete = every active, approved golden question has a result
    @run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @wanted INT = (SELECT COUNT(*) FROM genbi.golden_question WHERE is_active = 1 AND review_status = 'Approved');
    DECLARE @done   INT = (SELECT COUNT(*) FROM genbi.eval_result WHERE run_id = @run_id);

    UPDATE genbi.eval_run
    SET    status = CASE WHEN @done >= @wanted THEN N'complete' ELSE N'partial' END,
           finished_at = SYSDATETIME()
    WHERE  run_id = @run_id;

    SELECT * FROM genbi.vw_eval_summary WHERE run_id = @run_id;
END;
GO

/* ---------- 3. Views ---------- */
CREATE OR ALTER VIEW genbi.vw_eval_summary
AS
SELECT  r.run_id, r.started_at, r.label, r.status,
        COUNT(e.golden_id)                                                         AS questions,
        SUM(CAST(e.passed AS INT))                                                 AS passed,
        CAST(100.0 * SUM(CAST(e.passed AS INT))       / NULLIF(COUNT(e.golden_id), 0)   AS DECIMAL(5,2)) AS pass_pct,
        CAST(100.0 * SUM(CAST(e.behavior_ok AS INT))  / NULLIF(COUNT(e.golden_id), 0)   AS DECIMAL(5,2)) AS behavior_ok_pct,
        CAST(100.0 * SUM(CAST(e.result_ok AS INT))    / NULLIF(COUNT(e.result_ok), 0)   AS DECIMAL(5,2)) AS result_ok_pct,
        CAST(100.0 * SUM(CAST(e.assumption_ok AS INT))/ NULLIF(COUNT(e.assumption_ok), 0) AS DECIMAL(5,2)) AS assumption_ok_pct,
        SUM(CASE WHEN e.failure_type = N'blocked'   THEN 1 ELSE 0 END)             AS blocked,
        SUM(CASE WHEN e.failure_type = N'sql_error' THEN 1 ELSE 0 END)             AS sql_errors,
        SUM(ISNULL(e.ai_calls, 0))                                                 AS ai_calls,
        SUM(CAST(e.from_cache AS INT))                                             AS cache_hits,
        AVG(e.total_ms)                                                            AS avg_total_ms,
        SUM(ISNULL(e.in_tokens, 0))                                                AS in_tokens,
        SUM(ISNULL(e.out_tokens, 0))                                               AS out_tokens
FROM    genbi.eval_run r
LEFT JOIN genbi.eval_result e ON e.run_id = r.run_id
GROUP BY r.run_id, r.started_at, r.label, r.status;
GO

CREATE OR ALTER VIEW genbi.vw_eval_by_agent
AS
SELECT  e.run_id, g.agent_name,
        COUNT(*) AS questions, SUM(CAST(e.passed AS INT)) AS passed,
        CAST(100.0 * SUM(CAST(e.passed AS INT)) / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS pass_pct
FROM    genbi.eval_result e
JOIN    genbi.golden_question g ON g.golden_id = e.golden_id
GROUP BY e.run_id, g.agent_name;
GO

CREATE OR ALTER VIEW genbi.vw_eval_by_type
AS
SELECT  e.run_id, g.question_type, g.difficulty,
        COUNT(*) AS questions, SUM(CAST(e.passed AS INT)) AS passed,
        CAST(100.0 * SUM(CAST(e.passed AS INT)) / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS pass_pct
FROM    genbi.eval_result e
JOIN    genbi.golden_question g ON g.golden_id = e.golden_id
GROUP BY e.run_id, g.question_type, g.difficulty;
GO

CREATE OR ALTER VIEW genbi.vw_eval_failures
AS
SELECT  e.run_id, e.golden_id, g.agent_name, g.question, g.question_type, g.difficulty,
        e.expected_behavior, e.got_behavior, e.failure_type, e.detail,
        e.expected_rows, e.got_rows, g.expected_sql, e.got_sql, e.got_note,
        e.validator_verdict, e.rule_codes, e.model
FROM    genbi.eval_result e
JOIN    genbi.golden_question g ON g.golden_id = e.golden_id
WHERE   e.passed = 0;
GO

CREATE OR ALTER VIEW genbi.vw_eval_detail          -- one row per question per run: the fact table for Power BI
AS
SELECT  e.run_id, r.label, r.started_at, e.golden_id, g.agent_name, g.question, g.question_type, g.difficulty,
        e.expected_behavior, e.got_behavior, e.behavior_ok, e.result_ok, e.passed, e.failure_type,
        e.expected_rows, e.got_rows, e.from_cache, e.ai_calls, e.in_tokens, e.out_tokens, e.run_ms, e.total_ms, e.model
FROM    genbi.eval_result e
JOIN    genbi.eval_run r ON r.run_id = e.run_id
JOIN    genbi.golden_question g ON g.golden_id = e.golden_id;
GO

CREATE OR ALTER VIEW genbi.vw_eval_changes         -- latest run vs the run before it, question by question
AS
WITH x AS (
    SELECT  e.run_id, e.golden_id, e.passed, e.failure_type, e.detail,
            LAG(e.passed) OVER (PARTITION BY e.golden_id ORDER BY e.run_id) AS prev_passed,
            LAG(e.run_id) OVER (PARTITION BY e.golden_id ORDER BY e.run_id) AS prev_run_id
    FROM    genbi.eval_result e
)
SELECT  x.run_id, x.prev_run_id, x.golden_id, g.agent_name, g.question,
        CASE WHEN x.passed = 0 AND x.prev_passed = 1 THEN N'regression' ELSE N'fixed' END AS change_type,
        x.failure_type, x.detail
FROM    x
JOIN    genbi.golden_question g ON g.golden_id = x.golden_id
WHERE   x.run_id = (SELECT MAX(run_id) FROM genbi.eval_run)
  AND   x.prev_passed IS NOT NULL
  AND   x.passed <> x.prev_passed;
GO
