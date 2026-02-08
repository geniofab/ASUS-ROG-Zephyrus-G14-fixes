#!/bin/bash
# mt76-pm-fix: Build patched mt76 driver with runtime PM disabled
#
# Fixes WiFi packet stalls on MediaTek MT7925 by changing the default
# pm.enable_user from true to false in the driver init code.
#
# Designed for Secure Boot systems — modules are signed with the
# existing MOK key (same one used by NVIDIA DKMS). BitLocker and
# Windows Hello remain unaffected.
#
# The fix is packaged as a DKMS module so it auto-rebuilds on kernel updates.

set -euo pipefail

PACKAGE_NAME="mt76-pm-fix"
PACKAGE_VERSION="1.0"
SRC_DIR="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | grep -oP '^\d+\.\d+')

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Must run as root (sudo)"

# ── Prerequisites ─────────────────────────────────────────────────────
log "Checking prerequisites..."
command -v dkms >/dev/null       || err "dkms not installed: sudo apt install dkms"
command -v git  >/dev/null       || err "git not installed:  sudo apt install git"
dpkg -s build-essential &>/dev/null || err "build-essential not installed: sudo apt install build-essential"
[[ -d "/lib/modules/${KERNEL_VER}/build" ]] \
    || err "Kernel headers missing: sudo apt install linux-headers-${KERNEL_VER}"

# MOK signing key (Ubuntu puts it here for DKMS)
MOK_KEY="/var/lib/shim-signed/mok/MOK.priv"
MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
SIGN_FILE="/usr/src/linux-headers-${KERNEL_VER}/scripts/sign-file"
[[ -f "$MOK_KEY"   ]] || err "MOK private key not found at $MOK_KEY"
[[ -f "$MOK_CERT"  ]] || err "MOK certificate not found at $MOK_CERT"
[[ -f "$SIGN_FILE" ]] || err "sign-file not found at $SIGN_FILE"
log "MOK key:  $(openssl x509 -inform DER -in "$MOK_CERT" -noout -subject 2>/dev/null)"

# ── Clean previous install ────────────────────────────────────────────
if dkms status "${PACKAGE_NAME}/${PACKAGE_VERSION}" 2>/dev/null | grep -q .; then
    warn "Removing previous DKMS installation..."
    dkms remove "${PACKAGE_NAME}/${PACKAGE_VERSION}" --all 2>/dev/null || true
fi
rm -rf "$SRC_DIR"

# ── Download mt76 source ─────────────────────────────────────────────
log "Downloading mt76 source for kernel v${KERNEL_MAJOR}..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git clone --depth 1 --filter=blob:none --sparse \
    --branch "v${KERNEL_MAJOR}" \
    https://github.com/torvalds/linux.git linux-src 2>&1 | tail -3
cd linux-src
git sparse-checkout set drivers/net/wireless/mediatek/mt76 2>&1 | tail -3

MT76="$TMPDIR/linux-src/drivers/net/wireless/mediatek/mt76"
[[ -f "$MT76/mt76.h" ]] || err "Failed to download mt76 source"
log "Source downloaded (v${KERNEL_MAJOR})"

# ── Create DKMS source tree ──────────────────────────────────────────
log "Creating DKMS source tree at ${SRC_DIR}..."
mkdir -p "$SRC_DIR/mt7925"

# --- Headers (all .h from root) ---
cp "$MT76"/*.h "$SRC_DIR/"

# --- mt76.ko source ---
for f in mmio.c util.c trace.c dma.c mac80211.c debugfs.c eeprom.c \
         tx.c agg-rx.c mcu.c wed.c scan.c channel.c pci.c testmode.c; do
    [[ -f "$MT76/$f" ]] && cp "$MT76/$f" "$SRC_DIR/"
done

# --- mt76-connac-lib.ko source ---
for f in mt76_connac_mcu.c mt76_connac_mac.c mt76_connac3_mac.c; do
    cp "$MT76/$f" "$SRC_DIR/"
done

# --- mt792x-lib.ko source ---
for f in mt792x_core.c mt792x_mac.c mt792x_trace.c mt792x_debugfs.c \
         mt792x_dma.c mt792x_acpi_sar.c; do
    [[ -f "$MT76/$f" ]] && cp "$MT76/$f" "$SRC_DIR/"
done

# --- mt7925/ source (mt7925-common.ko + mt7925e.ko) ---
cp "$MT76/mt7925"/*.c "$MT76/mt7925"/*.h "$SRC_DIR/mt7925/"

# ── Apply patch ───────────────────────────────────────────────────────
log "Patching mt7925/init.c: disable runtime PM + deep sleep by default..."
INIT="$SRC_DIR/mt7925/init.c"

sed -i 's/dev->pm\.enable_user = true;/dev->pm.enable_user = false;/' "$INIT"
sed -i 's/dev->pm\.enable = true;/dev->pm.enable = false;/'           "$INIT"
sed -i 's/dev->pm\.ds_enable_user = true;/dev->pm.ds_enable_user = false;/' "$INIT"
sed -i 's/dev->pm\.ds_enable = true;/dev->pm.ds_enable = false;/'     "$INIT"

grep -q "enable_user = true" "$INIT" && err "Patch failed: enable_user still true"
grep -q "ds_enable = true"   "$INIT" && err "Patch failed: ds_enable still true"
log "Patch applied successfully"

# ── Top-level Makefile ────────────────────────────────────────────────
cat > "$SRC_DIR/Makefile" << 'MAKEFILE_EOF'
ifneq ($(KERNELRELEASE),)
# ── Kbuild section (called by kernel build system) ──

obj-m += mt76.o
obj-m += mt76-connac-lib.o
obj-m += mt792x-lib.o
obj-m += mt7925/

mt76-y := \
	mmio.o util.o trace.o dma.o mac80211.o debugfs.o eeprom.o \
	tx.o agg-rx.o mcu.o wed.o scan.o channel.o

mt76-$(CONFIG_PCI) += pci.o
mt76-$(CONFIG_NL80211_TESTMODE) += testmode.o

CFLAGS_trace.o := -I$(src)
CFLAGS_mt792x_trace.o := -I$(src)

mt76-connac-lib-y := mt76_connac_mcu.o mt76_connac_mac.o mt76_connac3_mac.o

mt792x-lib-y := mt792x_core.o mt792x_mac.o mt792x_trace.o \
	mt792x_debugfs.o mt792x_dma.o
mt792x-lib-$(CONFIG_ACPI) += mt792x_acpi_sar.o

else
# ── Direct invocation ──

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

endif
MAKEFILE_EOF

# ── mt7925 sub-Makefile ───────────────────────────────────────────────
cat > "$SRC_DIR/mt7925/Makefile" << 'MAKEFILE_EOF'
obj-m += mt7925-common.o
obj-m += mt7925e.o

mt7925-common-y := mac.o mcu.o main.o init.o debugfs.o
mt7925-common-$(CONFIG_NL80211_TESTMODE) += testmode.o

mt7925e-y := pci.o pci_mac.o pci_mcu.o
MAKEFILE_EOF

# ── dkms.conf ─────────────────────────────────────────────────────────
cat > "$SRC_DIR/dkms.conf" << DKMS_EOF
PACKAGE_NAME="${PACKAGE_NAME}"
PACKAGE_VERSION="${PACKAGE_VERSION}"
AUTOINSTALL="yes"

MAKE="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"

BUILT_MODULE_NAME[0]="mt76"
BUILT_MODULE_LOCATION[0]=""
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="mt76-connac-lib"
BUILT_MODULE_LOCATION[1]=""
DEST_MODULE_LOCATION[1]="/updates/dkms"

BUILT_MODULE_NAME[2]="mt792x-lib"
BUILT_MODULE_LOCATION[2]=""
DEST_MODULE_LOCATION[2]="/updates/dkms"

BUILT_MODULE_NAME[3]="mt7925-common"
BUILT_MODULE_LOCATION[3]="mt7925"
DEST_MODULE_LOCATION[3]="/updates/dkms"

BUILT_MODULE_NAME[4]="mt7925e"
BUILT_MODULE_LOCATION[4]="mt7925"
DEST_MODULE_LOCATION[4]="/updates/dkms"
DKMS_EOF

# ── DKMS: add + build ────────────────────────────────────────────────
log "Registering with DKMS..."
dkms add "${PACKAGE_NAME}/${PACKAGE_VERSION}"

log "Building modules for kernel ${KERNEL_VER} (this may take a minute)..."
if ! dkms build "${PACKAGE_NAME}/${PACKAGE_VERSION}" -k "$KERNEL_VER" 2>&1; then
    err "DKMS build failed. Check: dkms status; cat /var/lib/dkms/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/make.log"
fi

# Note: DKMS on Ubuntu automatically signs modules with the MOK key
# found at /var/lib/shim-signed/mok/ during the build step above.

# ── DKMS: install ────────────────────────────────────────────────────
log "Installing modules..."
if ! dkms install "${PACKAGE_NAME}/${PACKAGE_VERSION}" -k "$KERNEL_VER" 2>&1; then
    err "DKMS install failed. Check: dkms status"
fi

# ── Verify ────────────────────────────────────────────────────────────
log "Verifying installation..."
INSTALLED_DIR="/lib/modules/${KERNEL_VER}/updates/dkms"
FOUND=0
for mod in mt76.ko mt76-connac-lib.ko mt792x-lib.ko mt7925-common.ko mt7925e.ko; do
    for ext in "" ".zst" ".xz" ".gz"; do
        if [[ -f "$INSTALLED_DIR/${mod}${ext}" ]]; then
            FOUND=$((FOUND + 1))
            break
        fi
    done
done

if [[ $FOUND -lt 5 ]]; then
    warn "Only ${FOUND}/5 modules found in ${INSTALLED_DIR}"
    ls -la "$INSTALLED_DIR"/ 2>/dev/null
else
    log "All 5 modules installed in ${INSTALLED_DIR}"
fi

# Check signing on mt7925-common
MOD_FILE=$(find "$INSTALLED_DIR" -name "mt7925-common.ko*" | head -1)
if [[ -n "$MOD_FILE" ]]; then
    SIGNER=$(modinfo "$MOD_FILE" 2>/dev/null | grep "^signer:" | awk -F: '{print $2}' | xargs)
    if [[ -n "$SIGNER" ]]; then
        log "Module signer: $SIGNER"
    else
        warn "Module may not be signed — check modinfo output"
    fi
fi

# ── Disable old workaround services ──────────────────────────────────
for svc in mt76-disable-rpm.service mt76-pci-power-fix.service; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        warn "Disabling old workaround: ${svc}"
        systemctl disable "$svc" 2>/dev/null || true
        systemctl stop "$svc" 2>/dev/null || true
    fi
done

# ── Done ──────────────────────────────────────────────────────────────
echo ""
log "================================================"
log " mt76-pm-fix installed successfully"
log "================================================"
echo ""
echo "  The patched mt76 driver disables internal runtime PM and"
echo "  deep sleep by default — no debugfs write needed."
echo ""
echo "  REBOOT REQUIRED for the new modules to load."
echo ""
echo "  After reboot, verify:"
echo "    modinfo mt7925-common | grep signer"
echo "    sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/runtime-pm   # → 0"
echo "    sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/deep-sleep   # → 0"
echo "    sudo cat /sys/kernel/debug/ieee80211/phy*/mt76/pm_stats"
echo ""
echo "  DKMS will auto-rebuild on kernel updates."
echo "  To remove:  sudo dkms remove ${PACKAGE_NAME}/${PACKAGE_VERSION} --all"
echo ""
