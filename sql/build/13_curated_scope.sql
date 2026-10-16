/* =============================================================================
   13 CURATED SCOPE
   Agents, their views, real database permissions, and the per-agent prompt view.
   ============================================================================= */
USE DataWarehouse;
SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('genbi') ORDER BY name;



/*
===============================================================================
PHASE 4 : CURATED SCOPE  (limited table access)
Each AI "agent" is a database role that can SELECT only the semantic views it needs.
SQL Server enforces it, not the prompt.  Everything else (bronze, silver, gold, genbi)
is explicitly denied.  The AI also only receives the context of its own views.

Agents (by business domain, not by person):
  sales_agent     vw_sales, vw_monthly_sales, vw_data_range
  customer_agent  vw_customer_metrics, vw_data_range
  product_agent   vw_product_metrics, vw_data_range
Run as dbo / sysadmin in SSMS.
===============================================================================
*/
USE DataWarehouse;
GO

-- ---------------------------------------------------------------------------
-- 4.1  Two small patches to the earlier context
-- ---------------------------------------------------------------------------
-- general context should not name a specific view (an agent may not have it)
UPDATE genbi.business_context
SET context_value = N'Monthly data uses the first day of the month as the month value.',
    updated_at = SYSDATETIME()
WHERE context_area = 'Time' AND context_key = 'month_format';

-- tell the AI what to do when a note mentions a view it was not given
IF NOT EXISTS (SELECT 1 FROM genbi.business_context WHERE context_area = 'Scope' AND context_key = 'agent_scope')
INSERT INTO genbi.business_context (context_area, context_key, context_value, priority)
VALUES ('Scope', 'agent_scope',
        N'You can only use the views listed for you. If a note mentions a view that is not listed, you cannot use it: say that the question needs a different agent or cannot be answered here.', 1);
GO

-- ---------------------------------------------------------------------------
-- 4.2  Agents and their access (edit these two tables to change the scope)
-- ---------------------------------------------------------------------------
IF OBJECT_ID('genbi.agent', 'U') IS NULL
CREATE TABLE genbi.agent (
    agent_name   SYSNAME       NOT NULL PRIMARY KEY,
    db_user      SYSNAME       NOT NULL UNIQUE,      -- database user the agent runs as
    description  NVARCHAR(300) NULL,
    is_active    BIT           NOT NULL DEFAULT 1
);
GO

-- view_name must exist in genbi.view_context: a view with no business context cannot be given to an agent
IF OBJECT_ID('genbi.agent_view_access', 'U') IS NULL
CREATE TABLE genbi.agent_view_access (
    agent_name  SYSNAME       NOT NULL REFERENCES genbi.agent (agent_name),
    view_name   SYSNAME       NOT NULL REFERENCES genbi.view_context (view_name),
    reason      NVARCHAR(300) NULL,
    PRIMARY KEY (agent_name, view_name)
);
GO

MERGE genbi.agent AS t
USING (VALUES
 ('sales_agent',    'agent_sales',    N'Sales, orders, quantity and monthly trends; cuts by country, gender, category and product line'),
 ('customer_agent', 'agent_customer', N'Customer segments, age groups, recency, lifespan and customer value'),
 ('product_agent',  'agent_product',  N'Product ranking, product segments and product performance')
) AS s(agent_name, db_user, description)
ON t.agent_name = s.agent_name
WHEN NOT MATCHED THEN INSERT (agent_name, db_user, description) VALUES (s.agent_name, s.db_user, s.description);
GO

MERGE genbi.agent_view_access AS t
USING (VALUES
 ('sales_agent',    'vw_sales',            N'Order-line detail and cuts by country, gender, category'),
 ('sales_agent',    'vw_monthly_sales',    N'Monthly trends'),
 ('sales_agent',    'vw_data_range',       N'Meaning of today, this month, last month'),
 ('customer_agent', 'vw_customer_metrics', N'One row per customer with KPIs and segments'),
 ('customer_agent', 'vw_data_range',       N'Meaning of today, this month, last month'),
 ('product_agent',  'vw_product_metrics',  N'One row per product with KPIs and segments'),
 ('product_agent',  'vw_data_range',       N'Meaning of today, this month, last month')
) AS s(agent_name, view_name, reason)
ON t.agent_name = s.agent_name AND t.view_name = s.view_name
WHEN NOT MATCHED THEN INSERT (agent_name, view_name, reason) VALUES (s.agent_name, s.view_name, s.reason);
GO

-- ---------------------------------------------------------------------------
-- 4.3  Turn the access table into real permissions (safe to re-run any time)
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE genbi.sp_apply_scope
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agent SYSNAME, @user SYSNAME, @role SYSNAME, @obj SYSNAME, @in BIT, @sql NVARCHAR(MAX);

    -- a) role and user per agent, plus an explicit DENY on everything outside the semantic layer
    DECLARE cur_a CURSOR LOCAL FAST_FORWARD FOR
        SELECT agent_name, db_user FROM genbi.agent WHERE is_active = 1;
    OPEN cur_a; FETCH NEXT FROM cur_a INTO @agent, @user;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @role = N'role_' + @agent;
        IF DATABASE_PRINCIPAL_ID(@role) IS NULL
        BEGIN
            SET @sql = N'CREATE ROLE ' + QUOTENAME(@role);
            EXEC (@sql);
        END
        IF DATABASE_PRINCIPAL_ID(@user) IS NULL
        BEGIN
            SET @sql = N'CREATE USER ' + QUOTENAME(@user) + N' WITHOUT LOGIN';
            EXEC (@sql);
        END
        IF ISNULL(IS_ROLEMEMBER(@role, @user), 0) = 0
        BEGIN
            SET @sql = N'ALTER ROLE ' + QUOTENAME(@role) + N' ADD MEMBER ' + QUOTENAME(@user);
            EXEC (@sql);
        END

        SET @sql = N'DENY SELECT ON SCHEMA::bronze TO ' + QUOTENAME(@role) + N'; '
                 + N'DENY SELECT ON SCHEMA::silver TO ' + QUOTENAME(@role) + N'; '
                 + N'DENY SELECT ON SCHEMA::gold TO '   + QUOTENAME(@role) + N'; '
                 + N'DENY SELECT ON SCHEMA::genbi TO '  + QUOTENAME(@role) + N';';
        EXEC (@sql);

        -- only if the app login exists (it is created in the Python phase)
        IF DATABASE_PRINCIPAL_ID(N'genbi_app') IS NOT NULL
        BEGIN
            SET @sql = N'GRANT IMPERSONATE ON USER::' + QUOTENAME(@user) + N' TO genbi_app';
            EXEC (@sql);
        END

        FETCH NEXT FROM cur_a INTO @agent, @user;
    END
    CLOSE cur_a; DEALLOCATE cur_a;

    -- b) GRANT SELECT on views in the agent's scope, REVOKE on every other semantic object
    DECLARE cur_g CURSOR LOCAL FAST_FORWARD FOR
        SELECT a.agent_name, o.name,
               CASE WHEN av.view_name IS NOT NULL THEN 1 ELSE 0 END
        FROM genbi.agent a
        CROSS JOIN (SELECT name FROM sys.objects
                    WHERE schema_id = SCHEMA_ID('semantic') AND type IN ('V', 'U')) o
        LEFT JOIN genbi.agent_view_access av
               ON av.agent_name = a.agent_name
              AND av.view_name COLLATE DATABASE_DEFAULT = o.name COLLATE DATABASE_DEFAULT
        WHERE a.is_active = 1;
    OPEN cur_g; FETCH NEXT FROM cur_g INTO @agent, @obj, @in;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @role = N'role_' + @agent;
        IF @in = 1
            SET @sql = N'GRANT SELECT ON OBJECT::semantic.' + QUOTENAME(@obj) + N' TO ' + QUOTENAME(@role);
        ELSE
            SET @sql = N'REVOKE SELECT ON OBJECT::semantic.' + QUOTENAME(@obj) + N' FROM ' + QUOTENAME(@role);
        EXEC (@sql);
        FETCH NEXT FROM cur_g INTO @agent, @obj, @in;
    END
    CLOSE cur_g; DEALLOCATE cur_g;
END;
GO

EXEC genbi.sp_apply_scope;
GO

-- ---------------------------------------------------------------------------
-- 4.4  Audit view: who can read what
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW genbi.vw_scope_audit
AS
SELECT r.name AS role_name, 'OBJECT' AS permission_level,
       OBJECT_SCHEMA_NAME(p.major_id) + '.' + OBJECT_NAME(p.major_id) AS target,
       p.permission_name, p.state_desc
FROM sys.database_permissions p
JOIN sys.database_principals r ON r.principal_id = p.grantee_principal_id
WHERE r.name LIKE 'role[_]%' AND p.class = 1 AND OBJECT_SCHEMA_NAME(p.major_id) = 'semantic'
UNION ALL
SELECT r.name, 'SCHEMA', SCHEMA_NAME(p.major_id), p.permission_name, p.state_desc
FROM sys.database_permissions p
JOIN sys.database_principals r ON r.principal_id = p.grantee_principal_id
WHERE r.name LIKE 'role[_]%' AND p.class = 3;
GO

-- ---------------------------------------------------------------------------
-- 4.5  Automated scope test: impersonate every agent and try to read every object
--      Expected ALLOWED only for the agent's own views; everything else must fail
--      with error 229 (permission denied).
-- ---------------------------------------------------------------------------
IF OBJECT_ID('genbi.scope_test_result', 'U') IS NULL
CREATE TABLE genbi.scope_test_result (
    result_id     INT IDENTITY(1,1) PRIMARY KEY,
    run_at        DATETIME2     NOT NULL,
    agent_name    SYSNAME       NOT NULL,
    object_name   NVARCHAR(300) NOT NULL,
    expected      NVARCHAR(10)  NOT NULL,
    actual        NVARCHAR(10)  NOT NULL,
    error_number  INT           NULL,
    passed        BIT           NOT NULL
);
GO

CREATE OR ALTER PROCEDURE genbi.sp_test_scope
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run DATETIME2 = SYSDATETIME();
    DECLARE @agent SYSNAME, @user SYSNAME, @obj NVARCHAR(300), @short SYSNAME, @is_sem BIT;
    DECLARE @sql NVARCHAR(MAX), @expected NVARCHAR(10), @actual NVARCHAR(10), @err INT;

    DECLARE @objects TABLE (object_name NVARCHAR(300), short_name SYSNAME NULL, is_semantic BIT);
    INSERT @objects (object_name, short_name, is_semantic)
    SELECT N'semantic.' + QUOTENAME(name), name, 1
    FROM sys.objects WHERE schema_id = SCHEMA_ID('semantic') AND type IN ('V', 'U');
    INSERT @objects (object_name, short_name, is_semantic) VALUES
        (N'gold.fact_sales', NULL, 0), (N'gold.dim_customers', NULL, 0),
        (N'silver.crm_cust_info', NULL, 0), (N'bronze.crm_sales_details', NULL, 0),
        (N'genbi.business_glossary', NULL, 0);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT a.agent_name, a.db_user, o.object_name, o.short_name, o.is_semantic
        FROM genbi.agent a CROSS JOIN @objects o
        WHERE a.is_active = 1
        ORDER BY a.agent_name, o.object_name;
    OPEN cur; FETCH NEXT FROM cur INTO @agent, @user, @obj, @short, @is_sem;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @expected = CASE WHEN @is_sem = 1 AND EXISTS
                                  (SELECT 1 FROM genbi.agent_view_access av
                                   WHERE av.agent_name = @agent AND av.view_name = @short)
                             THEN N'ALLOWED' ELSE N'DENIED' END;
        SET @actual = N'ALLOWED';
        SET @err = NULL;
        BEGIN TRY
            EXECUTE AS USER = @user;
            SET @sql = N'DECLARE @x INT; SELECT TOP 1 @x = 1 FROM ' + @obj + N';';
            EXEC sys.sp_executesql @sql;
            REVERT;
        END TRY
        BEGIN CATCH
            SET @err = ERROR_NUMBER();
            REVERT;
            SET @actual = N'DENIED';
        END CATCH;

        INSERT genbi.scope_test_result (run_at, agent_name, object_name, expected, actual, error_number, passed)
        VALUES (@run, @agent, @obj, @expected, @actual, @err,
                CASE WHEN @expected = @actual AND (@actual = N'ALLOWED' OR @err = 229) THEN 1 ELSE 0 END);

        FETCH NEXT FROM cur INTO @agent, @user, @obj, @short, @is_sem;
    END
    CLOSE cur; DEALLOCATE cur;

    -- result set 1: summary per agent
    SELECT agent_name, COUNT(*) AS tests, SUM(CAST(passed AS INT)) AS passed,
           SUM(CASE WHEN actual = 'ALLOWED' THEN 1 ELSE 0 END) AS objects_readable
    FROM genbi.scope_test_result WHERE run_at = @run
    GROUP BY agent_name ORDER BY agent_name;
    -- result set 2: failures only (should be empty)
    SELECT agent_name, object_name, expected, actual, error_number
    FROM genbi.scope_test_result WHERE run_at = @run AND passed = 0;
END;
GO

-- ---------------------------------------------------------------------------
-- 4.6  What each agent gets in its prompt: only the context of ITS views
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW genbi.vw_agent_prompt
AS
WITH acc AS (
    SELECT av.agent_name, av.view_name
    FROM genbi.agent_view_access av
    JOIN genbi.agent a ON a.agent_name = av.agent_name AND a.is_active = 1
),
g AS (
    SELECT gl.term, gl.maps_to_type, gl.maps_to_metric_code, gl.maps_to_view, gl.maps_to_column,
           gl.filter_expression, gl.meaning, gl.default_assumption, gl.needs_clarification,
           COALESCE(md.preferred_view, gl.maps_to_view) AS scope_view
    FROM genbi.business_glossary gl
    LEFT JOIN genbi.metric_definition md ON md.metric_code = gl.maps_to_metric_code
    WHERE gl.is_active = 1
),
gs AS (
    SELECT acc.agent_name, g.* FROM g JOIN acc ON acc.view_name = g.scope_view
    UNION ALL
    SELECT a.agent_name, g.* FROM g CROSS JOIN genbi.agent a WHERE g.scope_view IS NULL AND a.is_active = 1
)
-- 1) general business context
SELECT a.agent_name, 1 AS sec, CAST(bc.priority AS BIGINT) AS ord,
       CAST(bc.context_area + '.' + bc.context_key AS NVARCHAR(200)) AS item,
       CAST('[' + bc.context_area + '] ' + bc.context_key + ': ' + bc.context_value AS NVARCHAR(MAX)) AS line_text
FROM genbi.agent a CROSS JOIN genbi.business_context bc
WHERE a.is_active = 1 AND bc.is_active = 1
UNION ALL
-- 2) the views this agent may use
SELECT acc.agent_name, 2, 0, CAST(vc.view_name AS NVARCHAR(200)),
       CAST('semantic.' + vc.view_name + ' | grain: ' + vc.grain + ' | purpose: ' + vc.business_purpose
            + ' | use when: ' + vc.use_when + ' | not for: ' + vc.not_for AS NVARCHAR(MAX))
FROM acc JOIN genbi.view_context vc ON vc.view_name = acc.view_name
UNION ALL
-- 3) the columns of those views
SELECT acc.agent_name, 3, CAST(mc.catalog_id AS BIGINT), CAST(mc.view_name + '.' + mc.column_name AS NVARCHAR(200)),
       CAST('semantic.' + mc.view_name + '.' + mc.column_name + ' [' + mc.column_role + '] ' + mc.definition
            + ISNULL(' | calc: ' + mc.calculation, '')
            + CASE mc.is_additive WHEN 1 THEN ' | additive' WHEN 0 THEN ' | NOT additive' ELSE '' END
            + ISNULL(' | rule: ' + mc.aggregation_rule, '')
            + CASE WHEN mc.contains_personal_data = 1 THEN ' | personal data' ELSE '' END AS NVARCHAR(MAX))
FROM acc JOIN genbi.metric_catalog mc ON mc.view_name = acc.view_name AND mc.status = 'Approved'
UNION ALL
-- 4) trusted KPIs whose preferred view is in scope
SELECT acc.agent_name, 4, 0, CAST(md.metric_code AS NVARCHAR(200)),
       CAST('TRUSTED METRIC ' + md.metric_code + ' (' + md.metric_name + '): ' + md.business_definition
            + ' | use semantic.' + md.preferred_view + ' | expression: ' + md.sql_expression
            + ISNULL(' | time: ' + md.time_rule, '') + ISNULL(' | caveat: ' + md.caveat, '') AS NVARCHAR(MAX))
FROM acc JOIN genbi.metric_definition md ON md.preferred_view = acc.view_name AND md.status = 'Approved'
UNION ALL
-- 5a) glossary: synonyms of the same clear metric on one line
SELECT gs.agent_name, 5, 0, CAST(gs.maps_to_metric_code AS NVARCHAR(200)),
       CAST('GLOSSARY: "' + STRING_AGG(CAST(gs.term AS NVARCHAR(MAX)), '", "') WITHIN GROUP (ORDER BY gs.term)
            + '" all mean the trusted metric ' + gs.maps_to_metric_code AS NVARCHAR(MAX))
FROM gs
WHERE gs.maps_to_type = 'Metric' AND gs.needs_clarification = 0
GROUP BY gs.agent_name, gs.maps_to_metric_code
UNION ALL
-- 5b) glossary: every other term on its own line
SELECT gs.agent_name, 5, 1, CAST(gs.term AS NVARCHAR(200)),
       CAST('GLOSSARY: "' + gs.term + '" -> ' + gs.maps_to_type
            + ISNULL(' metric ' + gs.maps_to_metric_code, '')
            + ISNULL(' semantic.' + gs.maps_to_view + '.' + gs.maps_to_column, '')
            + ISNULL(' | filter: ' + gs.filter_expression, '')
            + ' | ' + gs.meaning
            + ISNULL(' | assumption: ' + gs.default_assumption, '')
            + CASE WHEN gs.needs_clarification = 1 THEN ' | ask the user or state the assumption' ELSE '' END AS NVARCHAR(MAX))
FROM gs
WHERE NOT (gs.maps_to_type = 'Metric' AND gs.needs_clarification = 0);
GO
