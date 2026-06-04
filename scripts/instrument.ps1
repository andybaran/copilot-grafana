# Copilot CLI OpenTelemetry instrumentation (Windows / PowerShell).
#
# Dot-source this from your PowerShell profile so every `copilot` run ships OTLP
# metrics/traces to the local collector started by this stack:
#
#   Add-Content $PROFILE ". '$PWD\scripts\instrument.ps1'"
#   . .\scripts\instrument.ps1
#
# The CLI runs on the host and pushes to the collector's published loopback port.
# Content capture stays OFF so prompts, code, and secrets are never exported.
#
# This is the Windows counterpart of scripts/instrument.sh. The project-name
# normalization rules are kept in sync with that script and with backfill/parser.py.

$env:OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4318"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:COPILOT_OTEL_ENABLED = "true"
$env:OTEL_SERVICE_NAME = "github-copilot-cli"
$env:OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "false"

# --- Project attribution -----------------------------------------------------
# Each `copilot` run is attributed to a project name, resolved at launch time by:
#   1. $env:COPILOT_PROJECT               (highest; prefer one-shot: $env:COPILOT_PROJECT='x'; copilot; ...)
#   2. a .copilot-project file in $PWD    (first non-empty line)
#   3. the enclosing git repo's basename
#   4. the basename of $PWD
#   5. "unknown"                          (for $HOME, a drive root, or $env:TEMP)
#
# The resolved name is attached to live OTel metrics (project resource attribute ->
# Prometheus label) for that invocation only, and recorded to a sidecar so the history
# parser attributes the same name to the session. Both pipelines therefore agree.

if (-not $env:COPILOT_HOME) { $env:COPILOT_HOME = Join-Path $env:USERPROFILE ".copilot" }
if (-not $env:COPILOT_PROJECT_TAGS) {
    $env:COPILOT_PROJECT_TAGS = Join-Path $env:COPILOT_HOME "session-state\project-tags.jsonl"
}

# Resolve the REAL copilot command ONCE, before the wrapper function shadows it.
# Excluding the Function command type means re-dot-sourcing still finds the script.
$global:CopilotObsOriginal = (
    Get-Command copilot -All -CommandType ExternalScript, Application -ErrorAction SilentlyContinue |
    Sort-Object { if ($_.Source -like '*.ps1') { 0 } else { 1 } } |
    Select-Object -First 1
).Source

if (-not $global:CopilotObsOriginal) {
    Write-Warning "instrument.ps1: 'copilot' was not found on PATH; the wrapper will be inert."
}

# Normalize a candidate project name to a label/SQL-safe value: first line only,
# trimmed, restricted to [A-Za-z0-9._-], collapsed dashes, max 80 chars.
function global:Get-CopilotNormalizedProject {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    $first = ($Value -split "`r?`n", 2)[0].Trim()
    $cleaned = [regex]::Replace($first, '[^A-Za-z0-9._-]', '-')
    $cleaned = [regex]::Replace($cleaned, '-+', '-').Trim('-')
    if ($cleaned.Length -gt 80) { $cleaned = $cleaned.Substring(0, 80) }
    return $cleaned
}

function global:Resolve-CopilotProject {
    $cwd = (Get-Location).ProviderPath
    $proj = ""; $src = "unknown"

    $tempDir = if ($env:TEMP) { (Resolve-Path -LiteralPath $env:TEMP -ErrorAction SilentlyContinue).Path } else { $null }
    $isRoot = ($cwd -eq $env:USERPROFILE) -or
              ($cwd -match '^[A-Za-z]:\\?$') -or
              ($tempDir -and $cwd -eq $tempDir)

    if ($env:COPILOT_PROJECT) {
        $proj = $env:COPILOT_PROJECT; $src = "env"
    }
    elseif (Test-Path -LiteralPath (Join-Path $cwd ".copilot-project")) {
        $proj = (Get-Content -LiteralPath (Join-Path $cwd ".copilot-project") -TotalCount 1 -ErrorAction SilentlyContinue)
        $src = "file"
    }
    else {
        $top = & git -C $cwd rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) {
            $proj = Split-Path -Leaf $top; $src = "git"
        }
        elseif (-not $isRoot) {
            $proj = Split-Path -Leaf $cwd; $src = "cwd"
        }
    }

    $norm = Get-CopilotNormalizedProject $proj
    if (-not $norm) { $norm = "unknown"; $src = "unknown" }
    return [pscustomobject]@{ Project = $norm; Source = $src; Cwd = $cwd }
}

# PowerShell resolves functions ahead of external scripts, so this shadows copilot.ps1.
function global:copilot {
    if (-not $global:CopilotObsOriginal) {
        Write-Warning "instrument.ps1: original 'copilot' not found; cannot run."
        return
    }

    $info = Resolve-CopilotProject
    $launch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Attach the project label to live OTel for this invocation only; restore after.
    $savedAttrs = $env:OTEL_RESOURCE_ATTRIBUTES
    $base = if ($savedAttrs) {
        (($savedAttrs -split ',') | Where-Object { $_ -and ($_ -notmatch '^\s*project\s*=') }) -join ','
    } else { "" }
    $env:OTEL_RESOURCE_ATTRIBUTES = if ($base) { "$base,project=$($info.Project)" } else { "project=$($info.Project)" }

    $copilotRc = 0
    try {
        & $global:CopilotObsOriginal @args
        $copilotRc = $LASTEXITCODE
    }
    finally {
        if ($null -eq $savedAttrs) {
            Remove-Item Env:OTEL_RESOURCE_ATTRIBUTES -ErrorAction SilentlyContinue
        } else {
            $env:OTEL_RESOURCE_ATTRIBUTES = $savedAttrs
        }
    }

    # Correlate this run to its session id and record the project for the history
    # pipeline. Best-effort: never fails or delays the user.
    try {
        $py = @'
import json, os, sys, time, glob
from os.path import normcase, normpath

cwd, project, source, launch, tags_file = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
root = os.path.join(os.environ.get("COPILOT_HOME", os.path.expanduser("~/.copilot")), "session-state")

def same_path(a, b):
    return a and b and normcase(normpath(a)) == normcase(normpath(b))

def start_epoch(s):
    if not s:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None

best = None  # (start_epoch, session_id)
for path in glob.glob(os.path.join(root, "*", "events.jsonl")):
    try:
        if os.path.getmtime(path) < launch - 5:
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                evt = json.loads(line)
                if evt.get("type") != "session.start":
                    break
                data = evt.get("data") or {}
                if not same_path((data.get("context") or {}).get("cwd"), cwd):
                    break
                se = start_epoch(data.get("startTime"))
                if se is None or se < launch - 5:
                    break
                sid = data.get("sessionId") or os.path.basename(os.path.dirname(path))
                if best is None or se > best[0]:
                    best = (se, sid)
                break
    except (OSError, ValueError):
        continue

if best:
    os.makedirs(os.path.dirname(tags_file), exist_ok=True)
    with open(tags_file, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "session_id": best[1],
            "project": project,
            "source": source,
            "cwd": cwd,
            "ts": time.time(),
        }) + "\n")
'@
        $py | & python - $info.Cwd $info.Project $info.Source "$launch" $env:COPILOT_PROJECT_TAGS 2>$null
    } catch {
        # best-effort; ignore
    }

    $global:LASTEXITCODE = $copilotRc
}
