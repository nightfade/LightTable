#!/bin/zsh
# Builds the app and zips it for handing to another Mac: dist/LightTable-<version>-macOS.zip + .sha256.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
./scripts/build-app.sh 2>&1 | cat
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="dist/LightTable-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/LightTable.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
unzip -tq "$ZIP"
echo "Packaged: $ZIP"
