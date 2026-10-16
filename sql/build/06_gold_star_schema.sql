/* =============================================================================
   06 GOLD LAYER
   Gold star schema stored as indexed tables, loaded from Silver by gold.sp_load_gold.
   This file loads Silver into Gold at its end (EXEC gold.sp_load_gold). Re-run that EXEC whenever Silver changes.
   ============================================================================= */
USE DataWarehouse;
GO

/* ---------- Gold tables ---------- */
/*
Gold is a star schema stored as indexed physical tables: gold.dim_customers, gold.dim_products, gold.fact_sales.
It started as three views; every query re-ran the Silver joins, which made the semantic layer and the golden-question
validator very slow, so the views became tables. All Gold logic lives in ONE place: gold.sp_load_gold (below).
customer_key / product_key come from ROW_NUMBER() and are re-numbered on every load, which is fine as long as nothing
stores these keys outside the database.
Safe to re-run: old views are dropped only if they still exist; tables are created only if missing; the load procedure
empties and reloads them. If Silver changes later, run:  EXEC gold.sp_load_gold;
*/

-- Remove the old Gold views (only if they still exist in this database)
IF OBJECT_ID('gold.fact_sales',    'V') IS NOT NULL DROP VIEW gold.fact_sales;
IF OBJECT_ID('gold.dim_customers', 'V') IS NOT NULL DROP VIEW gold.dim_customers;
IF OBJECT_ID('gold.dim_products',  'V') IS NOT NULL DROP VIEW gold.dim_products;
GO

-- Tables (structure only)
IF OBJECT_ID('gold.dim_customers', 'U') IS NULL
CREATE TABLE gold.dim_customers (
    customer_key     INT           NOT NULL,
    customer_id      INT           NOT NULL,
    customer_number  NVARCHAR(50)  NULL,
    first_name       NVARCHAR(50)  NULL,
    last_name        NVARCHAR(50)  NULL,
    country          NVARCHAR(50)  NULL,
    marital_status   NVARCHAR(20)  NULL,
    gender           NVARCHAR(20)  NULL,
    birthdate        DATE          NULL,
    create_date      DATE          NULL,
    CONSTRAINT PK_gold_dim_customers PRIMARY KEY CLUSTERED (customer_key)
);
GO

IF OBJECT_ID('gold.dim_products', 'U') IS NULL
CREATE TABLE gold.dim_products (
    product_key      INT           NOT NULL,
    product_id       INT           NOT NULL,
    product_number   NVARCHAR(50)  NULL,
    product_name     NVARCHAR(200) NULL,
    category_id      NVARCHAR(50)  NULL,
    category         NVARCHAR(100) NULL,
    subcategory      NVARCHAR(100) NULL,
    maintenance      NVARCHAR(100) NULL,
    cost             INT           NULL,
    product_line     NVARCHAR(50)  NULL,
    start_date       DATE          NULL,
    CONSTRAINT PK_gold_dim_products PRIMARY KEY CLUSTERED (product_key)
);
GO

IF OBJECT_ID('gold.fact_sales', 'U') IS NULL
CREATE TABLE gold.fact_sales (
    order_number   NVARCHAR(50)   NOT NULL,
    product_key    INT            NULL,
    customer_key   INT            NULL,
    order_date     DATE           NULL,
    shipping_date  DATE           NULL,
    due_date       DATE           NULL,
    sales_amount   DECIMAL(18,2)  NULL,
    quantity       INT            NULL,
    price          DECIMAL(18,2)  NULL
);
GO

-- Indexes on the fact table (safe to re-run)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_sales_customer_key' AND object_id = OBJECT_ID('gold.fact_sales'))
    CREATE NONCLUSTERED INDEX IX_fact_sales_customer_key ON gold.fact_sales (customer_key);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_sales_product_key' AND object_id = OBJECT_ID('gold.fact_sales'))
    CREATE NONCLUSTERED INDEX IX_fact_sales_product_key  ON gold.fact_sales (product_key);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_sales_order_number' AND object_id = OBJECT_ID('gold.fact_sales'))
    CREATE NONCLUSTERED INDEX IX_fact_sales_order_number ON gold.fact_sales (order_number);
GO

-- The ONE place where the Gold logic lives
CREATE OR ALTER PROCEDURE gold.sp_load_gold
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_sales;
        TRUNCATE TABLE gold.dim_customers;
        TRUNCATE TABLE gold.dim_products;

        INSERT INTO gold.dim_customers (customer_key, customer_id, customer_number, first_name, last_name,
                                        country, marital_status, gender, birthdate, create_date)
        SELECT ROW_NUMBER() OVER (ORDER BY ci.cst_id), ci.cst_id, ci.cst_key, ci.cst_firstname, ci.cst_lastname,
               la.cntry, ci.cst_marital_status,
               CASE WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr ELSE COALESCE(ca.gen, 'n/a') END,
               ca.bdate, ci.cst_create_date
        FROM silver.crm_cust_info ci
        LEFT JOIN silver.erp_cust_az12 ca ON ci.cst_key = ca.cid
        LEFT JOIN silver.erp_loc_a101  la ON ci.cst_key = la.cid;

        INSERT INTO gold.dim_products (product_key, product_id, product_number, product_name, category_id,
                                       category, subcategory, maintenance, cost, product_line, start_date)
        SELECT ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_key), pn.prd_id, pn.prd_key, pn.prd_nm,
               pn.cat_id, pc.cat, pc.subcat, pc.maintenance, pn.prd_cost, pn.prd_line, pn.prd_start_dt
        FROM silver.crm_prd_info pn
        LEFT JOIN silver.erp_px_cat_g1v2 pc ON pn.cat_id = pc.id
        WHERE pn.prd_end_dt IS NULL;

        INSERT INTO gold.fact_sales (order_number, product_key, customer_key, order_date, shipping_date,
                                     due_date, sales_amount, quantity, price)
        SELECT sd.sls_ord_num, pr.product_key, cu.customer_key, sd.sls_order_dt, sd.sls_ship_dt,
               sd.sls_due_dt, sd.sls_sales, sd.sls_quantity, sd.sls_price
        FROM silver.crm_sales_details sd
        LEFT JOIN gold.dim_products  pr ON sd.sls_prd_key = pr.product_number
        LEFT JOIN gold.dim_customers cu ON sd.sls_cust_id = cu.customer_id;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

-- Load Gold now
EXEC gold.sp_load_gold;
GO
