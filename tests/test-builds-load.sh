#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ok.ini" <<'EOF'
# comment

[x86]
target = x86/64

[jdcloud]
target  = qualcommax/ipq60xx
devices = jdcloud_re-cs-02 jdcloud_re-ss-01

[tr3000]
target = mediatek/filogic
devices = cudy_tr3000-v1
source = immortalwrt/immortalwrt
ref = master
EOF
out=$(builds_load "$tmp/ok.ini")
[ "$(echo "$out" | wc -l | tr -d ' ')" = 3 ] || { echo "FAIL: expected 3 records"; exit 1; }
echo "$out" | grep -qx 'x86|x86/64|openwrt/openwrt||' || { echo "FAIL: minimal section / default source"; exit 1; }
echo "$out" | grep -qx 'jdcloud|qualcommax/ipq60xx|openwrt/openwrt||jdcloud_re-cs-02 jdcloud_re-ss-01' \
  || { echo "FAIL: devices key"; exit 1; }
echo "$out" | grep -qx 'tr3000|mediatek/filogic|immortalwrt/immortalwrt|master|cudy_tr3000-v1' \
  || { echo "FAIL: source/ref override"; exit 1; }

# missing target
printf '%s\n' '[bad]' 'devices = x' > "$tmp/notarget.ini"
( builds_load "$tmp/notarget.ini" >/dev/null 2>&1 ) && { echo "FAIL: missing target must fail"; exit 1; }

# duplicate section
printf '%s\n' '[x86]' 'target = x86/64' '[x86]' 'target = x86/64' > "$tmp/dup.ini"
err=$( (builds_load "$tmp/dup.ini") 2>&1 ) && { echo "FAIL: duplicate section must fail"; exit 1; }
printf '%s' "$err" | grep -q "duplicate section" || { echo "FAIL: duplicate section needs a specific error, got: $err"; exit 1; }

# unknown key
printf '%s\n' '[x86]' 'target = x86/64' 'foo = bar' > "$tmp/unk.ini"
err=$( (builds_load "$tmp/unk.ini") 2>&1 ) && { echo "FAIL: unknown key must fail"; exit 1; }
printf '%s' "$err" | grep -q "unknown key" || { echo "FAIL: unknown key needs a specific error, got: $err"; exit 1; }

# names may prefix each other: release tag matching is exact on <name>-date-time
printf '%s\n' '[x86]' 'target = x86/64' '[x86-old]' 'target = x86/64' > "$tmp/prefix.ini"
out=$(builds_load "$tmp/prefix.ini") || { echo "FAIL: prefixing names must be allowed"; exit 1; }
[ "$(echo "$out" | wc -l | tr -d ' ')" = 2 ] || { echo "FAIL: prefixing names should yield 2 records"; exit 1; }

echo "PASS: test-builds-load"
