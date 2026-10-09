#!/usr/bin/env bash
# ===========================================================================
# SOC Lab - pipeline doctor.
#
# Checks every link in the chain, left to right, and tells you exactly which
# command fixes each failure. Every check here exists because it actually
# broke during a real deployment.
#
#   ./scripts/doctor.sh          # checks only
#   ./scripts/doctor.sh --e2e    # also runs a live end-to-end event test
# ===========================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

E2E=false
[[ "${1:-}" == "--e2e" ]] && E2E=true

PASS=0; FAIL=0; WARN=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
fix()  { printf '      \033[36m→ fix:\033[0m %s\n' "$*"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

ES="http://${ES_BIND_ADDR:-127.0.0.1}:9200"
KB="http://${KIBANA_BIND_ADDR:-127.0.0.1}:5601"
EU=(-u "elastic:${ELASTIC_PASSWORD:-}")

# ---------------------------------------------------------------- 1. config
sec "1. Configuration"
if [[ -f .env ]]; then
  pass ".env present"
  [[ "$(stat -c '%a' .env 2>/dev/null || stat -f '%A' .env)" == "600" ]] \
    && pass ".env permissions are 600" \
    || { warn ".env is not mode 600"; fix "chmod 600 .env"; }
  if [[ "${ES_BIND_ADDR:-}" == "127.0.0.1" ]]; then
    warn "bound to loopback - a REMOTE endpoint cannot ship events"
    fix "./scripts/deploy-server.sh --bind \$(tailscale ip -4)"
  else
    pass "bound to ${ES_BIND_ADDR}"
  fi
else
  fail ".env missing"; fix "./scripts/deploy-server.sh"; echo; exit 1
fi

# ------------------------------------------------------------- 2. containers
sec "2. Containers"
if docker info >/dev/null 2>&1; then
  pass "docker daemon reachable"
  for c in soc-elasticsearch soc-kibana; do
    s="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)"
    case "$s" in
      healthy)  pass "$c healthy" ;;
      starting) warn "$c still starting"; fix "wait, then re-run" ;;
      "")       fail "$c not running"; fix "make up" ;;
      *)        fail "$c unhealthy ($s)"; fix "docker compose logs ${c#soc-}" ;;
    esac
  done
else
  fail "cannot reach docker daemon"; fix "start Docker, check your 'docker' group membership"
fi

# ---------------------------------------------------------- 3. elasticsearch
sec "3. Elasticsearch"
if curl -sS -m 10 "${EU[@]}" "$ES" >/dev/null 2>&1; then
  pass "responds at $ES"
  st="$(curl -sS "${EU[@]}" "$ES/_cluster/health" | grep -oE '"status":"[a-z]+"' | cut -d'"' -f4)"
  [[ "$st" == "red" ]] && { fail "cluster status red"; fix "curl $ES/_cluster/allocation/explain?pretty"; } \
                       || pass "cluster status ${st} (yellow is normal on one node)"
else
  fail "no response at $ES"; fix "make up  (and check ES_BIND_ADDR in .env)"
fi

curl -sS "${EU[@]}" "$ES/_ingest/pipeline/soc-lab-normalize" 2>/dev/null | grep -q processors \
  && pass "ingest pipeline soc-lab-normalize installed" \
  || { fail "ingest pipeline missing"; fix "docker compose up setup"; }

# -------------------------------------------------------------- 4. accounts
sec "4. Accounts and privileges"
code="$(curl -sS -o /dev/null -w '%{http_code}' -u "soc-beats:${BEATS_PASSWORD:-}" "$ES" 2>/dev/null)"
[[ "$code" == "200" ]] && pass "soc-beats authenticates" \
  || { fail "soc-beats auth failed (HTTP $code)"; fix "make fix-shipper"; }

# Scope each grep to the relevant JSON array. Grepping the whole document
# also matches the role's own metadata text, which produced a FALSE PASS
# during testing: the description literally contains the word manage_ilm.
role="$(curl -sS "${EU[@]}" "$ES/_security/role/soc_beats_writer" 2>/dev/null)"
cluster_block="$(grep -o '"cluster":\[[^]]*\]' <<<"$role")"
priv_block="$(grep -o '"privileges":\[[^]]*\]' <<<"$role")"

if [[ -z "$cluster_block" ]]; then
  warn "could not read the soc_beats_writer role"
  fix "make fix-roles"
elif grep -q 'manage_ilm' <<<"$cluster_block"; then
  pass "soc_beats_writer has manage_ilm (Beats need it on every connect)"
else
  fail "soc_beats_writer lacks manage_ilm - Beats fail to connect and ship NOTHING"
  fix "make fix-roles"
fi

if [[ -n "$priv_block" ]] && grep -qE '"(manage|all)"' <<<"$priv_block"; then
  warn "soc_beats_writer has index 'manage' - a compromised endpoint could DELETE evidence"
  fix "remove \"manage\" from provision/role-beats-writer.json, then make fix-roles"
else
  pass "soc_beats_writer cannot delete indices (index 'manage' withheld)"
fi

# ---------------------------------------------------------------- 5. kibana
sec "5. Kibana"
if curl -sS -m 10 "$KB/api/status" 2>/dev/null | grep -q '"level":"available"'; then
  pass "available at $KB"
  n="$(curl -sS "${EU[@]}" "$KB/api/data_views" 2>/dev/null | grep -o '"title"' | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] && pass "$n data view(s) defined" \
                   || { warn "no data views"; fix "make provision"; }
  r="$(curl -sS "${EU[@]}" -H 'kbn-xsrf: true' "$KB/api/alerting/rules/_find?per_page=100" 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')"
  [[ "$r" -gt 0 ]] && pass "$r alerting rule(s) defined" \
                   || { warn "no alerting rules"; fix "make provision-security"; }
else
  fail "Kibana not available at $KB"; fix "docker compose logs kibana --tail 30"
fi

# -------------------------------------------------------------- 6. endpoint
sec "6. Endpoint sensor (auditd)"
if command -v auditctl >/dev/null 2>&1; then
  if sudo -n auditctl -l 2>/dev/null | grep -q soc_ || sudo auditctl -l 2>/dev/null | grep -q soc_; then
    pass "soc_* audit rules loaded"
  else
    fail "no soc_* audit rules"; fix "sudo augenrules --load"
  fi
  # The blind-shell trap: a shell started before auditing was enabled has a
  # NULL audit context and its syscalls are NEVER recorded. Probe with a
  # freshly forked process so the check is meaningful.
  if [[ -d "${SOC_LAB_DIR:-$HOME/soc-lab}" ]]; then
    before="$(sudo ausearch -k soc_file_monitor -ts recent 2>/dev/null | grep -c '^type=SYSCALL')"
    bash -c "echo 'doctor probe' >> ${SOC_LAB_DIR:-$HOME/soc-lab}/security-test.txt" 2>/dev/null
    sleep 2
    after="$(sudo ausearch -k soc_file_monitor -ts recent 2>/dev/null | grep -c '^type=SYSCALL')"
    [[ "$after" -gt "$before" ]] \
      && pass "auditd records file writes (fresh-process probe)" \
      || { fail "auditd did NOT record a file write"
           fix "check the watched path matches your lab dir; note that a login shell started BEFORE auditd was enabled is never audited - log out and back in"; }
  else
    warn "lab directory not found; skipping the write probe"
  fi
else
  warn "auditctl not present - this host is not acting as an endpoint"
fi

# -------------------------------------------------------------- 7. shippers
sec "7. Shippers"
for beat in auditbeat filebeat; do
  if command -v "$beat" >/dev/null 2>&1; then
    systemctl is-active --quiet "$beat" 2>/dev/null \
      && pass "$beat service active" \
      || { fail "$beat installed but not running"; fix "sudo systemctl restart $beat; sudo journalctl -u $beat -n 30"; }

    sudo "$beat" keystore list 2>/dev/null | grep -q BEATS_PASSWORD \
      && pass "$beat keystore holds BEATS_PASSWORD" \
      || { fail "$beat keystore missing BEATS_PASSWORD"; fix "make fix-shipper"; }

    if sudo "$beat" test output 2>&1 | grep -q 'talk to server... OK'; then
      pass "$beat can authenticate to Elasticsearch"
    else
      fail "$beat cannot talk to Elasticsearch"; fix "make fix-shipper"
    fi

    logf="$(sudo bash -c "ls -t /var/log/$beat/*.ndjson 2>/dev/null | head -1")"
    if [[ -n "$logf" ]]; then
      errs="$(sudo tail -c 20000 "$logf" 2>/dev/null | grep -ciE 'lifecycle policy .* failed|onConnect callback failed|401 Unauthorized')"
      [[ "$errs" -eq 0 ]] && pass "$beat log clean of auth/ILM errors" \
        || { fail "$beat log shows ILM or auth failures ($errs recent)"; fix "make fix-roles && make fix-shipper"; }
    fi
  else
    warn "$beat not installed"
    [[ "$beat" == "filebeat" ]] && fix "make filebeat   (optional - Auditbeat alone satisfies the lab)"
  fi
done

if command -v filebeat >/dev/null 2>&1; then
  curl -sS "${EU[@]}" "$ES/_ingest/pipeline/filebeat-*-auditd-log-pipeline" 2>/dev/null | grep -q soc-lab-normalize \
    && pass "filebeat auditd pipeline chained to soc-lab-normalize" \
    || { fail "filebeat auditd pipeline NOT chained - events will lack soc.rule_key"; fix "make chain-filebeat"; }
fi

# ------------------------------------------------------------------ 8. data
sec "8. Data"
curl -sS "${EU[@]}" "$ES/_cat/indices/auditbeat-*,filebeat-*?h=index,docs.count" 2>/dev/null \
  | sed 's/^/      /' | grep . || warn "no auditbeat-* or filebeat-* indices yet"

real="$(curl -sS "${EU[@]}" -H 'Content-Type: application/json' "$ES/auditbeat-*,filebeat-*/_count" \
  -d '{"query":{"bool":{"must":[{"exists":{"field":"soc.rule_key"}}],"must_not":[{"term":{"soc.source":"synthetic"}}]}}}' 2>/dev/null \
  | grep -oE '"count":[0-9]+' | cut -d: -f2)"
real="${real:-0}"
[[ "$real" -gt 0 ]] && pass "$real real endpoint event(s) with soc.rule_key" \
  || { fail "no real endpoint events indexed"; fix "run ./scripts/doctor.sh --e2e to trace a live event"; }

# --------------------------------------------------------------- 9. end-to-end
if [[ "$E2E" == true ]]; then
  sec "9. End-to-end live test"
  lab="${SOC_LAB_DIR:-$HOME/soc-lab}"
  mkdir -p "$lab"
  b="$(curl -sS "${EU[@]}" -H 'Content-Type: application/json' "$ES/auditbeat-*,filebeat-*/_count" \
      -d '{"query":{"term":{"soc.rule_key":"soc_file_monitor"}}}' 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2)"
  echo "      baseline: ${b:-0} documents; generating an event..."
  bash -c "echo 'doctor e2e $(date -u +%FT%TZ)' >> $lab/security-test.txt"
  for i in $(seq 1 12); do
    sleep 5
    a="$(curl -sS "${EU[@]}" -H 'Content-Type: application/json' "$ES/auditbeat-*,filebeat-*/_count?refresh=true" \
        -d '{"query":{"term":{"soc.rule_key":"soc_file_monitor"}}}' 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2)"
    if [[ "${a:-0}" -gt "${b:-0}" ]]; then
      pass "event reached Elasticsearch in ~$((i*5))s (${b} → ${a})"
      break
    fi
    printf '      waiting... %ss\n' "$((i*5))"
  done
  [[ "${a:-0}" -gt "${b:-0}" ]] || { fail "event never arrived after 60s"
    fix "sudo tail -5 \$(sudo ls -t /var/log/auditbeat/*.ndjson | head -1)"; }
fi

# ----------------------------------------------------------------- summary
printf '\n\033[1mSummary:\033[0m %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"
[[ "$FAIL" -gt 0 ]] && { echo "Run the suggested fixes above, then re-run: make doctor"; exit 1; }
echo "Pipeline looks healthy."
