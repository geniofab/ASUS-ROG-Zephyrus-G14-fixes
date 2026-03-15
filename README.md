# ASUS ROG Zephyrus G14 (2025) Linux Tweaks

Practical configuration files and scripts for Ubuntu 24.04 on the ASUS ROG Zephyrus G14 2025 (GA403WR).

## What this repository includes

- [configs/grub/grub](configs/grub/grub): GRUB defaults for NVIDIA and dual-boot friendly behavior.
- [configs/cirrus/cirrus-fix.sh](configs/cirrus/cirrus-fix.sh): Creates required Cirrus CS35L56 firmware links.
- [configs/gnome/vitals-setup.sh](configs/gnome/vitals-setup.sh): Configures GNOME Vitals panel sensors.
- [configs/NetworkManager/wifi-powersave-off.conf](configs/NetworkManager/wifi-powersave-off.conf): Disables WiFi powersave in NetworkManager.
- [configs/mt76-pm-fix/revert-to-stock-oem.sh](configs/mt76-pm-fix/revert-to-stock-oem.sh): Resets MT7925 WiFi to stock OEM baseline.
- [configs/power/g14-power-mode.sh](configs/power/g14-power-mode.sh): Maps Ubuntu power profile + AC/DC to ASUS profile and GPU policy.
- [configs/power/install.sh](configs/power/install.sh): Installs user service and applies startup defaults for power mapping.
- [configs/power/systemd-user/g14-power-acdc-monitor.service](configs/power/systemd-user/g14-power-acdc-monitor.service): Re-applies mapping when AC state or Ubuntu power profile changes.
- [configs/power/systemd-user/g14-power-startup-eco.service](configs/power/systemd-user/g14-power-startup-eco.service): Forces startup default to Eco (`Power Saver`) on login.

## Target setup

- Ubuntu 24.04 (GNOME/Wayland)
- `linux-oem-24.04b`
- In-tree `mt7925e` driver
- Ubuntu `linux-firmware`

## Quick setup

### 1) Install NVIDIA open driver branch

```bash
sudo apt update
sudo apt install nvidia-driver-570-open
```

### 2) Apply Cirrus speaker firmware links

```bash
sudo bash configs/cirrus/cirrus-fix.sh
```

### 3) Apply GRUB configuration

```bash
sudo cp configs/grub/grub /etc/default/grub
sudo update-grub
```

### 4) Configure GNOME Vitals (run as desktop user)

```bash
bash configs/gnome/vitals-setup.sh
```

### 5) Install OEM kernel line and current firmware

```bash
sudo apt update
sudo apt install linux-firmware linux-oem-24.04b linux-image-oem-24.04b
```

### 6) Apply WiFi powersave policy

```bash
sudo install -D -m 644 configs/NetworkManager/wifi-powersave-off.conf \
  /etc/NetworkManager/conf.d/wifi-powersave-off.conf
sudo systemctl restart NetworkManager
```

### 7) Install power profile mapping (Ubuntu menu driven)

```bash
bash configs/power/install.sh
sudo systemctl enable --now supergfxd.service
```

This keeps Ubuntu's built-in top-right power menu as the only mode selector.

### 8) Reboot

```bash
sudo reboot
```

## Power profile mapping (Ubuntu top-right menu)

The active Ubuntu power profile (`Power Saver`, `Balanced`, `Performance`) is mapped automatically with AC/DC awareness.

| Ubuntu menu selection | Power source | ASUS profile | GPU policy | Intent |
|---|---|---|---|---|
| Power Saver | Battery (DC) | Quiet | Integrated | Ultra power saving |
| Balanced | Battery (DC) | Balanced | Hybrid | Moderate savings |
| Performance | Battery (DC) | Performance | Hybrid | Maximum performance without reboot-required MUX switching |
| Power Saver | AC | Balanced | Hybrid | Quiet daily use |
| Balanced | AC | Balanced | Hybrid | Quiet daily use |
| Performance | AC | Performance | Hybrid | Maximum performance without reboot-required MUX switching |

Notes:

- On AC, `Power Saver` and `Balanced` intentionally use the same quiet hybrid policy.
- GPU mode changes may require a session reload/log out depending on current mode.
- The background monitor will automatically trigger logout when required to complete a GPU mode transition.
- This setup intentionally avoids MUX dGPU mode for profile switching, to keep mode changes reboot-free.
- Startup default is `Power Saver`.
- Startup default is enforced on each login by `g14-power-startup-eco.service`.

## WiFi verification

Run these checks after reboot:

```bash
dkms status | grep -Ei 'mt76|mt7925' || echo "No custom MT76/MT7925 DKMS modules"
modinfo mt7925e | grep '^filename:'
apt-cache policy linux-firmware linux-oem-24.04b
IFACE=$(iw dev | awk '$1=="Interface"{print $2; exit}')
iw dev "$IFACE" get power_save

# Power mapping status
bash configs/power/g14-power-mode.sh status

# Power mapping consistency check (exit 0 on match)
bash configs/power/g14-power-mode.sh check || true

# Current Ubuntu power profile
powerprofilesctl get

# supergfxd availability (required for GPU policy switching)
systemctl is-active supergfxd
```

Expected results:

- No custom MT76/MT7925 DKMS module entries.
- `mt7925e` from `/lib/modules/<kernel>/kernel/drivers/net/wireless/mediatek/mt76/mt7925/`.
- `Power save: off`.
- `supergfxd` active if you want automatic GPU mode switching.
- `gpu_mode_consistent=yes` in `g14-power-mode.sh status` for the selected profile.

If reported and effective GPU mode differ (for example, reported dGPU while hardware is not present), `g14-power-mode.sh check` prints `mismatch: ...` and exits with code `2`.

If mismatch indicates missing dGPU PCI device while `Hybrid`/`Performance` is expected, recover without reboot:

```bash
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
nvidia-smi -L
```

## Reset to stock OEM WiFi baseline

If your system previously used custom MT76 tweaks, run:

```bash
sudo bash configs/mt76-pm-fix/revert-to-stock-oem.sh
sudo reboot
```

## Diagnostics

```bash
uname -r
nvidia-smi
lspci -nnk | grep -A4 -Ei 'Network|Mediatek|MT7925'
modinfo mt7925e | grep '^filename:'
apt-cache policy linux-firmware linux-oem-24.04b
dconf read /org/gnome/shell/extensions/vitals/hot-sensors
upower -e | grep BAT
```
