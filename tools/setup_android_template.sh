#!/usr/bin/env sh
# Restores the pieces of the Godot Android gradle build template that are too
# large to commit (godot-lib AARs, ~200 MB). Run once after cloning, before the
# first Android export. Requires the Godot 4.5 export templates to be installed
# (Editor > Manage Export Templates, or download the .tpz — see README.md).
set -e

TEMPLATES_DIR="${GODOT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/4.5.stable}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$TEMPLATES_DIR/android_source.zip"

if [ ! -f "$ZIP" ]; then
    echo "error: $ZIP not found."
    echo "Install the Godot 4.5 export templates first (see README.md), or set"
    echo "GODOT_TEMPLATES_DIR to the directory containing android_source.zip."
    exit 1
fi

echo "Extracting godot-lib AARs from $ZIP ..."
cd "$REPO_DIR/android/build"
unzip -o -q "$ZIP" "libs/*"
echo "Done. android/build/libs/ is ready."
