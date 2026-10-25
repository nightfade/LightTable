#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
WORK=$(mktemp -d)
swiftc -O "$PROJECT_DIR/scripts/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
