#!/bin/sh
# preset-openclash-core.sh <openwrt-dir> — when this build enables OpenClash,
# fetch its meta core into the cloned package so it ships inside the ipk.
# OpenClash carries no core and the file is ~20 MB; a shared files/ overlay
# would land it on every device of the build, whereas bound to the package it
# reaches only the devices that actually install openclash.
set -eu
owrt=$1
cfg="$owrt/.config"

# Nothing to do unless this build enables openclash. This runs for every build
# and no-ops on the ones that do not, so the workflow needs no per-build knowledge.
grep -qE '^CONFIG_PACKAGE_luci-app-openclash=[ym]$' "$cfg" || exit 0

# clash names its builds by GOARCH; map the OpenWrt package arch onto it. Only
# the arches this repo's targets use are mapped — a new target fails loudly here
# rather than fetching a wrong or nonexistent core.
arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$cfg")
case "$arch" in
  aarch64*) core=arm64 ;;
  x86_64)   core=amd64 ;;
  *) echo "preset-openclash-core: no clash core mapped for arch '$arch' — add it to the case" >&2; exit 1 ;;
esac

# clone-packages.sh cloned the repo to package/custom/<section>; find the app by
# its Makefile rather than hardcoding the section name.
mk=$(find "$owrt/package/custom" -path '*/luci-app-openclash/Makefile' 2>/dev/null | head -n1)
[ -n "$mk" ] || { echo "preset-openclash-core: openclash is enabled but its package was not cloned (check packages.ini)" >&2; exit 1; }
dest="$(dirname "$mk")/root/etc/openclash/core"
mkdir -p "$dest"

url="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$core.tar.gz"
tarball=$(mktemp)
ok=0
for i in 1 2 3; do
  if curl -fsSL -m 60 "$url" -o "$tarball" && [ -s "$tarball" ]; then ok=1; break; fi
  echo "preset-openclash-core: fetch failed, retry $i..." >&2
  sleep 5
done
[ "$ok" = 1 ] || { rm -f "$tarball"; echo "preset-openclash-core: could not fetch $url" >&2; exit 1; }

# the tarball holds a single clash binary; -O concatenates member contents to
# stdout, which for one member is exactly that binary.
tar xzOf "$tarball" > "$dest/clash_meta"
rm -f "$tarball"
[ -s "$dest/clash_meta" ] || { echo "preset-openclash-core: core is empty after extracting $url" >&2; exit 1; }
chmod +x "$dest/clash_meta"
echo "preset-openclash-core: $core core -> $dest/clash_meta ($(wc -c < "$dest/clash_meta" | tr -d ' ') bytes)"
