# SOC Lab Part 3 — Containerized Elasticsearch + Kibana

A reproducible, Docker-based SOC monitoring platform for `soc-server`: Elasticsearch for storage and search, Kibana for investigation, and a documented ingest path from `soc-endpoint` over Tailscale.

**Logstash is not used.** See [Where Logstash went](#where-logstash-went) for what replaces it and how to answer the assignment's pipeline questions.

## Architecture

```
soc-endpoint                                 soc-server (this repo)
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

## Repository layout

```
docker-compose.yml           Elasticsearch + one-shot setup + Kibana
images/elasticsearch/        Dockerfile + baked elasticsearch.yml
images/kibana/               Dockerfile + baked kibana.yml
provision/                   ingest pipeline, roles, setup.sh (runs in-container)
scripts/deploy-server.sh     one-command SOC server deployment
scripts/                     bootstrap, verification, Kibana provisioning, samples
endpoint/install-endpoint.sh one-command SOC endpoint deployment
endpoint/                    Auditbeat/Filebeat configs, audit rules
docs/                        walkthrough, troubleshooting, report templates
```

## Deployment

### 1. SOC server — one command

```bash
# Prerequisites: Docker Engine + compose plugin, Tailscale up
sudo apt update && sudo apt install -y docker.io docker-compose-v2 make git
sudo usermod -aG docker "$USER" && newgrp docker

git clone <this-repo> && cd ElasticSearch
./scripts/deploy-server.sh          # or: make deploy
```

`deploy-server.sh` runs the whole sequence and stops with a clear error if any step fails:

1. **Preflight** — Docker, compose plugin, daemon reachable, host RAM (picks a sane heap), `vm.max_map_count`, port conflicts on 9200/5601
2. **Credentials** — generates `.env` (mode 600, git-ignored), auto-detecting the Tailscale address; warns loudly if it can only bind to loopback
3. **Build** — both images
4. **Start** — Elasticsearch → provisioning container → Kibana, waiting for real health checks
5. **Provision** — Kibana data views, alerting rule, Security detection rule
6. **Verify** — end-to-end checks, then prints the exact endpoint commands

Useful variants:

```bash
./scripts/deploy-server.sh --bind 100.x.y.z   # explicit address
./scripts/deploy-server.sh --heap 2g          # override the auto-sized heap
./scripts/deploy-server.sh --reset            # regenerate all credentials
```

It is safe to re-run; existing credentials are reused unless you pass `--reset`.

Before wiring up the endpoint, prove the platform works on its own:

```bash
make sample      # synthetic events through the real pipeline
make verify      # end-to-end checks - good screenshot material
```

### 2. SOC endpoint — one command

On the server, bundle and copy the endpoint files:

```bash
make endpoint-bundle
scp endpoint-setup.tar.gz <user>@<endpoint-tailscale-ip>:~/
```

On `soc-endpoint`:

```bash
tar xzf endpoint-setup.tar.gz && cd endpoint
sudo ./install-endpoint.sh --server <soc-server-tailscale-ip> --lab-dir ~/soc-lab
```

That script checks connectivity, adds the Elastic APT repo, installs `auditd` if missing plus the SOC audit rules, installs Auditbeat at a pinned version, templates the config, stores the password in the Beats keystore, runs the one-time index/dashboard setup, then starts and self-checks the service. It prompts for two passwords (`make passwords` on the server) and is safe to re-run.

Options:

- `--filebeat` — also install Filebeat. **Then run `make chain-filebeat` on the server**, or the audit key will not be normalized into `soc.rule_key`.
- `--kibana-host HOST` — if Kibana is not on the same host as Elasticsearch
- `--version VER` — must match the server's `STACK_VERSION`

### 3. Confirm the pipeline

```bash
./generate-test-event.sh ~/soc-lab     # on the endpoint
make verify                            # on the server
```

Then in Kibana at `http://<soc-server-tailscale-ip>:5601`, search Discover for:

```
soc.rule_key : "soc_file_monitor"
```

Run `make help` for every target.

## Where Logstash went

This stack has no Logstash. The classic lab pipeline is `Beats → Logstash → Elasticsearch`, where Logstash owns **transport, parsing, normalization and enrichment**. None of that work disappears when Logstash is absent — something else has to absorb it, and the point of this section is to be explicit about what:

| Logstash responsibility | Replacement in this build |
| --- | --- |
| Receive events from Beats (`beats` input) | Beats talk to the Elasticsearch HTTP API directly (`output.elasticsearch`) |
| Parse raw auditd lines (`grok`, `kv`) | Auditbeat's `auditd` module parses in the agent and emits ECS; Filebeat's `auditd` module parses via its own Elasticsearch ingest pipeline |
| Normalize / rename / enrich fields (`mutate`, `date`) | The `soc-lab-normalize` **Elasticsearch ingest pipeline** (`provision/ingest-pipeline.json`) |
| Buffer and retry on failure | Beats' internal queue plus infinite retry/backoff (`max_retries: -1`) |
| Route to indices (`elasticsearch` output) | Beats index templates + ILM (`auditbeat-*`, `filebeat-*`) |

Trade-offs you should be able to state in the write-up: you lose Logstash's on-disk persistent queue, its multi-destination fan-out (e.g. simultaneously to a SIEM and to cold storage), and heavier transformations (lookups, aggregation, Ruby filters). You gain fewer moving parts, less memory on a small VM, and one fewer service to secure and troubleshoot.

The pipeline is inspectable and testable like any other config:

```bash
make pipeline-test        # _simulate the pipeline against a sample document
```

## Security choices (and their justification)

- **Authentication is on.** `xpack.security.enabled: true`; every component authenticates. The endpoint uses a dedicated least-privilege `soc-beats` account that can only create documents in `auditbeat-*` / `filebeat-*`; a read-only `soc-analyst` account exists for investigation work.
- **TLS is off inside Docker, on the wire it is Tailscale.** HTTP between containers stays on the Docker bridge; endpoint-to-server traffic rides WireGuard. This keeps the lab focused on the SOC pipeline instead of certificate management. In production you would enable TLS on the Elasticsearch HTTP layer as well.
- **Nothing is published to the public Internet.** Ports bind to the address in `.env` — loopback by default, your Tailscale IP once you need the endpoint. Never set these to `0.0.0.0` on a cloud VM.
- **Secrets never live in config files you submit.** Credentials sit in `.env` (git-ignored, mode 600) on the server and in the Beats keystore on the endpoint. Run `make passwords` when you need them; do not paste them into your report.

## Cost reminder

Elasticsearch wants memory. `ES_HEAP=1g` suits a 2–4 GB VM. If the container is OOM-killed, either raise `ES_HEAP` on a bigger instance or reduce what you collect. Stop the stack with `make down` when you are not working, and delete cloud resources when the lab is finished — those charges are yours, not the university's.

## Documentation

- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — **the consolidated runbook.** Prerequisites, both deployments, verification, the security model, operations, a troubleshooting index and known gaps. Start here.
- [`docs/SOC-LAB-PART3.md`](docs/SOC-LAB-PART3.md) — step-by-step walkthrough mapped to every numbered part of the assignment, including the required searches, visualization, detection and evidence list.
- [`docs/pipeline-explained.md`](docs/pipeline-explained.md) — Part 22: what each component does, why it is needed, what breaks without it.
- [`docs/incident-report-template.md`](docs/incident-report-template.md) — Part 21 report skeleton.
- [`docs/investigation-timeline.md`](docs/investigation-timeline.md) — Part 20 timeline template.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — Part 23, worked left-to-right along the pipeline.
- [`docs/verification-status.md`](docs/verification-status.md) — **what has actually been tested versus assumed.** Read this before trusting any claim in the other documents.

> Authorized systems only. Everything here is intended for the VMs you built for this course.
