#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SOC Lab Part 3 - Kibana provisioning.
#
# Creates, via the Kibana API:
#   * data views for auditbeat-* and filebeat-*            (assignment Part 13)
#   * a stack alerting rule on the soc_file_monitor key    (assignment Part 17)
#   * optionally an Elastic Security detection rule        (assignment Part 17)
#
# Everything here can also be done by hand in the UI - doing it by hand is a
# perfectly good way to produce the required screenshots. This script exists so
# you can rebuild the lab quickly after a teardown.
#
# Usage:
#   ./scripts/provision-kibana.sh            # data views + alerting rule
#   ./scripts/provision-kibana.sh --security # also create the detection rule
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

KIBANA_URL="${KIBANA_URL:-http://${KIBANA_BIND_ADDR:-127.0.0.1}:5601}"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD not found - create .env first}"

WITH_SECURITY_RULE=false
[[ "${1:-}" == "--security" ]] && WITH_SECURITY_RULE=true

log() { printf '[kibana] %s\n' "$*"; }

kbn() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o /tmp/kbn.out -w '%{http_code}'
    -u "elastic:${ELASTIC_PASSWORD}"
    -H 'kbn-xsrf: true'
    -H 'Content-Type: application/json'
    -H 'elastic-api-version: 2023-10-31'
    -X "$method" "${KIBANA_URL}${path}")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

log "waiting for Kibana at ${KIBANA_URL} ..."
for _ in $(seq 1 60); do
  if curl -sS "${KIBANA_URL}/api/status" 2>/dev/null | grep -q '"level":"available"'; then
    break
  fi
  sleep 5
done
log "Kibana is available."

create_data_view() {
  local title="$1" name="$2" code
  code="$(kbn POST /api/data_views/data_view \
    "$(printf '{"data_view":{"title":"%s","name":"%s","timeFieldName":"@timestamp"}}' "$title" "$name")")"
  case "$code" in
    200|201) log "data view created: ${title}" ;;
    400|409)  log "data view already exists (or no matching index yet): ${title}"
              sed -n '1,3p' /tmp/kbn.out; echo ;;
    *)        log "unexpected HTTP ${code} creating data view ${title}"; cat /tmp/kbn.out; echo ;;
  esac
}

create_data_view "auditbeat-*" "SOC - Auditbeat (endpoint audit events)"
create_data_view "filebeat-*"  "SOC - Filebeat (endpoint log files)"

# The alerting API happily creates rules with duplicate names, so check first.
ALERT_NAME="SOC - Monitored file activity (soc_file_monitor)"
rule_exists() {
  kbn GET "/api/alerting/rules/_find?per_page=100" >/dev/null
  # Read the response from the file, not stdin: a heredoc here would be
  # silently replaced by any stdin redirect and python would try to execute
  # the JSON as a program.
  python3 -c '
import json, sys
try:
    with open("/tmp/kbn.out") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sys.exit(0 if any(r.get("name") == sys.argv[1] for r in data.get("data", [])) else 1)
' "$1"
}

if rule_exists "$ALERT_NAME"; then
  log "alerting rule already exists - skipping: ${ALERT_NAME}"
  SKIP_ALERT=true
else
  SKIP_ALERT=false
fi

ALERT_BODY=$(cat <<'JSON'
{
  "name": "SOC - Monitored file activity (soc_file_monitor)",
  "rule_type_id": ".es-query",
  "consumer": "stackAlerts",
  "enabled": true,
  "tags": ["soc-lab", "part3", "detection"],
  "schedule": { "interval": "1m" },
  "actions": [],
  "params": {
    "searchType": "esQuery",
    "index": ["auditbeat-*", "filebeat-*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"soc.rule_key\":\"soc_file_monitor\"}}]}}}",
    "size": 100,
    "timeWindowSize": 5,
    "timeWindowUnit": "m",
    "threshold": [0],
    "thresholdComparator": ">",
    "excludeHitsFromPreviousRun": true,
    "aggType": "count",
    "groupBy": "all"
  }
}
JSON
)
if [[ "$SKIP_ALERT" == false ]]; then
  log "creating stack alerting rule: ${ALERT_NAME}"
  code="$(kbn POST /api/alerting/rule "$ALERT_BODY")"
  if [[ "$code" == "200" ]]; then
    log "alerting rule created."
  else
    log "alerting rule request returned HTTP ${code}:"
    cat /tmp/kbn.out; echo
    log "If this failed, create the rule in the UI: Stack Management > Rules > Create rule > Elasticsearch query."
  fi
fi

if [[ "$WITH_SECURITY_RULE" == true ]]; then
  log "creating Elastic Security detection rule"
  DETECTION_BODY=$(cat <<'JSON'
{
  "rule_id": "soc-lab-file-monitor",
  "name": "SOC Lab - Write/attribute change on monitored file (soc_file_monitor)",
  "description": "An auditd rule tagged soc_file_monitor fired on soc-endpoint, meaning a watched file under the SOC lab directory was written to or had its attributes changed. Investigate the user, process and command responsible.",
  "type": "query",
  "language": "kuery",
  "query": "soc.rule_key: \"soc_file_monitor\"",
  "index": ["auditbeat-*", "filebeat-*"],
  "severity": "medium",
  "risk_score": 47,
  "from": "now-10m",
  "interval": "5m",
  "enabled": true,
  "tags": ["soc-lab", "part3"],
  "false_positives": ["Expected administrative edits to lab files made by the student during testing."],
  "note": "Triage: confirm user.name / process.executable, compare with the change window, and check whether the same auid performed other soc_* keyed activity."
}
JSON
)
  code="$(kbn POST /api/detection_engine/rules "$DETECTION_BODY")"
  if [[ "$code" == "200" ]]; then
    log "detection rule created."
  elif [[ "$code" == "409" ]]; then
    log "detection rule already exists (rule_id soc-lab-file-monitor) - skipping."
  else
    log "detection rule request returned HTTP ${code}:"
    cat /tmp/kbn.out; echo
    log "Open Security > Rules once in the UI (this initializes the detection engine) and re-run with --security."
  fi
fi

rm -f /tmp/kbn.out
log "done."
