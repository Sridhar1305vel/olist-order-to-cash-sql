#!/usr/bin/env python3
"""
Generate a SMALL, SYNTHETIC dataset with the same file names and columns as
the Olist Brazilian E-Commerce dataset, so you can test the whole pipeline
before downloading the real data.

!! Do NOT report findings from this data. It is random and contains planted
!! anomalies purely so every SQL check has something to detect.

Usage:  python3 scripts/generate_sample_data.py [--out data_sample] [--orders 3000] [--seed 42]
"""
import argparse, csv, os, random
from datetime import datetime, timedelta

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="data_sample")
ap.add_argument("--orders", type=int, default=3000)
ap.add_argument("--seed", type=int, default=42)
a = ap.parse_args()
random.seed(a.seed)
os.makedirs(a.out, exist_ok=True)

STATES = ["SP", "RJ", "MG", "RS", "PR", "BA", "SC", "GO"]
CATS = ["health_beauty", "computers_accessories", "furniture_decor", "sports_leisure",
        "housewares", "toys", "watches_gifts", "bed_bath_table"]
TRANSL = {c: c.replace("_", " ") for c in CATS}
FMT = "%Y-%m-%d %H:%M:%S"
hexid = lambda: "%032x" % random.getrandbits(128)

def w(name, header, rows):
    with open(os.path.join(a.out, name), "w", newline="", encoding="utf-8") as f:
        cw = csv.writer(f); cw.writerow(header); cw.writerows(rows)

# --- reference tables -------------------------------------------------
n_cust_unique = int(a.orders * 0.85)
uniq = [hexid() for _ in range(n_cust_unique)]
customers, cust_ids = [], []
for _ in range(a.orders):
    cid = hexid(); cust_ids.append(cid)
    customers.append([cid, random.choice(uniq), random.randint(1000, 99999),
                      "city_%d" % random.randint(1, 50), random.choice(STATES)])
sellers = [[hexid(), random.randint(1000, 99999), "city_%d" % random.randint(1, 30), random.choice(STATES)]
           for _ in range(60)]
products = []
for _ in range(400):
    cat = random.choice(CATS) if random.random() > 0.02 else ""
    products.append([hexid(), cat, random.randint(20, 60), random.randint(100, 900), random.randint(1, 6),
                     random.randint(100, 5000), random.randint(10, 60), random.randint(5, 40), random.randint(10, 40)])

# --- orders / items / payments / reviews ------------------------------
orders, items, pays, reviews = [], [], [], []
start = datetime(2017, 1, 1)
span_days = 700
for idx, cid in enumerate(cust_ids):
    oid = hexid()
    purchase = start + timedelta(days=random.random() * span_days, seconds=random.randint(0, 86399))
    status = random.choices(["delivered", "shipped", "canceled", "unavailable", "invoiced", "processing"],
                            [93, 3, 1.5, 0.7, 1, 0.8])[0]
    approved = purchase + timedelta(hours=random.randint(0, 24))
    carrier = approved + timedelta(days=random.randint(1, 4))
    est = purchase + timedelta(days=random.randint(10, 30))
    delivered = carrier + timedelta(days=random.randint(2, 25)) if status == "delivered" else None

    # planted date anomalies
    if status == "delivered" and random.random() < 0.004:
        delivered = purchase - timedelta(days=2)               # delivered before purchase
    if status == "delivered" and random.random() < 0.003:
        delivered = None                                       # delivered without date
    if random.random() < 0.003:
        approved = purchase - timedelta(hours=5)               # approved before purchase

    orders.append([oid, cid, status, purchase.strftime(FMT), approved.strftime(FMT),
                   carrier.strftime(FMT), delivered.strftime(FMT) if delivered else "", est.strftime(FMT)])

    no_items = status in ("canceled", "unavailable") and random.random() < 0.8
    expected = 0.0
    if not no_items:
        for k in range(1, random.choices([1, 2, 3], [80, 15, 5])[0] + 1):
            price = round(random.uniform(9, 400), 2)
            if random.random() < 0.002: price = 0.0
            freight = round(random.uniform(5, 45), 2)
            expected += price + freight
            items.append([oid, k, random.choice(products)[0], random.choice(sellers)[0],
                          (purchase + timedelta(days=3)).strftime(FMT), price, freight])
    expected = round(expected, 2)

    # payments (with planted mismatches)
    r = random.random()
    if r < 0.004 and status not in ("canceled", "unavailable"):
        pass                                                   # missing payment record
    else:
        ptype = random.choices(["credit_card", "boleto", "voucher", "debit_card"], [74, 19, 5, 1])[0]
        inst = random.choice([1, 1, 1, 2, 3, 4, 6, 10]) if ptype == "credit_card" else 1
        value = expected
        if not no_items:
            if ptype == "credit_card" and inst > 1:
                value = round(expected * (1 + 0.012 * inst), 2)   # instalment interest -> overpaid
            elif r < 0.02:
                value = round(expected - random.uniform(1, 30), 2) # underpaid
        else:
            value = round(random.uniform(20, 200), 2)            # paid but no items
        if ptype == "voucher" and random.random() < 0.3:
            pays.append([oid, 1, "voucher", 1, round(value * 0.4, 2)])
            pays.append([oid, 2, "credit_card", 1, round(value * 0.6, 2)])
        else:
            pays.append([oid, 1, ptype, inst, value])
        if random.random() < 0.0015:
            pays.append([oid, 1, ptype, inst, value])            # duplicate payment key
        if random.random() < 0.001:
            pays.append([oid, 3, "not_defined", 1, 0.00])        # zero, undefined type

    # reviews (sometimes none, sometimes duplicated review_id reused)
    if random.random() < 0.85:
        late = delivered is not None and delivered > est
        score = random.choices([1, 2, 3, 4, 5], [45, 20, 15, 10, 10] if late else [4, 4, 10, 25, 57])[0]
        rid = hexid()
        created = (delivered or purchase) + timedelta(days=1)
        answered = created + timedelta(days=random.randint(0, 3))
        reviews.append([rid, oid, score, "", "", created.strftime(FMT), answered.strftime(FMT)])
        if random.random() < 0.01 and reviews:
            reviews.append([rid, oid, score, "", "", created.strftime(FMT), answered.strftime(FMT)])  # exact duplicate

w("olist_customers_dataset.csv",
  ["customer_id", "customer_unique_id", "customer_zip_code_prefix", "customer_city", "customer_state"], customers)
w("olist_sellers_dataset.csv",
  ["seller_id", "seller_zip_code_prefix", "seller_city", "seller_state"], sellers)
w("olist_products_dataset.csv",
  ["product_id", "product_category_name", "product_name_lenght", "product_description_lenght",
   "product_photos_qty", "product_weight_g", "product_length_cm", "product_height_cm", "product_width_cm"], products)
w("product_category_name_translation.csv",
  ["product_category_name", "product_category_name_english"], list(TRANSL.items())[:-1])  # one category deliberately untranslated
w("olist_orders_dataset.csv",
  ["order_id", "customer_id", "order_status", "order_purchase_timestamp", "order_approved_at",
   "order_delivered_carrier_date", "order_delivered_customer_date", "order_estimated_delivery_date"], orders)
w("olist_order_items_dataset.csv",
  ["order_id", "order_item_id", "product_id", "seller_id", "shipping_limit_date", "price", "freight_value"], items)
w("olist_order_payments_dataset.csv",
  ["order_id", "payment_sequential", "payment_type", "payment_installments", "payment_value"], pays)
w("olist_order_reviews_dataset.csv",
  ["review_id", "order_id", "review_score", "review_comment_title", "review_comment_message",
   "review_creation_date", "review_answer_timestamp"], reviews)
w("olist_geolocation_dataset.csv",
  ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng", "geolocation_city", "geolocation_state"],
  [[random.randint(1000, 99999), round(random.uniform(-30, -5), 6), round(random.uniform(-55, -35), 6),
    "city_%d" % random.randint(1, 50), random.choice(STATES)] for _ in range(500)])

print("Wrote synthetic sample data to %s/ (%d orders, %d items, %d payments, %d reviews)"
      % (a.out, len(orders), len(items), len(pays), len(reviews)))
