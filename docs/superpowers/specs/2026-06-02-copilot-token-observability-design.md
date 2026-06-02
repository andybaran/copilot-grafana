# Copilot CLI Token Observability — Design

**Date:** 2026-06-02
**Status:** Approved-by-delegation (user unavailable; building autonomously, pending later review)
**Author:** Copilot CLI session

## Problem

I (an individual contributor) want to understand my own GitHub Copilot CLI token-usage
patterns over time so I can self-regulate and advise customers when token budgets tighten.
I need:

- **Per-session** token usage (input / output / cache / reasoning).
- Which **models** were used in each session.
- Which **skills** were used in each session.
- **Trends across many sessions** over time.
- A **local Grafana** stack that starts at login. No data leaves my machine.
- **OpenTelemetry** included (Copilot CLI emits OTel natively, like VS Code agent monitoring).

## Key findings (validated)

1. **Copilot CLI v1.0.57 has native OpenTelemetry export** (`copilot help monitoring`).
   Activated by env vars (`COPILOT_OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, or
   `COPILOT_OTEL_FILE_EXPORTER_PATH`). Signals follow OTel GenAI semantic conventions.

   Validated by capturing real output from a headless run:
   - **Spans**: `invoke_agent` (carries `gen_ai.conversation.id` = session id,
     `gen_ai.request.model`, `gen_ai.agent.version` = CLI version,
     `github.copilot.context.skills`) and `chat <model>` (per-call
     `gen_ai.usage.input_tokens` / `output_tokens` / `cache_creation.input_tokens`,
     `github.copilot.cost`, `github.copilot.turn_id`).
   - **Metrics**: `gen_ai.client.token.usage` (histogram, labels:
     `gen_ai.token.type`, `gen_ai.request.model`), `gen_ai.client.operation.duration`,
     `github.copilot.agent.turn.count`, `github.copilot.tool.call.count/duration`,
     `github.copilot.mcp.server.connection.count`.
   - **Critical constraint**: the token-usage *metric* has **no session-id label**
     (aggregate by model only). **Per-session detail must come from traces.**

2. **Historical data exists locally** in `~/.copilot/session-state/<id>/events.jsonl`.
   The `session.shutdown` event has a full `modelMetrics` block (per-model
   input/output/cache/reasoning tokens, premium request cost, duration) and
   `skill.invoked` events list skills used. 405 session files exist; ~275 (~68%)
   contain the complete shutdown summary. This enables **day-one historical trends**.
   (The local `session-store.db` SQLite DB does NOT contain token data.)

3. **Runtime**: host uses **podman** (5.7.1, libkrun machine, 6 CPU / 3.7 GiB),
   aliased as `docker`, with `podman-compose`. Affects autostart (needs
   `podman machine start`) and container→host networking
   (`host.containers.internal`).

## Architecture

Two pipelines with **distinct, non-overlapping responsibilities** feed one Grafana.
This split (revised after design critique) deliberately avoids double-counting: the
two pipelines are never summed together.

### Canonical data model (source-of-truth rules)

- **Per-session totals, skills, models** → the **Postgres** store, populated from
  `events.jsonl` (`session.shutdown.modelMetrics` is authoritative). This powers the
  per-session, skills, models AND long-term trend dashboards.
- **Live/operational "what's happening now"** → **Prometheus**, populated from live
  OTel metrics. Used only for the real-time view; **never** summed with Postgres for
  historical accounting.
- Sessions are marked `complete` (have a `session.shutdown` summary) or not. Incomplete
  sessions appear in tables but are **excluded from trend totals by default**.

### Pipeline A — Live OTel (real-time, standard semconv) — the "include OpenTelemetry" requirement

```
copilot CLI ──OTLP/HTTP 127.0.0.1:4318──▶ otel-collector ──▶ Prometheus (live metrics)
   (env vars)                                   └······▶ Tempo (traces, OPTIONAL profile)
```

- **Instrumentation**: env vars exported in the shell so every `copilot` run ships
  OTLP to the local collector at `http://localhost:4318`. Content capture stays **OFF**
  (prompts/code/secrets would otherwise be captured).
- **otel-collector** (contrib): `otlp` receiver → `prometheus` exporter (scraped by
  Prometheus); optional `otlp` exporter → Tempo.
- **Prometheus**: live aggregate operational metrics — tokens by model & token type,
  operation durations, turns, tool calls (real-time only).
- **Tempo** (optional `traces` compose profile): per-session live trace drill-down keyed
  by `gen_ai.conversation.id`. Default `up` is lean; enable with `--profile traces`.

### Pipeline B — Per-session facts & history (batch) — the analytical source of truth

```
~/.copilot/session-state/*/events.jsonl ──▶ parser.py ──(idempotent upsert)──▶ Postgres
```

- A Python parser reads every `events.jsonl`, upserting per-session facts keyed by
  `session_id` (re-runnable, no duplication). Tables:
  - `sessions(session_id, start_time, end_time, cwd, cli_version, selected_model,
    premium_requests, premium_cost, api_duration_ms, lines_added, lines_removed,
    complete, source)`
  - `session_models(session_id, model, input_tokens, output_tokens, cache_read_tokens,
    cache_write_tokens, reasoning_tokens, requests, cost)`
  - `session_skills(session_id, skill, invocations)`
  - `session_tools(session_id, tool, invocations)`
- Covers all ~405 sessions (marking ~130 incomplete). Postgres is a **first-class
  Grafana datasource (no plugin)**; upsert is naturally idempotent — no TSDB block
  surgery, staleness, or backfill caveats.
- A scheduled run (cron/launchd) keeps it current as sessions finish.

### Grafana

Provisioned datasources (Postgres + Prometheus; Tempo when profile enabled) and dashboards:

1. **Token Trends** (Postgres SQL) — tokens/day & /week by model and token type
   (input/output/cache/reasoning), premium requests, code-change volume. Finalized
   sessions only.
2. **Per-Session Explorer** (Postgres SQL) — table of sessions (tokens, models, skills,
   premium cost, duration, `complete` flag); drill to Tempo trace when running.
3. **Skills & Models** (Postgres SQL) — skill/model usage counts over time; tokens
   correlated by skill and model.
4. **Live OTel (operational)** (Prometheus) — real-time metrics for the current/active
   sessions; clearly labeled as operational, not historical accounting.

### Startup at login (macOS / podman)

A `launchd` user agent (`~/Library/LaunchAgents/com.user.copilot-observability.plist`)
runs at login: ensures `podman machine start`, then `podman-compose up -d` in the repo.
Containers use `restart: unless-stopped`. A `Makefile` wraps up/down/backfill/install.

## Components / boundaries

| Unit | Responsibility | Interface | Depends on |
|------|----------------|-----------|------------|
| `compose.yaml` | Orchestrate containers (Tempo behind `traces` profile) | podman-compose | podman machine |
| `otelcol/config.yaml` | Receive OTLP, fan out to Prometheus (+Tempo) | OTLP in `127.0.0.1:4317/4318`; Prom scrape + OTLP out | — |
| `prometheus/prometheus.yml` | Scrape + store LIVE metrics only | :9090 | collector |
| `tempo/tempo.yaml` | Store/query traces (optional) | :3200, OTLP in | collector |
| `postgres` (+`initdb`) | Per-session facts store | :5432 SQL | — |
| `grafana/provisioning/*` | Datasources + dashboards | :3000 | Postgres, Prom, Tempo |
| `backfill/parser.py` | events.jsonl → Postgres upsert | CLI script | session-state files, Postgres |
| `scripts/instrument.sh` | Shell env snippet for OTLP | sourced in profile | collector port |
| `launchd plist` + `Makefile` | Autostart + ops | `make install/up/down/backfill` | compose |

## Privacy / security

- All data stays local; no exporter targets leave `localhost`.
- **Content capture disabled** — only metadata (token counts, model names, skill names,
  durations) is collected, never prompts, code, or secrets.
- Note: existing CLI logs were observed to contain an MCP credential; this project does
  not ingest `logs/` and does not surface secrets.

## Testing / verification

- Bring the stack up; assert each container healthy (HTTP probes on 3000/9090/3200/4318).
- Run a headless `copilot -p` with OTLP env pointed at the collector; assert
  Prometheus shows `gen_ai_client_token_usage_*` series and Tempo has a trace for the
  new `conversation.id`.
- Run the backfill; assert per-session + skills series exist for historical sessions.
- Load Grafana; assert all three dashboards render panels with data.

## Out of scope (YAGNI)

- Multi-user / team aggregation, alerting, cost-dollar conversion beyond premium-request
  counts, long-term retention tuning, and shipping anything off-box.
