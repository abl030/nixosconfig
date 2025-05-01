# Leaving this here for reference.  The micorsoft mousse here increments its bluetooth address
# every time it is paired with a new ccomputer. So this script doesn't help us.
# The mouse essentially can only be used with one computer at a time.
#!/usr/bin/bash

# Define the MAC address of your mouse
MOUSE_ADDR="CB:75:24:8F:69:D0"

echo "Attempting to reset connection for mouse: ${MOUSE_ADDR}"

# Try to disconnect if connected
echo "Disconnecting mouse (if connected)..."
bluetoothctl disconnect ${MOUSE_ADDR} 2>/dev/null || true

# Try to remove if it exists
echo "Removing existing mouse entry (if present)..."
bluetoothctl remove ${MOUSE_ADDR} 2>/dev/null || true

echo "Restarting Bluetooth stack..."
# --- IMPORTANT ---
# The following line uses a custom script specific to your NixOS setup.
# If you are on a different system (e.g., Ubuntu, Fedora), you might need to
# replace this with the appropriate command, often:
# sudo systemctl restart bluetooth.service
# If using systemctl, you might need to run this entire script with sudo.
bash ~/nixosconfig/scripts/bluetooth_restart.sh
# --- /IMPORTANT ---

echo "Waiting for Bluetooth stack to initialize..."
sleep 3 # Increased slightly to ensure stack is ready

echo "Starting scan..."
bluetoothctl scan on &
SCAN_PID=$!

echo "*** Put your mouse in pairing mode now! ***"
echo "Scanning for 10 seconds..." # Increased scan time slightly for mice
sleep 20

# Kill the scan process gracefully
echo "Stopping scan..."
kill ${SCAN_PID} 2>/dev/null || true
# Give bluetoothctl a moment to clean up
sleep 1

echo "Attempting to pair with mouse (${MOUSE_ADDR})..."
bluetoothctl pair ${MOUSE_ADDR} || {
  echo "ERROR: Pairing failed. Ensure the mouse is discoverable and in range."
  # Optionally turn scan back off if pairing fails early
  bluetoothctl scan off &>/dev/null
  exit 1
}

# Turn off scanning explicitly after successful pairing attempt
bluetoothctl scan off &>/dev/null

echo "Attempting to connect to mouse (${MOUSE_ADDR})..."
bluetoothctl connect ${MOUSE_ADDR} || {
  echo "ERROR: Connection failed. The mouse might have exited pairing mode or there was an issue."
  exit 1
}

echo "Marking mouse (${MOUSE_ADDR}) as trusted..."
bluetoothctl trust ${MOUSE_ADDR} || {
  echo "WARNING: Failed to mark mouse as trusted. It might not auto-connect next time."
  # Continue despite warning, as connection succeeded.
}

# If you prefer to use your specific trust script:
# 1. Comment out the `bluetoothctl trust ${MOUSE_ADDR} || { ... }` block above.
# 2. Uncomment the line below and make sure it correctly handles the mouse address.
# bash ~/nixosconfig/scripts/trust_buds.sh ${MOUSE_ADDR} # Assuming script accepts address as argument

echo "Process complete! Mouse ${MOUSE_ADDR} should be paired and connected."
