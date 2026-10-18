# Data

The source data files are **not included** in this repo. They are not committed, on purpose
(see `.gitignore`).

## Source and credit

The data comes from the free "SQL Ultimate Course" materials by **Data With Baraa** (YouTube).

Course materials (download page):
https://academy.datawithbaraa.com/l/digital_download/930511/sql-course-materials

Terms stated by the creator: the materials are for learning and personal use only.
Commercial use, redistribution or resale of the files is not permitted, and public work
should credit "Data With Baraa". For that reason the data files are not in this repo.
Download them from the link above.

Credit: Data With Baraa. The bronze, silver and gold warehouse follows his course.
The semantic layer, governance tables, agents, safety layers, evaluation, tests and the
Streamlit app are my own additions.

## Where to put the files

Create two folders next to this README and copy the CSV files in:

    data/source_crm/    cust_info.csv, prd_info.csv, sales_details.csv
    data/source_erp/    LOC_A101.csv, CUST_AZ12.csv, PX_CAT_G1V2.csv

## Load them

SQL Server must be able to read the folder. The path must end with a single backslash and
the folder must contain `source_crm` and `source_erp`:

    EXEC bronze.load_bronze @base_path = N'C:\full\path\to\data\';

Then continue with `sql/RUN_ORDER.md`.
