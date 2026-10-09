# SOC Lab Part 3 — Walkthrough (containerized, Logstash-free)

This maps the assignment's numbered parts onto this repository. Where the assignment says "install Logstash", this build substitutes an Elasticsearch ingest pipeline and explains the substitution — make sure your write-up does the same rather than silently skipping the requirement.

## Parts 1–2 — Prepare and verify the SOC server

```bash
sudo apt update && sudo apt upgrade -y
hostname                       # expect: soc-server
tailscale status               # both soc-server and soc-endpoint present
ping -c 4 <SOC-ENDPOINT-TAILSCALE-IP>
tailscale ip -4                # record this: it is your SOC server address
```

Install Docker if it is not already present:

```bash
sudo apt install -y docker.io docker-compose-v2 make
sudo usermod -aG docker "$USER" && newgrp docker
```

## Parts 3–4 — Elasticsearch

Instead of `apt install elasticsearch`, Elasticsearch runs as a container built from `images/elasticsearch/`.

```bash
make init        # writes .env; picks up your Tailscale IP automatically
make up          # builds images, starts Elasticsearch, runs provisioning, starts Kibana
```

Service state — the container equivalent of `systemctl status elasticsearch`:

```bash
docker compose ps
docker inspect -f '{{.State.Health.Status}}' soc-elasticsearch
docker compose logs elasticsearch | tail -30
```

Listening socket (assignment asks for port 9200):

```bash
sudo ss -lntp | grep 9200
```

Elasticsearch responds:

```bash
source .env
curl -u "elastic:$ELASTIC_PASSWORD" "http://$ES_BIND_ADDR:9200"
curl -u "elastic:$ELASTIC_PASSWORD" "http://$ES_BIND_ADDR:9200/_cluster/health?pretty"
```

You get a version banner and `"status":"green"` (or `yellow` — normal for a single node, since replica shards have nowhere to go).

> **Evidence 1 and 2** come from these commands.

## Parts 5–8 — The processing layer (Logstash replacement)

Logstash is not installed. The parsing/normalization/enrichment stage lives in the Elasticsearch ingest pipeline `soc-lab-normalize`, defined in `provision/ingest-pipeline.json` and installed automatically by the `setup` container.

Show the pipeline — this is the analogue of `cat /etc/logstash/conf.d/soc-lab.conf`:

```bash
curl -u "elastic:$ELASTIC_PASSWORD" "http://$ES_BIND_ADDR:9200/_ingest/pipeline/soc-lab-normalize?pretty"
```

Test it before any real data flows — the analogue of `logstash -f ... --config.test_and_exit`:

```bash
make pipeline-test
```

The simulator output should show `soc.rule_key: soc_file_monitor` derived from the incoming `tags` array, plus `soc.lab`, `soc.severity` and `event.ingested`.

What the pipeline does, processor by processor:

1. `set event.ingested` — stamps when the SOC platform received the event, so you can measure pipeline latency against `@timestamp` (when it happened on the endpoint).
2. `script` — normalizes the auditd rule key into `soc.rule_key`. Auditbeat delivers the key in `tags[]`; Filebeat's auditd module delivers it as `auditd.log.key`. One field to search regardless of shipper.
3. `set soc.lab` / `set soc.pipeline` — provenance, so an analyst can tell where a document came from.
4. `set event.outcome` — maps auditd's `success` / `fail` into the ECS field Kibana and detection rules expect.
5. `set soc.severity` — a crude triage hint keyed off the audit rule (`soc_identity` outranks `soc_file_monitor`).
6. `append tags` — marks every document that passed through the SOC pipeline.
7. `on_failure` — tags bad documents with `soc-pipeline-error` instead of dropping them. **Never silently discard telemetry you failed to parse.**

> **Evidence 3**: replace "Logstash is running" with the pipeline definition plus the `make pipeline-test` output, and say in your report why.

## Parts 9–12 — Kibana

Kibana runs as the `soc-kibana` container.

```bash
docker compose ps kibana
docker inspect -f '{{.State.Health.Status}}' soc-kibana
sudo ss -lntp | grep 5601
curl -s "http://$KIBANA_BIND_ADDR:5601/api/status" | head -c 200
```

Kibana's configuration is `images/kibana/kibana.yml` (baked into the image) plus the environment in `docker-compose.yml`. The network-exposure decision the assignment asks about is `KIBANA_BIND_ADDR` in `.env`:

- `127.0.0.1` — reachable only from soc-server itself (use an SSH tunnel: `ssh -L 5601:127.0.0.1:5601 user@<soc-server-tailscale-ip>`)
- `100.x.y.z` — reachable from any device on your tailnet. **This is the intended setting for the lab.**
- `0.0.0.0` — exposed to every network the VM is attached to, including the public Internet on a cloud VM. Do not do this.

Open `http://<soc-server-tailscale-ip>:5601` and log in as `elastic` (`make passwords`).

> **Evidence 4 and 5.**

## Part 13 — Data view

```bash
make provision
```

This creates data views for `auditbeat-*` and `filebeat-*` with `@timestamp` as the time field. You can also do it in the UI: **Stack Management → Data Views → Create data view**. A data view can only be created once at least one matching index exists — run `make sample` or ship real events first.

Which pattern is correct depends on your shipper:

| Shipper | Index pattern | Where the audit key lands |
| --- | --- | --- |
| Auditbeat (`auditd` module) | `auditbeat-*` | `tags[]` → normalized to `soc.rule_key` |
| Filebeat (`auditd` module) | `filebeat-*` | `auditd.log.key` → normalized to `soc.rule_key` (after `scripts/chain-filebeat-pipeline.sh`) |

## Parts 14–15 — Find and investigate your event

Generate traffic from the endpoint first (`endpoint/generate-test-event.sh`), then in **Discover**:

```
soc.rule_key : "soc_file_monitor"
soc.rule_key : "soc_file_monitor" and host.name : "soc-endpoint"
tags : "soc_file_monitor"                       # raw Auditbeat form
auditd.log.key : "soc_file_monitor"             # raw Filebeat form
event.outcome : "failure" and soc.rule_key : *   # failed attempts only
```

Fields to pull into the Discover table for the investigation write-up:

| Investigation question | Field |
| --- | --- |
| Timestamp | `@timestamp` (and `event.ingested` for pipeline lag) |
| Hostname | `host.name` |
| User | `user.name`, `user.audit.name` (auid — the original login identity, survives `su`) |
| Source IP | `source.ip` (present for network/ssh-related records) |
| Process | `process.name`, `process.pid`, `process.parent.name` |
| Command / executable | `process.executable`, `process.args`, `auditd.summary.how` |
| File affected | `file.path`, `auditd.paths.name`, `auditd.summary.object.primary` |
| Action performed | `event.action`, `auditd.message_type` |
| Success / failure | `event.outcome`, `auditd.result` |

Compare that to the raw record on the endpoint:

```bash
sudo ausearch -k soc_file_monitor -ts recent -i
```

Point out in your report what centralization added: resolved UIDs, ECS field names, host metadata, multiple kernel messages coalesced into one document, and the ability to query across hosts.

> **Evidence 6 and 7.**

## Part 16 — Visualization

Suggested, in order of usefulness to an analyst:

1. **Events over time by audit key** — Lens, Bar vertical stacked; X axis `@timestamp` (date histogram), Y axis `Count`, Break down by `soc.rule_key`. Shows baseline versus spike, which is how you spot abnormal activity rather than just confirming activity exists.
2. **Top users by event count** — Lens, Table; rows `user.name`, metric `Count`, with a second column `Unique count of file.path`. Answers "who is touching the most monitored files".
3. **Successful versus failed** — Lens, Donut split by `event.outcome`. A sudden rise in failures often means someone is probing permissions.

Say what the chart tells an analyst and what action it would drive. A chart with no decision attached is decoration.

> **Evidence 8.**

## Part 17 — Detection

```bash
make provision              # Stack alerting rule (works on a basic license)
make provision-security     # also an Elastic Security detection rule
```

The stack rule created for you:

- **Name**: SOC - Monitored file activity (soc_file_monitor)
- **Type**: Elasticsearch query, every 1 minute over a 5-minute window
- **Condition**: more than 0 documents matching `soc.rule_key: soc_file_monitor`
- **Indices**: `auditbeat-*`, `filebeat-*`

To build it by hand instead: **Stack Management → Rules → Create rule → Elasticsearch query**, pick the data view, use the KQL `soc.rule_key : "soc_file_monitor"`, size 100, "is above 0", check every 1 minute.

For your report, document: name, description, query, severity and why, affected host, and the supporting evidence. A threshold of "more than 0" is deliberately noisy — a real detection would baseline normal write activity, exclude known-good processes, and alert on deviation. Note that limitation; it shows you understand the difference between a trip-wire and a detection.

> **Evidence 9.**

## Parts 18–19 — Trigger and investigate

On the endpoint:

```bash
./generate-test-event.sh ~/soc-lab
```

Allow one Beats flush interval plus the rule interval (under two minutes). Then on the server:

```bash
make verify     # shows the document count and the newest SOC event
```

In Kibana, open the alert (**Observability → Alerts** or **Stack Management → Rules → rule → Alerts**) and answer the ten investigation questions. Treat the answer "is the behavior expected?" seriously: in this lab it is expected, because you caused it — your evidence for that is the correlation between your shell session, the `auid`, and the timestamp. Say that explicitly rather than asserting it.

> **Evidence 10.**

## Parts 20–21 — Timeline and report

Use `docs/investigation-timeline.md` and `docs/incident-report-template.md`. Pull every timestamp from Kibana in UTC so the timeline is internally consistent, and note the delta between `@timestamp` and `event.ingested` — detection latency is a real SOC metric.

> **Evidence 11 and 12.**

## Part 22 — Explain the pipeline

See `docs/pipeline-explained.md`. Your version of the pipeline diagram should be:

```
auditd → Auditbeat/Filebeat → Elasticsearch (ingest pipeline + index) → Kibana → Analyst
```

and your write-up must address why Logstash is absent and what absorbed its responsibilities.

## Part 23 — Troubleshooting

See `docs/troubleshooting.md`. Work left to right: endpoint → shipper → network → Elasticsearch → index → data view.

## Evidence checklist

| # | Assignment item | Where it comes from here |
| --- | --- | --- |
| 1 | Elasticsearch running | `docker compose ps`, container health |
| 2 | Elasticsearch responding | `curl http://<ip>:9200` |
| 3 | Processing layer running | ingest pipeline definition + `make pipeline-test` (replaces Logstash) |
| 4 | Kibana running | `docker compose ps kibana`, `/api/status` |
| 5 | Kibana reachable over the lab network | browser at the Tailscale address |
| 6 | Events in Discover | Discover with the data view |
| 7 | Search for the SOC audit event | `soc.rule_key : "soc_file_monitor"` |
| 8 | Visualization | Lens chart |
| 9 | Detection/alert | rule detail page |
| 10 | Triggering event | alert detail + `make verify` output |
| 11 | Timeline | `docs/investigation-timeline.md` |
| 12 | Incident report | `docs/incident-report-template.md` |

Before submitting: `grep -ri password` your document set. No credentials, keys or tokens.
