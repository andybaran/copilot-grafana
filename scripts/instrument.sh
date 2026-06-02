# Copilot CLI OpenTelemetry instrumentation.
# Source this from your shell profile (~/.zshrc or ~/.bashrc) so every `copilot`
# run ships OTLP metrics/traces to the local collector started by this stack.
#
#   echo 'source /Users/andy.baran/code/grafana/scripts/instrument.sh' >> ~/.zshrc
#
# The CLI runs on the host and pushes to the collector's published loopback port.
# Content capture stays OFF so prompts, code, and secrets are never exported.

export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export COPILOT_OTEL_ENABLED="true"
export OTEL_SERVICE_NAME="github-copilot-cli"
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT="false"

# --- Project attribution -----------------------------------------------------
# Each `copilot` run is attributed to a project name, resolved at launch time by:
#   1. $COPILOT_PROJECT env var          (highest; prefer one-shot: COPILOT_PROJECT=x copilot)
#   2. a .copilot-project file in $PWD    (first non-empty line)
#   3. the enclosing git repo's basename
#   4. the basename of $PWD
#   5. "unknown"                          (for $HOME, /, /tmp, /private/tmp)
#
# The resolved name is attached to live OTel metrics (project resource attribute ->
# Prometheus label) and recorded to a sidecar so the history parser attributes the
# same name to the session. Both pipelines therefore agree.

# Where Copilot stores per-session state; the sidecar lives alongside it so it is
# automatically visible to the backfill container (which already mounts this dir).
: "${COPILOT_HOME:=$HOME/.copilot}"
export COPILOT_PROJECT_TAGS="${COPILOT_PROJECT_TAGS:-$COPILOT_HOME/session-state/project-tags.jsonl}"

# Normalize a candidate project name (reads stdin, writes a label/SQL-safe name):
# first line only, trimmed, restricted to [A-Za-z0-9._-], collapsed dashes, max 80 chars.
__copilot_norm_project() {
  tr -d '\r' \
    | sed -e '1!d' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/[^A-Za-z0-9._-]/-/g' \
          -e 's/--*/-/g' -e 's/^-*//' -e 's/-*$//' \
    | cut -c1-80
}

# zsh refuses to define a function whose name matches an existing alias
# ("defining function based on alias"); clear any stale alias first.
unalias copilot 2>/dev/null || true

copilot() {
  local _cwd _proj _src _norm _launch _rc _top
  _cwd="$PWD"

  if [ -n "$COPILOT_PROJECT" ]; then
    _proj="$COPILOT_PROJECT"; _src="env"
  elif [ -f "$_cwd/.copilot-project" ]; then
    _proj="$(cat "$_cwd/.copilot-project")"; _src="file"
  elif _top="$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_top" ]; then
    _proj="${_top##*/}"; _src="git"
  else
    case "$_cwd" in
      "$HOME"|/|/tmp|/private/tmp) _proj=""; _src="unknown" ;;
      *) _proj="${_cwd##*/}"; _src="cwd" ;;
    esac
  fi

  _norm="$(printf '%s' "$_proj" | __copilot_norm_project)"
  if [ -z "$_norm" ]; then _norm="unknown"; _src="unknown"; fi

  _launch="$(date +%s)"
  # Attach the project label to live OTel for this invocation only (subshell keeps
  # the parent shell's environment clean).
  (
    if [ -n "$OTEL_RESOURCE_ATTRIBUTES" ]; then
      export OTEL_RESOURCE_ATTRIBUTES="$OTEL_RESOURCE_ATTRIBUTES,project=$_norm"
    else
      export OTEL_RESOURCE_ATTRIBUTES="project=$_norm"
    fi
    command copilot "$@"
  )
  _rc=$?

  # Correlate this run to its session id and record the project for the history
  # pipeline. Best-effort: never fails or delays the user.
  COPILOT_HOME="$COPILOT_HOME" python3 - "$_cwd" "$_norm" "$_src" "$_launch" "$COPILOT_PROJECT_TAGS" <<'PY' 2>/dev/null || true
import json, os, sys, time, glob

cwd, project, source, launch, tags_file = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
root = os.path.join(os.environ.get("COPILOT_HOME", os.path.expanduser("~/.copilot")), "session-state")

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
                if (data.get("context") or {}).get("cwd") != cwd:
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
PY

  return $_rc
}
