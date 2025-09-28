#!/bin/bash

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 ERROR: This script must be run as root or with sudo."
    echo "Please run: sudo $0"
    exit 1
fi

# --- Architecture Check and Enable ---
echo "Checking for i386 architecture support..."

# Check if 'i386' is already listed in foreign architectures
if dpkg --print-foreign-architectures | grep -q 'i386'; then
    echo "✅ i386 architecture is already enabled."
else
    echo "⚠️ i386 architecture is NOT enabled. Enabling now..."
    if dpkg --add-architecture i386; then
        echo "✅ i386 architecture successfully added."
        echo "NOTE: Run 'apt update' to refresh package lists with the new architecture."
    else
        echo "❌ ERROR: Failed to add i386 architecture."
        exit 1
    fi
fi

exit 0
