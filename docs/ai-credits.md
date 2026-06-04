# AI Credit cost estimates

This stack estimates **GitHub Copilot AI Credit usage** from the token counts already
captured by the local history pipeline. It is meant to help you understand cost trends by
session, model, and project without sending anything off your machine.

## TL;DR / Why

- GitHub switched Copilot billing to **AI Credits** on 2026-06-01: **1 AI credit =
  $0.01 USD**.
- AI Credits replace the older per-"premium-request" model, which is now **legacy**.
- Cost is now a function of **model + tokens**, not request counts.
- This stack already stores per-model token counts in `session_models`, so it can estimate
  credit cost from those totals.
- The legacy `sessions.premium_requests` / `sessions.premium_cost` columns are the old
  premium-request **count**. They are **not money**, **not credits**, and are kept only for
  historical/legacy reference.

## What we track

The Copilot CLI does **not** send a credit or dollar amount in `events.jsonl`; there is no
field to ingest for "cost". Instead, this stack **derives** an estimate from:

1. per-session, per-model token counts in `session_models`; and
2. published per-model list prices stored in `model_pricing`.

That means the estimate is transparent and reproducible, but it is still an estimate — not
your GitHub bill.

## How the estimate is computed

Prices are stored per 1M tokens. For each `(session_id, model)` row, the SQL view computes:

```text
usd = ( max(input_tokens − cache_read_tokens − cache_write_tokens, 0) × input_rate + cache_read_tokens × cached_rate + cache_write_tokens × cache_write_rate + output_tokens × output_rate ) / 1,000,000
credits = usd × 100
```

This avoids double-counting because of two verified facts about the CLI's normalized token
metrics:

- `input_tokens` is the **total prompt** and already **includes** `cache_read_tokens` and
  `cache_write_tokens` as subsets.
- `output_tokens` already **includes** `reasoning_tokens`.

So the estimate bills non-cached input, cached reads, cache writes, and total output.
Reasoning tokens are **not** added separately because they are already in output. The
cache-write rate is Anthropic-only; it is `0` for OpenAI and Google models.

## Data model

### `model_pricing`

`model_pricing(model, display_name, vendor, input_per_mtok, cached_input_per_mtok,
cache_write_per_mtok, output_per_mtok, pricing_confidence, source, note)`

- `model` matches the CLI model string in `session_models.model`.
- Rates are list prices per 1M tokens.
- `pricing_confidence` is `exact` or `approximate`.
- `source` is `official_seed` or `local_override`.
- Re-seeding with `make migrate` only overwrites rows still marked `official_seed`, so you
  can safely customize a rate by setting `source = 'local_override'`.

### `session_model_credits`

`session_model_credits(session_id, model, priced, input_tokens, output_tokens, usd, credits)`

One row per session + model. `usd` and `credits` are `NULL` for any model with no pricing
row, so unpriced usage is never silently counted as `$0`.

### `session_credits`

`session_credits(session_id, est_usd, est_credits, complete_pricing, unpriced_models,
unpriced_tokens)`

One row per session. `complete_pricing = false` and `unpriced_models` flag sessions that used
a model not present in `model_pricing`.

## Important caveats

This is a **gross list-price estimate**, not your bill.

- Ignores the **10% discount** for auto model selection.
- Ignores **included monthly allowances** (base + flex credits). It estimates total
  list-price consumption, not overage.
- Ignores **long-context tier surcharges**. For example, GPT-5.4 list rate applies to
  prompts ≤272K tokens and Gemini ≤200K. These cannot be reconstructed from per-session token
  totals.
- Uses the **current** published list prices applied to **all** historical sessions; there is
  no price-effective-dating.
- Some CLI model names are mapped approximately, such as `gemini-3-pro-preview` → Gemini 3.1
  Pro rates, and are flagged with `pricing_confidence = 'approximate'`.
- Code completions / next-edit suggestions are not billed in credits and are not represented
  here.

See GitHub's billing docs for the source-of-truth billing rules:

- [Usage-based billing for individuals](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals)
- [Models and pricing](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing)

## The dashboard

Open Grafana (http://localhost:3000) → **Copilot Usage** folder → **Copilot — AI Credits
(estimated)** (`uid: copilot-credits`). It shares the same **Project** and time-range filters
as the other dashboards and includes:

- **Stats** — total estimated credits, total estimated USD, and sessions with incomplete
  pricing.
- **Credits by Model** — estimated credits grouped by model.
- **Credits by Project** — estimated credits grouped by project.
- **Credits per Day** — daily trend over the selected time range.
- **Top Sessions** — sessions with the highest estimated credit usage.
- **Model Cost Detail** — model-level usage and estimated cost.
- **Pricing Reference** — the seeded rates and confidence/source metadata.

## Applying to an existing database & updating prices

```bash
make migrate     # creates model_pricing + credit views, seeds current prices (idempotent)
make backfill    # only needed to (re)load token data; credits are computed live in SQL
```

Prices are seeded by `postgres/migrations/003-ai-credits.sql` and, on a fresh volume,
`postgres/initdb/02-seed-pricing.sql`. To update a rate when GitHub changes pricing, edit
those files and re-run `make migrate`.

To override a single rate locally without it being re-seeded, update that row and mark it as
a local override:

```sql
UPDATE model_pricing
SET input_per_mtok = 3.00,
    source = 'local_override'
WHERE model = 'example-model';
```

No parser or image rebuild is required, unlike parser changes, because credit math lives
entirely in SQL views.

## Useful ad-hoc queries

```sql
-- Estimated credits per project
SELECT t.project,
       ROUND(SUM(c.est_credits)::numeric, 2) AS est_credits,
       ROUND(SUM(c.est_usd)::numeric, 2) AS est_usd,
       COUNT(*) AS sessions,
       COUNT(*) FILTER (WHERE NOT c.complete_pricing) AS sessions_with_unpriced_models
FROM session_credits c
JOIN session_totals t ON t.session_id = c.session_id
GROUP BY t.project
ORDER BY est_credits DESC;

-- Share of priced spend from fresh input vs. cache reads vs. cache writes vs. output
WITH parts AS (
  SELECT 'fresh_input' AS component,
         SUM(GREATEST(sm.input_tokens - sm.cache_read_tokens - sm.cache_write_tokens, 0)
             * p.input_per_mtok) / 1000000.0 AS usd
  FROM session_models sm JOIN model_pricing p ON p.model = sm.model
  UNION ALL
  SELECT 'cache_read', SUM(sm.cache_read_tokens * p.cached_input_per_mtok) / 1000000.0
  FROM session_models sm JOIN model_pricing p ON p.model = sm.model
  UNION ALL
  SELECT 'cache_write', SUM(sm.cache_write_tokens * p.cache_write_per_mtok) / 1000000.0
  FROM session_models sm JOIN model_pricing p ON p.model = sm.model
  UNION ALL
  SELECT 'output', SUM(sm.output_tokens * p.output_per_mtok) / 1000000.0
  FROM session_models sm JOIN model_pricing p ON p.model = sm.model
), total AS (
  SELECT SUM(usd) AS usd FROM parts
)
SELECT component,
       ROUND((usd * 100)::numeric, 2) AS credits,
       ROUND((usd / NULLIF(total.usd, 0) * 100)::numeric, 1) AS pct_of_priced_credits
FROM parts CROSS JOIN total
ORDER BY credits DESC;

-- Most expensive sessions
SELECT t.start_time,
       t.project,
       c.session_id,
       ROUND(c.est_credits::numeric, 2) AS est_credits,
       ROUND(c.est_usd::numeric, 2) AS est_usd,
       c.complete_pricing,
       c.unpriced_models
FROM session_credits c
JOIN session_totals t ON t.session_id = c.session_id
ORDER BY c.est_credits DESC NULLS LAST
LIMIT 25;
```

## Privacy

No new data classes are collected. AI Credit estimates use only token counts already present
in the local database multiplied by public list prices. No prompts, code, or secrets are
stored or sent anywhere.
