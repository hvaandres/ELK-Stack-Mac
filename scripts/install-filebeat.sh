#!/usr/bin/env bash
# ===========================================================================
# SOC Lab - install and wire up Filebeat on THIS host.
#
# For the single-machine setup, where soc-server and soc-endpoint are the
# same box, so credentials can be read from .env instead of prompted.
# Adds the auditd + system log modules alongside Auditbeat.
#
# Does everything end to end:
#   install -> template config -> keystore -> setup -> chain pipeline -> start
#
# Usage:  make filebeat      (or ./scripts/install-filebeat.sh)
#
# NOTE: Filebeat is OPTIONAL. Auditbeat alone satisfies the lab pipeline.
#       Running both means each auditd event is indexed twice - once from the
#       kernel (auditbeat-*) and once from /var/log/audit/audit.log
#       (filebeat-*). Use --no-auditd-module to keep Filebeat for
#       auth/syslog only, which avoids the duplication.
# ===========================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

: "${BEATS_PASSWORD:?BEATS_PASSWORD not found - run this on the server host where .env lives}"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD not found}"
SERVER="${ES_BIND_ADDR:-127.0.0.1}"
LAB_USER="$(id -un)"
NO_AUDITD_MODULE=false
[[ "${1:-}" == "--no-auditd-module" ]] && NO_AUDITD_MODULE=true

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "1/6  Installing the filebeat package"
if command -v filebeat >/dev/null 2>&1; then
  ok "already installed: $(dpkg-query -W -f='${Version}' filebeat 2>/dev/null)"
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq filebeat
  ok "installed $(dpkg-query -W -f='${Version}' filebeat 2>/dev/null)"
fi

step "2/6  Writing /etc/filebeat/filebeat.yml"
sudo sed -e "s|__SOC_SERVER_IP__|${SERVER}|g" \
         -e "s|__SOC_LAB_USER__|${LAB_USER}|g" \
         endpoint/filebeat.yml | sudo tee /etc/filebeat/filebeat.yml >/dev/null
if [[ "$NO_AUDITD_MODULE" == true ]]; then
  # Flip only the FIRST 'enabled: true' - that is the auditd module's log
  # fileset - leaving the system module collecting auth.log and syslog.
  sudo sed -i '0,/^      enabled: true$/s//      enabled: false/' /etc/filebeat/filebeat.yml
  ok "auditd module disabled - no duplicate events; system module kept"
fi
sudo chown root:root /etc/filebeat/filebeat.yml
sudo chmod 600 /etc/filebeat/filebeat.yml
ok "config written (mode 600), pointing at ${SERVER}:9200"

step "3/6  Storing the shipper password in the Filebeat keystore"
sudo filebeat keystore create --force >/dev/null
printf '%s' "${BEATS_PASSWORD}" | sudo filebeat keystore add BEATS_PASSWORD --stdin --force >/dev/null
ok "keystore populated from .env"

step "4/6  Validating config and connectivity"
sudo filebeat test config
if sudo filebeat test output 2>&1 | grep -q 'talk to server... OK'; then
  ok "filebeat can authenticate to Elasticsearch"
else
  warn "filebeat cannot reach Elasticsearch:"
  sudo filebeat test output 2>&1 | tail -6 | sed 's/^/        /'
  exit 1
fi

step "5/6  One-time setup (index template + module ingest pipelines) as elastic"
sudo filebeat setup --index-management --pipelines \
  -E output.elasticsearch.username=elastic \
  -E output.elasticsearch.password="${ELASTIC_PASSWORD}" \
  && ok "index management and module pipelines loaded" \
  || warn "setup reported a problem - check the output above"

if [[ "$NO_AUDITD_MODULE" == false ]]; then
  step "5b/6  Chaining SOC normalization onto the auditd module pipeline"
  ./scripts/chain-filebeat-pipeline.sh \
    && ok "chained - Filebeat auditd events will populate soc.rule_key" \
    || warn "chaining failed; run ./scripts/chain-filebeat-pipeline.sh manually"
fi

step "6/6  Starting filebeat"
sudo systemctl enable --now filebeat
sleep 5
systemctl is-active --quiet filebeat && ok "filebeat running and enabled at boot" \
  || { warn "filebeat is not active:"; sudo journalctl -u filebeat -n 20 --no-pager; }

cat <<EOF

Filebeat is configured. Verify with:
    make doctor
    make events

In Kibana, use the filebeat-* data view. Note that with the auditd module
enabled you will see each audit event TWICE - once under auditbeat-* (read
from the kernel) and once under filebeat-* (read from the log file). That is
expected. To avoid it, re-run with:

    ./scripts/install-filebeat.sh --no-auditd-module
EOF
