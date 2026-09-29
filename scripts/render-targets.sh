#!/usr/bin/env bash
# Turn inventory/hosts.txt into a Prometheus file_sd targets file.
#   ./scripts/render-targets.sh [inventory] [output]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="${1:-$ROOT/inventory/hosts.txt}"
OUTPUT="${2:-$ROOT/prometheus/targets/nodes.yml}"
PORT="${NODE_EXPORTER_PORT:-9100}"

[[ -f "$INVENTORY" ]] || { echo "No inventory at $INVENTORY (copy inventory/hosts.example.txt)"; exit 1; }

tmp="$(mktemp)"
echo "# Generated from $(basename "$INVENTORY") by render-targets.sh on $(date -u +%FT%TZ). Do not edit." > "$tmp"

count=0
while read -r name ip role _; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  [[ -n "${ip:-}" ]] || { echo "Line for '$name' has no IP"; exit 1; }
  [[ "$name" =~ ^[A-Za-z0-9-]+$ ]] || { echo "Bad host name '$name' (letters, digits, dash only)"; exit 1; }
  printf -- '- targets: ["%s:%s"]\n  labels: { host: "%s", role: "%s" }\n' \
    "$ip" "$PORT" "$name" "${role:-default}" >> "$tmp"
  count=$((count + 1))
done < "$INVENTORY"

# Write atomically: Prometheus watches this file and could read a half-written one.
mv "$tmp" "$OUTPUT"
chmod 644 "$OUTPUT"
echo "Wrote $count target(s) to $OUTPUT"
