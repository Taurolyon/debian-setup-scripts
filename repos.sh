#!/bin/bash

# Configuration
COMPONENTS="contrib non-free non-free-firmware"
SOURCES_DIR="/etc/apt"
LISTS_DIR="${SOURCES_DIR}/sources.list.d"
MAIN_FILE="${SOURCES_DIR}/sources.list"
BACKUP_DIR="/var/backups/apt-sources"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 ERROR: This script must be run as root or with sudo."
    echo "Please run: sudo $0"
    exit 1
fi

# --- Backup Function ---
backup_apt_sources() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local archive_name="apt-sources_backup_${timestamp}.tar.gz"
    
    echo "Creating backup of ${SOURCES_DIR}/sources.list and ${LISTS_DIR}/..."
    
    # Ensure the backup directory exists (already running as root)
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "Error: Failed to create backup directory ${BACKUP_DIR}. Aborting backup."
        return 1
    fi

    # Create the tar.gz archive
    # The -C flag ensures paths in the archive are relative (e.g., sources.list, not /etc/apt/sources.list)
    if tar -czf "${BACKUP_DIR}/${archive_name}" -C "${SOURCES_DIR}" sources.list -C "${SOURCES_DIR}" sources.list.d; then
        echo "✅ Backup successful: ${BACKUP_DIR}/${archive_name}"
        return 0
    else
        echo "Error: Failed to create backup archive."
        return 1
    fi
}

# --- Core Logic Functions ---

# Function to add components to a .list file (one-line style)
add_to_list_file() {
    local file="$1"
    local temp_file
    
    # Check if the components are already present (ignoring commented lines)
    if ! grep -vE '^\s*#' "$file" | grep -qE 'contrib|non-free|non-free-firmware'; then
        temp_file=$(mktemp)

        # Look for the 'main' component and insert the new components after it.
        # This targets lines starting with deb/deb-src and ensures main is present before substitution.
        # The 'I' flag enables case-insensitive matching for 'deb'/'deb-src' and 'main'.
        if sed -E "/^(deb|deb-src) /I { /main/I s/(\s+main)(\s+|$)/\1 ${COMPONENTS}\2/I; }" "$file" > "$temp_file"; then
            
            # Check if any effective change was made by comparing files
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

# Function to add components to a .sources file (deb822 style)
add_to_sources_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)

    # Use awk to find 'Components:' lines and append missing components.
    if awk -v components_to_add="$COMPONENTS" '
        # Look for Components: line that does NOT contain contrib
        /^[[:space:]]*Components:/ && !/contrib/ {
            # Append the new components
            $0 = $0 " " components_to_add
            changed = 1
        }
        { print }
        END { exit !changed } # Non-zero exit if no change was made
    ' "$file" > "$temp_file"; then
        echo "-> Updated file: ${file}"
        mv "$temp_file" "$file"
    else
        # Awk exited non-zero (or failed)
        if grep -qE '^[[:space:]]*Components:.*(contrib|non-free|non-free-firmware)' "$file"; then
            echo "-> Components already present in ${file}. Skipping."
        else
            echo "-> Could not find 'Components:' line to update in ${file} or no change was necessary."
        fi
        rm "$temp_file"
    fi
}

# --- Main Script Execution ---

echo "Starting component addition for Debian Trixie (Debian 13)."

# 1. Run the backup
if ! backup_apt_sources; then
    echo "Script cannot proceed without a successful backup. Exiting."
    exit 1
fi

echo ""
# 2. Processing /etc/apt/sources.list (if it exists)
if [ -f "$MAIN_FILE" ]; then
    echo "Processing main file: $MAIN_FILE"
    # Check if it's likely a deb822 file by looking for 'Types:'
    if grep -q '^Types:' "$MAIN_FILE"; then
        add_to_sources_file "$MAIN_FILE"
    else
        add_to_list_file "$MAIN_FILE"
    fi
else
    echo "Main file $MAIN_FILE not found (typical with modern Debian installs using *.sources). Skipping."
fi

# 3. Processing files in /etc/apt/sources.list.d/
echo ""
echo "Processing files in $LISTS_DIR/..."
if [ -d "$LISTS_DIR" ]; then
    # Find all .list and .sources files and process them
    find "$LISTS_DIR" -type f \( -name "*.list" -o -name "*.sources" \) -print0 | while IFS= read -r -d $'\0' file; do
        echo "Processing file: ${file}"
        
        # Check the extension to determine the format
        if [[ "$file" == *.list ]]; then
            add_to_list_file "$file"
        elif [[ "$file" == *.sources ]]; then
            add_to_sources_file "$file"
        fi
    done
else
    echo "Directory $LISTS_DIR not found. Skipping."
fi

echo ""
echo "Finished modifying APT sources."
echo "************************************************************************"
echo "ATTENTION: You must now run 'apt update' to refresh your package list."
echo "************************************************************************"
