#!/bin/sh
# gen-firmware-defaults.sh <settings.ini> <files-root> — generate firmware
# defaults from the personalization settings:
#   BUILD_BY -> etc/uci-defaults/90-branding (append a build tag on first boot)
#   WIFI_*   -> etc/board.d/05-wifi-defaults (official board.json wlan.defaults entry)
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
conf=$1; files=$2
[ -f "$conf" ] || exit 0
# settings_load rejects unknown keys and wrong sections (typo = early failure)
vals=$(settings_load "$conf")
get() { printf '%s\n' "$vals" | sed -n "s/^$1|//p" | head -n 1; }
BUILD_BY=$(get BUILD_BY)
WIFI_SSID=$(get WIFI_SSID)
WIFI_SSID_5G=$(get WIFI_SSID_5G)
WIFI_KEY=$(get WIFI_KEY)
WIFI_COUNTRY=$(get WIFI_COUNTRY)
WIFI_ENCRYPTION=$(get WIFI_ENCRYPTION)
[ -n "$WIFI_ENCRYPTION" ] || WIFI_ENCRYPTION=sae-mixed

if [ -n "$BUILD_BY" ]; then
  out="$files/etc/uci-defaults"
  mkdir -p "$out"
  cat > "$out/90-branding" <<EOF
#!/bin/sh
# Append the builder tag to the firmware version. Two files, two readers, both
# live -- neither line is redundant:
#   /usr/lib/os-release   OPENWRT_RELEASE -> procd -> ubus 'system board' ->
#     release.description, the version line LuCI renders. Patch this path, not
#     /etc/os-release: that is a symlink here (upstream commits it as mode
#     120000), and 'sed -i' would replace the link with a regular file, leaving
#     the file procd actually opens untouched.
#   /etc/openwrt_release  DISTRIB_DESCRIPTION -> luci-lua-runtime's luci.version,
#     which dofile()s this file at runtime -- its contents happen to be valid
#     Lua. passwall2 depends on luci-compat, which pulls that runtime in, so the
#     path is live in these builds; drop this line and the two disagree.
# 'built by', not 'by': what we did is build it, OpenWrt itself is not ours.
sed -i 's/^OPENWRT_RELEASE="\\(.*\\)"/OPENWRT_RELEASE="\\1 built by ${BUILD_BY}"/' /usr/lib/os-release
sed -i "s/^DISTRIB_DESCRIPTION='\\(.*\\)'/DISTRIB_DESCRIPTION='\\1 built by ${BUILD_BY}'/" /etc/openwrt_release
exit 0
EOF
  echo "generated 90-branding (by ${BUILD_BY})"
fi

if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_KEY" ]; then
  out="$files/etc/board.d"
  mkdir -p "$out"
  cat > "$out/05-wifi-defaults" <<EOF
#!/bin/sh
# factory default wireless via the official board.json wlan.defaults entry,
# consumed by wifi-scripts when generating the config
. /lib/functions/uci-defaults.sh
board_config_update
ucidef_set_wireless 'all' '${WIFI_SSID}' '${WIFI_ENCRYPTION}' '${WIFI_KEY}'
EOF
  # A per-band entry replaces the 'all' entry wholesale for that band, and
  # wifi-scripts ignores one that carries no ssid -- so repeat encryption+key.
  if [ -n "$WIFI_SSID_5G" ]; then
    printf "ucidef_set_wireless '5g' '%s' '%s' '%s'\n" \
      "$WIFI_SSID_5G" "$WIFI_ENCRYPTION" "$WIFI_KEY" >> "$out/05-wifi-defaults"
  fi
  if [ -n "$WIFI_COUNTRY" ]; then
    printf "ucidef_set_country '%s'\n" "$WIFI_COUNTRY" >> "$out/05-wifi-defaults"
  fi
  cat >> "$out/05-wifi-defaults" <<'EOF'
board_config_flush
exit 0
EOF
  echo "generated 05-wifi-defaults (SSID ${WIFI_SSID})"
fi
