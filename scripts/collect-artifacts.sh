#!/bin/sh
# collect-artifacts.sh <openwrt-dir> <upload-dir> <meta-dir>
# Split what the build produced into two piles, keeping original filenames:
#   upload-dir  every file that can be flashed as-is — this is what the release
#               ships, and "everything in here is firmware" is the invariant
#               release-notes.sh relies on to describe the images
#   meta-dir    profiles.json and the per-device manifests: inputs to the release
#               notes, never uploaded
# Both are copies; bin/targets is left untouched for later steps to read.
set -eu
owrt=$1; up=$2; meta=${3:?usage: collect-artifacts.sh <openwrt-dir> <upload-dir> <meta-dir>}
src=$owrt/bin/targets
[ -d "$src" ] || { echo "error: $src not found" >&2; exit 1; }
mkdir -p "$up" "$meta"
find "$src" -type d -name packages -prune -o -type f -print | while read -r f; do
  case "$(basename "$f")" in
    *.manifest|profiles.json) cp -f "$f" "$meta/$(basename "$f")" ;;
    *)                        cp -f "$f" "$up/$(basename "$f")" ;;
  esac
done
# Build byproducts that no config option can disable. Bootloader images are
# deliberately absent from this list: the ubootmod install path flashes
# preloader.bin and bl31-uboot.fip by hand, so they are first-class artifacts.
#   *-rootfs.*             a rootfs with no bootloader — not flashable on its own
#   *-generic-kernel.bin   the bare x86 kernel. The glob needs that literal
#                          ending, so it cannot swallow *-initramfs-kernel.bin
rm -f "$up"/*.buildinfo \
      "$up"/*-rootfs.img.gz "$up"/*-rootfs.tar.gz \
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
ls -l "$up" "$meta" >&2
