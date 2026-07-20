#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ok.ini" <<'EOF'
# comment
[settings]
BUILD_BY        = eamonxg
WIFI_SSID       = Rilakkuma
WIFI_KEY        = Rilakkuma
WIFI_COUNTRY    = CN
WIFI_ENCRYPTION = sae-mixed
EOF
out=$(settings_load "$tmp/ok.ini")
echo "$out" | grep -qx 'BUILD_BY|eamonxg' || { echo "FAIL: alignment whitespace must be trimmed"; exit 1; }
echo "$out" | grep -qx 'WIFI_ENCRYPTION|sae-mixed' || { echo "FAIL: WIFI_ENCRYPTION"; exit 1; }
[ "$(echo "$out" | wc -l | tr -d ' ')" = 5 ] || { echo "FAIL: expected 5 records"; exit 1; }

# partial keys + empty value: empty means disabled, keep it as-is
printf '%s\n' '[settings]' 'WIFI_SSID = x' 'BUILD_BY =' > "$tmp/part.ini"
out=$(settings_load "$tmp/part.ini")
echo "$out" | grep -qx 'WIFI_SSID|x' || { echo "FAIL: partial keys"; exit 1; }
echo "$out" | grep -qx 'BUILD_BY|' || { echo "FAIL: empty value must be kept"; exit 1; }

# a typoed key used to fail silently; it must be a hard error now
printf '%s\n' '[settings]' 'WIFI_SSD = oops' > "$tmp/unk.ini"
err=$( (settings_load "$tmp/unk.ini") 2>&1 ) && { echo "FAIL: unknown key must fail"; exit 1; }
printf '%s' "$err" | grep -q 'unknown key' || { echo "FAIL: unknown key needs a specific error, got: $err"; exit 1; }

# typoed section name
printf '%s\n' '[setting]' 'BUILD_BY = x' > "$tmp/sec.ini"
( settings_load "$tmp/sec.ini" >/dev/null 2>&1 ) && { echo "FAIL: non-[settings] section must fail"; exit 1; }

# legacy flat format (no section header) must fail and point at the missing section
printf '%s\n' 'BUILD_BY=x' > "$tmp/flat.ini"
err=$( (settings_load "$tmp/flat.ini") 2>&1 ) && { echo "FAIL: missing section header must fail"; exit 1; }
printf '%s' "$err" | grep -q 'before any section' || { echo "FAIL: error should point at the missing section, got: $err"; exit 1; }

echo "PASS: test-settings-load"
