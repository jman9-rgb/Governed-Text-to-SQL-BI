/* =============================================================================
   05 LOAD SILVER
   Cleans and loads Bronze into the silver tables.
   ============================================================================= */
USE DataWarehouse;
GO

EXEC silver.load_silver;
GO

-- Check: every table should have rows (silver customers <= bronze customers because of de-duplication)
SELECT 'silver.crm_cust_info' AS tbl, COUNT(*) AS n FROM silver.crm_cust_info
UNION ALL SELECT 'silver.crm_prd_info', COUNT(*) FROM silver.crm_prd_info
UNION ALL SELECT 'silver.crm_sales_details', COUNT(*) FROM silver.crm_sales_details
UNION ALL SELECT 'silver.erp_loc_a101', COUNT(*) FROM silver.erp_loc_a101
UNION ALL SELECT 'silver.erp_cust_az12', COUNT(*) FROM silver.erp_cust_az12
UNION ALL SELECT 'silver.erp_px_cat_g1v2', COUNT(*) FROM silver.erp_px_cat_g1v2;
