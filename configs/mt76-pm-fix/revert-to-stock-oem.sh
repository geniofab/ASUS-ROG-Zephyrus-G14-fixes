#!/bin/bash
# Revert MT7925 custom fixes and return to stock Ubuntu OEM/HWE stack
# - Removes custom mt76 DKMS override and PM workarounds
# - Installs latest ubuntu linux-firmware and OEM kernel meta package
# - Leaves system ready for clean re-evaluation after reboot

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo bash configs/mt76-pm-fix/revert-to-stock-oem.sh"

log "Updating package lists"
apt update

log "Installing OEM kernel meta and latest firmware"
apt install -y linux-firmware linux-oem-24.04b linux-image-oem-24.04b

if dkms status mt76-pm-fix/1.0 2>/dev/null | grep -q .; then
    log "Removing DKMS override: mt76-pm-fix/1.0"
    dkms remove mt76-pm-fix/1.0 --all || true
else
    warn "DKMS override mt76-pm-fix/1.0 not installed"
fi

log "Removing custom MT7925 workaround files"
rm -f /etc/modprobe.d/mt7925-fix.conf
rm -f /etc/udev/rules.d/99-mt7925-aspm.rules
rm -f /usr/lib/systemd/system-sleep/mt7925-reload.sh
rm -f /etc/NetworkManager/conf.d/wifi-powersave-off.conf

log "Refreshing module/initramfs state"
depmod -a || true
update-initramfs -u || true

log "Reloading services"
udevadm control --reload-rules || true
udevadm trigger || true
systemctl daemon-reload
systemctl restart NetworkManager || true

echo ""
log "Rollback complete"
echo "Next steps:"
echo "  1) Reboot into OEM kernel"
echo "  2) Verify stock module path: modinfo mt7925e | grep '^filename:'"
echo "     (should be under /lib/modules/<kernel>/kernel/... and not updates/dkms)"
echo "  3) Verify package versions: apt-cache policy linux-firmware linux-oem-24.04b"
