-- Seed: GitHub Copilot per-model AI Credit pricing (published list prices, per 1M tokens).
-- 1 AI credit = $0.01 USD. Source: https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
-- Keyed by the CLI model string (session_models.model). Keep this file identical to the
-- INSERT block in postgres/migrations/003-ai-credits.sql.
--
-- ON CONFLICT updates only rows that are still the official seed, so a user who edits a
-- rate to source='local_override' is never clobbered by a re-seed.
INSERT INTO model_pricing
    (model, display_name, vendor, input_per_mtok, cached_input_per_mtok, cache_write_per_mtok, output_per_mtok, pricing_confidence, note)
VALUES
    -- OpenAI (no separate cache-write rate)
    ('gpt-4.1',              'GPT-4.1',        'OpenAI',    2.00, 0.50,  0.00,  8.00, 'exact',       'included model'),
    ('gpt-5-mini',           'GPT-5 mini',     'OpenAI',    0.25, 0.025, 0.00,  2.00, 'exact',       'included model'),
    ('gpt-5.2',              'GPT-5.2',        'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.2-codex',        'GPT-5.2-Codex',  'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.3-codex',        'GPT-5.3-Codex',  'OpenAI',    1.75, 0.175, 0.00, 14.00, 'exact',       NULL),
    ('gpt-5.4',              'GPT-5.4',        'OpenAI',    2.50, 0.25,  0.00, 15.00, 'exact',       'rate applies to prompts <=272K tokens'),
    ('gpt-5.4-mini',         'GPT-5.4 mini',   'OpenAI',    0.75, 0.075, 0.00,  4.50, 'exact',       NULL),
    ('gpt-5.4-nano',         'GPT-5.4 nano',   'OpenAI',    0.20, 0.02,  0.00,  1.25, 'exact',       NULL),
    ('gpt-5.5',              'GPT-5.5',        'OpenAI',    5.00, 0.50,  0.00, 30.00, 'exact',       NULL),
    -- Anthropic (cache-write priced separately)
    ('claude-haiku-4.5',     'Claude Haiku 4.5','Anthropic',1.00, 0.10,  1.25,  5.00, 'exact',       NULL),
    ('claude-sonnet-4',      'Claude Sonnet 4','Anthropic', 3.00, 0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-sonnet-4.5',    'Claude Sonnet 4.5','Anthropic',3.00,0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-sonnet-4.6',    'Claude Sonnet 4.6','Anthropic',3.00,0.30,  3.75, 15.00, 'exact',       NULL),
    ('claude-opus-4.5',      'Claude Opus 4.5','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.6',      'Claude Opus 4.6','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.7',      'Claude Opus 4.7','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    ('claude-opus-4.8',      'Claude Opus 4.8','Anthropic', 5.00, 0.50,  6.25, 25.00, 'exact',       NULL),
    -- Google (mapped from CLI preview name to the closest published rate)
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
