# SOC Investigation Timeline — Part 20

All times in **UTC**, taken from Kibana so the ordering is consistent across hosts. Set Kibana's timezone explicitly: **Stack Management → Advanced Settings → `dateFormat:tz` → `UTC`**.

| Time (UTC) | Event | System | User | Analyst observation |
| --- | --- | --- | --- | --- |
| | Audit rule `soc_file_monitor` loaded | soc-endpoint | root | Baseline: detection surface established |
| | Auditbeat started shipping to soc-server | soc-endpoint | root | Transport verified over Tailscale |
| | Controlled write to `~/soc-lab/security-test.txt` | soc-endpoint | | Source event; `process.executable` = |
| | Event indexed into `auditbeat-*` (`event.ingested`) | soc-server | — | Pipeline latency: <n> s |
| | Detection rule fired | soc-server | — | Rule: SOC - Monitored file activity |
| | Alert triaged in Kibana | soc-server | analyst | First analyst action; time-to-triage: <n> min |
| | Determination recorded | — | analyst | Benign / Suspicious / Malicious |

## How to populate this accurately

1. In Discover, add the columns `@timestamp`, `event.ingested`, `host.name`, `user.name`, `process.executable`, `file.path`, `event.outcome`.
2. Sort ascending by `@timestamp` and narrow the time picker to the ten minutes around your test.
3. Copy timestamps verbatim — do not round them. Precision is part of the evidence.
4. For the rule-fired time, use **Stack Management → Rules → <rule> → Alerts** (or the alert's `kibana.alert.start`).

## Metrics worth calling out in the report

- **Detection latency** = `event.ingested` − `@timestamp` (how long the pipeline took).
- **Alert latency** = alert start − `@timestamp` (pipeline plus rule schedule; bounded below by your 1-minute rule interval).
- **Time to triage** = analyst first action − alert start. In this lab it is however long you took to look; in a real SOC it is an SLA.
