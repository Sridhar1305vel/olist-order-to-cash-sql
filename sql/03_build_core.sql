-- =====================================================================
-- 03_build_core.sql
-- Transforms staging (raw TEXT) into core (typed + constrained).
-- Every removal or alteration is written to dq.cleaning_log so the
-- cleaning is auditable, not silent.
--
-- DEDUPLICATION RULE: only rows identical in EVERY column are collapsed.
-- Two rows that share a key but differ in content (e.g. two different
-- amounts for the same payment) are NOT silently discarded: the primary
-- key then rejects the load and the conflict surfaces loudly. In a
-- reconciliation project, quietly dropping a row can hide real money.
-- =====================================================================

-- ---------- customers ------------------------------------------------
INSERT INTO core.customers
SELECT customer_id,
       customer_unique_id,
       NULLIF(TRIM(customer_zip_code_prefix), ''),
       NULLIF(TRIM(customer_city), ''),
       UPPER(NULLIF(TRIM(customer_state), ''))
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state) AS rn
    FROM staging.customers s
    WHERE customer_id IS NOT NULL AND customer_unique_id IS NOT NULL
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows', 'customers',
       (SELECT COUNT(*) FROM staging.customers),
       (SELECT COUNT(*) FROM core.customers),
       'Removed fully identical duplicate rows / rows with NULL keys';

-- ---------- sellers --------------------------------------------------
INSERT INTO core.sellers
SELECT seller_id,
       NULLIF(TRIM(seller_zip_code_prefix), ''),
       NULLIF(TRIM(seller_city), ''),
       UPPER(NULLIF(TRIM(seller_state), ''))
FROM (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY seller_id, seller_zip_code_prefix, seller_city, seller_state) AS rn
    FROM staging.sellers s
    WHERE seller_id IS NOT NULL
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows', 'sellers',
       (SELECT COUNT(*) FROM staging.sellers),
       (SELECT COUNT(*) FROM core.sellers),
       'Removed fully identical duplicate rows / rows with NULL keys';

-- ---------- products -------------------------------------------------
INSERT INTO core.products
SELECT product_id,
       NULLIF(TRIM(product_category_name), ''),
       NULLIF(product_name_lenght, '')::NUMERIC::INT,
       NULLIF(product_description_lenght, '')::NUMERIC::INT,
       NULLIF(product_photos_qty, '')::NUMERIC::INT,
       NULLIF(product_weight_g, '')::NUMERIC,
       NULLIF(product_length_cm, '')::NUMERIC,
       NULLIF(product_height_cm, '')::NUMERIC,
       NULLIF(product_width_cm, '')::NUMERIC
FROM (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm) AS rn
    FROM staging.products s
    WHERE product_id IS NOT NULL
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows', 'products',
       (SELECT COUNT(*) FROM staging.products),
       (SELECT COUNT(*) FROM core.products),
       'Removed fully identical duplicate rows / rows with NULL keys';

-- ---------- category translation ------------------------------------
INSERT INTO core.category_translation
SELECT DISTINCT TRIM(product_category_name), TRIM(product_category_name_english)
FROM staging.category_translation
WHERE NULLIF(TRIM(product_category_name), '') IS NOT NULL;

-- ---------- orders ---------------------------------------------------
INSERT INTO core.orders
SELECT order_id,
       customer_id,
       LOWER(TRIM(order_status)),
       order_purchase_timestamp::TIMESTAMP,
       NULLIF(order_approved_at, '')::TIMESTAMP,
       NULLIF(order_delivered_carrier_date, '')::TIMESTAMP,
       NULLIF(order_delivered_customer_date, '')::TIMESTAMP,
       NULLIF(order_estimated_delivery_date, '')::TIMESTAMP
FROM (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date) AS rn
    FROM staging.orders s
    WHERE order_id IS NOT NULL
      AND NULLIF(order_purchase_timestamp, '') IS NOT NULL
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows, require purchase timestamp', 'orders',
       (SELECT COUNT(*) FROM staging.orders),
       (SELECT COUNT(*) FROM core.orders),
       'Removed fully identical duplicates / rows without purchase timestamp';

-- ---------- order_items ---------------------------------------------
INSERT INTO core.order_items
SELECT order_id,
       order_item_id::INT,
       product_id,
       seller_id,
       NULLIF(shipping_limit_date, '')::TIMESTAMP,
       price::NUMERIC(10,2),
       freight_value::NUMERIC(10,2)
FROM (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value) AS rn
    FROM staging.order_items s
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows', 'order_items',
       (SELECT COUNT(*) FROM staging.order_items),
       (SELECT COUNT(*) FROM core.order_items),
       'Removed fully identical duplicate line items';

-- ---------- order_payments ------------------------------------------
INSERT INTO core.order_payments
SELECT order_id,
       payment_sequential::INT,
       LOWER(TRIM(payment_type)),
       payment_installments::INT,
       payment_value::NUMERIC(10,2)
FROM (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY order_id, payment_sequential, payment_type, payment_installments, payment_value) AS rn
    FROM staging.order_payments s
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe identical rows', 'order_payments',
       (SELECT COUNT(*) FROM staging.order_payments),
       (SELECT COUNT(*) FROM core.order_payments),
       'Removed fully identical duplicate payment rows';

-- ---------- order_reviews -------------------------------------------
-- Keep the most recently answered row per (review_id, order_id).
INSERT INTO core.order_reviews
SELECT review_id,
       order_id,
       review_score::INT,
       NULLIF(review_creation_date, '')::TIMESTAMP,
       NULLIF(review_answer_timestamp, '')::TIMESTAMP
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY review_id, order_id
                              ORDER BY NULLIF(review_answer_timestamp, '')::TIMESTAMP DESC NULLS LAST) AS rn
    FROM staging.order_reviews s
) d
WHERE rn = 1;

INSERT INTO dq.cleaning_log (step, table_name, rows_in, rows_out, note)
SELECT 'dedupe on (review_id, order_id), keep latest answer', 'order_reviews',
       (SELECT COUNT(*) FROM staging.order_reviews),
       (SELECT COUNT(*) FROM core.order_reviews),
       'Removed duplicate review rows';

ANALYZE;

SELECT step, table_name, rows_in, rows_out, rows_removed FROM dq.cleaning_log ORDER BY table_name;
