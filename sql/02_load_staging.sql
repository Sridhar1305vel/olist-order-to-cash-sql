-- =====================================================================
-- 02_load_staging.sql
-- Loads the raw Olist CSVs into staging.* with client-side \copy.
-- Inside the Docker container the CSV folder is mounted at /data.
-- (If running psql on your own machine, either create a /data symlink
--  to your CSV folder or edit the paths below.)
-- =====================================================================

\echo 'Loading staging tables...'

\copy staging.customers            FROM '/data/olist_customers_dataset.csv'          WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.geolocation          FROM '/data/olist_geolocation_dataset.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.orders               FROM '/data/olist_orders_dataset.csv'             WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.order_items          FROM '/data/olist_order_items_dataset.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.order_payments       FROM '/data/olist_order_payments_dataset.csv'     WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.order_reviews        FROM '/data/olist_order_reviews_dataset.csv'      WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.products             FROM '/data/olist_products_dataset.csv'           WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.sellers              FROM '/data/olist_sellers_dataset.csv'            WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy staging.category_translation FROM '/data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Row counts: compare with the file line counts to prove nothing was lost.
SELECT 'customers' AS staging_table, COUNT(*) AS rows_loaded FROM staging.customers
UNION ALL SELECT 'geolocation',          COUNT(*) FROM staging.geolocation
UNION ALL SELECT 'orders',               COUNT(*) FROM staging.orders
UNION ALL SELECT 'order_items',          COUNT(*) FROM staging.order_items
UNION ALL SELECT 'order_payments',       COUNT(*) FROM staging.order_payments
UNION ALL SELECT 'order_reviews',        COUNT(*) FROM staging.order_reviews
UNION ALL SELECT 'products',             COUNT(*) FROM staging.products
UNION ALL SELECT 'sellers',              COUNT(*) FROM staging.sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM staging.category_translation
ORDER BY 1;
