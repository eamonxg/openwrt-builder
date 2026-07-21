#!/bin/sh
# gen-firmware-defaults.sh <settings.ini> <files-root> [build] [device...] —
# generate firmware defaults from the personalization settings:
#   BUILD_BY -> etc/uci-defaults/90-branding (append a build tag on first boot)
#   LAN_IP   -> etc/uci-defaults/95-network  (default LAN address)
#   WIFI_*   -> etc/board.d/05-wifi-defaults (official board.json wlan.defaults entry)
#
# files/ is shared by every device in a build, so a value that differs between
# devices cannot be resolved here -- it becomes a board_name case in the
# generated script.
#
# Everything else must stay resolved at build time. A runtime test claims "this
# is not knowable until the box boots"; making that claim about a value we
# already know misleads whoever reads the script on the router, and leaves
# branches that can never be taken. So each key is classified twice -- do the
# possible values differ, and do they differ in being empty -- and only a key
# that genuinely varies becomes a variable or gains a guard.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
conf=$1; files=$2; build=${3:-}
if [ $# -gt 3 ]; then shift 3; devices=$*; else devices=''; fi
[ -f "$conf" ] || exit 0
# paths this run writes, checked with 'sh -n' once everything below is done
generated=''

# One settings_load per scope, each captured before any pipe: a die() inside it
# on the left of one would be swallowed (see lib.sh header). settings_load
# rejects unknown keys, so a typo fails here rather than silently doing nothing.
# '@build' cannot collide with a device file: ini section names exclude '@'.
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
settings_load "$conf" "$build" > "$work/@build"
for d in $devices; do
  settings_load "$conf" "$build" "$d" > "$work/$d"
done

# val <scope-file> <key>. WIFI_ENCRYPTION's default is applied per scope here,
# not on the device: which cipher to use is a build-time fact.
val() {
  _v=$(sed -n "s/^$2|//p" "$1" | head -n 1)
  if [ "$2" = WIFI_ENCRYPTION ] && [ -z "$_v" ]; then _v=sae-mixed; fi
  printf '%s' "$_v"
}

# The outcome set of a key is the build-level value plus every device's. The
# build-level one counts: it is what a board matching no case branch gets.
varies() { # $1 key -> true when the outcomes are not all equal
  _base=$(val "$work/@build" "$1")
  for _s in $devices; do
    [ "$(val "$work/$_s" "$1")" = "$_base" ] || return 0
  done
  return 1
}
all_set() { # $1 key -> true when every outcome is non-empty
  [ -n "$(val "$work/@build" "$1")" ] || return 1
  for _s in $devices; do
    [ -n "$(val "$work/$_s" "$1")" ] || return 1
  done
  return 0
}
none_set() { # $1 key -> true when every outcome is empty
  [ -z "$(val "$work/@build" "$1")" ] || return 1
  for _s in $devices; do
    [ -z "$(val "$work/$_s" "$1")" ] || return 1
  done
  return 0
}
any_varies() {
  for _k in "$@"; do
    if varies "$_k"; then return 0; fi
  done
  return 1
}

# ref <key> -> the shell text yielding the value: a quoted literal when it is
# the same on every board, "$KEY" when a device changes it.
ref() {
  if varies "$1"; then printf '"$%s"' "$1"
  else printf "'%s'" "$(val "$work/@build" "$1")"
  fi
}

# board_patterns <image-id> -> 'vendor,model|vendor_model'
# board_name returns the first device-tree compatible (jdcloud,re-cs-02) while
# builds.ini names a device the way its image is named (jdcloud_re-cs-02). The
# two differ only in the first separator, but that is a naming convention in
# each target's .mk rather than a guarantee, and a miss would be silent -- the
# board would quietly fall back to the build-level value. Both are matched.
board_patterns() {
  printf '%s|%s' "$(printf '%s' "$1" | sed 's/_/,/')" "$1"
}

# emit_vars <key>...: assignments plus one case, for the keys that actually
# vary. A key that is the same on every board produces nothing here -- ref()
# inlined it instead.
emit_vars() {
  _varying=''
  for _k in "$@"; do
    if varies "$_k"; then _varying="$_varying $_k"; fi
  done
  [ -n "$_varying" ] || return 0
  for _k in $_varying; do
    printf "%s='%s'\n" "$_k" "$(val "$work/@build" "$_k")"
  done
  printf "case \"\$(board_name)\" in\n"
  for _d in $devices; do
    _diff=''
    for _k in $_varying; do
      _dv=$(val "$work/$_d" "$_k")
      if [ "$_dv" != "$(val "$work/@build" "$_k")" ]; then _diff="$_diff $_k='$_dv';"; fi
    done
    [ -n "$_diff" ] || continue
    printf '  %s)%s ;;\n' "$(board_patterns "$_d")" "${_diff%;}"
  done
  printf 'esac\n'
}

# emit_guarded <key> <line>: drop the line when the key is empty on every board,
# emit it bare when set on every board, guard it only when it is genuinely one
# or the other depending on which board booted.
emit_guarded() {
  if none_set "$1"; then return 0; fi
  if all_set "$1"; then printf '%s\n' "$2"
  else printf '[ -n %s ] && %s\n' "$(ref "$1")" "$2"
  fi
}

# emit_wifi_guard: the runtime gate before board_config_update. wifi-scripts
# needs both WIFI_SSID and WIFI_KEY non-empty, but each contributes its own
# test only when its OWN emptiness actually varies (! all_set) -- a key that
# is non-empty on every board needs no runtime check, and testing it anyway
# would assert against a literal the build already knows is true.
emit_wifi_guard() {
  _wg=''
  for _wk in WIFI_SSID WIFI_KEY; do
    if ! all_set "$_wk"; then
      _wg="$_wg${_wg:+ && }[ -n $(ref "$_wk") ]"
    fi
  done
  [ -z "$_wg" ] || printf '%s || exit 0\n' "$_wg"
}

# 5 GHz defaults need a country code (mac80211 restriction). Without one the
# entry is accepted and silently does nothing -- a failure you would only meet
# after flashing. Checked per resolution unit, since either key can be
# overridden by a single device.
for f in "$work"/*; do
  if [ -n "$(val "$f" WIFI_SSID_5G)" ] && [ -z "$(val "$f" WIFI_COUNTRY)" ]; then
    scope=$(basename "$f")
    [ "$scope" != '@build' ] || scope="build ${build:-<none>}"
    die "WIFI_SSID_5G is set without WIFI_COUNTRY ($scope): 5 GHz defaults need a country code and would silently not apply"
  fi
done

if ! none_set BUILD_BY; then
  out="$files/etc/uci-defaults"
  mkdir -p "$out"
  {
    cat <<'EOF'
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
EOF
    if any_varies BUILD_BY; then printf '. /lib/functions.sh\n'; fi
    emit_vars BUILD_BY
    if ! all_set BUILD_BY; then printf '[ -n %s ] || exit 0\n' "$(ref BUILD_BY)"; fi
    # one indirection so both spellings of the value share the sed expressions
    printf 'tag=" built by "%s\n' "$(ref BUILD_BY)"
    cat <<'EOF'
sed -i "s/^OPENWRT_RELEASE=\"\(.*\)\"/OPENWRT_RELEASE=\"\1$tag\"/" /usr/lib/os-release
sed -i "s/^DISTRIB_DESCRIPTION='\(.*\)'/DISTRIB_DESCRIPTION='\1$tag'/" /etc/openwrt_release
exit 0
EOF
  } > "$out/90-branding"
  generated="$generated $out/90-branding"
  echo "generated 90-branding (by $(val "$work/@build" BUILD_BY))"
fi

if ! none_set LAN_IP; then
  out="$files/etc/uci-defaults"
  mkdir -p "$out"
  {
    cat <<'EOF'
#!/bin/sh
# Default LAN address. uci-defaults rather than board.d: this runs from
# /etc/init.d/boot before the network is brought up, and unlike a board.d entry
# it does not have to interleave with each target's own 02_network, so it stays
# target-independent. The DHCP pool needs no attention -- dnsmasq's start and
# limit are relative to the network address, so the range follows on its own.
EOF
    if any_varies LAN_IP; then printf '. /lib/functions.sh\n'; fi
    emit_vars LAN_IP
    if ! all_set LAN_IP; then printf '[ -n %s ] || exit 0\n' "$(ref LAN_IP)"; fi
    printf 'uci set network.lan.ipaddr=%s\n' "$(ref LAN_IP)"
    printf 'uci commit network\nexit 0\n'
  } > "$out/95-network"
  generated="$generated $out/95-network"
  # the build-level address, the one a board matching no case branch gets --
  # empty is a real outcome (every device may set its own and none), so it
  # gets a word rather than reading as an omission
  base_lan=$(val "$work/@build" LAN_IP)
  echo "generated 95-network (base LAN address ${base_lan:-unset, per-device only})"
fi

if ! none_set WIFI_SSID && ! none_set WIFI_KEY; then
  out="$files/etc/board.d"
  mkdir -p "$out"
  {
    cat <<'EOF'
#!/bin/sh
# factory default wireless via the official board.json wlan.defaults entry,
# consumed by wifi-scripts when generating the config
EOF
    if any_varies WIFI_SSID WIFI_SSID_5G WIFI_KEY WIFI_COUNTRY WIFI_ENCRYPTION; then
      printf '. /lib/functions.sh\n'
    fi
    printf '. /lib/functions/uci-defaults.sh\n'
    emit_vars WIFI_SSID WIFI_SSID_5G WIFI_KEY WIFI_COUNTRY WIFI_ENCRYPTION
    emit_wifi_guard
    printf 'board_config_update\n'
    printf "ucidef_set_wireless 'all' %s %s %s\n" "$(ref WIFI_SSID)" "$(ref WIFI_ENCRYPTION)" "$(ref WIFI_KEY)"
    # A per-band entry replaces the 'all' entry wholesale for that band, and
    # wifi-scripts ignores one that carries no ssid -- so repeat encryption+key.
    emit_guarded WIFI_SSID_5G \
      "$(printf "ucidef_set_wireless '5g' %s %s %s" "$(ref WIFI_SSID_5G)" "$(ref WIFI_ENCRYPTION)" "$(ref WIFI_KEY)")"
    emit_guarded WIFI_COUNTRY "$(printf 'ucidef_set_country %s' "$(ref WIFI_COUNTRY)")"
    printf 'board_config_flush\nexit 0\n'
  } > "$out/05-wifi-defaults"
  generated="$generated $out/05-wifi-defaults"
  echo "generated 05-wifi-defaults (base SSID $(val "$work/@build" WIFI_SSID))"
fi

# README's forbidden characters (quotes, backslashes, slashes, '#') are a
# convention -- ini_load only rejects '|' and treats '#' as a comment, so a
# value like "Eamon's WiFi" reaches here untouched and breaks the single
# quotes it gets spliced into above. Catching that at build time, by naming
# the file, beats shipping firmware whose first-boot script fails silently.
for f in $generated; do
  sh -n "$f" || die "generated invalid shell syntax, check settings.ini values: $f"
done
