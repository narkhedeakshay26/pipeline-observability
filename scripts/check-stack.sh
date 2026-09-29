#!/usr/bin/env bash
# Health check for the whole setup, run from anywhere that can reach the monitoring server.
#   ./scripts/check-stack.sh [monitoring-host]     (default: localhost)
set -uo pipefail

MON="${1:-localhost}"
PROM="http://$MON:${PROMETHEUS_PORT:-9090}"
LOKI="http://$MON:${LOKI_PORT:-3100}"
GRAF="http://$MON:${GRAFANA_PORT:-3000}"

check() { if curl -fsS -m 5 "$2" >/dev/null 2>&1; then echo "  [ OK ] $1"; else echo "  [FAIL] $1  ($2)"; fi; }
prom_query() { curl -fsS -m 5 -G "$PROM/api/v1/query" --data-urlencode "query=$1"; }

echo "Services"
check "Prometheus ready" "$PROM/-/ready"
check "Loki ready"       "$LOKI/ready"
check "Grafana healthy"  "$GRAF/api/health"

echo
echo "Hosts scraped by Prometheus (job=node): 1 = up, 0 = down"
prom_query 'up{job="node"}' | python3 -c '
import json, sys
res = json.load(sys.stdin)["data"]["result"]
for r in sorted(res, key=lambda r: r["metric"].get("host", "")):
    m = r["metric"]
    print("  %-16s %-22s %s" % (m.get("host", "?"), m.get("instance", "?"), r["value"][1]))
' 2>/dev/null || echo "  (could not query Prometheus)"

echo
echo "Hosts that have sent logs to Loki"
curl -fsS -m 5 "$LOKI/loki/api/v1/label/host/values" | python3 -c '
import json, sys
vals = json.load(sys.stdin).get("data") or []
print("\n".join("  " + v for v in vals) or "  (none yet)")
' 2>/dev/null || echo "  (could not query Loki)"
