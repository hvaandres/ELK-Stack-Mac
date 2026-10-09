# Verification status

What has actually been executed and observed, versus what is still assumed. Keep this honest — a deployment guide that claims more than it has tested is worse than one that admits the gap, because you will trust it at the exact moment it fails.

Last updated after a full deployment run on 2026-10-09 (Elastic Stack 9.5.5, arm64).

## Verified by execution

**Server stack**
- Both images build from the official Elastic bases; `docker compose config` validates
- Cold start to healthy Elasticsearch + Kibana: ~35 seconds
- Provisioning container runs to completion and is idempotent across repeated runs
- Cluster reports `yellow` on a single node — expected, as replica shards cannot be allocated

**Ingest pipeline (the Logstash replacement)**
- `_simulate` confirms `tags[] → soc.rule_key`, `auditd.result → event.outcome`, severity, provenance and `event.ingested`
- Bulk indexing through the pipeline: 5 documents, zero errors
- Both shipper branches of the normalization script proven with real data:
  - Auditbeat: key arrives in `tags[]`
  - Filebeat: key arrives as `auditd.log.key`

**Kibana provisioning**
- Data views created via API
- Stack alerting rule (`.es-query`) created and **observed firing**: "Document count is 4 in the last 5m" → `active`, then `recovered`
- Elastic Security detection rule created on a basic license
- Re-running provisioning is a no-op (no duplicate rules)

**Security model** — tested by attempting operations that should fail:
- `soc-beats` authenticates and indexes through the pipeline → HTTP 201
- `soc-beats` deleting an index → HTTP 403
- `soc-beats` writing outside `auditbeat-*` / `filebeat-*` → HTTP 403
- `soc-analyst` can search → HTTP 200; cannot write → HTTP 403

**Endpoint on real Ubuntu 24.04 (arm64 container, on the stack network)**
- Elastic APT repo configured; Auditbeat 9.5.5 and Filebeat 9.5.5 install cleanly
- `auditd` auto-install path works when the package is absent
- Config templating substitutes the server address correctly
- Password stored in and read from the Beats keystore
- `auditbeat test config` → Config OK
- `auditbeat test output` → `talk to server... OK, version: 9.5.5` (real authentication)
- `setup --index-management` loads the index template and ILM policy
- **3 real file-integrity events shipped, acked, indexed and enriched**, ~4.3s from `@timestamp` to `event.ingested`
- Filebeat auditd module parsed real audit records; `chain-filebeat-pipeline.sh` patched the module pipeline; resulting documents carry both `auditd.log.key` and `soc.rule_key`

## NOT verified — assumed to work

These are the places to look first if something misbehaves on your VMs.

- **systemd service management.** `systemctl enable --now auditbeat` never ran; the test environment was a container without systemd. The package ships the unit file, so this is low risk, but it is untested here.
- **The `auditd` module against a live kernel audit subsystem.** The test host denied access to the audit netlink socket, so only `file_integrity` events were shipped. Specifically untested: the multicast socket working alongside a running `auditd`, and whether audit rule keys actually land in `tags[]` on your kernel. **This is the single most important thing to confirm first on the real endpoint.**
- **Tailscale as the transport.** Testing used a Docker bridge network. The address-substitution logic is identical, but WireGuard MTU, ACLs and DNS were never exercised.
- **amd64.** Everything above ran on arm64. Elastic publishes both; no architecture-specific code exists here.
- **Kibana reachable from a separate device** over the tailnet.
- **Sustained load and disk growth.** Only a handful of events were indexed. ILM retention behavior over days is unknown.
- **Reboot survival.** Neither host was restarted.

## Known behaviors worth remembering

- **A failing `auditd` module terminates the entire Auditbeat process**, taking `file_integrity` with it. Observed directly. If you need resilience, run file integrity as a second instance.
- **`host.name` comes from `add_host_metadata`, not the `name:` field** in the config. On a host actually named `soc-endpoint` these agree; elsewhere they will not.
- **Data views cannot be created before a matching index exists.** Ship data (or run `make sample`) first, then `make provision`.
- **Kibana encryption keys must stay stable.** Regenerating `.env` with `--reset` invalidates previously encrypted saved objects, including alerting rules.

## How to re-verify after changing anything

```bash
make pipeline-test      # ingest pipeline logic
make sample             # bulk path end to end
make verify             # full stack, left to right along the pipeline
make provision          # should report "already exists" on a second run
```
