#!/bin/bash

# Configuration
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

# --- Architecture Check and Enable Function (Included for completeness) ---
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
    
    if ! grep -vE '^\s*#' "$file" | grep -qE 'contrib|non-free|non-free-firmware'; then
        temp_file=$(mktemp)

        if sed -E "/^(deb|deb-src) /I { /main/I s/(\s+main)(\s+|$)/\1 ${COMPONENTS}\2/I; }" "$file" > "$temp_file"; then
            
            if ! cmp -s "$file" "$temp_file"; then
                echo "-> Updated file: ${file}"
                mv "$temp_file" "$file"
            else
                echo "-> Components already present or 'main' not found in an entry in ${file}. No changes made."
                rm "$temp_file"
            fi
        else
            echo "Error: Failed to process ${file} with sed."
            rm "$temp_file"
        fi
    else
        echo "-> Components already present in ${file}. Skipping."
    fi
}

# --- Function to add components to a .sources file (deb822 style) ---
add_to_sources_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)

    if awk -v components_to_add="$COMPONENTS" '
        /^[[:space:]]*Components:/ && !/contrib/ {
            $0 = $0 " " components_to_add
            changed = 1
        }
        { print }
        END { exit !changed }
    ' "$file" > "$temp_file"; then
        echo "-> Updated file: ${file}"
        mv "$temp_file" "$file"
    else
        if grep -qE '^[[:space:]]*Components:.*(contrib|non-free|non-free-firmware)' "$file"; then
            echo "-> Components already present in ${file}. Skipping."
        else
            echo "-> Could not find 'Components:' line to update in ${file} or no change was necessary."
        fi
        rm "$temp_file"
    fi
}

# -----------------------------------------------------------------------
#                           MAIN EXECUTION
# -----------------------------------------------------------------------

echo "Starting configuration script for Debian Trixie (Debian 13)."

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

# 5. Execute apt update automatically
echo ""
echo "************************************************************************"
echo "Refreshing package lists (apt update)..."
if apt update; then
    echo "✅ Package lists successfully refreshed."
else
    echo "❌ ERROR: apt update failed. Please investigate source file errors."
    exit 1
fi
echo "************************************************************************"
echo "Finished configuration script."
