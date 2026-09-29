#!/usr/bin/env bash
# Install the agents on every host in inventory/hosts.txt over SSH.
#
#   LOKI_URL=http://192.0.2.10:3100/loki/api/v1/push ./scripts/deploy-agents.sh [host ...]
#
# Environment:
#   LOKI_URL     required: Loki push URL, as the *agents* reach it
#   SSH_USER     remote user with sudo            (default: current user)
#   SSH_OPTS     extra ssh options, e.g. "-J me@bastion.example.com -i ~/.ssh/id_ed25519"
#   UNIT_REGEX   passed to install-agent.sh       (default: myapp-.+)
#   DROP_REGEX   passed to install-agent.sh       (default: .*(DEBUG|TRACE).*)
#   DRY_RUN=1    print what would happen, change nothing
# Pass host names to deploy only to those; otherwise every host is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="$ROOT/inventory/hosts.txt"
: "${LOKI_URL:?set LOKI_URL, e.g. http://<monitoring-ip>:3100/loki/api/v1/push}"
SSH_USER="${SSH_USER:-$USER}"
read -r -a SSH_ARGS <<< "${SSH_OPTS:-}"
SSH_ARGS+=(-o ConnectTimeout=10)
ONLY=("$@")

[[ -f "$INVENTORY" ]] || { echo "No inventory at $INVENTORY"; exit 1; }

ok=() failed=()
while read -r name ip role _; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  if [[ ${#ONLY[@]} -gt 0 && ! " ${ONLY[*]} " =~ " $name " ]]; then continue; fi

  echo "================ $name ($ip, ${role:-default}) ================"
  args=(--name "$name" --role "${role:-default}" --loki-url "$LOKI_URL"
        --unit-regex "${UNIT_REGEX:-myapp-.+}" --drop-regex "${DROP_REGEX:-.*(DEBUG|TRACE).*}")

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "would copy agent/ + install-agent.sh to $SSH_USER@$ip and run: sudo bash install-agent.sh ${args[*]}"
    continue
  fi

  # 1) Copy the bundle (tar over ssh works through jump hosts, unlike some scp setups).
  if tar -C "$ROOT" -czf - agent scripts/install-agent.sh \
      | ssh "${SSH_ARGS[@]}" "$SSH_USER@$ip" 'rm -rf /tmp/po-agent && mkdir -p /tmp/po-agent && tar -xzf - -C /tmp/po-agent' \
      && ssh -t "${SSH_ARGS[@]}" "$SSH_USER@$ip" \
           "sudo bash /tmp/po-agent/scripts/install-agent.sh $(printf '%q ' "${args[@]}")" </dev/tty; then
    ok+=("$name")
  else
    failed+=("$name")
  fi
done < "$INVENTORY"

echo
echo "Succeeded: ${ok[*]:-none}"
echo "Failed:    ${failed[*]:-none}"
[[ ${#failed[@]} -eq 0 ]]
