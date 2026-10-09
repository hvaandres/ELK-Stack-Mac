#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SOC Lab Part 3 - Elasticsearch provisioning (runs once, in the `setup`
# container, before Kibana starts).
#
# What it does:
#   1. Waits for Elasticsearch to answer.
#   2. Sets the kibana_system password so Kibana can authenticate.
#   3. Installs the `soc-lab-normalize` ingest pipeline (the Logstash
#      replacement: parsing / normalization / enrichment inside Elasticsearch).
#   4. Creates a least-privilege `soc-beats` shipper account for the endpoint.
#   5. Creates a read-only `soc-analyst` account for investigation work.
#
# Passwords are read from the environment and never echoed.
# ---------------------------------------------------------------------------
set -euo pipefail

ES_URL="${ES_URL:-http://elasticsearch:9200}"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
: "${KIBANA_SYSTEM_PASSWORD:?KIBANA_SYSTEM_PASSWORD must be set}"
: "${BEATS_PASSWORD:?BEATS_PASSWORD must be set}"

log() { printf '[setup] %s\n' "$*"; }

# curl wrapper: prints the response body, fails the script on HTTP >= 400.
es_call() {
  local method="$1" path="$2" body="${3:-}"
  local tmp code
  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -u "elastic:${ELASTIC_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X "$method" "${ES_URL}${path}" -d "$body")"
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -u "elastic:${ELASTIC_PASSWORD}" \
      -X "$method" "${ES_URL}${path}")"
  fi
  if [[ "$code" -ge 400 ]]; then
    log "ERROR ${method} ${path} -> HTTP ${code}"
    cat "$tmp"; echo
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"; echo
  rm -f "$tmp"
}

log "waiting for Elasticsearch at ${ES_URL} ..."
for _ in $(seq 1 60); do
  if curl -sS -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}/_cluster/health" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
es_call GET "/_cluster/health?wait_for_status=yellow&timeout=60s" >/dev/null
log "Elasticsearch is up."

log "setting kibana_system password"
es_call POST "/_security/user/kibana_system/_password" \
  "$(printf '{"password":"%s"}' "${KIBANA_SYSTEM_PASSWORD}")" >/dev/null

log "installing ingest pipeline soc-lab-normalize (Logstash replacement)"
es_call PUT "/_ingest/pipeline/soc-lab-normalize" "$(cat /provision/ingest-pipeline.json)" >/dev/null

log "creating role soc_beats_writer"
es_call PUT "/_security/role/soc_beats_writer" "$(cat /provision/role-beats-writer.json)" >/dev/null

log "creating user soc-beats"
es_call PUT "/_security/user/soc-beats" \
  "$(printf '{"password":"%s","roles":["soc_beats_writer"],"full_name":"SOC Lab endpoint shipper"}' "${BEATS_PASSWORD}")" >/dev/null

log "creating role soc_analyst"
es_call PUT "/_security/role/soc_analyst" "$(cat /provision/role-soc-analyst.json)" >/dev/null

if [[ -n "${ANALYST_PASSWORD:-}" ]]; then
  log "creating user soc-analyst"
  es_call PUT "/_security/user/soc-analyst" \
    "$(printf '{"password":"%s","roles":["soc_analyst"],"full_name":"SOC Lab analyst (read-only)"}' "${ANALYST_PASSWORD}")" >/dev/null
else
  log "ANALYST_PASSWORD not set - skipping soc-analyst user"
fi

log "provisioning complete."
