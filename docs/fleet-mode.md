# Fleet mode (subagent) observability

This stack captures **GitHub Copilot CLI fleet/subagent activity** so you can see how much
of your token usage is driven by parallel agents (`/fleet`, the `Task` tool, `explore`,
`code-review`, `research`, etc.) rather than the main conversation.

## TL;DR

- Fleet/subagent **token totals are already counted** in your session totals — subagent token
  usage is rolled up into the parent session's `session.shutdown` model metrics, so the
  numbers on the Token Trends / Per-Session / Skills & Models dashboards already include
  fleet work.
- What was previously **invisible** is the *per-subagent breakdown*: how many subagents ran,
  which agent types, which models, how many tokens and tool calls each used, and how long
  they took. That is now captured in the **`session_subagents`** table and visualized on the
  **"Copilot — Fleet (Subagents)"** dashboard.
- To avoid double counting, `session_subagents` is **informational only** — it is never
  summed into `session_totals`.

## What "fleet mode" looks like in the data

Subagents run *inside* their parent session (they do not get their own `events.jsonl`
directory). Each one produces two events in the parent session's
`~/.copilot/session-state/<id>/events.jsonl`:

```jsonc
// when a subagent is launched
{ "type": "subagent.started",   "data": { "toolCallId": "toolu_…", "agentName": "general-purpose",
                                          "agentDisplayName": "General Purpose Agent" }, "timestamp": "…" }

// when it finishes — authoritative for tokens/model/duration
{ "type": "subagent.completed", "data": { "toolCallId": "toolu_…", "agentName": "general-purpose",
                                          "model": "gpt-5.5", "totalTokens": 1784703,
                                          "totalToolCalls": 51, "durationMs": 494635 }, "timestamp": "…" }
```

The two events are correlated by `toolCallId`.

## Data model: `session_subagents`

The parser (`backfill/parser.py`) writes one row per subagent launch, keyed by
`(session_id, tool_call_id)`. Like the other child tables it is rewritten with a
delete-then-insert on every backfill, so re-runs are idempotent.

| Column               | Source                         | Notes                                              |
|----------------------|--------------------------------|----------------------------------------------------|
| `session_id`         | parent session                 | FK → `sessions(session_id)`                         |
| `tool_call_id`       | `data.toolCallId`              | natural key linking `started`/`completed`          |
| `agent_name`         | `data.agentName`               | e.g. `general-purpose`, `explore`, `code-review`   |
| `agent_display_name` | `data.agentDisplayName`        | human-friendly label                               |
| `model`              | `data.model` (completed)       | `NULL` if the subagent never completed             |
| `total_tokens`       | `data.totalTokens` (completed) | `0` if not completed                               |
| `total_tool_calls`   | `data.totalToolCalls`          | `0` if not completed                               |
| `duration_ms`        | `data.durationMs`              | milliseconds                                        |
| `started_at`         | `subagent.started` timestamp   | `NULL` if only a completed event was seen          |
| `completed_at`       | `subagent.completed` timestamp | `NULL` for still-running / aborted subagents       |

> **Do not join `session_subagents` into `session_totals` or sum the two.** Subagent tokens
> are already included in `session_models` via the parent `session.shutdown` summary. This
> table exists purely to *attribute* that usage, not to add to it.

## The dashboard

Open Grafana (http://localhost:3000) → **Copilot Usage** folder → **Copilot — Fleet
(Subagents)** (`uid: copilot-fleet`). It is filtered by the same **Project** and time-range
variables as the other dashboards and includes:

- **Stats** — total subagents launched, total subagent tokens, average subagent duration.
- **Subagents by Agent Type** — launches per `agent_name`.
- **Subagent Tokens by Model** — tokens per `model`.
- **Subagents Launched per Day** — stacked-bar trend by agent type.
- **Top Fleet Sessions** — which sessions spawned the most subagents / tokens.
- **Subagent Detail** — per agent type + model breakdown (launches, tokens, avg duration, tool calls).

### Useful ad-hoc queries

```sql
-- Share of tokens spent in subagents vs. the parent session, per session
SELECT t.session_id, t.project, t.total_tokens AS session_tokens,
       COALESCE(SUM(a.total_tokens), 0) AS subagent_tokens
FROM session_totals t
LEFT JOIN session_subagents a ON a.session_id = t.session_id
GROUP BY t.session_id, t.project, t.total_tokens
ORDER BY subagent_tokens DESC
LIMIT 25;

-- Most expensive agent types overall
SELECT agent_name, COUNT(*) AS launches, SUM(total_tokens) AS tokens
FROM session_subagents
WHERE completed_at IS NOT NULL
GROUP BY agent_name
ORDER BY tokens DESC;
```

## "I launched fleet tasks but see no metrics"

Two legitimate reasons a fleet-heavy session can still show **zero** tokens — both are about
the **History** pipeline, which only trusts the `session.shutdown` summary:

1. **The session hasn't shut down yet.** A session with no `session.shutdown` event is
   recorded with `complete = FALSE` and zero token totals (it still contributes skills/tools).
   A long-running session with dozens of active subagents will report nothing until it exits.
   Re-run `make backfill` after the session ends.
2. **Multiple shutdown summaries (fixed).** Some sessions emit more than one
   `session.shutdown`, and a trailing one can carry an *empty* `modelMetrics`. The parser used
   to take the last summary (last-wins), which zeroed out the entire session. It now keeps the
   **richest** shutdown (the one with the most tokens) while still using the latest shutdown
   timestamp for `end_time`. Re-run `make backfill` to repair previously-zeroed sessions.

## Applying this to an existing database

`session_subagents` is created automatically on a fresh Postgres volume. For an existing
database, apply the migration and re-ingest once:

```bash
make migrate      # creates session_subagents (idempotent)
make backfill     # populates subagents + repairs multi-shutdown sessions
```

> **Note for parser changes:** the backfill image bakes `parser.py` via `COPY`, so a plain
> `make backfill` reuses the cached image. After editing `backfill/parser.py`, rebuild first:
>
> ```bash
> docker compose build backfill   # or: COMPOSE="docker compose" — podman build backfill
> make backfill
> ```

## Privacy

No new data classes are collected. `session_subagents` holds only metadata already present in
`events.jsonl` — agent type, model name, token counts, tool-call counts, and durations. No
prompts, code, or secrets.
