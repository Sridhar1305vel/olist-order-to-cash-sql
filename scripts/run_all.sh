#!/usr/bin/env bash
# Runs the whole pipeline: schema -> load -> build core -> DQ checks ->
# reconciliation -> analytics (-> optional performance tuning).
#
#   ./scripts/run_all.sh                 # real data in ./data, via Docker
#   ./scripts/run_all.sh --tuning        # also run 07_performance_tuning.sql
#   DATA_DIR=./data_sample ./scripts/run_all.sh     # test with synthetic data
#   MODE=local ./scripts/run_all.sh      # use a Postgres you already run (needs psql,
#                                        #  PG* env vars, and CSVs visible at /data)
#
# Console output of each step is saved to ./results/ .
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

MODE="${MODE:-docker}"
export DATA_DIR="${DATA_DIR:-./data}"
RUN_TUNING=false
[[ "${1:-}" == "--tuning" ]] && RUN_TUNING=true

REQUIRED=(olist_customers_dataset.csv olist_geolocation_dataset.csv olist_orders_dataset.csv
          olist_order_items_dataset.csv olist_order_payments_dataset.csv olist_order_reviews_dataset.csv
          olist_products_dataset.csv olist_sellers_dataset.csv product_category_name_translation.csv)
if [[ "$MODE" == "docker" ]]; then
  for f in "${REQUIRED[@]}"; do
    [[ -f "$DATA_DIR/$f" ]] || { echo "Missing $DATA_DIR/$f  (see data/README.md)"; exit 1; }
  done
  docker compose up -d
  echo -n "Waiting for Postgres"
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' olist_pg 2>/dev/null)" == "healthy" ]]; do
    echo -n "."; sleep 2
  done
  echo " ready."
  run_sql() { docker compose exec -T db psql -U postgres -d olist -v ON_ERROR_STOP=1 -q -f "/sql/$1"; }
else
  run_sql() { psql -v ON_ERROR_STOP=1 -q -f "sql/$1"; }
fi

mkdir -p results
STEPS=(01_schema.sql 02_load_staging.sql 03_build_core.sql 04_data_quality_checks.sql
       05_reconciliation.sql 06_analytics.sql)
$RUN_TUNING && STEPS+=(07_performance_tuning.sql)

for step in "${STEPS[@]}"; do
  echo ">>> $step"
  run_sql "$step" 2>&1 | tee "results/${step%.sql}.txt" | tail -n 3
done
echo "Done. Full outputs are in ./results/"
