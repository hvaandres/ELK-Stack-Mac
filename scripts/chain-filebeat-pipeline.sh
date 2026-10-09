#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Only needed if you ship audit data with FILEBEAT (the auditd module).
#
# The Filebeat auditd module parses events with its own Elasticsearch ingest
# pipeline, so the beat cannot also point at `soc-lab-normalize` without
# breaking parsing. This script appends a `pipeline` processor to the end of
# the module pipeline so SOC normalization runs right after module parsing:
#
#   filebeat-<ver>-auditd-log-pipeline  ->  soc-lab-normalize
#
# Run it on soc-server AFTER the endpoint has run:
#   filebeat setup --pipelines --modules auditd
#
# Safe to re-run: already-chained pipelines are detected and skipped.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

ES_URL="http://${ES_BIND_ADDR:-127.0.0.1}:9200"
AUTH=(-u "elastic:${ELASTIC_PASSWORD:?ELASTIC_PASSWORD not set}")

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

all="$(curl -sS "${AUTH[@]}" "${ES_URL}/_ingest/pipeline/filebeat-*-auditd-log-pipeline")"
names="$(printf '%s' "$all" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).keys()))')"

if [[ -z "$names" ]]; then
  echo "No filebeat auditd module pipeline found." >&2
  echo "Run this on the endpoint first: filebeat setup --pipelines --modules auditd" >&2
  exit 1
fi

failed=0
while read -r name; do
  [[ -n "$name" ]] || continue

  # Elasticsearch returns system-managed metadata (created_date_millis and
  # friends) on GET, but rejects those same properties on PUT. Strip them,
  # and skip pipelines that are already chained.
  body="$(printf '%s' "$all" | python3 -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)[name]
for managed in ("created_date", "created_date_millis",
                "modified_date", "modified_date_millis"):
    doc.pop(managed, None)
procs = doc.get("processors", [])
if any(p.get("pipeline", {}).get("name") == "soc-lab-normalize" for p in procs):
    print("")          # already chained
else:
    procs.append({"pipeline": {"name": "soc-lab-normalize", "ignore_failure": True}})
    doc["processors"] = procs
    print(json.dumps(doc))
' "$name")"

  if [[ -z "$body" ]]; then
    echo "==> ${name}: already chained, skipping"
    continue
  fi

  code="$(curl -sS -o /tmp/chain.out -w '%{http_code}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -X PUT "${ES_URL}/_ingest/pipeline/${name}" -d "$body")"

  if [[ "$code" == "200" ]]; then
    echo "==> ${name}: chained to soc-lab-normalize"
  else
    echo "==> ${name}: FAILED (HTTP ${code})" >&2
    cat /tmp/chain.out >&2; echo >&2
    failed=1
  fi
done <<< "$names"

rm -f /tmp/chain.out

if [[ "$failed" -ne 0 ]]; then
  echo "One or more pipelines could not be patched." >&2
  exit 1
fi
echo "Done. New Filebeat auditd events will populate soc.rule_key."
