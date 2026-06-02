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
