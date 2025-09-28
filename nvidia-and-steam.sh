#!/bin/bash

# =======================================================================
# --- SCRIPT 1: APT and System Setup ---
# =======================================================================

# Configuration Variables
# Redefining COMPONENTS as an array for targeted checking
REQUIRED_COMPONENTS=("contrib" "non-free" "non-free-firmware") 
SOURCES_DIR="/etc/apt"
LISTS_DIR="${SOURCES_DIR}/sources.list.d"
MAIN_FILE="${SOURCES_DIR}/sources.list"
BACKUP_DIR="/var/backups/apt-sources"
DEBIAN_URIS="deb.debian.org/debian|security.debian.org"

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
    local component_added=0
    
    # Check 1: Is it a Debian official source file?
    if grep -qE "deb.*(${DEBIAN_URIS})" "$file"; then
        
        # Iterate over each required component (contrib, non-free, non-free-firmware)
        for COMPONENT in "${REQUIRED_COMPONENTS[@]}"; do
            
            # Check if the current component is missing in any active, official line
            # We check the file itself because we need to update it in place.
            if ! grep -vE '^\s*#' "$file" | grep -qE "deb.*(${DEBIAN_URIS}).*(\s$COMPONENT|\s$COMPONENT\s)"; then
                
                # If component is missing, prepare temporary file
                temp_file=$(mktemp)

                # SED command: Insert only the missing COMPONENT
                # Strategy: Replace the entire line's content with itself PLUS the missing component.
                # A simpler, safer strategy for sequential insertion: target 'main'
                
                # Check if 'main' is missing, then insert component after it.
                if sed -E "/^(deb|deb-src) /I { 
                    /(${DEBIAN_URIS})/ { 
                        # If the line contains 'main' but NOT the component, insert it.
                        /main/I !/\s${COMPONENT}/ {
                            s/(\s+main)(\s+.*)/\1 ${COMPONENT}\2/I;
                        }
                    } 
                }" "$file" > "$temp_file"; then
                    
                    # Check if the file was modified
                    if ! cmp -s "$file" "$temp_file"; then
                        echo "-> Inserted '${COMPONENT}' into ${file}."
                        mv "$temp_file" "$file"
                        component_added=1
                    else
                        # If sed runs but makes no change (e.g., component was added in a previous run)
                        rm "$temp_file"
                    fi
                else
                    echo "Error: Failed to process ${file} with sed while adding ${COMPONENT}."
                    rm "$temp_file"
                    return 1
                fi
            fi
        done
        
        if [ "$component_added" -eq 1 ]; then
            echo "-> Finished applying updates to ${file}."
        else
            echo "-> All required components are already present in ${file}. Skipping."
        fi
    else
        echo "-> File ${file} does not contain official Debian entries. Skipping component addition."
    fi
}


# --- Function to add components to a .sources file (deb822 style) ---
add_to_sources_file() {
    local file="$1"
    local temp_file
    local component_added=0
    
    if grep -qE "URIs:.*(${DEBIAN_URIS})" "$file"; then
        
        # Iterate and apply changes sequentially for each missing component
        for COMPONENT in "${REQUIRED_COMPONENTS[@]}"; do
            # Check if the component is missing in any Components line in the file
            if ! grep -vE '^\s*#' "$file" | grep -qE "Components:.*$COMPONENT"; then
                temp_file=$(mktemp)
                
                # AWK LOGIC: Only modify if COMPONENT is missing and URI matches.
                # The file is overwritten on each loop if a component is missing.
                if awk -v component_to_add="$COMPONENT" -v uris="$DEBIAN_URIS" '
                    /Types:/ { is_debian_stanza = 0; }
                    
                    /URIs:.*('"${uris}"')/ { is_debian_stanza = 1; }
                    
                    /^[[:space:]]*Components:/ && is_debian_stanza && $0 !~ component_to_add {
                        $0 = $0 " " component_to_add;
                        changed = 1;
                    }
                    
                    { print }
                    END { exit !changed }
                ' "$file" > "$temp_file"; then
                    
                    if ! cmp -s "$file" "$temp_file"; then
                        echo "-> Inserted '${COMPONENT}' into ${file}."
                        mv "$temp_file" "$file"
                        component_added=1
                    fi
                    
                fi
                rm "$temp_file" # Clean up temp file regardless of status
            fi
        done
        
        if [ "$component_added" -eq 1 ]; then
            echo "-> Finished applying updates to ${file}."
        else
            echo "-> All required components are already present in ${file}. Skipping."
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

# 3. Processing /etc/apt/sources.list 
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

# 4. Processing files in /etc/apt/sources.list.d/
echo ""
echo "Processing files in $LISTS_DIR/..."
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

# 5. Execute first apt update to refresh package lists with new sources/architecture
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

# 6. Install the packages
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

# 7. Append the configuration line
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
