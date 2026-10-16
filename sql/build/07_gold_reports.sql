/* =============================================================================
   07 GOLD REPORT VIEWS
   gold.report_customers and gold.report_products. The semantic views in step 08 are built on these two views.
   ============================================================================= */
USE DataWarehouse;
GO

/*
===============================================================================
Customer Report
===============================================================================
Purpose:
    - This report consolidates key customer metrics and behaviors

Highlights:
    1. Gathers essential fields such as names, ages, and transaction details.
	2. Segments customers into categories (VIP, Regular, New) and age groups.
    3. Aggregates customer-level metrics:
	   - total orders
	   - total sales
	   - total quantity purchased
	   - total products
	   - lifespan (in months)
    4. Calculates valuable KPIs:
	    - recency (months since last order, measured from the LAST DATE IN THE DATA)
		- average order value
		- average monthly spend

Fixes applied here:
    FIX 1  comma added between total_products and lifespan
    FIX 2  GO after the view
    FIX 4  decimal division with NULLIF (no truncated averages)
    FIX 5  recency and age use the dataset's last order date; age counts real birthdays
    FIX 6  NULL age -> 'Unknown' age group
    NOTE   sales with no matching customer are excluded from this customer-level report
===============================================================================
*/

-- =============================================================================
-- Create Report: gold.report_customers
-- =============================================================================
CREATE OR ALTER VIEW gold.report_customers AS

WITH ref AS (
/*---------------------------------------------------------------------------
0) Reference date = last order date in the data (NOT today's date)
---------------------------------------------------------------------------*/
SELECT MAX(order_date) AS ref_date FROM gold.fact_sales
),

base_query AS (
/*---------------------------------------------------------------------------
1) Base Query: Retrieves core columns from tables
---------------------------------------------------------------------------*/
SELECT
    f.order_number,
    f.product_key,
    f.order_date,
    f.sales_amount,
    f.quantity,
    c.customer_key,
    c.customer_number,
    CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
    CASE
        WHEN c.birthdate IS NULL THEN NULL
        ELSE DATEDIFF(YEAR, c.birthdate, r.ref_date)
           - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, c.birthdate, r.ref_date), c.birthdate) > r.ref_date
                  THEN 1 ELSE 0 END      -- subtract 1 if the birthday has not happened yet
    END AS age
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
    ON c.customer_key = f.customer_key
CROSS JOIN ref r
WHERE f.order_date IS NOT NULL
  AND c.customer_key IS NOT NULL
),

customer_aggregation AS (
/*---------------------------------------------------------------------------
2) Customer Aggregations: Summarizes key metrics at the customer level
---------------------------------------------------------------------------*/
SELECT
    customer_key,
    customer_number,
    customer_name,
    age,
    COUNT(DISTINCT order_number)      AS total_orders,
    CAST(SUM(sales_amount) AS BIGINT) AS total_sales,
    SUM(quantity)                     AS total_quantity,
    COUNT(DISTINCT product_key)       AS total_products,
    MAX(order_date)                   AS last_order_date,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan
FROM base_query
GROUP BY
    customer_key,
    customer_number,
    customer_name,
    age
)

SELECT
    ca.customer_key,
    ca.customer_number,
    ca.customer_name,
    ca.age,
    CASE
        WHEN ca.age IS NULL           THEN 'Unknown'
        WHEN ca.age < 20              THEN 'Under 20'
        WHEN ca.age BETWEEN 20 AND 29 THEN '20-29'
        WHEN ca.age BETWEEN 30 AND 39 THEN '30-39'
        WHEN ca.age BETWEEN 40 AND 49 THEN '40-49'
        ELSE '50 and above'
    END AS age_group,
    CASE
        WHEN ca.lifespan >= 12 AND ca.total_sales > 5000  THEN 'VIP'
        WHEN ca.lifespan >= 12 AND ca.total_sales <= 5000 THEN 'Regular'
        ELSE 'New'
    END AS customer_segment,
    ca.last_order_date,
    DATEDIFF(MONTH, ca.last_order_date, r.ref_date) AS recency,
    ca.total_orders,
    ca.total_sales,
    ca.total_quantity,
    ca.total_products,
    ca.lifespan,
    -- Compute average order value (AOV)
    CAST(ROUND(CAST(ca.total_sales AS DECIMAL(18,2)) / NULLIF(ca.total_orders, 0), 2) AS DECIMAL(18,2)) AS avg_order_value,
    -- Compute average monthly spend
    CAST(CASE WHEN ca.lifespan = 0 THEN ca.total_sales
              ELSE ROUND(CAST(ca.total_sales AS DECIMAL(18,2)) / ca.lifespan, 2)
         END AS DECIMAL(18,2)) AS avg_monthly_spend
FROM customer_aggregation ca
CROSS JOIN ref r;
GO

/*
===============================================================================
Product Report
===============================================================================
Purpose:
    - This report consolidates key product metrics and behaviors.

Highlights:
    1. Gathers essential fields such as product name, category, subcategory, and cost.
    2. Segments products by revenue to identify High-Performers, Mid-Range, or Low-Performers.
    3. Aggregates product-level metrics:
       - total orders
       - total sales
       - total quantity sold
       - total customers (unique)
       - lifespan (in months)
    4. Calculates valuable KPIs:
       - recency (months since last sale, measured from the LAST DATE IN THE DATA)
       - average order revenue (AOR)
       - average monthly revenue

Fixes applied here: FIX 2 (GO), FIX 4 (decimal division), FIX 5 (recency reference date)
===============================================================================
*/
-- =============================================================================
-- Create Report: gold.report_products
-- =============================================================================
CREATE OR ALTER VIEW gold.report_products AS

WITH ref AS (
SELECT MAX(order_date) AS ref_date FROM gold.fact_sales
),

base_query AS (
/*---------------------------------------------------------------------------
1) Base Query: Retrieves core columns from fact_sales and dim_products
---------------------------------------------------------------------------*/
    SELECT
        f.order_number,
        f.order_date,
        f.customer_key,
        f.sales_amount,
        f.quantity,
        p.product_key,
        p.product_name,
        p.category,
        p.subcategory,
        p.cost
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON f.product_key = p.product_key
    WHERE f.order_date IS NOT NULL  -- only consider valid sales dates
      AND p.product_key IS NOT NULL -- only sales that match a product
),

product_aggregations AS (
/*---------------------------------------------------------------------------
2) Product Aggregations: Summarizes key metrics at the product level
---------------------------------------------------------------------------*/
SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan,
    MAX(order_date) AS last_sale_date,
    COUNT(DISTINCT order_number) AS total_orders,
    COUNT(DISTINCT customer_key) AS total_customers,
    CAST(SUM(sales_amount) AS BIGINT) AS total_sales,
    SUM(quantity) AS total_quantity,
    ROUND(AVG(CAST(sales_amount AS FLOAT) / NULLIF(quantity, 0)), 1) AS avg_selling_price
FROM base_query
GROUP BY
    product_key,
    product_name,
    category,
    subcategory,
    cost
)

/*---------------------------------------------------------------------------
  3) Final Query: Combines all product results into one output
---------------------------------------------------------------------------*/
SELECT
    pa.product_key,
    pa.product_name,
    pa.category,
    pa.subcategory,
    pa.cost,
    pa.last_sale_date,
    DATEDIFF(MONTH, pa.last_sale_date, r.ref_date) AS recency_in_months,
    CASE
        WHEN pa.total_sales > 50000  THEN 'High-Performer'
        WHEN pa.total_sales >= 10000 THEN 'Mid-Range'
        ELSE 'Low-Performer'
    END AS product_segment,
    pa.lifespan,
    pa.total_orders,
    pa.total_sales,
    pa.total_quantity,
    pa.total_customers,
    pa.avg_selling_price,
    -- Average Order Revenue (AOR)
    CAST(ROUND(CAST(pa.total_sales AS DECIMAL(18,2)) / NULLIF(pa.total_orders, 0), 2) AS DECIMAL(18,2)) AS avg_order_revenue,
    -- Average Monthly Revenue
    CAST(CASE WHEN pa.lifespan = 0 THEN pa.total_sales
              ELSE ROUND(CAST(pa.total_sales AS DECIMAL(18,2)) / pa.lifespan, 2)
         END AS DECIMAL(18,2)) AS avg_monthly_revenue
FROM product_aggregations pa
CROSS JOIN ref r;
GO
