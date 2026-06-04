-- Migration 004: add the "no prompt caching" counterfactual cost to the credit
-- views so dashboards can show how much prompt caching is saving.
--
-- Why this matters: the headline AI-credit estimate looks surprisingly low
-- because the overwhelming majority of input tokens are served from the model
-- providers' prompt caches at ~10% of the base input price (see docs/ai-credits.md
-- and the vendor references therein). usd_uncached / est_usd_uncached price every
-- prompt token at the full base input rate, so (uncached - actual) is the caching
-- discount. cache_read_tokens and cache_write_tokens are subsets of input_tokens,
-- so pricing all of input_tokens at the base rate already covers them.
--
-- Idempotent: CREATE OR REPLACE only appends new trailing columns to each view.

CREATE OR REPLACE VIEW session_model_credits AS
SELECT
    q.session_id,
    q.model,
    q.priced,
    q.input_tokens,
    q.output_tokens,
    q.usd,
    (q.usd * 100.0) AS credits,
    q.usd_uncached
FROM (
    SELECT
        sm.session_id,
        sm.model,
        (p.model IS NOT NULL) AS priced,
        sm.input_tokens,
        sm.output_tokens,
        CASE WHEN p.model IS NULL THEN NULL ELSE (
            GREATEST(sm.input_tokens - sm.cache_read_tokens - sm.cache_write_tokens, 0) * p.input_per_mtok
            + sm.cache_read_tokens  * p.cached_input_per_mtok
            + sm.cache_write_tokens * p.cache_write_per_mtok
            + sm.output_tokens      * p.output_per_mtok
        ) / 1000000.0 END AS usd,
        CASE WHEN p.model IS NULL THEN NULL ELSE (
            sm.input_tokens  * p.input_per_mtok
            + sm.output_tokens * p.output_per_mtok
        ) / 1000000.0 END AS usd_uncached
    FROM session_models sm
    LEFT JOIN model_pricing p ON p.model = sm.model
) q;

CREATE OR REPLACE VIEW session_credits AS
SELECT
    c.session_id,
    SUM(c.usd)     AS est_usd,
    SUM(c.credits) AS est_credits,
    bool_and(c.priced) AS complete_pricing,
    COALESCE(string_agg(DISTINCT CASE WHEN NOT c.priced THEN c.model END, ', '), '') AS unpriced_models,
    COALESCE(SUM(CASE WHEN NOT c.priced THEN c.input_tokens + c.output_tokens ELSE 0 END), 0) AS unpriced_tokens,
    SUM(c.usd_uncached) AS est_usd_uncached
FROM session_model_credits c
GROUP BY c.session_id;
