/* =============================================================================
   03 LOAD BRONZE
   Loads the six CSV files into the bronze tables.
   EDIT the path below: the folder that contains source_crm\ and source_erp\ (end it with a backslash).
   SQL Server itself must be able to read that folder.
   ============================================================================= */
USE DataWarehouse;
GO

DECLARE @path NVARCHAR(500) = N'C:\path\to\your\datasets\';   -- <== EDIT THIS LINE
EXEC bronze.load_bronze @base_path = @path;
GO

-- Check: every table should have rows
SELECT 'bronze.crm_cust_info' AS tbl, COUNT(*) AS n FROM bronze.crm_cust_info
UNION ALL SELECT 'bronze.crm_prd_info', COUNT(*) FROM bronze.crm_prd_info
UNION ALL SELECT 'bronze.crm_sales_details', COUNT(*) FROM bronze.crm_sales_details
UNION ALL SELECT 'bronze.erp_loc_a101', COUNT(*) FROM bronze.erp_loc_a101
UNION ALL SELECT 'bronze.erp_cust_az12', COUNT(*) FROM bronze.erp_cust_az12
UNION ALL SELECT 'bronze.erp_px_cat_g1v2', COUNT(*) FROM bronze.erp_px_cat_g1v2;
