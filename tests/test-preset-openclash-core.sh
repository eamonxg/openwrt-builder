#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/preset-openclash-core.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# a fake meta-core tarball: a single binary named 'clash', as the real one ships
echo 'FAKE_CLASH_META_BINARY' > "$tmp/clash"
tar czf "$tmp/core.tar.gz" -C "$tmp" clash

# stub curl on PATH: record the URL it was asked for, and answer with the fake
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -m) shift 2 ;;
    -*) shift ;;
    *)  url=\$1; shift ;;
  esac
done
printf '%s\n' "\$url" >> "$tmp/urls.log"
cp "$tmp/core.tar.gz" "\$out"
EOF
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"; export PATH

# a cloned openclash package, as clone-packages.sh would leave it
mk_pkg() { mkdir -p "$1/package/custom/openclash/luci-app-openclash"; : > "$1/package/custom/openclash/luci-app-openclash/Makefile"; }
core_of() { printf '%s' "$1/package/custom/openclash/luci-app-openclash/root/etc/openclash/core/clash_meta"; }

# --- not enabled: no-op, no download, no core file ---
o="$tmp/o_off"; mkdir -p "$o"; mk_pkg "$o"
printf '%s\n' 'CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"' '# CONFIG_PACKAGE_luci-app-openclash is not set' > "$o/.config"
sh "$sc" "$o"
[ ! -e "$tmp/urls.log" ] || { echo "FAIL: a build that does not enable openclash must not fetch"; exit 1; }
[ ! -e "$(core_of "$o")" ] || { echo "FAIL: a disabled build must write no core"; exit 1; }

# --- enabled, aarch64 -> arm64 core lands inside the package, executable ---
o="$tmp/o_arm"; mkdir -p "$o"; mk_pkg "$o"
printf '%s\n' 'CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"' 'CONFIG_PACKAGE_luci-app-openclash=m' > "$o/.config"
sh "$sc" "$o"
core=$(core_of "$o")
[ -s "$core" ] || { echo "FAIL: an enabled build must place the core in the package"; exit 1; }
grep -q FAKE_CLASH_META_BINARY "$core" || { echo "FAIL: core content wrong"; exit 1; }
[ -x "$core" ] || { echo "FAIL: core must be executable"; exit 1; }
grep -q 'clash-linux-arm64.tar.gz' "$tmp/urls.log" || { echo "FAIL: aarch64 must fetch the arm64 core"; exit 1; }

# --- arch mapping: x86_64 -> amd64 ---
rm -f "$tmp/urls.log"
o="$tmp/o_x86"; mkdir -p "$o"; mk_pkg "$o"
printf '%s\n' 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"' 'CONFIG_PACKAGE_luci-app-openclash=y' > "$o/.config"
sh "$sc" "$o"
grep -q 'clash-linux-amd64.tar.gz' "$tmp/urls.log" || { echo "FAIL: x86_64 must fetch the amd64 core"; exit 1; }

# --- unmapped arch fails loudly rather than fetching a wrong core ---
o="$tmp/o_bad"; mkdir -p "$o"; mk_pkg "$o"
printf '%s\n' 'CONFIG_TARGET_ARCH_PACKAGES="mips_24kc"' 'CONFIG_PACKAGE_luci-app-openclash=m' > "$o/.config"
if sh "$sc" "$o" 2>/dev/null; then echo "FAIL: an unmapped arch must fail"; exit 1; fi

# --- enabled but the package was never cloned: fail, do not silently skip ---
o="$tmp/o_noclone"; mkdir -p "$o/package/custom"
printf '%s\n' 'CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"' 'CONFIG_PACKAGE_luci-app-openclash=m' > "$o/.config"
if sh "$sc" "$o" 2>/dev/null; then echo "FAIL: openclash enabled but not cloned must fail"; exit 1; fi

echo "PASS: test-preset-openclash-core"
