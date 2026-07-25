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
  UPSTREAM_LOG="kernel: bump to 6.12.35
mediatek: add support for a board" UPSTREAM_TOTAL=2 \
  sh "$sc" "$tmp/meta" "$tmp/up" "$tmp/s" "$pki" "$tpl" "$tmp/custom")

# fetching lives in publish-release.sh; this script only renders what it is
# handed, which is what keeps it testable without a network
echo "$out" | grep -q 'Upstream changes · 2 commits' || { echo "FAIL: upstream commit count"; exit 1; }
echo "$out" | grep -qx -- '- kernel: bump to 6.12.35' || { echo "FAIL: upstream subjects inlined"; exit 1; }
echo "$out" | grep -q 'compare/2222222.*\.\.\.1111111' || { echo "FAIL: upstream compare link"; exit 1; }

# the build name and kernel belong to the release title and the metadata list;
# the body must not open with a heading repeating them
echo "$out" | grep -q '^## tr3000' && { echo "FAIL: the duplicated H2 heading must be gone"; exit 1; }
echo "$out" | grep -q '\*\*Built\*\*' && { echo "FAIL: the build timestamp line must be gone"; exit 1; }
echo "$out" | grep -q 'Built by' && { echo "FAIL: the builder line must be gone"; exit 1; }

# --- the images table is transposed: one row per use, one column per device.
# --- use_of() keys off the filename suffix, so printing the description under
# --- every device repeated it verbatim N times; as a row label it is stated once
echo "$out" | grep -q '^| Use | Cudy TR3000 256mb v1 | Cudy TR3000 v1 | Cudy TR3000 v1 (OpenWrt U-Boot layout) |$' \
  || { echo "FAIL: one column per device, titled from profiles.json, in heading order"; exit 1; }
[ "$(echo "$out" | grep -c 'tftp-boot it from U-Boot')" = 1 ] \
  || { echo "FAIL: a use description must appear exactly once, not once per device"; exit 1; }

# THE prefix trap: cudy_tr3000-v1 is a prefix of cudy_tr3000-v1-ubootmod, so a
# naive match files every ubootmod artifact under the stock profile. Transposed,
# that shows up as an ubootmod filename in the middle (stock v1) column.
firstrow=$(echo "$out" | grep '^| \*\*First install\*\*')
[ "$(echo "$firstrow" | awk -F'|' '{print $4}' | grep -c ubootmod)" = 0 ] \
  || { echo "FAIL: ubootmod artifacts leaked into the stock profile column"; exit 1; }
echo "$firstrow" | grep -q 'cudy_tr3000-v1-ubootmod-initramfs-recovery.itb' \
  || { echo "FAIL: the ubootmod initramfs belongs in the ubootmod column"; exit 1; }

# BL2 and FIP exist only for the ubootmod layout: the empty cells say so, which
# three separate per-device tables could not
# shellcheck disable=SC2016
echo "$out" | grep -q '^| \*\*BL2\*\*.*| — | — | `cudy_tr3000-v1-ubootmod-preloader.bin` |$' \
  || { echo "FAIL: BL2 must be empty for the two stock profiles"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | grep -q '^| \*\*FIP\*\*.*| — | — | `cudy_tr3000-v1-ubootmod-bl31-uboot.fip` |$' \
  || { echo "FAIL: FIP must be empty for the two stock profiles"; exit 1; }

# the shared prefix is derived from TARGET, not guessed, and stated once
# shellcheck disable=SC2016
echo "$out" | grep -q 'All filenames start with `openwrt-mediatek-filogic-`' \
  || { echo "FAIL: the common prefix must be stripped and stated once"; exit 1; }
echo "$out" | grep -q '`openwrt-mediatek-filogic-cudy' && { echo "FAIL: the prefix must not survive in a cell"; exit 1; }

# every file must be filed under a device; nothing may land in the catch-all
echo "$out" | grep -q 'not claimed by any device' && { echo "FAIL: every artifact must be claimed by a device"; exit 1; }
# sha256sums is not firmware and gets no row
# shellcheck disable=SC2016
echo "$out" | grep -q '`sha256sums`' && { echo "FAIL: sha256sums must not be listed as an image"; exit 1; }

# the regression this whole redesign exists for: a package only one device has.
# Columns follow the heading order: 256mb-v1, v1, v1-ubootmod
echo "$out" | grep -q '^| Package | Version | Source | cudy_tr3000-256mb-v1 | cudy_tr3000-v1 | cudy_tr3000-v1-ubootmod |$' \
  || { echo "FAIL: one column per device, in heading order, after Source"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | grep -q '^| luci-app-nikki | 1.26.1 | nikki `bbbbbbb` | ✓ | — | — |$' \
  || { echo "FAIL: per-device package presence (nikki is 256mb-only)"; exit 1; }
# the Source column answers "where did this come from" in the same row, and
# flags a repo whose SHA moved since the previous build
# shellcheck disable=SC2016
echo "$out" | grep -q '^| luci-app-passwall2 | 25.7.1 | passwall2 `aaaaaaa` ↑ | ✓ | ✓ | ✓ |$' \
  || { echo "FAIL: a package on every device must be ticked everywhere, with its source"; exit 1; }
# an unchanged repo carries no arrow
# shellcheck disable=SC2016
echo "$out" | grep -q 'nikki `bbbbbbb` ↑' && { echo "FAIL: an unchanged repo must not be flagged as moved"; exit 1; }
# candidates absent from every manifest print no row. Scoped to the package
# table: 'nikki' is also a repo name and legitimately appears in the Source column
pkgsec=$(echo "$out" | awk '/^### Packages/{f=1;next} /^<details>/{f=0} f')
echo "$pkgsec" | grep -q 'hysteria' && { echo "FAIL: a package not in any manifest must not show"; exit 1; }
echo "$pkgsec" | grep -q '^| nikki |' && { echo "FAIL: a package not in any manifest must not show"; exit 1; }

echo "$out" | grep -q '<!-- packages: passwall2@aaaa' || { echo "FAIL: packages comment for the next build"; exit 1; }

# without PLUGIN_LOG there is nothing to say about plugin commits, and the block
# must not render an empty shell
echo "$out" | grep -q 'Plugin changes' && { echo "FAIL: no PLUGIN_LOG must drop the plugin block"; exit 1; }

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
echo x > "$tmp/u2/openwrt-x86-64-generic-ext4-combined-efi.img.gz"
echo x > "$tmp/u2/openwrt-x86-64-generic-image-efi.iso"
printf '%s\n' '[settings]' > "$tmp/bare"
# shellcheck disable=SC1007
out2=$(BUILD=x86 TARGET=x86/64 DEVICES= SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=6.12.34 DIGEST=abcdefabcdefabcd \
  sh "$sc" "$tmp/m2" "$tmp/u2" "$tmp/bare" "$pki" "$tpl" "$tmp/custom")

echo "$out2" | grep -q '^| Package | Version | Source |$' || { echo "FAIL: one uniform device set means no extra columns"; exit 1; }
echo "$out2" | grep -q '^| Package | Version | Source | generic |$' \
  && { echo "FAIL: a '0' inside a version must not be read as a per-device flag"; exit 1; }
echo "$out2" | grep -q '| luci-app-nikki | 1.1.1-r20260712 | nikki |' || { echo "FAIL: package row in the 3-column form"; exit 1; }
# with no PKG_REPOS there is no SHA to print, but the repo name still answers
# "where did this come from"
echo "$out2" | grep -q '| luci-app-nikki | 1.1.1-r20260712 | nikki  |' \
  && { echo "FAIL: a missing SHA must not leave a double space"; exit 1; }
# a lone profile needs no column of its own — there is nothing to tell apart
echo "$out2" | grep -q '^| Use | File |$' || { echo "FAIL: a single profile takes a plain File column"; exit 1; }
echo "$out2" | grep -q '^| Use | generic |$' && { echo "FAIL: a lone profile must not get its own column"; exit 1; }

# THE x86 defect this redesign fixes: ext4 and squashfs images used to carry the
# byte-identical description, hiding the one difference a reader is choosing on
echo "$out2" | grep -q 'UEFI whole-disk, ext4.*writable, resizable' || { echo "FAIL: ext4 must state it is writable"; exit 1; }
echo "$out2" | grep -q 'UEFI whole-disk, squashfs.*read-only rootfs plus overlay' \
  || { echo "FAIL: squashfs must state it is read-only with an overlay"; exit 1; }
echo "$out2" | grep -q 'BIOS whole-disk, squashfs' || { echo "FAIL: x86 BIOS purpose"; exit 1; }
echo "$out2" | grep -q 'UEFI install media' || { echo "FAIL: iso purpose"; exit 1; }
echo "$out2" | grep -q 'not claimed by any device' && { echo "FAIL: the generic profile must claim its own files"; exit 1; }

# the "line with an empty placeholder is dropped" rule still governs the scalars
echo "$out2" | grep -q 'Upstream changes' && { echo "FAIL: no UPSTREAM_LOG must drop the whole block"; exit 1; }
echo "$out2" | grep -q 'Wi-Fi `' && { echo "FAIL: no SSID must drop the Wi-Fi line"; exit 1; }
echo "$out2" | grep -q 'Separate 5 GHz' && { echo "FAIL: no 5G SSID must drop that line"; exit 1; }
# a block with nothing to say must not leave its heading behind
echo "$out2" | grep -q 'Plugin changes' && { echo "FAIL: no PLUGIN_LOG must drop the whole block"; exit 1; }
# a line without placeholders keeps its place even when its neighbours are dropped
echo "$out2" | grep -q 'Theme shadcn' || { echo "FAIL: lines without placeholders must survive"; exit 1; }
# an unset LAN_IP is not unknown: it is OpenWrt's own default, and the address is
# the first thing a freshly flashed box needs
# shellcheck disable=SC2016
echo "$out2" | grep -q 'LAN address `192.168.1.1`' || { echo "FAIL: unset LAN_IP must fall back to the OpenWrt default"; exit 1; }

# --- artifacts no device claims: the mediatek DDR blobs ride along in the upload
# --- dir but belong to no profile. They used to fill a table whose Purpose column
# --- was blank on every row; now they get one sentence — with every name spelled
# --- out, because "only the one matching this board applies" cannot be acted on
# --- from a count and a single sample name
mkdir -p "$tmp/u4"
cp "$tmp/up/$p-cudy_tr3000-v1-initramfs-kernel.bin" "$tmp/u4/"
echo x > "$tmp/u4/mt7981-ram-ddr3-bl2.bin"
echo x > "$tmp/u4/mt7988-ram-comb-bl2.bin"
# shellcheck disable=SC1007
out4=$(BUILD=tr3000 TARGET=mediatek/filogic DEVICES= SOURCE_REPO=o/o SOURCE_REF=m \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" "$tmp/meta" "$tmp/u4" "$tmp/bare" "$pki" "$tpl" "$tmp/custom")
# shellcheck disable=SC2016
echo "$out4" | grep -q 'Plus `mt7981-ram-ddr3-bl2.bin`, `mt7988-ram-comb-bl2.bin` — MediaTek RAM training blob' \
  || { echo "FAIL: unclaimed files must be named in full, with what they are"; exit 1; }
echo "$out4" | grep -q '^| \*\*DDR blob\*\*' && { echo "FAIL: unclaimed files must not become a table row"; exit 1; }
# only one of the three profiles has a file here, so the other two get no column
# at all — scoped to the images block, since the packages table legitimately uses
# em dashes for per-device presence
img4=$(echo "$out4" | awk '/^### Images/{f=1;next} /^### /{f=0} f')
echo "$img4" | grep -q -- '| — |' && { echo "FAIL: a lone claimed device must not get empty sibling columns"; exit 1; }
echo "$img4" | grep -q '^| Use | File |$' || { echo "FAIL: one claimed device takes the plain File column"; exit 1; }

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
# columns fall back to the machine name, with no title to dress them up
echo "$out3" | grep -q '^| Use | cudy_tr3000-256mb-v1 | cudy_tr3000-v1 | cudy_tr3000-v1-ubootmod |$' \
  || { echo "FAIL: fall back to the machine name from DEVICES"; exit 1; }
echo "$out3" | grep -q 'not claimed by any device' && { echo "FAIL: the fallback ids must still claim every file"; exit 1; }
# and the longest-match rule must survive the fallback path too: the stock v1
# column (field 4) must hold no ubootmod artifact
row3=$(echo "$out3" | grep '^| \*\*First install\*\*')
[ "$(echo "$row3" | awk -F'|' '{print $4}' | grep -c ubootmod)" = 0 ] \
  || { echo "FAIL: prefix trap must be handled without profiles.json"; exit 1; }
# shellcheck disable=SC2016
echo "$out3" | grep -q '^| luci-app-nikki | 1.26.1 | nikki | ✓ | — | — |$' \
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

# ---- how settings scopes surface on the release page ----
# A key whose value differs between devices cannot be stated as one string, so
# it resolves to empty and the template drops the whole line -- the one
# conditional the template already has. Printing a value that is wrong for half
# the devices would be worse than printing none.
printf '%s\n' 'ssid={{wifi_ssid}}' 'lan={{lan_ip}}' > "$tmp/t-scope.md"
notes() { # $1 settings.ini  $2 BUILD  $3 DEVICES  $4 template
  BUILD=$2 TARGET=x/y DEVICES=$3 SOURCE_REPO=o/r SOURCE_REF=main \
    SOURCE_SHA=1111111111111111111111111111111111111111 KERNEL=1.2.3 \
    sh "$sc" "$tmp/meta" "$tmp/up" "$1" "$pki" "$4"
}

# devices agree -> render as usual
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' \
  '' '[jd]' 'WIFI_SSID = Rilakkuma_Shared' > "$tmp/agree.ini"
out=$(notes "$tmp/agree.ini" jd 'jdcloud_re-cs-02 jdcloud_re-ss-01' "$tmp/t-scope.md")
echo "$out" | grep -qx 'ssid=Rilakkuma_Shared' || { echo "FAIL: agreeing devices must render the value (got: $out)"; exit 1; }
# an unset LAN_IP resolves to OpenWrt's own default rather than dropping the
# line: the address is what a freshly flashed box is reached at, and silence
# there is the one thing a reader cannot act on
echo "$out" | grep -qx 'lan=192.168.1.1' || { echo "FAIL: unset LAN_IP must fall back to the default (got: $out)"; exit 1; }

# devices disagree -> both lines drop
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' \
  '' '[jdcloud_re-cs-02]' 'WIFI_SSID = A' 'LAN_IP = 192.168.8.1' \
  '' '[jdcloud_re-ss-01]' 'WIFI_SSID = B' 'LAN_IP = 192.168.6.1' > "$tmp/disagree.ini"
out=$(notes "$tmp/disagree.ini" jd 'jdcloud_re-cs-02 jdcloud_re-ss-01' "$tmp/t-scope.md")
echo "$out" | grep -q '^ssid=' && { echo "FAIL: devices disagree, the SSID line must drop (got: $out)"; exit 1; }
echo "$out" | grep -q '^lan=' && { echo "FAIL: devices disagree, the LAN line must drop (got: $out)"; exit 1; }

# a build with no devices (x86 and the like) takes the build-level value
out=$(notes "$tmp/disagree.ini" x86 '' "$tmp/t-scope.md")
echo "$out" | grep -qx 'ssid=Rilakkuma' || { echo "FAIL: a build with no devices takes the build-level value (got: $out)"; exit 1; }

# {{lan_ip}} renders when the devices agree
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' 'LAN_IP = 10.0.0.1' > "$tmp/lan.ini"
out=$(notes "$tmp/lan.ini" b 'd_one d_two' "$tmp/t-scope.md")
echo "$out" | grep -qx 'lan=10.0.0.1' || { echo "FAIL: agreeing LAN_IP must render (got: $out)"; exit 1; }

# devices that all set the same value explicitly agree just as much as devices
# that all inherit it: the comparison is between devices, not against a
# build-level baseline they may all deviate from
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' \
  '' '[d_one]' 'LAN_IP = 192.168.7.1' '' '[d_two]' 'LAN_IP = 192.168.7.1' > "$tmp/samedev.ini"
out=$(notes "$tmp/samedev.ini" b 'd_one d_two' "$tmp/t-scope.md")
echo "$out" | grep -qx 'lan=192.168.7.1' || { echo "FAIL: devices agreeing on a value the build scope lacks must render (got: $out)"; exit 1; }

# a single-device build: one device's value is unambiguous by construction
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' '' '[d_one]' 'LAN_IP = 192.168.7.1' > "$tmp/onedev.ini"
out=$(notes "$tmp/onedev.ini" b 'd_one' "$tmp/t-scope.md")
echo "$out" | grep -qx 'lan=192.168.7.1' || { echo "FAIL: a single device's value must render (got: $out)"; exit 1; }

# the sae-mixed default must not paper over a disagreement: it is applied per
# device before the comparison
printf '%s\n' 'enc={{wifi_encryption}}' > "$tmp/t-enc.md"
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' \
  '' '[d_one]' 'WIFI_ENCRYPTION = psk2' > "$tmp/enc.ini"
out=$(notes "$tmp/enc.ini" b 'd_one d_two' "$tmp/t-enc.md")
echo "$out" | grep -q '^enc=' && { echo "FAIL: one device on psk2, the encryption line must drop (got: $out)"; exit 1; }
out=$(notes "$tmp/lan.ini" b 'd_one d_two' "$tmp/t-enc.md")
echo "$out" | grep -qx 'enc=sae-mixed' || { echo "FAIL: unset encryption must still default to sae-mixed (got: $out)"; exit 1; }

echo "PASS: test-release-notes"
