-- Schema for Copilot CLI per-session usage facts.
-- Source of truth = ~/.copilot/session-state/<id>/events.jsonl (session.shutdown summary).
-- The parser (backfill/parser.py) upserts into these tables; safe to re-run.

CREATE TABLE IF NOT EXISTS sessions (
    session_id        TEXT PRIMARY KEY,
    start_time        TIMESTAMPTZ,
    end_time          TIMESTAMPTZ,
    cwd               TEXT,
    cli_version       TEXT,
    selected_model    TEXT,
    project           TEXT,
    project_source    TEXT,  -- env | file | git | cwd | unknown | sidecar
    premium_requests  INTEGER DEFAULT 0,
    premium_cost      DOUBLE PRECISION DEFAULT 0,
    api_duration_ms   BIGINT DEFAULT 0,
    lines_added       INTEGER DEFAULT 0,
    lines_removed     INTEGER DEFAULT 0,
    complete          BOOLEAN NOT NULL DEFAULT FALSE,  -- has a session.shutdown summary
    source            TEXT NOT NULL DEFAULT 'events_jsonl',
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS session_models (
    session_id         TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    model              TEXT NOT NULL,
    input_tokens       BIGINT DEFAULT 0,
    output_tokens      BIGINT DEFAULT 0,
    cache_read_tokens  BIGINT DEFAULT 0,
    cache_write_tokens BIGINT DEFAULT 0,
    reasoning_tokens   BIGINT DEFAULT 0,
    requests           INTEGER DEFAULT 0,
    cost               DOUBLE PRECISION DEFAULT 0,
    PRIMARY KEY (session_id, model)
);

CREATE TABLE IF NOT EXISTS session_skills (
    session_id   TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    skill        TEXT NOT NULL,
    invocations  INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (session_id, skill)
);

CREATE TABLE IF NOT EXISTS session_tools (
    session_id   TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    tool         TEXT NOT NULL,
    invocations  INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (session_id, tool)
);

-- Per-subagent (fleet) facts; informational only and not summed into session_totals to avoid double counting.
CREATE TABLE IF NOT EXISTS session_subagents (
    session_id         TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    tool_call_id       TEXT NOT NULL,
    agent_name         TEXT,
    agent_display_name TEXT,
    model              TEXT,
    total_tokens       BIGINT DEFAULT 0,
    total_tool_calls   INTEGER DEFAULT 0,
    duration_ms        BIGINT DEFAULT 0,
    started_at         TIMESTAMPTZ,
    completed_at       TIMESTAMPTZ,
    PRIMARY KEY (session_id, tool_call_id)
);

-- Per-model AI Credit pricing (published GitHub Copilot list prices, per 1M tokens).
-- Keyed by the CLI model string exactly as it appears in session_models.model.
-- Seed data lives in 02-seed-pricing.sql (initdb) and migrations/003-ai-credits.sql.
-- Estimates are GROSS list-price only: they ignore the 10% auto-model discount,
-- included monthly allowances, and long-context tier surcharges (see docs/ai-credits.md).
CREATE TABLE IF NOT EXISTS model_pricing (
    model                 TEXT PRIMARY KEY,  -- matches session_models.model
    display_name          TEXT,
    vendor                TEXT,
    input_per_mtok        DOUBLE PRECISION NOT NULL DEFAULT 0,
    cached_input_per_mtok DOUBLE PRECISION NOT NULL DEFAULT 0,
    cache_write_per_mtok  DOUBLE PRECISION NOT NULL DEFAULT 0,  -- Anthropic only; 0 elsewhere
    output_per_mtok       DOUBLE PRECISION NOT NULL DEFAULT 0,
    pricing_confidence    TEXT NOT NULL DEFAULT 'exact',          -- exact | approximate
    source                TEXT NOT NULL DEFAULT 'official_seed',  -- official_seed | local_override
    note                  TEXT
);

-- Per session+model estimated cost. The CLI normalizes token metrics so that
-- input_tokens is the TOTAL prompt (cache_read + cache_write are subsets) and
-- output_tokens already INCLUDES reasoning_tokens (verified against the data).
-- We therefore bill non-cached input + cached read + cache write + total output,
-- and never re-add reasoning_tokens, to avoid double counting. usd is NULL for
-- models with no pricing row so unpriced usage is never silently counted as $0.
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

-- One row per session: estimated gross cost plus transparency on unpriced usage.
CREATE OR REPLACE VIEW session_credits AS
SELECT
    c.session_id,
    SUM(c.usd)     AS est_usd,      -- NULL contributions (unpriced) are ignored by SUM
    SUM(c.credits) AS est_credits,
    bool_and(c.priced) AS complete_pricing,
    COALESCE(string_agg(DISTINCT CASE WHEN NOT c.priced THEN c.model END, ', '), '') AS unpriced_models,
    COALESCE(SUM(CASE WHEN NOT c.priced THEN c.input_tokens + c.output_tokens ELSE 0 END), 0) AS unpriced_tokens
FROM session_model_credits c
GROUP BY c.session_id;

-- Convenience view: one row per session with summed token totals.
CREATE OR REPLACE VIEW session_totals AS
SELECT
    s.session_id,
    s.start_time,
    s.end_time,
    s.cwd,
    s.cli_version,
    s.selected_model,
    s.project,
    s.project_source,
    s.premium_requests,
    s.premium_cost,
    s.complete,
    COALESCE(SUM(m.input_tokens), 0)        AS input_tokens,
    COALESCE(SUM(m.output_tokens), 0)       AS output_tokens,
    COALESCE(SUM(m.cache_read_tokens), 0)   AS cache_read_tokens,
    COALESCE(SUM(m.cache_write_tokens), 0)  AS cache_write_tokens,
    COALESCE(SUM(m.reasoning_tokens), 0)    AS reasoning_tokens,
    COALESCE(SUM(m.input_tokens + m.output_tokens + m.cache_read_tokens
                 + m.cache_write_tokens + m.reasoning_tokens), 0) AS total_tokens
FROM sessions s
LEFT JOIN session_models m ON m.session_id = s.session_id
GROUP BY s.session_id;

CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start_time);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);
CREATE INDEX IF NOT EXISTS idx_session_models_model ON session_models(model);
CREATE INDEX IF NOT EXISTS idx_session_skills_skill ON session_skills(skill);
CREATE INDEX IF NOT EXISTS idx_session_subagents_agent ON session_subagents(agent_name);
CREATE INDEX IF NOT EXISTS idx_session_subagents_model ON session_subagents(model);
