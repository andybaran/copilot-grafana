# Copilot CLI Token Observability — operations
# Uses podman-compose (docker compose compatible). Override with: make COMPOSE="docker compose"
COMPOSE ?= docker-compose
PLIST   := com.user.copilot-observability.plist
LA_DIR  := $(HOME)/Library/LaunchAgents

.PHONY: help up down restart logs ps backfill traces install uninstall psql urls

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (postgres, collector, prometheus, grafana)
	$(COMPOSE) up -d
	@echo "Grafana: http://localhost:3000  (anonymous admin)"

traces: ## Start the stack WITH Tempo trace storage
	$(COMPOSE) --profile traces up -d

down: ## Stop the stack (keep data volumes)
	$(COMPOSE) --profile traces --profile tools down

restart: ## Restart the core stack
	$(COMPOSE) restart

logs: ## Tail logs from all services
	$(COMPOSE) logs -f --tail=100

ps: ## Show container status
	$(COMPOSE) ps

backfill: ## Parse ~/.copilot/session-state/*/events.jsonl into Postgres (idempotent)
	$(COMPOSE) --profile tools run --rm backfill

psql: ## Open a psql shell to the usage database
	$(COMPOSE) exec postgres psql -U copilot -d copilot_usage

urls: ## Print service URLs
	@echo "Grafana    http://localhost:3000"
	@echo "Prometheus http://localhost:9090"
	@echo "Collector  http://localhost:4318 (OTLP/HTTP), :4317 (gRPC), :8889 (/metrics)"
	@echo "Tempo      http://localhost:3200 (only with 'make traces')"

install: ## Install the launchd agent to auto-start the stack at login
	@mkdir -p "$(LA_DIR)"
	@sed "s|__REPO_DIR__|$(CURDIR)|g; s|__COMPOSE__|$(COMPOSE)|g" scripts/startup.sh.template > scripts/startup.sh
	@chmod +x scripts/startup.sh
	@sed "s|__REPO_DIR__|$(CURDIR)|g" launchd/$(PLIST).template > "$(LA_DIR)/$(PLIST)"
	@launchctl unload "$(LA_DIR)/$(PLIST)" 2>/dev/null || true
	@launchctl load "$(LA_DIR)/$(PLIST)"
	@echo "Installed $(LA_DIR)/$(PLIST). Stack will start at login."

uninstall: ## Remove the launchd auto-start agent
	@launchctl unload "$(LA_DIR)/$(PLIST)" 2>/dev/null || true
	@rm -f "$(LA_DIR)/$(PLIST)"
	@echo "Removed launchd agent."
