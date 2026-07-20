#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/release-notes.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/m" <<'EOF'
luci-app-passwall2 - 25.7.1
xray-core - 1.8.24
chinadns-ng - 2024.1
luci-app-nikki - 1.2.3
mihomo-meta - 1.19.0
luci-theme-shadcn - 2.0.0
kernel - 6.12.34
EOF
printf '%s\n' '[settings]' 'BUILD_BY = eamonxg' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' > "$tmp/s"

# a stand-in package/custom tree: one repo whose Makefiles declare packages
# explicitly, one luci repo declaring none (named after its directory), and a
# multi-package repo — the three shapes the real clones take
mkdir -p "$tmp/custom/passwall2/luci-app-passwall2" \
         "$tmp/custom/passwall-packages/xray-core" \
         "$tmp/custom/passwall-packages/chinadns-ng" \
         "$tmp/custom/passwall-packages/hysteria" \
         "$tmp/custom/nikki" \
         "$tmp/custom/luci-theme-shadcn"
: > "$tmp/custom/passwall2/luci-app-passwall2/Makefile"          # luci: dir name only
printf 'define Package/xray-core\nendef\n'   > "$tmp/custom/passwall-packages/xray-core/Makefile"
printf 'define Package/chinadns-ng\nendef\n' > "$tmp/custom/passwall-packages/chinadns-ng/Makefile"
printf 'define Package/hysteria\nendef\n'    > "$tmp/custom/passwall-packages/hysteria/Makefile"
printf 'define Package/nikki\nendef\ndefine Package/luci-app-nikki\nendef\ndefine Package/mihomo-meta\nendef\n' \
  > "$tmp/custom/nikki/Makefile"
: > "$tmp/custom/luci-theme-shadcn/Makefile"

tpl="$(dirname "$0")/../firmware/release.md"
out=$(BUILD=jdcloud TARGET=qualcommax/ipq60xx \
  DEVICES="jdcloud_re-cs-02 jdcloud_re-ss-01" SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA=2222222222222222222222222222222222222222 \
  KERNEL=6.12.34 DIGEST=abcdefabcdefabcd sh "$sc" "$tmp/m" "$tmp/s" "$tpl" "$tmp/custom")

echo "$out" | grep -q '^## jdcloud · kernel 6.12.34' || { echo "FAIL: title"; exit 1; }
echo "$out" | grep -q 'compare/2222222.*\.\.\.1111111' || { echo "FAIL: compare link"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | grep -q '`jdcloud_re-cs-02` `jdcloud_re-ss-01`' || { echo "FAIL: devices row"; exit 1; }

# packages are discovered from the cloned repos; no list is maintained anywhere
echo "$out" | grep -q '| luci-app-passwall2 | 25.7.1 |' || { echo "FAIL: luci package named after its directory"; exit 1; }
echo "$out" | grep -q '| xray-core | 1.8.24 |' || { echo "FAIL: 'define Package/' declaration"; exit 1; }
echo "$out" | grep -q '| chinadns-ng | 2024.1 |' || { echo "FAIL: a dependency the core pulled in must be listed too"; exit 1; }
echo "$out" | grep -q '| mihomo-meta | 1.19.0 |' || { echo "FAIL: the mihomo variant that exists"; exit 1; }
echo "$out" | grep -q '| luci-theme-shadcn | 2.0.0 |' || { echo "FAIL: single-package repo at its root"; exit 1; }
# declared by a repo but absent from this firmware -> no row
echo "$out" | grep -q '| hysteria |' && { echo "FAIL: a package not in the manifest must not show"; exit 1; }
echo "$out" | grep -q '| nikki |' && { echo "FAIL: a package not in the manifest must not show"; exit 1; }
# repo dir and 'define Package/' can name the same package; it must appear once
[ "$(echo "$out" | grep -c '| xray-core |')" = 1 ] || { echo "FAIL: rows must be deduplicated"; exit 1; }

# the "line with an empty placeholder is dropped" rule
echo "$out" | grep -q 'Default Wi-Fi.*Rilakkuma.*sae-mixed' || { echo "FAIL: unset WIFI_ENCRYPTION must default to sae-mixed"; exit 1; }
echo "$out" | grep -q 'Build tag: by eamonxg' || { echo "FAIL: build tag"; exit 1; }
echo "$out" | grep -q 'generic image' && { echo "FAIL: a build with devices must drop the generic-image line"; exit 1; }

# shellcheck disable=SC2016
echo "$out" | grep -q '<!-- builder-digest: `abcdefabcdefabcd` -->' || { echo "FAIL: digest comment"; exit 1; }
echo "$out" | grep -q '<!-- source: openwrt/openwrt@1111111111111111111111111111111111111111 -->' || { echo "FAIL: source comment"; exit 1; }
# shellcheck disable=SC2016
echo "$out" | sed -n 's/.*builder-digest: `\([0-9a-f]\{16\}\)`.*/\1/p' | grep -qx abcdefabcdefabcd || { echo "FAIL: last_digest sed compatibility"; exit 1; }

# generic image, no previous release, no Wi-Fi, no build tag: every optional line goes
printf '%s\n' '[settings]' > "$tmp/bare"
# shellcheck disable=SC1007
out2=$(BUILD=x86 TARGET=x86/64 DEVICES= SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=6.12.34 DIGEST=abcdefabcdefabcd \
  sh "$sc" /dev/null "$tmp/bare" "$tpl")
echo "$out2" | grep -q 'generic image' || { echo "FAIL: no devices means the generic-image line stays"; exit 1; }
echo "$out2" | grep -q 'Devices' && { echo "FAIL: no devices must drop the devices row"; exit 1; }
echo "$out2" | grep -q 'Changes' && { echo "FAIL: no PREV_SHA must drop the changes row"; exit 1; }
echo "$out2" | grep -q 'Default Wi-Fi' && { echo "FAIL: no SSID must drop the Wi-Fi line"; exit 1; }
echo "$out2" | grep -q 'Build tag' && { echo "FAIL: no BUILD_BY must drop the build tag line"; exit 1; }
# a line without placeholders keeps its place even when its neighbours are dropped
echo "$out2" | grep -q 'Default theme: shadcn' || { echo "FAIL: lines without placeholders must survive"; exit 1; }

# the LAST discovered candidate missing from the manifest must not abort the run:
# its failed test would otherwise become the package loop's exit status
mkdir -p "$tmp/last/zzz-absent"
printf 'define Package/zzz-absent\nendef\n' > "$tmp/last/zzz-absent/Makefile"
mkdir -p "$tmp/last/aaa-present"
printf 'define Package/luci-app-passwall2\nendef\n' > "$tmp/last/aaa-present/Makefile"
# shellcheck disable=SC1007
out3=$(BUILD=x86 TARGET=x86/64 DEVICES= SOURCE_REPO=o/o SOURCE_REF=m \
  SOURCE_SHA=1111111111111111111111111111111111111111 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" "$tmp/m" "$tmp/bare" "$tpl" "$tmp/last") \
  || { echo "FAIL: a trailing candidate absent from the manifest must not abort"; exit 1; }
echo "$out3" | grep -q '| luci-app-passwall2 | 25.7.1 |' || { echo "FAIL: rows before the absent one must still print"; exit 1; }
echo "$out3" | grep -q 'zzz-absent' && { echo "FAIL: absent candidate must not print"; exit 1; }

# a typoed placeholder must fail loudly rather than silently blanking a line
printf '%s\n' 'kernel {{kernal}}' > "$tmp/typo.md"
# shellcheck disable=SC1007
( BUILD=x TARGET=x/y DEVICES= SOURCE_REPO=o/o SOURCE_REF=m SOURCE_SHA=1 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" /dev/null "$tmp/bare" "$tmp/typo.md" >/dev/null 2>&1 ) && { echo "FAIL: unknown placeholder must fail"; exit 1; }
# a missing template must fail too
# shellcheck disable=SC1007
( BUILD=x TARGET=x/y DEVICES= SOURCE_REPO=o/o SOURCE_REF=m SOURCE_SHA=1 PREV_SHA= KERNEL=k DIGEST=d \
  sh "$sc" /dev/null "$tmp/bare" "$tmp/nonexistent.md" >/dev/null 2>&1 ) && { echo "FAIL: missing template must fail"; exit 1; }
echo "PASS: test-release-notes"
