#!/usr/bin/env bash
# ===========================================================================
# SOC Lab - repair the endpoint shippers.
#
# Fixes the two failures that actually happen in practice:
#   1. The Beats keystore holds a wrong/stale password (401 Unauthorized).
#      Usually caused by pasting the whole "BEATS_PASSWORD=..." line from
#      `make passwords` instead of just the value.
#   2. The password in .env no longer matches Elasticsearch after a --reset.
#
# Reads the value straight from .env, so no copy-paste is involved.
# Run on the endpoint (or on the server when both roles share a host).
# ===========================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; [[ -f .env ]] && source .env; set +a

: "${BEATS_PASSWORD:?BEATS_PASSWORD not found - is .env present?}"
ES="http://${ES_BIND_ADDR:-127.0.0.1}:9200"

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Checking the password in .env against Elasticsearch"
code="$(curl -sS -o /dev/null -w '%{http_code}' -u "soc-beats:${BEATS_PASSWORD}" "$ES" 2>/dev/null)"
if [[ "$code" == "200" ]]; then
  ok "soc-beats password in .env is correct"
else
  warn "Elasticsearch rejected the .env password (HTTP ${code})"
  warn "re-applying roles and users from provision/ ..."
  docker compose up setup || warn "could not run the setup container - are you on the server host?"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "soc-beats:${BEATS_PASSWORD}" "$ES" 2>/dev/null)"
  [[ "$code" == "200" ]] && ok "soc-beats now authenticates" \
                         || { echo "  still failing (HTTP ${code}) - check ES_BIND_ADDR and that the stack is up"; exit 1; }
fi

fixed=0
for beat in auditbeat filebeat; do
  command -v "$beat" >/dev/null 2>&1 || continue
  step "Repairing ${beat}"

  sudo "$beat" keystore create --force >/dev/null 2>&1
  printf '%s' "${BEATS_PASSWORD}" | sudo "$beat" keystore add BEATS_PASSWORD --stdin --force >/dev/null
  ok "keystore updated from .env"

  if sudo "$beat" test output 2>&1 | grep -q 'talk to server... OK'; then
    ok "${beat} authenticates to Elasticsearch"
  else
    warn "${beat} still cannot reach Elasticsearch:"
    sudo "$beat" test output 2>&1 | tail -5 | sed 's/^/        /'
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    sudo systemctl restart "$beat"
    sleep 4
    systemctl is-active --quiet "$beat" && ok "${beat} restarted and running" \
      || warn "${beat} is not active - sudo journalctl -u ${beat} -n 30 --no-pager"
  fi
  fixed=$((fixed+1))
done

[[ "$fixed" -eq 0 ]] && { warn "no Beats installed on this host - nothing to repair"; exit 0; }

cat <<EOF

Done. Confirm the whole pipeline with:
    make doctor
    make doctor-e2e     # generates a live event and waits for it to land
EOF
