/* =============================================================================
   14 GOLDEN QUESTIONS AND VALIDATOR
   46 golden questions (18 sales, 16 customer, 12 product), the validator procedure and review views.
   After running: EXEC genbi.sp_validate_golden @create_snapshot = 1;   (stores the answer key used by the evaluation)
   ============================================================================= */
USE DataWarehouse;
GO

/*
===============================================================================
PHASE 5 : GOLDEN QUESTIONS
46 real business questions, each with:
  - the agent that should answer it
  - the expected BEHAVIOR (Answer, Answer with stated assumption, Clarify, Decline, Redirect)
  - the trusted SQL (only for answerable questions)
  - a snapshot of the trusted result (filled by genbi.sp_validate_golden)
The trusted SQL is run AS the agent's own database user, so it also proves that
the agent's scope is big enough to answer its own questions.
Re-runnable: questions are only inserted when missing.
===============================================================================
*/
USE DataWarehouse;
GO

-- ---------------------------------------------------------------------------
-- 5.1  Table
-- ---------------------------------------------------------------------------
IF OBJECT_ID('genbi.golden_question', 'U') IS NULL
CREATE TABLE genbi.golden_question (
    golden_id            INT IDENTITY(1,1) PRIMARY KEY,
    agent_name           SYSNAME        NOT NULL REFERENCES genbi.agent (agent_name),
    question             NVARCHAR(500)  NOT NULL,
    question_type        NVARCHAR(15)   NOT NULL
        CONSTRAINT ck_golden_type CHECK (question_type IN
            ('KPI','Trend','Breakdown','Ranking','Segment','Time-relative','Ambiguous','Unsupported','Out-of-scope')),
    difficulty           NVARCHAR(6)    NOT NULL
        CONSTRAINT ck_golden_difficulty CHECK (difficulty IN ('Easy','Medium','Hard')),
    expected_behavior    NVARCHAR(30)   NOT NULL
        CONSTRAINT ck_golden_behavior CHECK (expected_behavior IN
            ('Answer','Answer with stated assumption','Clarify','Decline','Redirect')),
    glossary_term        NVARCHAR(100)  NULL REFERENCES genbi.business_glossary (term),
    expected_sql         NVARCHAR(MAX)  NULL,
    expected_note        NVARCHAR(500)  NULL,              -- what the reply must state or do
    review_status        NVARCHAR(10)   NOT NULL DEFAULT 'Draft'
        CONSTRAINT ck_golden_review CHECK (review_status IN ('Draft','Approved')),
    reviewed_by          NVARCHAR(100)  NULL,
    reviewed_at          DATETIME2      NULL,
    validation_status    NVARCHAR(10)   NOT NULL DEFAULT 'Not run'
        CONSTRAINT ck_golden_validation CHECK (validation_status IN ('Not run','OK','Error','No SQL')),
    validation_error     NVARCHAR(400)  NULL,
    expected_row_count   INT            NULL,
    expected_result_json NVARCHAR(MAX)  NULL,
    validated_at         DATETIME2      NULL,
    use_as_example       BIT            NOT NULL DEFAULT 0,   -- used as a worked example in the prompt later
    is_active            BIT            NOT NULL DEFAULT 1,
    created_at           DATETIME2      NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT uq_golden_question UNIQUE (agent_name, question),
    -- answerable questions MUST have SQL; Clarify / Decline / Redirect must NOT
    CONSTRAINT ck_golden_sql_rule CHECK (
        (expected_behavior IN ('Answer','Answer with stated assumption') AND expected_sql IS NOT NULL)
     OR (expected_behavior IN ('Clarify','Decline','Redirect')           AND expected_sql IS NULL)),
    -- the validator appends FOR JSON PATH, so no trailing semicolon
    CONSTRAINT ck_golden_no_semicolon CHECK (expected_sql IS NULL OR RIGHT(RTRIM(expected_sql), 1) <> ';')
);
GO

-- ---------------------------------------------------------------------------
-- 5.2  Seed: 18 sales_agent, 16 customer_agent, 12 product_agent
--      (agent, question, type, difficulty, behavior, glossary term, expected SQL, expected note)
--      Every output column has an alias (required by FOR JSON).
--      Every TOP N query has a tie-breaker so the expected answer is deterministic.
-- ---------------------------------------------------------------------------
MERGE genbi.golden_question AS t
USING (VALUES
-- ===================== sales_agent =====================
('sales_agent','What are the total sales?','KPI','Easy','Answer',NULL,
 'SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM semantic.vw_sales',
 NULL),
('sales_agent','How many orders were placed in total?','KPI','Easy','Answer',NULL,
 'SELECT COUNT(DISTINCT order_number) AS total_orders FROM semantic.vw_sales',
 'Must count distinct orders, not order lines.'),
('sales_agent','What is the average order value?','KPI','Medium','Answer',NULL,
 'SELECT CAST(SUM(CAST(sales_amount AS DECIMAL(18,2))) / NULLIF(COUNT(DISTINCT order_number), 0) AS DECIMAL(18,2)) AS average_order_value FROM semantic.vw_sales',
 NULL),
('sales_agent','How many customers have placed an order?','KPI','Medium','Answer',NULL,
 'SELECT COUNT(DISTINCT customer_key) AS customers FROM semantic.vw_sales',
 'Must count distinct customers.'),
('sales_agent','What were total sales by year?','Trend','Medium','Answer',NULL,
 'SELECT YEAR(sales_month) AS sales_year, SUM(total_sales) AS total_sales FROM semantic.vw_monthly_sales GROUP BY YEAR(sales_month) ORDER BY sales_year',
 'Should say that the latest year is incomplete.'),
('sales_agent','Which country has the highest sales?','Breakdown','Medium','Answer',NULL,
 'SELECT TOP 1 country, SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM semantic.vw_sales GROUP BY country ORDER BY total_sales DESC',
 NULL),
('sales_agent','What are the sales by product category?','Breakdown','Medium','Answer',NULL,
 'SELECT category, SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM semantic.vw_sales GROUP BY category ORDER BY total_sales DESC',
 NULL),
('sales_agent','What were total sales last month?','Time-relative','Medium','Answer with stated assumption','last month',
 'SELECT m.sales_month, m.total_sales FROM semantic.vw_monthly_sales m WHERE m.sales_month = DATEADD(MONTH, -1, (SELECT latest_month FROM semantic.vw_data_range))',
 'Must name the month used. Last month is the month before the latest (partial) month.'),
('sales_agent','What were total sales in the last 12 months?','Time-relative','Medium','Answer with stated assumption','last 12 months',
 'SELECT SUM(total_sales) AS total_sales FROM semantic.vw_monthly_sales WHERE sales_month >= DATEADD(MONTH, -12, (SELECT latest_month FROM semantic.vw_data_range)) AND sales_month < (SELECT latest_month FROM semantic.vw_data_range)',
 'Must state the exact period used.'),
('sales_agent','What are the sales this year?','Time-relative','Medium','Answer with stated assumption','this year',
 'SELECT SUM(total_sales) AS total_sales FROM semantic.vw_monthly_sales WHERE sales_month >= DATEFROMPARTS(YEAR((SELECT last_order_date FROM semantic.vw_data_range)), 1, 1)',
 'Must say that the year is incomplete.'),
('sales_agent','What was the month-over-month growth in 2013?','Trend','Hard','Answer',NULL,
 'SELECT sales_month, total_sales, CAST(100.0 * (total_sales - prev_sales) / NULLIF(prev_sales, 0) AS DECIMAL(18,2)) AS mom_growth_pct FROM (SELECT sales_month, total_sales, LAG(total_sales) OVER (ORDER BY sales_month) AS prev_sales FROM semantic.vw_monthly_sales) x WHERE YEAR(sales_month) = 2013 ORDER BY sales_month',
 'The previous month must be taken from all months before filtering the year, so January uses the previous December.'),
('sales_agent','What is the sales growth?','Ambiguous','Hard','Answer with stated assumption','growth',
 'SELECT sales_month, total_sales, CAST(100.0 * (total_sales - prev_sales) / NULLIF(prev_sales, 0) AS DECIMAL(18,2)) AS mom_growth_pct FROM (SELECT sales_month, total_sales, LAG(total_sales) OVER (ORDER BY sales_month) AS prev_sales FROM semantic.vw_monthly_sales) x WHERE sales_month < (SELECT latest_month FROM semantic.vw_data_range) ORDER BY sales_month',
 'Must state that growth means month over month and that the partial latest month is excluded.'),
('sales_agent','What was the sales volume by category?','Ambiguous','Medium','Answer with stated assumption','volume',
 'SELECT category, SUM(CAST(quantity AS BIGINT)) AS total_units FROM semantic.vw_sales GROUP BY category ORDER BY total_units DESC',
 'Must state that volume is read as units sold.'),
('sales_agent','What was the profit last year?','Unsupported','Easy','Decline','profit',
 NULL,
 'Must say profit cannot be answered and offer sales analysis instead.'),
('sales_agent','Which age group spends the most?','Out-of-scope','Medium','Redirect',NULL,
 NULL,
 'Age group exists only in the customer data. Must say this needs the customer agent.'),
('sales_agent','What are the sales by region?','Breakdown','Easy','Answer with stated assumption','region',
 'SELECT country, SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM semantic.vw_sales GROUP BY country ORDER BY total_sales DESC',
 'Must state that region means country.'),
('sales_agent','What are the sales this month?','Time-relative','Easy','Answer with stated assumption','this month',
 'SELECT m.sales_month, m.total_sales FROM semantic.vw_monthly_sales m WHERE m.sales_month = (SELECT latest_month FROM semantic.vw_data_range)',
 'Must say that the month is partial.'),
('sales_agent','What were the recent sales?','Ambiguous','Medium','Answer with stated assumption','recent',
 'SELECT sales_month, total_sales FROM semantic.vw_monthly_sales WHERE sales_month >= DATEADD(MONTH, -3, (SELECT latest_month FROM semantic.vw_data_range)) AND sales_month < (SELECT latest_month FROM semantic.vw_data_range) ORDER BY sales_month',
 'Must state the 3 months used.'),

-- ===================== customer_agent =====================
('customer_agent','How many customers are in each segment?','Segment','Easy','Answer',NULL,
 'SELECT customer_segment, COUNT(*) AS customers FROM semantic.vw_customer_metrics GROUP BY customer_segment ORDER BY customers DESC',
 NULL),
('customer_agent','How many VIP customers do we have?','KPI','Easy','Answer','vip',
 'SELECT COUNT(*) AS vip_customers FROM semantic.vw_customer_metrics WHERE customer_segment = ''VIP''',
 NULL),
('customer_agent','Which age group spends the most in total?','Segment','Medium','Answer',NULL,
 'SELECT TOP 1 age_group, SUM(total_sales) AS total_sales FROM semantic.vw_customer_metrics GROUP BY age_group ORDER BY total_sales DESC',
 NULL),
('customer_agent','Who are the top 10 customers by sales?','Ranking','Medium','Answer with stated assumption','top customers',
 'SELECT TOP 10 customer_name, total_sales FROM semantic.vw_customer_metrics ORDER BY total_sales DESC, customer_key',
 'Must say customers are ranked by total sales.'),
('customer_agent','How many repeat customers do we have?','Segment','Medium','Answer with stated assumption','repeat customers',
 'SELECT COUNT(*) AS repeat_customers FROM semantic.vw_customer_metrics WHERE total_orders >= 2',
 'Must state that repeat means two or more orders.'),
('customer_agent','How many one-time customers are there?','Segment','Easy','Answer','one-time customers',
 'SELECT COUNT(*) AS one_time_customers FROM semantic.vw_customer_metrics WHERE total_orders = 1',
 NULL),
('customer_agent','What is the average order value of VIP customers?','KPI','Hard','Answer',NULL,
 'SELECT CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(total_orders), 0) AS DECIMAL(18,2)) AS average_order_value FROM semantic.vw_customer_metrics WHERE customer_segment = ''VIP''',
 'Must divide total sales by total orders, not average the avg_order_value column.'),
('customer_agent','How many customers have an unknown age?','Segment','Easy','Answer','unknown age',
 'SELECT COUNT(*) AS unknown_age_customers FROM semantic.vw_customer_metrics WHERE age_group = ''Unknown''',
 NULL),
('customer_agent','What is the average age of our customers?','KPI','Easy','Answer',NULL,
 'SELECT CAST(AVG(CAST(age AS DECIMAL(10,2))) AS DECIMAL(10,1)) AS average_age FROM semantic.vw_customer_metrics',
 'Customers with unknown age must be ignored.'),
('customer_agent','How many loyal customers do we have?','Ambiguous','Medium','Answer with stated assumption','loyal customers',
 'SELECT COUNT(*) AS loyal_customers FROM semantic.vw_customer_metrics WHERE customer_segment IN (''VIP'', ''Regular'')',
 'Must state that loyal means VIP and Regular customers (lifespan of 12 months or more).'),
('customer_agent','Which customers are inactive?','Ambiguous','Medium','Clarify','inactive customers',
 NULL,
 'Must ask for the number of months, or say that no limit was applied.'),
('customer_agent','Which country has the most customers?','Out-of-scope','Medium','Redirect',NULL,
 NULL,
 'Country is not in the customer metrics. Must say this needs the sales agent.'),
('customer_agent','What is our customer churn rate?','Unsupported','Easy','Decline','churn rate',
 NULL,
 'Must say churn is not defined and offer recency analysis instead.'),
('customer_agent','How many customers are in each tier?','Segment','Easy','Answer with stated assumption','customer tier',
 'SELECT customer_segment, COUNT(*) AS customers FROM semantic.vw_customer_metrics GROUP BY customer_segment ORDER BY customers DESC',
 'Must state that tier means customer segment.'),
('customer_agent','What is the average customer tenure?','KPI','Medium','Answer with stated assumption','tenure',
 'SELECT CAST(AVG(CAST(lifespan AS DECIMAL(10,2))) AS DECIMAL(10,1)) AS average_lifespan_months FROM semantic.vw_customer_metrics',
 'Must state that tenure means lifespan in months.'),
('customer_agent','Who are our 5 best customers?','Ranking','Medium','Answer with stated assumption','best customers',
 'SELECT TOP 5 customer_name, total_sales FROM semantic.vw_customer_metrics ORDER BY total_sales DESC, customer_key',
 'Must state that best means highest total sales.'),

-- ===================== product_agent =====================
('product_agent','What are the top 5 products by sales?','Ranking','Easy','Answer with stated assumption','top products',
 'SELECT TOP 5 product_name, total_sales FROM semantic.vw_product_metrics ORDER BY total_sales DESC, product_key',
 'Must state that products are ranked by sales.'),
('product_agent','Which category has the most sales?','Breakdown','Easy','Answer',NULL,
 'SELECT TOP 1 category, SUM(total_sales) AS total_sales FROM semantic.vw_product_metrics GROUP BY category ORDER BY total_sales DESC',
 NULL),
('product_agent','How many products are low performers?','Segment','Easy','Answer','low performers',
 'SELECT COUNT(*) AS low_performers FROM semantic.vw_product_metrics WHERE product_segment = ''Low-Performer''',
 NULL),
('product_agent','How many products are best sellers?','Segment','Easy','Answer with stated assumption','best sellers',
 'SELECT COUNT(*) AS best_sellers FROM semantic.vw_product_metrics WHERE product_segment = ''High-Performer''',
 'Must state that best seller means the High-Performer segment (by sales).'),
('product_agent','What are the 5 most popular products?','Ranking','Medium','Answer with stated assumption','popular products',
 'SELECT TOP 5 product_name, total_quantity FROM semantic.vw_product_metrics ORDER BY total_quantity DESC, product_key',
 'Must state that popular means units sold.'),
('product_agent','How many units were sold by subcategory?','Breakdown','Medium','Answer',NULL,
 'SELECT subcategory, SUM(CAST(total_quantity AS BIGINT)) AS total_units FROM semantic.vw_product_metrics GROUP BY subcategory ORDER BY total_units DESC',
 NULL),
('product_agent','What is the average selling price per category?','KPI','Hard','Answer',NULL,
 'SELECT category, CAST(SUM(CAST(total_sales AS DECIMAL(18,2))) / NULLIF(SUM(CAST(total_quantity AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS average_selling_price FROM semantic.vw_product_metrics GROUP BY category ORDER BY category',
 'Must weight by quantity (total sales divided by total quantity), not average the avg_selling_price column.'),
('product_agent','Which products have not sold recently?','Ambiguous','Medium','Clarify','inactive products',
 NULL,
 'Must ask for the number of months, or say that no limit was applied.'),
('product_agent','What were product sales by month?','Out-of-scope','Medium','Redirect',NULL,
 NULL,
 'The product metrics have no month. Must say this needs the sales agent.'),
('product_agent','Which product has the highest profit margin?','Unsupported','Easy','Decline','margin',
 NULL,
 'Must say margin cannot be answered.'),
('product_agent','How many products are in each segment?','Segment','Easy','Answer',NULL,
 'SELECT product_segment, COUNT(*) AS products FROM semantic.vw_product_metrics GROUP BY product_segment ORDER BY products DESC',
 NULL),
('product_agent','What are the 5 best products?','Ranking','Easy','Answer with stated assumption','best products',
 'SELECT TOP 5 product_name, total_sales FROM semantic.vw_product_metrics ORDER BY total_sales DESC, product_key',
 'Must state that best means highest sales.')
) AS s(agent_name, question, question_type, difficulty, expected_behavior, glossary_term, expected_sql, expected_note)
ON t.agent_name = s.agent_name AND t.question = s.question
WHEN NOT MATCHED THEN
    INSERT (agent_name, question, question_type, difficulty, expected_behavior, glossary_term, expected_sql, expected_note)
    VALUES (s.agent_name, s.question, s.question_type, s.difficulty, s.expected_behavior, s.glossary_term, s.expected_sql, s.expected_note);
GO

/* ---------- 5.3 Validator (v2): runs every trusted SQL as the agent's own user and stores a result snapshot ---------- */
IF COL_LENGTH('genbi.golden_question', 'snapshot_sql_hash') IS NULL
    ALTER TABLE genbi.golden_question ADD snapshot_sql_hash VARBINARY(32) NULL;
IF COL_LENGTH('genbi.golden_question', 'validation_ms') IS NULL
    ALTER TABLE genbi.golden_question ADD validation_ms INT NULL;
GO

-- your existing snapshots were built from the current SQL
UPDATE genbi.golden_question
SET snapshot_sql_hash = HASHBYTES('SHA2_256', expected_sql)
WHERE expected_result_json IS NOT NULL AND snapshot_sql_hash IS NULL;
GO

CREATE OR ALTER PROCEDURE genbi.sp_validate_golden
    @golden_id       INT = NULL,
    @create_snapshot BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @id         INT,
        @user       SYSNAME,
        @question   NVARCHAR(500),
        @sql        NVARCHAR(MAX),
        @cmd        NVARCHAR(MAX),
        @json       NVARCHAR(MAX),
        @err        NVARCHAR(400),
        @rowcount   INT,
        @start_time DATETIME2(7),
        @elapsed_ms INT;            -- INT on purpose: RAISERROR cannot print BIGINT

    /* 1. Questions with no SQL (Clarify / Decline / Redirect) */
    UPDATE genbi.golden_question
    SET validation_status = 'No SQL', validation_error = NULL, validation_ms = NULL,
        expected_row_count = NULL, expected_result_json = NULL, snapshot_sql_hash = NULL,
        validated_at = SYSDATETIME()
    WHERE is_active = 1 AND expected_sql IS NULL
      AND (@golden_id IS NULL OR golden_id = @golden_id);

    /* ===================================================================
       2. FAST MODE (default): run the SQL as the agent's user, store row count and time.
          No JSON is built.
       =================================================================== */
    IF @create_snapshot = 0
    BEGIN
        DECLARE fast_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT g.golden_id, a.db_user, g.question, g.expected_sql
            FROM genbi.golden_question g
            JOIN genbi.agent a ON a.agent_name = g.agent_name
            WHERE g.is_active = 1 AND g.expected_sql IS NOT NULL
              AND (@golden_id IS NULL OR g.golden_id = @golden_id)
            ORDER BY g.golden_id;

        OPEN fast_cur;
        FETCH NEXT FROM fast_cur INTO @id, @user, @question, @sql;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @cmd = NULL; SET @err = NULL; SET @rowcount = NULL;
            RAISERROR(N'Starting Golden ID %d: %s', 10, 1, @id, @question) WITH NOWAIT;

            BEGIN TRY
                SET @start_time = SYSDATETIME();
                EXECUTE AS USER = @user;
                SET @cmd = @sql + N'; SET @rowcount_out = @@ROWCOUNT;';
                EXEC sys.sp_executesql @cmd, N'@rowcount_out INT OUTPUT', @rowcount_out = @rowcount OUTPUT;
                REVERT;
                SET @elapsed_ms = DATEDIFF(MILLISECOND, @start_time, SYSDATETIME());

                UPDATE genbi.golden_question
                SET validation_status = 'OK', validation_error = NULL,
                    expected_row_count = @rowcount, validation_ms = @elapsed_ms,
                    validated_at = SYSDATETIME()
                WHERE golden_id = @id;

                RAISERROR(N'Golden ID %d: OK | Rows = %d | Time = %d ms', 10, 1, @id, @rowcount, @elapsed_ms) WITH NOWAIT;
            END TRY
            BEGIN CATCH
                SET @err = LEFT(ERROR_MESSAGE(), 400);
                BEGIN TRY REVERT; END TRY BEGIN CATCH END CATCH;

                UPDATE genbi.golden_question
                SET validation_status = 'Error', validation_error = @err, validation_ms = NULL,
                    expected_result_json = NULL, snapshot_sql_hash = NULL,
                    expected_row_count = NULL, validated_at = SYSDATETIME()
                WHERE golden_id = @id;

                RAISERROR(N'Golden ID %d: ERROR - %s', 10, 1, @id, @err) WITH NOWAIT;
            END CATCH;

            FETCH NEXT FROM fast_cur INTO @id, @user, @question, @sql;
        END;
        CLOSE fast_cur; DEALLOCATE fast_cur;

        SELECT validation_status, COUNT(*) AS questions,
               SUM(CASE WHEN expected_result_json IS NOT NULL THEN 1 ELSE 0 END) AS with_snapshot
        FROM genbi.golden_question
        WHERE is_active = 1 AND (@golden_id IS NULL OR golden_id = @golden_id)
        GROUP BY validation_status ORDER BY validation_status;
        RETURN;
    END;

    /* ===================================================================
       3. SNAPSHOT MODE: only questions that are validated OK and either have no snapshot
          or whose SQL has changed since the snapshot was taken.
       =================================================================== */
    DECLARE snapshot_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT g.golden_id, a.db_user, g.question, g.expected_sql
        FROM genbi.golden_question g
        JOIN genbi.agent a ON a.agent_name = g.agent_name
        WHERE g.is_active = 1 AND g.expected_sql IS NOT NULL
          AND g.validation_status = 'OK'
          AND (g.expected_result_json IS NULL
               OR g.snapshot_sql_hash IS NULL
               OR g.snapshot_sql_hash <> HASHBYTES('SHA2_256', g.expected_sql))
          AND (@golden_id IS NULL OR g.golden_id = @golden_id)
        ORDER BY g.golden_id;

    OPEN snapshot_cur;
    FETCH NEXT FROM snapshot_cur INTO @id, @user, @question, @sql;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @json = NULL; SET @cmd = NULL; SET @err = NULL; SET @rowcount = NULL;
        RAISERROR(N'Snapshot starting Golden ID %d: %s', 10, 1, @id, @question) WITH NOWAIT;

        BEGIN TRY
            SET @start_time = SYSDATETIME();
            EXECUTE AS USER = @user;
            SET @cmd = N'SET @json_out = (' + @sql + N' FOR JSON PATH);';
            EXEC sys.sp_executesql @cmd, N'@json_out NVARCHAR(MAX) OUTPUT', @json_out = @json OUTPUT;
            REVERT;

            SET @rowcount = (SELECT COUNT(*) FROM OPENJSON(@json));
            SET @elapsed_ms = DATEDIFF(MILLISECOND, @start_time, SYSDATETIME());

            UPDATE genbi.golden_question
            SET expected_result_json = @json,
                snapshot_sql_hash    = HASHBYTES('SHA2_256', @sql),
                expected_row_count   = @rowcount,
                validated_at         = SYSDATETIME()
            WHERE golden_id = @id;

            RAISERROR(N'Golden ID %d: SNAPSHOT OK | Rows = %d | Time = %d ms', 10, 1, @id, @rowcount, @elapsed_ms) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @err = LEFT(ERROR_MESSAGE(), 400);
            BEGIN TRY REVERT; END TRY BEGIN CATCH END CATCH;

            UPDATE genbi.golden_question
            SET validation_status = 'Error', validation_error = @err, validation_ms = NULL,
                expected_result_json = NULL, snapshot_sql_hash = NULL,
                expected_row_count = NULL, validated_at = SYSDATETIME()
            WHERE golden_id = @id;

            RAISERROR(N'Golden ID %d: SNAPSHOT ERROR - %s', 10, 1, @id, @err) WITH NOWAIT;
        END CATCH;

        FETCH NEXT FROM snapshot_cur INTO @id, @user, @question, @sql;
    END;
    CLOSE snapshot_cur; DEALLOCATE snapshot_cur;

    SELECT validation_status, COUNT(*) AS questions,
           SUM(CASE WHEN expected_result_json IS NOT NULL THEN 1 ELSE 0 END) AS with_snapshot
    FROM genbi.golden_question
    WHERE is_active = 1 AND (@golden_id IS NULL OR golden_id = @golden_id)
    GROUP BY validation_status ORDER BY validation_status;
END;
GO

-- ---------------------------------------------------------------------------
-- 5.4  Review and coverage views
-- ---------------------------------------------------------------------------
-- Your review screen: question, expected behavior, and a preview of the trusted answer
CREATE OR ALTER VIEW genbi.vw_golden_review
AS
SELECT golden_id, agent_name, question_type, difficulty, expected_behavior, question,
       review_status, validation_status, expected_row_count,
       LEFT(expected_result_json, 200) AS result_preview, expected_note, validation_error
FROM genbi.golden_question
WHERE is_active = 1;
GO

-- Glossary terms that need an assumption but have no golden question yet (target: 0 rows)
CREATE OR ALTER VIEW genbi.vw_golden_coverage
AS
SELECT gl.term, gl.maps_to_type, gl.default_assumption
FROM genbi.business_glossary gl
WHERE gl.is_active = 1 AND gl.needs_clarification = 1
  AND NOT EXISTS (SELECT 1 FROM genbi.golden_question q WHERE q.glossary_term = gl.term AND q.is_active = 1);
GO

/* ---------- 5.5 Corrections to four trusted answers (found during the first evaluation) ---------- */
UPDATE genbi.golden_question SET reviewed_at = SYSDATETIME(), expected_sql =
  N'SELECT m.total_sales FROM semantic.vw_monthly_sales m WHERE m.sales_month = DATEADD(MONTH, -1, (SELECT latest_month FROM semantic.vw_data_range))'
WHERE golden_id = 8;

UPDATE genbi.golden_question SET reviewed_at = SYSDATETIME(), expected_sql =
  N'SELECT m.total_sales FROM semantic.vw_monthly_sales m WHERE m.sales_month = (SELECT latest_month FROM semantic.vw_data_range)'
WHERE golden_id = 17;

UPDATE genbi.golden_question SET reviewed_at = SYSDATETIME(), expected_sql =
  N'SELECT AVG(CAST(age AS DECIMAL(10,2))) AS average_age FROM semantic.vw_customer_metrics'
WHERE golden_id = 27;

UPDATE genbi.golden_question SET reviewed_at = SYSDATETIME(), expected_sql =
  N'SELECT AVG(CAST(lifespan AS DECIMAL(10,2))) AS average_lifespan_months FROM semantic.vw_customer_metrics'
WHERE golden_id = 33;
GO