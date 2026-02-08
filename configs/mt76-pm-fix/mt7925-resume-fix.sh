#!/bin/bash
# mt7925-aspm-fix: Disable ASPM L1 substates for MT7925 at boot AND after resume
#
# The mt7925e driver's `disable_aspm=Y` parameter disables ASPM L1 at PCI link
# level, but does NOT disable the L1 substates (L1.1, L1.2 ASPM and PCI-PM).
# These substates put the PCIe link into deep low-power modes that corrupt
# the MT7925 firmware's TX path, causing silent data stalls every ~5 minutes.
#
# Additionally, after s2idle resume the PCI subsystem restores ALL ASPM states
# (including L1 itself), and the firmware ends up in a bad state that requires
# a full module reload to recover.
#
# This script installs:
# 1. A udev rule to disable L1 substates when the MT7925 is detected at boot
# 2. A systemd system-sleep hook to reload mt7925e + disable ASPM after resume

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Must run as root (sudo)"

# ── 1. udev rule: disable L1 substates at boot ───────────────────────
UDEV_FILE="/etc/udev/rules.d/99-mt7925-aspm.rules"
log "Installing udev rule: ${UDEV_FILE}"

cat > "$UDEV_FILE" << 'UDEV_EOF'
# Disable ASPM L1 substates for MediaTek MT7925 WiFi (PCI 14c3:7925)
# The driver's disable_aspm=Y only disables L1, not L1.1/L1.2 substates
# which cause silent TX stalls every ~5 minutes.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x7925", \
  ATTR{link/l1_aspm}="0", \
  ATTR{link/l1_1_aspm}="0", \
  ATTR{link/l1_2_aspm}="0", \
  ATTR{link/l1_1_pcipm}="0", \
  ATTR{link/l1_2_pcipm}="0"
UDEV_EOF

log "udev rule installed"

# ── 2. system-sleep hook: reload driver after resume ──────────────────
HOOK_DIR="/usr/lib/systemd/system-sleep"
HOOK_FILE="${HOOK_DIR}/mt7925-reload.sh"
log "Installing system-sleep hook: ${HOOK_FILE}"

mkdir -p "$HOOK_DIR"

cat > "$HOOK_FILE" << 'HOOK_EOF'
#!/bin/bash
# mt7925-reload: Reload MT7925 WiFi driver + disable ASPM after resume
#
# After s2idle resume, PCI restores ASPM L1 + L1 substates, corrupting
# the MT7925 firmware TX path. Module reload resets firmware, and the
# udev rule + explicit sysfs writes disable ASPM again.

case "$1" in
    post)
        logger -t mt7925-reload "Resume detected — reloading mt7925e driver"

        # Unload the driver stack
        if modprobe -r mt7925e 2>/dev/null; then
            sleep 1
            modprobe mt7925e
            logger -t mt7925-reload "mt7925e reloaded successfully"
        else
            logger -t mt7925-reload "WARNING: failed to unload mt7925e — forcing ASPM disable"
        fi

        # Disable all ASPM (belt and suspenders — udev should also trigger on re-probe)
        sleep 2
        for dev in /sys/bus/pci/devices/*/; do
            if [[ -f "${dev}vendor" && -f "${dev}device" ]]; then
                vendor=$(cat "${dev}vendor" 2>/dev/null)
                device=$(cat "${dev}device" 2>/dev/null)
                if [[ "$vendor" == "0x14c3" && "$device" == "0x7925" ]]; then
                    for f in l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
                        [[ -f "${dev}link/${f}" ]] && echo 0 > "${dev}link/${f}" 2>/dev/null || true
                    done
                    logger -t mt7925-reload "ASPM disabled for $(basename "$dev")"
                fi
            fi
        done
        ;;
esac
HOOK_EOF

chmod 755 "$HOOK_FILE"
log "system-sleep hook installed"

# ── 3. Apply immediately ─────────────────────────────────────────────
log "Applying ASPM disable now..."
for f in l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
    path="/sys/bus/pci/devices/0000:63:00.0/link/${f}"
    if [[ -f "$path" ]]; then
        echo 0 > "$path" 2>/dev/null || true
    fi
done

# Reload udev rules
udevadm control --reload-rules 2>/dev/null || true
log "udev rules reloaded"

# ── Verify ────────────────────────────────────────────────────────────
ALL_OFF=true
for f in l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
    val=$(cat "/sys/bus/pci/devices/0000:63:00.0/link/${f}" 2>/dev/null)
    if [[ "$val" != "0" ]]; then
        warn "${f} = ${val} (expected 0)"
        ALL_OFF=false
    fi
done
if $ALL_OFF; then
    log "All ASPM states disabled successfully"
fi

echo ""
log "================================================"
log " mt7925 ASPM fix installed"
log "================================================"
echo ""
echo "  Installed:"
echo "    • ${UDEV_FILE} — disables L1 substates at boot"
echo "    • ${HOOK_FILE} — reloads driver + disables ASPM after resume"
echo ""
echo "  No reboot required — fix is active now."
echo ""
echo "  Verify:"
echo "    cat /sys/bus/pci/devices/0000:63:00.0/link/l1_aspm       # → 0"
echo "    sudo lspci -s 63:00.0 -vv | grep LnkCtl                 # → ASPM Disabled"
echo "    journalctl -b 0 -t mt7925-reload                         # after resume"
echo ""
echo "  Remove:"
echo "    sudo rm ${UDEV_FILE} ${HOOK_FILE}"
echo ""
