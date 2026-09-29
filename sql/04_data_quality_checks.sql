-- =====================================================================
-- 04_data_quality_checks.sql
-- Runs data-quality checks and logs each result to dq.issues.
-- Section A checks RAW staging data (duplicates, missing keys).
-- Section B checks CLEAN core data (logic, completeness, consistency).
-- A check with rows_affected = 0 is still logged: it proves the check ran.
-- =====================================================================

TRUNCATE dq.issues RESTART IDENTITY;

-- =====================  A. RAW (staging)  ===========================

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'duplicate_order_id', 'staging.orders', 'HIGH',
       COUNT(*) - COUNT(DISTINCT order_id), COUNT(*),
       'Rows sharing an order_id with another row'
FROM staging.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'duplicate_customer_id', 'staging.customers', 'HIGH',
       COUNT(*) - COUNT(DISTINCT customer_id), COUNT(*),
       'Rows sharing a customer_id with another row'
FROM staging.customers;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'duplicate_review_id', 'staging.order_reviews', 'MEDIUM',
       COUNT(*) - COUNT(DISTINCT review_id), COUNT(*),
       'review_id reused across rows (Olist reuses IDs across orders), so review_id alone is not a key'
FROM staging.order_reviews;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'duplicate_review_id_order_id', 'staging.order_reviews', 'MEDIUM',
       COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT review_id, order_id FROM staging.order_reviews) x),
       COUNT(*),
       'Exact (review_id, order_id) duplicates removed during core build'
FROM staging.order_reviews;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'duplicate_payment_key', 'staging.order_payments', 'HIGH',
       COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, payment_sequential FROM staging.order_payments) x),
       COUNT(*),
       'Duplicate (order_id, payment_sequential) rows'
FROM staging.order_payments;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'missing_purchase_timestamp', 'staging.orders', 'HIGH',
       COUNT(*) FILTER (WHERE NULLIF(order_purchase_timestamp, '') IS NULL), COUNT(*),
       'Orders without a purchase timestamp (dropped in core)'
FROM staging.orders;

-- Referential integrity in the raw data (0 is the expected outcome; if the
-- core build succeeded these must be 0, so they double as proof of integrity).
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orphan_order_items_no_order', 'staging.order_items', 'HIGH',
       COUNT(*) FILTER (WHERE o.order_id IS NULL), COUNT(*),
       'Line items whose order_id is not in orders'
FROM staging.order_items i
LEFT JOIN (SELECT DISTINCT order_id FROM staging.orders) o ON o.order_id = i.order_id;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orphan_payments_no_order', 'staging.order_payments', 'HIGH',
       COUNT(*) FILTER (WHERE o.order_id IS NULL), COUNT(*),
       'Payments whose order_id is not in orders'
FROM staging.order_payments p
LEFT JOIN (SELECT DISTINCT order_id FROM staging.orders) o ON o.order_id = p.order_id;

-- =====================  B. CLEAN (core)  ============================

-- Orders vs items / payments
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orders_without_items', 'core.orders', 'MEDIUM',
       COUNT(*) FILTER (WHERE i.order_id IS NULL), COUNT(*),
       'Orders with zero line items (often cancelled/unavailable, but check the status mix)'
FROM core.orders o
LEFT JOIN (SELECT DISTINCT order_id FROM core.order_items) i ON i.order_id = o.order_id;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orders_without_payments', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE p.order_id IS NULL), COUNT(*),
       'Orders with no payment record at all'
FROM core.orders o
LEFT JOIN (SELECT DISTINCT order_id FROM core.order_payments) p ON p.order_id = o.order_id;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'payments_without_items', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE p.order_id IS NOT NULL AND i.order_id IS NULL), COUNT(*),
       'Orders that were paid for but have no line items'
FROM core.orders o
LEFT JOIN (SELECT DISTINCT order_id FROM core.order_items)    i ON i.order_id = o.order_id
LEFT JOIN (SELECT DISTINCT order_id FROM core.order_payments) p ON p.order_id = o.order_id;

-- Status vs timestamp consistency
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'delivered_without_delivery_date', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE order_status = 'delivered' AND delivered_customer_ts IS NULL),
       COUNT(*) FILTER (WHERE order_status = 'delivered'),
       'Status = delivered but no customer delivery timestamp'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'delivery_date_but_not_delivered', 'core.orders', 'MEDIUM',
       COUNT(*) FILTER (WHERE order_status <> 'delivered' AND delivered_customer_ts IS NOT NULL),
       COUNT(*) FILTER (WHERE order_status <> 'delivered'),
       'Has a customer delivery timestamp but status is not delivered'
FROM core.orders;

-- Impossible date sequences
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'delivered_before_purchase', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE delivered_customer_ts < purchase_ts),
       COUNT(*) FILTER (WHERE delivered_customer_ts IS NOT NULL),
       'Customer delivery timestamp earlier than purchase timestamp'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'approved_before_purchase', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE approved_ts < purchase_ts),
       COUNT(*) FILTER (WHERE approved_ts IS NOT NULL),
       'Approval timestamp earlier than purchase timestamp'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'carrier_before_purchase', 'core.orders', 'HIGH',
       COUNT(*) FILTER (WHERE delivered_carrier_ts < purchase_ts),
       COUNT(*) FILTER (WHERE delivered_carrier_ts IS NOT NULL),
       'Handed to carrier before the purchase happened'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'delivered_before_carrier_pickup', 'core.orders', 'MEDIUM',
       COUNT(*) FILTER (WHERE delivered_customer_ts < delivered_carrier_ts),
       COUNT(*) FILTER (WHERE delivered_customer_ts IS NOT NULL AND delivered_carrier_ts IS NOT NULL),
       'Delivered to customer before the carrier picked it up'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'estimate_before_purchase', 'core.orders', 'MEDIUM',
       COUNT(*) FILTER (WHERE estimated_delivery_ts < purchase_ts),
       COUNT(*) FILTER (WHERE estimated_delivery_ts IS NOT NULL),
       'Estimated delivery date earlier than purchase date'
FROM core.orders;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'shipping_limit_before_purchase', 'core.order_items', 'MEDIUM',
       COUNT(*) FILTER (WHERE i.shipping_limit_ts < o.purchase_ts),
       COUNT(*),
       'Seller shipping deadline earlier than order purchase time'
FROM core.order_items i
JOIN core.orders o ON o.order_id = i.order_id;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'review_answer_before_creation', 'core.order_reviews', 'LOW',
       COUNT(*) FILTER (WHERE answer_ts < creation_ts),
       COUNT(*),
       'Review answered before it was created'
FROM core.order_reviews;

-- Amounts
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'zero_value_payments', 'core.order_payments', 'MEDIUM',
       COUNT(*) FILTER (WHERE payment_value = 0), COUNT(*),
       'Payment rows with value 0'
FROM core.order_payments;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'payment_type_not_defined', 'core.order_payments', 'MEDIUM',
       COUNT(*) FILTER (WHERE payment_type = 'not_defined'), COUNT(*),
       'Payments with an undefined payment type'
FROM core.order_payments;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'zero_price_items', 'core.order_items', 'MEDIUM',
       COUNT(*) FILTER (WHERE price = 0), COUNT(*),
       'Line items with price 0'
FROM core.order_items;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'zero_installments_on_card', 'core.order_payments', 'LOW',
       COUNT(*) FILTER (WHERE payment_type = 'credit_card' AND payment_installments = 0),
       COUNT(*) FILTER (WHERE payment_type = 'credit_card'),
       'Credit-card payments with 0 installments (should be at least 1)'
FROM core.order_payments;

-- Reference data
INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'products_missing_category', 'core.products', 'LOW',
       COUNT(*) FILTER (WHERE category_name IS NULL), COUNT(*),
       'Products with no category'
FROM core.products;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'category_without_translation', 'core.products', 'LOW',
       COUNT(*) FILTER (WHERE p.category_name IS NOT NULL AND t.category_name IS NULL),
       COUNT(*) FILTER (WHERE p.category_name IS NOT NULL),
       'Products whose category has no English translation row'
FROM core.products p
LEFT JOIN core.category_translation t ON t.category_name = p.category_name;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orders_with_multiple_reviews', 'core.orders', 'INFO',
       COUNT(*) FILTER (WHERE r.n > 1), COUNT(*),
       'Orders carrying more than one review (analytics average them per order)'
FROM core.orders o
LEFT JOIN (SELECT order_id, COUNT(*) AS n FROM core.order_reviews GROUP BY order_id) r ON r.order_id = o.order_id;

INSERT INTO dq.issues (check_name, table_name, severity, rows_affected, rows_checked, description)
SELECT 'orders_without_reviews', 'core.orders', 'INFO',
       COUNT(*) FILTER (WHERE r.order_id IS NULL), COUNT(*),
       'Orders with no review (normal; not every customer reviews)'
FROM core.orders o
LEFT JOIN (SELECT DISTINCT order_id FROM core.order_reviews) r ON r.order_id = o.order_id;

-- ---------------- Report ---------------------------------------------
SELECT check_id, severity, table_name, check_name, rows_affected, rows_checked, pct_affected
FROM dq.issues
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
         rows_affected DESC;
