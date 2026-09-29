-- =====================================================================
-- 07_performance_tuning.sql
-- Measure -> index -> measure again, using EXPLAIN (ANALYZE, BUFFERS).
--
-- HOW TO USE: run this file, then copy the "Execution Time" and the scan
-- type (Seq Scan / Index Scan) BEFORE and AFTER into the README table.
-- Numbers depend on your machine; report your own, never someone else's.
-- PostgreSQL does not auto-index foreign-key columns. That is one of the
-- most common causes of slow joins, and this file demonstrates it.
-- =====================================================================

-- Start from a clean slate so the run is repeatable.
DROP INDEX IF EXISTS core.idx_orders_purchase_ts;
DROP INDEX IF EXISTS core.idx_order_reviews_order_id;
DROP INDEX IF EXISTS core.idx_order_items_seller_id;
DROP INDEX IF EXISTS core.idx_orders_customer_id;
ANALYZE;

-- Pick a busy seller to use in the demo (top seller by line items).
SELECT seller_id AS demo_seller
FROM core.order_items
GROUP BY seller_id
ORDER BY COUNT(*) DESC
LIMIT 1
\gset

\echo '================ BEFORE INDEXES ================'

\echo '--- Query 1: monthly review score for a 3-month purchase window ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE_TRUNC('month', o.purchase_ts) AS month,
       COUNT(*)                           AS reviewed_orders,
       ROUND(AVG(r.review_score), 2)      AS avg_score
FROM core.orders o
JOIN core.order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.purchase_ts >= '2018-01-01' AND o.purchase_ts < '2018-04-01'
GROUP BY 1;

\echo '--- Query 2: revenue and order count for one seller ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(DISTINCT i.order_id) AS orders,
       SUM(i.price)               AS revenue
FROM core.order_items i
WHERE i.seller_id = :'demo_seller';

\echo '--- Query 3: all orders for a customer (customer_id foreign key) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.purchase_ts, o.order_status
FROM core.orders o
WHERE o.customer_id = (SELECT customer_id FROM core.customers ORDER BY customer_id LIMIT 1 OFFSET 500);

-- ---------------------------------------------------------------------
-- Add the indexes
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_purchase_ts     ON core.orders (purchase_ts);
CREATE INDEX idx_order_reviews_order_id ON core.order_reviews (order_id);  -- PK leads with review_id, so it cannot serve this join
CREATE INDEX idx_order_items_seller_id  ON core.order_items (seller_id);
CREATE INDEX idx_orders_customer_id     ON core.orders (customer_id);
ANALYZE;

\echo '================ AFTER INDEXES ================'

\echo '--- Query 1 (after) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE_TRUNC('month', o.purchase_ts) AS month,
       COUNT(*)                           AS reviewed_orders,
       ROUND(AVG(r.review_score), 2)      AS avg_score
FROM core.orders o
JOIN core.order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.purchase_ts >= '2018-01-01' AND o.purchase_ts < '2018-04-01'
GROUP BY 1;

\echo '--- Query 2 (after) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(DISTINCT i.order_id) AS orders,
       SUM(i.price)               AS revenue
FROM core.order_items i
WHERE i.seller_id = :'demo_seller';

\echo '--- Query 3 (after) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.purchase_ts, o.order_status
FROM core.orders o
WHERE o.customer_id = (SELECT customer_id FROM core.customers ORDER BY customer_id LIMIT 1 OFFSET 500);

-- Indexes now present:
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'core' AND indexname LIKE 'idx_%'
ORDER BY tablename, indexname;
