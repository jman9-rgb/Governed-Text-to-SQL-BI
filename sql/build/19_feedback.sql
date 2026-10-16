/* =============================================================================
   19 FEEDBACK SYSTEM
   Run once in SSMS. Safe to re-run (nothing is dropped; existing feedback is kept).
   Needs Phase 9 (genbi.query_log) and Phase 8 (genbi.answer_cache).

   The loop:   user rates an answer (thumbs up / down + reason)
               -> a thumbs-down also removes that answer from the cache
               -> you review the down-votes in SSMS (sp_review_feedback) and say what to fix
               -> confirmed issues become the improvement backlog (Phase 13)

     genbi.feedback_reason   the reason list (drives the app drop-down and Power BI)
     genbi.feedback          one rating per logged question (a user can change it)
     views                   vw_feedback_queue, vw_feedback_daily, vw_feedback_reasons, vw_improvement_backlog
     procedures              sp_submit_feedback, sp_review_feedback, sp_cache_evict
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. Reasons ---------- */
IF OBJECT_ID('genbi.feedback_reason') IS NULL
    CREATE TABLE genbi.feedback_reason (
        reason_code NVARCHAR(30)  NOT NULL PRIMARY KEY,
        description NVARCHAR(200) NOT NULL,
        sort_order  INT           NOT NULL
    );
GO

MERGE genbi.feedback_reason AS t
USING (VALUES
    (N'wrong_number',     N'The number is wrong',                                         1),
    (N'wrong_logic',      N'The calculation, filter or time period is wrong',             2),
    (N'misunderstood',    N'It misunderstood my question',                                3),
    (N'should_answer',    N'It should have answered, but declined or redirected',        4),
    (N'should_not_answer',N'It answered something it should have declined',               5),
    (N'too_slow',         N'It was too slow',                                             6),
    (N'other',            N'Something else (please add a comment)',                       7)
) AS s (reason_code, description, sort_order)
ON t.reason_code = s.reason_code
WHEN NOT MATCHED THEN INSERT (reason_code, description, sort_order) VALUES (s.reason_code, s.description, s.sort_order);
GO

/* ---------- 2. Feedback ---------- */
IF OBJECT_ID('genbi.feedback') IS NULL
    CREATE TABLE genbi.feedback (
        feedback_id   INT IDENTITY(1,1) PRIMARY KEY,
        log_id        INT           NOT NULL UNIQUE
                      REFERENCES genbi.query_log(log_id) ON DELETE CASCADE,   -- one rating per question
        created_at    DATETIME2(0)  NOT NULL CONSTRAINT DF_feedback_created_at DEFAULT SYSDATETIME(),
        rating        NVARCHAR(10)  NOT NULL CHECK (rating IN (N'up', N'down')),
        reason_code   NVARCHAR(30)  NULL REFERENCES genbi.feedback_reason(reason_code),
        comment       NVARCHAR(500) NULL,
        -- review (done by you, the analyst, for thumbs-down items)
        review_status NVARCHAR(20)  NOT NULL CONSTRAINT DF_feedback_review_status DEFAULT N'new'
                      CHECK (review_status IN (N'new', N'confirmed_issue', N'not_an_issue', N'fixed')),
        fix_type      NVARCHAR(30)  NULL
                      CHECK (fix_type IN (N'context', N'metric', N'glossary', N'scope', N'prompt_rule',
                                          N'validator_rule', N'golden_question', N'none')),
        reviewer_note NVARCHAR(500) NULL,
        reviewed_at   DATETIME2(0)  NULL
    );
GO

/* ---------- 3. Procedures ---------- */
CREATE OR ALTER PROCEDURE genbi.sp_submit_feedback
    @log_id INT, @rating NVARCHAR(10), @reason_code NVARCHAR(30) = NULL, @comment NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM genbi.query_log WHERE log_id = @log_id)
        THROW 50001, N'That log_id does not exist.', 1;
    IF @rating NOT IN (N'up', N'down')
        THROW 50002, N'rating must be up or down.', 1;

    IF @rating = N'up'
        SET @reason_code = NULL;
    ELSE IF @reason_code IS NULL
         OR NOT EXISTS (SELECT 1 FROM genbi.feedback_reason WHERE reason_code = @reason_code)
        SET @reason_code = N'other';

    MERGE genbi.feedback AS t
    USING (SELECT @log_id AS log_id) AS s ON t.log_id = s.log_id
    WHEN MATCHED THEN
        UPDATE SET rating = @rating, reason_code = @reason_code,
                   comment = LEFT(@comment, 500), created_at = SYSDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (log_id, rating, reason_code, comment) VALUES (@log_id, @rating, @reason_code, LEFT(@comment, 500));

    SELECT feedback_id FROM genbi.feedback WHERE log_id = @log_id;
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_review_feedback
    @feedback_id INT, @review_status NVARCHAR(20), @fix_type NVARCHAR(30) = NULL, @reviewer_note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM genbi.feedback WHERE feedback_id = @feedback_id)
        THROW 50003, N'That feedback_id does not exist.', 1;
    IF @review_status NOT IN (N'new', N'confirmed_issue', N'not_an_issue', N'fixed')
        THROW 50004, N'review_status must be new, confirmed_issue, not_an_issue or fixed.', 1;
    IF @review_status IN (N'confirmed_issue', N'fixed') AND @fix_type IS NULL
        THROW 50005, N'Say what needs fixing: fix_type is required for confirmed_issue and fixed.', 1;

    IF @review_status = N'not_an_issue'
        SET @fix_type = N'none';

    UPDATE genbi.feedback
    SET    review_status = @review_status,
           fix_type      = @fix_type,
           reviewer_note = LEFT(@reviewer_note, 500),
           reviewed_at   = SYSDATETIME()
    WHERE  feedback_id = @feedback_id;
END;
GO

CREATE OR ALTER PROCEDURE genbi.sp_cache_evict      -- a thumbs-down must not keep serving the same answer
    @cache_key CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM genbi.answer_cache WHERE cache_key = @cache_key;
END;
GO

/* ---------- 4. Views ---------- */
CREATE OR ALTER VIEW genbi.vw_feedback_queue         -- thumbs-down items still waiting for your review
AS
SELECT  f.feedback_id, f.log_id, f.created_at, l.agent_name, l.question, l.behavior, l.outcome,
        l.validator_verdict, l.row_count, l.sql_text, l.note AS ai_note,
        f.reason_code, r.description AS reason, f.comment,
        DATEDIFF(DAY, f.created_at, SYSDATETIME()) AS age_days
FROM    genbi.feedback f
JOIN    genbi.query_log l ON l.log_id = f.log_id
LEFT JOIN genbi.feedback_reason r ON r.reason_code = f.reason_code
WHERE   f.rating = N'down' AND f.review_status = N'new';
GO

CREATE OR ALTER VIEW genbi.vw_feedback_daily
AS
SELECT  CAST(l.asked_at AS DATE)                               AS log_date,
        l.agent_name,
        COUNT(*)                                               AS questions,
        COUNT(f.feedback_id)                                   AS rated,
        SUM(CASE WHEN f.rating = N'up'   THEN 1 ELSE 0 END)    AS thumbs_up,
        SUM(CASE WHEN f.rating = N'down' THEN 1 ELSE 0 END)    AS thumbs_down,
        CAST(100.0 * COUNT(f.feedback_id) / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS rated_pct,
        CAST(100.0 * SUM(CASE WHEN f.rating = N'up' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(f.feedback_id), 0) AS DECIMAL(5,2)) AS satisfaction_pct
FROM    genbi.query_log l
LEFT JOIN genbi.feedback f ON f.log_id = l.log_id
GROUP BY CAST(l.asked_at AS DATE), l.agent_name;
GO

CREATE OR ALTER VIEW genbi.vw_feedback_reasons       -- why people say "not right"
AS
SELECT  l.agent_name, f.reason_code, r.description AS reason,
        COUNT(*) AS thumbs_down,
        SUM(CASE WHEN f.review_status = N'confirmed_issue' THEN 1 ELSE 0 END) AS confirmed,
        SUM(CASE WHEN f.review_status = N'not_an_issue'    THEN 1 ELSE 0 END) AS not_an_issue,
        SUM(CASE WHEN f.review_status = N'new'             THEN 1 ELSE 0 END) AS waiting_review
FROM    genbi.feedback f
JOIN    genbi.query_log l ON l.log_id = f.log_id
LEFT JOIN genbi.feedback_reason r ON r.reason_code = f.reason_code
WHERE   f.rating = N'down'
GROUP BY l.agent_name, f.reason_code, r.description;
GO

CREATE OR ALTER VIEW genbi.vw_improvement_backlog    -- confirmed problems not fixed yet (input of Phase 13)
AS
SELECT  f.feedback_id, f.log_id, l.agent_name, l.question, l.behavior, l.sql_text,
        f.reason_code, f.fix_type, f.reviewer_note, f.reviewed_at,
        DATEDIFF(DAY, f.reviewed_at, SYSDATETIME()) AS days_open
FROM    genbi.feedback f
JOIN    genbi.query_log l ON l.log_id = f.log_id
WHERE   f.review_status = N'confirmed_issue';
GO
