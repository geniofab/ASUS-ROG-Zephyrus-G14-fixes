#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

mkdir -p "$BIN_DIR" "$SYSTEMD_USER_DIR"

install -m 755 "$ROOT_DIR/configs/power/g14-power-mode.sh" "$BIN_DIR/g14-power-mode.sh"
install -m 644 "$ROOT_DIR/configs/power/systemd-user/g14-power-acdc-monitor.service" "$SYSTEMD_USER_DIR/g14-power-acdc-monitor.service"
install -m 644 "$ROOT_DIR/configs/power/systemd-user/g14-power-startup-eco.service" "$SYSTEMD_USER_DIR/g14-power-startup-eco.service"

systemctl --user daemon-reload
systemctl --user enable --now g14-power-acdc-monitor.service
systemctl --user enable --now g14-power-startup-eco.service

if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set power-saver || true
fi

"$BIN_DIR/g14-power-mode.sh" apply --logout-on-pending no || true

echo "Installed Ubuntu-menu power mapper and AC/DC monitor."
echo "Startup default set to: power-saver"
echo ""
echo "Required once for GPU mode switching support:"
echo "  sudo systemctl enable --now supergfxd.service"
