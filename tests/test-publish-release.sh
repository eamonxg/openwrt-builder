#!/bin/bash
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/upload"
echo fw > "$tmp/upload/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo sums > "$tmp/upload/sha256sums"
printf '%s\n' 'luci-app-passwall2 - 25.7.1' > "$tmp/m"
printf '%s\n' '[settings]' 'BUILD_BY = t' > "$tmp/s"
# release notes template + a stand-in package/custom tree for package discovery
printf '%s\n' '| **Changes** | {{changes}} |' '{{packages}}' > "$tmp/tpl.md"
mkdir -p "$tmp/custom/passwall2/luci-app-passwall2"
: > "$tmp/custom/passwall2/luci-app-passwall2/Makefile"

# fake gh: list has a prefixing decoy (x86-old, newer, different source); view
# serves each body; create records all its arguments
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "release list" ]; then
  json='[{"tagName":"x86-old-20260601-0000"},{"tagName":"x86-20260501-0000"}]'
  expr=""; prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  echo "$json" | jq -r "$expr"
elif [ "$1 $2" = "release view" ]; then
  case "$3" in
    x86-20260501-0000)     echo '<!-- source: openwrt/openwrt@2222222222222222222222222222222222222222 -->' ;;
    x86-old-20260601-0000) echo '<!-- source: openwrt/openwrt@9999999999999999999999999999999999999999 -->' ;;
  esac
elif [ "$1 $2" = "release create" ]; then
  shift 2
  printf '%s\n' "$@" > "$GH_CREATED"
fi
FAKE
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" GH_CREATED="$tmp/created"
export REPO=me/ci BUILD=x86 DATE=20260720-0300 KERNEL=6.12.34 TARGET=x86/64 DEVICES='' \
  SOURCE_REPO=openwrt/openwrt SOURCE_REF=main \
  SOURCE_SHA=1111111111111111111111111111111111111111 DIGEST=abcd1234abcd1234
bash "$here/../scripts/publish-release.sh" "$tmp/m" "$tmp/s" "$tmp/tpl.md" "$tmp/upload" "$tmp/custom"

grep -qx 'x86-20260720-0300' "$tmp/created" || { echo "FAIL: tag"; exit 1; }
grep -q 'x86 · kernel 6.12.34 · 20260720-0300' "$tmp/created" || { echo "FAIL: title"; exit 1; }
grep -q 'combined-efi.img.gz' "$tmp/created" || { echo "FAIL: firmware asset missing"; exit 1; }
grep -q 'sha256sums' "$tmp/created" || { echo "FAIL: sha256sums asset missing"; exit 1; }
# PREV_SHA must come from the exact-match x86-* release (2222...), not the newer decoy x86-old (9999...)
notes=$(grep -A1 -- '--notes-file' "$tmp/created" | tail -n 1)
grep -q 'compare/2222222.*\.\.\.1111111' "$notes" || { echo "FAIL: PREV_SHA must come from the exact-match previous release"; exit 1; }
grep -q '| luci-app-passwall2 | 25.7.1 |' "$notes" || { echo "FAIL: notes must contain the packages table"; exit 1; }

# missing upload dir must fail
( REPO=me/ci BUILD=x86 DATE=20260720-0300 SOURCE_REPO=o/o \
  bash "$here/../scripts/publish-release.sh" "$tmp/m" "$tmp/s" "$tmp/tpl.md" "$tmp/nonexistent" >/dev/null 2>&1 ) \
  && { echo "FAIL: missing upload dir must fail"; exit 1; }
echo "PASS: test-publish-release"
