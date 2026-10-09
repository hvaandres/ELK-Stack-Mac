SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

.PHONY: help deploy init build up down restart logs ps status verify provision provision-security \
        sample passwords endpoint-bundle pipeline-test chain-filebeat clean destroy \
        doctor doctor-e2e fix fix-shipper fix-roles filebeat filebeat-syslog-only \
        events shipper-logs shipper-status audit-check

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
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

status: ## Show container status plus the Elasticsearch and Kibana URLs
	@$(COMPOSE) ps
	@set -a; source .env; set +a; \
	echo; echo "Elasticsearch: http://$$ES_BIND_ADDR:9200"; \
	echo "Kibana:        http://$$KIBANA_BIND_ADDR:5601  (user: elastic)"

ps: status ## Alias for status

verify: ## Run end-to-end pipeline checks (use this for your screenshots)
	@./scripts/verify-stack.sh

# --- diagnosis and repair -------------------------------------------------

doctor: ## DIAGNOSE every link in the pipeline and print the fix for each failure
	@./scripts/doctor.sh

doctor-e2e: ## Same as doctor, plus generate a live event and wait for it to land
	@./scripts/doctor.sh --e2e

fix: fix-roles fix-shipper ## Apply both repairs (roles, then shippers)

fix-roles: ## Re-apply Elasticsearch roles/users (fixes 403s and ILM connect failures)
	@docker compose up setup

fix-shipper: ## Re-push the shipper password from .env into the Beats keystores and restart
	@./scripts/fix-shipper.sh

audit-check: ## Verify auditd actually records a write (uses a freshly forked process)
	@sudo auditctl -l | grep soc_ || echo "no soc_* rules loaded - sudo augenrules --load"
	@bash -c 'echo "audit-check $$(date -u +%FT%TZ)" >> $${SOC_LAB_DIR:-$$HOME/soc-lab}/security-test.txt'
	@sleep 2
	@sudo ausearch -k soc_file_monitor -ts recent -i 2>/dev/null | grep '^type=SYSCALL' | tail -3 \
	  || echo "NO records - a shell started before auditd was enabled is never audited; log out and back in"

# --- endpoint shippers ----------------------------------------------------

filebeat: ## Install + configure + chain + start Filebeat on THIS host
	@./scripts/install-filebeat.sh

filebeat-syslog-only: ## Install Filebeat for auth/syslog only (avoids duplicate audit events)
	@./scripts/install-filebeat.sh --no-auditd-module

shipper-status: ## Show the state of Auditbeat and Filebeat on this host
	@for b in auditbeat filebeat; do \
	  if command -v $$b >/dev/null 2>&1; then \
	    printf '%-10s %s\n' "$$b" "$$(systemctl is-active $$b 2>/dev/null)"; \
	  else printf '%-10s not installed\n' "$$b"; fi; done

shipper-logs: ## Tail the Beats log files (they do NOT log to journald)
	@sudo bash -c 'for b in auditbeat filebeat; do \
	  f=$$(ls -t /var/log/$$b/*.ndjson 2>/dev/null | head -1); \
	  [ -n "$$f" ] && { echo "=== $$f"; tail -c 4000 "$$f" | grep -oE "\"message\":\"[^\"]{0,140}" | tail -8; }; \
	done'

events: ## Show the most recent SOC events that reached Elasticsearch
	@set -a; source .env; set +a; \
	curl -sS -u "elastic:$$ELASTIC_PASSWORD" "http://$$ES_BIND_ADDR:9200/_cat/indices/auditbeat-*,filebeat-*?v&h=index,docs.count,store.size"; \
	echo; echo "--- 5 most recent events with soc.rule_key:"; \
	curl -sS -u "elastic:$$ELASTIC_PASSWORD" -H 'Content-Type: application/json' \
	  "http://$$ES_BIND_ADDR:9200/auditbeat-*,filebeat-*/_search?pretty" \
	  -d '{"size":5,"sort":[{"@timestamp":"desc"}],"query":{"exists":{"field":"soc.rule_key"}},"_source":["@timestamp","soc.rule_key","host.name","user.name","process.name","file.path","event.outcome"]}'

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
