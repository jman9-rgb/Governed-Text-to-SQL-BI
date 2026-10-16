/* =============================================================================
   23 FINAL SETTINGS
   Sets the daily AI call limit to your free-tier quota.
   Change 20 if your quota is different.
   ============================================================================= */
USE DataWarehouse;
GO

UPDATE genbi.guardrail SET limit_value = 20 WHERE guardrail_name = N'daily_ai_calls';
SELECT guardrail_name, limit_value FROM genbi.guardrail WHERE guardrail_name = N'daily_ai_calls';   -- expect 20
GO
