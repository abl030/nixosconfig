#!/usr/bin/bash

# # Cache sudo credentials upfront
# sudo -v || {
#     echo "Script requires sudo privileges"
#     exit 1
# }

# Define the buds addresses
BUDS_1="24:24:B7:04:58:B5"
BUDS_2="24:24:B7:58:C6:49"

echo "Toggling trust status for Buds..."

for buds in "$BUDS_1" "$BUDS_2"; do
    echo "Processing device: $buds"

    # Check current trust status
    if bluetoothctl info "$buds" | grep -q "Trusted: yes"; then
        echo "Current status: Trusted"
        echo "Removing trust for device $buds"
        bluetoothctl untrust "$buds"
    else
        echo "Current status: Untrusted"
        echo "Setting trust for device $buds"
        bluetoothctl trust "$buds"
    fi

    # Show final status
    if bluetoothctl info "$buds" | grep -q "Trusted: yes"; then
        echo "✓ Final status: Trusted"
    else
        echo "✓ Final status: Untrusted"
    fi

    echo "---"
done

echo "Trust toggle complete"
