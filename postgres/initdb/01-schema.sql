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
