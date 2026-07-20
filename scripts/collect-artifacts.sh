#!/bin/sh
# collect-artifacts.sh <openwrt-dir> <out-dir> — collect firmware artifacts, keeping original filenames
set -eu
owrt=$1; up=$2
src=$owrt/bin/targets
[ -d "$src" ] || { echo "error: $src not found" >&2; exit 1; }
mkdir -p "$up"
find "$src" -type d -name packages -prune -o -type f -print | while read -r f; do
  cp -f "$f" "$up/$(basename "$f")"
done
# drop build byproducts that no config option can disable
rm -f "$up"/*-bl2.bin "$up"/*.buildinfo "$up"/*profiles.json \
      "$up"/*.manifest "$up"/*-rootfs.img.gz "$up"/*-rootfs.tar.gz \
      "$up"/*-generic-kernel.bin "$up"/*sha256sums
# regenerate checksums: the originals are per-target and no longer match after filtering
(
  cd "$up"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- * > sha256sums
  else
    shasum -a 256 -- * > sha256sums
  fi
)
ls -l "$up" >&2
