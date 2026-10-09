#!/usr/bin/env bash
# ===========================================================================
# SOC Lab Part 3 - complete SOC ENDPOINT deployment.
#
# Run this ON soc-endpoint, as root. It:
#   1. Checks it can reach Elasticsearch on soc-server
#   2. Installs the Elastic APT repository
#   3. Installs auditd (if absent) and the SOC lab audit rules
#   4. Installs Auditbeat (optionally Filebeat) at a pinned version
#   5. Templates the config and stores the password in the Beats keystore
#   6. Runs one-time index-template / dashboard setup as 'elastic'
#   7. Enables and starts the service, then self-checks
#
# Usage:
#   sudo ./install-endpoint.sh --server 100.x.y.z
#   sudo ./install-endpoint.sh --server 100.x.y.z --lab-dir /home/student/soc-lab
#   sudo ./install-endpoint.sh --server 100.x.y.z --filebeat
#   sudo ./install-endpoint.sh --server 100.x.y.z --kibana-host 100.a.b.c
#
# Options:
#   --server HOST       soc-server address (Tailscale IP). Required.
#   --kibana-host HOST  Kibana address, if not the same host as Elasticsearch.
#   --lab-dir DIR       directory watched by the soc_file_monitor rule.
#   --version VER       Elastic Stack version. Must match the server.
#   --filebeat          also install Filebeat (auditd + system log modules).
#
# Safe to re-run.
#
# Authorized systems only: run this against lab machines you own.
# ===========================================================================
set -euo pipefail

SERVER_IP=""
KIBANA_HOST=""
LAB_DIR=""
STACK_VERSION="9.5.5"
INSTALL_FILEBEAT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)      SERVER_IP="$2"; shift 2 ;;
    --kibana-host) KIBANA_HOST="$2"; shift 2 ;;
    --lab-dir)     LAB_DIR="$2"; shift 2 ;;
    --version)     STACK_VERSION="$2"; shift 2 ;;
    --filebeat)    INSTALL_FILEBEAT=true; shift ;;
    -h|--help)     sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ -n "$SERVER_IP" ]] || { echo "--server <soc-server address> is required." >&2; exit 2; }

# Default the lab dir to the invoking (non-root) user's home.
if [[ -z "$LAB_DIR" ]]; then
  if [[ -n "${SUDO_USER:-}" ]]; then LAB_DIR="/home/${SUDO_USER}/soc-lab"; else LAB_DIR="/root/soc-lab"; fi
fi
KIBANA_HOST="${KIBANA_HOST:-$SERVER_IP}"

HERE="$(cd "$(dirname "$0")" && pwd)"
MAJOR="${STACK_VERSION%%.*}"
LAB_USER="$(basename "$(dirname "$LAB_DIR")")"

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "SOC endpoint setup"
echo "  Elasticsearch : http://${SERVER_IP}:9200"
echo "  Kibana        : http://${KIBANA_HOST}:5601"
echo "  Monitored dir : ${LAB_DIR}"
echo "  Stack version : ${STACK_VERSION}  (must match soc-server)"

# --- 1. Connectivity -------------------------------------------------------
step "1/7  Checking connectivity to soc-server"
# A 401 here is a SUCCESS: it proves we reached Elasticsearch and it demanded
# authentication. Only a connection failure is fatal.
code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://${SERVER_IP}:9200" 2>/dev/null || echo 000)"
case "$code" in
  401|200) ok "Elasticsearch reachable (HTTP ${code})" ;;
  000)     warn "cannot reach http://${SERVER_IP}:9200"
           warn "check 'tailscale status', and that ES_BIND_ADDR on soc-server is its Tailscale IP, not 127.0.0.1"
           read -r -p "  Continue anyway? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || exit 1 ;;
  *)       warn "unexpected HTTP ${code} from Elasticsearch - continuing" ;;
esac

# --- 2. Elastic APT repository --------------------------------------------
step "2/7  Installing the Elastic ${MAJOR}.x APT repository"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apt-transport-https curl gnupg
install -d -m 0755 /usr/share/keyrings
# --batch --yes so a re-run (existing keyring) does not try to prompt on
# /dev/tty, which fails over a non-interactive SSH session.
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/elastic-keyring.gpg
chmod 0644 /usr/share/keyrings/elastic-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/${MAJOR}.x/apt stable main" \
  > "/etc/apt/sources.list.d/elastic-${MAJOR}.x.list"
apt-get update -qq
ok "repository configured"

# --- 3. auditd and the SOC audit rules ------------------------------------
step "3/7  Installing audit rules (key: soc_file_monitor)"
if ! command -v auditctl >/dev/null 2>&1; then
  warn "auditd not found (Part 2 normally installs it) - installing now"
  apt-get install -y -qq auditd audispd-plugins
fi
install -d -m 0750 /etc/audit/rules.d
mkdir -p "$LAB_DIR"
[[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:${SUDO_USER}" "$LAB_DIR" 2>/dev/null || true
sed "s|__SOC_LAB_DIR__|${LAB_DIR}|g" "${HERE}/soc-lab.rules" > /etc/audit/rules.d/soc-lab.rules
chmod 640 /etc/audit/rules.d/soc-lab.rules
if command -v augenrules >/dev/null 2>&1; then
  augenrules --load >/dev/null 2>&1 || systemctl restart auditd >/dev/null 2>&1 || true
fi
if auditctl -l 2>/dev/null | grep -q 'soc_'; then
  ok "audit rules loaded:"
  auditctl -l | grep 'soc_' | sed 's/^/        /'
else
  warn "no soc_* rules are active. Check: sudo augenrules --load && sudo auditctl -l"
fi

# --- 4. Credentials --------------------------------------------------------
step "4/7  Credentials"
echo "  Get these from soc-server with: make passwords"
read -r -s -p "  Password for the 'soc-beats' user: " BEATS_PASSWORD; echo
[[ -n "$BEATS_PASSWORD" ]] || { echo "  a soc-beats password is required" >&2; exit 2; }
echo
echo "  One-time setup (index template, ILM policy, dashboards) needs privileges"
echo "  that the least-privilege soc-beats account deliberately lacks - it can"
echo "  create documents but cannot manage or delete indices."
read -r -s -p "  Password for 'elastic' (press Enter to skip setup): " ELASTIC_PASSWORD; echo

# --- 5-7. Install each beat ------------------------------------------------
install_beat() {
  local beat="$1"

  step "5/7  Installing ${beat} ${STACK_VERSION}"
  apt-get install -y -qq "${beat}"
  ok "$(dpkg-query -W -f='${Package} ${Version} ${Architecture}' "${beat}")"

  sed -e "s|__SOC_SERVER_IP__|${SERVER_IP}|g" \
      -e "s|__SOC_LAB_USER__|${LAB_USER}|g" \
      "${HERE}/${beat}.yml" > "/etc/${beat}/${beat}.yml"
  # If Kibana lives on a different host than Elasticsearch, fix up that one line.
  if [[ "$KIBANA_HOST" != "$SERVER_IP" ]]; then
    sed -i "s|host: \"http://${SERVER_IP}:5601\"|host: \"http://${KIBANA_HOST}:5601\"|" "/etc/${beat}/${beat}.yml"
  fi
  chown root:root "/etc/${beat}/${beat}.yml"
  chmod 600 "/etc/${beat}/${beat}.yml"
  ok "config written to /etc/${beat}/${beat}.yml (mode 600)"

  # The secret lives in the keystore, never in the YAML and never in a report.
  "${beat}" keystore create --force >/dev/null
  printf '%s' "${BEATS_PASSWORD}" | "${beat}" keystore add BEATS_PASSWORD --stdin --force >/dev/null
  ok "password stored in the ${beat} keystore"

  "${beat}" test config && ok "${beat} config is valid"

  step "6/7  ${beat}: one-time index and dashboard setup"
  if [[ -n "${ELASTIC_PASSWORD:-}" ]]; then
    "${beat}" setup --index-management \
      -E output.elasticsearch.username=elastic \
      -E output.elasticsearch.password="${ELASTIC_PASSWORD}" \
      && ok "index template and ILM policy loaded" \
      || warn "index-management setup failed"
    "${beat}" setup --dashboards \
      -E setup.kibana.username=elastic \
      -E setup.kibana.password="${ELASTIC_PASSWORD}" \
      && ok "Kibana dashboards loaded" \
      || warn "dashboard setup failed (is Kibana reachable at ${KIBANA_HOST}:5601?)"
    if [[ "$beat" == "filebeat" ]]; then
      "${beat}" setup --pipelines --modules auditd \
        -E output.elasticsearch.username=elastic \
        -E output.elasticsearch.password="${ELASTIC_PASSWORD}" \
        && ok "auditd module ingest pipelines loaded" \
        || warn "module pipeline setup failed"
      echo
      warn "FILEBEAT ONLY: now run this on soc-server so the audit key is normalized:"
      echo "           ./scripts/chain-filebeat-pipeline.sh"
    fi
  else
    warn "skipped (no elastic password given). Run later from this host:"
    echo "           sudo ${beat} setup --index-management --dashboards \\"
    echo "             -E output.elasticsearch.username=elastic -E output.elasticsearch.password=<pw> \\"
    echo "             -E setup.kibana.username=elastic -E setup.kibana.password=<pw>"
  fi

  step "7/7  Starting ${beat}"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl enable --now "${beat}"
    sleep 5
    if systemctl is-active --quiet "${beat}"; then
      ok "${beat} is running and enabled at boot"
    else
      warn "${beat} is not active. Inspect with:"
      echo "           sudo journalctl -u ${beat} -n 50 --no-pager"
    fi
  else
    warn "systemd not available - start it manually: ${beat} -e"
  fi
}

install_beat auditbeat
if [[ "$INSTALL_FILEBEAT" == true ]]; then
  install_beat filebeat
fi
unset BEATS_PASSWORD ELASTIC_PASSWORD

cat <<EOF

============================================================================
 SOC endpoint is configured.
============================================================================

 Generate a controlled test event:
     ./generate-test-event.sh ${LAB_DIR}

 Then on soc-server:
     make verify

 And in Kibana Discover:
     soc.rule_key : "soc_file_monitor"

 If events do not appear, work LEFT TO RIGHT along the pipeline:
     sudo auditctl -l | grep soc_              # 1. is auditd recording?
     sudo systemctl status auditbeat           # 2. is the shipper running?
     sudo auditbeat test output                # 3. can it reach + authenticate?
     sudo journalctl -u auditbeat -n 50        # 4. what is it complaining about?

 Full guide: docs/troubleshooting.md on soc-server.
EOF
