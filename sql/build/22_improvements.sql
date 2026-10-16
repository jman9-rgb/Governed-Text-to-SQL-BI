/* =============================================================================
   22 IMPROVEMENTS (CONTINUOUS IMPROVEMENT)
   Change log (genbi.change_log) and the three improvement cycles found by the evaluation.
   Each cycle: measure -> find the cause -> fix one thing in the data or the prompt -> log it -> measure again.
   On a fresh rebuild the run numbers stored in the change log (3, 4, 6) refer to the author's runs; they only
   match your own evaluation history if your run numbers are the same.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- Cycle 1: after baseline-v2 (40/46) ---------- */
/* =============================================================================
   GenBI - PHASE 13: CONTINUOUS IMPROVEMENT
   Run in SSMS, connected to the server that holds DataWarehouse. Run the whole file once.

   The loop:   measure (Phase 11)  ->  find the cause  ->  fix ONE thing in the DATA or the PROMPT
               ->  record it (genbi.change_log)  ->  measure again  ->  keep or undo the fix.

   Baseline = evaluation run "baseline-v2" (40 of 46 correct, 86.96 %). Failures to fix:
     #3, #19  timeouts (SQL Server database was shutting down between questions: AUTO_CLOSE)
     #11      January growth was NULL    (LAG was calculated AFTER the year filter)
     #12      38 rows instead of 37      (partial latest month was included)
     #41      130 rows instead of 3      (grouped by product instead of category; unweighted price)
     #42      answered instead of asking (glossary told the AI it may answer with a default)

   What this file creates / changes
     tables   genbi.change_log, genbi.change_log_golden
     view     genbi.vw_change_effect
     data     1 new trusted metric, 2 new glossary terms, 2 glossary updates, 1 metric update
     setting  AUTO_CLOSE OFF
   Nothing is deleted. Running the file twice is safe.
   ============================================================================= */

/* ---------- 1. Fix the timeouts: keep the database open ---------- */
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND is_auto_close_on = 1)
    ALTER DATABASE CURRENT SET AUTO_CLOSE OFF;
GO

/* ---------- 2. Change log: what we changed, why, and which golden questions it should affect ---------- */
IF OBJECT_ID('genbi.change_log') IS NULL
    CREATE TABLE genbi.change_log (
        change_id       INT IDENTITY(1,1) PRIMARY KEY,
        changed_at      DATETIME2(0)  NOT NULL CONSTRAINT DF_change_log_at DEFAULT SYSDATETIME(),
        change_area     NVARCHAR(20)  NOT NULL
                        CONSTRAINT CK_change_log_area CHECK (change_area IN
                            (N'Infrastructure', N'Metric', N'Glossary', N'Prompt rule', N'Golden set')),
        target          NVARCHAR(100) NOT NULL,         -- the object that changed
        what_changed    NVARCHAR(500) NOT NULL,
        why             NVARCHAR(500) NOT NULL,
        eval_run_before INT           NULL,             -- the run that showed the problem
        eval_run_after  INT           NULL,             -- the run that checks the fix (filled in after re-testing)
        CONSTRAINT UQ_change_log UNIQUE (change_area, target)
    );
GO

IF OBJECT_ID('genbi.change_log_golden') IS NULL
    CREATE TABLE genbi.change_log_golden (
        change_id INT NOT NULL REFERENCES genbi.change_log(change_id) ON DELETE CASCADE,
        golden_id INT NOT NULL REFERENCES genbi.golden_question(golden_id),
        CONSTRAINT PK_change_log_golden PRIMARY KEY (change_id, golden_id)
    );
GO

/* ---------- 3. The fixes (data first, prompt second) ---------- */

-- 3.1  #12 and #11: growth must skip the partial latest month, and LAG must see ALL months before any filter
UPDATE genbi.metric_definition
SET    time_rule  = N'Leave out the partial latest month: WHERE sales_month < (SELECT DATEFROMPARTS(YEAR(last_order_date),MONTH(last_order_date),1) FROM semantic.vw_data_range). Calculate LAG over ALL months in a CTE first, then filter the year or period in the outer query.',
       updated_at = SYSDATETIME()
WHERE  metric_code = N'mom_growth_pct';
GO

-- 3.2  #12: the glossary word "growth" must carry the same rule
UPDATE genbi.business_glossary
SET    default_assumption = N'State that growth means month over month. Year over year is not available. Leave out the latest month because it is partial (see semantic.vw_data_range).',
       updated_at         = SYSDATETIME()
WHERE  term = N'growth';
GO

-- 3.3  #41: the product agent has no trusted price metric (the existing one lives on vw_sales, which it cannot see)
INSERT INTO genbi.metric_definition
       (metric_code, metric_name, business_definition, preferred_view, sql_expression, time_rule, caveat, status, owner)
SELECT N'avg_selling_price_weighted',
       N'Average selling price (weighted)',
       N'Total sales divided by total quantity sold: the quantity-weighted average price per unit. Works for one product, a category or all products.',
       N'vw_product_metrics',
       N'CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(CAST(total_quantity AS DECIMAL(18,2))), 0) AS DECIMAL(18,2))',
       NULL,
       N'Never average the avg_selling_price column: it is not weighted by quantity. Group only by the dimension the user asked for (for example category), never by product unless asked.',
       N'Approved',
       owner
FROM   genbi.metric_definition
WHERE  metric_code = N'average_selling_price'
  AND  NOT EXISTS (SELECT 1 FROM genbi.metric_definition WHERE metric_code = N'avg_selling_price_weighted');
GO

MERGE genbi.business_glossary AS t
USING (SELECT N'average selling price' AS term, N'What is the average selling price per category?' AS example_question
       UNION ALL SELECT N'avg selling price', NULL) AS s
   ON t.term = s.term
WHEN MATCHED THEN
    UPDATE SET maps_to_type = N'Metric', maps_to_metric_code = N'avg_selling_price_weighted',
               maps_to_view = NULL, maps_to_column = NULL, filter_expression = NULL,
               meaning = N'Quantity-weighted average price per unit (total sales / total quantity).',
               default_assumption = NULL, needs_clarification = 0, is_active = 1, updated_at = SYSDATETIME()
WHEN NOT MATCHED THEN
    INSERT (term, maps_to_type, maps_to_metric_code, meaning, needs_clarification, example_question, owner)
    VALUES (s.term, N'Metric', N'avg_selling_price_weighted',
            N'Quantity-weighted average price per unit (total sales / total quantity).', 0, s.example_question,
            (SELECT owner FROM genbi.business_glossary WHERE term = N'average price'));
GO

-- 3.4  #42: "not sold recently" is vague on purpose. The glossary must say: ask, do not answer.
UPDATE genbi.business_glossary
SET    meaning             = N'Products with no sales for a period the user has not defined. "Recently" has no fixed length here.',
       default_assumption  = N'No default. Ask how many months without a sale counts as inactive. Do not use the "recent" default and do not write SQL until the user answers.',
       needs_clarification = 1,
       updated_at          = SYSDATETIME()
WHERE  term = N'inactive products';
GO

/* ---------- 4. Record every change (this is the audit trail) ---------- */
INSERT INTO genbi.change_log (change_area, target, what_changed, why, eval_run_before)
SELECT v.change_area, v.target, v.what_changed, v.why,
       COALESCE((SELECT MAX(run_id) FROM genbi.eval_run WHERE label = N'baseline-v2'), 3)
FROM (VALUES
 (N'Infrastructure', N'DataWarehouse AUTO_CLOSE',
  N'AUTO_CLOSE set to OFF.',
  N'Questions 3 and 19 timed out (HYT00): the database shut itself down when idle and had to restart. Not an AI error.'),
 (N'Metric', N'mom_growth_pct',
  N'time_rule now says: skip the partial latest month, and calculate LAG over all months before filtering.',
  N'Q12 returned 38 rows (partial month included). Q11 January growth was NULL because LAG ran after the year filter.'),
 (N'Glossary', N'growth',
  N'default_assumption now says to leave out the partial latest month.',
  N'The word "growth" is what the user types; the rule must be attached to the word as well as to the metric.'),
 (N'Metric', N'avg_selling_price_weighted',
  N'New trusted metric on vw_product_metrics (total_sales / total_quantity) plus glossary terms "average selling price" and "avg selling price".',
  N'Q41: product_agent could not see the vw_sales metric, grouped by product (130 rows, expected 3 categories) and used an unweighted price.'),
 (N'Glossary', N'inactive products',
  N'Made Clarify-only: no default answer, ask for the number of months.',
  N'Q42 expected a clarifying question but the AI answered, because the old text allowed a default. Q29 (inactive customers) already passes with Clarify.'),
 (N'Prompt rule', N'rules 6, 13, 14',
  N'Rule 6: add a tie-breaker only by ordering, never by adding columns to GROUP BY. Rule 13: "per X" means one row per X. Rule 14: window functions (LAG) in a CTE over all rows, filter outside.',
  N'Q41 over-applied the tie-breaker rule and changed the grain. Q11 applied LAG after the filter.')
) AS v(change_area, target, what_changed, why)
WHERE NOT EXISTS (SELECT 1 FROM genbi.change_log c WHERE c.change_area = v.change_area AND c.target = v.target);
GO

INSERT INTO genbi.change_log_golden (change_id, golden_id)
SELECT c.change_id, v.golden_id
FROM (VALUES
 (N'Infrastructure', N'DataWarehouse AUTO_CLOSE',  3),
 (N'Infrastructure', N'DataWarehouse AUTO_CLOSE', 19),
 (N'Metric',         N'mom_growth_pct',           11),
 (N'Metric',         N'mom_growth_pct',           12),
 (N'Glossary',       N'growth',                   12),
 (N'Metric',         N'avg_selling_price_weighted', 41),
 (N'Glossary',       N'inactive products',        42),
 (N'Prompt rule',    N'rules 6, 13, 14',          11),
 (N'Prompt rule',    N'rules 6, 13, 14',          41)
) AS v(change_area, target, golden_id)
JOIN genbi.change_log c ON c.change_area = v.change_area AND c.target = v.target
WHERE NOT EXISTS (SELECT 1 FROM genbi.change_log_golden g WHERE g.change_id = c.change_id AND g.golden_id = v.golden_id);
GO

/* ---------- 5. View: did each change help the questions it was meant for? ---------- */
CREATE OR ALTER VIEW genbi.vw_change_effect
AS
SELECT  c.change_id, c.change_area, c.target, g.golden_id, q.agent_name, q.question,
        b.passed AS passed_before, a.passed AS passed_after,
        CASE WHEN c.eval_run_after IS NULL                    THEN N'not measured yet'
             WHEN b.passed = 0 AND a.passed = 1               THEN N'fixed'
             WHEN b.passed = 1 AND a.passed = 0               THEN N'REGRESSION'
             WHEN a.passed = 1                                THEN N'still passing'
             ELSE N'still failing' END AS effect,
        a.failure_type AS failure_after, a.detail AS detail_after
FROM    genbi.change_log c
JOIN    genbi.change_log_golden g ON g.change_id = c.change_id
JOIN    genbi.golden_question q   ON q.golden_id = g.golden_id
LEFT JOIN genbi.eval_result b ON b.run_id = c.eval_run_before AND b.golden_id = g.golden_id
LEFT JOIN genbi.eval_result a ON a.run_id = c.eval_run_after  AND a.golden_id = g.golden_id;
GO

/* ---------- Cycle 2: after run 4 (43/46) ---------- */
/* =============================================================================
   GenBI - PHASE 13b: second improvement cycle (after run 4, "after-phase13-v2": 43 of 46)
   Run in SSMS. Safe to run twice.

   Problems found in run 4 that this file addresses
     #25  average order value of VIP customers: got 2554.00, expected 2554.11
          The AI divided without CAST, so the cents were cut off (integer division).
          customer_agent has no trusted metric for this (the existing one lives on vw_sales,
          which only sales_agent can see).
     #29  inactive customers: the AI answered with an assumption instead of asking.
          The glossary text still allowed a default answer (same cause as #42, fixed for products).

   #12 is NOT touched here: first run the diagnosis queries (Step 2 of my message).
   ============================================================================= */

/* ---------- 1. Trusted metric for the customer agent ---------- */
INSERT INTO genbi.metric_definition
       (metric_code, metric_name, business_definition, preferred_view, sql_expression, time_rule, caveat, status, owner)
SELECT N'avg_order_value_customers',
       N'Average order value (customer view)',
       N'Total sales divided by total orders: the average value of one order. Works for all customers, one segment, one country or any other customer group.',
       N'vw_customer_metrics',
       N'CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(CAST(total_orders AS DECIMAL(18,2))), 0) AS DECIMAL(18,2))',
       NULL,
       N'Always divide as decimals: dividing whole numbers cuts off the cents. Do not average a per-customer column.',
       N'Approved',
       owner
FROM   genbi.metric_definition
WHERE  metric_code = N'average_selling_price'
  AND  NOT EXISTS (SELECT 1 FROM genbi.metric_definition WHERE metric_code = N'avg_order_value_customers');
GO

/* ---------- 2. "inactive customers" must ask, not answer ---------- */
UPDATE genbi.business_glossary
SET    meaning             = N'Customers with no orders for a period the user has not defined. "Inactive" has no fixed length here.',
       default_assumption  = N'No default. Ask how many months without an order counts as inactive. Do not write SQL until the user answers.',
       needs_clarification = 1,
       updated_at          = SYSDATETIME()
WHERE  term = N'inactive customers';
GO

/* ---------- 3. Record the changes (problem seen in run 4) ---------- */
INSERT INTO genbi.change_log (change_area, target, what_changed, why, eval_run_before)
SELECT v.change_area, v.target, v.what_changed, v.why, 4
FROM (VALUES
 (N'Metric',   N'avg_order_value_customers',
  N'New trusted metric on vw_customer_metrics (total_sales / total_orders, decimal cast).',
  N'Q25 returned 2554.00 instead of 2554.11: the AI divided whole numbers. customer_agent could not see the vw_sales metric.'),
 (N'Glossary', N'inactive customers',
  N'Made Clarify-only: no default answer, ask for the number of months.',
  N'Q29 answered with an assumption in run 4 (it had passed in run 3): the old text allowed a default, so the result depended on chance.')
) AS v(change_area, target, what_changed, why)
WHERE NOT EXISTS (SELECT 1 FROM genbi.change_log c WHERE c.change_area = v.change_area AND c.target = v.target);
GO

INSERT INTO genbi.change_log_golden (change_id, golden_id)
SELECT c.change_id, v.golden_id
FROM (VALUES (N'Metric', N'avg_order_value_customers', 25),
             (N'Glossary', N'inactive customers',      29)) AS v(change_area, target, golden_id)
JOIN genbi.change_log c ON c.change_area = v.change_area AND c.target = v.target
WHERE NOT EXISTS (SELECT 1 FROM genbi.change_log_golden g WHERE g.change_id = c.change_id AND g.golden_id = v.golden_id);
GO

/* ---------- Cycle 3: after run 6 (44/46) ---------- */
/* =============================================================================
   GenBI - PHASE 13c: third improvement cycle (after run 6, "final": 44 of 46)
   Run in SSMS. Safe to run twice.

   Problem: #22 "Who are the top 10 customers by sales?"
     The AI grouped by customer_name. Two different customers are both called "Jordan Turner",
     so their sales were added together (15,998) and that person looked like the top customer.
     Cause: the metric catalog has no rule for customer_name (aggregation_rule was NULL),
     so nothing told the AI that names are not unique.

   Not changed: #12 (the AI left out total_sales). That is answer variation on a vague question.
   ============================================================================= */

UPDATE genbi.metric_catalog
SET    aggregation_rule = N'Not unique: two different customers can share a name. Never GROUP BY customer_name. To rank or list customers use one row per customer_key and show the name as a label.',
       updated_at       = SYSDATETIME()
WHERE  view_name = N'vw_customer_metrics' AND column_name = N'customer_name';

UPDATE genbi.metric_catalog
SET    aggregation_rule = N'Not unique: two different customers can share a name. To rank or list customers GROUP BY customer_key and show customer_name as a label.',
       updated_at       = SYSDATETIME()
WHERE  view_name = N'vw_sales' AND column_name = N'customer_name';
GO

INSERT INTO genbi.change_log (change_area, target, what_changed, why, eval_run_before)
SELECT N'Metric', N'customer_name column rule',
       N'Added an aggregation rule to customer_name in vw_customer_metrics and vw_sales: names are not unique, group by customer_key.',
       N'Q22 ranked a merged "Jordan Turner" (two customers, 15,998) as the top customer because the AI grouped by name.',
       6
WHERE NOT EXISTS (SELECT 1 FROM genbi.change_log WHERE change_area = N'Metric' AND target = N'customer_name column rule');
GO

INSERT INTO genbi.change_log_golden (change_id, golden_id)
SELECT c.change_id, 22
FROM   genbi.change_log c
WHERE  c.change_area = N'Metric' AND c.target = N'customer_name column rule'
  AND  NOT EXISTS (SELECT 1 FROM genbi.change_log_golden g WHERE g.change_id = c.change_id AND g.golden_id = 22);
GO