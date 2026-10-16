Put the source CSV files here (not committed to git):

- data/source_crm/cust_info.csv, prd_info.csv, sales_details.csv
- data/source_erp/LOC_A101.csv, CUST_AZ12.csv, PX_CAT_G1V2.csv

Then pass this folder to `EXEC bronze.load_bronze @base_path = N'<full path>\\';`
