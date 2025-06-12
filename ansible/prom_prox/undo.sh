#!/bin/bash

# This script uninstalls a manually installed r8126 driver
# and restores the original r8169 driver that was backed up.
#
# It MUST be run with root privileges.
# 'sudo bash' and then paste the script, or save it and 'sudo ./uninstall.sh'

set -e # Exit immediately if a command exits with a non-zero status.

echo "--- Realtek r8126 Manual Driver Uninstall ---"
echo

if [[ $EUID -ne 0 ]]; then
    echo "!!! ERROR: This script must be run as root. Please use 'sudo'." 2>&1
    exit 1
fi

# --- 1. Find the kernel module directory ---
echo "--> Detecting kernel module path..."
KERNEL_VER=$(uname -r)
TARGET_PATH=$(find /lib/modules/${KERNEL_VER}/kernel/drivers/net/ethernet -name realtek -type d)
if [ -z "$TARGET_PATH" ]; then
    TARGET_PATH=$(find /lib/modules/${KERNEL_VER}/kernel/drivers/net -name realtek -type d)
fi
if [ -z "$TARGET_PATH" ]; then
    TARGET_PATH=/lib/modules/${KERNEL_VER}/kernel/drivers/net
fi

if [ ! -d "$TARGET_PATH" ]; then
    echo "!!! ERROR: Could not find kernel driver directory: $TARGET_PATH"
    exit 1
fi
echo "    Found driver path: $TARGET_PATH"
echo

# --- 2. Unload the r8126 module if it is loaded ---
echo "--> Unloading the r8126 module..."
if lsmod | grep -q "^r8126"; then
    rmmod r8126
    echo "    Module r8126 unloaded."
else
    echo "    Module r8126 is not currently loaded. Skipping."
fi
echo

# --- 3. Remove the r8126.ko file ---
echo "--> Removing the r8126.ko file..."
if [ -f "$TARGET_PATH/r8126.ko" ]; then
    rm -v "$TARGET_PATH/r8126.ko"
else
    echo "    File $TARGET_PATH/r8126.ko not found. Skipping."
fi
echo

# --- 4. Restore the original r8169 driver from backup ---
echo "--> Restoring original r8169 driver from backup..."
# The autorun.sh script might create .bak, .bak0, .bak1, etc.
# We will search for the most likely candidates and restore them.

# Handle uncompressed backup
BACKUP_FILE=$(find "$TARGET_PATH" -name "r8169.ko.bak*" | sort -V | tail -n 1)
if [ -n "$BACKUP_FILE" ]; then
    echo "    Found backup: $BACKUP_FILE"
    mv -v "$BACKUP_FILE" "$TARGET_PATH/r8169.ko"
else
    echo "    Warning: No standard backup file (r8169.ko.bak) found."
fi

# Handle zstd compressed backup (common in modern kernels)
BACKUP_FILE_ZST=$(find "$TARGET_PATH" -name "r8169.ko.zst.bak*" | sort -V | tail -n 1)
if [ -n "$BACKUP_FILE_ZST" ]; then
    echo "    Found compressed backup: $BACKUP_FILE_ZST"
    mv -v "$BACKUP_FILE_ZST" "$TARGET_PATH/r8169.ko.zst"
else
    echo "    Warning: No compressed backup file (r8169.ko.zst.bak) found."
fi
echo

# --- 5. Rebuild module dependencies and update initramfs ---
echo "--> Rebuilding module dependencies..."
depmod -a
echo "    'depmod -a' completed."
echo

echo "--> Updating initramfs (this may take a moment)..."
update-initramfs -u
echo "    'update-initramfs -u' completed."
echo

# --- 6. Load the original r8169 module ---
echo "--> Loading the original r8169 module..."
if ! lsmod | grep -q "^r8169"; then
    modprobe r8169
    echo "    Module r8169 loaded."
else
    echo "    Module r8169 is already loaded. Skipping."
fi
echo

echo "--- Uninstallation Complete ---"
echo "The system has been restored to use the default r8169 driver."
echo "A reboot is recommended to ensure a clean state."

exit 0
