#!/bin/bash
# Based on instructions provided at: https://wiki.debian.org/NvidiaGraphicsDrivers#trixie-550

# --- Privilege Check and Elevation ---
if [ "$(id -u)" -ne 0 ]; then
    echo "⚠️ Not running as root. Re-executing script with 'sudo'..."
    # $0 is the script name; $@ passes all arguments
    exec sudo "$0" "$@"
    # The 'exec' command replaces the current shell process, 
    # so the code below this line only runs as root.
fi

# -------------------------------------------------------------
# --- Commands Below This Line Run ONLY AS ROOT ---
# -------------------------------------------------------------

echo "✅ Running script with root privileges."

# Update the package list
if ! apt update; then
    echo "❌ ERROR: Failed to run apt update. Exiting."
    exit 1
fi

# Install the packages
if ! apt install -y \
    linux-headers-$(dpkg --print-architecture) \
    nvidia-kernel-dkms \
    nvidia-driver \
    firmware-misc-nonfree \
    nvidia-driver-libs:i386 \
    mesa-vulkan-drivers \
    libglx-mesa0:i386 \
    mesa-vulkan-drivers:i386 \
    libgl1-mesa-dri:i386 \
    steam-installer
then
    echo "❌ ERROR: Failed to install one or more packages. Check the output above."
    exit 1
fi

# Append the configuration line
CONFIG_FILE="/etc/modprobe.d/nvidia-options.conf"
CONFIG_LINE="options nvidia NVreg_PreserveVideoMemoryAllocations=1"

# Check if the line is already in the file before appending (optional but good practice)
if ! grep -qF "$CONFIG_LINE" "$CONFIG_FILE" 2>/dev/null; then
    echo "$CONFIG_LINE" >> "$CONFIG_FILE"
    echo "✅ Added configuration line to $CONFIG_FILE"
else
    echo "➡️ Configuration line already present in $CONFIG_FILE. Skipping."
fi

echo "Installation complete. Please reboot your system for changes to take effect."
