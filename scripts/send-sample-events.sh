#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Indexes a handful of synthetic auditd-shaped events through the
# soc-lab-normalize ingest pipeline.
#
# Purpose: prove that Elasticsearch + the pipeline + Kibana work BEFORE you
# wire up soc-endpoint, and give you something to build a data view and
# visualization against. These documents are clearly labelled synthetic
# (soc.source: "synthetic") - do not pass them off as endpoint evidence in
# your report.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

ES_URL="http://${ES_BIND_ADDR:-127.0.0.1}:9200"
INDEX="auditbeat-soc-lab-synthetic"
NOW() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

doc() {
  local key="$1" user="$2" action="$3" result="$4" path="$5" exe="$6"
  cat <<EOF
{"index":{"_index":"${INDEX}"}}
{"@timestamp":"$(NOW)","tags":["${key}"],"event":{"category":["file"],"type":["change"],"action":"${action}","module":"auditd","dataset":"auditd.log"},"auditd":{"message_type":"syscall","result":"${result}","session":"3","summary":{"actor":{"primary":"${user}","secondary":"${user}"},"object":{"type":"file","primary":"${path}"},"how":"${exe}"}},"host":{"name":"soc-endpoint","hostname":"soc-endpoint","os":{"type":"linux","platform":"ubuntu"}},"user":{"name":"${user}","audit":{"name":"${user}"}},"process":{"executable":"${exe}","name":"$(basename "${exe}")","pid":4242},"file":{"path":"${path}"},"source":{"ip":"100.64.0.11"},"soc":{"source":"synthetic"}}
EOF
}

{
  doc soc_file_monitor  student  "modified-file"  success "/home/student/soc-lab/security-test.txt" /usr/bin/bash
  doc soc_file_monitor  student  "modified-file"  success "/home/student/soc-lab/security-test.txt" /usr/bin/nano
  doc soc_file_monitor  root     "modified-file"  success "/home/student/soc-lab/security-test.txt" /usr/bin/bash
  doc soc_identity      root     "changed-passwd" success "/etc/passwd"                             /usr/sbin/usermod
  doc soc_file_monitor  attacker "modified-file"  fail    "/home/student/soc-lab/security-test.txt" /usr/bin/vi
} > /tmp/soc-bulk.ndjson

echo "POSTing synthetic events to ${ES_URL}/_bulk?pipeline=soc-lab-normalize"
curl -sS -u "elastic:${ELASTIC_PASSWORD}" \
  -H 'Content-Type: application/x-ndjson' \
  "${ES_URL}/_bulk?pipeline=soc-lab-normalize&refresh=true" \
  --data-binary @/tmp/soc-bulk.ndjson | head -c 400
echo
rm -f /tmp/soc-bulk.ndjson

echo
echo "Verify the pipeline normalized the audit key into soc.rule_key:"
curl -sS -u "elastic:${ELASTIC_PASSWORD}" -H 'Content-Type: application/json' \
  "${ES_URL}/${INDEX}/_search?pretty&size=1&_source=@timestamp,soc,user.name,file.path,tags" \
  -d '{"query":{"term":{"soc.rule_key":"soc_file_monitor"}}}'

echo
echo "Clean up later with:"
echo "  curl -u elastic:\$ELASTIC_PASSWORD -XDELETE ${ES_URL}/${INDEX}"
