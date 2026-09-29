-- =====================================================================
-- 01_schema.sql
-- Creates schemas, raw staging tables (all TEXT), clean core tables
-- (typed, constrained) and the data-quality issue log.
-- Safe to re-run: it drops and recreates everything in these schemas.
-- =====================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS core    CASCADE;
DROP SCHEMA IF EXISTS recon   CASCADE;
DROP SCHEMA IF EXISTS dq      CASCADE;

CREATE SCHEMA staging;  -- raw CSV copies, everything TEXT, nothing rejected
CREATE SCHEMA core;     -- cleaned, typed, constrained tables
CREATE SCHEMA recon;    -- reconciliation outputs
CREATE SCHEMA dq;       -- data-quality issue log

-- ---------------------------------------------------------------------
-- STAGING: mirrors the Olist CSV headers exactly (note Olist's own
-- misspelling "lenght" in the products file).
-- ---------------------------------------------------------------------
CREATE TABLE staging.customers (
    customer_id              TEXT,
    customer_unique_id       TEXT,
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT
);

CREATE TABLE staging.geolocation (
    geolocation_zip_code_prefix TEXT,
    geolocation_lat             TEXT,
    geolocation_lng             TEXT,
    geolocation_city            TEXT,
    geolocation_state           TEXT
);

CREATE TABLE staging.orders (
    order_id                      TEXT,
    customer_id                   TEXT,
    order_status                  TEXT,
    order_purchase_timestamp      TEXT,
    order_approved_at             TEXT,
    order_delivered_carrier_date  TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

CREATE TABLE staging.order_items (
    order_id            TEXT,
    order_item_id       TEXT,
    product_id          TEXT,
    seller_id           TEXT,
    shipping_limit_date TEXT,
    price               TEXT,
    freight_value       TEXT
);

CREATE TABLE staging.order_payments (
    order_id             TEXT,
    payment_sequential   TEXT,
    payment_type         TEXT,
    payment_installments TEXT,
    payment_value        TEXT
);

CREATE TABLE staging.order_reviews (
    review_id               TEXT,
    order_id                TEXT,
    review_score            TEXT,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT
);

CREATE TABLE staging.products (
    product_id                 TEXT,
    product_category_name      TEXT,
    product_name_lenght        TEXT,
    product_description_lenght TEXT,
    product_photos_qty         TEXT,
    product_weight_g           TEXT,
    product_length_cm          TEXT,
    product_height_cm          TEXT,
    product_width_cm           TEXT
);

CREATE TABLE staging.sellers (
    seller_id              TEXT,
    seller_zip_code_prefix TEXT,
    seller_city            TEXT,
    seller_state           TEXT
);

CREATE TABLE staging.category_translation (
    product_category_name         TEXT,
    product_category_name_english TEXT
);

-- ---------------------------------------------------------------------
-- CORE: typed and constrained. Secondary indexes are deliberately NOT
-- created here; 07_performance_tuning.sql adds them and measures the gain.
-- ---------------------------------------------------------------------
CREATE TABLE core.customers (
    customer_id        TEXT PRIMARY KEY,
    customer_unique_id TEXT NOT NULL,
    zip_code_prefix    TEXT,
    city               TEXT,
    state              CHAR(2)
);

CREATE TABLE core.sellers (
    seller_id       TEXT PRIMARY KEY,
    zip_code_prefix TEXT,
    city            TEXT,
    state           CHAR(2)
);

CREATE TABLE core.products (
    product_id         TEXT PRIMARY KEY,
    category_name      TEXT,
    name_length        INT,
    description_length INT,
    photos_qty         INT,
    weight_g           NUMERIC,
    length_cm          NUMERIC,
    height_cm          NUMERIC,
    width_cm           NUMERIC
);

CREATE TABLE core.category_translation (
    category_name         TEXT PRIMARY KEY,
    category_name_english TEXT NOT NULL
);

CREATE TABLE core.orders (
    order_id              TEXT PRIMARY KEY,
    customer_id           TEXT NOT NULL REFERENCES core.customers (customer_id),
    order_status          TEXT NOT NULL,
    purchase_ts           TIMESTAMP NOT NULL,
    approved_ts           TIMESTAMP,
    delivered_carrier_ts  TIMESTAMP,
    delivered_customer_ts TIMESTAMP,
    estimated_delivery_ts TIMESTAMP
);

CREATE TABLE core.order_items (
    order_id          TEXT NOT NULL REFERENCES core.orders (order_id),
    order_item_id     INT  NOT NULL,
    product_id        TEXT NOT NULL REFERENCES core.products (product_id),
    seller_id         TEXT NOT NULL REFERENCES core.sellers (seller_id),
    shipping_limit_ts TIMESTAMP,
    price             NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    freight_value     NUMERIC(10,2) NOT NULL CHECK (freight_value >= 0),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE core.order_payments (
    order_id             TEXT NOT NULL REFERENCES core.orders (order_id),
    payment_sequential   INT  NOT NULL,
    payment_type         TEXT NOT NULL,
    payment_installments INT  NOT NULL CHECK (payment_installments >= 0),
    payment_value        NUMERIC(10,2) NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

-- Olist reuses some review_ids across different orders, so review_id
-- alone is not unique. (review_id, order_id) is the natural key.
CREATE TABLE core.order_reviews (
    review_id    TEXT NOT NULL,
    order_id     TEXT NOT NULL REFERENCES core.orders (order_id),
    review_score INT  NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    creation_ts  TIMESTAMP,
    answer_ts    TIMESTAMP,
    PRIMARY KEY (review_id, order_id)
);

-- ---------------------------------------------------------------------
-- DATA-QUALITY LOG: every check writes one row here.
-- ---------------------------------------------------------------------
CREATE TABLE dq.issues (
    check_id      SERIAL PRIMARY KEY,
    check_name    TEXT   NOT NULL,
    table_name    TEXT   NOT NULL,
    severity      TEXT   NOT NULL CHECK (severity IN ('HIGH','MEDIUM','LOW','INFO')),
    rows_affected BIGINT NOT NULL,
    rows_checked  BIGINT NOT NULL,
    pct_affected  NUMERIC(7,3) GENERATED ALWAYS AS
                  (CASE WHEN rows_checked = 0 THEN 0
                        ELSE ROUND(100.0 * rows_affected / rows_checked, 3) END) STORED,
    description   TEXT,
    run_at        TIMESTAMP NOT NULL DEFAULT now()
);

-- Cleaning log: what the build step removed or altered, and why.
CREATE TABLE dq.cleaning_log (
    step         TEXT   NOT NULL,
    table_name   TEXT   NOT NULL,
    rows_in      BIGINT NOT NULL,
    rows_out     BIGINT NOT NULL,
    rows_removed BIGINT GENERATED ALWAYS AS (rows_in - rows_out) STORED,
    note         TEXT
);
