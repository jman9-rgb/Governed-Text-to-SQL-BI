/* =============================================================================
   REPORT QUERIES
   Example queries on the report views (the views themselves are built in sql/build/07_gold_reports.sql).
   ============================================================================= */
USE DataWarehouse;
GO

-- Customer segmentation counts (moved here from section 16: ONE definition = this view)
SELECT
    customer_segment,
    COUNT(customer_key) AS total_customers
FROM gold.report_customers
GROUP BY customer_segment
ORDER BY total_customers DESC;
GO
