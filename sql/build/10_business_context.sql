/* =============================================================================
   10 BUSINESS CONTEXT
   Company, time, source and limitation facts the AI is told, plus the views' purpose.
   ============================================================================= */
USE DataWarehouse;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'genbi')
    EXEC('CREATE SCHEMA genbi');
GO

-- 1) General business context (company, time rules, sources, limits, scope, answer style)
IF OBJECT_ID('genbi.business_context', 'U') IS NULL
CREATE TABLE genbi.business_context (
    context_id     INT IDENTITY(1,1) PRIMARY KEY,
    context_area   NVARCHAR(30)   NOT NULL
        CONSTRAINT ck_context_area CHECK (context_area IN
            ('Company','Time','Data Source','Data Limitation','Scope','Answer Style')),
    context_key    NVARCHAR(60)   NOT NULL,
    context_value  NVARCHAR(1000) NOT NULL,
    priority       TINYINT        NOT NULL DEFAULT 2,      -- 1 = always include, 2 = normal
    is_active      BIT            NOT NULL DEFAULT 1,
    owner          NVARCHAR(100)  NULL,
    updated_at     DATETIME2      NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT uq_business_context UNIQUE (context_area, context_key)
);
GO

-- 2) What each approved semantic view is for
IF OBJECT_ID('genbi.view_context', 'U') IS NULL
CREATE TABLE genbi.view_context (
    view_name         SYSNAME        NOT NULL PRIMARY KEY,   -- name only, no schema
    business_purpose  NVARCHAR(500)  NOT NULL,
    grain             NVARCHAR(200)  NOT NULL,
    use_when          NVARCHAR(500)  NOT NULL,
    not_for           NVARCHAR(500)  NOT NULL,
    owner             NVARCHAR(100)  NULL,
    updated_at        DATETIME2      NOT NULL DEFAULT SYSDATETIME()
);
GO

-- Seed: only inserts rows that do not exist yet, so re-running never overwrites your edits.
-- Text marked <<CONFIRM>> is something only YOU can answer. Resolve it in Step 1.3.
MERGE genbi.business_context AS t
USING (VALUES
 ('Company','business_summary', N'Sales analytics data warehouse of a bicycle business: customers, products and sales order lines, built from CRM and ERP extracts.', 1),
 ('Company','currency',         N'Currency of all sales amounts: <<CONFIRM: e.g. USD>>. Amounts are whole numbers.', 1),
 ('Company','audience',         N'Users are business managers and analysts who ask questions in plain English.', 2),

 ('Time','data_period',         N'The data is historical. "Today", "this year", "last month" and "recent" mean relative to the latest order date in the data, never the system date.', 1),
 ('Time','latest_date_rule',    N'Latest date = MAX(order_date) in semantic.vw_sales. Latest month = the first day of that month.', 1),
 ('Time','calendar',            N'Calendar year (January to December) is used. <<CONFIRM: no fiscal year?>>', 2),
 ('Time','month_format',        N'In semantic.vw_monthly_sales, sales_month is the first day of the month.', 2),

 ('Data Source','sources',      N'CRM supplies customers, products and sales. ERP supplies birthdate, country and product categories. Layers: Bronze, Silver, Gold, Semantic.', 2),
 ('Data Source','refresh',      N'Data is loaded manually from CSV files. It is not real time.', 2),

 ('Data Limitation','unmatched_customers', N'Sales lines whose customer is not in the customer data have no customer. They count in sales totals but are missing from semantic.vw_customer_metrics.', 2),
 ('Data Limitation','unmatched_products',  N'Sales lines whose product is not in the product data have no product. They count in sales totals but are missing from semantic.vw_product_metrics.', 2),
 ('Data Limitation','null_order_dates',    N'Sales lines with no valid order date are excluded from monthly and time-based views.', 2),
 ('Data Limitation','product_history',     N'Only the current version of each product is kept. Past product versions are not available.', 2),
 ('Data Limitation','unknown_age',         N'Customers without a birthdate have age group Unknown. Age is measured at the latest order date, not today.', 2),
 ('Data Limitation','surrogate_keys',      N'customer_key and product_key can change when the data is reloaded. Never use them as permanent IDs.', 2),
 ('Data Limitation','personal_data',       N'Customer names exist in the semantic views. <<CONFIRM: may users see individual customer names?>>', 1),

 ('Scope','in_scope',           N'Can answer: sales, orders, quantity, customers, products, categories and countries, based on the approved semantic views.', 1),
 ('Scope','out_of_scope',       N'Cannot answer: profit or margin (not defined in the semantic layer), inventory, forecasts, marketing, returns, employees.', 1),

 ('Answer Style','ambiguity',   N'If a question is ambiguous (for example "best product" could mean revenue or units), state the assumption used or ask one short question.', 1),
 ('Answer Style','no_guessing', N'If the data cannot answer the question, say so. Never invent numbers.', 1),
 ('Answer Style','formatting',  N'Show amounts with thousand separators and always state the period the answer covers.', 2)
) AS s(context_area, context_key, context_value, priority)
ON t.context_area = s.context_area AND t.context_key = s.context_key
WHEN NOT MATCHED THEN
    INSERT (context_area, context_key, context_value, priority)
    VALUES (s.context_area, s.context_key, s.context_value, s.priority);
GO

MERGE genbi.view_context AS t
USING (VALUES
 ('vw_sales',
  N'Detailed sales transactions with product and customer attributes.',
  N'One row = one order line',
  N'Order-line detail, sales by country, gender, product or category, anything the monthly view cannot answer.',
  N'Customer KPIs such as segment or lifespan (use vw_customer_metrics). Product KPIs such as product segment (use vw_product_metrics).'),
 ('vw_monthly_sales',
  N'Monthly sales performance.',
  N'One row = one calendar month',
  N'Monthly trends of sales, orders, quantity and active customers.',
  N'Any breakdown by product, category, country or customer. It has no such columns.'),
 ('vw_customer_metrics',
  N'Customer value and behaviour KPIs.',
  N'One row = one customer',
  N'Customer ranking, segments, age groups, recency, lifespan, average order value.',
  N'Monthly trends. Product details. Totals for the whole business (it excludes sales without a customer).'),
 ('vw_product_metrics',
  N'Product performance KPIs.',
  N'One row = one product',
  N'Product ranking, product segments, category and subcategory performance, product recency.',
  N'Monthly trends. Customer details. Totals for the whole business (it excludes sales without a product).')
) AS s(view_name, business_purpose, grain, use_when, not_for)
ON t.view_name = s.view_name
WHEN NOT MATCHED THEN
    INSERT (view_name, business_purpose, grain, use_when, not_for)
    VALUES (s.view_name, s.business_purpose, s.grain, s.use_when, s.not_for);
GO

-- 3) One view that assembles everything the AI will later read, one line per item
CREATE OR ALTER VIEW genbi.vw_prompt_business_context
AS
SELECT 1 AS sec, priority AS ord, context_area AS grp, context_key AS item,
       CAST('[' + context_area + '] ' + context_key + ': ' + context_value AS NVARCHAR(MAX)) AS line_text
FROM genbi.business_context
WHERE is_active = 1
UNION ALL
SELECT 2, 0, 'View', view_name,
       CAST('semantic.' + view_name + ' | grain: ' + grain + ' | purpose: ' + business_purpose
            + ' | use when: ' + use_when + ' | not for: ' + not_for AS NVARCHAR(MAX))
FROM genbi.view_context;
GO

/* ---------- Corrections found while testing (applied after the seed) ---------- */
-- 1) Switch off the two limitations that T4 showed are not true (0 rows each)
UPDATE genbi.business_context
SET is_active = 0, updated_at = SYSDATETIME()
WHERE context_area = 'Data Limitation'
  AND context_key IN ('unmatched_customers', 'unmatched_products');

-- 2) Correct the "not for" text of the customer and product views
UPDATE genbi.view_context
SET not_for = N'Monthly trends. Product details. Sales lines with no valid order date are not included.',
    updated_at = SYSDATETIME()
WHERE view_name = 'vw_customer_metrics';



UPDATE genbi.view_context
SET not_for = N'Monthly trends. Customer details. Sales lines with no valid order date are not included.',
    updated_at = SYSDATETIME()
WHERE view_name = 'vw_product_metrics';

-- 3) Add the missing view
IF NOT EXISTS (SELECT 1 FROM genbi.view_context WHERE view_name = 'vw_data_range')
INSERT INTO genbi.view_context (view_name, business_purpose, grain, use_when, not_for)
VALUES ('vw_data_range',
        N'First and last order date in the data, and the latest month.',
        N'One row in total',
        N'Always, to find out what "today", "this year", "last month" or "recent" mean.',
        N'Any sales analysis. It holds dates only.');

-- 4) Point the "latest date" rule at the view that exists for this purpose
UPDATE genbi.business_context
SET context_value = N'Latest date = last_order_date in semantic.vw_data_range. Latest month = latest_month in the same view.',
    updated_at = SYSDATETIME()
WHERE context_area = 'Time' AND context_key = 'latest_date_rule';

-- 5) Resolve the 3 open questions (edit the wording if your answer is different)
UPDATE genbi.business_context
SET context_value = N'The source files do not state a currency. Amounts are shown as plain currency units. Amounts are whole numbers.',
    updated_at = SYSDATETIME()
WHERE context_area = 'Company' AND context_key = 'currency';

UPDATE genbi.business_context
SET context_value = N'Calendar year (January to December) is used. There is no fiscal year.',
    updated_at = SYSDATETIME()
WHERE context_area = 'Time' AND context_key = 'calendar';

UPDATE genbi.business_context
SET context_value = N'Customer names exist in the semantic views. Only show individual customer names when the user explicitly asks for a customer list.',
    updated_at = SYSDATETIME()
WHERE context_area = 'Data Limitation' AND context_key = 'personal_data';
GO

/* ---------- Partial latest month limitation ---------- */
IF NOT EXISTS (SELECT 1 FROM genbi.business_context
               WHERE context_area = 'Data Limitation' AND context_key = 'partial_latest_month')
INSERT INTO genbi.business_context (context_area, context_key, context_value, priority)
VALUES ('Data Limitation', 'partial_latest_month',
        N'The latest month in the data is usually incomplete because the data ends mid-month (see last_order_date in semantic.vw_data_range). When comparing it with earlier months, say that it is a partial month, or compare only complete months.', 1);
GO