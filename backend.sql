-- Setup
CREATE WAREHOUSE IF NOT EXISTS WH_LOAD WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60;
CREATE DATABASE IF NOT EXISTS HEALTHCARE;
CREATE SCHEMA IF NOT EXISTS HEALTHCARE.MEDICARE;
USE SCHEMA HEALTHCARE.MEDICARE;

-- Table (columns match the Part D Prescribers by Provider & Drug schema)
CREATE OR REPLACE TABLE PARTD_PRESCRIBERS_BY_DRUG (
    PRSCRBR_NPI            NUMBER,
    PRSCRBR_LAST_ORG_NAME  STRING,
    PRSCRBR_FIRST_NAME     STRING,
    PRSCRBR_CITY           STRING,
    PRSCRBR_STATE_ABRVTN   STRING,
    PRSCRBR_STATE_FIPS     STRING,
    PRSCRBR_TYPE           STRING,
    PRSCRBR_TYPE_SRC       STRING,
    BRND_NAME              STRING,
    GNRC_NAME              STRING,
    TOT_CLMS               NUMBER,
    TOT_30DAY_FILLS        FLOAT,
    TOT_DAY_SUPLY          NUMBER,
    TOT_DRUG_CST           FLOAT,
    TOT_BENES              NUMBER,
    GE65_SPRSN_FLAG        STRING,
    GE65_TOT_CLMS          NUMBER,
    GE65_TOT_30DAY_FILLS   FLOAT,
    GE65_TOT_DRUG_CST      FLOAT,
    GE65_TOT_DAY_SUPLY     NUMBER,
    GE65_BENE_SExpand_FLAG STRING,
    GE65_TOT_BENES         NUMBER
);

-- File format
CREATE OR REPLACE FILE FORMAT CSV_FF
    TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    SKIP_HEADER = 1 NULL_IF = ('', 'NA') EMPTY_FIELD_AS_NULL = TRUE;

-- Internal stage
CREATE OR REPLACE STAGE PARTD_STAGE FILE_FORMAT = CSV_FF;


--------------------------------------------
--------------------------------------------


USE ROLE ACCOUNTADMIN;


CREATE OR REPLACE STORAGE INTEGRATION s3_medicare_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = ''
  STORAGE_ALLOWED_LOCATIONS = ('s3://examplebucket/MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv');




-- Grab the values Snowflake generates so you can trust it in AWS:
DESC INTEGRATION s3_medicare_int;


-- modification

USE ROLE ACCOUNTADMIN;

ALTER STORAGE INTEGRATION s3_medicare_int
  SET STORAGE_ALLOWED_LOCATIONS = ('s3://examplebucket/');


--step 4

USE SCHEMA HEALTHCARE.MEDICARE;

CREATE OR REPLACE FILE FORMAT CSV_FF
  TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  SKIP_HEADER = 1 NULL_IF = ('', 'NA') EMPTY_FIELD_AS_NULL = TRUE;

CREATE OR REPLACE STAGE partd_s3_stage
  STORAGE_INTEGRATION = s3_medicare_int
  URL = 's3://examplebucket/'
  FILE_FORMAT = CSV_FF;


-------step 5

LIST @partd_s3_stage;



------step 6 - infer schema and create table 

CREATE OR REPLACE TABLE PARTD_PROVIDER_DRUG
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@partd_s3_stage',
        FILE_FORMAT => 'CSV_FF'
      )
    )
  );


------step 7 - load table /SQL compilation error: match_by_column_name option is not supported for file format CSV without PARSE_HEADER = TRUE


COPY INTO PARTD_PROVIDER_DRUG
  FROM @partd_s3_stage/MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv
  FILE_FORMAT = CSV_FF
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  ON_ERROR = 'CONTINUE';

------partial redo--------

CREATE OR REPLACE FILE FORMAT CSV_FF_HEADER
  TYPE = CSV
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  PARSE_HEADER = TRUE
  NULL_IF = ('', 'NA')
  EMPTY_FIELD_AS_NULL = TRUE;


  CREATE OR REPLACE TABLE PARTD_PROVIDER_DRUG
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@partd_s3_stage',
        FILE_FORMAT => 'CSV_FF_HEADER'
      )
    )
  );



  COPY INTO PARTD_PROVIDER_DRUG
  FROM @partd_s3_stage/MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv
  FILE_FORMAT = CSV_FF_HEADER
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  ON_ERROR = 'CONTINUE';


  ------status = load_failed debug------

  SELECT *
FROM TABLE(VALIDATE(PARTD_PROVIDER_DRUG, JOB_ID => '_last'));



DESCRIBE TABLE PARTD_PROVIDER_DRUG;


-- What columns does the table actually have, and how many? 62
DESCRIBE TABLE PARTD_PROVIDER_DRUG;

-- What does INFER_SCHEMA see in the file right now?
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@partd_s3_stage',
    FILE_FORMAT => 'CSV_FF_HEADER',
    FILES => 'MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv'
  )


  ------------------------------------
  -----------final fix----------------



  CREATE OR REPLACE TABLE PARTD_PROVIDER_DRUG
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@partd_s3_stage',
        FILE_FORMAT => 'CSV_FF_HEADER',
        FILES => 'MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv'
      )
    )
  );


  DESCRIBE TABLE PARTD_PROVIDER_DRUG;


  COPY INTO PARTD_PROVIDER_DRUG
  FROM @partd_s3_stage/MUP_DPR_RY24_P04_V10_DY19_NPIBN.csv
  FILE_FORMAT = CSV_FF_HEADER
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  ON_ERROR = 'CONTINUE';




  -----sanity check----------

SELECT COUNT(*) FROM PARTD_PROVIDER_DRUG;   -- should echo 25,401,870
DESCRIBE TABLE PARTD_PROVIDER_DRUG;          -- gives the exact column names
SELECT * FROM PARTD_PROVIDER_DRUG LIMIT 20;  -- eyeball real values



-------roll up tables-----


USE SCHEMA HEALTHCARE.MEDICARE;

-- By state
CREATE OR REPLACE TABLE RPT_BY_STATE AS
SELECT
  "Prscrbr_State_Abrvtn"          AS STATE,
  COUNT(DISTINCT "Prscrbr_NPI")   AS PRESCRIBERS,
  SUM("Tot_Clms")                 AS TOTAL_CLAIMS,
  SUM("Tot_Drug_Cst")             AS TOTAL_COST,
  SUM("Tot_Benes")                AS TOTAL_BENES
FROM PARTD_PROVIDER_DRUG
WHERE "Prscrbr_State_Abrvtn" IS NOT NULL
GROUP BY 1;

-- By drug (generic)
CREATE OR REPLACE TABLE RPT_BY_DRUG AS
SELECT
  "Gnrc_Name"                     AS DRUG,
  SUM("Tot_Clms")                 AS TOTAL_CLAIMS,
  SUM("Tot_Drug_Cst")             AS TOTAL_COST,
  SUM("Tot_Benes")                AS TOTAL_BENES,
  COUNT(DISTINCT "Prscrbr_NPI")   AS PRESCRIBERS
FROM PARTD_PROVIDER_DRUG
WHERE "Gnrc_Name" IS NOT NULL
GROUP BY 1;

-- By specialty
CREATE OR REPLACE TABLE RPT_BY_SPECIALTY AS
SELECT
  "Prscrbr_Type"                  AS SPECIALTY,
  COUNT(DISTINCT "Prscrbr_NPI")   AS PRESCRIBERS,
  SUM("Tot_Clms")                 AS TOTAL_CLAIMS,
  SUM("Tot_Drug_Cst")             AS TOTAL_COST
FROM PARTD_PROVIDER_DRUG
WHERE "Prscrbr_Type" IS NOT NULL
GROUP BY 1;

-- By state + drug (for the drill-down filter)
CREATE OR REPLACE TABLE RPT_BY_STATE_DRUG AS
SELECT
  "Prscrbr_State_Abrvtn"          AS STATE,
  "Gnrc_Name"                     AS DRUG,
  SUM("Tot_Clms")                 AS TOTAL_CLAIMS,
  SUM("Tot_Drug_Cst")             AS TOTAL_COST
FROM PARTD_PROVIDER_DRUG
WHERE "Prscrbr_State_Abrvtn" IS NOT NULL AND "Gnrc_Name" IS NOT NULL
GROUP BY 1, 2;




