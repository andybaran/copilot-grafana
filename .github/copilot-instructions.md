# Copilot CLI Token Observability

A fully-local Grafana stack for analyzing **GitHub Copilot CLI token usage**. There is no
application code to "build" — this repo is a compose stack plus a Python parser and
provisioned Grafana assets. Nothing leaves the machine; all ports bind to `127.0.0.1`.

## Operating the stack

Everything is driven by the `Makefile` (wraps `docker-compose`; override the engine with
`make COMPOSE="docker compose"` — podman is the default tested engine).

- `make up` — start core services (postgres, otel-collector, prometheus, grafana).
- `make traces` — start core stack **plus** Tempo (the `traces` compose profile).
- `make backfill` — run the parser one-shot (the `tools` profile) to ingest session history.
- `make migrate` — apply idempotent SQL migrations in `postgres/migrations/` to a running db
  (needed because `initdb` only runs on a fresh postgres volume).
- `make psql` — open a psql shell to `copilot_usage`.
- `make down` / `make logs` / `make ps` / `make urls` — stop, tail, status, endpoints.
- `make install` / `make uninstall` — launchd auto-start at login (renders templates in
  `scripts/` and `launchd/`).

There is no test suite, linter, or CI. Validate changes by running the relevant service and
checking its output (e.g. `make backfill`, then `make psql` to inspect rows, or open a
dashboard at http://localhost:3000).

## Architecture: two independent pipelines, one Grafana

The defining design constraint: **two pipelines feed Grafana and must never be summed
together** (doing so double-counts tokens).

- **Pipeline B — History (source of truth for token totals).**
  `~/.copilot/session-state/<id>/events.jsonl` → `backfill/parser.py` → Postgres → Grafana
  (Postgres datasource). The `session.shutdown` event's `modelMetrics` block carries the
  authoritative per-model token totals. This pipeline powers per-session, skills, models, and
  trend dashboards.
- **Pipeline A — Live OTel (operational only).**
  `copilot` CLI → OTLP → `otel-collector` → Prometheus (+ optional Tempo) → Grafana
  (Prometheus datasource). Treated as real-time/operational; never used for authoritative
  totals.

Data flow files: `compose.yaml` (services), `otelcol/config.yaml` (OTLP in →
Prometheus exporter on :8889 + Tempo), `prometheus/prometheus.yml` (scrapes the collector),
`scripts/instrument.sh` (host shell env that enables CLI OTel export).

## Conventions specific to this repo

- **Parser idempotency.** `backfill/parser.py` must stay safe to re-run. It upserts the
  `sessions` row, then **deletes and re-inserts** child rows (`session_models`,
  `session_skills`, `session_tools`) so re-runs converge. Preserve this delete-then-insert
  pattern when adding child tables.
- **Authoritative totals come only from `session.shutdown`.** Sessions without a shutdown
  summary are written with `complete = FALSE` and zero token totals (they still contribute
  skills/tools). Don't derive token totals from other event types.
- **Schema + token math live in SQL.** `postgres/initdb/01-schema.sql` defines the tables and
  the `session_totals` view. "Total tokens" = input + output + cache_read + cache_write +
  reasoning, summed in that view. Dashboards should query `session_totals` rather than
  re-implementing the sum. Note: `initdb` scripts only run on a fresh volume — schema changes
  require recreating the postgres volume (or applying migrations manually via `make psql`).
- **Privacy is a hard requirement.** Keep
  `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT="false"` in `scripts/instrument.sh` and
  all published ports bound to `127.0.0.1`. Only metadata (token counts, model/skill names,
  durations) is collected — never prompts, code, or secrets.
- **OTel naming follows GenAI semantic conventions.** Live metrics/attributes use `gen_ai.*`
  names (e.g. `gen_ai_client_token_usage_sum`, `gen_ai_request_model`, `gen_ai_token_type`).
  Match these when editing the Live OTel dashboard or collector config.
- **Grafana is fully provisioned from files** under `grafana/provisioning/` (datasources,
  dashboard provider) and `grafana/dashboards/*.json`. Datasources are referenced by stable
  UIDs `copilot-postgres`, `copilot-prometheus`, `copilot-tempo` — keep these UIDs stable so
  existing dashboard panels keep resolving. Dashboards land in the "Copilot Usage" folder.
- **Project attribution is resolved once, at CLI launch, and shared by both pipelines.** The
  `copilot` shell function in `scripts/instrument.sh` resolves a project name by precedence
  (`COPILOT_PROJECT` env → `.copilot-project` file in cwd → git repo basename → cwd basename →
  `unknown`), normalizes it (`[A-Za-z0-9._-]`, ≤80 chars), attaches it to live OTel as a
  `project` resource attribute (→ Prometheus label), and writes a record to the sidecar
  `~/.copilot/session-state/project-tags.jsonl` keyed to the resolved session id. The history
  parser reads that sidecar as authoritative and only falls back to deterministic
  cwd-basename derivation for untagged/legacy sessions — it never re-reads the working tree,
  keeping backfill time-stable. The normalization + guardrail logic is duplicated in bash
  (`instrument.sh`) and Python (`parser.py`); keep the two in sync if you change either.

## Reference

The full design rationale (validated OTel signal shapes, the no-double-counting decision) is
in `docs/superpowers/specs/2026-06-02-copilot-token-observability-design.md`.
