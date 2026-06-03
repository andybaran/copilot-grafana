-- Migration 002: per-session subagent facts.
-- Idempotent: safe to apply to an existing copilot_usage database where the
-- initdb schema (01-schema.sql) ran before session_subagents existed.
-- session_subagents is informational only; it is not summed into session_totals
-- to avoid double counting fleet token usage already rolled into session_models.
-- Apply with: make migrate

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

CREATE INDEX IF NOT EXISTS idx_session_subagents_agent ON session_subagents(agent_name);
CREATE INDEX IF NOT EXISTS idx_session_subagents_model ON session_subagents(model);
