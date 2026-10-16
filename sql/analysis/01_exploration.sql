/* =============================================================================
   EXPLORATORY ANALYSIS
   Database, dimensions, dates, measures, magnitude, ranking, time, cumulative, performance, segmentation, part-to-whole.
   Not needed to rebuild the project. These are the analysis queries run on the Gold layer.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- 7 ---------- */
/*
===============================================================================
Database Exploration
===============================================================================
Purpose:
    - To explore the structure of the database, including the list of tables and their schemas.
    - To inspect the columns and metadata for specific tables.

Table Used:
    - INFORMATION_SCHEMA.TABLES
    - INFORMATION_SCHEMA.COLUMNS
===============================================================================
*/

-- Retrieve a list of all tables in the database
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES;

-- Retrieve all columns for a specific table (dim_customers)
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    IS_NULLABLE,
    CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'dim_customers';

/* ---------- 8 ---------- */
/*
===============================================================================
Dimensions Exploration
===============================================================================
Purpose:
    - To explore the structure of dimension tables.

SQL Functions Used:
    - DISTINCT
    - ORDER BY
===============================================================================
*/

-- Retrieve a list of unique countries from which customers originate
SELECT DISTINCT
    country
FROM gold.dim_customers
ORDER BY country;

-- Retrieve a list of unique categories, subcategories, and products
SELECT DISTINCT
    category,
    subcategory,
    product_name
FROM gold.dim_products
ORDER BY category, subcategory, product_name;

/* ---------- 9 ---------- */
/*
===============================================================================
Date Range Exploration
===============================================================================
Purpose:
    - To determine the temporal boundaries of key data points.
    - To understand the range of historical data.

SQL Functions Used:
    - MIN(), MAX(), DATEDIFF()
===============================================================================
*/

-- Determine the first and last order date and the total duration in months
SELECT
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS order_range_months
FROM gold.fact_sales;

-- Find the youngest and oldest customer based on birthdate
-- FIX 5: ages are measured at the dataset's last order date, not GETDATE()
SELECT
    MIN(birthdate) AS oldest_birthdate,
    DATEDIFF(YEAR, MIN(birthdate), (SELECT MAX(order_date) FROM gold.fact_sales)) AS oldest_age,
    MAX(birthdate) AS youngest_birthdate,
    DATEDIFF(YEAR, MAX(birthdate), (SELECT MAX(order_date) FROM gold.fact_sales)) AS youngest_age
FROM gold.dim_customers;

/* ---------- 10 ---------- */
/*
===============================================================================
Measures Exploration (Key Metrics)
===============================================================================
Purpose:
    - To calculate aggregated metrics (e.g., totals, averages) for quick insights.
    - To identify overall trends or spot anomalies.

SQL Functions Used:
    - COUNT(), SUM(), AVG()
===============================================================================
*/

-- Find the Total Sales
SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM gold.fact_sales;

-- Find how many items are sold
SELECT SUM(CAST(quantity AS BIGINT)) AS total_quantity FROM gold.fact_sales;

-- Find the average selling price (cast avoids integer truncation)
SELECT AVG(CAST(price AS DECIMAL(18,2))) AS avg_price FROM gold.fact_sales;

-- Find the Total number of Orders
SELECT COUNT(order_number) AS total_order_lines FROM gold.fact_sales;
SELECT COUNT(DISTINCT order_number) AS total_orders FROM gold.fact_sales;

-- Find the total number of products
SELECT COUNT(product_name) AS total_products FROM gold.dim_products;

-- Find the total number of customers
SELECT COUNT(customer_key) AS total_customers FROM gold.dim_customers;

-- Find the total number of customers that has placed an order
SELECT COUNT(DISTINCT customer_key) AS total_customers FROM gold.fact_sales;

-- Generate a Report that shows all key metrics of the business
SELECT 'Total Sales' AS measure_name, CAST(SUM(CAST(sales_amount AS BIGINT)) AS DECIMAL(18,2)) AS measure_value FROM gold.fact_sales
UNION ALL
SELECT 'Total Quantity', CAST(SUM(CAST(quantity AS BIGINT)) AS DECIMAL(18,2)) FROM gold.fact_sales
UNION ALL
SELECT 'Average Price', AVG(CAST(price AS DECIMAL(18,2))) FROM gold.fact_sales
UNION ALL
SELECT 'Total Orders', CAST(COUNT(DISTINCT order_number) AS DECIMAL(18,2)) FROM gold.fact_sales
UNION ALL
SELECT 'Total Products', CAST(COUNT(DISTINCT product_name) AS DECIMAL(18,2)) FROM gold.dim_products
UNION ALL
SELECT 'Total Customers', CAST(COUNT(customer_key) AS DECIMAL(18,2)) FROM gold.dim_customers;

/* ---------- 11 ---------- */
/*
===============================================================================
Magnitude Analysis
===============================================================================
Purpose:
    - To quantify data and group results by specific dimensions.
    - For understanding data distribution across categories.

SQL Functions Used:
    - Aggregate Functions: SUM(), COUNT(), AVG()
    - GROUP BY, ORDER BY
===============================================================================
*/

-- Find total customers by countries
SELECT
    country,
    COUNT(customer_key) AS total_customers
FROM gold.dim_customers
GROUP BY country
ORDER BY total_customers DESC;

-- Find total customers by gender
SELECT
    gender,
    COUNT(customer_key) AS total_customers
FROM gold.dim_customers
GROUP BY gender
ORDER BY total_customers DESC;

-- Find total products by category
SELECT
    category,
    COUNT(product_key) AS total_products
FROM gold.dim_products
GROUP BY category
ORDER BY total_products DESC;

-- What is the average costs in each category?
SELECT
    category,
    AVG(CAST(cost AS DECIMAL(18,2))) AS avg_cost
FROM gold.dim_products
GROUP BY category
ORDER BY avg_cost DESC;

-- What is the total revenue generated for each category?
SELECT
    p.category,
    SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
    ON p.product_key = f.product_key
GROUP BY p.category
ORDER BY total_revenue DESC;


-- What is the total revenue generated by each customer?
SELECT
    c.customer_key,
    c.first_name,
    c.last_name,
    SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
    ON c.customer_key = f.customer_key
GROUP BY
    c.customer_key,
    c.first_name,
    c.last_name
ORDER BY total_revenue DESC;

-- What is the distribution of sold items across countries?
SELECT
    c.country,
    SUM(CAST(f.quantity AS BIGINT)) AS total_sold_items
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
    ON c.customer_key = f.customer_key
GROUP BY c.country
ORDER BY total_sold_items DESC;

/* ---------- 12 ---------- */
/*
===============================================================================
Ranking Analysis
===============================================================================
Purpose:
    - To rank items (e.g., products, customers) based on performance or other metrics.
    - To identify top performers or laggards.

SQL Functions Used:
    - Window Ranking Functions: RANK(), DENSE_RANK(), ROW_NUMBER(), TOP
    - Clauses: GROUP BY, ORDER BY
===============================================================================
*/

-- Which 5 products Generating the Highest Revenue?
-- Simple Ranking
SELECT TOP 5
    p.product_name,
    SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
    ON p.product_key = f.product_key
GROUP BY p.product_name
ORDER BY total_revenue DESC;

-- Complex but Flexibly Ranking Using Window Functions
SELECT *
FROM (
    SELECT
        p.product_name,
        SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue,
        RANK() OVER (ORDER BY SUM(CAST(f.sales_amount AS BIGINT)) DESC) AS rank_products
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON p.product_key = f.product_key
    GROUP BY p.product_name
) AS ranked_products
WHERE rank_products <= 5;

-- What are the 5 worst-performing products in terms of sales?
SELECT TOP 5
    p.product_name,
    SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
    ON p.product_key = f.product_key
GROUP BY p.product_name
ORDER BY total_revenue;

-- Find the top 10 customers who have generated the highest revenue
SELECT TOP 10
    c.customer_key,
    c.first_name,
    c.last_name,
    SUM(CAST(f.sales_amount AS BIGINT)) AS total_revenue
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
    ON c.customer_key = f.customer_key
GROUP BY
    c.customer_key,
    c.first_name,
    c.last_name
ORDER BY total_revenue DESC;

-- The 3 customers with the fewest orders placed
SELECT TOP 3
    c.customer_key,
    c.first_name,
    c.last_name,
    COUNT(DISTINCT order_number) AS total_orders
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
    ON c.customer_key = f.customer_key
GROUP BY
    c.customer_key,
    c.first_name,
    c.last_name
ORDER BY total_orders ;

/* ---------- 13 ---------- */
/*
===============================================================================
Change Over Time Analysis
===============================================================================
Purpose:
    - To track trends, growth, and changes in key metrics over time.
    - For time-series analysis and identifying seasonality.
    - To measure growth or decline over specific periods.

SQL Functions Used:
    - Date Functions: DATEPART(), DATETRUNC(), FORMAT()
    - Aggregate Functions: SUM(), COUNT(), AVG()
===============================================================================
*/

-- Analyse sales performance over time
-- Quick Date Functions
SELECT
    YEAR(order_date) AS order_year,
    MONTH(order_date) AS order_month,
    SUM(CAST(sales_amount AS BIGINT)) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(CAST(quantity AS BIGINT)) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY YEAR(order_date), MONTH(order_date)
ORDER BY YEAR(order_date), MONTH(order_date);

-- DATETRUNC()   (needs SQL Server 2022 or newer; use the DATEFROMPARTS query below on older versions)
SELECT
    DATETRUNC(month, order_date) AS order_date,
    SUM(CAST(sales_amount AS BIGINT)) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(CAST(quantity AS BIGINT)) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY DATETRUNC(month, order_date)
ORDER BY DATETRUNC(month, order_date);

-- DATEFROMPARTS()  (works on every SQL Server version, same result as DATETRUNC)
SELECT
    DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS order_date,
    SUM(CAST(sales_amount AS BIGINT)) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(CAST(quantity AS BIGINT)) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)
ORDER BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1);

-- FORMAT()
-- FIX: the original ORDER BY FORMAT(...) sorted alphabetically (Apr, Aug, Dec ...).
--      Sort by the real date instead.
SELECT
    FORMAT(order_date, 'yyyy-MMM') AS order_date,
    SUM(CAST(sales_amount AS BIGINT)) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(CAST(quantity AS BIGINT)) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY FORMAT(order_date, 'yyyy-MMM')
ORDER BY MIN(order_date);

/* ---------- 14 ---------- */
/*
===============================================================================
Cumulative Analysis
===============================================================================
Purpose:
    - To calculate running totals or moving averages for key metrics.
    - To track performance over time cumulatively.
    - Useful for growth analysis or identifying long-term trends.

SQL Functions Used:
    - Window Functions: SUM() OVER(), AVG() OVER()
===============================================================================
*/

-- Calculate the total sales per year
-- and the running total of sales over time.
-- FIX: the old "moving_average_price" was really a cumulative average. Now both exist,
--      correctly named. DATEFROMPARTS replaces DATETRUNC so it runs on any version.
SELECT
    order_year,
    total_sales,
    SUM(total_sales) OVER (ORDER BY order_year ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total_sales,
    AVG(avg_price)   OVER (ORDER BY order_year ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_avg_price,
    AVG(avg_price)   OVER (ORDER BY order_year ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)         AS moving_avg_price_3yr
FROM
(
    SELECT
        DATEFROMPARTS(YEAR(order_date), 1, 1) AS order_year,
        SUM(CAST(sales_amount AS BIGINT)) AS total_sales,
        AVG(CAST(price AS DECIMAL(18,2))) AS avg_price
    FROM gold.fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY DATEFROMPARTS(YEAR(order_date), 1, 1)
) t;

/* ---------- 15 ---------- */
/*
===============================================================================
Performance Analysis (Year-over-Year, Month-over-Month)
===============================================================================
Purpose:
    - To measure the performance of products, customers, or regions over time.
    - For benchmarking and identifying high-performing entities.
    - To track yearly trends and growth.

SQL Functions Used:
    - LAG(): Accesses data from previous rows.
    - AVG() OVER(): Computes average values within partitions.
    - CASE: Defines conditional logic for trend analysis.
===============================================================================
*/

/* Analyze the yearly performance of products by comparing their sales
to both the average sales performance of the product and the previous year's sales */
WITH yearly_product_sales AS (
    SELECT
        YEAR(f.order_date) AS order_year,
        p.product_name,
        SUM(CAST(f.sales_amount AS BIGINT)) AS current_sales
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON f.product_key = p.product_key
    WHERE f.order_date IS NOT NULL
    GROUP BY
        YEAR(f.order_date),
        p.product_name
)
SELECT
    order_year,
    product_name,
    current_sales,
    AVG(current_sales) OVER (PARTITION BY product_name) AS avg_sales,
    current_sales - AVG(current_sales) OVER (PARTITION BY product_name) AS diff_avg,
    CASE
        WHEN current_sales - AVG(current_sales) OVER (PARTITION BY product_name) > 0 THEN 'Above Avg'
        WHEN current_sales - AVG(current_sales) OVER (PARTITION BY product_name) < 0 THEN 'Below Avg'
        ELSE 'Avg'
    END AS avg_change,
    -- Year-over-Year Analysis
    LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year) AS py_sales,
    current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year) AS diff_py,
    CASE
        WHEN current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year) > 0 THEN 'Increase'
        WHEN current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year) < 0 THEN 'Decrease'
        ELSE 'No Change'
    END AS py_change
FROM yearly_product_sales
ORDER BY product_name, order_year;

/* ---------- 16 ---------- */
/*
===============================================================================
Data Segmentation Analysis
===============================================================================
Purpose:
    - To group data into meaningful categories for targeted insights.
    - For customer segmentation, product categorization, or regional analysis.

SQL Functions Used:
    - CASE: Defines custom segmentation logic.
    - GROUP BY: Groups data into segments.
===============================================================================
*/

/*Segment products into cost ranges and
count how many products fall into each segment*/
WITH product_segments AS (
    SELECT
        product_key,
        product_name,
        cost,
        CASE
            WHEN cost < 100   THEN 'Below 100'
            WHEN cost <= 500  THEN '100-500'
            WHEN cost <= 1000 THEN '500-1000'
            ELSE 'Above 1000'
        END AS cost_range   -- ranges no longer overlap at 500 / 1000
    FROM gold.dim_products
)
SELECT
    cost_range,
    COUNT(product_key) AS total_products
FROM product_segments
GROUP BY cost_range
ORDER BY total_products DESC;

/*
FIX (duplicated logic): the customer segmentation query that lived here
(VIP / Regular / New) repeated the same rule as gold.report_customers.
There must be ONE definition, and it is the view in section 18.
The segment-count query now lives at the end of section 18.
*/

/* ---------- 17 ---------- */
/*
===============================================================================
Part-to-Whole Analysis
===============================================================================
Purpose:
    - To compare performance or metrics across dimensions or time periods.
    - To evaluate differences between categories.
    - Useful for A/B testing or regional comparisons.

SQL Functions Used:
    - SUM(), AVG(): Aggregates values for comparison.
    - Window Functions: SUM() OVER() for total calculations.
===============================================================================
*/
-- Which categories contribute the most to overall sales?
WITH category_sales AS (
    SELECT
        p.category,
        SUM(CAST(f.sales_amount AS BIGINT)) AS total_sales
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON p.product_key = f.product_key
    GROUP BY p.category
)
SELECT
    category,
    total_sales,
    SUM(total_sales) OVER () AS overall_sales,
    ROUND((CAST(total_sales AS FLOAT) / SUM(total_sales) OVER ()) * 100, 2) AS percentage_of_total
FROM category_sales
ORDER BY total_sales DESC;