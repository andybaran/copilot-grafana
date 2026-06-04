-- Migration 003: AI Credit cost estimation.
-- Idempotent: safe to apply to an existing copilot_usage database created before
-- AI-credit support existed. Adds the model_pricing table, seeds published list
-- prices, and creates the session_model_credits / session_credits views.
-- Apply with: make migrate
--
-- Estimates are GROSS list-price only (1 AI credit = $0.01 USD): they ignore the
-- 10% auto-model discount, included monthly allowances, and long-context tier
-- surcharges. See docs/ai-credits.md. The existing session_totals view is NOT
-- modified, so token dashboards are unaffected.

CREATE TABLE IF NOT EXISTS model_pricing (
    model                 TEXT PRIMARY KEY,
    display_name          TEXT,
    vendor                TEXT,
    input_per_mtok        DOUBLE PRECISION NOT NULL DEFAULT 0,
    cached_input_per_mtok DOUBLE PRECISION NOT NULL DEFAULT 0,
    cache_write_per_mtok  DOUBLE PRECISION NOT NULL DEFAULT 0,
    output_per_mtok       DOUBLE PRECISION NOT NULL DEFAULT 0,
    pricing_confidence    TEXT NOT NULL DEFAULT 'exact',
    source                TEXT NOT NULL DEFAULT 'official_seed',
    note                  TEXT
);

-- Seed / refresh official prices (keep identical to postgres/initdb/02-seed-pricing.sql).
INSERT INTO model_pricing
    (model, display_name, vendor, input_per_mtok, cached_input_per_mtok, cache_write_per_mtok, output_per_mtok, pricing_confidence, note)
VALUES
    ('gpt-4.1',              'GPT-4.1',        'OpenAI',    2.00, 0.50,  0.00,  8.00, 'exact',       'included model'),
    ('gpt-5-mini',           'GPT-5 mini',     'OpenAI',    0.25, 0.025, 0.00,  2.00, 'exact',       'included model'),
    ('gpt-5.2',              'GPT-5.2',        'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.2-codex',        'GPT-5.2-Codex',  'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.3-codex',        'GPT-5.3-Codex',  'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.4',              'GPT-5.4',        'OpenAI',    2.50, 0.25,  0.00, 15.00, 'exact',       'rate applies to prompts <=272K tokens'),
    ('gpt-5.4-mini',         'GPT-5.4 mini',   'OpenAI',    0.75, 0.075, 0.00,  4.50, 'exact',       NULL),
    ('gpt-5.4-nano',         'GPT-5.4 nano',   'OpenAI',    0.20, 0.02,  0.00,  1.25, 'exact',       NULL),
    ('gpt-5.5',              'GPT-5.5',        'OpenAI',    5.00, 0.50,  0.00, 30.00, 'exact',       NULL),
    ('claude-haiku-4.5',     'Claude Haiku 4.5','Anthropic',1.00, 0.10,  1.25,  5.00, 'exact',       NULL),
    ('claude-sonnet-4',      'Claude Sonnet 4','Anthropic', 3.00, 0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-sonnet-4.5',    'Claude Sonnet 4.5','Anthropic',3.00,0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-sonnet-4.6',    'Claude Sonnet 4.6','Anthropic',3.00,0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-opus-4.5',      'Claude Opus 4.5','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.6',      'Claude Opus 4.6','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.7',      'Claude Opus 4.7','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.8',      'Claude Opus 4.8','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('gemini-3-pro-preview', 'Gemini 3.1 Pro', 'Google',    2.00, 0.20,  0.00, 12.00, 'approximate', 'CLI gemini-3-pro-preview mapped to Gemini 3.1 Pro; rate applies to prompts <=200K tokens'),
    ('gemini-2.5-pro',       'Gemini 2.5 Pro', 'Google',    1.25, 0.125, 0.00, 10.00, 'exact',       'rate applies to prompts <=200K tokens')
ON CONFLICT (model) DO UPDATE SET
    display_name          = EXCLUDED.display_name,
    vendor                = EXCLUDED.vendor,
    input_per_mtok        = EXCLUDED.input_per_mtok,
    cached_input_per_mtok = EXCLUDED.cached_input_per_mtok,
    cache_write_per_mtok  = EXCLUDED.cache_write_per_mtok,
    output_per_mtok       = EXCLUDED.output_per_mtok,
    pricing_confidence    = EXCLUDED.pricing_confidence,
    note                  = EXCLUDED.note
WHERE model_pricing.source = 'official_seed';

CREATE OR REPLACE VIEW session_model_credits AS
SELECT
    q.session_id,
    q.model,
    q.priced,
    q.input_tokens,
    q.output_tokens,
    q.usd,
    (q.usd * 100.0) AS credits
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
        ) / 1000000.0 END AS usd
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
    COALESCE(SUM(CASE WHEN NOT c.priced THEN c.input_tokens + c.output_tokens ELSE 0 END), 0) AS unpriced_tokens
FROM session_model_credits c
GROUP BY c.session_id;
