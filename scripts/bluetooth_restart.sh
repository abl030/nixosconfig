#!/usr/bin/bash

# Cache sudo credentials upfront
sudo -v || {
    echo "Script requires sudo privileges"
    exit 1
}

# Clear dmesg and get device name
sudo dmesg -c >/dev/null && clear
DEVICE=$(rfkill list all | grep -o 'hci*.' | head -n 1)

echo "Performing aggressive Bluetooth restart..."

# Chain all restart commands
sudo systemctl stop bluetooth.service &&
sudo hciconfig ${DEVICE} down &&
sudo rmmod btusb &&
sudo modprobe btusb &&
sudo hciconfig ${DEVICE} up &&
sudo systemctl start bluetooth.service &&
sudo rfkill unblock bluetooth

# Show current status
echo -e "\n=== System Status ==="
echo "rfkill status:"
sudo rfkill list all

echo -e "\nBluetooth dmesg output:"
sudo dmesg | grep -i bluetooth

echo -e "\nBluetooth service status:"
systemctl is-active --quiet bluetooth.service &&
echo "Bluetooth service is running" ||
echo "Bluetooth service is not running"

# Power on bluetooth
echo -e "\nAttempting to power on Bluetooth..."
bluetoothctl power on

# Show available devices
echo -e "\nAvailable devices:"
bluetoothctl devices
