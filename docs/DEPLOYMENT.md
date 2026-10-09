# SOC Lab — Consolidated Deployment Runbook

Single source of truth for standing up the platform. Elasticsearch + Kibana on `soc-server` in Docker, Auditbeat on `soc-endpoint`, connected over Tailscale. **No Logstash** — see [Processing layer](#processing-layer-the-logstash-replacement).

Read [`verification-status.md`](verification-status.md) before trusting any claim here. It records what was executed and observed versus what is assumed.

## Contents
1. [Prerequisites](#1-prerequisites)
2. [Architecture](#2-architecture)
3. [Deploy the SOC server](#3-deploy-the-soc-server)
4. [Deploy the SOC endpoint](#4-deploy-the-soc-endpoint)
5. [Verify the pipeline](#5-verify-the-pipeline)
6. [Processing layer](#processing-layer-the-logstash-replacement)
7. [Accounts and security model](#7-accounts-and-security-model)
8. [Day-to-day operations](#8-day-to-day-operations)
9. [Troubleshooting index](#9-troubleshooting-index)
10. [Known gaps](#10-known-gaps)

---

## 1. Prerequisites

**Both machines**
- Ubuntu (22.04 or 24.04), reachable over Tailscale, with Parts 1–2 complete
- Record both Tailscale addresses: `tailscale ip -4`

**soc-server**
- Docker Engine + the compose plugin, your user in the `docker` group
- 4 GB RAM minimum (8 GB comfortable). Heap is auto-sized: 2g at ≥8 GB, 1g at ≥4 GB, 512m below
- `vm.max_map_count = 262144`

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 make git
sudo usermod -aG docker "$USER" && newgrp docker
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

**soc-endpoint**
- `auditd` installed and recording (Part 2). The installer adds it if missing
- The Elastic Stack version **must match the server** (default `9.5.5`)

---

## 2. Architecture

```
soc-endpoint                                 soc-server
┌──────────────────────────┐                 ┌─────────────────────────────────────┐
│ security event           │                 │ Docker                              │
│   ↓                      │                 │  ┌───────────────────────────────┐  │
│ auditd (kernel)          │                 │  │ Elasticsearch :9200           │  │
│   ↓                      │   Tailscale     │  │  • ingest pipeline            │  │
│ Auditbeat / Filebeat ────┼────WireGuard────┼─▶│    soc-lab-normalize          │  │
│   (ECS documents)        │   100.x.y.z     │  │  • auditbeat-* / filebeat-*   │  │
└──────────────────────────┘                 │  └──────────────┬────────────────┘  │
                                             │                 ▼                   │
                                             │  ┌───────────────────────────────┐  │
                                             │  │ Kibana :5601                  │  │
                                             │  │  Discover / Lens / Alerting   │  │
                                             │  └───────────────────────────────┘  │
                                             └─────────────────────────────────────┘
                                                              ↓
                                                        SOC analyst
```

Three containers: `soc-elasticsearch`, a one-shot `soc-setup` that provisions and exits, and `soc-kibana`. Kibana only starts after provisioning succeeds.

---

## 3. Deploy the SOC server

```bash
git clone <this-repo> && cd ElasticSearch
./scripts/deploy-server.sh
```

One command, six stages, stopping with a clear error on failure:

| Stage | What it does |
| --- | --- |
| 1. Preflight | Docker daemon, compose plugin, RAM → heap size, `vm.max_map_count`, port conflicts on 9200/5601 |
| 2. Credentials | Generates `.env` (mode 600, git-ignored) with random passwords and Kibana encryption keys; auto-detects the Tailscale address |
| 3. Build | `soc-lab/elasticsearch` and `soc-lab/kibana` images |
| 4. Start | Elasticsearch → provisioning → Kibana, waiting on real health checks |
| 5. Provision | Kibana data views, alerting rule, Security detection rule |
| 6. Verify | End-to-end checks, then prints the endpoint commands with your address filled in |

Options:

```bash
./scripts/deploy-server.sh --bind 100.x.y.z   # explicit address
./scripts/deploy-server.sh --heap 2g          # override auto-sizing
./scripts/deploy-server.sh --reset            # regenerate ALL credentials
./scripts/deploy-server.sh --skip-verify
```

Safe to re-run; credentials are reused unless `--reset`.

> **Binding matters.** `127.0.0.1` means the endpoint cannot ship events. Use the Tailscale address. Never `0.0.0.0` on a cloud VM — that is the public internet.

> **`--reset` invalidates Kibana's encryption keys**, which breaks previously saved alerting rules. Use it only on a fresh start.

Confirm the platform works before involving the endpoint:

```bash
make sample     # synthetic events through the real pipeline
make verify     # full end-to-end check
```

---

## 4. Deploy the SOC endpoint

On the server:

```bash
make endpoint-bundle
scp endpoint-setup.tar.gz <user>@<endpoint-tailscale-ip>:~/
make passwords          # you will be prompted for these
```

On the endpoint:

```bash
tar xzf endpoint-setup.tar.gz && cd endpoint
sudo ./install-endpoint.sh --server <soc-server-tailscale-ip> --lab-dir ~/soc-lab
```

Seven stages: connectivity check → Elastic APT repo → auditd + SOC audit rules → credentials → install and template Auditbeat → one-time index/dashboard setup → start and self-check.

Prompts for two passwords:
- **`soc-beats`** (required) — stored in the Beats keystore, never in a config file
- **`elastic`** (optional) — only for one-time index template and dashboard setup. Skipping it is fine; the script prints the command to run later

Options:

| Flag | Purpose |
| --- | --- |
| `--lab-dir DIR` | Directory watched by `soc_file_monitor`. Defaults to `~/soc-lab` |
| `--filebeat` | Also install Filebeat. **Then run `make chain-filebeat` on the server** |
| `--kibana-host HOST` | Only if Kibana is not on the same host as Elasticsearch |
| `--version VER` | Must match the server |

Audit rules installed (`soc-lab.rules`): file writes in the lab directory (`soc_file_monitor`), identity files (`soc_identity`), privilege tools (`soc_privilege`), SSH config, cron persistence.

---

## 5. Verify the pipeline

On the endpoint:

```bash
./generate-test-event.sh ~/soc-lab
```

On the server, within about two minutes:

```bash
make verify
```

In Kibana at `http://<soc-server-tailscale-ip>:5601` (user `elastic`), Discover:

```
soc.rule_key : "soc_file_monitor"
soc.rule_key : "soc_file_monitor" and host.name : "soc-endpoint"
event.outcome : "failure" and soc.rule_key : *
```

Useful columns for the investigation write-up: `@timestamp`, `event.ingested`, `host.name`, `user.name`, `user.audit.name` (auid — survives `su`), `process.executable`, `file.path`, `event.action`, `event.outcome`, `soc.rule_key`.

Compare against the raw record on the endpoint — this is the before/after that justifies the whole platform:

```bash
sudo ausearch -k soc_file_monitor -ts recent -i
```

---

## Processing layer (the Logstash replacement)

This stack has no Logstash. Its responsibilities are redistributed:

| Logstash responsibility | Replacement here |
| --- | --- |
| Receive from Beats | Beats call the Elasticsearch HTTP API directly |
| Parse raw auditd text | Auditbeat parses in-agent and emits ECS; Filebeat's auditd module parses via its own ingest pipeline |
| Normalize / enrich | The `soc-lab-normalize` Elasticsearch ingest pipeline |
| Buffer and retry | Beats memory queue, `max_retries: -1` with backoff |
| Route to indices | Beats index templates + ILM |

What `soc-lab-normalize` does: stamps `event.ingested`; derives `soc.rule_key` from either `tags[]` (Auditbeat) or `auditd.log.key` (Filebeat); maps `auditd.result` → `event.outcome`; sets provenance and a severity hint; and on failure **tags** the document (`soc-pipeline-error`) rather than dropping it.

Inspect and test it exactly as you would a Logstash config:

```bash
make pipeline-test      # _simulate against a sample document
source .env && curl -u "elastic:$ELASTIC_PASSWORD" \
  "http://$ES_BIND_ADDR:9200/_ingest/pipeline/soc-lab-normalize?pretty"
```

**What you give up:** the on-disk persistent queue, fan-out to multiple destinations, and non-Beats inputs (syslog, Kafka, JDBC). With many heterogeneous sources, Logstash earns its place. For one endpoint shipping auditd telemetry, it is a service maintained for nothing.

---

## 7. Accounts and security model

| Account | Purpose | Privileges |
| --- | --- | --- |
| `elastic` | Admin, Kibana login, one-time Beats setup | Superuser |
| `kibana_system` | Kibana → Elasticsearch | Built-in service account |
| `soc-beats` | Endpoint shipper | Create documents in `auditbeat-*` / `filebeat-*` only |
| `soc-analyst` | Investigation | Read-only |

`soc-beats` deliberately lacks the index `manage` privilege. With it, anyone compromising the endpoint could **delete the evidence indices** — handing the least trustworthy host the power to destroy its own audit trail. Verify any time:

```bash
source .env
curl -o /dev/null -w '%{http_code}\n' -u "soc-beats:$BEATS_PASSWORD" \
  -X DELETE "http://$ES_BIND_ADDR:9200/auditbeat-test"      # expect 403
```

Other decisions:
- **Authentication on everywhere.** No anonymous access
- **TLS off inside Docker, Tailscale on the wire.** A deliberate lab simplification; production should enable TLS on the Elasticsearch HTTP layer too
- **Secrets isolated.** `.env` (mode 600, git-ignored) on the server; the Beats keystore on the endpoint. `make passwords` to read them — never paste them into a report

---

## 8. Day-to-day operations

```bash
make help              # every target
make verify            # end-to-end health, good screenshot material
make passwords         # show credentials
make logs              # follow all container logs
make down              # stop, keep indexed data
make up                # start again
make destroy           # stop and DELETE all data - irreversible
```

Stop the stack when you are not working. On a cloud VM those are your charges, and delete the resources when the lab is finished.

---

## 9. Troubleshooting index

Work **left to right**: endpoint → shipper → network → Elasticsearch → index → data view → Kibana. Full detail in [`troubleshooting.md`](troubleshooting.md).

| Symptom | Likely cause |
| --- | --- |
| Endpoint cannot reach port 9200 | `ES_BIND_ADDR` still `127.0.0.1`. Re-run `deploy-server.sh --bind <tailscale-ip>` |
| Shipper logs `401` | Wrong keystore value: `sudo auditbeat keystore add BEATS_PASSWORD --force` |
| Shipper logs `403` | Role drift: `docker compose up setup` |
| Auditbeat exits immediately | `auditd` module cannot reach the kernel audit socket — **this kills the whole process, including `file_integrity`** |
| `device or resource busy` | `auditd` owns the unicast socket. Keep `socket_type: multicast` |
| Events arrive, `soc.rule_key` empty | Auditbeat: check `output.elasticsearch.pipeline`. Filebeat: run `make chain-filebeat` |
| Elasticsearch restarts, exit 137 | Out of memory. Lower `--heap` or use a larger VM |
| Cluster is `yellow` | Expected on a single node — replicas have nowhere to go |
| Data view cannot be created | No matching index yet. Ship data or `make sample`, then `make provision` |
| Kibana: `Unable to authenticate [kibana_system]` | `docker compose up setup && docker compose restart kibana` |

---

## 10. Known gaps

Verified by execution: server stack, ingest pipeline (both shipper branches), Kibana provisioning and a firing alert, the privilege model, and the endpoint install on real Ubuntu 24.04 including authenticated event delivery.

Not yet verified — check these first on your VMs:

- **The `auditd` module against a live kernel.** Only `file_integrity` events were shipped during testing. Confirm that rule keys actually appear in `tags[]` on your kernel, and that multicast coexists with running `auditd`. **Highest-priority check.**
- **`systemctl` service management** — the test environment had no systemd
- **Tailscale as transport** — testing used a Docker bridge network
- **amd64** — testing was arm64
- **Reboot survival and sustained retention behavior**

This is a learning lab, not production. The detection fires on *any* matching event rather than on deviation from a baseline, no alert is routed to a human, there is a single node with no replicas, and retention is whatever the default lifecycle policy says.

> Authorized systems only. Run this against machines you own or have explicit written permission to test.
