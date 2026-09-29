# Pipeline Observability: Complete Guide

This guide takes you from nothing to a working dashboard, then covers day-2 operations.
Allow about 30 minutes for a first install.

- [0. How it works](#0-how-it-works)
- [1. Prerequisites](#1-prerequisites)
- [2. Plan your ports and firewall](#2-plan-your-ports-and-firewall)
- [3. Add your hosts (the inventory)](#3-add-your-hosts-the-inventory)
- [4. Start the central stack](#4-start-the-central-stack)
- [5. Install the agents](#5-install-the-agents)
- [6. (Optional) Run the demo service](#6-optional-run-the-demo-service)
- [7. Verify end to end](#7-verify-end-to-end)
- [8. Using the dashboard](#8-using-the-dashboard)
- [9. Customising for your services](#9-customising-for-your-services)
- [10. Day-2 operations](#10-day-2-operations)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Hardening for production](#12-hardening-for-production)
- [13. Uninstall](#13-uninstall)

---

## 0. How it works

| Component | Runs on | Job |
|---|---|---|
| **node_exporter** | every host | Exposes host metrics and systemd unit state on `:9100/metrics` |
| **Grafana Alloy** | every host | Reads the systemd journal, keeps only your services, drops noisy lines, pushes to Loki |
| **Prometheus** | monitoring server | Pulls (scrapes) every node_exporter every 15 s and stores metrics for 15 days |
| **Loki** | monitoring server | Receives and stores logs for 7 days. Indexes labels only, so it is cheap |
| **Grafana** | monitoring server | Dashboard over both |

Metrics are **pulled**: Prometheus connects to each host. Logs are **pushed**: each host
connects to Loki. That's why the firewall rules go in both directions (step 2).

Labels on every series and every log stream:

| Label | Source | Example |
|---|---|---|
| `host` | inventory name | `app-01` |
| `role` | inventory role | `ingest` |
| `job` | fixed | `node` (metrics), `systemd-journal` (logs) |
| `unit` | journald, logs only | `myapp-demo@1.service` |
| `level` | journald priority, logs only | `info`, `err` |
| `name` | systemd collector, metrics only | `myapp-demo@1.service` |

## 1. Prerequisites

**Monitoring server** (1 VM is plenty for dozens of hosts):
- Linux with Docker Engine and the Compose plugin (`docker compose version` works)
- 2 vCPU, 4 GB RAM, 50 GB disk to start. Loki and Prometheus data grow with retention
- Reachable from all hosts on port 3100, and able to reach all hosts on port 9100

**Each monitored host:**
- Linux with systemd (Debian/Ubuntu, or RHEL/Rocky/Alma/Fedora)
- `curl`, internet access to `github.com` and `apt.grafana.com` / `rpm.grafana.com`
  (for air-gapped hosts, see [§10](#air-gapped-hosts))
- An SSH user with `sudo`

**Your laptop:** `git`, `ssh`, `bash`, `python3` (used by `check-stack.sh` only).

## 2. Plan your ports and firewall

| Port | On | Opened to | Why |
|---|---|---|---|
| 3000/tcp | monitoring server | you / your team | Grafana UI |
| 9090/tcp | monitoring server | you (optional) | Prometheus UI. Can stay closed |
| 3100/tcp | monitoring server | **all monitored hosts** | Alloy pushes logs here |
| 9100/tcp | each host | **monitoring server only** | Prometheus scrapes here |

**firewalld** (RHEL family), for example:
```bash
# on the monitoring server
sudo firewall-cmd --permanent --add-port=3000/tcp --add-port=3100/tcp
# on each host: allow only the monitoring server to reach node_exporter
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.0.2.10/32" port port="9100" protocol="tcp" accept'
sudo firewall-cmd --reload
```

**ufw** (Ubuntu):
```bash
sudo ufw allow 3000/tcp && sudo ufw allow 3100/tcp            # monitoring server
sudo ufw allow from 192.0.2.10 to any port 9100 proto tcp      # each host
```

Cloud VMs also have a provider-level firewall (security groups, VPC rules). Open the
same ports there.

> **Most common first-day failure:** everything is installed but no logs arrive,
> because 3100 was never opened. Alloy's log will show `no route to host` or
> `connection refused`. See [§11](#11-troubleshooting).

## 3. Add your hosts (the inventory)

The inventory is the **only place IPs live**.

```bash
cp inventory/hosts.example.txt inventory/hosts.txt
```

```text
# name      ip             role
app-01      10.0.1.11      ingest
app-02      10.0.1.12      ingest
app-03      10.0.1.21      worker
```

- `name`: short, unique, letters/digits/dash. It becomes the `host` label on metrics
  **and** logs, which is what links the two in the dashboard.
- `ip`: what Prometheus scrapes and SSH connects to.
- `role`: any grouping you like. It becomes the dashboard's Role filter.

`inventory/hosts.txt` is in `.gitignore`, so real addresses never reach GitHub.

Generate the Prometheus targets file from it:
```bash
./scripts/render-targets.sh
# → Wrote 3 target(s) to prometheus/targets/nodes.yml
```

## 4. Start the central stack

On the monitoring server:

```bash
git clone https://github.com/narkhedeakshay26/pipeline-observability.git
cd pipeline-observability
cp .env.example .env && vi .env          # set GRAFANA_ADMIN_PASSWORD at least
# copy your inventory/hosts.txt here too, then:
./scripts/render-targets.sh
docker compose up -d
docker compose ps                         # all three should be "running"
```

Check each piece:
```bash
curl -s localhost:9090/-/ready            # Prometheus Server is Ready.
curl -s localhost:3100/ready              # ready  (may say "not ready" for ~15 s after start)
curl -s localhost:3000/api/health         # {"database":"ok",...}
```

Open `http://<monitoring-server>:3000`, log in with the `.env` credentials, and go to
**Dashboards → Pipeline Observability**. It will be empty until agents are installed.

## 5. Install the agents

### Option A: all hosts from your laptop (recommended)

```bash
LOKI_URL=http://<monitoring-server-ip>:3100/loki/api/v1/push \
SSH_USER=youruser \
./scripts/deploy-agents.sh
```

- Behind a bastion/jump host: `SSH_OPTS="-J you@bastion.example.com"`.
- Specific hosts only: `./scripts/deploy-agents.sh app-01 app-03`.
- Preview without changing anything: `DRY_RUN=1 ./scripts/deploy-agents.sh`.
- It prompts for the sudo password per host if your sudo needs one.

### Option B: one host by hand

```bash
scp -r agent scripts/install-agent.sh you@10.0.1.11:/tmp/po/
ssh you@10.0.1.11
sudo bash /tmp/po/install-agent.sh --name app-01 --role ingest \
     --loki-url http://<monitoring-server-ip>:3100/loki/api/v1/push
```

### What the installer does

1. Downloads node_exporter from its official GitHub release and **verifies the
   SHA-256 checksum** before installing it to `/usr/local/bin`.
2. Creates a locked-down `node_exporter` system user and a systemd unit with the
   systemd collector limited to `--unit-regex` (default `myapp-.+`).
3. Adds the Grafana package repository and installs `alloy`.
4. Copies `config.alloy` to `/etc/alloy/` and writes your settings (Loki URL, host name,
   role, regexes) into a marked block in `/etc/default/alloy` or `/etc/sysconfig/alloy`.
   Re-running replaces the block rather than duplicating it.
5. Adds the `alloy` user to `systemd-journal`/`adm` so it can read the journal.
6. Starts both and fails loudly if either doesn't come up.

It never touches your application services.

## 6. (Optional) Run the demo service

No pipeline services yet? Install three fake workers on any host:

```bash
scp -r examples/demo-service you@10.0.1.11:/tmp/
ssh you@10.0.1.11 'sudo bash /tmp/demo-service/install-demo.sh'
```

Each `myapp-demo@N` writes:
- a `DEBUG ...` line every second: **dropped by the agent**, so it never reaches Loki
- a `Progress report | worker=N records=123` line every 10 s: feeds the throughput panel
- an occasional `ERROR ...` line at journald priority `err`: feeds the Errors panel

To see an inactive service on the dashboard: `sudo systemctl stop myapp-demo@3`.

## 7. Verify end to end

```bash
./scripts/check-stack.sh <monitoring-server-ip>
```
```text
Services
  [ OK ] Prometheus ready
  [ OK ] Loki ready
  [ OK ] Grafana healthy

Hosts scraped by Prometheus (job=node): 1 = up, 0 = down
  app-01           10.0.1.11:9100         1
  app-02           10.0.1.12:9100         1

Hosts that have sent logs to Loki
  app-01
  app-02
```

A host that is `up` but missing from the Loki list means node_exporter works but Alloy
can't push. Check port 3100 and `journalctl -u alloy`.

## 8. Using the dashboard

**Top bar variables**

- **Role / Host**: multi-select. "All" matches every host that has a `host` label
  (`.+`), never hosts without one.
- **Search**: filters the Service finder by unit name and the Live logs panel by text
  (case-insensitive). Leave it empty to show everything.

**Fleet overview**

| Panel | Reads | Notes |
|---|---|---|
| Host status | `up` | UP/DOWN tile per host |
| CPU usage | `node_cpu_seconds_total` | % busy, all cores averaged |
| Memory used | `MemAvailable / MemTotal` | Uses *available*, not *free*: Linux cache isn't "used" |
| Root disk used | `node_filesystem_*` on `/` | Orange at 75 %, red at 90 % |
| Load per CPU core | `node_load5 / cores` | 1.0 = fully busy. Comparable across host sizes |
| Network traffic | `node_network_*_bytes_total` | In above zero, out below zero. Virtual interfaces excluded |

**Services**

| Panel | Notes |
|---|---|
| Active / Inactive services | Per host. Inactive is `total − active`, so a healthy host shows a real **0** |
| Service finder | Every watched unit with Host, Role, Service, Status. Filter any column with its funnel icon |

**Logs**

| Panel | Notes |
|---|---|
| Log volume by service | Lines per interval after filtering. A spike usually means someone turned on verbose logging |
| Errors by host | Lines at priority `err` or worse |
| Throughput from logs | Sums the `records=N` value from "Progress report" lines. See §9 |
| Live logs | Newest first. Click a line to see all its labels |

## 9. Customising for your services

**Which services are watched.** Pass `--unit-regex` (or `UNIT_REGEX=` to deploy-agents).
It is used by *both* agents, so metrics and logs stay consistent:
```bash
UNIT_REGEX='(ingest|forwarder|consumer)-.+' ./scripts/deploy-agents.sh
```
Don't use backslashes. systemd rewrites them inside `ExecStart`. `.+` is fine.

**What gets dropped.** Pass `--drop-regex`. Put the noisiest and most sensitive
patterns here. Examples:
```bash
DROP_REGEX='.*(DEBUG|TRACE|Message received|payload=).*'
```
Before you tighten it, measure how many lines a busy service produces:
```bash
journalctl -u 'myapp-*' --since '-1 min' | wc -l     # lines per minute, on the host
```
Alloy counts what it drops, split by reason, at
`curl -s localhost:12345/metrics | grep loki_process_dropped_lines_total`.

**Throughput from your own log format.** Edit the *Throughput from logs* panel query:
```logql
sum by (host, unit) (
  rate({job="systemd-journal", host=~"$host"} |= "Progress report"
       | regexp `records=(?P<records>[0-9]+)` | unwrap records [$__auto]))
```
Change the `|= "..."` filter to your summary line, and the regex to capture its count.
If your service prints JSON, use `| json | unwrap your_field` instead.

The log panels have a **minimum interval of 1m** (panel → Query options). If your
service writes its summary line less often than once a minute, raise it to at least
that gap. Otherwise most intervals contain no summary line and the graph looks empty.

**Retention.** Metrics: `PROMETHEUS_RETENTION` in `.env`. Logs:
`limits_config.retention_period` in `loki/loki-config.yml`. Then run `docker compose up -d`.

## 10. Day-2 operations

**Add a host:** add a line to `inventory/hosts.txt`, then:
```bash
./scripts/render-targets.sh        # Prometheus picks it up within 1 minute, no restart
LOKI_URL=... ./scripts/deploy-agents.sh app-05
```

**Remove a host:** delete its line, re-run `render-targets.sh`, and run
`scripts/uninstall-agent.sh` on it.

**Change Prometheus config or rules without a restart:**
```bash
curl -X POST localhost:9090/-/reload
```

**Edit the dashboard:** edit it in the Grafana UI, then **Export → Export as JSON**
and save over `grafana/dashboards/pipeline-observability.json`. Commit it, so the repo
stays the source of truth.

**Upgrade:** bump the version in `.env`, then `docker compose pull && docker compose up -d`.
For agents, set `NODE_EXPORTER_VERSION=` and re-run `deploy-agents.sh`. Alloy upgrades
with the OS package manager.

**Back up:** the only state is the three Docker volumes. Everything else is in git.
```bash
docker run --rm -v pipeline-observability_grafana-data:/d -v "$PWD":/b alpine tar czf /b/grafana-data.tgz -C /d .
```

### Air-gapped hosts
Download the node_exporter tarball and the Alloy `.deb`/`.rpm` on a machine with
internet, copy them over, and install by hand. `sha256sum -c` the tarball against the
release's `sha256sums.txt` at every hop. Silently corrupted copies are a real thing.

## 11. Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Host shows DOWN | 9100 blocked, or node_exporter stopped | From the monitoring server: `curl http://<ip>:9100/metrics`. On the host: `systemctl status node_exporter` |
| Host UP but no logs | 3100 blocked, or wrong `LOKI_URL` | On the host: `curl -s -o /dev/null -w '%{http_code}' http://<mon>:3100/ready`. Then `journalctl -u alloy -n 50` |
| Alloy log: `permission denied` on journal | `alloy` user not in `systemd-journal` | `sudo usermod -aG systemd-journal alloy && sudo systemctl restart alloy` |
| Logs arrive but not for my service | `UNIT_REGEX` doesn't match | `systemctl list-units 'yourprefix*'` and compare. The regex matches the full unit name, including `.service` |
| Service finder empty | Same regex, on node_exporter | `curl -s localhost:9100/metrics \| grep node_systemd_unit_state \| head` |
| Memory/Load panels empty on some hosts | Non-Linux host | Those metrics are Linux-specific |
| Loki says `not ready` | Normal for ~15 s after start | Wait, then check `docker compose logs loki` |
| Loki `429 Too Many Requests` | A host is flooding logs | Tighten `DROP_REGEX`, or raise `ingestion_rate_mb` |
| Grafana shows "No data" everywhere | Datasource can't reach its backend | Grafana → Connections → Data sources → **Test** |
| Dashboard edits vanish after restart | Provisioned file overwrote them | Export and commit the JSON (§10) |

**Alloy's built-in UI** shows every component and whether it is healthy. Open a tunnel
to it:
```bash
ssh -L 12345:127.0.0.1:12345 you@app-01      # then open http://localhost:12345
```

## 12. Hardening for production

- **Change the Grafana admin password**, and create named user accounts. Don't share admin.
- **Loki and Prometheus have no authentication.** Keep 3100/9090 on a private network,
  or put them behind a reverse proxy (nginx/Caddy) with TLS and basic auth. Alloy supports
  `basic_auth` and TLS in its `loki.write` endpoint block.
- **Restrict 9100** on each host to the monitoring server's IP only (§2).
- **Put TLS in front of Grafana** if anyone reaches it outside a VPN.
- **Treat logs as sensitive.** Use `DROP_REGEX` to strip lines that contain payloads,
  tokens or personal data *before* they leave the host.
- **Keep `.env` and `inventory/hosts.txt` out of git** (already in `.gitignore`). Run
  `git status` before every commit.

## 13. Uninstall

On each host:
```bash
sudo bash scripts/uninstall-agent.sh
```
On the monitoring server:
```bash
docker compose down          # keeps data volumes
docker compose down -v       # also deletes all stored metrics, logs and Grafana state
```
