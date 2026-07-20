#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/gen-firmware-defaults.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# with country code: branding + board.d entry + country block; unset WIFI_ENCRYPTION defaults to sae-mixed
printf '%s\n' '[settings]' 'BUILD_BY = eamonxg' 'WIFI_SSID = Rilakkuma' \
  'WIFI_KEY = Rilakkuma' 'WIFI_COUNTRY = CN' > "$tmp/s.ini"
mkdir -p "$tmp/files"
sh "$sc" "$tmp/s.ini" "$tmp/files"
grep -q "by eamonxg" "$tmp/files/etc/uci-defaults/90-branding" || { echo "FAIL: branding"; exit 1; }
grep -qF "ucidef_set_wireless 'all' 'Rilakkuma' 'sae-mixed' 'Rilakkuma'" "$tmp/files/etc/board.d/05-wifi-defaults" || { echo "FAIL: ucidef_set_wireless missing (default sae-mixed)"; exit 1; }
grep -qF "ucidef_set_country 'CN'" "$tmp/files/etc/board.d/05-wifi-defaults" || { echo "FAIL: WIFI_COUNTRY set, ucidef_set_country expected"; exit 1; }
sh -n "$tmp/files/etc/uci-defaults/90-branding" || { echo "FAIL: 90-branding syntax error"; exit 1; }
sh -n "$tmp/files/etc/board.d/05-wifi-defaults" || { echo "FAIL: 05-wifi-defaults syntax error"; exit 1; }

# without country code: no country block
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' > "$tmp/nocountry.ini"
mkdir -p "$tmp/files2"
sh "$sc" "$tmp/nocountry.ini" "$tmp/files2"
grep -q 'country' "$tmp/files2/etc/board.d/05-wifi-defaults" && { echo "FAIL: no WIFI_COUNTRY, no country block expected"; exit 1; }
sh -n "$tmp/files2/etc/board.d/05-wifi-defaults" || { echo "FAIL: 05-wifi-defaults (no country) syntax error"; exit 1; }

# explicit WIFI_ENCRYPTION=psk2: used as-is, no sae-mixed fallback
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' 'WIFI_ENCRYPTION = psk2' > "$tmp/enc.ini"
mkdir -p "$tmp/files4"
sh "$sc" "$tmp/enc.ini" "$tmp/files4"
grep -qF "ucidef_set_wireless 'all' 'Rilakkuma' 'psk2' 'Rilakkuma'" "$tmp/files4/etc/board.d/05-wifi-defaults" || { echo "FAIL: explicit WIFI_ENCRYPTION=psk2 not applied"; exit 1; }
sh -n "$tmp/files4/etc/board.d/05-wifi-defaults" || { echo "FAIL: 05-wifi-defaults (psk2) syntax error"; exit 1; }

# empty settings generate nothing
printf '%s\n' '[settings]' 'BUILD_BY =' 'WIFI_SSID =' > "$tmp/empty.ini"
mkdir -p "$tmp/files3"
sh "$sc" "$tmp/empty.ini" "$tmp/files3"
[ -z "$(ls -A "$tmp/files3")" ] || { echo "FAIL: empty settings must generate nothing"; exit 1; }

# a typoed key must fail hard (used to fail silently)
printf '%s\n' '[settings]' 'WIFI_SSD = oops' > "$tmp/unk.ini"
if sh "$sc" "$tmp/unk.ini" "$tmp/files3" 2>/dev/null; then
  echo "FAIL: unknown key must fail"; exit 1
fi
[ -z "$(ls -A "$tmp/files3")" ] || { echo "FAIL: unknown key must not generate files"; exit 1; }

sh "$sc" "$tmp/missing.ini" "$tmp/files3" || { echo "FAIL: missing file must be a silent no-op"; exit 1; }

echo "PASS: test-gen-firmware-defaults"
