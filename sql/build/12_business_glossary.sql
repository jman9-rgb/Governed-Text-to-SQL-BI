/* =============================================================================
   12 BUSINESS GLOSSARY
   Business words mapped to metrics, columns, filters and time rules.
   ============================================================================= */
USE DataWarehouse;
GO

/*
===============================================================================
PHASE 3 : BUSINESS GLOSSARY
Maps the words people actually say to something that exists in your semantic layer:
  Metric       -> a trusted KPI in genbi.metric_definition
  Column       -> a column in genbi.metric_catalog (view + column)
  Filter       -> a condition on a column (VIP, repeat customers ...)
  TimeRule     -> what today / this month / last month / this year mean in this data
  Ambiguous    -> words with no single meaning, with a default assumption to state
  Unsupported  -> things the data cannot answer (profit, inventory ...)
The glossary can only point to metrics and columns that exist: foreign keys enforce it.
Re-runnable: rows are only inserted when missing; your edits are never overwritten.
===============================================================================
*/
USE DataWarehouse;
GO

-- ---------------------------------------------------------------------------
-- 3.0  Small Phase 2 patch (found in the Phase 2 tests): all-time totals include undated orders
-- ---------------------------------------------------------------------------
UPDATE genbi.metric_definition
SET time_rule  = N'For a period, filter on order_date. All-time totals also include orders that have no order date.',
    updated_at = SYSDATETIME()
WHERE metric_code IN ('total_orders', 'active_customers');
GO

-- ---------------------------------------------------------------------------
-- 3.1  Table
-- ---------------------------------------------------------------------------
IF OBJECT_ID('genbi.business_glossary', 'U') IS NULL
CREATE TABLE genbi.business_glossary (
    glossary_id          INT IDENTITY(1,1) PRIMARY KEY,
    term                 NVARCHAR(100)  NOT NULL,          -- lower case, what the user says
    maps_to_type         NVARCHAR(12)   NOT NULL
        CONSTRAINT ck_glossary_type CHECK (maps_to_type IN ('Metric','Column','Filter','TimeRule','Ambiguous','Unsupported')),
    maps_to_metric_code  NVARCHAR(40)   NULL,
    maps_to_view         SYSNAME        NULL,
    maps_to_column       SYSNAME        NULL,
    filter_expression    NVARCHAR(500)  NULL,
    meaning              NVARCHAR(500)  NOT NULL,
    default_assumption   NVARCHAR(300)  NULL,
    needs_clarification  BIT            NOT NULL DEFAULT 0,
    example_question     NVARCHAR(300)  NULL,
    is_active            BIT            NOT NULL DEFAULT 1,
    owner                NVARCHAR(100)  NULL,
    updated_at           DATETIME2      NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT uq_business_glossary_term UNIQUE (term),
    CONSTRAINT fk_glossary_metric FOREIGN KEY (maps_to_metric_code)
        REFERENCES genbi.metric_definition (metric_code),
    CONSTRAINT fk_glossary_column FOREIGN KEY (maps_to_view, maps_to_column)
        REFERENCES genbi.metric_catalog (view_name, column_name),
    CONSTRAINT ck_glossary_metric_needs_code CHECK (maps_to_type <> 'Metric' OR maps_to_metric_code IS NOT NULL),
    CONSTRAINT ck_glossary_column_needs_target CHECK
        (maps_to_type NOT IN ('Column','Filter','TimeRule') OR (maps_to_view IS NOT NULL AND maps_to_column IS NOT NULL))
);
GO

-- ---------------------------------------------------------------------------
-- 3.2  Seed
--      (term, type, metric_code, view, column, filter_expression, meaning, default_assumption, needs_clarification, example_question)
--      The time rules and default assumptions are DECISIONS. Review them and change what does not fit your business.
-- ---------------------------------------------------------------------------
MERGE genbi.business_glossary AS t
USING (VALUES
-- ===== Metrics =====
('revenue','Metric','total_sales',NULL,NULL,NULL,'Total revenue of the order lines.',NULL,0,'What was the revenue in 2013?'),
('sales','Metric','total_sales',NULL,NULL,NULL,'Total revenue of the order lines.',NULL,0,'What were total sales?'),
('total sales','Metric','total_sales',NULL,NULL,NULL,'Total revenue of the order lines.',NULL,0,'What were total sales by year?'),
('turnover','Metric','total_sales',NULL,NULL,NULL,'Total revenue of the order lines.',NULL,0,'What was the turnover last year?'),
('orders','Metric','total_orders',NULL,NULL,NULL,'Number of distinct orders, not order lines.',NULL,0,'How many orders were placed?'),
('number of orders','Metric','total_orders',NULL,NULL,NULL,'Number of distinct orders, not order lines.',NULL,0,'What is the number of orders by month?'),
('order count','Metric','total_orders',NULL,NULL,NULL,'Number of distinct orders, not order lines.',NULL,0,NULL),
('units sold','Metric','total_quantity',NULL,NULL,NULL,'Total units sold.',NULL,0,'How many units did we sell?'),
('quantity','Metric','total_quantity',NULL,NULL,NULL,'Total units sold.',NULL,0,NULL),
('volume','Metric','total_quantity',NULL,NULL,NULL,'Units sold.','Volume is read as units, not money. State this.',1,'What was the sales volume by category?'),
('buyers','Metric','active_customers',NULL,NULL,NULL,'Distinct customers who placed an order in the period.',NULL,0,'How many buyers did we have in 2013?'),
('active customers','Metric','active_customers',NULL,NULL,NULL,'Distinct customers who placed an order in the period.',NULL,0,NULL),
('purchasing customers','Metric','active_customers',NULL,NULL,NULL,'Distinct customers who placed an order in the period.',NULL,0,NULL),
('aov','Metric','average_order_value',NULL,NULL,NULL,'Total sales divided by distinct orders.',NULL,0,'What is the AOV?'),
('average order value','Metric','average_order_value',NULL,NULL,NULL,'Total sales divided by distinct orders.',NULL,0,NULL),
('basket size','Metric','average_order_value',NULL,NULL,NULL,'Total sales divided by distinct orders.',NULL,0,NULL),
('average price','Metric','average_selling_price',NULL,NULL,NULL,'Quantity-weighted average price per unit.',NULL,0,'What is the average price per unit?'),
('price per unit','Metric','average_selling_price',NULL,NULL,NULL,'Quantity-weighted average price per unit.',NULL,0,NULL),
('revenue per customer','Metric','sales_per_customer',NULL,NULL,NULL,'Total sales divided by distinct customers who ordered.',NULL,0,'What is the revenue per customer?'),
('sales per customer','Metric','sales_per_customer',NULL,NULL,NULL,'Total sales divided by distinct customers who ordered.',NULL,0,NULL),
('monthly sales','Metric','monthly_sales',NULL,NULL,NULL,'Revenue per calendar month.',NULL,0,'Show monthly sales for 2013.'),
('sales trend','Metric','monthly_sales',NULL,NULL,NULL,'Sales by calendar month over time.','Show monthly sales and say that the latest month is partial.',0,'What is the sales trend?'),
('mom growth','Metric','mom_growth_pct',NULL,NULL,NULL,'Percentage change of monthly sales versus the previous month.',NULL,0,'What was the MoM growth in 2013?'),
('month over month growth','Metric','mom_growth_pct',NULL,NULL,NULL,'Percentage change of monthly sales versus the previous month.',NULL,0,NULL),
('growth','Metric','mom_growth_pct',NULL,NULL,NULL,'Growth is read as month-over-month growth.','State that growth means month over month. Year over year is not available.',1,'What is the sales growth?'),
('vip customers','Metric','vip_customers',NULL,NULL,NULL,'Number of customers in the VIP segment.',NULL,0,'How many VIP customers do we have?'),

-- ===== Columns =====
('country','Column',NULL,'vw_sales','country',NULL,'Country of the customer.',NULL,0,'Which country has the highest sales?'),
('region','Column',NULL,'vw_sales','country',NULL,'Region is read as the customer country. There is no other geography.','State that region means country.',1,'Sales by region'),
('gender','Column',NULL,'vw_sales','gender',NULL,'Gender of the customer: Male, Female or n/a.',NULL,0,'Sales by gender'),
('marital status','Column',NULL,'vw_sales','marital_status',NULL,'Marital status of the customer: Single, Married or n/a.',NULL,0,NULL),
('category','Column',NULL,'vw_sales','category',NULL,'Product category.','Use vw_sales for sales by category. Use vw_product_metrics for product KPIs by category.',0,'Which category has the most sales?'),
('subcategory','Column',NULL,'vw_sales','subcategory',NULL,'Product subcategory.','Use vw_sales for sales by subcategory.',0,NULL),
('product line','Column',NULL,'vw_sales','product_line',NULL,'Product line: Mountain, Road, Touring, Other Sales or n/a.',NULL,0,'Sales by product line'),
('age group','Column',NULL,'vw_customer_metrics','age_group',NULL,'Age band of the customer at the last order date in the data.',NULL,0,'Which age group spends the most?'),
('customer segment','Column',NULL,'vw_customer_metrics','customer_segment',NULL,'VIP, Regular or New.',NULL,0,'How many customers are in each segment?'),
('customer tier','Column',NULL,'vw_customer_metrics','customer_segment',NULL,'Tier is read as the customer segment: VIP, Regular or New.','State that tier means customer segment.',1,NULL),
('recency','Column',NULL,'vw_customer_metrics','recency',NULL,'Months since the last order of the customer.',NULL,0,NULL),
('lifespan','Column',NULL,'vw_customer_metrics','lifespan',NULL,'Months between the first and the last order of the customer.',NULL,0,NULL),
('tenure','Column',NULL,'vw_customer_metrics','lifespan',NULL,'Tenure is read as customer lifespan in months.','State that tenure means lifespan.',1,NULL),
('order date','Column',NULL,'vw_sales','order_date',NULL,'Date the order was placed.',NULL,0,NULL),
('shipping date','Column',NULL,'vw_sales','shipping_date',NULL,'Date the order was shipped.',NULL,0,NULL),
('due date','Column',NULL,'vw_sales','due_date',NULL,'Due date of the order.',NULL,0,NULL),

-- ===== Filters =====
('vip','Filter',NULL,'vw_customer_metrics','customer_segment','customer_segment = ''VIP''','Customers with a lifespan of 12 months or more and total sales above 5000.',NULL,0,'List the VIP customers by sales.'),
('regular customers','Filter',NULL,'vw_customer_metrics','customer_segment','customer_segment = ''Regular''','Customers with a lifespan of 12 months or more and total sales of 5000 or less.',NULL,0,NULL),
('new customers','Filter',NULL,'vw_customer_metrics','customer_segment','customer_segment = ''New''','Customers with a lifespan under 12 months. This is not the same as first-time buyers.','State the definition of New.',0,'How many new customers do we have?'),
('repeat customers','Filter',NULL,'vw_customer_metrics','total_orders','total_orders >= 2','Customers with two or more orders.','Repeat is read as two or more orders. State this.',1,'How many repeat customers do we have?'),
('one-time customers','Filter',NULL,'vw_customer_metrics','total_orders','total_orders = 1','Customers with exactly one order.',NULL,0,NULL),
('unknown age','Filter',NULL,'vw_customer_metrics','age_group','age_group = ''Unknown''','Customers with no birthdate.',NULL,0,NULL),
('best sellers','Filter',NULL,'vw_product_metrics','product_segment','product_segment = ''High-Performer''','Products with total sales above 50000.','Best seller is read as the High-Performer segment (by sales, not units). State this.',1,'List the best sellers.'),
('low performers','Filter',NULL,'vw_product_metrics','product_segment','product_segment = ''Low-Performer''','Products with total sales below 10000.',NULL,0,'Which products are low performers?'),

-- ===== Time rules (all relative to semantic.vw_data_range, never the system date) =====
('today','TimeRule',NULL,'vw_data_range','last_order_date','last_order_date from semantic.vw_data_range','Today means the last order date in the data, not the system date.',NULL,0,NULL),
('now','TimeRule',NULL,'vw_data_range','last_order_date','last_order_date from semantic.vw_data_range','Now means the last order date in the data, not the system date.',NULL,0,NULL),
('this month','TimeRule',NULL,'vw_data_range','latest_month','latest_month from semantic.vw_data_range','The latest month in the data. It is incomplete because the data ends mid-month.','Say that the month is partial.',1,'What are the sales this month?'),
('latest month','TimeRule',NULL,'vw_data_range','latest_month','latest_month from semantic.vw_data_range','The latest month in the data. It is incomplete because the data ends mid-month.','Say that the month is partial.',0,NULL),
('last month','TimeRule',NULL,'vw_data_range','latest_month','On vw_monthly_sales: sales_month = DATEADD(MONTH, -1, latest_month). On vw_sales: order_date >= DATEADD(MONTH, -1, latest_month) AND order_date < latest_month. latest_month comes from semantic.vw_data_range.','The month before the latest month in the data. It is a complete month.','Last month is the month before the latest (partial) month. State the month name.',1,'What were total sales last month?'),
('this year','TimeRule',NULL,'vw_data_range','last_order_date','order_date >= DATEFROMPARTS(YEAR(last_order_date), 1, 1), with last_order_date from semantic.vw_data_range','The year of the last order date, from 1 January to the last order date.','Say that the year is incomplete when it is the latest year in the data.',1,'What are the sales this year?'),
('last year','TimeRule',NULL,'vw_data_range','last_order_date','order_date >= DATEFROMPARTS(YEAR(last_order_date) - 1, 1, 1) AND order_date < DATEFROMPARTS(YEAR(last_order_date), 1, 1), with last_order_date from semantic.vw_data_range','The calendar year before the year of the last order date.',NULL,0,'What were the sales last year?'),
('year to date','TimeRule',NULL,'vw_data_range','last_order_date','order_date >= DATEFROMPARTS(YEAR(last_order_date), 1, 1), with last_order_date from semantic.vw_data_range','From 1 January of the year of the last order date up to the last order date.',NULL,0,NULL),
('ytd','TimeRule',NULL,'vw_data_range','last_order_date','order_date >= DATEFROMPARTS(YEAR(last_order_date), 1, 1), with last_order_date from semantic.vw_data_range','From 1 January of the year of the last order date up to the last order date.',NULL,0,NULL),
('last 12 months','TimeRule',NULL,'vw_data_range','latest_month','order_date >= DATEADD(MONTH, -12, latest_month) AND order_date < latest_month, with latest_month from semantic.vw_data_range','The 12 complete months before the latest (partial) month.','State the exact period used.',1,'What were sales in the last 12 months?'),

-- ===== Ambiguous words (state the default assumption, or ask) =====
('best customers','Ambiguous',NULL,'vw_customer_metrics','total_sales',NULL,'Best is not defined. It could mean highest sales, most orders or highest order value.','Rank by total_sales and state this.',1,'Who are the best customers?'),
('top customers','Ambiguous',NULL,'vw_customer_metrics','total_sales',NULL,'Top is not defined. It could mean highest sales, most orders or highest order value.','Rank by total_sales and state this.',1,'Who are the top 10 customers?'),
('best products','Ambiguous',NULL,'vw_product_metrics','total_sales',NULL,'Best could mean highest sales or most units sold.','Rank by total_sales and state this.',1,'What are the best products?'),
('top products','Ambiguous',NULL,'vw_product_metrics','total_sales',NULL,'Top could mean highest sales or most units sold.','Rank by total_sales and state this.',1,'What are the top 5 products?'),
('popular products','Ambiguous',NULL,'vw_product_metrics','total_quantity',NULL,'Popular is read as most units sold.','Rank by total_quantity and state this.',1,'Which products are the most popular?'),
('loyal customers','Ambiguous',NULL,'vw_customer_metrics','customer_segment',NULL,'Loyal is not defined. Customers with a lifespan of 12 months or more are in the VIP and Regular segments.','Use customer_segment IN (''VIP'', ''Regular'') and state this.',1,'How many loyal customers do we have?'),
('inactive customers','Ambiguous',NULL,'vw_customer_metrics','recency',NULL,'Inactive needs a time limit. Recency is the months since the last order.','Ask for the number of months. If none is given, sort by recency, highest first, and say that no limit was applied.',1,'Which customers are inactive?'),
('inactive products','Ambiguous',NULL,'vw_product_metrics','recency_in_months',NULL,'Inactive needs a time limit. Recency is the months since the last sale.','Ask for the number of months. If none is given, sort by recency_in_months, highest first, and say that no limit was applied.',1,'Which products have not sold recently?'),
('recent','Ambiguous',NULL,'vw_data_range','latest_month',NULL,'Recent is not a fixed period.','Use the last 3 complete months before the latest month and state the period.',1,'What were the recent sales?'),

-- ===== Unsupported: the data cannot answer these =====
('profit','Unsupported',NULL,NULL,NULL,NULL,'Profit is not defined in the semantic layer. The cost column of vw_product_metrics is a product master cost, not the cost of the goods sold.','Say it cannot be answered. Offer sales analysis instead.',0,'What was the profit last year?'),
('margin','Unsupported',NULL,NULL,NULL,NULL,'Margin is not defined in the semantic layer. There is no cost of goods sold.','Say it cannot be answered. Offer sales analysis instead.',0,NULL),
('inventory','Unsupported',NULL,NULL,NULL,NULL,'There is no inventory or stock data.','Say it cannot be answered.',0,'How much stock do we have?'),
('returns','Unsupported',NULL,NULL,NULL,NULL,'There is no returns or refunds data.','Say it cannot be answered.',0,NULL),
('forecast','Unsupported',NULL,NULL,NULL,NULL,'There is only historical data. No forecasts are produced.','Say it cannot be answered. Offer the historical trend instead.',0,'What will sales be next month?'),
('churn rate','Unsupported',NULL,NULL,NULL,NULL,'Churn is not defined in the semantic layer.','Say it cannot be answered. Offer recency analysis instead.',0,NULL),
('retention','Unsupported',NULL,NULL,NULL,NULL,'Retention is not defined in the semantic layer.','Say it cannot be answered. Offer repeat customers instead.',0,NULL),
('year over year','Unsupported',NULL,NULL,NULL,NULL,'There is no trusted year-over-year metric yet.','Say it is not available yet. Offer monthly sales by year instead.',0,'What is the year over year growth?')
) AS s(term, maps_to_type, maps_to_metric_code, maps_to_view, maps_to_column, filter_expression,
       meaning, default_assumption, needs_clarification, example_question)
ON t.term = s.term
WHEN NOT MATCHED THEN
    INSERT (term, maps_to_type, maps_to_metric_code, maps_to_view, maps_to_column, filter_expression,
            meaning, default_assumption, needs_clarification, example_question)
    VALUES (s.term, s.maps_to_type, s.maps_to_metric_code, s.maps_to_view, s.maps_to_column, s.filter_expression,
            s.meaning, s.default_assumption, s.needs_clarification, s.example_question);
GO

-- ---------------------------------------------------------------------------
-- 3.3  Prompt view: synonyms of the same metric are grouped on one line to save tokens
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW genbi.vw_prompt_glossary
AS
SELECT 1 AS sec, maps_to_metric_code AS grp,
       CAST('GLOSSARY: "' + STRING_AGG(CAST(term AS NVARCHAR(MAX)), '", "') WITHIN GROUP (ORDER BY term)
            + '" all mean the trusted metric ' + maps_to_metric_code AS NVARCHAR(MAX)) AS line_text
FROM genbi.business_glossary
WHERE is_active = 1 AND maps_to_type = 'Metric' AND needs_clarification = 0
GROUP BY maps_to_metric_code
UNION ALL
SELECT 2, term,
       CAST('GLOSSARY: "' + term + '" -> ' + maps_to_type
            + ISNULL(' metric ' + maps_to_metric_code, '')
            + ISNULL(' semantic.' + maps_to_view + '.' + maps_to_column, '')
            + ISNULL(' | filter: ' + filter_expression, '')
            + ' | ' + meaning
            + ISNULL(' | assumption: ' + default_assumption, '')
            + CASE WHEN needs_clarification = 1 THEN ' | ask the user or state the assumption' ELSE '' END
            AS NVARCHAR(MAX))
FROM genbi.business_glossary
WHERE is_active = 1 AND NOT (maps_to_type = 'Metric' AND needs_clarification = 0);
GO
