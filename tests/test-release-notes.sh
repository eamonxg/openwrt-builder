#!/bin/sh
set -eu
R="$(dirname "$0")/.."
sc="$R/scripts/release-notes.sh"
tpl="$R/firmware/release.md"
pki="$R/firmware/packages.ini"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
p=openwrt-mediatek-filogic

# --- a multi-device build shaped like tr3000: three profiles of one box, and a
# --- package only the 256 MB variant has room for
mkdir -p "$tmp/meta" "$tmp/up"
cat > "$tmp/meta/profiles.json" <<'EOF'
{"profiles":{
 "cudy_tr3000-v1":{"titles":[{"vendor":"Cudy","model":"TR3000","variant":"v1"}]},
 "cudy_tr3000-256mb-v1":{"titles":[{"vendor":"Cudy","model":"TR3000","variant":"256mb v1"}]},
 "cudy_tr3000-v1-ubootmod":{"titles":[{"vendor":"Cudy","model":"TR3000","variant":"v1 (OpenWrt U-Boot layout)"}]}},
 "target":"mediatek/filogic"}
EOF
printf 'luci-app-passwall2 - 25.7.1\nkernel - 6.12.34\n' > "$tmp/meta/$p-cudy_tr3000-v1.manifest"
printf 'luci-app-passwall2 - 25.7.1\nluci-app-nikki - 1.26.1\nkernel - 6.12.34\n' \
  > "$tmp/meta/$p-cudy_tr3000-256mb-v1.manifest"
printf 'luci-app-passwall2 - 25.7.1\nkernel - 6.12.34\n' > "$tmp/meta/$p-cudy_tr3000-v1-ubootmod.manifest"
for f in cudy_tr3000-v1-initramfs-kernel.bin cudy_tr3000-v1-squashfs-sysupgrade.bin \
         cudy_tr3000-256mb-v1-initramfs-kernel.bin cudy_tr3000-256mb-v1-squashfs-sysupgrade.bin \
         cudy_tr3000-v1-ubootmod-initramfs-recovery.itb cudy_tr3000-v1-ubootmod-squashfs-sysupgrade.itb \
         cudy_tr3000-v1-ubootmod-preloader.bin cudy_tr3000-v1-ubootmod-bl31-uboot.fip; do
  echo x > "$tmp/up/$p-$f"
done
echo sums > "$tmp/up/sha256sums"

# a stand-in package/custom tree: one repo whose Makefiles declare packages
# explicitly, one luci repo declaring none (named after its directory), and a
# multi-package repo — the three shapes the real clones take
mkdir -p "$tmp/custom/passwall2/luci-app-passwall2" \
         "$tmp/custom/passwall-packages/xray-core" \
         "$tmp/custom/passwall-packages/hysteria" \
         "$tmp/custom/nikki"
: > "$tmp/custom/passwall2/luci-app-passwall2/Makefile"          # luci: dir name only
printf 'define Package/xray-core\nendef\n' > "$tmp/custom/passwall-packages/xray-core/Makefile"
printf 'define Package/hysteria\nendef\n'  > "$tmp/custom/passwall-packages/hysteria/Makefile"
printf 'define Package/nikki\nendef\ndefine Package/luci-app-nikki\nendef\n' \
  > "$tmp/custom/nikki/Makefile"
printf '%s\n' '[settings]' 'BUILD_BY = eamonxg' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' > "$tmp/s"

# shellcheck disable=SC1007
out=$(BUILD=tr3000 TARGET=mediatek/filogic DEVICES= SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA=2222222222222222222222222222222222222222 \
  KERNEL=6.12.34 DIGEST=abcdefabcdefabcd DATE=20260720-2102 \
  PKG_REPOS="passwall2@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa nikki@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  PREV_PKG_REPOS="passwall2@cccccccccccccccccccccccccccccccccccccccc nikki@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  sh "$sc" "$tmp/meta" "$tmp/up" "$tmp/s" "$pki" "$tpl" "$tmp/custom")

echo "$out" | grep -q '^## tr3000 · kernel 6.12.34' || { echo "FAIL: title"; exit 1; }
echo "$out" | grep -q 'compare/2222222.*\.\.\.1111111' || { echo "FAIL: upstream compare link"; exit 1; }

# the tag suffix must be spelled out, not left as '-2102'
echo "$out" | grep -q '2026-07-20 21:02 (Asia/Shanghai)' || { echo "FAIL: built_at not humanised"; exit 1; }

# device sections carry the human title from profiles.json
# shellcheck disable=SC2016
echo "$out" | grep -q '^#### Cudy TR3000 v1 · `cudy_tr3000-v1`$' || { echo "FAIL: device heading"; exit 1; }

# every file must be filed under a device; nothing may land in the catch-all
echo "$out" | grep -q 'Unclassified' && { echo "FAIL: every artifact must be claimed by a device"; exit 1; }

# THE prefix trap: cudy_tr3000-v1 is a prefix of cudy_tr3000-v1-ubootmod, so a
# naive match files every ubootmod artifact under the stock profile
v1sec=$(echo "$out" | awk '/^#### Cudy TR3000 v1 · /{f=1;next} /^#### /{f=0} f')
echo "$v1sec" | grep -q 'ubootmod' && { echo "FAIL: ubootmod artifacts leaked into the stock profile"; exit 1; }
[ "$(echo "$v1sec" | grep -c '^| `')" = 2 ] || { echo "FAIL: stock profile must list exactly its own 2 files"; exit 1; }

# purposes come from filename patterns, no per-model knowledge
echo "$out" | grep -q 'initramfs-kernel.bin` | First install' || { echo "FAIL: initramfs purpose"; exit 1; }
echo "$out" | grep -q 'preloader.bin` | Bootloader stage 1' || { echo "FAIL: preloader purpose"; exit 1; }
echo "$out" | grep -q 'bl31-uboot.fip` | ATF' || { echo "FAIL: fip purpose"; exit 1; }
echo "$out" | grep -q 'sysupgrade.itb` | Upgrade' || { echo "FAIL: sysupgrade purpose"; exit 1; }
# the ubootmod initramfs is '...-initramfs-recovery.itb'; the initramfs arm wins
echo "$out" | grep -q 'initramfs-recovery.itb` | First install' || { echo "FAIL: ubootmod initramfs purpose"; exit 1; }
# sha256sums is not firmware and gets no row
# shellcheck disable=SC2016
echo "$out" | grep -q '| `sha256sums` |' && { echo "FAIL: sha256sums must not be listed as an image"; exit 1; }

# the regression this whole redesign exists for: a package only one device has.
# Columns follow the heading order: 256mb-v1, v1, v1-ubootmod
echo "$out" | grep -q '^| Package | Version | cudy_tr3000-256mb-v1 | cudy_tr3000-v1 | cudy_tr3000-v1-ubootmod |$' \
  || { echo "FAIL: one column per device, in heading order"; exit 1; }
echo "$out" | grep -q '^| luci-app-nikki | 1.26.1 | ✓ | — | — |$' \
  || { echo "FAIL: per-device package presence (nikki is 256mb-only)"; exit 1; }
echo "$out" | grep -q '^| luci-app-passwall2 | 25.7.1 | ✓ | ✓ | ✓ |$' \
  || { echo "FAIL: a package on every device must be ticked everywhere"; exit 1; }
# candidates absent from every manifest print no row. Scoped to the package
# table: 'nikki' is also a repo name and legitimately appears in the source list
pkgsec=$(echo "$out" | awk '/^### Bundled packages/{f=1;next} /^<details>/{f=0} f')
echo "$pkgsec" | grep -q 'hysteria' && { echo "FAIL: a package not in any manifest must not show"; exit 1; }
echo "$pkgsec" | grep -q '^| nikki |' && { echo "FAIL: a package not in any manifest must not show"; exit 1; }

# plugin sources: the changed repo links to a compare, the unchanged one says so
echo "$out" | grep -q 'Plugin sources (2 repos, 1 updated)' || { echo "FAIL: plugin repo summary"; exit 1; }
echo "$out" | grep -q 'Openwrt-Passwall/openwrt-passwall2/compare/cccccccc*\.\.\.aaaa' \
  || { echo "FAIL: changed repo must link to a compare"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | grep -q '| nikki | `bbbbbbb` | unchanged |' || { echo "FAIL: unchanged repo"; exit 1; }
echo "$out" | grep -q '<!-- packages: passwall2@aaaa' || { echo "FAIL: packages comment for the next build"; exit 1; }

# no empty table header rows anywhere
echo "$out" | grep -q '^| | |$' && { echo "FAIL: empty table header row"; exit 1; }

# shellcheck disable=SC2016
echo "$out" | grep -q '<!-- builder-digest: `abcdefabcdefabcd` -->' || { echo "FAIL: digest comment"; exit 1; }
echo "$out" | grep -q '<!-- source: openwrt/openwrt@1111111111111111111111111111111111111111 -->' \
  || { echo "FAIL: source comment"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | sed -n 's/.*builder-digest: `\([0-9a-f]\{16\}\)`.*/\1/p' | grep -qx abcdefabcdefabcd \
  || { echo "FAIL: last_digest sed compatibility"; exit 1; }

# --- a single-profile build shaped like x86: no DEVICES, one manifest, and the
# --- per-device columns would be noise
mkdir -p "$tmp/m2" "$tmp/u2"
printf '{"profiles":{"generic":{"titles":[]}},"target":"x86/64"}\n' > "$tmp/m2/profiles.json"
# a version carrying a literal '0' — deciding "do the devices differ?" by
# grepping whole rows would see it and wrongly split the table into columns
printf 'luci-app-passwall2 - 25.7.1\nluci-app-nikki - 1.1.1-r20260712\nkernel - 6.12.34\n' \
  > "$tmp/m2/openwrt-x86-64-generic.manifest"
echo x > "$tmp/u2/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo x > "$tmp/u2/openwrt-x86-64-generic-squashfs-combined.img.gz"
echo x > "$tmp/u2/openwrt-x86-64-generic-image-efi.iso"
printf '%s\n' '[settings]' > "$tmp/bare"
# shellcheck disable=SC1007
out2=$(BUILD=x86 TARGET=x86/64 DEVICES= SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=6.12.34 DIGEST=abcdefabcdefabcd \
  sh "$sc" "$tmp/m2" "$tmp/u2" "$tmp/bare" "$pki" "$tpl" "$tmp/custom")

echo "$out2" | grep -q '^| Package | Version |$' || { echo "FAIL: one uniform device set means no extra columns"; exit 1; }
echo "$out2" | grep -q '^| Package | Version | generic |$' \
  && { echo "FAIL: a '0' inside a version must not be read as a per-device flag"; exit 1; }
echo "$out2" | grep -q '| luci-app-nikki | 1.1.1-r20260712 |' || { echo "FAIL: package row in the 2-column form"; exit 1; }
# a single nameless profile needs no heading of its own
# shellcheck disable=SC2016
echo "$out2" | grep -q '^#### `generic`$' && { echo "FAIL: a lone nameless profile must not get a heading"; exit 1; }
echo "$out2" | grep -q 'combined-efi.img.gz` | UEFI whole-disk image' || { echo "FAIL: x86 EFI purpose"; exit 1; }
echo "$out2" | grep -q 'combined.img.gz` | Legacy BIOS whole-disk image' || { echo "FAIL: x86 BIOS purpose"; exit 1; }
echo "$out2" | grep -q 'image-efi.iso` | UEFI bootable install media' || { echo "FAIL: iso purpose"; exit 1; }
echo "$out2" | grep -q 'Unclassified' && { echo "FAIL: the generic profile must claim its own files"; exit 1; }

# the "line with an empty placeholder is dropped" rule still governs the scalars
echo "$out2" | grep -q 'Upstream changes' && { echo "FAIL: no PREV_SHA must drop the changes line"; exit 1; }
echo "$out2" | grep -q '\*\*Built\*\*' && { echo "FAIL: no DATE must drop the built_at line"; exit 1; }
echo "$out2" | grep -q 'Built by' && { echo "FAIL: no BUILD_BY must drop the builder line"; exit 1; }
echo "$out2" | grep -q 'Default Wi-Fi' && { echo "FAIL: no SSID must drop the Wi-Fi line"; exit 1; }
# a block with nothing to say must not leave its heading behind
echo "$out2" | grep -q 'Plugin sources' && { echo "FAIL: no PKG_REPOS must drop the whole plugin-source block"; exit 1; }
# a line without placeholders keeps its place even when its neighbours are dropped
echo "$out2" | grep -q 'Default theme: shadcn' || { echo "FAIL: lines without placeholders must survive"; exit 1; }

# --- degradation: no profiles.json at all, device ids fall back to $DEVICES.
# --- Multi-device on purpose: that is where the fallback has to carry its weight
mkdir -p "$tmp/m3"
cp "$tmp/meta/$p-cudy_tr3000-v1.manifest" "$tmp/meta/$p-cudy_tr3000-256mb-v1.manifest" \
   "$tmp/meta/$p-cudy_tr3000-v1-ubootmod.manifest" "$tmp/m3/"
# shellcheck disable=SC1007
out3=$(BUILD=tr3000 TARGET=mediatek/filogic \
  DEVICES="cudy_tr3000-v1 cudy_tr3000-256mb-v1 cudy_tr3000-v1-ubootmod" SOURCE_REPO=o/o SOURCE_REF=m \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" "$tmp/m3" "$tmp/up" "$tmp/bare" "$pki" "$tpl" "$tmp/custom") \
  || { echo "FAIL: a missing profiles.json must not abort"; exit 1; }
# headings fall back to the machine name, with no title to dress them up
# shellcheck disable=SC2016
echo "$out3" | grep -q '^#### `cudy_tr3000-v1`$' || { echo "FAIL: fall back to the machine name from DEVICES"; exit 1; }
echo "$out3" | grep -q 'Unclassified' && { echo "FAIL: the fallback ids must still claim every file"; exit 1; }
# and the longest-match rule must survive the fallback path too
v1s3=$(echo "$out3" | awk '/^#### `cudy_tr3000-v1`$/{f=1;next} /^#### /{f=0} f')
echo "$v1s3" | grep -q 'ubootmod' && { echo "FAIL: prefix trap must be handled without profiles.json"; exit 1; }
echo "$out3" | grep -q '^| luci-app-nikki | 1.26.1 | ✓ | — | — |$' \
  || { echo "FAIL: per-device columns must work without profiles.json"; exit 1; }

# a typoed placeholder must fail loudly rather than silently blanking a line
printf '%s\n' 'kernel {{kernal}}' > "$tmp/typo.md"
# shellcheck disable=SC1007
( BUILD=x TARGET=x/y DEVICES= SOURCE_REPO=o/o SOURCE_REF=m SOURCE_SHA=1 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" "$tmp/m2" "$tmp/u2" "$tmp/bare" "$pki" "$tmp/typo.md" >/dev/null 2>&1 ) \
  && { echo "FAIL: unknown placeholder must fail"; exit 1; }
# a missing template must fail too
# shellcheck disable=SC1007
( BUILD=x TARGET=x/y DEVICES= SOURCE_REPO=o/o SOURCE_REF=m SOURCE_SHA=1 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" "$tmp/m2" "$tmp/u2" "$tmp/bare" "$pki" "$tmp/nonexistent.md" >/dev/null 2>&1 ) \
  && { echo "FAIL: missing template must fail"; exit 1; }

echo "PASS: test-release-notes"
