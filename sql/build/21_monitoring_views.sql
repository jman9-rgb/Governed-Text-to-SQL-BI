/* =============================================================================
   21 MONITORING VIEWS FOR POWER BI AND TABLEAU
   Run once in SSMS. Safe to re-run (views are CREATE OR ALTER, nothing is dropped).

   Power BI never reads the raw log tables. It reads ONE small reporting layer:

     genbi.vw_mon_date        calendar (one row per day)            -> the shared date table
     genbi.vw_mon_questions   one row per user question (+ rating)  -> usage, quality, speed
     genbi.vw_mon_ai_usage    one row per AI call / cache hit       -> cost
     genbi.vw_mon_rules       one row per validator rule hit        -> SQL safety
     genbi.vw_mon_eval        one row per golden question per run   -> accuracy over time
     genbi.vw_mon_golden      the golden question set itself        -> test-set health
     genbi.vw_mon_agent       the three agents                      -> shared agent filter
     genbi.vw_mon_scorecard   ONE row: today's health numbers       -> top-of-page cards

   Plus a read-only role (genbi_monitor) that can read ONLY these views
   (and the Phase 10/11 review views) - never the tables, never the data warehouse.

   Needs Phases 7-11. Test rows (agent_name = 'test_agent') are hidden from every view.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 1. Calendar ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_date
AS
WITH b AS (
    SELECT MIN(d) AS first_day
    FROM (
        SELECT CAST(MIN(asked_at)   AS DATE) AS d FROM genbi.query_log
        UNION ALL SELECT CAST(MIN(called_at)  AS DATE) FROM genbi.ai_usage
        UNION ALL SELECT CAST(MIN(started_at) AS DATE) FROM genbi.eval_run
    ) x
),
n AS (
    SELECT TOP (400) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects c
)
SELECT  dt.date_value,
        YEAR(dt.date_value)                                                  AS year_no,
        DATEFROMPARTS(YEAR(dt.date_value), MONTH(dt.date_value), 1)          AS month_start,
        DATENAME(MONTH, dt.date_value)                                       AS month_name,
        DATENAME(WEEKDAY, dt.date_value)                                     AS weekday_name,
        CASE WHEN DATEPART(WEEKDAY, dt.date_value) IN (1, 7) THEN 1 ELSE 0 END AS is_weekend   -- default US setting: 1=Sun, 7=Sat
FROM    n
CROSS JOIN b
CROSS APPLY (SELECT DATEADD(DAY, n.i, ISNULL(b.first_day, CAST(SYSDATETIME() AS DATE))) AS date_value) dt
WHERE   dt.date_value <= CAST(SYSDATETIME() AS DATE);      -- no future dates in the slicer
GO

/* ---------- 2. Agents ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_agent
AS
SELECT DISTINCT agent_name FROM genbi.golden_question;
GO

/* ---------- 3. Questions (real usage; evaluation runs are NOT in query_log) ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_questions
AS
SELECT  l.log_id, l.asked_at,
        CAST(l.asked_at AS DATE)                      AS log_date,
        DATEPART(HOUR, l.asked_at)                    AS hour_of_day,
        l.agent_name, l.question, l.behavior, l.outcome,
        l.validator_verdict, l.rule_codes,
        l.row_count, l.run_ms, l.total_ms, l.model, l.error_text,
        CAST(l.executed   AS INT)                     AS executed_n,
        CAST(l.from_cache AS INT)                     AS from_cache_n,
        CAST(l.retried    AS INT)                     AS retried_n,
        ISNULL(l.ai_calls, 0)                         AS ai_calls,
        ISNULL(l.in_tokens, 0)                        AS in_tokens,
        ISNULL(l.out_tokens, 0)                       AS out_tokens,
        CASE WHEN l.outcome = N'answered'     THEN 1 ELSE 0 END AS is_answered,
        CASE WHEN l.outcome IN (N'blocked', N'sql_error', N'guardrail', N'ai_error', N'unreadable')
                                              THEN 1 ELSE 0 END AS is_failure,
        CASE WHEN l.total_ms IS NULL  THEN N'n/a'
             WHEN l.total_ms <  2000  THEN N'1 Fast (< 2 s)'
             WHEN l.total_ms < 10000  THEN N'2 OK (2-10 s)'
             ELSE                          N'3 Slow (> 10 s)' END AS speed_band,
        f.rating, f.reason_code, f.review_status, f.fix_type
FROM    genbi.query_log l
LEFT JOIN genbi.feedback f ON f.log_id = l.log_id
WHERE   ISNULL(l.agent_name, N'') <> N'test_agent';
GO

/* ---------- 4. AI usage / cost ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_ai_usage
AS
SELECT  usage_id, called_at,
        CAST(called_at AS DATE) AS usage_date,
        agent_name, model, source, in_tokens, out_tokens, status, error_text
FROM    genbi.ai_usage
WHERE   ISNULL(agent_name, N'') <> N'test_agent';
GO

/* ---------- 5. Validator rule hits ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_rules
AS
SELECT  r.log_id,
        CAST(l.asked_at AS DATE) AS log_date,
        l.agent_name,
        r.rule_code, s.severity, s.description
FROM    genbi.query_log_rule r
JOIN    genbi.query_log l ON l.log_id = r.log_id
LEFT JOIN genbi.sql_rule s ON s.rule_code = r.rule_code
WHERE   ISNULL(l.agent_name, N'') <> N'test_agent';
GO

/* ---------- 6. Evaluation (fact table; runs that are still 'running' are kept but flagged by status) ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_eval
AS
SELECT  d.run_id, d.label, d.started_at,
        CAST(d.started_at AS DATE) AS run_date,
        r.status AS run_status,
        d.golden_id, d.agent_name, d.question, d.question_type, d.difficulty,
        d.expected_behavior, d.got_behavior, d.failure_type,
        d.expected_rows, d.got_rows, d.ai_calls, d.in_tokens, d.out_tokens, d.run_ms, d.total_ms, d.model,
        CAST(d.passed      AS INT) AS passed_n,
        CAST(d.behavior_ok AS INT) AS behavior_ok_n,
        CAST(d.result_ok   AS INT) AS result_ok_n,        -- NULL when no result was expected
        CAST(d.from_cache  AS INT) AS from_cache_n
FROM    genbi.vw_eval_detail d
JOIN    genbi.eval_run r ON r.run_id = d.run_id;
GO

/* ---------- 7. Golden question set health ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_golden
AS
SELECT  golden_id, agent_name, question, question_type, difficulty, expected_behavior,
        review_status, validation_status, expected_row_count, validation_ms,
        CAST(is_active AS INT)        AS is_active_n,
        CAST(use_as_example AS INT)   AS use_as_example_n
FROM    genbi.golden_question;
GO

/* ---------- 8. Scorecard: ONE row, the numbers for the top cards (last 7 days) ---------- */
CREATE OR ALTER VIEW genbi.vw_mon_scorecard
AS
WITH q AS (
    SELECT * FROM genbi.vw_mon_questions WHERE asked_at >= DATEADD(DAY, -7, SYSDATETIME())
),
p AS (
    SELECT DISTINCT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_ms) OVER () AS p95_ms
    FROM q WHERE total_ms IS NOT NULL AND from_cache_n = 0
)
SELECT
    (SELECT COUNT(*) FROM q)                                                                           AS questions_7d,
    (SELECT CAST(100.0 * SUM(is_answered) / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) FROM q)              AS answer_rate_7d,
    (SELECT CAST(100.0 * SUM(is_failure)  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) FROM q)              AS failure_rate_7d,
    (SELECT AVG(total_ms) FROM q WHERE from_cache_n = 0)                                               AS avg_ms_7d,
    (SELECT CAST(MAX(p95_ms) AS INT) FROM p)                                                           AS p95_ms_7d,
    (SELECT CAST(100.0 * SUM(CASE WHEN rating = N'up' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(rating), 0) AS DECIMAL(5,2)) FROM q)                                        AS satisfaction_pct_7d,
    (SELECT api_calls_today FROM genbi.vw_budget_today)                                                AS api_calls_today,
    (SELECT daily_limit     FROM genbi.vw_budget_today)                                                AS daily_limit,
    (SELECT TOP (1) run_id   FROM genbi.vw_eval_summary WHERE status = N'complete' ORDER BY run_id DESC) AS latest_eval_run,
    (SELECT TOP (1) pass_pct FROM genbi.vw_eval_summary WHERE status = N'complete' ORDER BY run_id DESC) AS latest_eval_pass_pct,
    (SELECT COUNT(*) FROM genbi.vw_improvement_backlog)                                                AS open_backlog,
    (SELECT COUNT(*) FROM genbi.vw_feedback_queue)                                                     AS feedback_waiting_review,
    SYSDATETIME()                                                                                      AS refreshed_at;
GO

/* ---------- 9. Read-only role for Power BI ---------- */
IF DATABASE_PRINCIPAL_ID('genbi_monitor') IS NULL
    CREATE ROLE genbi_monitor;
GO

GRANT SELECT ON genbi.vw_mon_date           TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_agent          TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_questions      TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_ai_usage       TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_rules          TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_eval           TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_golden         TO genbi_monitor;
GRANT SELECT ON genbi.vw_mon_scorecard      TO genbi_monitor;
-- review lists used by the improvement page (they come from Phases 10 and 11)
GRANT SELECT ON genbi.vw_eval_failures      TO genbi_monitor;
GRANT SELECT ON genbi.vw_improvement_backlog TO genbi_monitor;
GRANT SELECT ON genbi.vw_feedback_queue     TO genbi_monitor;
GO

/* ---------- Optional: let the genbi_reader login read the monitoring views ----------
   Only needed if Power BI connects as genbi_reader (see 09_reader_login_optional.sql). To use it, delete the comment line above and the closing mark below.
GRANT SELECT ON OBJECT::genbi.vw_mon_agent     TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_ai_usage  TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_date      TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_eval      TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_golden    TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_questions TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_rules     TO genbi_reader;
GRANT SELECT ON OBJECT::genbi.vw_mon_scorecard TO genbi_reader;
*/
GO
