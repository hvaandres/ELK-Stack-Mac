# Part 23 — Troubleshooting

Work **left to right along the pipeline**. Do not assume Kibana is broken because an event is missing; six things upstream can be wrong first.

```
auditd → Auditbeat → Tailscale → Elasticsearch → index → data view → Kibana
  1        2            3            4            5         6          7
```

## 1. Is auditd generating events? (endpoint)

```bash
sudo auditctl -l | grep soc_          # rules loaded?
sudo auditctl -s                      # enabled=1, and check "lost"
sudo ausearch -k soc_file_monitor -ts recent -i
```

No rules: `sudo augenrules --load`, then `sudo systemctl restart auditd`.
Non-zero and climbing `lost`: the kernel backlog is overflowing — raise `backlog_limit` or reduce rules.

## 2. Is the shipper running and healthy? (endpoint)

```bash
sudo systemctl status auditbeat --no-pager
sudo journalctl -u auditbeat -n 50 --no-pager
sudo auditbeat test config
sudo auditbeat test output          # resolves host, connects, authenticates
```

Common failures:

- `401 Unauthorized` — the keystore value is wrong: `sudo auditbeat keystore add BEATS_PASSWORD --force` with the value from `make passwords` on the server.
- `403 action [...] is unauthorized` — the `soc_beats_writer` role is missing a privilege; re-run the `setup` container with `docker compose up setup`.
- `failed to create audit client ... device or resource busy` — auditd already owns the unicast netlink socket. Keep `socket_type: multicast` in `auditbeat.yml` (the default in this repo), or stop auditd and let Auditbeat own the rules.
- `Exiting: failed to create audit data client: ... bind failed: operation not permitted` — Auditbeat cannot access the kernel audit subsystem. It needs to run as root (or hold `CAP_AUDIT_READ`) on a host with auditing enabled. **Important:** this failure is fatal to the *whole process*, not just the `auditd` module — every other module, including `file_integrity`, stops with it. If you need the rest of your telemetry to survive an audit-subsystem problem, run `file_integrity` as a second Auditbeat instance with its own config, or comment out the `auditd` module while you debug.
- Events flow but `soc.rule_key` is empty — the pipeline is not being applied. For Auditbeat check `output.elasticsearch.pipeline: soc-lab-normalize`; for Filebeat run `scripts/chain-filebeat-pipeline.sh`.

## 3. Can the endpoint reach the SOC server?

```bash
tailscale status
tailscale ping soc-server
curl -v http://<soc-server-tailscale-ip>:9200          # expect 401, which proves reachability
```

A connection refused or timeout almost always means `ES_BIND_ADDR` on the server is still `127.0.0.1`. Fix `.env`, then `make up`.

## 4. Is Elasticsearch healthy? (server)

```bash
docker compose ps
docker compose logs elasticsearch --tail 50
docker inspect -f '{{.State.Health.Status}}' soc-elasticsearch
source .env; curl -u "elastic:$ELASTIC_PASSWORD" "http://$ES_BIND_ADDR:9200/_cluster/health?pretty"
```

- Container restarts in a loop with exit code 137: out of memory. Lower `ES_HEAP`, or give the VM more RAM. The heap should be at most half of the VM's memory.
- `max virtual memory areas vm.max_map_count [65530] is too low`: `sudo sysctl -w vm.max_map_count=262144` and persist it in `/etc/sysctl.d/`.
- `status: red`: `curl ".../_cluster/allocation/explain?pretty"`.

## 5. Is Elasticsearch receiving documents?

```bash
curl -u "elastic:$ELASTIC_PASSWORD" "http://$ES_BIND_ADDR:9200/_cat/indices/auditbeat-*,filebeat-*?v"
curl -u "elastic:$ELASTIC_PASSWORD" -H 'Content-Type: application/json' \
  "http://$ES_BIND_ADDR:9200/auditbeat-*/_count" \
  -d '{"query":{"term":{"soc.rule_key":"soc_file_monitor"}}}'
```

Index exists with `docs.count: 0` → shipper is connecting but not sending; check step 1.
Index missing entirely → shipper never connected or lacks `create_index`; check steps 2 and 3.

Documents tagged `soc-pipeline-error` mean the ingest pipeline threw. Inspect one:

```bash
curl -u "elastic:$ELASTIC_PASSWORD" -H 'Content-Type: application/json' \
  "http://$ES_BIND_ADDR:9200/auditbeat-*/_search?pretty&size=1" \
  -d '{"query":{"term":{"tags":"soc-pipeline-error"}}}'
```

Then debug the pipeline itself with `make pipeline-test` or `_ingest/pipeline/soc-lab-normalize/_simulate?verbose`.

## 6. Is Kibana using the right data view?

- **Stack Management → Data Views** — the pattern must match a real index (`auditbeat-*`, not `auditbeat`).
- New fields such as `soc.rule_key` only appear after a refresh of the data view's field list.
- Widen the time picker. "No results" is usually a time range problem, not a data problem.

## 7. Is Kibana itself up?

```bash
docker compose logs kibana --tail 50
curl -s "http://$KIBANA_BIND_ADDR:5601/api/status" | head -c 300
sudo ss -lntp | grep 5601
```

- `Unable to authenticate user [kibana_system]` — the setup container did not run or ran with a different password. `docker compose up setup` then `docker compose restart kibana`.
- Alerting unavailable / rules will not save — the `xpack.encryptedSavedObjects.encryptionKey` changed. Keep `.env` stable; regenerating it invalidates previously encrypted saved objects.
- Browser cannot reach it but `curl` on the server can — `KIBANA_BIND_ADDR` is loopback. Either set it to the Tailscale IP or tunnel: `ssh -L 5601:127.0.0.1:5601 user@<soc-server-tailscale-ip>`.

## Start over, carefully

```bash
make down       # keeps indexed data
make destroy    # deletes the data volume and the built images - irreversible
```
