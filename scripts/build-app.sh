#!/bin/zsh
# Assembles dist/LightTable.app (arm64, macOS 14+), ad-hoc signed.
#
# Bundled helpers. Contents/Helpers holds only Mach-O code (codesign treats every file there as
# code); scripts and text go under Contents/Resources:
#   Helpers/llama/       llama.cpp runtime for Qwen (Resources/llama, from TravelCut)
#   Helpers/ffmpeg/      static LGPL ffmpeg + ffprobe from vendor/ffmpeg (scripts/build-ffmpeg-lgpl.sh)
#   Resources/exiftool/  exiftool script + Perl library, run by the system /usr/bin/perl
#   Resources/Licenses/  licence and version notes of the above
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
# `--show-bin-path` fails with "Unable to flush stdout" when the script's output goes to a file.
BIN_DIR=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path 2>/dev/null || true)
[[ -d "$BIN_DIR" ]] || BIN_DIR="$PROJECT_DIR/.build-release/release"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/LightTable" "$APP_DIR/Contents/MacOS/LightTable"
cp "$BIN_DIR/lighttable-cli" "$APP_DIR/Contents/Helpers/lighttable-cli"
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP_DIR/Contents/Resources/"; done
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
[[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]] && cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
LICENSES="$APP_DIR/Contents/Resources/Licenses"
mkdir -p "$LICENSES/llama" "$APP_DIR/Contents/Helpers/llama"
for f in "$PROJECT_DIR/Resources/llama/"*; do
  if file "$f" | grep -q Mach-O; then cp "$f" "$APP_DIR/Contents/Helpers/llama/"; else cp "$f" "$LICENSES/llama/"; fi
done

if [[ -x "$PROJECT_DIR/vendor/ffmpeg/ffmpeg" && -x "$PROJECT_DIR/vendor/ffmpeg/ffprobe" ]]; then
  mkdir -p "$APP_DIR/Contents/Helpers/ffmpeg" "$LICENSES/ffmpeg"
  cp "$PROJECT_DIR/vendor/ffmpeg/ffmpeg" "$PROJECT_DIR/vendor/ffmpeg/ffprobe" "$APP_DIR/Contents/Helpers/ffmpeg/"
  cp "$PROJECT_DIR/vendor/ffmpeg/LICENSE.md" "$PROJECT_DIR/vendor/ffmpeg/VERSION.txt" "$LICENSES/ffmpeg/"
else
  echo "warning: vendor/ffmpeg missing; run scripts/build-ffmpeg-lgpl.sh. The app will use Homebrew ffmpeg." >&2
fi

EXIFTOOL_SRC=${EXIFTOOL_SRC:-$(ls -d /opt/homebrew/Cellar/exiftool/*/libexec 2>/dev/null | sort -V | tail -1)}
if [[ -n "$EXIFTOOL_SRC" && -f "$EXIFTOOL_SRC/bin/exiftool" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources/exiftool/lib"
  # The script finds Image::ExifTool in ./lib next to itself; run it with the system Perl.
  sed '1s|.*|#!/usr/bin/perl|' "$EXIFTOOL_SRC/bin/exiftool" > "$APP_DIR/Contents/Resources/exiftool/exiftool"
  chmod +x "$APP_DIR/Contents/Resources/exiftool/exiftool"
  cp -R "$EXIFTOOL_SRC/lib/perl5/"* "$APP_DIR/Contents/Resources/exiftool/lib/"
  EXIFTOOL_VERSION=$("$APP_DIR/Contents/Resources/exiftool/exiftool" -ver 2>/dev/null || echo unknown)
  print -r -- "exiftool $EXIFTOOL_VERSION (from $EXIFTOOL_SRC)" > "$APP_DIR/Contents/Resources/exiftool/VERSION.txt"
else
  echo "warning: exiftool not found (brew install exiftool, or set EXIFTOOL_SRC); photo features will need it installed." >&2
fi

chmod +x "$APP_DIR/Contents/MacOS/LightTable"
plutil -lint "$APP_DIR/Contents/Info.plist"
# Sign nested Mach-O helpers first, then the app itself. `--deep` does not handle the SwiftPM
# resource bundle and the exiftool Perl library, and Apple discourages it for signing.
find "$APP_DIR/Contents/Helpers" -type f -perm +111 -print0 | while IFS= read -r -d '' helper; do
  if file "$helper" | grep -q "Mach-O"; then codesign --force --sign - --timestamp=none "$helper"; fi
done
find "$APP_DIR/Contents/Helpers" -name "*.dylib" -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
file "$APP_DIR/Contents/MacOS/LightTable"
echo "Built: $APP_DIR"
