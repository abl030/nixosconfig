#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
TARGET_DISK="/dev/sda"
BOOT_PART_LABEL="BOOT"
ROOT_PART_LABEL="nixos"

# --- Safety Check ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "WARNING: This script will partition, format, and mount:"
echo "  Disk: ${TARGET_DISK}"
echo "  Partitions:"
echo "    1: EFI System Partition (FAT32), Label: ${BOOT_PART_LABEL}"
echo "    2: Linux Root (ext4), Label: ${ROOT_PART_LABEL}"
echo ""
echo "ALL EXISTING DATA ON ${TARGET_DISK} WILL BE DESTROYED."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Are you absolutely sure you want to continue? (yes/NO): " confirmation
if [[ ! "$confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted by user."
    exit 1
fi

# --- Unmount existing partitions (just in case) ---
echo "+++ Unmounting existing partitions on ${TARGET_DISK} (if any)..."
# Ignore errors if they are not mounted
umount "${TARGET_DISK}1" 2>/dev/null || true
umount "${TARGET_DISK}2" 2>/dev/null || true
umount /mnt/boot 2>/dev/null || true
umount /mnt 2>/dev/null || true

# --- Partitioning ---
echo "+++ Partitioning ${TARGET_DISK}..."
parted "${TARGET_DISK}" --script -- \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart primary ext4 513MiB 100%

# Short pause to ensure the kernel recognizes the new partitions
sync
sleep 2

# --- Formatting ---
# Define partition device names
BOOT_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"

echo "+++ Formatting partitions..."
mkfs.fat -F 32 -n "${BOOT_PART_LABEL}" "${BOOT_PART}"
mkfs.ext4 -L "${ROOT_PART_LABEL}" "${ROOT_PART}"

# --- Force re-read of partition tables and wait for udev ---
echo "+++ Waiting for udev to recognize labels..."
sync # Ensure changes are written to disk
# Trigger udev rules to process the new labels
udevadm trigger --type=devices --action=change # Or use --action=add
# Wait for udev processing queue to finish
udevadm settle

# --- Mounting ---
echo "+++ Mounting partitions using labels..."
# Verify labels exist before mounting (optional but good practice)
if [[ ! -e "/dev/disk/by-label/${ROOT_PART_LABEL}" || ! -e "/dev/disk/by-label/${BOOT_PART_LABEL}" ]]; then
    echo "ERROR: Labels ${ROOT_PART_LABEL} or ${BOOT_PART_LABEL} not found in /dev/disk/by-label/ even after udevadm settle. Check dmesg."
    ls -l /dev/disk/by-label/
    exit 1
fi

mount "/dev/disk/by-label/${ROOT_PART_LABEL}" /mnt
mkdir -p /mnt/boot
mount "/dev/disk/by-label/${BOOT_PART_LABEL}" /mnt/boot

echo "+++ Disk preparation complete! +++"
echo "Partitions mounted successfully:"
lsblk "${TARGET_DISK}" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
echo ""
echo "You can now proceed with:"
echo "  nixos-generate-config --root /mnt"
echo "  # (Edit /mnt/etc/nixos/configuration.nix if needed)"
echo "  nixos-install --flake /mnt/etc/nixos#yourFlakeOutputName" # Adjust flake path/name as needed
nixos-generate-config --root /mnt
exit 0
