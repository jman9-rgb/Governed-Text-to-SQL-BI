/* =============================================================================
   15 BUILD THE ANSWER KEY
   Runs every trusted SQL as its agent and stores the result snapshot used by the evaluation.
   The first run can take a few minutes. Later runs only rebuild questions whose SQL changed.
   ============================================================================= */
USE DataWarehouse;
GO

EXEC genbi.sp_validate_golden;                       -- expect: OK 38, No SQL 8
EXEC genbi.sp_validate_golden @create_snapshot = 1;  -- builds the snapshots
GO

/* ---------- Approve the validated questions ----------
   The evaluation (step 20 and genbi_eval.py) only runs questions with review_status = 'Approved'.
   A question is approved only when its trusted SQL ran (OK) or it needs no SQL (Clarify / Decline / Redirect).
   Questions whose SQL fails stay Draft, so a broken answer key can never be scored. */
UPDATE genbi.golden_question
SET    review_status = 'Approved'
WHERE  is_active = 1 AND review_status = 'Draft' AND validation_status IN ('OK', 'No SQL');
GO

SELECT review_status, validation_status, COUNT(*) AS questions
FROM   genbi.golden_question WHERE is_active = 1
GROUP BY review_status, validation_status ORDER BY review_status, validation_status;   -- expect: Approved OK 38, Approved No SQL 8
GO
