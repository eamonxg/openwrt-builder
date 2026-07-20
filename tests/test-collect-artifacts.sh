#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/collect-artifacts.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

b=$tmp/owrt/bin/targets/mediatek/filogic
mkdir -p "$b/packages"
echo img > "$b/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo img > "$b/openwrt-x86-64-generic-squashfs-sysupgrade.bin"
echo sum > "$b/sha256sums"
echo pkg > "$b/packages/foo.apk"
# the U-Boot install path needs these three; they must survive
echo ini > "$b/openwrt-mediatek-filogic-cudy_tr3000-v1-initramfs-kernel.bin"
echo pre > "$b/openwrt-mediatek-filogic-cudy_tr3000-v1-ubootmod-preloader.bin"
echo fip > "$b/openwrt-mediatek-filogic-cudy_tr3000-v1-ubootmod-bl31-uboot.fip"
# metadata: not firmware, but the release notes read it — routed to meta-dir
echo pj > "$b/profiles.json"
echo mf > "$b/openwrt-mediatek-filogic-cudy_tr3000-v1.manifest"
echo mf > "$b/openwrt-mediatek-filogic-cudy_tr3000-256mb-v1.manifest"
# build byproducts never published
echo bi > "$b/config.buildinfo"
echo gk > "$b/openwrt-x86-64-generic-generic-kernel.bin"
echo rt > "$b/openwrt-x86-64-generic-rootfs.tar.gz"
echo ri > "$b/openwrt-x86-64-generic-squashfs-rootfs.img.gz"

sh "$sc" "$tmp/owrt" "$tmp/up" "$tmp/meta"

# artifacts ship under their original OpenWrt filenames, no prefixes added
[ -f "$tmp/up/openwrt-x86-64-generic-squashfs-combined-efi.img.gz" ] \
  || { echo "FAIL: image must keep its original filename"; exit 1; }
[ -f "$tmp/up/openwrt-x86-64-generic-squashfs-sysupgrade.bin" ] \
  || { echo "FAIL: sysupgrade must be kept"; exit 1; }
[ -z "$(find "$tmp/up" -name '*foo.apk*')" ] || { echo "FAIL: packages dir must be excluded"; exit 1; }

# the U-Boot first-install path: initramfs image and both bootloader blobs
[ -f "$tmp/up/openwrt-mediatek-filogic-cudy_tr3000-v1-initramfs-kernel.bin" ] \
  || { echo "FAIL: initramfs image is the only way to flash from U-Boot, it must ship"; exit 1; }
[ -f "$tmp/up/openwrt-mediatek-filogic-cudy_tr3000-v1-ubootmod-preloader.bin" ] \
  || { echo "FAIL: preloader.bin must ship (written to the BL2 partition)"; exit 1; }
[ -f "$tmp/up/openwrt-mediatek-filogic-cudy_tr3000-v1-ubootmod-bl31-uboot.fip" ] \
  || { echo "FAIL: bl31-uboot.fip must ship (written to the FIP partition)"; exit 1; }

# metadata goes to meta-dir, not to the upload dir
[ -f "$tmp/meta/profiles.json" ] || { echo "FAIL: profiles.json must reach meta-dir"; exit 1; }
[ -f "$tmp/meta/openwrt-mediatek-filogic-cudy_tr3000-v1.manifest" ] \
  || { echo "FAIL: per-device manifest must reach meta-dir"; exit 1; }
[ "$(find "$tmp/meta" -name '*.manifest' | wc -l | tr -d ' ')" = 2 ] \
  || { echo "FAIL: every per-device manifest must be kept, not just the first"; exit 1; }

# deny list: none of these may appear in the upload dir
for pat in '*buildinfo*' '*profiles.json*' '*.manifest*' \
           '*generic-kernel.bin*' '*rootfs.tar.gz*' '*rootfs.img.gz*'; do
  [ -z "$(find "$tmp/up" -name "$pat")" ] || { echo "FAIL: junk not filtered ($pat)"; exit 1; }
done

# sha256sums: must exist and be regenerated for the final set (not the per-target leftover)
[ -f "$tmp/up/sha256sums" ] || { echo "FAIL: sha256sums not generated"; exit 1; }
grep -q "openwrt-x86-64-generic-squashfs-combined-efi.img.gz" "$tmp/up/sha256sums" \
  || { echo "FAIL: sha256sums must reference original filenames"; exit 1; }
[ -z "$(find "$tmp/up" -name "*sha256sums" ! -name "sha256sums")" ] \
  || { echo "FAIL: stale sha256sums copies must be removed"; exit 1; }

(
  cd "$tmp/up"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c sha256sums
  else
    shasum -a 256 -c sha256sums
  fi
) || { echo "FAIL: sha256sums verification failed"; exit 1; }

# meta-dir is required: forgetting it would silently drop the release notes' input
sh "$sc" "$tmp/owrt" "$tmp/up2" >/dev/null 2>&1 \
  && { echo "FAIL: a missing meta-dir must fail loudly"; exit 1; }

echo "PASS: test-collect-artifacts"
