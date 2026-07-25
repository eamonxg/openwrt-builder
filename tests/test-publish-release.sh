#!/bin/bash
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/upload" "$tmp/meta"
echo fw > "$tmp/upload/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo sums > "$tmp/upload/sha256sums"
printf '{"profiles":{"generic":{"titles":[]}},"target":"x86/64"}\n' > "$tmp/meta/profiles.json"
printf '%s\n' 'luci-app-passwall2 - 25.7.1' > "$tmp/meta/openwrt-x86-64-generic.manifest"
printf '%s\n' '[settings]' 'BUILD_BY = t' > "$tmp/s"
printf '%s\n' '[passwall2]' 'repo = https://github.com/Openwrt-Passwall/openwrt-passwall2.git' > "$tmp/p.ini"
# release notes template + a stand-in package/custom tree for package discovery
printf '%s\n' '{{upstream}}' '{{packages}}' '{{plugin_changes}}' > "$tmp/tpl.md"
mkdir -p "$tmp/custom/passwall2/luci-app-passwall2"
: > "$tmp/custom/passwall2/luci-app-passwall2/Makefile"

# fake gh: list has a prefixing decoy (x86-old, newer, different source); view
# serves each body; api answers compare with two commits; create records all its
# arguments
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
jq_expr() { local prev="" a; for a in "$@"; do [ "$prev" = "--jq" ] && { echo "$a"; return; }; prev=$a; done; }
if [ "$1 $2" = "release list" ]; then
  json='[{"tagName":"x86-old-20260601-0000"},{"tagName":"x86-20260501-0000"}]'
  echo "$json" | jq -r "$(jq_expr "$@")"
elif [ "$1 $2" = "release view" ]; then
  case "$3" in
    x86-20260501-0000)     printf '%s\n%s\n' \
      '<!-- source: openwrt/openwrt@2222222222222222222222222222222222222222 -->' \
      '<!-- packages: passwall2@cccccccccccccccccccccccccccccccccccccccc -->' ;;
    x86-old-20260601-0000) echo '<!-- source: openwrt/openwrt@9999999999999999999999999999999999999999 -->' ;;
  esac
elif [ "$1" = "api" ]; then
  case "$2" in
    */compare/*)
      json='{"total_commits":2,"commits":[
        {"commit":{"message":"kernel: bump to 6.12.35\n\nlong body here"}},
        {"commit":{"message":"mediatek: fix the thing"}}]}'
      expr=$(jq_expr "$@")
      if [ -n "$expr" ]; then echo "$json" | jq -r "$expr"; else echo "$json"; fi ;;
    *) exit 1 ;;
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
  SOURCE_SHA=1111111111111111111111111111111111111111 DIGEST=abcd1234abcd1234 \
  PKG_REPOS=passwall2@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$here/../scripts/publish-release.sh" "$tmp/meta" "$tmp/upload" "$tmp/s" "$tmp/p.ini" "$tmp/tpl.md" "$tmp/custom"

grep -qx 'x86-20260720-0300' "$tmp/created" || { echo "FAIL: tag"; exit 1; }
# The tag keeps the compact stamp; the title spells out the date. It must stay
# short enough to survive the release sidebar, so no kernel version in it.
grep -qx 'x86 07-20 03:00' "$tmp/created" || { echo "FAIL: title"; exit 1; }
grep -q 'kernel' "$tmp/created" && { echo "FAIL: the kernel version must not be in the title"; exit 1; }
grep -q 'combined-efi.img.gz' "$tmp/created" || { echo "FAIL: firmware asset missing"; exit 1; }
grep -q 'sha256sums' "$tmp/created" || { echo "FAIL: sha256sums asset missing"; exit 1; }

notes=$(grep -A1 -- '--notes-file' "$tmp/created" | tail -n 1)
# PREV_SHA must come from the exact-match x86-* release (2222...), not the newer decoy x86-old (9999...)
grep -q 'compare/2222222.*\.\.\.1111111' "$notes" || { echo "FAIL: PREV_SHA must come from the exact-match previous release"; exit 1; }
# upstream commits are spelled out, not merely linked
grep -q 'Upstream changes · 2 commits' "$notes" || { echo "FAIL: upstream commit count"; exit 1; }
grep -qx -- '- kernel: bump to 6.12.35' "$notes" || { echo "FAIL: upstream commit subject inlined"; exit 1; }
grep -q 'long body here' "$notes" && { echo "FAIL: only the subject line, not the body"; exit 1; }
# the package table carries its source repo, flagged as moved since last build
# shellcheck disable=SC2016
grep -q '| luci-app-passwall2 | 25.7.1 | passwall2 `aaaaaaa` ↑ |' "$notes" \
  || { echo "FAIL: package row must name its source repo and flag the move"; exit 1; }
# the previous release's packages comment must drive the per-repo commit log...
grep -q 'Plugin changes · 1 repos, 2 commits' "$notes" || { echo "FAIL: plugin change summary"; exit 1; }
grep -q 'openwrt-passwall2/compare/cccccccc.*\.\.\.aaaaaaaa' "$notes" \
  || { echo "FAIL: PREV_PKG_REPOS must produce a per-repo compare link"; exit 1; }
# ...and this release must record its own, so the next build can diff against it
grep -q '<!-- packages: passwall2@aaaaaaaa' "$notes" \
  || { echo "FAIL: this release must record its package SHAs for the next one"; exit 1; }

# a build with no previous release has nothing to compare against: both change
# blocks must vanish rather than render empty
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "release list" ]; then echo ""
elif [ "$1 $2" = "release create" ]; then shift 2; printf '%s\n' "$@" > "$GH_CREATED"
fi
FAKE
chmod +x "$tmp/bin/gh"
bash "$here/../scripts/publish-release.sh" "$tmp/meta" "$tmp/upload" "$tmp/s" "$tmp/p.ini" "$tmp/tpl.md" "$tmp/custom"
notes=$(grep -A1 -- '--notes-file' "$tmp/created" | tail -n 1)
grep -q 'Upstream changes' "$notes" && { echo "FAIL: no previous release must drop the upstream block"; exit 1; }
grep -q 'Plugin changes' "$notes" && { echo "FAIL: no previous release must drop the plugin block"; exit 1; }
grep -q '| luci-app-passwall2 |' "$notes" || { echo "FAIL: packages must still render without a previous release"; exit 1; }

# missing upload dir must fail
( REPO=me/ci BUILD=x86 DATE=20260720-0300 SOURCE_REPO=o/o \
  bash "$here/../scripts/publish-release.sh" "$tmp/meta" "$tmp/nonexistent" "$tmp/s" "$tmp/p.ini" "$tmp/tpl.md" >/dev/null 2>&1 ) \
  && { echo "FAIL: missing upload dir must fail"; exit 1; }
echo "PASS: test-publish-release"
