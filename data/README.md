# Data

This project uses the **Olist Brazilian E-Commerce Public Dataset** (about 100k orders, 2016 to 2018).

1. Download it from Kaggle: https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
2. Unzip and place these 9 CSV files directly in this `data/` folder:

```
olist_customers_dataset.csv
olist_geolocation_dataset.csv
olist_orders_dataset.csv
olist_order_items_dataset.csv
olist_order_payments_dataset.csv
olist_order_reviews_dataset.csv
olist_products_dataset.csv
olist_sellers_dataset.csv
product_category_name_translation.csv
```

The CSVs are git-ignored on purpose: do not re-upload the dataset. Credit Olist as the source and
check the licence shown on the Kaggle page before publishing anything derived from it.

All monetary values are in Brazilian reais (BRL).

## Testing without the real data

`python3 scripts/generate_sample_data.py` writes a small SYNTHETIC look-alike to `data_sample/` so you
can check that the pipeline runs. Never publish results from that data.
