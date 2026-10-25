#!/bin/zsh
# Assembles dist/LightTable.app (arm64, macOS 14+), ad-hoc signed.
#
# Bundled helpers, all under Contents/Helpers/:
#   llama/      llama.cpp runtime for Qwen (Resources/llama, from TravelCut)
#   ffmpeg/     static LGPL ffmpeg + ffprobe from vendor/ffmpeg (scripts/build-ffmpeg-lgpl.sh)
#   exiftool/   exiftool script + Perl library, run by the system /usr/bin/perl
# Without vendor/ffmpeg the app still builds and falls back to Homebrew's ffmpeg at runtime;
# that is fine on a development Mac but not for giving the app to someone else.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/LightTable.app"
BUILD_FLAGS=(--disable-sandbox -c release --triple arm64-apple-macosx14.0 --scratch-path "$PROJECT_DIR/.build-release")

cd "$PROJECT_DIR"
swift build "${BUILD_FLAGS[@]}" --product LightTable
swift build "${BUILD_FLAGS[@]}" --product lighttable-cli
BIN_DIR=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/LightTable" "$APP_DIR/Contents/MacOS/LightTable"
cp "$BIN_DIR/lighttable-cli" "$APP_DIR/Contents/Helpers/lighttable-cli"
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP_DIR/Contents/Resources/"; done
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
[[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]] && cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cp -R "$PROJECT_DIR/Resources/llama" "$APP_DIR/Contents/Helpers/llama"

if [[ -x "$PROJECT_DIR/vendor/ffmpeg/ffmpeg" && -x "$PROJECT_DIR/vendor/ffmpeg/ffprobe" ]]; then
  cp -R "$PROJECT_DIR/vendor/ffmpeg" "$APP_DIR/Contents/Helpers/ffmpeg"
else
  echo "warning: vendor/ffmpeg missing; run scripts/build-ffmpeg-lgpl.sh. The app will use Homebrew ffmpeg." >&2
fi

EXIFTOOL_SRC=${EXIFTOOL_SRC:-$(ls -d /opt/homebrew/Cellar/exiftool/*/libexec 2>/dev/null | sort -V | tail -1)}
if [[ -n "$EXIFTOOL_SRC" && -f "$EXIFTOOL_SRC/bin/exiftool" ]]; then
  mkdir -p "$APP_DIR/Contents/Helpers/exiftool/lib"
  # The script finds Image::ExifTool in ./lib next to itself; run it with the system Perl.
  sed '1s|.*|#!/usr/bin/perl|' "$EXIFTOOL_SRC/bin/exiftool" > "$APP_DIR/Contents/Helpers/exiftool/exiftool"
  chmod +x "$APP_DIR/Contents/Helpers/exiftool/exiftool"
  cp -R "$EXIFTOOL_SRC/lib/perl5/"* "$APP_DIR/Contents/Helpers/exiftool/lib/"
  "$APP_DIR/Contents/Helpers/exiftool/exiftool" -ver > "$APP_DIR/Contents/Helpers/exiftool/VERSION.txt"
else
  echo "warning: exiftool not found (brew install exiftool, or set EXIFTOOL_SRC); photo features will need it installed." >&2
fi

chmod +x "$APP_DIR/Contents/MacOS/LightTable"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
file "$APP_DIR/Contents/MacOS/LightTable"
echo "Built: $APP_DIR"
