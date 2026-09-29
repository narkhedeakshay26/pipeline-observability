#!/usr/bin/env bash
# Install 3 demo workers (myapp-demo@1..3) on a test host. Run as root.
set -euo pipefail
cd "$(dirname "$0")"
install -m 0755 myapp-demo.sh /usr/local/bin/myapp-demo.sh
install -m 0644 myapp-demo@.service /etc/systemd/system/myapp-demo@.service
systemctl daemon-reload
for n in 1 2 3; do systemctl enable --now "myapp-demo@$n"; done
systemctl --no-pager --type=service list-units 'myapp-demo@*'
