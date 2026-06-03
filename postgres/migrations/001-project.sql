-- Migration 001: per-session project attribution.
-- Idempotent: safe to apply to an existing copilot_usage database where the
-- initdb schema (01-schema.sql) ran before project columns existed.
-- Apply with: make migrate

ALTER TABLE sessions ADD COLUMN IF NOT EXISTS project        TEXT;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS project_source TEXT;  -- env | file | git | cwd | unknown | sidecar

CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);

-- Recreate the convenience view so it exposes the new columns. CREATE OR REPLACE
-- cannot reorder/insert columns, so drop first (the view holds no data).
DROP VIEW IF EXISTS session_totals;
CREATE VIEW session_totals AS
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
