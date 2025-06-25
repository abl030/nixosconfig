#!/usr/bin/bash

# Define the MAC addresses for the buds
MAIN_BUDS="24:24:B7:58:C6:49"
SECONDARY_BUDS="24:24:B7:04:58:B5"

# Try to disconnect both if connected
bluetoothctl disconnect ${MAIN_BUDS} 2>/dev/null || true
bluetoothctl disconnect ${SECONDARY_BUDS} 2>/dev/null || true

# Try to remove both if they exist
echo "Removing existing bud entries..."
bluetoothctl remove ${MAIN_BUDS} 2>/dev/null || true
bluetoothctl remove ${SECONDARY_BUDS} 2>/dev/null || true

echo "Waiting a moment..."
sleep 2

echo "Starting scan..."
bluetoothctl scan on &
SCAN_PID=$!

echo "Put your buds in pairing mode now..."
echo "Scanning for 7 seconds..."
sleep 7

# Kill the scan process gracefully
kill ${SCAN_PID} 2>/dev/null || true
# Give bluetoothctl a moment to clean up
sleep 1

echo "Attempting to pair with main buds..."
bluetoothctl pair ${MAIN_BUDS} || {
    echo "Pairing failed. Please try again."
    exit 1
}

echo "Attempting to connect..."
bluetoothctl connect ${MAIN_BUDS} || {
    echo "Connection failed. Please try again."
    exit 1
}

bash ~/nixosconfig/scripts/trust_buds.sh

echo "Pairing process complete!"
