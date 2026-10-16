/* =============================================================================
   TESTS: STEP 19 FEEDBACK
   Thumbs up/down, input checks, the review workflow and cache eviction. Test rows are removed at the end.
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

DELETE FROM genbi.query_log    WHERE agent_name = N'test_agent';          -- leftovers (feedback goes with its log row)
DELETE FROM genbi.answer_cache WHERE cache_key = REPLICATE('1', 64);

INSERT genbi.query_log (agent_name, question, outcome, behavior)
VALUES (N'test_agent', N'TEST feedback question', N'answered', N'Answer');
DECLARE @id INT = SCOPE_IDENTITY();
DECLARE @fid_t TABLE (feedback_id INT);
DECLARE @e1 NVARCHAR(300) = N'', @e2 NVARCHAR(300) = N'', @e3 NVARCHAR(300) = N'';

INSERT @fid_t EXEC genbi.sp_submit_feedback @id, N'up',   NULL,            NULL;
INSERT @fid_t EXEC genbi.sp_submit_feedback @id, N'down', N'wrong_number', N'Total looks too high';
DECLARE @after_change NVARCHAR(100) =
    (SELECT CONCAT(COUNT(*), '/', MAX(rating), '/', MAX(reason_code)) FROM genbi.feedback WHERE log_id = @id);

BEGIN TRY EXEC genbi.sp_submit_feedback 0, N'up', NULL, NULL; END TRY
BEGIN CATCH SET @e1 = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC genbi.sp_submit_feedback @id, N'meh', NULL, NULL; END TRY
BEGIN CATCH SET @e2 = ERROR_MESSAGE(); END CATCH;

INSERT @fid_t EXEC genbi.sp_submit_feedback @id, N'down', N'not_a_real_reason', N'x';
DECLARE @unknown_reason NVARCHAR(30) = (SELECT reason_code FROM genbi.feedback WHERE log_id = @id);
INSERT @fid_t EXEC genbi.sp_submit_feedback @id, N'down', N'wrong_number', N'Total looks too high';   -- put it back

DECLARE @in_queue INT = (SELECT COUNT(*) FROM genbi.vw_feedback_queue WHERE agent_name = N'test_agent');
DECLARE @fid INT = (SELECT feedback_id FROM genbi.feedback WHERE log_id = @id);
BEGIN TRY EXEC genbi.sp_review_feedback @fid, N'confirmed_issue', NULL, NULL; END TRY
BEGIN CATCH SET @e3 = ERROR_MESSAGE(); END CATCH;
EXEC genbi.sp_review_feedback @fid, N'confirmed_issue', N'glossary', N'Define what counts as a sale in the glossary';

DECLARE @k CHAR(64) = REPLICATE('1', 64);
EXEC genbi.sp_cache_put @k, N'test_agent', N'test question', N'Answer', N'SELECT 1 AS x FROM semantic.vw_data_range', N'test';
DECLARE @before_evict INT = (SELECT COUNT(*) FROM genbi.answer_cache WHERE cache_key = @k);
EXEC genbi.sp_cache_evict @k;
DECLARE @after_evict INT = (SELECT COUNT(*) FROM genbi.answer_cache WHERE cache_key = @k);

INSERT #t (id, kind, test, expected, actual) VALUES ('F1', 'RULE', N'feedback objects exist (2 tables, 4 views, 3 procedures)', N'9', CAST((SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('genbi') AND name IN ('feedback','feedback_reason','vw_feedback_queue','vw_feedback_daily','vw_feedback_reasons','vw_improvement_backlog','sp_submit_feedback','sp_review_feedback','sp_cache_evict')) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F2', 'SEED', N'feedback reasons', N'7', CAST((SELECT COUNT(*) FROM genbi.feedback_reason) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F3', 'RULE', N'up then down keeps ONE row: rows / rating / reason', N'1/down/wrong_number', CAST((SELECT @after_change) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F4', 'RULE', N'unknown log_id is refused', N'That log_id does not exist.', CAST((SELECT @e1) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F5', 'RULE', N'rating other than up/down is refused', N'rating must be up or down.', CAST((SELECT @e2) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F6', 'RULE', N'unknown reason is stored as other', N'other', CAST((SELECT @unknown_reason) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F7', 'RULE', N'a thumbs-down waits in the review queue', N'1', CAST((SELECT @in_queue) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F8', 'RULE', N'confirming without fix_type is refused', N'Say what needs fixing: fix_type is required for confirmed_issue and fixed.', CAST((SELECT @e3) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F9', 'RULE', N'after review: still in queue', N'0', CAST((SELECT COUNT(*) FROM genbi.vw_feedback_queue WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F10', 'RULE', N'after review: backlog fix_type', N'glossary', CAST((SELECT fix_type FROM genbi.vw_improvement_backlog WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F11', 'RULE', N'daily view: questions / rated / up / down / satisfaction_pct', N'1/1/0/1/0.00', CAST((SELECT CONCAT(questions, '/', rated, '/', thumbs_up, '/', thumbs_down, '/', satisfaction_pct) FROM genbi.vw_feedback_daily WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F12', 'RULE', N'reasons view: reason / thumbs_down / confirmed', N'wrong_number/1/1', CAST((SELECT CONCAT(reason_code, '/', thumbs_down, '/', confirmed) FROM genbi.vw_feedback_reasons WHERE agent_name = N'test_agent') AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('F13', 'RULE', N'cache evict: rows before / after', N'1/0', CAST((SELECT CONCAT(@before_evict, '/', @after_evict)) AS NVARCHAR(200)));

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

DELETE FROM genbi.query_log WHERE agent_name = N'test_agent';         -- clean up (the feedback row goes with its log row)
GO
