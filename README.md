# System Fixes — ASUS ROG Zephyrus G14 2025

**Tested on:** Ubuntu 24.04 (noble), kernel 6.17.x
**Hardware:** ASUS ROG Zephyrus G14 2025 (GA403WR)
- **GPU:** AMD iGPU + NVIDIA GeForce RTX 5070 Ti Laptop (hybrid/Optimus)
- **Audio:** Realtek ALC285 HDA codec + 2× Cirrus Logic CS35L56 Rev B0 amplifiers (subsystem ID `10431024`)
- **WiFi:** MediaTek MT7925 (PCIe), driver `mt7925e`
- **Desktop:** GNOME on Wayland

---

## 1. NVIDIA Freeze Fix

### Problem
The Ubuntu session froze during suspend/resume:
- NVIDIA 590.48.01 **open kernel module** failed suspend/resume
- `pm_runtime_work` hogged CPU
- NVIDIA HDA controller kept re-enabling in a loop
- GNOME Shell compositor couldn't allocate/render windows

### Root Cause
The `nvidia-driver-590-open` (open-source kernel module) has bugs in power state transitions on this hardware.

### Fix
Switched from `nvidia-driver-590-open` to `nvidia-driver-590` (proprietary closed kernel module):
```bash
sudo apt install nvidia-driver-590
# (replaces nvidia-driver-590-open)
# Reboot required
```

### Files Changed
- None (package swap via apt)

---

## 2. rog-control-center Crash Fix

### Problem
`rog-control-center` (asusctl 6.1.12) crashed immediately with `SIGABRT`:
```
neither WAYLAND_DISPLAY nor WAYLAND_SOCKET is set;
note: enable the `winit/x11` feature to support X11.
No backends configured.
```

### Root Cause
The binary was compiled with Wayland-only windowing support (`slint/backend-winit-wayland`), but the session was running on X11.

### Fix
Switched to Wayland session (which happened naturally after the NVIDIA driver reboot). The GDM udev rule at `/usr/lib/udev/rules.d/61-gdm.rules` had been forcing X11 for NVIDIA 590+, but GDM correctly selected Wayland after the proprietary driver was installed.

### Files Changed
- None (session type change)

### Note
The installed version (6.1.12) is from a local `.deb` with no PPA. Latest upstream is 6.3.2 on GitLab.

---

## 3. Cleanup

### Actions
- Removed crash report: `/var/crash/_usr_bin_rog-control-center.1000.crash`
- Removed temporary log collection script: `/tmp/collect_freeze_logs.sh`

---

## 4. WiFi Stability Fixes (MediaTek MT7925)

### Problem
WiFi silently stopped passing traffic while appearing connected. Required manual WiFi off/on toggle to restore connectivity. Pattern:
- Ping works normally while traffic is flowing
- After a few seconds of idle, WiFi goes silent
- 100% packet loss until manual toggle
- No kernel errors logged — connection appears "up" to NetworkManager

### Root Cause
Three layers of power management were fighting each other on this new MT7925 chip:

1. **WiFi 802.11 Power Save** — radio enters doze mode between beacons
2. **PCIe ASPM (Active State Power Management)** — PCIe link enters low-power L1 state
3. **mt76 driver internal runtime PM** — firmware put into deep sleep after 83ms idle

The mt76 internal runtime PM was the primary culprit. It was entering doze ~50% of the time (`1781s doze / 1854s awake`) with wake failures causing silent data stalls.

### Fix 1: Disable WiFi Power Save
**File:** `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`
```ini
[connection]
wifi.powersave = 2
```
- Value `2` = disabled (vs `0` = default/on, `3` = enabled)
- Applied by: `sudo systemctl restart NetworkManager`
- Verify: `iw dev wlp99s0 get power_save` → `Power save: off`

### Fix 2: Disable PCIe ASPM for mt7925e
**File:** `/etc/modprobe.d/mt7925-fix.conf`
```
options mt7925e disable_aspm=Y
```
- Takes effect on module load (reboot or `modprobe -r mt7925e && modprobe mt7925e`)
- Verify: `cat /sys/module/mt7925e/parameters/disable_aspm` → `Y`

### Fix 3: Disable mt76 Internal Runtime PM (DKMS patched driver)

The upstream mt76 driver hardcodes `pm.enable_user = true` and `pm.ds_enable_user = true` at init time, and the **only** interface to change these is via debugfs. With Secure Boot enabled (kernel lockdown = `integrity`), debugfs writes are blocked — so the original systemd service approach cannot work.

**Solution:** Build a patched mt76 driver stack via DKMS, signed with the existing MOK key (same one NVIDIA uses). The patch changes the defaults to `false` in `mt7925/init.c`, eliminating the need for debugfs writes entirely.

```bash
sudo bash configs/mt76-pm-fix/setup.sh
# Reboot required
```

The script:
1. Downloads mt76 source from kernel v6.17 (matching the running kernel)
2. Patches `mt7925_register_device()` to default `pm.enable_user = false` and `pm.ds_enable_user = false`
3. Builds all 5 mt76 modules (mt76, mt76-connac-lib, mt792x-lib, mt7925-common, mt7925e)
4. Signs them with the existing MOK key (DKMS auto-signs on Ubuntu)
5. Installs via DKMS to `/lib/modules/.../updates/dkms/` (takes priority over stock modules)
6. Disables the old systemd workaround services

**DKMS auto-rebuilds** on kernel updates, so the fix persists across upgrades.

- Verify: `sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/runtime-pm` → `0`
- Verify: `sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/deep-sleep` → `0`
- Verify: `modinfo mt7925-common | grep signer` → should show your MOK key name
- Remove: `sudo dkms remove mt76-pm-fix/1.0 --all`

> **Note:** The PHY number (phy0, phy1) varies between boots. Always use the wildcard `phy*` in paths.

### Files Changed
- **Created:** `configs/NetworkManager/wifi-powersave-off.conf` → install to `/etc/NetworkManager/conf.d/`
- **Created:** `configs/modprobe/mt7925-fix.conf` → install to `/etc/modprobe.d/`
- **Created:** `configs/mt76-pm-fix/setup.sh` → run with `sudo bash` to build and install patched DKMS modules
- **Removed:** `/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf` (had `wifi.powersave = 3`, conflicted with `wifi-powersave-off.conf`)

### Note
If a `default-wifi-powersave-on.conf` file exists in `/etc/NetworkManager/conf.d/`, remove it — it overrides the power-save-off config since NetworkManager merges all `.conf` files alphabetically and `default-*` sorts before `wifi-*`.

### Secure Boot Compatibility
Fix 3 requires building out-of-tree kernel modules. With Secure Boot enabled, these must be signed with a Machine Owner Key (MOK). The setup script uses the existing MOK key at `/var/lib/shim-signed/mok/` (created during NVIDIA DKMS setup). **No Secure Boot changes are needed** — BitLocker and Windows Hello remain fully functional.

### Kernel Updates & Removal
DKMS automatically rebuilds and signs the patched modules whenever a new kernel is installed. No manual intervention is needed.

If a future kernel ships with a fixed mt76 driver (e.g., runtime PM disabled by default or a proper module parameter), the DKMS module will still override it. To test whether the stock driver has been fixed:

```bash
# Temporarily remove the DKMS override for the current kernel
sudo dkms uninstall mt76-pm-fix/1.0 -k $(uname -r)
sudo reboot

# After reboot, check if stock driver still has the issue
sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/runtime-pm
# If 0 → upstream fixed it, remove DKMS entirely:
#   sudo dkms remove mt76-pm-fix/1.0 --all
# If 1 → still broken, re-enable:
#   sudo dkms install mt76-pm-fix/1.0 -k $(uname -r) && sudo reboot
```

To remove the fix permanently:
```bash
sudo dkms remove mt76-pm-fix/1.0 --all
```

### Fix 4: Reload mt7925e on Resume from Suspend

Even with Fixes 1–3 active, WiFi stalls recur after resume from s2idle (closing the laptop lid). The PCI subsystem restores ASPM L1 and all L1 substates (L1.1, L1.2 ASPM/PCI-PM) on resume, overriding the driver's `disable_aspm=Y` from probe time. The repeated L1 power-state cycling corrupts the MT7925 firmware's TX path — the connection appears "up" (associated, good signal, no beacon loss) but packets are silently dropped.

Disabling ASPM via sysfs after resume is insufficient because the firmware is already in a bad state. The only reliable fix is a full module reload, which resets the firmware.

```bash
sudo bash configs/mt76-pm-fix/mt7925-resume-fix.sh
```

The script installs a systemd system-sleep hook (`/usr/lib/systemd/system-sleep/mt7925-reload.sh`) that:
1. Detects resume from suspend
2. Unloads `mt7925e` (resets firmware)
3. Reloads `mt7925e` (re-probes with ASPM disabled)
4. Disables ASPM L1 substates via sysfs (belt and suspenders)

WiFi briefly disconnects (~3s) during resume; NetworkManager auto-reconnects.

- Verify: `journalctl -b 0 -t mt7925-reload`
- Verify: `sudo lspci -s 63:00.0 -vv | grep LnkCtl` → `ASPM Disabled`
- Remove: `sudo rm /usr/lib/systemd/system-sleep/mt7925-reload.sh`

### Files Changed
- **Created:** `configs/mt76-pm-fix/mt7925-resume-fix.sh` → run with `sudo bash` to install the resume hook

---

## 5. Cirrus CS35L56 Amplifier Firmware Fix

### Problem
Laptop speakers had no audio output. The Cirrus Logic CS35L56 DSP amplifiers (responsible for driving the speakers) were not loading firmware at boot:
```
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: DSP1: cirrus/cs35l56-b0-dsp1-misc-10431024-spkid1 (.bin file required but not found)
cs35l56-hda i2c-CSC3556:00-cs35l56-hda.0: Failed to load firmware: -2
```
Audio was limited to the HDA codec only — quiet, tinny, and without the amplified speakers.

### Root Cause
The Ubuntu `linux-firmware` package (20240318.git3b128b60) predates the September 2024 upstream commit ([9504a7f8](https://gitlab.com/kernel-firmware/linux-firmware/-/commit/9504a7f8)) that added firmware for ASUS subsystem ID `10431024`. The kernel driver requests firmware files matching the subsystem ID, but the files were simply not present.

In upstream linux-firmware, the `10431024` firmware files are symlinks to `10431044` (same tuning, shared between ASUS models).

### Fix
Download the `10431044` base firmware files from upstream and create symlinks for `10431024`:

```bash
sudo bash configs/cirrus/cirrus-fix.sh
# Reboot required
```

The script:
1. Downloads 4 `.bin` firmware files for subsystem `10431044` from the linux-firmware GitLab
2. Installs them to `/lib/firmware/cirrus/`
3. Creates symlinks: `10431024` → `10431044` (matching upstream)
4. Creates `.wmfw` symlinks pointing to the existing `CS35L56_Rev3.11.16.wmfw.zst`
5. Runs `update-initramfs -u` to include firmware in the initramfs

### Verification
After reboot:
```bash
sudo dmesg | grep cs35l56
# Should show: patched=1 (firmware loaded and calibration applied)
# Previously showed: patched=0 or "Failed to load firmware"
```

### Files Changed
- **Created:** `configs/cirrus/cirrus-fix.sh` → run with `sudo bash` to install firmware

---

## 6. GRUB Dual-Boot Configuration

### Problem
GRUB was configured with hidden menu and zero timeout, making it impossible to select Windows or other boot options. The machine has Windows dual-boot (Windows Boot Manager on `/dev/nvme0n1p1`).

### Fix
Modified `/etc/default/grub`:
```diff
-GRUB_TIMEOUT_STYLE=hidden
+GRUB_TIMEOUT_STYLE=menu
-GRUB_TIMEOUT=0
+GRUB_TIMEOUT=5
-#GRUB_DISABLE_OS_PROBER=false
+GRUB_DISABLE_OS_PROBER=false
```

Applied with:
```bash
sudo update-grub
```

### Files Changed
- **Created:** `configs/grub/grub` → install to `/etc/default/grub`, then run `sudo update-grub`

### Note
Only one "Windows Boot Manager" entry appears in GRUB, even if multiple Windows installs exist. The Windows bootloader on the EFI system partition handles selecting between Windows installations internally.

---

## 7. Volume Slider (Known Issue — Deferred)

### Problem
The GNOME volume slider moves but does not actually change speaker volume. Audio is always at maximum regardless of slider position.

### Root Cause
The Cirrus CS35L56 DSP takes over volume control from the ALSA mixer. The `Master` and `Speaker` ALSA controls (which GNOME/PipeWire normally use) are effectively bypassed — only the `PCM` control actually affects volume. PipeWire maps to `Master` by default, which the DSP ignores.

### Status
**Deferred.** Multiple approaches were tested and reverted:
- **PipeWire soft-mixer:** Works but caps maximum volume well below the amplifier's capability
- **PCM control remap:** `api.alsa.mixer.pcm-control=PCM` had no effect in WirePlumber
- **PulseAudio path override:** Editing `analog-output-speaker.conf` to use `PCM` instead of `Master` worked but had a non-linear volume curve
- **`api.alsa.ignore-dB`:** Broke audio entirely

This is a known issue with Cirrus DSP amplifiers on Linux. Upstream kernel/PipeWire work is ongoing. The speakers work at full volume; the slider just doesn't attenuate.

### Workaround
Use `alsamixer` or `amixer` to manually control the `PCM` level:
```bash
# Set PCM volume (0-255)
amixer -c 0 sset PCM 200
```

---

## Installation

To re-apply all fixes on a fresh install:

```bash
# --- Audio: Cirrus CS35L56 amplifier firmware ---
sudo bash configs/cirrus/cirrus-fix.sh

# --- WiFi: power save off ---
sudo cp configs/NetworkManager/wifi-powersave-off.conf /etc/NetworkManager/conf.d/
sudo rm -f /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
sudo systemctl restart NetworkManager

# --- WiFi: ASPM disable for MT7925 ---
sudo cp configs/modprobe/mt7925-fix.conf /etc/modprobe.d/

# --- WiFi: mt76 internal runtime PM disable (DKMS patched driver) ---
sudo bash configs/mt76-pm-fix/setup.sh

# --- WiFi: reload mt7925e on resume from suspend ---
sudo bash configs/mt76-pm-fix/mt7925-resume-fix.sh

# --- GRUB: dual-boot with visible menu ---
sudo cp configs/grub/grub /etc/default/grub
sudo update-grub

# Reboot to apply all changes
sudo reboot
```

## Diagnostic Commands

```bash
# --- Audio ---
# Check Cirrus amplifier firmware loaded
sudo dmesg | grep cs35l56

# Check ALSA controls for speaker volume
amixer -c 0 sget Master
amixer -c 0 sget PCM

# --- WiFi ---
# Check WiFi power save (interface name may vary)
iw dev wlp99s0 get power_save

# Check ASPM status  
cat /sys/module/mt7925e/parameters/disable_aspm

# Check mt76 internal runtime PM (phy number varies between boots, use phy*)
sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/runtime-pm

# Check mt76 deep sleep
sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/deep-sleep

# Check mt76 PM stats
sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/pm_stats

# Check DKMS module is signed and loaded
modinfo mt7925-common | grep signer

# Check PCI runtime PM
cat /sys/bus/pci/devices/0000:63:00.0/power/control

# WiFi driver info
modinfo mt7925e

# Firmware version (shown at boot)
journalctl -b 0 -k | grep mt7925

# --- GRUB ---
# Check detected operating systems
grep menuentry /boot/grub/grub.cfg | head -20
```
