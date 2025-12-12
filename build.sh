#!/bin/bash
set -euo pipefail

# === Configuration ===
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$ROOT_DIR/modules"

# === GPG Sandbox Setup ===
# Create a temporary directory for the GPG keyring to ensure isolation
export GNUPGHOME="$(mktemp -d)"
# Ensure the temporary directory is removed when the script exits
trap 'rm -rf "$GNUPGHOME"' EXIT

# Path to the trusted keys file
KEYS_FILE="$ROOT_DIR/builder/KEYS"

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

# === Module packager ===
build_module_to_debian() {
    local package_module_path="$1"              # The module package, usually just resides int he project root directory.
    local sub_module_path="$MODULES_DIR/$1"     # little bit confusing, but the git sub module resides inside the module dir and has name as the package.

    echo ">>> Updating submodule: $package_module_path"
    git -C "$sub_module_path" pull --rebase

    echo ">>> Verifying GPG signature for: $package_module_path"
    if ! git -C "$sub_module_path" verify-commit HEAD > /dev/null 2>&1; then
        echo ">>> ERROR: GPG signature verification failed for $package_module_path! Stopping build to prevent supply chain attack."
        exit 1
    fi

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

# Since the submodules are following commit head instead of a branch head.
git submodule foreach 'git checkout main || true'
git submodule foreach 'git pull origin main'

# Discover all modules in ./modules/
for module_dir in "${tools[@]}"; do
    build_module_to_debian $module_dir
    build_module_to_rpm $module_dir
done

echo "=== All modules built successfully! ==="
find "$ROOT_DIR" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -printf "%f\n"
