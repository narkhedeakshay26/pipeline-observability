#!/usr/bin/env bash
# Remove node_exporter + Alloy from THIS host. Run as root.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

systemctl disable --now node_exporter 2>/dev/null || true
rm -f /etc/systemd/system/node_exporter.service /usr/local/bin/node_exporter
userdel node_exporter 2>/dev/null || true

systemctl disable --now alloy 2>/dev/null || true
if command -v apt-get >/dev/null; then apt-get remove -y alloy || true
else (dnf remove -y alloy || yum remove -y alloy) || true; fi

systemctl daemon-reload
echo "Agents removed."
