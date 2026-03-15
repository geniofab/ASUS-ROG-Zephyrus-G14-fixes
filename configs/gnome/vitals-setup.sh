#!/bin/bash
# Configure GNOME Vitals extension for Zephyrus G14 telemetry
# Sets panel sensors to: CPU %, GPU %, RAM %, Battery power (W)
# Fixes "Battery: no data" by selecting BAT1 (this laptop uses BAT1, not BAT0/BATT).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

command -v gnome-extensions >/dev/null || err "gnome-extensions not found (install GNOME Shell integration tools)"
command -v dconf >/dev/null || err "dconf not found"

EXT_ID="Vitals@CoreCoding.com"

if ! gnome-extensions info "$EXT_ID" >/dev/null 2>&1; then
    err "Vitals extension is not installed. Install it from https://extensions.gnome.org/extension/1460/vitals/"
fi

if ! gnome-extensions info "$EXT_ID" | grep -q "Enabled: Yes"; then
    warn "Vitals is installed but disabled; enabling now"
    gnome-extensions enable "$EXT_ID" || true
fi

log "Detecting battery name in /sys/class/power_supply..."
battery_name=""
for candidate in BAT1 BAT0 BAT2 BATT CMB0 CMB1 CMB2 macsmc-battery; do
    if [[ -e "/sys/class/power_supply/${candidate}/uevent" ]]; then
        battery_name="$candidate"
        break
    fi
done

if [[ -z "$battery_name" ]]; then
    warn "No known battery path found; keeping current battery-slot setting"
else
    # Vitals slot mapping from prefs.ui
    # 0: BAT0, 1: BAT1, 2: BAT2, 3: BATT, 4: CMB0, 5: CMB1, 6: CMB2, 7: macsmc-battery
    case "$battery_name" in
        BAT0) battery_slot=0 ;;
        BAT1) battery_slot=1 ;;
        BAT2) battery_slot=2 ;;
        BATT) battery_slot=3 ;;
        CMB0) battery_slot=4 ;;
        CMB1) battery_slot=5 ;;
        CMB2) battery_slot=6 ;;
        macsmc-battery) battery_slot=7 ;;
        *) battery_slot=1 ;;
    esac

    log "Setting Vitals battery-slot to ${battery_slot} (${battery_name})"
    dconf write /org/gnome/shell/extensions/vitals/battery-slot "$battery_slot"
fi

log "Enabling required sensor groups"
dconf write /org/gnome/shell/extensions/vitals/show-processor true
dconf write /org/gnome/shell/extensions/vitals/show-gpu true
dconf write /org/gnome/shell/extensions/vitals/show-memory true
dconf write /org/gnome/shell/extensions/vitals/show-battery true

log "Detecting GPU sensor key"
gpu_hot_sensor="_gpu#1_utilization_"

# If NVIDIA telemetry is available, Vitals uses nvidia-smi and indexes GPUs as gpu#1..N
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    gpu_hot_sensor="_gpu#1_utilization_"
else
    # Fallback to DRM gpu_busy_percent (typically AMD iGPU): key is _gpu#<card index>_usage_
    gpu_busy_path=$(ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -n1 || true)
    if [[ -n "$gpu_busy_path" ]]; then
        gpu_card=$(basename "$(dirname "$(dirname "$gpu_busy_path")")")
        gpu_index=${gpu_card#card}
        if [[ "$gpu_index" =~ ^[0-9]+$ ]]; then
            gpu_hot_sensor="_gpu#${gpu_index}_usage_"
        fi
    fi
fi

log "Using GPU sensor key: ${gpu_hot_sensor}"
log "Setting panel hot sensors: CPU %, GPU %, RAM %, Battery power"
dconf write /org/gnome/shell/extensions/vitals/hot-sensors "['_processor_usage_', '${gpu_hot_sensor}', '_memory_usage_', '_battery_battery_']"

log "Reloading Vitals extension"
gnome-extensions disable "$EXT_ID" || true
gnome-extensions enable "$EXT_ID"

echo ""
log "Vitals configuration applied"
echo "  battery-slot : $(dconf read /org/gnome/shell/extensions/vitals/battery-slot 2>/dev/null || echo unknown)"
echo "  hot-sensors  : $(dconf read /org/gnome/shell/extensions/vitals/hot-sensors 2>/dev/null || echo unknown)"

echo ""
echo "If GPU usage stays near 0%, the NVIDIA dGPU may be idle in hybrid mode (normal)."
echo "Battery wattage sign is inferred from State (Charging/Discharging)."
