#!/bin/bash
set -euo pipefail

# Reads the /modules/ggui/versions/* and /modules/ggdirect/versions/* and takes the highest number changelog.* and writes it into the respective package changelog file for deb.

# Configuration
MAINTAINER_NAME="Gabriel Golzar"
MAINTAINER_EMAIL="golzar.gabriel@gmail.com"

find_highest_changelog() {
    local search_dir="$1"
    if [ -d "$search_dir" ]; then
        find "$search_dir" -maxdepth 1 -name "version_*" -print0 | \
            sort -z -V | \
            tail -z -n 1 | \
            tr -d '\0'
    fi
}

extract_version_from_filename() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    # Extract version from version_X.Y.Z.md -> X.Y.Z
    echo "$filename" | sed -E 's/version_([0-9.]+)\..*/\1/'
}

get_current_version_in_changelog() {
    local changelog_file="$1"
    if [ -f "$changelog_file" ]; then
        # Extract version from first line: package (X.Y.Z-N) ...
        head -n1 "$changelog_file" | sed -E 's/.*\(([0-9.]+)-[0-9]+\).*/\1/'
    else
        echo ""
    fi
}

parse_version_file_to_bullets() {
    local version_file="$1"
    # Extract lines starting with "- " at the beginning (no indentation), format as changelog bullets
    # Also remove any leading '#' characters from the text
    grep -E '^-\s+' "$version_file" | \
        sed -E 's/^-\s+/  * /' | \
        sed -E 's/^(\s*\*\s*)#+ */\1/' | \
        head -20  # Limit to first 20 bullet points to keep it reasonable
}

generate_changelog_entry() {
    local package_name="$1"
    local version="$2"
    local version_file="$3"
    local revision="${4:-1}"
    
    local date_str
    date_str=$(date -R)
    
    echo "${package_name} (${version}-${revision}) unstable; urgency=medium"
    echo ""
    
    local bullets
    bullets=$(parse_version_file_to_bullets "$version_file")
    
    if [ -n "$bullets" ]; then
        echo "$bullets"
    else
        echo "  * Update to version ${version}"
    fi
    
    echo ""
    echo " -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  ${date_str}"
}

update_package_changelog() {
    local package_name="$1"
    local versions_path="$2"
    local dest_file="$3"

    echo "Looking for changelogs in $versions_path..."
    
    local highest_log
    highest_log=$(find_highest_changelog "$versions_path")

    if [ -n "$highest_log" ] && [ -f "$highest_log" ]; then
        local new_version
        new_version=$(extract_version_from_filename "$highest_log")
        
        local current_version
        current_version=$(get_current_version_in_changelog "$dest_file")
        
        echo "Found highest version file: $highest_log (version: $new_version)"
        echo "Current changelog version: $current_version"
        
        # Check if this version is already in the changelog
        if [ "$new_version" = "$current_version" ]; then
            echo "Version $new_version already in changelog, skipping."
            return
        fi
        
        echo "Prepending new entry to $dest_file"
        
        local new_entry
        new_entry=$(generate_changelog_entry "$package_name" "$new_version" "$highest_log")
        
        # Create temp file with new entry + existing content
        local temp_file
        temp_file=$(mktemp)
        
        echo "$new_entry" > "$temp_file"
        echo "" >> "$temp_file"
        
        if [ -f "$dest_file" ]; then
            cat "$dest_file" >> "$temp_file"
        fi
        
        mv "$temp_file" "$dest_file"
        echo "Changelog updated successfully."
    else
        echo "No version_* files found in $versions_path"
    fi
}

# Main function to update changelog for a specific module
# Usage: update_changelog_for_module <module_name>
update_changelog_for_module() {
    local module_name="$1"
    
    if [ -z "$module_name" ]; then
        echo "ERROR: Module name is required"
        return 1
    fi
    
    # Determine the versions path - check both possible locations
    local versions_path="modules/${module_name}/versions"
    if [ ! -d "$versions_path" ] && [ -d "modules/${module_name}/bin/versions" ]; then
        versions_path="modules/${module_name}/bin/versions"
    fi
    
    local changelog_path="${module_name}/debian/changelog"
    
    echo ">>> Updating changelog for module: $module_name"
    update_package_changelog "$module_name" "$versions_path" "$changelog_path"
}

# Only run directly if script is executed, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # GGUI
    update_changelog_for_module "ggui"

    # GGDIRECT
    update_changelog_for_module "ggdirect"
fi


