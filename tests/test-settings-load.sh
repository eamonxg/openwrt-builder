#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# baseline: with only [settings], behaviour is unchanged
printf '%s\n' '[settings]' \
  'BUILD_BY        = eamonxg' \
  'WIFI_SSID       = Rilakkuma' \
  'WIFI_KEY        = Rilakkuma' \
  'WIFI_COUNTRY    = CN' \
  'WIFI_ENCRYPTION = sae-mixed' > "$tmp/ok.ini"
out=$(settings_load "$tmp/ok.ini")
echo "$out" | grep -qx 'BUILD_BY|eamonxg' || { echo "FAIL: alignment whitespace must be trimmed"; exit 1; }
echo "$out" | grep -qx 'WIFI_ENCRYPTION|sae-mixed' || { echo "FAIL: WIFI_ENCRYPTION"; exit 1; }

# LAN_IP is a known key
printf '%s\n' '[settings]' 'LAN_IP = 192.168.1.1' > "$tmp/lan.ini"
settings_load "$tmp/lan.ini" | grep -qx 'LAN_IP|192.168.1.1' || { echo "FAIL: LAN_IP must be a known key"; exit 1; }

# three scopes merged: narrowest first, so consumers take the first hit
printf '%s\n' '[settings]' 'WIFI_SSID = base' 'WIFI_KEY = pw' 'BUILD_BY = me' \
  '' '[jdcloud]' 'WIFI_SSID = buildlevel' \
  '' '[jdcloud_re-ss-01]' 'WIFI_SSID = devlevel' > "$tmp/three.ini"
first() { printf '%s\n' "$1" | sed -n "s/^$2|//p" | head -n 1; }

out=$(settings_load "$tmp/three.ini" jdcloud jdcloud_re-ss-01)
[ "$(first "$out" WIFI_SSID)" = devlevel ] || { echo "FAIL: device scope must win"; exit 1; }
[ "$(first "$out" WIFI_KEY)" = pw ] || { echo "FAIL: unset key must inherit from [settings]"; exit 1; }
[ "$(first "$out" BUILD_BY)" = me ] || { echo "FAIL: BUILD_BY must inherit"; exit 1; }

out=$(settings_load "$tmp/three.ini" jdcloud)
[ "$(first "$out" WIFI_SSID)" = buildlevel ] || { echo "FAIL: build scope must win over [settings]"; exit 1; }

out=$(settings_load "$tmp/three.ini")
[ "$(first "$out" WIFI_SSID)" = base ] || { echo "FAIL: no scope must yield [settings]"; exit 1; }

# a section this call did not select must not leak in
out=$(settings_load "$tmp/three.ini" jdcloud)
echo "$out" | grep -q 'devlevel' && { echo "FAIL: unselected section must not leak"; exit 1; }

# an empty value is a real override: it switches off what a wider scope turned on
printf '%s\n' '[settings]' 'WIFI_SSID_5G = wide' '' '[dev]' 'WIFI_SSID_5G =' > "$tmp/blank.ini"
out=$(settings_load "$tmp/blank.ini" dev)
[ -z "$(first "$out" WIFI_SSID_5G)" ] || { echo "FAIL: an empty value in a narrower scope must override"; exit 1; }

# an empty argument (what "${BUILD:-}" expands to when BUILD is unset) is
# ignored rather than treated as a section name
out=$(settings_load "$tmp/three.ini" '' jdcloud)
[ "$(first "$out" WIFI_SSID)" = buildlevel ] || { echo "FAIL: empty scope argument must be ignored"; exit 1; }

# One argument per scope. An argument containing whitespace must be fatal: it
# still word-splits in the loop below, but unreversed -- so device values leak
# into what callers treat as the build-level baseline, yielding a script with
# no case block and one device's values baked in for every board: wrong, and
# indistinguishable from correct output at a glance.
err=$( (settings_load "$tmp/three.ini" 'jdcloud jdcloud_re-ss-01') 2>&1 ) \
  && { echo "FAIL: a scope argument containing whitespace must fail"; exit 1; }
printf '%s' "$err" | grep -q 'not a section name' || { echo "FAIL: scope guard needs a specific error, got: $err"; exit 1; }
( settings_load "$tmp/three.ini" 'jd/cloud' >/dev/null 2>&1 ) \
  && { echo "FAIL: a scope argument that is not a section name must fail"; exit 1; }

# partial keys and empty-value records are kept: consumers rely on head -n 1,
# so the empty record has to be there to win
printf '%s\n' '[settings]' 'WIFI_SSID = x' 'BUILD_BY =' > "$tmp/part.ini"
out=$(settings_load "$tmp/part.ini")
echo "$out" | grep -qx 'WIFI_SSID|x' || { echo "FAIL: partial keys"; exit 1; }
echo "$out" | grep -qx 'BUILD_BY|' || { echo "FAIL: empty value must be kept"; exit 1; }

# an unknown key is fatal in every section, including ones not selected here
printf '%s\n' '[settings]' 'WIFI_SSD = oops' > "$tmp/unk.ini"
err=$( (settings_load "$tmp/unk.ini") 2>&1 ) && { echo "FAIL: unknown key must fail"; exit 1; }
printf '%s' "$err" | grep -q 'unknown key' || { echo "FAIL: unknown key needs a specific error, got: $err"; exit 1; }
printf '%s\n' '[settings]' 'WIFI_SSID = x' '' '[other]' 'WIFI_SSD = oops' > "$tmp/unk2.ini"
( settings_load "$tmp/unk2.ini" >/dev/null 2>&1 ) && { echo "FAIL: unknown key in an unselected section must still fail"; exit 1; }

# Section-name validity is no longer the loader's call -- make-matrix.sh checks
# every section against builds.ini instead. All this guarantees is that an
# unselected section quietly produces nothing rather than killing the build.
printf '%s\n' '[setting]' 'BUILD_BY = x' > "$tmp/sec.ini"
out=$(settings_load "$tmp/sec.ini") || { echo "FAIL: an unselected section must not be fatal here"; exit 1; }
[ -z "$out" ] || { echo "FAIL: an unselected section must produce nothing"; exit 1; }

# a bare key with no section header is still a syntax error (ini_load's job)
printf '%s\n' 'BUILD_BY=x' > "$tmp/flat.ini"
err=$( (settings_load "$tmp/flat.ini") 2>&1 ) && { echo "FAIL: missing section header must fail"; exit 1; }
printf '%s' "$err" | grep -q 'before any section' || { echo "FAIL: error should point at the missing section, got: $err"; exit 1; }

echo "PASS: test-settings-load"
