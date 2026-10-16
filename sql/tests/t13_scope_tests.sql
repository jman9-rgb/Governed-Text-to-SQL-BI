/* =============================================================================
   TESTS: STEP 13 CURATED SCOPE
   Each agent can read only its own views (checked with real impersonation).
   Prints a PASS / FAIL table, then one summary line.
     RULE  must always pass.
     SEED  true right after this step; a later step may change it legitimately.
     DATA  depends on the source data you loaded; DIFF only means your data differs.
   ============================================================================= */
USE DataWarehouse;
GO
SET NOCOUNT ON;
DROP TABLE IF EXISTS #t;
CREATE TABLE #t (
    n        INT IDENTITY(1,1),
    id       VARCHAR(12)   NOT NULL,
    kind     VARCHAR(4)    NOT NULL,
    test     NVARCHAR(200) NOT NULL,
    expected NVARCHAR(200) NOT NULL,
    actual   NVARCHAR(200) NULL,
    ok AS (CASE WHEN expected = ISNULL(actual, N'<NULL>') THEN 1 ELSE 0 END)
);
GO

EXEC genbi.sp_test_scope;          -- impersonates every agent and tries every object (its own two result sets are shown first)
DECLARE @run DATETIME2 = (SELECT MAX(run_at) FROM genbi.scope_test_result);

INSERT #t (id, kind, test, expected, actual) VALUES ('S1', 'SEED', N'number of agents', N'3', CAST((SELECT COUNT(*) FROM genbi.agent) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('S2', 'SEED', N'views in scope per agent', N'customer_agent=2; product_agent=2; sales_agent=3', CAST((SELECT STRING_AGG(CAST(agent_name + '=' + CAST(n AS VARCHAR(5)) AS NVARCHAR(100)), '; ') WITHIN GROUP (ORDER BY agent_name) FROM (SELECT agent_name, COUNT(*) AS n FROM genbi.agent_view_access GROUP BY agent_name) x) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('S3', 'RULE', N'scope test: checks that were run', N'1', CAST((SELECT CASE WHEN (SELECT COUNT(*) FROM genbi.scope_test_result WHERE run_at = @run) > 0 THEN 1 ELSE 0 END) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('S4', 'RULE', N'scope test: checks that failed', N'0', CAST((SELECT COUNT(*) FROM genbi.scope_test_result WHERE run_at = @run AND passed = 0) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('S5', 'RULE', N'agents whose database user is missing', N'0', CAST((SELECT COUNT(*) FROM genbi.agent a WHERE NOT EXISTS (SELECT 1 FROM sys.database_principals p WHERE p.name = a.db_user)) AS NVARCHAR(200)));
INSERT #t (id, kind, test, expected, actual) VALUES ('S6', 'RULE', N'agents with an empty prompt', N'0', CAST((SELECT COUNT(*) FROM genbi.agent a WHERE NOT EXISTS (SELECT 1 FROM genbi.vw_agent_prompt p WHERE p.agent_name = a.agent_name)) AS NVARCHAR(200)));

SELECT id, kind, test, expected, actual,
       CASE WHEN ok = 1 THEN 'PASS' WHEN kind = 'RULE' THEN 'FAIL' ELSE 'DIFF' END AS result
FROM #t ORDER BY n;

SELECT COUNT(*) AS tests, SUM(ok) AS passed,
       SUM(CASE WHEN ok = 0 AND kind = 'RULE' THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN ok = 0 AND kind <> 'RULE' THEN 1 ELSE 0 END) AS diffs
FROM #t;

IF EXISTS (SELECT 1 FROM #t WHERE ok = 0 AND kind = 'RULE')
    SELECT 'FAILED RULE TEST' AS problem, id, test, expected, actual FROM #t WHERE ok = 0 AND kind = 'RULE';

IF EXISTS (SELECT 1 FROM #t WHERE ok = 0 AND kind = 'RULE')
    RAISERROR(N'At least one RULE test failed: see the FAIL rows above.', 11, 1);
GO

/* ---------- Reference (not a test): size of each agent prompt, and prompt lines that mention a view the agent does NOT have ---------- */
SELECT agent_name, COUNT(*) AS lines, SUM(LEN(line_text)) AS characters
FROM genbi.vw_agent_prompt GROUP BY agent_name ORDER BY agent_name;

SELECT p.agent_name, v.view_name AS view_not_in_scope, COUNT(*) AS lines
FROM genbi.vw_agent_prompt p
CROSS JOIN genbi.view_context v
WHERE NOT EXISTS (SELECT 1 FROM genbi.agent_view_access av WHERE av.agent_name = p.agent_name AND av.view_name = v.view_name)
  AND p.line_text LIKE '%' + v.view_name + '%'
GROUP BY p.agent_name, v.view_name ORDER BY p.agent_name, v.view_name;
GO
