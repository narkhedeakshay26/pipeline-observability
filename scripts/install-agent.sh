#!/usr/bin/env bash
# Install node_exporter + Grafana Alloy on THIS host. Run as root. Safe to re-run.
#
#   sudo ./install-agent.sh --name app-01 --role ingest \
#        --loki-url http://192.0.2.10:3100/loki/api/v1/push
#
# Options:
#   --name NAME          host label (must match inventory/hosts.txt)       [required]
#   --loki-url URL       Loki push URL                                     [required unless --skip-alloy]
#   --role ROLE          role label                                        [default: default]
#   --unit-regex RE      systemd units to watch/ship (no backslashes)      [default: myapp-.+]
#   --drop-regex RE      log lines to drop on the host                     [default: .*(DEBUG|TRACE).*]
#   --skip-node-exporter / --skip-alloy
set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.12.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Works both from a repo checkout (scripts/..) and from deploy-agents.sh's bundle.
AGENT_DIR="$HERE/../agent"; [[ -d "$AGENT_DIR" ]] || AGENT_DIR="$HERE/agent"

NAME="" ROLE="default" LOKI_URL="" UNIT_REGEX="myapp-.+" DROP_REGEX='.*(DEBUG|TRACE).*'
DO_NODE=1 DO_ALLOY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --loki-url) LOKI_URL="$2"; shift 2 ;;
    --unit-regex) UNIT_REGEX="$2"; shift 2 ;;
    --drop-regex) DROP_REGEX="$2"; shift 2 ;;
    --skip-node-exporter) DO_NODE=0; shift ;;
    --skip-alloy) DO_ALLOY=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ -n "$NAME" ]] || die "--name is required"
[[ $DO_ALLOY -eq 0 || -n "$LOKI_URL" ]] || die "--loki-url is required (or pass --skip-alloy)"
[[ "$UNIT_REGEX" != *\\* ]] || die "--unit-regex must not contain backslashes (systemd would mangle them)"
command -v systemctl >/dev/null || die "systemd is required"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU architecture $(uname -m)" ;;
esac

if command -v apt-get >/dev/null; then PKG=apt; ENV_FILE=/etc/default/alloy
elif command -v dnf >/dev/null;   then PKG=dnf; ENV_FILE=/etc/sysconfig/alloy
elif command -v yum >/dev/null;   then PKG=yum; ENV_FILE=/etc/sysconfig/alloy
else die "need apt, dnf or yum"; fi

# ---------------------------------------------------------------- node_exporter
install_node_exporter() {
  log "Installing node_exporter v$NODE_EXPORTER_VERSION ($ARCH)"
  local base="https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION"
  local file="node_exporter-$NODE_EXPORTER_VERSION.linux-$ARCH.tar.gz"
  local tmp; tmp="$(mktemp -d)"

  curl -fsSL -o "$tmp/$file" "$base/$file"
  curl -fsSL -o "$tmp/sha256sums.txt" "$base/sha256sums.txt"
  # Never install a binary you haven't checksum-verified.
  (cd "$tmp" && grep " $file\$" sha256sums.txt | sha256sum -c -) || die "checksum mismatch for $file"

  tar -xzf "$tmp/$file" -C "$tmp"
  install -m 0755 "$tmp/node_exporter-$NODE_EXPORTER_VERSION.linux-$ARCH/node_exporter" /usr/local/bin/node_exporter
  rm -rf "$tmp"

  id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin node_exporter

  local unit; unit="$(cat "$AGENT_DIR/node_exporter/node_exporter.service")"
  printf '%s\n' "${unit//__UNIT_REGEX__/$UNIT_REGEX}" > /etc/systemd/system/node_exporter.service

  systemctl daemon-reload
  systemctl enable node_exporter >/dev/null
  systemctl restart node_exporter
  sleep 2
  curl -fsS http://127.0.0.1:9100/metrics >/dev/null && echo "node_exporter OK on :9100" \
    || die "node_exporter not answering on :9100 (journalctl -u node_exporter)"
}

# ---------------------------------------------------------------- Grafana Alloy
install_alloy() {
  log "Installing Grafana Alloy from the Grafana package repo ($PKG)"
  if ! command -v alloy >/dev/null && [[ ! -x /usr/bin/alloy ]]; then
    if [[ $PKG == apt ]]; then
      apt-get update -qq && apt-get install -y -qq gpg curl ca-certificates >/dev/null
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
      echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
      apt-get update -qq && apt-get install -y -qq alloy
    else
      cat > /etc/yum.repos.d/grafana.repo <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO
      $PKG install -y -q alloy
    fi
  else
    echo "Alloy already installed, updating config only"
  fi

  install -m 0644 "$AGENT_DIR/alloy/config.alloy" /etc/alloy/config.alloy

  # Our settings live in a marked block so re-runs replace, not duplicate, them.
  touch "$ENV_FILE"
  sed -i '/^# BEGIN pipeline-observability/,/^# END pipeline-observability/d' "$ENV_FILE"
  cat >> "$ENV_FILE" <<ENV
# BEGIN pipeline-observability (managed by install-agent.sh)
LOKI_URL="$LOKI_URL"
HOST_LABEL="$NAME"
HOST_ROLE="$ROLE"
UNIT_REGEX="$UNIT_REGEX"
DROP_REGEX="$DROP_REGEX"
# END pipeline-observability
ENV

  # Alloy runs as user 'alloy' and needs permission to read the journal.
  getent group systemd-journal >/dev/null && usermod -aG systemd-journal alloy
  getent group adm >/dev/null && usermod -aG adm alloy

  systemctl enable alloy >/dev/null
  systemctl restart alloy
  sleep 3
  systemctl is-active --quiet alloy && echo "alloy OK (UI/debug: http://127.0.0.1:12345)" \
    || die "alloy failed to start (journalctl -u alloy -n 50)"
}

[[ $DO_NODE  -eq 1 ]] && install_node_exporter
[[ $DO_ALLOY -eq 1 ]] && install_alloy
log "Done: $NAME ($ROLE)"
