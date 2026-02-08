#!/bin/bash
# mt7925-resume-fix: Reload mt7925e after suspend/resume
#
# After s2idle resume, the PCI subsystem restores ASPM L1 + all L1 substates
# (L1.1, L1.2 ASPM/PCI-PM) for the MT7925 WiFi device, even though the driver
# disabled ASPM at probe time (disable_aspm=Y). The repeated L1 power-state
# cycling corrupts the MT7925 firmware's TX path, causing silent data stalls:
# the connection appears "up" (associated, good signal, no beacon loss) but
# 100% of packets are dropped.
#
# The only reliable recovery is a full module reload, which resets the firmware
# and re-runs probe (re-disabling ASPM). A simple sysfs ASPM disable is not
# sufficient once the firmware is already in a bad state.
#
# This script installs a systemd system-sleep hook that reloads mt7925e on
# every resume from suspend (s2idle/deep).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Must run as root (sudo)"

HOOK_DIR="/usr/lib/systemd/system-sleep"
HOOK_FILE="${HOOK_DIR}/mt7925-reload.sh"

# ── Install the hook ──────────────────────────────────────────────────
log "Installing systemd system-sleep hook..."

mkdir -p "$HOOK_DIR"

cat > "$HOOK_FILE" << 'HOOK_EOF'
#!/bin/bash
# mt7925-reload: Reload MT7925 WiFi driver after resume from suspend
#
# Fixes ASPM L1 re-enable bug: PCI subsystem restores ASPM L1 + L1 substates
# on resume, corrupting MT7925 firmware TX path. Module reload resets firmware
# and re-probes with ASPM disabled.

case "$1" in
    post)
        logger -t mt7925-reload "Resume detected — reloading mt7925e driver"

        # Unload the driver stack (mt7925e depends on mt7925-common, mt792x-lib, etc.)
        if modprobe -r mt7925e 2>/dev/null; then
            sleep 1
            modprobe mt7925e
            logger -t mt7925-reload "mt7925e reloaded successfully"
        else
            logger -t mt7925-reload "WARNING: failed to unload mt7925e"
        fi

        # Also ensure ASPM is disabled via sysfs (belt and suspenders)
        sleep 2
        for f in l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
            path="/sys/bus/pci/devices/0000:63:00.0/link/${f}"
            if [[ -f "$path" ]]; then
                echo 0 > "$path" 2>/dev/null || true
            fi
        done
        ;;
esac
HOOK_EOF

chmod 755 "$HOOK_FILE"
log "Hook installed: ${HOOK_FILE}"

# ── Verify ────────────────────────────────────────────────────────────
if [[ -x "$HOOK_FILE" ]]; then
    log "Hook is executable and ready"
else
    err "Hook file is not executable"
fi

echo ""
log "================================================"
log " mt7925 resume fix installed"
log "================================================"
echo ""
echo "  On every resume from suspend, mt7925e will be reloaded"
echo "  to reset firmware and re-disable ASPM."
echo ""
echo "  WiFi will briefly disconnect (~3s) during resume while"
echo "  the module reloads. NetworkManager will auto-reconnect."
echo ""
echo "  Verify after next suspend/resume:"
echo "    journalctl -b 0 -t mt7925-reload"
echo "    sudo lspci -s 63:00.0 -vv | grep LnkCtl"
echo "    cat /sys/bus/pci/devices/0000:63:00.0/link/l1_aspm  # → 0"
echo ""
echo "  To remove:"
echo "    sudo rm ${HOOK_FILE}"
echo ""
