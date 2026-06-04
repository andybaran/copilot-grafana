# Running on Windows 11 (PowerShell + podman)

This stack was originally built for macOS/Linux (bash + `make`). Everything runs on
**Windows 11** too — the containers are identical; only the host-side tooling (the shell
instrumentation and the `make` targets) needed a PowerShell port. This guide is the Windows
counterpart of the macOS instructions in the [README](../README.md).

> **TL;DR**
> ```powershell
> .\make.ps1 up         # start the stack (postgres, collector, prometheus, grafana)
> .\make.ps1 backfill   # load your session history into Postgres
> . .\scripts\instrument.ps1   # turn on live OTel for this shell
> start http://localhost:3000  # dashboards under "Copilot Usage"
> ```

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **podman** (or Docker Desktop) with compose | Tested with podman 5.8. `podman compose` transparently uses the bundled `docker-compose` provider. |
| A running podman machine | `podman machine init` then `podman machine start` (one-time). |
| **Python 3.x** on `PATH` | Used by `scripts/instrument.ps1` to correlate a run to its session id. `python --version` should work. |
| **GitHub Copilot CLI** | Installed via npm; `copilot` resolves to `%APPDATA%\npm\copilot.ps1`. |
| PowerShell 5.1 or 7+ | Both work. PowerShell 7 (`pwsh`) recommended. |

There is **no `make` and no `docker` CLI requirement** on Windows. Use `make.ps1` (a
PowerShell port of the `Makefile`) and `podman compose`.

## 1. Start the stack

```powershell
cd path\to\copilot-grafana
.\make.ps1 up
```

`make.ps1` defaults to `podman compose`. To use Docker Desktop instead:

```powershell
.\make.ps1 -ComposeExe docker -ComposeArgs compose up
```

Check status and endpoints:

```powershell
.\make.ps1 ps
.\make.ps1 urls
```

All ports bind to `127.0.0.1`, exactly as on macOS — nothing is exposed off-box.

## 2. Load your session history

```powershell
.\make.ps1 backfill
```

This runs the one-shot parser container against `~\.copilot\session-state\*\events.jsonl`
and upserts authoritative per-session token totals into Postgres. It is **idempotent** — re-run
it any time to ingest newly finished sessions.

`make.ps1 backfill` sets `COPILOT_HOME` for you (forward-slash normalized so the Windows
drive-letter survives the compose bind mount). Override the location by setting
`$env:COPILOT_HOME` before invoking it.

## 3. Turn on live OTel

Dot-source the instrumentation script so every `copilot` run in that shell exports OTLP
metrics to the local collector:

```powershell
. .\scripts\instrument.ps1
```

Make it permanent by adding it to your PowerShell profile:

```powershell
Add-Content $PROFILE ". '$PWD\scripts\instrument.ps1'"
```

(Then open a new shell, or `. $PROFILE`.)

What the script does — the Windows equivalent of `scripts/instrument.sh`:

- Sets the same `OTEL_*` environment variables. **Content capture stays OFF**
  (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT="false"`) so prompts, code, and secrets
  are never exported.
- Defines a `copilot` **wrapper function** that shadows the npm `copilot.ps1` shim. For each
  run it resolves a **project name**, attaches it to live OTel as a `project` resource
  attribute (→ Prometheus label) for that invocation only, runs the real CLI, then records the
  resolved session id + project to the sidecar
  `~\.copilot\session-state\project-tags.jsonl` that the history parser reads.
- Preserves Copilot's exit code (`$LASTEXITCODE`) and restores any pre-existing
  `OTEL_RESOURCE_ATTRIBUTES` after the run.

### Verifying it works

```powershell
. .\scripts\instrument.ps1
copilot -p "Reply with exactly one word: pong"

# live metrics reached the collector (note project="...")
(Invoke-WebRequest http://localhost:8889/metrics -UseBasicParsing).Content `
  -split "`n" | Select-String 'gen_ai_client_token_usage'

# and Prometheus scraped them
Invoke-RestMethod 'http://localhost:9090/api/v1/query?query=gen_ai_client_token_usage_sum'
```

Open Grafana at http://localhost:3000 → **Copilot Usage** folder → **Copilot — Live OTel**.

## 4. Project attribution

Identical model and precedence to macOS — only the implementation is PowerShell:

1. `$env:COPILOT_PROJECT` — highest. Prefer the one-shot form so it doesn't stick to unrelated
   sessions: `$env:COPILOT_PROJECT='my-thing'; copilot ...; Remove-Item Env:COPILOT_PROJECT`.
2. A `.copilot-project` file in the working directory (its first line names the project).
3. The enclosing git repository's name.
4. The working directory's name.
5. `unknown` (for `$HOME`, a drive root like `C:\`, or `$env:TEMP`).

Tag a directory once:

```powershell
'my-project' | Set-Content .\.copilot-project
```

Names are normalized to `[A-Za-z0-9._-]`, collapsed dashes, max 80 chars — the same rule used
by `instrument.sh` and `backfill/parser.py`, so both pipelines agree on the label.

> **Windows path fix:** `backfill/parser.py` now derives the project basename correctly from
> Windows (`C:\Users\me\repo`) and UNC (`\\server\share\repo`) paths. Previously a Windows cwd
> collapsed into one mangled label. If you backfilled with an older parser, rebuild the image
> and re-run to repair existing rows:
>
> ```powershell
> podman compose --profile tools build backfill
> .\make.ps1 backfill
> ```

## 5. Auto-start at logon (optional)

Instead of macOS `launchd`, Windows uses a **Scheduled Task**:

```powershell
.\make.ps1 install     # registers a logon task that ensures the podman machine + stack are up
.\make.ps1 uninstall   # removes it
```

`install` renders `scripts/startup.ps1` from the template (substituting the repo dir and your
chosen compose engine) and registers a `CopilotObservability` task triggered at logon. The task
starts the podman machine if needed, waits for the engine, then runs `compose up -d`.

> Registering a logon task can require an **elevated** PowerShell (or may be blocked by
> corporate policy). If `install` reports *Access is denied*, re-run it from an Administrator
> shell, or simply start the stack manually with `.\make.ps1 up` when you need it.

> Auto-start only manages the **stack**. To also enable live OTel automatically, add the
> `instrument.ps1` dot-source line to your `$PROFILE` (step 3).

## Command reference (`make.ps1` ↔ `Makefile`)

| `make.ps1`            | `make`        | Purpose |
|-----------------------|---------------|---------|
| `.\make.ps1 up`       | `make up`     | Start core stack |
| `.\make.ps1 traces`   | `make traces` | Start stack incl. Tempo |
| `.\make.ps1 down`     | `make down`   | Stop (keep volumes) |
| `.\make.ps1 restart`  | `make restart`| Restart core stack |
| `.\make.ps1 logs`     | `make logs`   | Tail logs |
| `.\make.ps1 ps`       | `make ps`     | Container status |
| `.\make.ps1 backfill` | `make backfill` | Ingest session history |
| `.\make.ps1 migrate`  | `make migrate`| Apply SQL migrations |
| `.\make.ps1 psql`     | `make psql`   | psql shell |
| `.\make.ps1 urls`     | `make urls`   | Print endpoints |
| `.\make.ps1 install`  | `make install`| Auto-start at login |
| `.\make.ps1 uninstall`| `make uninstall` | Remove auto-start |

## Troubleshooting

- **`podman machine` not running** — `podman machine start`. `make.ps1 install`'s task does
  this for you at logon.
- **`The "HOME" variable is not set` warning** from compose — harmless on Windows; the stack
  uses `COPILOT_HOME` (set by `make.ps1 backfill`) for the only host-path mount.
- **Live dashboard empty** — confirm `scripts/instrument.ps1` is dot-sourced in the shell you
  launched `copilot` from (`(Get-Command copilot).CommandType` should be `Function`), and that
  the collector shows `gen_ai_*` series at http://localhost:8889/metrics.
- **A session shows zero tokens** — the History pipeline only trusts the `session.shutdown`
  summary. A session that hasn't exited yet reports nothing; re-run `make.ps1 backfill` after it
  ends. (See [docs/fleet-mode.md](fleet-mode.md).)
- **Running the parser's path tests** — `python backfill/test_parser.py` (no DB required).

## Privacy

Unchanged from the macOS setup: all endpoints bind to `127.0.0.1`, OTel content capture is
disabled, and only metadata (token counts, model/skill names, durations) is collected — never
prompts, code, or secrets.
