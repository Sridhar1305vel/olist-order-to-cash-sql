-- =====================================================================
-- 05_reconciliation.sql   (the flagship of the project)
--
-- Question: for every order, does what the customer PAID equal what the
-- order was WORTH (line-item prices + freight)?
--
--   expected_value = SUM(price + freight_value)   from core.order_items
--   paid_value     = SUM(payment_value)           from core.order_payments
--   variance       = paid_value - expected_value  (positive = customer paid more)
--
-- Tolerance: differences of 0.01 or less count as MATCHED (rounding).
-- Amounts are BRL, exactly as in the source data (no currency conversion).
--
-- probable_cause is a HEURISTIC label to speed up investigation. It is not
-- proof. See the README for the reasoning and limits.
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS recon.order_recon;

CREATE MATERIALIZED VIEW recon.order_recon AS
WITH expected AS (
    SELECT order_id,
           COUNT(*)                          AS n_items,
           SUM(price)                        AS items_value,
           SUM(freight_value)                AS freight_value,
           SUM(price + freight_value)        AS expected_value
    FROM core.order_items
    GROUP BY order_id
),
paid AS (
    SELECT order_id,
           COUNT(*)                                   AS n_payments,
           SUM(payment_value)                         AS paid_value,
           MAX(payment_installments)                  AS max_installments,
           BOOL_OR(payment_type = 'credit_card')      AS has_card,
           BOOL_OR(payment_type = 'voucher')          AS has_voucher
    FROM core.order_payments
    GROUP BY order_id
),
primary_payment AS (
    -- The payment type carrying the largest share of the order's value.
    SELECT DISTINCT ON (order_id) order_id, payment_type AS primary_payment_type
    FROM core.order_payments
    ORDER BY order_id, payment_value DESC, payment_sequential
),
joined AS (
    SELECT o.order_id,
           o.order_status,
           o.purchase_ts,
           c.state                                  AS customer_state,
           COALESCE(e.n_items, 0)                   AS n_items,
           COALESCE(p.n_payments, 0)                AS n_payments,
           COALESCE(e.expected_value, 0)            AS expected_value,
           COALESCE(p.paid_value, 0)                AS paid_value,
           COALESCE(p.paid_value, 0) - COALESCE(e.expected_value, 0) AS variance,
           pp.primary_payment_type,
           p.max_installments,
           COALESCE(p.has_card, FALSE)              AS has_card,
           COALESCE(p.has_voucher, FALSE)           AS has_voucher,
           (e.order_id IS NULL)                     AS no_items,
           (p.order_id IS NULL)                     AS no_payment
    FROM core.orders o
    JOIN core.customers c           ON c.customer_id = o.customer_id
    LEFT JOIN expected e            ON e.order_id = o.order_id
    LEFT JOIN paid p                ON p.order_id = o.order_id
    LEFT JOIN primary_payment pp    ON pp.order_id = o.order_id
),
classified AS (
    SELECT j.*,
           CASE
               WHEN no_items AND no_payment                 THEN 'EMPTY_ORDER'
               WHEN no_payment                              THEN 'NO_PAYMENT'
               WHEN no_items                                THEN 'PAYMENT_NO_ITEMS'
               WHEN ABS(variance) <= 0.01                   THEN 'MATCHED'
               WHEN variance < 0                            THEN 'UNDERPAID'
               ELSE                                              'OVERPAID'
           END AS recon_status
    FROM joined j
)
SELECT order_id,
       order_status,
       purchase_ts,
       DATE_TRUNC('month', purchase_ts)::DATE AS purchase_month,
       customer_state,
       primary_payment_type,
       n_items,
       n_payments,
       expected_value,
       paid_value,
       ROUND(variance, 2)                      AS variance,
       CASE WHEN expected_value > 0
            THEN ROUND(100.0 * variance / expected_value, 2) END AS variance_pct,
       recon_status,
       CASE
           WHEN recon_status = 'MATCHED' THEN NULL
           WHEN recon_status = 'EMPTY_ORDER'
               THEN 'Order has no items and no payment'
           WHEN recon_status = 'NO_PAYMENT' AND order_status IN ('canceled','unavailable')
               THEN 'Order not fulfilled (cancelled/unavailable)'
           WHEN recon_status = 'NO_PAYMENT'
               THEN 'Missing payment record: investigate'
           WHEN recon_status = 'PAYMENT_NO_ITEMS' AND order_status IN ('canceled','unavailable')
               THEN 'Paid then cancelled/unavailable: check refund'
           WHEN recon_status = 'PAYMENT_NO_ITEMS'
               THEN 'Payment without items: investigate'
           WHEN recon_status = 'OVERPAID' AND has_card AND max_installments > 1
               THEN 'Likely instalment interest on card payment'
           WHEN recon_status = 'OVERPAID'
               THEN 'Unexplained overpayment'
           WHEN recon_status = 'UNDERPAID' AND order_status IN ('canceled','unavailable')
               THEN 'Partial payment on unfulfilled order'
           ELSE 'Unexplained underpayment'
       END AS probable_cause
FROM classified;

CREATE UNIQUE INDEX ux_order_recon_order_id ON recon.order_recon (order_id);
ANALYZE recon.order_recon;

-- Integrity check on the recon itself: one row per order, nothing lost.
SELECT (SELECT COUNT(*) FROM core.orders)       AS orders_in_core,
       (SELECT COUNT(*) FROM recon.order_recon) AS rows_in_recon,
       (SELECT COUNT(*) FROM core.orders) = (SELECT COUNT(*) FROM recon.order_recon) AS counts_match;

-- ---------------------------------------------------------------------
-- REPORT 1: overall result by reconciliation status
-- ---------------------------------------------------------------------
SELECT recon_status,
       COUNT(*)                                             AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)   AS pct_of_orders,
       ROUND(SUM(expected_value), 2)                        AS expected_brl,
       ROUND(SUM(paid_value), 2)                            AS paid_brl,
       ROUND(SUM(variance), 2)                              AS net_variance_brl,
       ROUND(SUM(ABS(variance)), 2)                         AS gross_abs_variance_brl
FROM recon.order_recon
GROUP BY recon_status
ORDER BY orders DESC;

-- ---------------------------------------------------------------------
-- REPORT 2: probable cause of each exception
-- ---------------------------------------------------------------------
SELECT recon_status,
       probable_cause,
       COUNT(*)                        AS orders,
       ROUND(SUM(variance), 2)         AS net_variance_brl,
       ROUND(SUM(ABS(variance)), 2)    AS gross_abs_variance_brl
FROM recon.order_recon
WHERE recon_status <> 'MATCHED'
GROUP BY recon_status, probable_cause
ORDER BY gross_abs_variance_brl DESC;

-- ---------------------------------------------------------------------
-- REPORT 3: monthly trend of exceptions
-- ---------------------------------------------------------------------
SELECT purchase_month,
       COUNT(*)                                                  AS orders,
       COUNT(*) FILTER (WHERE recon_status <> 'MATCHED')         AS exception_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE recon_status <> 'MATCHED') / COUNT(*), 2) AS exception_pct,
       ROUND(SUM(variance) FILTER (WHERE variance > 0), 2)       AS gross_overpaid_brl,
       ROUND(SUM(variance) FILTER (WHERE variance < 0), 2)       AS gross_underpaid_brl,
       ROUND(SUM(variance), 2)                                   AS net_variance_brl
FROM recon.order_recon
GROUP BY purchase_month
ORDER BY purchase_month;

-- ---------------------------------------------------------------------
-- REPORT 4: exceptions by customer state (top 10 by absolute variance)
-- ---------------------------------------------------------------------
SELECT customer_state,
       COUNT(*)                                                   AS orders,
       COUNT(*) FILTER (WHERE recon_status <> 'MATCHED')          AS exception_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE recon_status <> 'MATCHED') / COUNT(*), 2) AS exception_pct,
       ROUND(SUM(ABS(variance)), 2)                               AS gross_abs_variance_brl
FROM recon.order_recon
GROUP BY customer_state
ORDER BY gross_abs_variance_brl DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- REPORT 5: exceptions by primary payment type
-- ---------------------------------------------------------------------
SELECT COALESCE(primary_payment_type, '(no payment)')             AS primary_payment_type,
       COUNT(*)                                                   AS orders,
       COUNT(*) FILTER (WHERE recon_status <> 'MATCHED')          AS exception_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE recon_status <> 'MATCHED') / COUNT(*), 2) AS exception_pct,
       ROUND(SUM(variance), 2)                                    AS net_variance_brl
FROM recon.order_recon
GROUP BY 1
ORDER BY exception_orders DESC;

-- ---------------------------------------------------------------------
-- REPORT 6: 20 largest individual exceptions (the investigation queue)
-- ---------------------------------------------------------------------
SELECT order_id, order_status, recon_status, expected_value, paid_value, variance, probable_cause
FROM recon.order_recon
WHERE recon_status <> 'MATCHED'
ORDER BY ABS(variance) DESC
LIMIT 20;
