-- =============================================
-- 1. Drop existing master table if exists
-- =============================================
IF OBJECT_ID('dbo.certificate_master', 'U') IS NOT NULL
    DROP TABLE dbo.certificate_master;
GO

-- =============================================
-- 2. Create master table
-- =============================================
CREATE TABLE dbo.certificate_master (
    RecordID INT IDENTITY(1,1) PRIMARY KEY,
    LMK_KEY NVARCHAR(255),
    PROPERTY_TYPE NVARCHAR(255),
    BUILT_FORM NVARCHAR(255),
    INSPECTION_DATE DATE,
    LODGEMENT_DATE DATE,
    CURRENT_ENERGY_RATING NVARCHAR(10),
    POTENTIAL_ENERGY_RATING NVARCHAR(10),
    CURRENT_ENERGY_EFFICIENCY INT,
    POTENTIAL_ENERGY_EFFICIENCY INT,
    ENERGY_CONSUMPTION_CURRENT FLOAT,
    ENERGY_CONSUMPTION_POTENTIAL FLOAT,
    CO2_EMISSIONS_CURRENT FLOAT,
    CO2_EMISSIONS_POTENTIAL FLOAT,
    LOCAL_AUTHORITY NVARCHAR(255),
    POSTCODE NVARCHAR(20),
    ADDRESS1 NVARCHAR(255),
    ADDRESS2 NVARCHAR(255),
    ADDRESS3 NVARCHAR(255),
    QualityFlag NVARCHAR(50)
);
GO

-- =============================================
-- 3. Import and clean data from certificates$
-- =============================================
INSERT INTO dbo.certificate_master (
    LMK_KEY, PROPERTY_TYPE, BUILT_FORM,
    INSPECTION_DATE, LODGEMENT_DATE,
    CURRENT_ENERGY_RATING, POTENTIAL_ENERGY_RATING,
    CURRENT_ENERGY_EFFICIENCY, POTENTIAL_ENERGY_EFFICIENCY,
    ENERGY_CONSUMPTION_CURRENT, ENERGY_CONSUMPTION_POTENTIAL,
    CO2_EMISSIONS_CURRENT, CO2_EMISSIONS_POTENTIAL,
    LOCAL_AUTHORITY, POSTCODE,
    ADDRESS1, ADDRESS2, ADDRESS3,
    QualityFlag
)
SELECT
    LMK_KEY,
    PROPERTY_TYPE,
    BUILT_FORM,
    TRY_CONVERT(date, INSPECTION_DATE),
    TRY_CONVERT(date, LODGEMENT_DATE),
    UPPER(CURRENT_ENERGY_RATING),
    UPPER(POTENTIAL_ENERGY_RATING),
    TRY_CONVERT(int, CURRENT_ENERGY_EFFICIENCY),
    TRY_CONVERT(int, POTENTIAL_ENERGY_EFFICIENCY),
    TRY_CONVERT(float, ENERGY_CONSUMPTION_CURRENT),
    TRY_CONVERT(float, ENERGY_CONSUMPTION_POTENTIAL),
    TRY_CONVERT(float, CO2_EMISSIONS_CURRENT),
    TRY_CONVERT(float, CO2_EMISSIONS_POTENTIAL),
    LOCAL_AUTHORITY,
    POSTCODE,
    ADDRESS1,
    ADDRESS2,
    ADDRESS3,
    CASE
        WHEN TRY_CONVERT(float, CO2_EMISSIONS_CURRENT) < 0 THEN 'Invalid CO2'
        WHEN TRY_CONVERT(int, CURRENT_ENERGY_EFFICIENCY) IS NULL THEN 'Missing Efficiency'
        ELSE 'OK'
    END AS QualityFlag
FROM dbo.[certificates$];
GO

-- =============================================
-- 4. Remove duplicates (keep latest LODGEMENT_DATE)
-- =============================================
;WITH CTE_Duplicates AS (
    SELECT *,
           ROW_NUMBER() OVER(PARTITION BY LMK_KEY ORDER BY LODGEMENT_DATE DESC) AS rn
    FROM dbo.certificate_master
)
DELETE FROM CTE_Duplicates
WHERE rn > 1;
GO

-- =============================================
-- 5. Clean negative or invalid values
-- =============================================
UPDATE dbo.certificate_master
SET CO2_EMISSIONS_CURRENT = NULL
WHERE CO2_EMISSIONS_CURRENT < 0;

UPDATE dbo.certificate_master
SET CO2_EMISSIONS_POTENTIAL = NULL
WHERE CO2_EMISSIONS_POTENTIAL < 0;

UPDATE dbo.certificate_master
SET CURRENT_ENERGY_EFFICIENCY = NULL
WHERE CURRENT_ENERGY_EFFICIENCY < 0;

UPDATE dbo.certificate_master
SET POTENTIAL_ENERGY_EFFICIENCY = NULL
WHERE POTENTIAL_ENERGY_EFFICIENCY < 0;
GO

-- =============================================
-- 6. Standardize PROPERTY_TYPE
-- =============================================
UPDATE dbo.certificate_master
SET PROPERTY_TYPE = UPPER(PROPERTY_TYPE);
GO

-- =============================================
-- 7. Create Views
-- =============================================

-- Energy Rating Distribution
CREATE OR ALTER VIEW dbo.vw_EnergyRatingDistribution AS
SELECT 
    CURRENT_ENERGY_RATING,
    COUNT(*) AS PropertyCount,
    AVG(CURRENT_ENERGY_EFFICIENCY) AS AvgEfficiency,
    AVG(CO2_EMISSIONS_CURRENT) AS AvgCO2
FROM dbo.certificate_master
GROUP BY CURRENT_ENERGY_RATING;
GO

-- Local Authority Summary
CREATE OR ALTER VIEW dbo.vw_LocalAuthoritySummary AS
SELECT 
    LOCAL_AUTHORITY,
    COUNT(*) AS TotalProperties,
    AVG(CURRENT_ENERGY_EFFICIENCY) AS AvgEfficiency,
    AVG(POTENTIAL_ENERGY_EFFICIENCY) AS AvgPotentialEfficiency,
    AVG(CO2_EMISSIONS_CURRENT) AS AvgCO2Current,
    AVG(CO2_EMISSIONS_POTENTIAL) AS AvgCO2Potential
FROM dbo.certificate_master
GROUP BY LOCAL_AUTHORITY;
GO

-- =============================================
-- 8. Create Stored Procedures
-- =============================================

-- Property count by Energy Rating and Local Authority
CREATE OR ALTER PROCEDURE dbo.usp_GetPropertyCount
    @LocalAuthority NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocalAuthority IS NULL
    BEGIN
        SELECT LOCAL_AUTHORITY,
               CURRENT_ENERGY_RATING,
               COUNT(*) AS PropertyCount
        FROM dbo.certificate_master
        GROUP BY LOCAL_AUTHORITY, CURRENT_ENERGY_RATING
        ORDER BY LOCAL_AUTHORITY, CURRENT_ENERGY_RATING;
    END
    ELSE
    BEGIN
        SELECT LOCAL_AUTHORITY,
               CURRENT_ENERGY_RATING,
               COUNT(*) AS PropertyCount
        FROM dbo.certificate_master
        WHERE LOCAL_AUTHORITY = @LocalAuthority
        GROUP BY LOCAL_AUTHORITY, CURRENT_ENERGY_RATING
        ORDER BY LOCAL_AUTHORITY, CURRENT_ENERGY_RATING;
    END
END;
GO

-- KPI Summary
CREATE OR ALTER PROCEDURE dbo.usp_GetKPIs
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        COUNT(*) AS TotalProperties,
        AVG(CO2_EMISSIONS_CURRENT) AS AvgCO2,
        AVG(CURRENT_ENERGY_EFFICIENCY) AS AvgEnergyEfficiency,
        SUM(CASE WHEN CURRENT_ENERGY_RATING IN ('D','E','F','G') THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS PercentNeedsImprovement
    FROM dbo.certificate_master;
END;
GO

-- =============================================
-- 9. Quick Data Checks
-- =============================================
-- Total Rows
SELECT COUNT(*) AS TotalCleanRows FROM dbo.certificate_master;

-- Null counts per column
DECLARE @table NVARCHAR(200) = 'certificate_master';
DECLARE @schema NVARCHAR(200) = 'dbo';
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + '
SELECT ''' + COLUMN_NAME + ''' AS ColumnName,
       SUM(CASE WHEN [' + COLUMN_NAME + '] IS NULL THEN 1 ELSE 0 END) AS NullCount,
       COUNT(*) AS TotalRows
FROM [' + @schema + '].[' + @table + '];'
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = @schema AND TABLE_NAME = @table;

EXEC(@sql);
GO
