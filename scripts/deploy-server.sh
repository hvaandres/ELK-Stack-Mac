#!/usr/bin/env bash
# ===========================================================================
# SOC Lab Part 3 - complete SOC SERVER deployment.
#
# Run this ON soc-server. It performs every step needed to go from a clean
# Docker host to a provisioned, verified Elasticsearch + Kibana platform:
#
#   1. Preflight checks (Docker, compose, RAM, vm.max_map_count, ports)
#   2. Generate .env with random credentials, bound to the Tailscale address
#   3. Build the soc-lab images
#   4. Start Elasticsearch, run provisioning, start Kibana
#   5. Create Kibana data views and the detection rule
#   6. Verify the stack and print the endpoint instructions
#
# Usage:
#   ./scripts/deploy-server.sh                      # auto-detect Tailscale IP
#   ./scripts/deploy-server.sh --bind 100.1.2.3     # explicit bind address
#   ./scripts/deploy-server.sh --bind 127.0.0.1     # local only (no endpoint)
#   ./scripts/deploy-server.sh --heap 2g
#   ./scripts/deploy-server.sh --reset              # regenerate credentials
#
# Safe to re-run: existing credentials are reused unless --reset is given.
# ===========================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

BIND=""
HEAP=""
RESET=false
SKIP_VERIFY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind)        BIND="$2"; shift 2 ;;
    --heap)        HEAP="$2"; shift 2 ;;
    --reset)       RESET=true; shift ;;
    --skip-verify) SKIP_VERIFY=true; shift ;;
    -h|--help)     sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "1/6  Preflight"
# ---------------------------------------------------------------------------
command -v docker >/dev/null || die "docker not found. Install Docker Engine first."
docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is required (not docker-compose v1)."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and is your user in the 'docker' group?"
ok "docker $(docker info --format '{{.ServerVersion}}') with compose plugin"

# Memory: Elasticsearch needs real headroom. The heap should be <= half of RAM.
TOTAL_MB=""
if [[ -r /proc/meminfo ]]; then
  TOTAL_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
elif command -v sysctl >/dev/null 2>&1; then
  TOTAL_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
fi

if [[ -n "$TOTAL_MB" && "$TOTAL_MB" -gt 0 ]]; then
  ok "host memory: ${TOTAL_MB} MB"
  if [[ -z "$HEAP" ]]; then
    if   [[ "$TOTAL_MB" -ge 7500 ]]; then HEAP=2g
    elif [[ "$TOTAL_MB" -ge 3500 ]]; then HEAP=1g
    else HEAP=512m
         warn "under 4 GB RAM - using a 512m heap. Expect this to be tight."
    fi
  fi
  ok "Elasticsearch heap: ${HEAP}"
else
  HEAP="${HEAP:-1g}"
  warn "could not determine host memory; defaulting heap to ${HEAP}"
fi

# Elasticsearch requires a high mmap count on Linux.
if [[ -r /proc/sys/vm/max_map_count ]]; then
  MMC=$(cat /proc/sys/vm/max_map_count)
  if [[ "$MMC" -lt 262144 ]]; then
    warn "vm.max_map_count is ${MMC}; Elasticsearch needs 262144."
    echo "         Fix it now with:"
    echo "           sudo sysctl -w vm.max_map_count=262144"
    echo "           echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf"
    read -r -p "  Continue anyway? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || exit 1
  else
    ok "vm.max_map_count = ${MMC}"
  fi
fi

# Port conflicts are a far more common failure than anything in the config.
for p in 9200 5601; do
  if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${p} "; then
    docker compose ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${p}->" \
      && ok "port ${p} already held by this stack (will be replaced)" \
      || warn "port ${p} is already in use by another process."
  fi
done

# ---------------------------------------------------------------------------
step "2/6  Credentials and network binding"
# ---------------------------------------------------------------------------
if [[ "$RESET" == true || ! -f .env ]]; then
  if [[ -z "$BIND" ]]; then
    if command -v tailscale >/dev/null 2>&1; then
      BIND="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
      [[ -n "$BIND" ]] && ok "detected Tailscale address: ${BIND}"
    fi
  fi
  if [[ -z "$BIND" ]]; then
    warn "no Tailscale address found - binding to 127.0.0.1 (local only)."
    warn "the endpoint will NOT be able to ship events until you re-run with --bind"
    BIND="127.0.0.1"
  fi
  BIND_ADDR="$BIND" ES_HEAP="$HEAP" FORCE=1 ./scripts/bootstrap-env.sh >/dev/null
  ok "generated .env (mode 600, git-ignored)"
else
  ok "reusing existing .env (pass --reset to regenerate credentials)"
  if [[ -n "$BIND" ]]; then
    sed -i.bak -E "s|^ES_BIND_ADDR=.*|ES_BIND_ADDR=${BIND}|; s|^KIBANA_BIND_ADDR=.*|KIBANA_BIND_ADDR=${BIND}|; s|^KIBANA_PUBLIC_URL=.*|KIBANA_PUBLIC_URL=http://${BIND}:5601|" .env
    rm -f .env.bak
    ok "updated bind address to ${BIND}"
  fi
  if [[ -n "$HEAP" ]]; then
    sed -i.bak -E "s|^ES_HEAP=.*|ES_HEAP=${HEAP}|" .env && rm -f .env.bak
  fi
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

[[ "$ES_BIND_ADDR" == "0.0.0.0" ]] && \
  warn "ES_BIND_ADDR is 0.0.0.0 - this exposes Elasticsearch on EVERY interface, including the public one on a cloud VM."
ok "Elasticsearch will listen on ${ES_BIND_ADDR}:9200"
ok "Kibana will listen on ${KIBANA_BIND_ADDR}:5601"

# ---------------------------------------------------------------------------
step "3/6  Building images"
# ---------------------------------------------------------------------------
docker compose build
ok "images built: soc-lab/elasticsearch and soc-lab/kibana (${STACK_VERSION})"

# ---------------------------------------------------------------------------
step "4/6  Starting the stack"
# ---------------------------------------------------------------------------
docker compose up -d
printf '  waiting for Kibana to report available'
for _ in $(seq 1 60); do
  if [[ "$(docker inspect -f '{{.State.Health.Status}}' soc-kibana 2>/dev/null)" == "healthy" ]]; then
    echo; ok "Elasticsearch and Kibana are healthy"; break
  fi
  printf '.'; sleep 5
done
echo
if [[ "$(docker inspect -f '{{.State.Health.Status}}' soc-kibana 2>/dev/null)" != "healthy" ]]; then
  echo
  warn "Kibana did not become healthy in time. Recent logs:"
  docker compose logs kibana --tail 20
  die "deployment incomplete - see docs/troubleshooting.md"
fi

# ---------------------------------------------------------------------------
step "5/6  Provisioning Kibana"
# ---------------------------------------------------------------------------
# Data views need at least one matching index to exist, so this is best-effort
# on a brand new cluster; re-run 'make provision' after the endpoint ships data.
./scripts/provision-kibana.sh --security || warn "some Kibana objects were not created - re-run 'make provision' once data is flowing"

# ---------------------------------------------------------------------------
step "6/6  Verification"
# ---------------------------------------------------------------------------
if [[ "$SKIP_VERIFY" == false ]]; then
  ./scripts/verify-stack.sh || true
fi

cat <<EOF

============================================================================
 SOC server is deployed.
============================================================================

 Kibana:         http://${KIBANA_BIND_ADDR}:5601      (log in as 'elastic')
 Elasticsearch:  http://${ES_BIND_ADDR}:9200
 Credentials:    make passwords          (never paste these into a report)

 NEXT - connect the endpoint:

   1. On this server, bundle the endpoint files:
        make endpoint-bundle

   2. Copy them to soc-endpoint over Tailscale:
        scp endpoint-setup.tar.gz <user>@<endpoint-tailscale-ip>:~/

   3. On soc-endpoint:
        tar xzf endpoint-setup.tar.gz && cd endpoint
        sudo ./install-endpoint.sh --server ${ES_BIND_ADDR} --lab-dir ~/soc-lab

   4. Generate a test event on soc-endpoint:
        ./generate-test-event.sh ~/soc-lab

   5. Back here, confirm it arrived:
        make verify

   6. In Kibana Discover:
        soc.rule_key : "soc_file_monitor"

EOF

if [[ "$ES_BIND_ADDR" == "127.0.0.1" ]]; then
  warn "Bound to loopback: soc-endpoint cannot reach this server."
  echo "       Re-run with:  ./scripts/deploy-server.sh --bind \$(tailscale ip -4)"
fi
