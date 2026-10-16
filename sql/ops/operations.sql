/* =============================================================================
   OPERATIONS: commands you run by hand now and then (not part of the build)
   ============================================================================= */
USE DataWarehouse;
GO

-- ---- Daily AI call limit (the free Gemini tier is the real limit) ----
SELECT guardrail_name, limit_value FROM genbi.guardrail;
SELECT api_calls_today, daily_limit, remaining FROM genbi.vw_budget_today;

-- Normal day: 20 calls
UPDATE genbi.guardrail SET limit_value = 20 WHERE guardrail_name = N'daily_ai_calls';

-- Evaluation day: a full fresh run of 46 questions needs about 46 calls on top of what is already used today.
-- Raise it, run the evaluation, then set it back to 20 straight away.
-- UPDATE genbi.guardrail SET limit_value = 120 WHERE guardrail_name = N'daily_ai_calls';

-- ---- Keep the database open (timeouts after idle time) ----
SELECT name, is_auto_close_on FROM sys.databases WHERE name = DB_NAME();
-- ALTER DATABASE CURRENT SET AUTO_CLOSE OFF;

-- ---- Feedback review ----
SELECT feedback_id, question, sql_text, row_count, reason_code FROM genbi.vw_feedback_queue;
-- EXEC genbi.sp_review_feedback @feedback_id = 1, @review_status = N'not_an_issue', @reviewer_note = N'Checked: result is correct.';
-- review_status: new | confirmed_issue | not_an_issue | fixed   (confirmed_issue and fixed need @fix_type)

-- ---- Evaluation results ----
SELECT * FROM genbi.vw_eval_summary ORDER BY run_id;
SELECT golden_id, agent_name, question, failure_type, detail FROM genbi.vw_eval_failures
WHERE  run_id = (SELECT MAX(run_id) FROM genbi.eval_run WHERE status = N'complete');
SELECT * FROM genbi.vw_eval_changes;                       -- latest run vs the run before it
SELECT * FROM genbi.vw_change_effect ORDER BY change_id, golden_id;

-- ---- Link a change to the run that tested it ----
-- UPDATE genbi.change_log SET eval_run_after = <run_id> WHERE eval_run_after IS NULL;

-- ---- Rebuild the Gold tables after Silver changed ----
-- EXEC gold.sp_load_gold;
