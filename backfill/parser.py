#!/usr/bin/env python3
"""Parse Copilot CLI session event logs into Postgres.

Reads every ``<SESSION_STATE_DIR>/<id>/events.jsonl`` and upserts per-session facts:
tokens by model, premium cost, duration, skills used, and tools used.

The ``session.shutdown`` event's ``modelMetrics`` block is the authoritative source for
token totals. Sessions without a shutdown summary are recorded with ``complete = FALSE``
and zero token totals (they still contribute skills/tools).

Idempotent: re-running re-derives each session and replaces its rows.
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras


_PROJECT_ALLOWED = re.compile(r"[^A-Za-z0-9._-]")
_NON_PROJECT_ROOTS = {"", "/", "/tmp", "/private/tmp"}


def normalize_project(value):
    """Match scripts/instrument.sh: first line, trimmed, [A-Za-z0-9._-] only,
    collapsed dashes, max 80 chars. Returns '' when nothing usable remains."""
    if not value:
        return ""
    first = value.splitlines()[0].strip() if value.splitlines() else ""
    cleaned = _PROJECT_ALLOWED.sub("-", first)
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned[:80]


def derive_project_from_cwd(cwd):
    """Deterministic fallback for sessions without an explicit tag: the basename
    of the working directory, with guardrails for non-project roots. No filesystem
    access (the cwd is an opaque host path inside the backfill container)."""
    if not cwd:
        return "unknown", "unknown"
    path = cwd.rstrip("/")
    parts = path.split("/")
    if path in _NON_PROJECT_ROOTS or (len(parts) == 3 and parts[1] in ("Users", "home")):
        return "unknown", "unknown"
    name = normalize_project(parts[-1])
    return (name, "cwd") if name else ("unknown", "unknown")


def load_project_tags(path):
    """Read the launch-time sidecar (one JSON object per line) into
    {session_id: (project, source)}. Last record for a session wins."""
    tags = {}
    if not path or not os.path.exists(path):
        return tags
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            sid = rec.get("session_id")
            if not sid:
                continue
            name = normalize_project(rec.get("project") or "")
            if name:
                tags[sid] = (name, "sidecar")
    return tags



def parse_iso(value):
    """Parse an ISO-8601 timestamp string into an aware datetime, or None."""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def ms_to_dt(value):
    try:
        return datetime.fromtimestamp(float(value) / 1000.0, tz=timezone.utc)
    except (TypeError, ValueError):
        return None


def parse_session(path, dir_session_id):
    """Return a dict describing one session, or None if no usable events."""
    session = {
        "session_id": dir_session_id,
        "start_time": None,
        "end_time": None,
        "cwd": None,
        "cli_version": None,
        "selected_model": None,
        "project": None,
        "project_source": None,
        "premium_requests": 0,
        "premium_cost": 0.0,
        "api_duration_ms": 0,
        "lines_added": 0,
        "lines_removed": 0,
        "complete": False,
        "models": {},  # model -> token dict
        "skills": defaultdict(int),
        "tools": defaultdict(int),
        "subagents": {},  # tool_call_id -> subagent facts
    }
    saw_event = False
    last_ts = None
    best_shutdown_token_sum = -1

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            saw_event = True
            etype = evt.get("type")
            data = evt.get("data") or {}
            ts = parse_iso(evt.get("timestamp"))
            if ts:
                last_ts = ts

            if etype == "session.start":
                session["session_id"] = data.get("sessionId") or dir_session_id
                session["cli_version"] = data.get("copilotVersion")
                session["selected_model"] = data.get("selectedModel")
                st = parse_iso(data.get("startTime"))
                if st:
                    session["start_time"] = st
                ctx = data.get("context") or {}
                session["cwd"] = ctx.get("cwd")

            elif etype == "skill.invoked":
                name = data.get("name")
                if name:
                    session["skills"][name] += 1

            elif etype == "tool.execution_start":
                tool = data.get("toolName")
                if tool:
                    session["tools"][tool] += 1

            elif etype == "subagent.started":
                tool_call_id = data.get("toolCallId")
                if tool_call_id:
                    subagent = session["subagents"].setdefault(tool_call_id, {})
                    subagent.setdefault("agent_name", data.get("agentName"))
                    subagent.setdefault("agent_display_name", data.get("agentDisplayName"))
                    subagent["started_at"] = ts

            elif etype == "subagent.completed":
                tool_call_id = data.get("toolCallId")
                if tool_call_id:
                    subagent = session["subagents"].setdefault(tool_call_id, {})
                    subagent.update({
                        "agent_name": data.get("agentName"),
                        "agent_display_name": data.get("agentDisplayName"),
                        "model": data.get("model"),
                        "total_tokens": int(data.get("totalTokens") or 0),
                        "total_tool_calls": int(data.get("totalToolCalls") or 0),
                        "duration_ms": int(data.get("durationMs") or 0),
                        "completed_at": ts,
                    })

            elif etype == "session.shutdown":
                session["complete"] = True
                if ts and (not session["end_time"] or ts > session["end_time"]):
                    session["end_time"] = ts

                metrics = data.get("modelMetrics") or {}
                total_cost = 0.0
                token_sum = 0
                models = {}
                for model, mdata in metrics.items():
                    usage = mdata.get("usage") or {}
                    reqs = mdata.get("requests") or {}
                    input_tokens = int(usage.get("inputTokens") or 0)
                    output_tokens = int(usage.get("outputTokens") or 0)
                    cache_read_tokens = int(usage.get("cacheReadTokens") or 0)
                    cache_write_tokens = int(usage.get("cacheWriteTokens") or 0)
                    reasoning_tokens = int(usage.get("reasoningTokens") or 0)
                    cost = float(reqs.get("cost") or 0)
                    token_sum += (
                        input_tokens + output_tokens + cache_read_tokens
                        + cache_write_tokens + reasoning_tokens
                    )
                    total_cost += cost
                    models[model] = {
                        "input_tokens": input_tokens,
                        "output_tokens": output_tokens,
                        "cache_read_tokens": cache_read_tokens,
                        "cache_write_tokens": cache_write_tokens,
                        "reasoning_tokens": reasoning_tokens,
                        "requests": int(reqs.get("count") or 0),
                        "cost": cost,
                    }

                if token_sum > best_shutdown_token_sum:
                    best_shutdown_token_sum = token_sum
                    session["premium_requests"] = int(data.get("totalPremiumRequests") or 0)
                    session["api_duration_ms"] = int(data.get("totalApiDurationMs") or 0)
                    changes = data.get("codeChanges") or {}
                    session["lines_added"] = int(changes.get("linesAdded") or 0)
                    session["lines_removed"] = int(changes.get("linesRemoved") or 0)
                    if not session["start_time"]:
                        session["start_time"] = ms_to_dt(data.get("sessionStartTime"))
                    session["models"] = models
                    session["premium_cost"] = total_cost

    if not saw_event:
        return None
    if not session["end_time"]:
        session["end_time"] = last_ts
    return session


UPSERT_SESSION = """
INSERT INTO sessions (session_id, start_time, end_time, cwd, cli_version,
    selected_model, project, project_source, premium_requests, premium_cost,
    api_duration_ms, lines_added, lines_removed, complete, source, updated_at)
VALUES (%(session_id)s, %(start_time)s, %(end_time)s, %(cwd)s, %(cli_version)s,
    %(selected_model)s, %(project)s, %(project_source)s, %(premium_requests)s,
    %(premium_cost)s, %(api_duration_ms)s,
    %(lines_added)s, %(lines_removed)s, %(complete)s, 'events_jsonl', now())
ON CONFLICT (session_id) DO UPDATE SET
    start_time = EXCLUDED.start_time,
    end_time = EXCLUDED.end_time,
    cwd = EXCLUDED.cwd,
    cli_version = EXCLUDED.cli_version,
    selected_model = EXCLUDED.selected_model,
    project = EXCLUDED.project,
    project_source = EXCLUDED.project_source,
    premium_requests = EXCLUDED.premium_requests,
    premium_cost = EXCLUDED.premium_cost,
    api_duration_ms = EXCLUDED.api_duration_ms,
    lines_added = EXCLUDED.lines_added,
    lines_removed = EXCLUDED.lines_removed,
    complete = EXCLUDED.complete,
    updated_at = now();
"""


def write_session(cur, s):
    sid = s["session_id"]
    cur.execute(UPSERT_SESSION, s)
    # Replace child rows so re-runs stay consistent.
    cur.execute("DELETE FROM session_models WHERE session_id = %s", (sid,))
    cur.execute("DELETE FROM session_skills WHERE session_id = %s", (sid,))
    cur.execute("DELETE FROM session_tools WHERE session_id = %s", (sid,))
    cur.execute("DELETE FROM session_subagents WHERE session_id = %s", (sid,))

    if s["models"]:
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO session_models (session_id, model, input_tokens,
               output_tokens, cache_read_tokens, cache_write_tokens,
               reasoning_tokens, requests, cost) VALUES %s""",
            [(sid, m, d["input_tokens"], d["output_tokens"], d["cache_read_tokens"],
              d["cache_write_tokens"], d["reasoning_tokens"], d["requests"], d["cost"])
             for m, d in s["models"].items()],
        )
    if s["skills"]:
        psycopg2.extras.execute_values(
            cur,
            "INSERT INTO session_skills (session_id, skill, invocations) VALUES %s",
            [(sid, k, v) for k, v in s["skills"].items()],
        )
    if s["tools"]:
        psycopg2.extras.execute_values(
            cur,
            "INSERT INTO session_tools (session_id, tool, invocations) VALUES %s",
            [(sid, k, v) for k, v in s["tools"].items()],
        )
    if s["subagents"]:
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO session_subagents (session_id, tool_call_id,
               agent_name, agent_display_name, model, total_tokens,
               total_tool_calls, duration_ms, started_at, completed_at) VALUES %s""",
            [(sid, tool_call_id, d.get("agent_name"), d.get("agent_display_name"),
              d.get("model"), d.get("total_tokens", 0),
              d.get("total_tool_calls", 0), d.get("duration_ms", 0),
              d.get("started_at"), d.get("completed_at"))
             for tool_call_id, d in s["subagents"].items()],
        )


def main():
    root = os.environ.get("SESSION_STATE_DIR", "/data/session-state")
    paths = sorted(glob.glob(os.path.join(root, "*", "events.jsonl")))
    if not paths:
        print(f"No events.jsonl found under {root}", file=sys.stderr)
        return 1

    tags_path = os.environ.get(
        "PROJECT_TAGS_FILE", os.path.join(root, "project-tags.jsonl")
    )
    project_tags = load_project_tags(tags_path)

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "postgres"),
        port=os.environ.get("PGPORT", "5432"),
        user=os.environ.get("PGUSER", "copilot"),
        password=os.environ.get("PGPASSWORD", "copilot"),
        dbname=os.environ.get("PGDATABASE", "copilot_usage"),
    )
    conn.autocommit = False
    processed = complete = 0
    try:
        with conn.cursor() as cur:
            for path in paths:
                dir_session_id = os.path.basename(os.path.dirname(path))
                try:
                    s = parse_session(path, dir_session_id)
                except OSError as exc:
                    print(f"skip {path}: {exc}", file=sys.stderr)
                    continue
                if not s:
                    continue
                tagged = project_tags.get(s["session_id"])
                if tagged:
                    s["project"], s["project_source"] = tagged
                else:
                    s["project"], s["project_source"] = derive_project_from_cwd(s["cwd"])
                write_session(cur, s)
                conn.commit()
                processed += 1
                complete += 1 if s["complete"] else 0
    finally:
        conn.close()

    print(f"Processed {processed} sessions ({complete} complete, "
          f"{processed - complete} incomplete).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
