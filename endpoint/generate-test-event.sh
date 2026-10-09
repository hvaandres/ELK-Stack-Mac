#!/usr/bin/env bash
# ===========================================================================
# SOC Lab Part 3 / Part 18 - generate a controlled security event on
# soc-endpoint so you can watch it travel the pipeline into Kibana.
#
#   ./generate-test-event.sh [LAB_DIR]
#
# Authorized systems only: run this on your own lab VM.
# ===========================================================================
set -euo pipefail

LAB_DIR="${1:-${HOME}/soc-lab}"
TARGET="${LAB_DIR}/security-test.txt"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$LAB_DIR"

echo "==> ${STAMP}: writing to ${TARGET}"
echo "SOC detection test ${STAMP}" >> "$TARGET"

echo "==> local auditd view of the event"
if command -v ausearch >/dev/null 2>&1; then
  sudo ausearch -k soc_file_monitor -ts recent -i 2>/dev/null | tail -30 \
    || echo "   (no matching auditd records yet)"
else
  sudo tail -5 /var/log/audit/audit.log
fi

cat <<EOF

Event generated at: ${STAMP}
File:               ${TARGET}
User:               $(id -un)  (auid: $(cat /proc/self/loginuid 2>/dev/null || echo n/a))
Host:               $(hostname)

Now find the same event centrally, in Kibana Discover:

  soc.rule_key : "soc_file_monitor"
  soc.rule_key : "soc_file_monitor" and host.name : "$(hostname)"

Record the timestamp above - you need it for the investigation timeline.
EOF
