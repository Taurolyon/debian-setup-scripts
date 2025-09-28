#!/bin/bash

# =======================================================================
# --- SCRIPT 1: APT and System Setup ---
# =======================================================================

# Configuration Variables
COMPONENTS="contrib non-free non-free-firmware"
SOURCES_DIR="/etc/apt"
LISTS_DIR="${SOURCES_DIR}/sources.list.d"
MAIN_FILE="${SOURCES_DIR}/sources.list"
BACKUP_DIR="/var/backups/apt-sources"

# -----------------------------------------------------------------------
# --- Privilege Check and Elevation ---
# -----------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "⚠️ Not running as root. Re-executing script with 'sudo'..."
    exec sudo "$0" "$@"
fi

echo "✅ Running script with root privileges."

# -----------------------------------------------------------------------
# --- Functions ---
# -----------------------------------------------------------------------

# --- Architecture Check and Enable Function ---
check_and_enable_i386() {
    echo "Checking for i386 architecture support..."
    if dpkg --print-foreign-architectures | grep -q 'i386'; then
        echo "✅ i386 architecture is already enabled."
    else
        echo "⚠️ i386 architecture is NOT enabled. Enabling now..."
        if dpkg --add-architecture i386; then
            echo "✅ i386 architecture successfully added."
        else
            echo "❌ ERROR: Failed to add i386 architecture."
            return 1
        fi
    fi
    return 0
}

# --- Backup Function ---
backup_apt_sources() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local archive_name="apt-sources_backup_${timestamp}.tar.gz"
    
    echo "Creating backup of ${SOURCES_DIR}/sources.list and ${LISTS_DIR}/..."
    
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "Error: Failed to create backup directory ${BACKUP_DIR}. Aborting backup."
        return 1
    fi

    if tar -czf "${BACKUP_DIR}/${archive_name}" -C "${SOURCES_DIR}" sources.list -C "${SOURCES_DIR}" sources.list.d 2>/dev/null; then
        echo "✅ Backup successful: ${BACKUP_DIR}/${archive_name}"
        return 0
    else
        echo "Error: Failed to create backup archive."
        return 1
    fi
}

# --- Function to add components to a .list file (one-line style) ---
add_to_list_file() {
    local file="$1"
    local temp_file
    
    # 1. Check if it's an official Debian source file
    if grep -qE 'deb.*(deb.debian.org/debian|security.debian.org)' "$file"; then
        
        # 2. Check if it is MISSING 'contrib' OR 'non-free' in any active line
        if ! grep -vE '^\s*#' "$file" | grep -qE 'contrib|non-free'; then
            temp_file=$(mktemp)

            # CORRECTED SED COMMAND (Now only adds missing components: contrib non-free)
            # It looks for 'main' followed by a space and ANYTHING else (including non-free-firmware)
            if sed -E "/^(deb|deb-src) /I { 
                /(deb.debian.org\/debian|security.debian.org)/ { 
                    # Match 'main' followed by a space, and capture everything after the space (e.g., 'non-free-firmware')
                    /main/I s/(\s+main)(\s+.*)/\1 contrib non-free\2/I; 
                } 
            }" "$file" > "$temp_file"; then
                
                # Check if the file was modified
                if ! cmp -s "$file" "$temp_file"; then
                    echo "-> Updated file: ${file} (Added missing contrib and non-free)"
                    mv "$temp_file" "$file"
                else
                    echo "-> Official entries already contain contrib/non-free. No changes made."
                    rm "$temp_file"
                fi
            else
                echo "Error: Failed to process ${file} with sed."
                rm "$temp_file"
            fi
        else
            echo "-> Components (contrib/non-free) already present in official entries in ${file}. Skipping."
        fi
    else
        echo "-> File ${file} does not contain official Debian entries. Skipping component addition."
    fi
}

# --- Function to add components to a .sources file (deb822 style) ---
add_to_sources_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)

    if grep -qE 'URIs:.*(deb.debian.org/debian|security.debian.org)' "$file"; then
        
        # AWK LOGIC for deb822 format (fixed to respect stanzas)
        if awk -v components_to_add="$COMPONENTS" '
            /Types:/ { 
                is_debian_stanza = 0; 
            }
            
            /URIs:.*(deb.debian.org\/debian|security.debian.org)/ { 
                is_debian_stanza = 1; 
            }
            
            /^[[:space:]]*Components:/ && is_debian_stanza && !/contrib/ {
                $0 = $0 " " components_to_add;
                changed = 1;
            }
            
            { print }
            END { exit !changed }
        ' "$file" > "$temp_file"; then
            echo "-> Updated file: ${file}"
            mv "$temp_file" "$file"
        else
            if grep -qE '^[[:space:]]*Components:.*(contrib|non-free|non-free-firmware)' "$file"; then
                echo "-> Official entries already updated. Skipping."
            else
                echo "-> Could not find 'Components:' line to update in official entry of ${file} or no change was necessary."
            fi
            rm "$temp_file"
        fi
    else
        echo "-> File ${file} does not contain official Debian entries. Skipping component addition."
    fi
}

# -----------------------------------------------------------------------
#                           APT SETUP EXECUTION
# -----------------------------------------------------------------------

echo "Starting Debian Trixie system setup."

# 1. Check/Enable i386 architecture
echo
if ! check_and_enable_i386; then
    echo "Architecture configuration failed. Exiting script."
    exit 1
fi

# 2. Run the backup
echo
if ! backup_apt_sources; then
    echo "Script cannot proceed without a successful backup. Exiting."
    exit 1
fi

echo ""
echo "Starting APT component modification."

# 3. Processing /etc/apt/sources.list and /etc/apt/sources.list.d/
if [ -f "$MAIN_FILE" ]; then
    echo "Processing main file: $MAIN_FILE"
    if grep -q '^Types:' "$MAIN_FILE"; then
        add_to_sources_file "$MAIN_FILE"
    else
        add_to_list_file "$MAIN_FILE"
    fi
else
    echo "Main file $MAIN_FILE not found. Skipping."
fi

if [ -d "$LISTS_DIR" ]; then
    find "$LISTS_DIR" -type f \( -name "*.list" -o -name "*.sources" \) -print0 | while IFS= read -r -d $'\0' file; do
        echo "Processing file: ${file}"
        
        if [[ "$file" == *.list ]]; then
            add_to_list_file "$file"
        elif [[ "$file" == *.sources ]]; then
            add_to_sources_file "$file"
        fi
    done
else
    echo "Directory $LISTS_DIR not found. Skipping."
fi

# 4. Execute first apt update to refresh package lists with new sources/architecture
echo ""
echo "************************************************************************"
echo "Refreshing package lists (apt update)..."
if apt update; then
    echo "✅ Package lists successfully refreshed."
else
    echo "❌ ERROR: Initial apt update failed after configuration. Exiting."
    exit 1
fi
echo "************************************************************************"

# =======================================================================
# --- SCRIPT 2: NVIDIA & Steam Installation ---
# =======================================================================

echo ""
echo "Starting NVIDIA Driver and Steam installation."

# 5. Install the packages
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

# 6. Append the configuration line
CONFIG_FILE="/etc/modprobe.d/nvidia-options.conf"
CONFIG_LINE="options nvidia NVreg_PreserveVideoMemoryAllocations=1"

# Check if the line is already in the file before appending
if ! grep -qF "$CONFIG_LINE" "$CONFIG_FILE" 2>/dev/null; then
    echo "$CONFIG_LINE" >> "$CONFIG_FILE"
    echo "✅ Added configuration line to $CONFIG_FILE"
else
    echo "➡️ Configuration line already present in $CONFIG_FILE. Skipping."
fi

echo ""
echo "========================================================================"
echo "Installation complete. It's crucial to reboot your system for the new"
echo "kernel modules and drivers to take effect."
echo "========================================================================"
