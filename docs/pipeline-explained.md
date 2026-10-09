# Part 22 — The SOC data pipeline, component by component

The assignment's reference pipeline is:

```
auditd → Auditbeat/Filebeat → Logstash → Elasticsearch → Kibana → Analyst
```

This build runs:

```
auditd → Auditbeat/Filebeat → Elasticsearch (ingest pipeline → index) → Kibana → Analyst
```

Use the notes below as raw material; write the final answers in your own words.

## auditd (Linux Audit Framework)

**What it does.** A kernel subsystem plus a userspace daemon that records security-relevant syscalls and file accesses according to rules you load (`-w /path -p wa -k soc_file_monitor`). It is the *sensor*.

**Why it is needed.** Without a sensor there is nothing to collect. Application logs tell you what an application chose to report; auditd tells you what actually happened at the kernel boundary, including the identity (`auid`) that initiated the session, which survives `su` and `sudo`.

**If it were unavailable.** You lose file-level and syscall-level visibility entirely. You could fall back to application logs and FIM, but you could no longer answer "which process, run by whom, touched this file".

**Contribution to the SOC workflow.** It defines the detection surface. The audit rule key is what makes an event findable later, in both `ausearch` and Kibana.

## Auditbeat / Filebeat (the shipper)

**What it does.** A small agent on the endpoint that reads events (Auditbeat subscribes to the kernel audit netlink socket; Filebeat tails `/var/log/audit/audit.log`), converts them to structured ECS JSON, adds host metadata, buffers them, and delivers them over the network with retry.

**Why it is needed.** Logs that stay on the endpoint are only useful if the endpoint is trustworthy and reachable — two things that stop being true during an incident. The shipper gets a copy off the box promptly, and normalizes the format so events from different hosts are comparable.

**If it were unavailable.** Events accumulate locally and the SOC is blind until someone logs in and reads files by hand — exactly the manual workflow Part 2 demonstrated the limits of. You also lose tamper resistance: an attacker who clears `/var/log/audit/audit.log` destroys evidence that was never copied.

**Contribution to the SOC workflow.** Collection and transport, plus the first normalization step (ECS field names, resolved UIDs, coalescing the several kernel messages that make up one logical event into one document).

## Logstash — why it is absent here, and what absorbed its job

**What it does in the reference design.** Receives from Beats, parses unstructured text (`grok`), reshapes and enriches (`mutate`, `date`, lookups), buffers on disk, and routes to one or more destinations.

**Why this build omits it.** The parsing it would do is already done — Auditbeat produces ECS documents in the agent, and Filebeat's auditd module ships a matching Elasticsearch ingest pipeline. The remaining lab-specific normalization (deriving `soc.rule_key`, setting `event.outcome`, tagging provenance) fits comfortably in an Elasticsearch ingest pipeline, which costs no extra service, no extra JVM, and no extra ~1 GB of RAM on a small VM.

**What took over each responsibility.**

- Transport: Beats → Elasticsearch HTTP API directly.
- Parsing: Beats modules (in-agent for Auditbeat, module ingest pipeline for Filebeat).
- Normalization/enrichment: `soc-lab-normalize` ingest pipeline.
- Buffering/retry: the Beats memory queue with unbounded retry and backoff.
- Routing: Beats index templates and ILM.

**What is genuinely lost.** Logstash's on-disk persistent queue (survives an agent restart better than a memory queue), fan-out to multiple sinks, protocol translation (syslog, Kafka, JDBC inputs), and heavyweight transformations like database enrichment. In a production SOC with many non-Beats sources, or where you must tee data to a second SIEM, Logstash (or an OpenTelemetry collector) earns its place. For one endpoint shipping auditd telemetry, it is a service you maintain for nothing.

**If the processing layer were unavailable** — that is, if ingest pipelines were removed as well — events would still land, but unnormalized: you would be searching `tags` on some documents and `auditd.log.key` on others, with no common `soc.rule_key`, no consistent `event.outcome`, and no way to write one detection rule that covers both shippers.

## Elasticsearch

**What it does.** Stores documents in inverted-index form and answers queries and aggregations over them quickly. It also runs the ingest pipelines, holds the security realm (users, roles) and keeps the alerting state.

**Why it is needed.** Searching text files does not scale past one host or a few megabytes. Aggregations ("events per user per hour") are what turn logs into monitoring.

**If it were unavailable.** Kibana has nothing to show, detection rules cannot run, and the shippers back up and eventually drop events. The whole SOC platform is down.

**Contribution to the SOC workflow.** It is the search engine, not the detection system. It answers questions quickly; a human or a rule still has to ask the right ones.

## Kibana

**What it does.** The analyst interface: Discover for searching, Lens for visualization, Alerting/Security for detection rules, and the management UI for data views and users.

**Why it is needed.** An investigation is an iterative series of questions. Doing that over raw REST calls is possible but slow, and visual aggregation (spike detection, outlier users) is impractical by hand.

**If it were unavailable.** You can still query Elasticsearch with `curl` and alerting rules still fire, but triage time increases dramatically and the correlation work becomes error-prone.

**Contribution to the SOC workflow.** Detection authoring, triage, investigation and reporting.

## The analyst

**What they do.** Decide. Tools surface candidates; the analyst determines whether activity is benign, suspicious or malicious, what the blast radius is, and what should happen next.

**Why they are needed.** Every component above is a trip-wire with no context. Only the analyst knows that a write to `~/soc-lab/security-test.txt` at 14:32 was a scheduled lab exercise and not an intrusion.

**If they were unavailable.** You have logging, not monitoring. Alerts accumulate unread — which is indistinguishable from having no detection at all.

## The one-line version

Collecting logs is *having the data*. Monitoring is *continuously asking questions of the data and acting on the answers*. Parts 1–2 built collection; Part 3 is the first time the environment can actually monitor.
