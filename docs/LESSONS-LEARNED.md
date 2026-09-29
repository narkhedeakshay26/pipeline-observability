# Lessons Learned

Mistakes that are easy to make with Prometheus, Loki and Grafana, and how this project
avoids each one. Most produce a dashboard that looks fine but is quietly wrong.

## PromQL

**`count(x == 0)` returns *nothing*, not `0`.**
When no series match, you get an empty result, and the panel shows "No data". The
healthy case (nothing is down) then looks like a broken panel. Count inactive services
as `count(x) - sum(x)` instead, which gives a real `0`.

**`.*` as the "All" value matches series with no label at all.**
`host=~".*"` also matches metrics that have no `host` label, which pulls in unrelated
jobs. Use `.+` as the All value, and always pin `job="node"` as well.

**Stat panels on range queries show one value per timestamp.**
For "current value per host" tiles, use an **instant** query.

**Don't compare raw load averages across machines.**
Load 8 is idle on a 32-core box and overloaded on a 4-core one. Divide by core count.

## Grafana

**`legendFormat` is ignored for table-format queries.**
The display name falls back to *all* label values joined together (instance, job,
device…), and the host name gets lost in the middle. Aggregate with `max by (host) (...)`
so only the label you want survives.

**A table-format query can return one data frame per series.**
A table then shows one row, or a dropdown of frames, instead of one row per series. A
`sortBy` transform on a field that doesn't exist silently does nothing. Add a **Merge**
transform first. This dashboard's Service finder does exactly that.

**`noValue` fires on *any* empty result**, including "this panel doesn't apply to the
current selection". Don't use it for red "OFFLINE" warnings. Map a real value instead.

**Series order from Prometheus is not guaranteed.** If order matters, sort explicitly,
or use one query per series. Grafana keeps queries in refId order.

**Provisioned dashboards are overwritten on restart.** Edit in the UI, export the JSON,
and commit it.

## Loki and log agents

**Filter at the source.** One service logging a line per message can produce more data
than every other service combined. Dropping those lines in the agent is far cheaper than
storing them. Keep periodic summary lines ("Progress report | records=N"), which give you
throughput almost for free.

**Some services log whole payloads at INFO.** That's a storage problem and a privacy
problem (emails, IPs, tokens). Look at a sample of each service's output before you ship
it, and add those patterns to the drop list.

**Keep label cardinality low.** `host`, `role`, `unit` and `level` are labels. Anything
unbounded (request IDs, users, IPs) belongs in the log line, where you search it with
`|=` or `| json`, not in a label.

**Log volume can't tell you a service is dead.** A crashed service and a quiet one look
the same in Loki. Get service state from systemd (`node_systemd_unit_state`), not from
the absence of logs.

**Promtail is end-of-life.** New setups should use Grafana Alloy.

**A Loki selector needs at least one positive matcher**, like `job="systemd-journal"`.
Alloy's `stage.match` selector also only accepts double-quoted strings, not backticks.
`alloy validate` doesn't catch this, but `alloy run` does, so test with a real run.

## Operations

**Open the log port.** Metrics are pulled and logs are pushed, so the firewall needs rules
in both directions. "Metrics fine, no logs" is almost always port 3100.

**Verify binaries you copy between machines.** `sha256sum` at every hop. A truncated
binary can start and then crash in confusing ways.

**Mass restarts cause load spikes.** When a host with hundreds of services reboots,
everything reconnects at once. A load spike in the first minutes after boot is normal.
If it lasts, stagger service start-up.

**Don't let monitoring change what it watches.** The agents only read metrics and
journals. They never restart or reconfigure application services.
