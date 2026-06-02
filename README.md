# Copilot CLI Token Observability

A fully-local Grafana stack for understanding your **GitHub Copilot CLI token usage** —
per session, per model, per skill, and as trends over time. Nothing leaves your machine.

## Why

Token budgets are loose today but likely to tighten. This stack lets an individual
contributor see their own usage patterns so they can self-regulate and advise others.

## What you get

- **Per-session** token usage (input / output / cache / reasoning), models, and skills used.
- **Trends** across all your sessions over time.
- **Native OpenTelemetry** ingestion (the CLI emits OTel directly, like VS Code agent
  monitoring) for a real-time operational view.
- Four Grafana dashboards: Token Trends, Per-Session Explorer, Skills & Models,
  and Live OTel.

## How it works

Two pipelines with separate jobs feed one Grafana (they are never summed together):

| Pipeline | Source | Store | Purpose |
|----------|--------|-------|---------|
| **A — Live OTel** | `copilot` CLI → OTLP | Prometheus (+ optional Tempo) | Real-time / operational |
| **B — History** | `~/.copilot/session-state/*/events.jsonl` | Postgres | Per-session + skills + trends (source of truth) |

The `session.shutdown` event in each session's `events.jsonl` carries authoritative
per-model token totals; the parser upserts those into Postgres. Live OTel metrics are
treated as operational only, so the two never double-count.

```
copilot CLI ──OTLP──▶ otel-collector ──▶ Prometheus ─┐
                            └······▶ Tempo (optional) │
events.jsonl ──▶ parser.py ──▶ Postgres ──────────────┴──▶ Grafana
```

## Quick start

Requires podman (or Docker) with compose.

```bash
# 1. Start the stack
make up

# 2. Load your existing session history into Postgres
make backfill

# 3. Turn on live OTel for future copilot runs
echo 'source '"$PWD"'/scripts/instrument.sh' >> ~/.zshrc
source scripts/instrument.sh

# 4. Open Grafana
open http://localhost:3000      # dashboards under the "Copilot Usage" folder
```

Run `make help` for all targets, `make urls` for service endpoints.

## Attributing usage to a project

Every session is tagged with a **project** so you can filter and group dashboards by it
(there's a `Project` variable at the top of each dashboard) instead of only by time.

The project name is resolved when you launch `copilot`, in this order:

1. `COPILOT_PROJECT` env var — highest precedence. Prefer the one-shot form so it doesn't
   stick to unrelated sessions: `COPILOT_PROJECT=my-thing copilot`.
2. A `.copilot-project` file in the working directory (its first line names the project).
3. The enclosing git repository's name.
4. The working directory's name.
5. `unknown` (for non-project locations like `$HOME` or `/tmp`).

The resolved name is attached to live OTel metrics (as a `project` Prometheus label) and
recorded to a sidecar (`~/.copilot/session-state/project-tags.jsonl`) that the history parser
reads, so both pipelines agree. Resolution happens via the `copilot` shell function added by
`scripts/instrument.sh` — make sure that's sourced (step 3 above).

To tag a project, drop a file once:

```bash
echo my-project > /path/to/repo/.copilot-project
```

Existing sessions (run before tagging, or without the wrapper) are auto-attributed from their
working directory, so dashboards are useful immediately.

### Applying the project columns to an existing database

The `project` columns are created automatically on a fresh Postgres volume. If your database
predates this feature, apply the migration once:

```bash
make migrate      # idempotent ALTER TABLE + view refresh
make backfill     # re-attribute existing sessions
```

### Auto-start at login

```bash
make install     # installs a launchd agent that starts podman + the stack at login
make uninstall   # remove it
```

### Optional: live traces (per-session drill-down)

```bash
make traces      # starts the stack including Tempo
```

## Keeping history current

Re-run `make backfill` any time (it is idempotent) to ingest newly finished sessions,
or add it to `cron`/`launchd` on a schedule.

## Privacy

- All endpoints bind to `127.0.0.1`; no data is sent off-box.
- OTel **content capture is disabled** — only metadata (token counts, model and skill
  names, durations) is collected, never prompts, code, or secrets.

## Layout

```
compose.yaml                  podman/docker compose stack
otelcol/config.yaml           OTel collector (OTLP in → Prometheus + Tempo)
prometheus/prometheus.yml     scrapes the collector
tempo/tempo.yaml              trace storage (optional profile)
postgres/initdb/01-schema.sql per-session schema + session_totals view
postgres/migrations/          idempotent schema migrations (make migrate)
backfill/parser.py            events.jsonl → Postgres (idempotent)
scripts/instrument.sh         shell env + `copilot` wrapper (OTel export + project tagging)
grafana/                      provisioned datasources + dashboards
launchd/, Makefile            auto-start + operations
docs/superpowers/specs/       design document
```

## Notes

- Tested with Copilot CLI 1.0.57 and podman 5.7.1 on macOS (Apple Silicon).
- Default Grafana login is anonymous-admin for local convenience.
- `gen_ai.*` metric/attribute names follow the OTel GenAI semantic conventions.
