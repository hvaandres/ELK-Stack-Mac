#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SOC Lab Part 3 - stack verification.
# Produces the output you need for the "Elasticsearch running / responding /
# Kibana running" evidence items, and walks the pipeline left to right so you
# can see exactly where data stops flowing.
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

ES_HOST="${ES_BIND_ADDR:-127.0.0.1}"
KB_HOST="${KIBANA_BIND_ADDR:-127.0.0.1}"
ES_URL="http://${ES_HOST}:9200"
KB_URL="http://${KB_HOST}:5601"
AUTH=(-u "elastic:${ELASTIC_PASSWORD:-}")

hr() { printf '\n==== %s ====\n' "$*"; }

hr "1. Containers"
docker compose ps

hr "2. Elasticsearch responds (${ES_URL})"
curl -sS "${AUTH[@]}" "${ES_URL}" || echo "FAILED"

hr "3. Cluster health"
curl -sS "${AUTH[@]}" "${ES_URL}/_cluster/health?pretty" || echo "FAILED"

hr "4. Ingest pipeline installed (Logstash replacement)"
curl -sS "${AUTH[@]}" "${ES_URL}/_ingest/pipeline/soc-lab-normalize" \
  | head -c 400; echo

hr "5. Security event indices"
curl -sS "${AUTH[@]}" "${ES_URL}/_cat/indices/auditbeat-*,filebeat-*?v&h=health,status,index,docs.count,store.size" \
  || echo "FAILED"

hr "6. Document count for the soc_file_monitor key"
curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
  "${ES_URL}/auditbeat-*,filebeat-*/_count" \
  -d '{"query":{"term":{"soc.rule_key":"soc_file_monitor"}}}' || echo "FAILED"
echo

hr "7. Most recent SOC event"
curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
  "${ES_URL}/auditbeat-*,filebeat-*/_search?pretty" \
  -d '{"size":1,"sort":[{"@timestamp":"desc"}],"query":{"exists":{"field":"soc.rule_key"}}}' \
  | head -60

hr "8. Kibana status (${KB_URL})"
curl -sS "${KB_URL}/api/status" | head -c 300; echo

hr "9. Listening sockets on the host"
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null | grep -E '9200|5601' || echo "no listeners found on 9200/5601"
else
  netstat -an 2>/dev/null | grep -E '9200|5601' || echo "no listeners found on 9200/5601"
fi

echo
echo "Kibana UI: ${KB_URL}  (user: elastic)"
