/* =============================================================================
   09 READ-ONLY LOGIN (OPTIONAL)
   Creates the genbi_reader login (semantic schema only).
   Change the placeholder password before running. Never commit a real password.
   Skip this step if you do not need a separate read-only login.
   ============================================================================= */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'genbi_reader')
    CREATE LOGIN genbi_reader WITH PASSWORD = '<REPLACE_WITH_A_STRONG_PASSWORD>';
GO

USE DataWarehouse;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'genbi_reader')
    CREATE USER genbi_reader FOR LOGIN genbi_reader;
GO
GRANT SELECT ON SCHEMA::semantic TO genbi_reader;
DENY  SELECT ON SCHEMA::gold     TO genbi_reader;
DENY  SELECT ON SCHEMA::silver   TO genbi_reader;
DENY  SELECT ON SCHEMA::bronze   TO genbi_reader;
GO
