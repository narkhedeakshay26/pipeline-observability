# Query Cheat Sheet

Paste these into **Grafana → Explore**, choosing the Prometheus or Loki datasource.

## PromQL (metrics)

```promql
# Which hosts are down right now?
up{job="node"} == 0

# CPU % per host
100 * (1 - avg by (host) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m])))

# Memory % used per host (available, not free)
100 * (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"})

# Filesystems over 80 % full
100 * (1 - node_filesystem_avail_bytes{job="node", fstype!~"tmpfs|overlay"}
          / node_filesystem_size_bytes{job="node", fstype!~"tmpfs|overlay"}) > 80

# Days until the root disk fills, based on the last 6 h trend
(node_filesystem_avail_bytes{job="node", mountpoint="/"}
  / -deriv(node_filesystem_avail_bytes{job="node", mountpoint="/"}[6h])) / 86400 > 0

# Load relative to core count
node_load5{job="node"} / on (instance) group_left count by (instance) (node_cpu_seconds_total{job="node", mode="idle"})

# Every inactive watched service, fleet-wide
node_systemd_unit_state{job="node", state="active"} == 0

# Active services per host
sum by (host) (node_systemd_unit_state{job="node", state="active"})

# Inactive services per host (total − active, so a healthy host shows a real 0)
count by (host) (node_systemd_unit_state{job="node", state="active"})
  - sum by (host) (node_systemd_unit_state{job="node", state="active"})

# Which host runs a given service?
node_systemd_unit_state{job="node", state="active", name=~".*demo@2.*"}

# Services that restarted in the last hour
changes(node_systemd_unit_state{job="node", state="active"}[1h]) > 0
```

## LogQL (logs)

```logql
# Everything from one host
{job="systemd-journal", host="app-01"}

# One service, only errors
{job="systemd-journal", unit="myapp-demo@1.service", level=~"err|crit"}

# Text search (case-insensitive)
{job="systemd-journal"} |~ "(?i)timeout"

# Exclude a pattern
{job="systemd-journal"} != "healthcheck"

# Lines per minute, per service
sum by (unit) (count_over_time({job="systemd-journal"}[1m]))

# Top 5 noisiest services over the last hour
topk(5, sum by (host, unit) (count_over_time({job="systemd-journal"}[1h])))

# Error rate per host
sum by (host) (rate({job="systemd-journal", level=~"err|crit|alert|emerg"}[5m]))

# Throughput pulled out of summary lines: "Progress report | records=123"
sum by (unit) (rate({job="systemd-journal"} |= "Progress report"
  | regexp `records=(?P<records>[0-9]+)` | unwrap records [5m]))

# JSON logs: filter on a field
{job="systemd-journal", unit=~"api-.+"} | json | status >= 500
```

## Useful API calls

```bash
# Prometheus: current value of any query
curl -s -G http://MON:9090/api/v1/query --data-urlencode 'query=up{job="node"}'

# Prometheus: reload config and rules
curl -X POST http://MON:9090/-/reload

# Loki: which hosts have sent logs
curl -s http://MON:3100/loki/api/v1/label/host/values

# Alloy (on a host): what it dropped, and why
curl -s localhost:12345/metrics | grep loki_process_dropped_lines_total
```
