#!/bin/bash
set -euo pipefail

# === Configuration ===
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$ROOT_DIR/modules"

# === Source helper scripts ===
source "$ROOT_DIR/updateChangelog.sh"

# === GPG Sandbox Setup ===
# Create a temporary directory for the GPG keyring to ensure isolation
export GNUPGHOME="$(mktemp -d)"
# Ensure the temporary directory is removed when the script exits
trap 'rm -rf "$GNUPGHOME"' EXIT

# Path to the trusted keys file
KEYS_FILE="$ROOT_DIR/maintainers.gpg"

# Fail immediately if the keys file is missing
if [[ ! -f "$KEYS_FILE" ]]; then
    echo ">>> ERROR: Trusted keys file not found at $KEYS_FILE"
    exit 1
fi

# Import the trusted keys into the temporary keyring
echo ">>> Importing trusted keys from $KEYS_FILE..."
gpg --import "$KEYS_FILE"

tools=(
    ggdirect
    ggui
)

# Get the latest semver tag from a git repository
# Args: $1 - path to the git repository
secure_git_tag_order() {
    local repo_path="$1"
    # Filter only valid semver tags (vX.Y.Z or X.Y.Z), sort by version, get latest
    # Note: grep returns exit code 1 when no matches, so we use || true to prevent crash with pipefail
    git -C "$repo_path" tag --list 2>/dev/null | \
        { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } | \
        sort -V | \
        tail -n 1
}

# === Module packager ===
build_module_to_debian() {
    local package_module_path="$1"              # The module package, usually just resides int he project root directory.
    local sub_module_path="$MODULES_DIR/$1"     # little bit confusing, but the git sub module resides inside the module dir and has name as the package.

    echo ">>> Updating submodule: $package_module_path"
    
    # Ensure we're on main branch (not detached) so pull --rebase works
    echo ">>> Checking out main branch for: $package_module_path"
    git -C "$sub_module_path" checkout main
    
    # Pull latest changes from origin
    echo ">>> Pulling latest changes for: $package_module_path"
    git -C "$sub_module_path" pull --rebase origin main

    # Fetch all tags from origin
    echo ">>> Fetching tags for submodule: $package_module_path"
    git -C "$sub_module_path" fetch --tags --prune

    # Find the latest semver tag
    local latest_tag
    latest_tag=$(secure_git_tag_order "$sub_module_path")

    # Checkout the latest tag if available (this will detach HEAD, which is expected for tags)
    if [[ -z "$latest_tag" ]]; then
        echo ">>> WARNING: No semver tags found for $package_module_path, staying on main branch."
    else
        echo ">>> Found latest tag for $package_module_path: $latest_tag"
        echo ">>> Checking out tag: $latest_tag"
        git -C "$sub_module_path" checkout "$latest_tag"
    fi

    # Verify GPG signature - try tag signature first, then commit signature
    echo ">>> Verifying GPG signature for: $package_module_path"
    local signature_verified=false
    
    # If we checked out a tag, verify the tag signature
    if [[ -n "$latest_tag" ]]; then
        if git -C "$sub_module_path" verify-tag "$latest_tag" >/dev/null 2>&1; then
            echo ">>> Tag signature verified for: $latest_tag"
            signature_verified=true
        fi
    fi
    
    # Fall back to verifying the commit signature
    if [[ "$signature_verified" == "false" ]]; then
        if git -C "$sub_module_path" verify-commit HEAD >/dev/null 2>&1; then
            echo ">>> Commit signature verified for HEAD"
            signature_verified=true
        fi
    fi

    if [[ "$signature_verified" == "false" ]]; then
        echo ">>> ERROR: GPG signature verification failed for $package_module_path!"
        echo ">>> Neither tag nor HEAD commit has a valid signature."
        echo ">>> Stopping build to prevent supply chain attack."
        exit 1
    fi

    echo ">>> Updating changelog for: $package_module_path"
    update_changelog_for_module "$package_module_path"

    echo ">>> Building Debian package for: $package_module_path"
    cd "$package_module_path"

    dh_clean || true

    # Build for debian
    dpkg-buildpackage -us -uc -b

    cd "$ROOT_DIR"
    echo ">>> Finished building $package_module_path"
}

# Uses alien to re-package the deb packages into RPM packages
build_module_to_rpm() {
    local package_module_path="$1"
    local module_pkg_dir="$ROOT_DIR/$1"
    local debian_files_list="$module_pkg_dir/debian/files"

    if ! command -v alien >/dev/null 2>&1; then
        echo ">>> ERROR: alien is not installed. Skipping RPM conversion for $package_module_path."
        return 1
    fi

    if [[ ! -f "$debian_files_list" ]]; then
        echo ">>> No debian/files manifest found for $package_module_path. Skipping RPM conversion."
        return 0
    fi

    local deb_artifacts=()
    while IFS=' ' read -r artifact _; do
        [[ -z "$artifact" ]] && continue
        [[ "${artifact}" != *.deb ]] && continue
        deb_artifacts+=("$artifact")
    done < "$debian_files_list"

    if [[ ${#deb_artifacts[@]} -eq 0 ]]; then
        echo ">>> No .deb artifacts listed for $package_module_path. Skipping RPM conversion."
        return 0
    fi

    cd "$ROOT_DIR"

    for deb_file in "${deb_artifacts[@]}"; do
        local deb_path="$ROOT_DIR/$deb_file"

        if [[ ! -f "$deb_path" ]]; then
            echo ">>> WARNING: Expected Debian package $deb_path not found; skipping."
            continue
        fi

        echo ">>> Converting $deb_file to RPM..."

        # Remove previously generated RPMs with the same stem to avoid stale artifacts.
        local deb_stem="${deb_file%.deb}"
        rm -f "${deb_stem}"*.rpm >/dev/null 2>&1 || true

        if alien --to-rpm --scripts "$deb_path"; then
            echo ">>> Successfully converted $deb_file to RPM."
        else
            echo ">>> ERROR: Failed to convert $deb_file to RPM."
        fi
    done

    cd "$ROOT_DIR"
    echo ">>> Finished converting RPM packages for: $package_module_path"
}

# === Main ===
echo "=== GGTools Debian Vendor Init ==="

# Initialize submodules if needed
echo ">>> Syncing submodules..."
git submodule update --init --recursive

# Discover all modules in ./modules/
for module_dir in "${tools[@]}"; do
    build_module_to_debian $module_dir
    build_module_to_rpm $module_dir
done

echo "=== All modules built successfully! ==="
find "$ROOT_DIR" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -printf "%f\n"
