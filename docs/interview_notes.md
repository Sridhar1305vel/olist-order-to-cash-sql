# Interview prep for this project

Answer using YOUR real numbers from the run. These are the questions an interviewer is most likely to ask.

**1. Walk me through the project in 60 seconds.**
Raw Olist CSVs into PostgreSQL staging, cleaned into constrained core tables, 28 logged data-quality checks,
then an order-level reconciliation of payments against item value, then business analytics, then index tuning.
Lead with the reconciliation result (your % matched and BRL variance), because that is the story.

**2. Why a staging schema and a core schema?**
Staging keeps the raw data untouched (all TEXT, nothing rejected) so I can audit it. Core enforces types and
constraints. Bad data is found and logged, not silently lost.

**3. How did you decide two rows were duplicates?**
Only rows identical in every column are collapsed. If two rows share a key but differ, the primary key rejects
the load and I investigate. In reconciliation, silently dropping a row could hide real money.

**4. Why is customer_id not enough to count customers?**
In Olist, `customer_id` changes with every order; `customer_unique_id` identifies the person. Using the wrong
one makes every customer look like a one-time buyer.

**5. Explain your reconciliation logic and the tolerance.**
Expected = items + freight; paid = sum of payments; variance = paid - expected. Differences of 0.01 or less are
rounding. Because orders can have several payments (vouchers plus card), I aggregate payments per order first,
otherwise joins would multiply rows and inflate totals.

**6. What are the classification categories and why those?**
Matched / over / under / no payment / payment without items / empty. They map to different actions: chase a
missing payment, check a refund, or explain an overpayment.

**7. How reliable is `probable_cause`?**
It is a heuristic, not proof. I say so in the README. I would confirm with the payments team (for example the
instalment-interest policy) before acting on it.

**8. Why NTILE for recency and monetary but fixed buckets for frequency?**
Most customers buy once, so quintiles of frequency would be meaningless: nearly every row ties.

**9. Show me one query where you used a window function and why.**
Pareto: a running `SUM() OVER (ORDER BY revenue DESC ...)` divided by total revenue gives cumulative share, so I
can count how many sellers make up 80%. Or `LAG` for month-over-month growth.

**10. What did EXPLAIN ANALYZE show and what did you change?**
Quote your own before/after table. Mention that FK columns are not auto-indexed in PostgreSQL and that the
review primary key cannot serve joins on `order_id` because it starts with `review_id`.

**11. What would you do differently with more time?**
Incremental loads and a scheduler, automated tests on the checks (dbt-style), a Power BI or Metabase dashboard
on the recon view, and validating the cause heuristics with domain owners.

**12. What are the limits of this analysis?**
Historical data from 2016 to 2018, unknown payment rules, self-selected reviews, partial months at the edges.
