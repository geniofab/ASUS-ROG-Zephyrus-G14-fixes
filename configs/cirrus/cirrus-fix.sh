#!/bin/bash
# Fix Cirrus CS35L56 amplifier firmware for ASUS ROG Zephyrus G14 2025 (GA403WR)
# Subsystem ID: 10431024
# The 10431024 firmware is symlinked to 10431044 in upstream linux-firmware.

set -e

cd /tmp

# Download the base 10431044 firmware files (10431024 uses the same tuning)
echo "Downloading CS35L56 firmware files for 10431044 (base for 10431024)..."
wget -q https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/cirrus/cs35l56-b0-dsp1-misc-10431044-spkid0-amp1.bin
wget -q https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/cirrus/cs35l56-b0-dsp1-misc-10431044-spkid0-amp2.bin
wget -q https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/cirrus/cs35l56-b0-dsp1-misc-10431044-spkid1-amp1.bin
wget -q https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/cirrus/cs35l56-b0-dsp1-misc-10431044-spkid1-amp2.bin

# Install base firmware files
echo "Installing firmware files..."
chmod 644 cs35l56-b0-dsp1-misc-10431044-spkid*
sudo chown root:root cs35l56-b0-dsp1-misc-10431044-spkid*
sudo mv cs35l56-b0-dsp1-misc-10431044-spkid* /lib/firmware/cirrus/

cd /lib/firmware/cirrus

# Create symlinks for 10431024 -> 10431044 (matching upstream linux-firmware)
echo "Creating symlinks for subsystem ID 10431024..."
sudo ln -sf cs35l56-b0-dsp1-misc-10431044-spkid0-amp1.bin cs35l56-b0-dsp1-misc-10431024-spkid0-amp1.bin
sudo ln -sf cs35l56-b0-dsp1-misc-10431044-spkid0-amp2.bin cs35l56-b0-dsp1-misc-10431024-spkid0-amp2.bin
sudo ln -sf cs35l56-b0-dsp1-misc-10431044-spkid1-amp1.bin cs35l56-b0-dsp1-misc-10431024-spkid1-amp1.bin
sudo ln -sf cs35l56-b0-dsp1-misc-10431044-spkid1-amp2.bin cs35l56-b0-dsp1-misc-10431024-spkid1-amp2.bin

# Create wmfw symlinks
sudo ln -sf cs35l56/CS35L56_Rev3.11.16.wmfw.zst cs35l56-b0-dsp1-misc-10431044-spkid0.wmfw.zst
sudo ln -sf cs35l56/CS35L56_Rev3.11.16.wmfw.zst cs35l56-b0-dsp1-misc-10431044-spkid1.wmfw.zst
sudo ln -sf cs35l56/CS35L56_Rev3.11.16.wmfw.zst cs35l56-b0-dsp1-misc-10431024-spkid0.wmfw.zst
sudo ln -sf cs35l56/CS35L56_Rev3.11.16.wmfw.zst cs35l56-b0-dsp1-misc-10431024-spkid1.wmfw.zst

# Rebuild initramfs
echo "Updating initramfs..."
sudo update-initramfs -u

echo ""
echo "Done! Reboot to apply the Cirrus amplifier firmware fix."
echo "After reboot, verify with: sudo dmesg | grep cs35l56"
echo "You should see 'patched=1' instead of 'patched=0'."
