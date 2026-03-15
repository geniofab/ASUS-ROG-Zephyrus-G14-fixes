# ASUS ROG Zephyrus G14 (2025) — Current Linux Setup

Current, cleaned project state for Ubuntu 24.04 on ASUS ROG Zephyrus G14 2025 (GA403WR).

## Scope

- **OS:** Ubuntu 24.04 (noble)
- **Kernel track:** OEM (`linux-oem-24.04b`)
- **WiFi policy:** **stock in-tree MT7925 driver + stock Ubuntu firmware** (no custom DKMS patches)
- **Desktop:** GNOME (Wayland)

---

## Active Components in This Repo

- `configs/grub/grub`
  - GRUB defaults with dual-boot menu and NVIDIA kernel parameters.
- `configs/cirrus/cirrus-fix.sh`
  - Installs missing Cirrus CS35L56 firmware links for speaker amplifiers.
- `configs/gnome/vitals-setup.sh`
  - Configures GNOME Vitals panel metrics (CPU/GPU/RAM/Battery power).
- `configs/mt76-pm-fix/revert-to-stock-oem.sh`
  - One-shot rollback/migration script to stock WiFi + OEM kernel/firmware.

Removed from this repo (deprecated custom MT7925 workarounds):

- `configs/mt76-pm-fix/setup.sh`
- `configs/mt76-pm-fix/mt7925-resume-fix.sh`
- `configs/modprobe/mt7925-fix.conf`
- `configs/NetworkManager/wifi-powersave-off.conf`

---

## WiFi (Current Policy)

WiFi is intentionally aligned with stock Ubuntu packages:

- `mt7925e` from in-tree kernel module path (`/lib/modules/.../kernel/...`)
- Official Ubuntu `linux-firmware`
- No MT76 DKMS override
- No custom ASPM/reload hooks

### Verify WiFi is stock

```bash
dkms status | grep -Ei 'mt76|mt7925' || echo "No custom MT76/MT7925 DKMS modules"
modinfo mt7925e | grep '^filename:'
apt-cache policy linux-firmware linux-oem-24.04b
```

Expected:

- No `mt76-pm-fix` DKMS entries.
- `mt7925e` path under `/lib/modules/<kernel>/kernel/drivers/net/wireless/mediatek/mt76/mt7925/`.

---

## Setup / Re-apply

### 1) NVIDIA (open module branch)

```bash
sudo apt update
sudo apt install nvidia-driver-570-open
```

### 2) Cirrus speaker firmware links

```bash
sudo bash configs/cirrus/cirrus-fix.sh
```

### 3) GRUB configuration

```bash
sudo cp configs/grub/grub /etc/default/grub
sudo update-grub
```

### 4) GNOME Vitals panel setup (run as desktop user)

```bash
bash configs/gnome/vitals-setup.sh
```

### 5) Ensure OEM kernel + current firmware

```bash
sudo apt update
sudo apt install linux-firmware linux-oem-24.04b linux-image-oem-24.04b
```

### 6) Reboot

```bash
sudo reboot
```

---

## Optional: Force Revert to Stock OEM WiFi

Use this if the machine previously had custom MT76 PM patches and you want a clean baseline:

```bash
sudo bash configs/mt76-pm-fix/revert-to-stock-oem.sh
sudo reboot
```

---

## Diagnostics

```bash
# Kernel currently running
uname -r

# NVIDIA status
nvidia-smi

# WiFi driver + firmware policy
lspci -nnk | grep -A4 -Ei 'Network|Mediatek|MT7925'
modinfo mt7925e | grep '^filename:'
apt-cache policy linux-firmware linux-oem-24.04b

# GNOME Vitals configuration
dconf read /org/gnome/shell/extensions/vitals/hot-sensors

# Battery power telemetry source
upower -e | grep BAT
```

---

## Notes

- This README intentionally documents only the **current** maintained setup.
- Historical experiments and deprecated WiFi workaround files were removed to avoid drift and confusion.
