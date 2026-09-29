-- =====================================================================
-- 06_analytics.sql
-- Business analytics on the clean data. Revenue = SUM(item price),
-- delivered orders only, freight excluded. Currency: BRL.
-- Techniques: CTEs, window functions (LAG, NTILE, RANK, running totals),
-- conditional aggregation (FILTER), date arithmetic.
-- NOTE: the first and last months of the Olist data are incomplete, so
-- read growth rates at the edges with care.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1. Monthly revenue, month-over-month growth, running total
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT DATE_TRUNC('month', o.purchase_ts)::DATE AS month,
           COUNT(DISTINCT o.order_id)               AS orders,
           SUM(i.price)                             AS revenue
    FROM core.orders o
    JOIN core.order_items i ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
)
SELECT month,
       orders,
       ROUND(revenue, 2)                                              AS revenue_brl,
       ROUND(100.0 * (revenue - LAG(revenue) OVER w)
             / NULLIF(LAG(revenue) OVER w, 0), 1)                     AS mom_growth_pct,
       ROUND(SUM(revenue) OVER (ORDER BY month), 2)                   AS running_revenue_brl,
       ROUND(revenue / orders, 2)                                     AS avg_order_value_brl
FROM monthly
WINDOW w AS (ORDER BY month)
ORDER BY month;

-- ---------------------------------------------------------------------
-- A2. Top 10 product categories by revenue, with share and rank
-- ---------------------------------------------------------------------
WITH cat_rev AS (
    SELECT COALESCE(t.category_name_english, p.category_name, 'uncategorised') AS category,
           SUM(i.price)                  AS revenue,
           COUNT(DISTINCT i.order_id)    AS orders
    FROM core.order_items i
    JOIN core.orders o    ON o.order_id = i.order_id AND o.order_status = 'delivered'
    JOIN core.products p  ON p.product_id = i.product_id
    LEFT JOIN core.category_translation t ON t.category_name = p.category_name
    GROUP BY 1
)
SELECT RANK() OVER (ORDER BY revenue DESC)                     AS rank,
       category,
       orders,
       ROUND(revenue, 2)                                       AS revenue_brl,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)        AS share_pct
FROM cat_rev
ORDER BY revenue DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- A3. RFM customer segmentation (delivered orders)
-- Recency and Monetary use NTILE(5). Frequency uses fixed buckets
-- (1 / 2 / 3+) because most marketplace customers buy only once, which
-- would make NTILE on frequency meaningless.
-- Customers are identified by customer_unique_id (customer_id changes per order).
-- ---------------------------------------------------------------------
WITH order_value AS (
    SELECT order_id, SUM(payment_value) AS order_value
    FROM core.order_payments
    GROUP BY order_id
),
as_of AS (
    SELECT (MAX(purchase_ts)::DATE + 1) AS as_of_date FROM core.orders
),
rfm_base AS (
    SELECT c.customer_unique_id,
           (SELECT as_of_date FROM as_of) - MAX(o.purchase_ts)::DATE AS recency_days,
           COUNT(DISTINCT o.order_id)                                 AS frequency,
           SUM(ov.order_value)                                        AS monetary
    FROM core.orders o
    JOIN core.customers c   ON c.customer_id = o.customer_id
    JOIN order_value ov     ON ov.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- 5 = most recent
           NTILE(5) OVER (ORDER BY monetary)          AS m_score,   -- 5 = highest spend
           CASE WHEN frequency >= 3 THEN 3 ELSE frequency::INT END AS f_score
    FROM rfm_base
),
segmented AS (
    SELECT *,
           CASE
               WHEN f_score >= 2 AND r_score >= 3 THEN 'Loyal repeat'
               WHEN r_score >= 4 AND m_score >= 4 THEN 'New high-value'
               WHEN r_score >= 4                  THEN 'New / recent'
               WHEN r_score <= 2 AND m_score >= 4 THEN 'At-risk high-value'
               WHEN r_score <= 2                  THEN 'Lapsed'
               ELSE                                    'Mid-lifecycle'
           END AS segment
    FROM scored
)
SELECT segment,
       COUNT(*)                                             AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)   AS pct_customers,
       ROUND(AVG(monetary), 2)                              AS avg_spend_brl,
       ROUND(SUM(monetary), 2)                              AS total_spend_brl,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_of_spend
FROM segmented
GROUP BY segment
ORDER BY total_spend_brl DESC;

-- ---------------------------------------------------------------------
-- A4. Cohort retention: % of each first-purchase-month cohort that buys
-- again 1..6 months later (cohorts under 100 customers are hidden).
-- ---------------------------------------------------------------------
WITH purchases AS (
    SELECT DISTINCT c.customer_unique_id,
           DATE_TRUNC('month', o.purchase_ts)::DATE AS order_month
    FROM core.orders o
    JOIN core.customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
first_month AS (
    SELECT customer_unique_id, MIN(order_month) AS cohort_month
    FROM purchases
    GROUP BY customer_unique_id
),
activity AS (
    SELECT f.cohort_month,
           p.customer_unique_id,
           (EXTRACT(YEAR  FROM p.order_month) - EXTRACT(YEAR  FROM f.cohort_month)) * 12
         + (EXTRACT(MONTH FROM p.order_month) - EXTRACT(MONTH FROM f.cohort_month)) AS month_index
    FROM purchases p
    JOIN first_month f USING (customer_unique_id)
)
SELECT cohort_month,
       COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0)  AS cohort_size,
       ROUND(100.0 * COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 1)
             / NULLIF(COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0), 0), 2) AS m1_pct,
       ROUND(100.0 * COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 2)
             / NULLIF(COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0), 0), 2) AS m2_pct,
       ROUND(100.0 * COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 3)
             / NULLIF(COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0), 0), 2) AS m3_pct,
       ROUND(100.0 * COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 6)
             / NULLIF(COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0), 0), 2) AS m6_pct
FROM activity
GROUP BY cohort_month
HAVING COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_index = 0) >= 100
ORDER BY cohort_month;

-- ---------------------------------------------------------------------
-- A5. Seller concentration (Pareto): how many sellers make 80% of revenue?
-- ---------------------------------------------------------------------
WITH seller_rev AS (
    SELECT i.seller_id, SUM(i.price) AS revenue
    FROM core.order_items i
    JOIN core.orders o ON o.order_id = i.order_id AND o.order_status = 'delivered'
    GROUP BY i.seller_id
),
ranked AS (
    SELECT seller_id,
           revenue,
           RANK()       OVER (ORDER BY revenue DESC)                          AS rnk,
           SUM(revenue) OVER (ORDER BY revenue DESC, seller_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue) OVER ()                                           AS cum_share
    FROM seller_rev
),
flagged AS (
    SELECT *,
           COALESCE(LAG(cum_share) OVER (ORDER BY revenue DESC, seller_id), 0) AS prev_cum_share
    FROM ranked
)
-- Headline: sellers needed to reach 80% of revenue
SELECT COUNT(*)                                                     AS total_sellers,
       COUNT(*) FILTER (WHERE prev_cum_share < 0.80)                AS sellers_for_80pct_revenue,
       ROUND(100.0 * COUNT(*) FILTER (WHERE prev_cum_share < 0.80)
             / COUNT(*), 2)                                         AS pct_of_sellers_for_80pct
FROM flagged;

-- Top 10 sellers with cumulative share
WITH seller_rev AS (
    SELECT i.seller_id, s.state, SUM(i.price) AS revenue
    FROM core.order_items i
    JOIN core.orders o  ON o.order_id  = i.order_id AND o.order_status = 'delivered'
    JOIN core.sellers s ON s.seller_id = i.seller_id
    GROUP BY i.seller_id, s.state
)
SELECT RANK() OVER (ORDER BY revenue DESC)                          AS rank,
       seller_id,
       state,
       ROUND(revenue, 2)                                            AS revenue_brl,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC, seller_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue) OVER (), 2)                             AS cumulative_share_pct
FROM seller_rev
ORDER BY revenue DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- A6. Does late delivery hurt review scores?
-- delay_days = actual delivery minus promised delivery date (positive = late).
-- Review scores are averaged per order first, so orders with several
-- reviews do not count more than once.
-- ---------------------------------------------------------------------
WITH order_review AS (
    SELECT order_id, AVG(review_score) AS avg_score
    FROM core.order_reviews
    GROUP BY order_id
),
delivery AS (
    SELECT o.order_id,
           EXTRACT(EPOCH FROM (o.delivered_customer_ts - o.estimated_delivery_ts)) / 86400.0 AS delay_days
    FROM core.orders o
    WHERE o.order_status = 'delivered'
      AND o.delivered_customer_ts IS NOT NULL
      AND o.estimated_delivery_ts IS NOT NULL
),
bucketed AS (
    SELECT d.order_id, r.avg_score,
           CASE
               WHEN delay_days <= -3 THEN '1. Early by 3+ days'
               WHEN delay_days <=  0 THEN '2. On time (0-3 days early)'
               WHEN delay_days <=  3 THEN '3. Late 1-3 days'
               WHEN delay_days <=  7 THEN '4. Late 4-7 days'
               ELSE                       '5. Late 8+ days'
           END AS delivery_bucket
    FROM delivery d
    JOIN order_review r ON r.order_id = d.order_id
)
SELECT delivery_bucket,
       COUNT(*)                                                    AS reviewed_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS pct_of_orders,
       ROUND(AVG(avg_score), 2)                                    AS avg_review_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE avg_score <= 2) / COUNT(*), 2) AS pct_low_scores
FROM bucketed
GROUP BY delivery_bucket
ORDER BY delivery_bucket;
