#!/bin/zsh
# Builds static LGPL ffmpeg + ffprobe for bundling into LightTable.app.
#
# Homebrew's ffmpeg is a GPL build (x264/x265) linked against ~30 dylibs, so it cannot ship
# inside the app. LightTable only needs VideoToolbox encoders, ProRes, lut3d and the native
# AAC encoder, all LGPL. Output: vendor/ffmpeg/{ffmpeg,ffprobe,VERSION.txt,LICENSE.md}.
set -euo pipefail

VERSION=7.1.1
# Pinned after checking ffmpeg-7.1.1.tar.xz.asc against the FFmpeg release signing key
# (FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8) on 2026-10-25.
SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
URL="https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"

PROJECT_DIR=${0:A:h:h}
WORK="$PROJECT_DIR/.build-ffmpeg"
OUT="$PROJECT_DIR/vendor/ffmpeg"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

if [[ ! -f ffmpeg-$VERSION.tar.xz ]]; then
  curl --fail --location --retry 3 -o ffmpeg-$VERSION.tar.xz "$URL"
fi
ACTUAL=$(shasum -a 256 ffmpeg-$VERSION.tar.xz | awk '{print $1}')
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "SHA-256 mismatch for ffmpeg-$VERSION.tar.xz: $ACTUAL" >&2
  exit 1
fi
rm -rf src && mkdir src && tar -xf ffmpeg-$VERSION.tar.xz -C src --strip-components 1
cd src

# No --enable-gpl / --enable-nonfree: the result is LGPL 2.1+. Static, so the binaries only
# depend on system frameworks. Network, devices and docs are not needed.
./configure \
  --prefix="$WORK/install" \
  --arch=arm64 --cc=clang \
  --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
  --enable-static --disable-shared \
  --disable-doc --disable-debug --disable-ffplay \
  --disable-network --disable-indevs --disable-outdevs \
  --disable-sdl2 --disable-xlib --disable-libxcb \
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib
make -j"$(sysctl -n hw.ncpu)"
make install

cp "$WORK/install/bin/ffmpeg" "$WORK/install/bin/ffprobe" "$OUT/"
cp COPYING.LGPLv2.1 "$OUT/LICENSE.md"
{
  echo "ffmpeg $VERSION, built $(date +%Y-%m-%d) by scripts/build-ffmpeg-lgpl.sh"
  echo "Source: $URL (sha256 $SHA256)"
  echo "License: LGPL 2.1 or later (no --enable-gpl, no --enable-nonfree)"
  "$OUT/ffmpeg" -hide_banner -buildconf | sed 's/^/  /'
} > "$OUT/VERSION.txt"
otool -L "$OUT/ffmpeg"
"$OUT/ffmpeg" -hide_banner -L | head -3
echo "Built: $OUT"
