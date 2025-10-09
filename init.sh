#!/bin/bash
set -euo pipefail

# === Configuration ===
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$ROOT_DIR/modules"

tools=(
    'ggui'
    'ggdirect'
)

# === Helper function ===
build_module() {
    local module_name="$1"
    local module_path="$MODULES_DIR/$module_name"

    echo ">>> Updating submodule: $module_name"
    git -C "$module_path" pull --rebase

    echo ">>> Building Debian package for: $module_name"
    cd "$module_name"

    # Clean any previous builds
    dpkg-buildpackage -us -uc -b

    cd "$ROOT_DIR"
    echo ">>> Finished building $module_name"
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
for module_dir in $tools; do
    build_module $module_dir
done

echo "=== All modules built successfully! ==="
