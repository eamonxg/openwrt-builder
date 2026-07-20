#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/collect-artifacts.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/owrt/bin/targets/x86/64/packages"
echo img > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo img > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-sysupgrade.bin"
echo sum > "$tmp/owrt/bin/targets/x86/64/sha256sums"
echo pkg > "$tmp/owrt/bin/targets/x86/64/packages/foo.apk"
# build byproducts never published (no config option disables them; the deny list filters them)
echo bl2 > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic-bl2.bin"
echo bi > "$tmp/owrt/bin/targets/x86/64/config.buildinfo"
echo pj > "$tmp/owrt/bin/targets/x86/64/profiles.json"
echo mf > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic.manifest"
echo gk > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic-generic-kernel.bin"
echo rt > "$tmp/owrt/bin/targets/x86/64/openwrt-x86-64-generic-rootfs.tar.gz"

sh "$sc" "$tmp/owrt" "$tmp/up"

# artifacts ship under their original OpenWrt filenames, no prefixes added
[ -f "$tmp/up/openwrt-x86-64-generic-squashfs-combined-efi.img.gz" ] \
  || { echo "FAIL: image must keep its original filename"; exit 1; }
[ -f "$tmp/up/openwrt-x86-64-generic-squashfs-sysupgrade.bin" ] \
  || { echo "FAIL: sysupgrade must be kept"; exit 1; }
[ -z "$(find "$tmp/up" -name '*foo.apk*')" ] || { echo "FAIL: packages dir must be excluded"; exit 1; }

# deny list: none of these may appear in the upload dir
for pat in '*bl2.bin*' '*buildinfo*' '*profiles.json*' '*.manifest*' \
           '*generic-kernel.bin*' '*rootfs.tar.gz*'; do
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

echo "PASS: test-collect-artifacts"
