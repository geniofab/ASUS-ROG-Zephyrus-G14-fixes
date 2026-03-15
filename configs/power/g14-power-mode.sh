#!/bin/bash
set -euo pipefail

SCRIPT_NAME="g14-power-mode"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/g14-power"
LOG_FILE="$STATE_DIR/apply.log"
REPORTED_MODE_FILE="$STATE_DIR/reported_mode"
NOTIFY_STATE_FILE="$STATE_DIR/last_notify"

mkdir -p "$STATE_DIR"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$*" | tee -a "$LOG_FILE" >/dev/null
}

warn() {
  log "WARN: $*"
}

die() {
  log "ERROR: $*"
  echo "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

normalize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

get_power_source() {
  local ac
  for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online /sys/class/power_supply/ACAD/online; do
    if [[ -f "$ac" ]]; then
      if [[ "$(cat "$ac")" == "1" ]]; then
        echo "ac"
      else
        echo "dc"
      fi
      return
    fi
  done

  if has_cmd upower && upower -e | grep -q line_power; then
    if upower -i "$(upower -e | grep line_power | head -n1)" | grep -qi 'online:\s*yes'; then
      echo "ac"
    else
      echo "dc"
    fi
    return
  fi

  echo "dc"
}

set_asus_profile() {
  local target="$1"
  if ! has_cmd asusctl; then
    warn "asusctl not found; skipping ASUS profile"
    return
  fi

  local current
  current="$(asusctl profile get 2>/dev/null | awk -F': ' '/Active profile/{print $2; exit}')"
  if [[ "$current" == "$target" ]]; then
    return
  fi

  if asusctl profile set "$target" >/dev/null 2>&1; then
    log "Set ASUS profile: $target"
  else
    warn "Failed to set ASUS profile to $target"
  fi
}

supergfx_active() {
  systemctl is-active --quiet supergfxd.service 2>/dev/null
}

run_supergfx() {
  if ! has_cmd supergfxctl; then
    return 127
  fi
  timeout -k 1s 5s supergfxctl "$@" 2>/dev/null
}

get_pending_action() {
  local action
  action="$(run_supergfx -p | tr -d '[:space:]' || true)"
  if [[ -z "$action" || "$(normalize "$action")" == "none" || "$(normalize "$action")" == "unknown" || "$(normalize "$action")" == "noactionrequired" ]]; then
    echo "none"
  else
    echo "$action"
  fi
}

get_pending_mode() {
  local mode
  mode="$(run_supergfx -P | tr -d '[:space:]' || true)"
  if [[ -z "$mode" || "$(normalize "$mode")" == "unknown" ]]; then
    echo "none"
  else
    echo "$mode"
  fi
}

notify_pending_logout() {
  local target="$1"
  local action="$2"
  local key
  key="${target}:${action}"

  if [[ -f "$NOTIFY_STATE_FILE" ]] && [[ "$(cat "$NOTIFY_STATE_FILE" 2>/dev/null || true)" == "$key" ]]; then
    return
  fi

  printf '%s\n' "$key" > "$NOTIFY_STATE_FILE"

  if has_cmd notify-send; then
    notify-send "Power mode pending" "GPU switch to ${target} is pending (${action}). Log out to complete transition." || true
  fi
}

supergfx_reported_mode() {
  if [[ -f "$REPORTED_MODE_FILE" ]]; then
    tr -d '[:space:]' < "$REPORTED_MODE_FILE"
    return
  fi
  echo "unknown"
}

cache_reported_mode() {
  local mode="$1"
  printf '%s\n' "$mode" > "$REPORTED_MODE_FILE"
}

mode_is_hybrid() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"hybrid"* ]]
}

mode_is_dgpu() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"asusmuxdgpu"* || "$value" == *"dgpu"* || "$value" == *"dedicated"* || "$value" == *"nvidia"* ]]
}

mode_is_integrated() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"integrated"* || "$value" == "intel" ]]
}

find_nvidia_gpu_bdf() {
  local dev vendor class
  for dev in /sys/bus/pci/devices/*; do
    [[ -f "$dev/vendor" && -f "$dev/class" ]] || continue
    vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
    class="$(cat "$dev/class" 2>/dev/null || true)"
    if [[ "$vendor" == "0x10de" && "$class" == 0x03* ]]; then
      basename "$dev"
      return 0
    fi
  done
  return 1
}

dgpu_pci_present() {
  [[ -n "$(find_nvidia_gpu_bdf || true)" ]]
}

nvidia_userspace_ready() {
  has_cmd nvidia-smi && nvidia-smi -L >/dev/null 2>&1
}

effective_gpu_class() {
  if ! dgpu_pci_present; then
    echo "integrated"
    return
  fi

  if ! nvidia_userspace_ready; then
    echo "dgpu-pci-no-driver"
    return
  fi

  echo "dgpu"
}

print_dgpu_repair_hint() {
  cat <<'EOF'
hint: dGPU device is missing from PCI tree while non-integrated mode is expected.
hint: try in terminal:
  sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
  nvidia-smi -L
EOF
}

expected_gpu_class_from_policy() {
  local ppd="$1"
  local source="$2"

  if [[ "$ppd" == "performance" ]]; then
    echo "hybrid"
  elif [[ "$source" == "dc" && "$ppd" == "power-saver" ]]; then
    echo "integrated"
  else
    echo "hybrid"
  fi
}

is_gpu_consistent_with_expected() {
  local expected="$1"
  local effective
  effective="$(effective_gpu_class)"

  case "$expected" in
    integrated)
      [[ "$effective" == "integrated" ]]
      ;;
    hybrid)
      [[ "$effective" == "dgpu" ]]
      ;;
    dgpu)
      [[ "$effective" == "dgpu" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

supported_gpu_modes() {
  run_supergfx -s \
    | tr -d '[]' \
    | tr ',' '\n' \
    | sed 's/^\s*//;s/\s*$//' \
    | sed '/^$/d'
}

select_mode_from_supported() {
  local desired_class="$1"
  local supported raw candidate normalized
  supported="$(supported_gpu_modes || true)"
  [[ -n "$supported" ]] || return 1

  if [[ "$desired_class" == "integrated" ]]; then
    for candidate in Integrated integrated Intel; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  elif [[ "$desired_class" == "hybrid" ]]; then
    for candidate in Hybrid hybrid AsusEgpu AsusMuxHybrid; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  else
    for candidate in AsusMuxDgpu Nvidia Dedicated; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  fi

  return 1
}

set_gpu_mode() {
  local desired_class="$1"
  local logout_on_pending="$2"

  if ! has_cmd supergfxctl; then
    warn "supergfxctl not found; skipping GPU mode"
    return
  fi

  if ! supergfx_active; then
    warn "supergfxd inactive; skipping GPU mode"
    return
  fi

  local target current
  target="$(select_mode_from_supported "$desired_class" || true)"
  if [[ -z "$target" ]]; then
    warn "No supported GPU mode found for class: $desired_class"
    return
  fi

  local current_pending_action current_pending_mode
  current_pending_action="$(get_pending_action)"
  current_pending_mode="$(get_pending_mode)"
  if [[ "$current_pending_action" != "none" ]]; then
    if [[ "$(normalize "$current_pending_mode")" == "$(normalize "$target")" ]]; then
      warn "GPU mode '$target' is already pending and requires session action: $current_pending_action"
      if [[ "$logout_on_pending" != "yes" ]]; then
        notify_pending_logout "$target" "$current_pending_action"
      fi
      return
    fi
  fi

  current="$(supergfx_reported_mode)"
  if [[ "$(normalize "$current")" == "$(normalize "$target")" ]]; then
    if is_gpu_consistent_with_expected "$desired_class"; then
      return
    fi
    warn "GPU reported mode already '$target' but effective state is inconsistent; re-requesting"
  fi

  if run_supergfx -m "$target" >/dev/null 2>&1; then
    log "Requested GPU mode: $target"
    cache_reported_mode "$target"
  else
    warn "Failed to request GPU mode: $target"
    return
  fi

  local pending_action
  pending_action="$(get_pending_action)"
  if [[ "$pending_action" != "none" ]]; then
    warn "GPU mode switch pending action: $pending_action"
    if [[ "$logout_on_pending" == "yes" ]]; then
      if has_cmd gnome-session-quit; then
        log "Logging out to complete GPU mode switch"
        gnome-session-quit --logout --no-prompt || true
      else
        warn "gnome-session-quit not found; please log out manually"
      fi
    else
      notify_pending_logout "$target" "$pending_action"
    fi
  fi

  if ! is_gpu_consistent_with_expected "$desired_class"; then
    warn "GPU state not yet consistent with expected class '$desired_class' (reported=$(supergfx_reported_mode), effective=$(effective_gpu_class))"
    if [[ "$desired_class" != "integrated" && "$(effective_gpu_class)" == "integrated" && ! dgpu_pci_present ]]; then
      print_dgpu_repair_hint | while IFS= read -r line; do warn "$line"; done
    fi
  fi
}

get_ppd() {
  if ! has_cmd powerprofilesctl; then
    echo "unknown"
    return
  fi

  local current
  current="$(powerprofilesctl get 2>/dev/null || true)"
  case "$current" in
    power-saver|balanced|performance) echo "$current" ;;
    *) echo "unknown" ;;
  esac
}

apply_profile_mapping() {
  local logout_on_pending="$1"
  local source ppd
  source="$(get_power_source)"
  ppd="$(get_ppd)"

  if [[ "$ppd" == "unknown" ]]; then
    warn "Could not read power profile; skipping apply"
    return
  fi

  if [[ "$ppd" == "performance" ]]; then
    set_asus_profile "Performance"
    set_gpu_mode "hybrid" "$logout_on_pending"
    log "Applied mapping: ppd=performance source=$source"
    return
  fi

  if [[ "$source" == "dc" && "$ppd" == "power-saver" ]]; then
    set_asus_profile "Quiet"
    set_gpu_mode "integrated" "$logout_on_pending"
    log "Applied mapping: ppd=power-saver source=dc"
    return
  fi

  set_asus_profile "Balanced"
  set_gpu_mode "hybrid" "$logout_on_pending"
  log "Applied mapping: ppd=$ppd source=$source (balanced policy)"
}

status() {
  local source profile ppd gfx effective expected consistent nvidia_bdf pending_action pending_mode requires_logout
  source="$(get_power_source)"
  profile="$(asusctl profile get 2>/dev/null | awk -F': ' '/Active profile/{print $2; exit}' || true)"
  ppd="$(get_ppd)"
  gfx="$(supergfx_reported_mode)"
  expected="$(expected_gpu_class_from_policy "$ppd" "$source")"
  effective="$(effective_gpu_class)"
  nvidia_bdf="$(find_nvidia_gpu_bdf || true)"
  pending_action="$(get_pending_action)"
  pending_mode="$(get_pending_mode)"
  if [[ "$pending_action" == "none" ]]; then
    requires_logout="no"
  else
    requires_logout="yes"
  fi
  if is_gpu_consistent_with_expected "$expected"; then
    consistent="yes"
  else
    consistent="no"
  fi

  cat <<EOF
power_source=$source
asus_profile=${profile:-unknown}
ppd=${ppd:-unknown}
gpu_mode_reported=$gfx
gpu_mode_effective=$effective
gpu_mode_expected=$expected
gpu_mode_consistent=$consistent
nvidia_gpu_bdf=${nvidia_bdf:-none}
pending_action=$pending_action
pending_mode=$pending_mode
requires_logout=$requires_logout
EOF
}

watch_loop() {
  local last_source=""
  local last_ppd=""
  while true; do
    local now_source now_ppd
    now_source="$(get_power_source)"
    now_ppd="$(get_ppd)"
    if [[ "$now_source" != "$last_source" || "$now_ppd" != "$last_ppd" ]]; then
      log "Change detected: source ${last_source:-unknown} -> $now_source, ppd ${last_ppd:-unknown} -> $now_ppd"
      apply_profile_mapping "no"
      last_source="$now_source"
      last_ppd="$now_ppd"
    fi
    sleep 5
  done
}

usage() {
  cat <<'EOF'
Usage:
  g14-power-mode.sh apply [--logout-on-pending yes|no]
  g14-power-mode.sh status
  g14-power-mode.sh check
  g14-power-mode.sh watch

Notes:
  - Ubuntu top-right menu (powerprofilesctl) is the mode selector.
  - AC/DC auto-apply is handled by the user systemd service running watch.
  - status/check rely on effective hardware state and cached requested mode.
EOF
}

cmd="${1:-}"
shift || true

logout_on_pending="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logout-on-pending)
      logout_on_pending="${2:-no}"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$cmd" in
  apply)
    apply_profile_mapping "$logout_on_pending"
    ;;
  status)
    status
    ;;
  check)
    source="$(get_power_source)"
    ppd="$(get_ppd)"
    expected="$(expected_gpu_class_from_policy "$ppd" "$source")"
    if is_gpu_consistent_with_expected "$expected"; then
      echo "ok: gpu state consistent (expected=$expected reported=$(supergfx_reported_mode) effective=$(effective_gpu_class))"
    else
      echo "mismatch: expected=$expected reported=$(supergfx_reported_mode) effective=$(effective_gpu_class)"
      if [[ "$expected" != "integrated" && "$(effective_gpu_class)" == "integrated" && ! dgpu_pci_present ]]; then
        print_dgpu_repair_hint
      fi
      exit 2
    fi
    ;;
  watch)
    watch_loop
    ;;
  *)
    usage
    exit 1
    ;;
esac
