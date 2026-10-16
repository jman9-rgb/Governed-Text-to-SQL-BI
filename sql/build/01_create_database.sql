/* =============================================================================
   01 CREATE DATABASE
   Creates the DataWarehouse database and the bronze, silver, gold and semantic schemas.
   WARNING: this script DROPS an existing DataWarehouse database first. Never run it on data you want to keep.
   ============================================================================= */
USE master;
GO

-- Drop and recreate the 'DataWarehouse' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
    ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouse;
END;
GO

-- Create the 'DataWarehouse' database
CREATE DATABASE DataWarehouse;
GO

-- Keep the database open between queries. With AUTO_CLOSE ON the first query after an idle period
-- has to wait for the database to restart, which caused timeouts in the evaluation (questions #3 and #19).
ALTER DATABASE DataWarehouse SET AUTO_CLOSE OFF;
GO

USE DataWarehouse;
GO

-- Create Schemas
CREATE SCHEMA bronze;
GO

CREATE SCHEMA silver;
GO

CREATE SCHEMA gold;
GO

-- The semantic schema is created here too, so everything is in ONE database
CREATE SCHEMA semantic;
GO
