SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

.PHONY: help deploy init build up down restart logs ps status verify provision provision-security \
        sample passwords endpoint-bundle pipeline-test chain-filebeat clean destroy

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

deploy: ## FULL server deployment: preflight, build, start, provision, verify
	@./scripts/deploy-server.sh

init: ## Generate .env with random credentials (Tailscale IP auto-detected)
	@./scripts/bootstrap-env.sh

build: ## Build the soc-lab Elasticsearch and Kibana images
	$(COMPOSE) build

up: ## Build if needed and start Elasticsearch + Kibana
	$(COMPOSE) up -d --build
	@echo
	@echo "Waiting for Kibana to become available (first start takes ~1-2 min)..."
	@until docker inspect -f '{{.State.Health.Status}}' soc-kibana 2>/dev/null | grep -q healthy; do \
		printf '.'; sleep 5; \
	done; echo " ready"
	@$(MAKE) --no-print-directory status

down: ## Stop containers (data volume is kept)
	$(COMPOSE) down

restart: ## Restart the stack
	$(COMPOSE) restart

logs: ## Follow logs for all services
	$(COMPOSE) logs -f --tail=100

ps status: ## Show container and endpoint status
	@$(COMPOSE) ps
	@set -a; source .env; set +a; \
	echo; echo "Elasticsearch: http://$$ES_BIND_ADDR:9200"; \
	echo "Kibana:        http://$$KIBANA_BIND_ADDR:5601  (user: elastic)"

verify: ## Run end-to-end pipeline checks (use this for your screenshots)
	@./scripts/verify-stack.sh

provision: ## Create Kibana data views + the stack alerting rule
	@./scripts/provision-kibana.sh

provision-security: ## Also create the Elastic Security detection rule
	@./scripts/provision-kibana.sh --security

sample: ## Index synthetic audit events to test the stack without the endpoint
	@./scripts/send-sample-events.sh

chain-filebeat: ## Chain SOC normalization onto Filebeat's auditd module pipeline
	@./scripts/chain-filebeat-pipeline.sh

pipeline-test: ## Run the ingest pipeline simulator against a sample document
	@set -a; source .env; set +a; \
	curl -sS -u "elastic:$$ELASTIC_PASSWORD" -H 'Content-Type: application/json' \
	  "http://$$ES_BIND_ADDR:9200/_ingest/pipeline/soc-lab-normalize/_simulate?pretty" \
	  -d '{"docs":[{"_source":{"@timestamp":"2026-01-01T00:00:00Z","tags":["soc_file_monitor"],"auditd":{"result":"success"},"host":{"name":"soc-endpoint"}}}]}'

passwords: ## Print the generated credentials (do NOT paste these into your report)
	@grep -E '^(ELASTIC|KIBANA_SYSTEM|BEATS|ANALYST)_PASSWORD=' .env

endpoint-bundle: ## Create endpoint-setup.tar.gz to copy to soc-endpoint
	@tar -czf endpoint-setup.tar.gz endpoint/
	@echo "Created endpoint-setup.tar.gz"
	@echo "Copy it over Tailscale:  scp endpoint-setup.tar.gz user@<endpoint-tailscale-ip>:~/"

clean: ## Stop containers and remove the built images (keeps data)
	$(COMPOSE) down --rmi local

destroy: ## Stop everything and DELETE all indexed security data
	$(COMPOSE) down -v --rmi local
