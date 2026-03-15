# ASUS ROG Zephyrus G14 (2025) Linux Tweaks

Practical configuration files and scripts for Ubuntu 24.04 on the ASUS ROG Zephyrus G14 2025 (GA403WR).

## What this repository includes

- [configs/grub/grub](configs/grub/grub): GRUB defaults for NVIDIA and dual-boot friendly behavior.
- [configs/cirrus/cirrus-fix.sh](configs/cirrus/cirrus-fix.sh): Creates required Cirrus CS35L56 firmware links.
- [configs/gnome/vitals-setup.sh](configs/gnome/vitals-setup.sh): Configures GNOME Vitals panel sensors.
- [configs/NetworkManager/wifi-powersave-off.conf](configs/NetworkManager/wifi-powersave-off.conf): Disables WiFi powersave in NetworkManager.
- [configs/mt76-pm-fix/revert-to-stock-oem.sh](configs/mt76-pm-fix/revert-to-stock-oem.sh): Resets MT7925 WiFi to stock OEM baseline.

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

### 7) Reboot

```bash
sudo reboot
```

## WiFi verification

Run these checks after reboot:

```bash
dkms status | grep -Ei 'mt76|mt7925' || echo "No custom MT76/MT7925 DKMS modules"
modinfo mt7925e | grep '^filename:'
apt-cache policy linux-firmware linux-oem-24.04b
IFACE=$(iw dev | awk '$1=="Interface"{print $2; exit}')
iw dev "$IFACE" get power_save
```

Expected results:

- No custom MT76/MT7925 DKMS module entries.
- `mt7925e` from `/lib/modules/<kernel>/kernel/drivers/net/wireless/mediatek/mt76/mt7925/`.
- `Power save: off`.

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
