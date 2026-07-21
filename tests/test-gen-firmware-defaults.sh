#!/bin/sh
# stub functions are called indirectly by the sourced script; shellcheck
# versions disagree on SC2317 vs SC2329 for that, and SC1091 flags the dynamic
# sourced file — all are safe here
# shellcheck disable=SC2317,SC2329,SC1091
set -eu
sc="$(dirname "$0")/../scripts/gen-firmware-defaults.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Run a generated script with the OpenWrt runtime replaced by stubs that print
# every call, so the assertions below describe what a board will actually do
# rather than what the file happens to look like. The '. /lib/...' lines are
# stripped: those files exist only on the device, and everything they provide is
# stubbed right here.
run_generated() { # $1 script  $2 board_name -> call log on stdout
  _rg_s=$1; _rg_b=$2
  sed '/^\. \/lib\//d' "$_rg_s" > "$tmp/stripped.sh"
  (
    board_name() { printf '%s\n' "$_rg_b"; }
    board_config_update() { echo "board_config_update"; }
    board_config_flush()  { echo "board_config_flush"; }
    ucidef_set_wireless() { echo "ucidef_set_wireless $*"; }
    ucidef_set_country()  { echo "ucidef_set_country $*"; }
    uci() { echo "uci $*"; }
    # tab-separated: the sed expression contains every other punctuation
    # character worth delimiting on
    sed() { if [ "$1" = "-i" ]; then printf 'sed -i\t%s\t%s\n' "$2" "$3"; else command sed "$@"; fi; }
    . "$tmp/stripped.sh"
  )
}

syntax_ok() { sh -n "$1" || { echo "FAIL: syntax error in $1"; exit 1; }; }

# ---- branding + wireless + country; unset WIFI_ENCRYPTION falls back to sae-mixed ----
printf '%s\n' '[settings]' 'BUILD_BY = eamonxg' 'WIFI_SSID = Rilakkuma' \
  'WIFI_KEY = Rilakkuma' 'WIFI_COUNTRY = CN' > "$tmp/s.ini"
mkdir -p "$tmp/files"
sh "$sc" "$tmp/s.ini" "$tmp/files"
br="$tmp/files/etc/uci-defaults/90-branding"
wf="$tmp/files/etc/board.d/05-wifi-defaults"
syntax_ok "$br"; syntax_ok "$wf"

log=$(run_generated "$wf" 'anything,at-all')
echo "$log" | grep -qx "ucidef_set_wireless all Rilakkuma sae-mixed Rilakkuma" || {
  echo "FAIL: wireless defaults (got: $log)"; exit 1; }
echo "$log" | grep -qx "ucidef_set_country CN" || { echo "FAIL: WIFI_COUNTRY set, ucidef_set_country expected"; exit 1; }
echo "$log" | grep -q "ucidef_set_wireless 5g" && { echo "FAIL: no WIFI_SSID_5G, no 5g entry expected"; exit 1; }
echo "$log" | grep -qx "board_config_flush" || { echo "FAIL: board_config_flush missing"; exit 1; }

# LuCI reads OPENWRT_RELEASE from /usr/lib/os-release; patching only the legacy
# /etc/openwrt_release left the version string in LuCI unbranded. And
# /etc/openwrt_release is not dead weight either: luci-lua-runtime dofile()s it
# for luci.version, and passwall2 pulls that runtime in via luci-compat.
log=$(run_generated "$br" 'anything,at-all')
expr_os=$(printf '%s\n' "$log" | awk -F'\t' '$3=="/usr/lib/os-release"{print $2}')
[ -n "$expr_os" ] || { echo "FAIL: os-release not patched"; exit 1; }
expr_rel=$(printf '%s\n' "$log" | awk -F'\t' '$3=="/etc/openwrt_release"{print $2}')
[ -n "$expr_rel" ] || { echo "FAIL: openwrt_release not patched"; exit 1; }
# the expression must actually rewrite a real os-release line. It arrives here
# already expanded by the generated script's own shell, so run it as-is.
got=$(printf '%s\n' 'OPENWRT_RELEASE="OpenWrt SNAPSHOT r0-672400f"' | sed "$expr_os")
[ "$got" = 'OPENWRT_RELEASE="OpenWrt SNAPSHOT r0-672400f built by eamonxg"' ] || {
  echo "FAIL: os-release sed did not append the builder tag, got: $got"; exit 1; }
got=$(printf '%s\n' "DISTRIB_DESCRIPTION='OpenWrt SNAPSHOT r0-672400f'" | sed "$expr_rel")
[ "$got" = "DISTRIB_DESCRIPTION='OpenWrt SNAPSHOT r0-672400f built by eamonxg'" ] || {
  echo "FAIL: openwrt_release sed did not append the builder tag, got: $got"; exit 1; }

# ---- no country code: no country line ----
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' > "$tmp/nocountry.ini"
mkdir -p "$tmp/files2"
sh "$sc" "$tmp/nocountry.ini" "$tmp/files2"
syntax_ok "$tmp/files2/etc/board.d/05-wifi-defaults"
run_generated "$tmp/files2/etc/board.d/05-wifi-defaults" 'x,y' | grep -q country && {
  echo "FAIL: no WIFI_COUNTRY, no country block expected"; exit 1; }

# ---- explicit psk2: used as-is, no sae-mixed fallback ----
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' 'WIFI_ENCRYPTION = psk2' > "$tmp/enc.ini"
mkdir -p "$tmp/files4"
sh "$sc" "$tmp/enc.ini" "$tmp/files4"
syntax_ok "$tmp/files4/etc/board.d/05-wifi-defaults"
run_generated "$tmp/files4/etc/board.d/05-wifi-defaults" 'x,y' \
  | grep -qx "ucidef_set_wireless all Rilakkuma psk2 Rilakkuma" || {
  echo "FAIL: explicit WIFI_ENCRYPTION=psk2 not applied"; exit 1; }

# ---- split bands: 'all' stays for 2.4 GHz, '5g' overrides 5 GHz, and the 5g
# ---- entry must repeat encryption+key (it replaces 'all' wholesale there, and
# ---- wifi-scripts ignores an entry carrying no ssid) ----
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_SSID_5G = Rilakkuma_5G' \
  'WIFI_KEY = Rilakkuma' 'WIFI_COUNTRY = CN' > "$tmp/split.ini"
mkdir -p "$tmp/files5"
sh "$sc" "$tmp/split.ini" "$tmp/files5"
syntax_ok "$tmp/files5/etc/board.d/05-wifi-defaults"
log=$(run_generated "$tmp/files5/etc/board.d/05-wifi-defaults" 'x,y')
echo "$log" | grep -qx "ucidef_set_wireless all Rilakkuma sae-mixed Rilakkuma" || { echo "FAIL: 'all' entry missing when 5G split"; exit 1; }
echo "$log" | grep -qx "ucidef_set_wireless 5g Rilakkuma_5G sae-mixed Rilakkuma" || { echo "FAIL: '5g' entry missing"; exit 1; }

# ---- everything empty: nothing generated ----
printf '%s\n' '[settings]' 'BUILD_BY =' 'WIFI_SSID =' > "$tmp/empty.ini"
mkdir -p "$tmp/files3"
sh "$sc" "$tmp/empty.ini" "$tmp/files3"
[ -z "$(ls -A "$tmp/files3")" ] || { echo "FAIL: empty settings must generate nothing"; exit 1; }

# ---- typoed key: hard failure, no half-written files ----
printf '%s\n' '[settings]' 'WIFI_SSD = oops' > "$tmp/unk.ini"
if sh "$sc" "$tmp/unk.ini" "$tmp/files3" 2>/dev/null; then
  echo "FAIL: unknown key must fail"; exit 1
fi
[ -z "$(ls -A "$tmp/files3")" ] || { echo "FAIL: unknown key must not generate files"; exit 1; }

# ---- missing file: silent no-op ----
sh "$sc" "$tmp/missing.ini" "$tmp/files3" || { echo "FAIL: missing file must be a silent no-op"; exit 1; }

# ---- build scope: shared by every device of the build. Nothing that is
# ---- already settled at build time may be deferred to runtime: no case, no
# ---- variables, no guards, and no sourcing of /lib/functions.sh (that is
# ---- only needed for board_name).
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' 'WIFI_COUNTRY = CN' \
  '' '[tr3000]' 'WIFI_SSID = Rilakkuma_Cudy' > "$tmp/build.ini"
mkdir -p "$tmp/f_build"
sh "$sc" "$tmp/build.ini" "$tmp/f_build" tr3000 cudy_tr3000-v1 cudy_tr3000-256mb-v1
wf="$tmp/f_build/etc/board.d/05-wifi-defaults"
syntax_ok "$wf"
grep -q '^case ' "$wf" && { echo "FAIL: no device differs, no case block expected"; exit 1; }
grep -q '^\. /lib/functions\.sh' "$wf" && { echo "FAIL: no case block, board_name is not needed"; exit 1; }
grep -q '\[ -n ' "$wf" && { echo "FAIL: every value is known at build time, no runtime guard expected"; exit 1; }
# shellcheck disable=SC2016
grep -q '\$WIFI_' "$wf" && { echo "FAIL: nothing varies, no variables expected"; exit 1; }
run_generated "$wf" 'cudy,tr3000-v1' | grep -qx "ucidef_set_wireless all Rilakkuma_Cudy sae-mixed Rilakkuma" || {
  echo "FAIL: build-scope SSID not applied"; exit 1; }

# ---- device scope: two boards in one build take their own branches ----
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = Rilakkuma' 'WIFI_COUNTRY = CN' \
  '' '[jdcloud_re-cs-02]' 'WIFI_SSID = Rilakkuma_Athena' \
  '' '[jdcloud_re-ss-01]' 'WIFI_SSID = Rilakkuma_Arthur' 'WIFI_SSID_5G = Rilakkuma_Arthur_5G' > "$tmp/dev.ini"
mkdir -p "$tmp/f_dev"
sh "$sc" "$tmp/dev.ini" "$tmp/f_dev" jdcloud jdcloud_re-cs-02 jdcloud_re-ss-01
wf="$tmp/f_dev/etc/board.d/05-wifi-defaults"
syntax_ok "$wf"
grep -q '^\. /lib/functions\.sh' "$wf" || { echo "FAIL: a case block needs board_name, so /lib/functions.sh must be sourced"; exit 1; }

log=$(run_generated "$wf" 'jdcloud,re-cs-02')
echo "$log" | grep -qx "ucidef_set_wireless all Rilakkuma_Athena sae-mixed Rilakkuma" || {
  echo "FAIL: athena SSID (got: $log)"; exit 1; }
echo "$log" | grep -q "ucidef_set_wireless 5g" && { echo "FAIL: athena must not split bands"; exit 1; }

log=$(run_generated "$wf" 'jdcloud,re-ss-01')
echo "$log" | grep -qx "ucidef_set_wireless all Rilakkuma_Arthur sae-mixed Rilakkuma" || {
  echo "FAIL: arthur SSID (got: $log)"; exit 1; }
echo "$log" | grep -qx "ucidef_set_wireless 5g Rilakkuma_Arthur_5G sae-mixed Rilakkuma" || {
  echo "FAIL: arthur 5g entry (got: $log)"; exit 1; }

# only a key that genuinely differs between devices becomes a variable; the
# rest stay build-time literals, and country is non-empty on every board, so
# that line carries no guard
# shellcheck disable=SC2016
grep -q '"\$WIFI_SSID"' "$wf" || { echo "FAIL: WIFI_SSID varies, it must be a variable"; exit 1; }
# shellcheck disable=SC2016
grep -q '\$WIFI_KEY' "$wf" && { echo "FAIL: WIFI_KEY is the same everywhere, it must stay a literal"; exit 1; }
# shellcheck disable=SC2016
grep -q '\$WIFI_COUNTRY' "$wf" && { echo "FAIL: WIFI_COUNTRY is the same everywhere, it must stay a literal"; exit 1; }
# shellcheck disable=SC2016
grep -q '\$WIFI_ENCRYPTION' "$wf" && { echo "FAIL: WIFI_ENCRYPTION is the same everywhere, it must stay a literal"; exit 1; }
grep -qx "ucidef_set_country 'CN'" "$wf" || { echo "FAIL: country is set on every board, that line must not be guarded"; exit 1; }

# builds.ini names devices the way the image is named; board_name returns the
# DTS compatible. Both spellings must hit the same branch.
run_generated "$wf" 'jdcloud_re-ss-01' | grep -qx "ucidef_set_wireless all Rilakkuma_Arthur sae-mixed Rilakkuma" || {
  echo "FAIL: underscore spelling of board_name must match too"; exit 1; }

# a board that is not listed falls back to the build-level value
run_generated "$wf" 'someone,else' | grep -qx "ucidef_set_wireless all Rilakkuma sae-mixed Rilakkuma" || {
  echo "FAIL: an unlisted board must fall back to the build-level value"; exit 1; }

# ---- an empty value in a narrower scope switches off what a wider one enabled ----
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' 'WIFI_COUNTRY = CN' 'WIFI_SSID_5G = R_5G' \
  '' '[a_one]' 'WIFI_SSID_5G =' > "$tmp/off.ini"
mkdir -p "$tmp/f_off"
sh "$sc" "$tmp/off.ini" "$tmp/f_off" b a_one a_two
wf="$tmp/f_off/etc/board.d/05-wifi-defaults"
syntax_ok "$wf"
run_generated "$wf" 'a,one' | grep -q "ucidef_set_wireless 5g" && {
  echo "FAIL: an empty value in a device scope must switch the 5g entry off"; exit 1; }
run_generated "$wf" 'a,two' | grep -q "ucidef_set_wireless 5g" || {
  echo "FAIL: the other device must keep the inherited 5g entry"; exit 1; }

# ---- guard: a 5 GHz SSID with no country code is fatal (otherwise you only
# ---- discover the 5 GHz defaults never applied after flashing) ----
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' \
  '' '[d_one]' 'WIFI_SSID_5G = R_5G' > "$tmp/no5gc.ini"
mkdir -p "$tmp/f_no5gc"
if sh "$sc" "$tmp/no5gc.ini" "$tmp/f_no5gc" b d_one 2>/dev/null; then
  echo "FAIL: WIFI_SSID_5G without WIFI_COUNTRY must fail"; exit 1
fi

# ---- nobody set LAN_IP: no script at all, OpenWrt's own 192.168.1.1 stands ----
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' > "$tmp/nolan.ini"
mkdir -p "$tmp/f_nolan"
sh "$sc" "$tmp/nolan.ini" "$tmp/f_nolan" b
[ -e "$tmp/f_nolan/etc/uci-defaults/95-network" ] && { echo "FAIL: no LAN_IP, no 95-network expected"; exit 1; }

# ---- two devices, two addresses ----
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' \
  '' '[jdcloud_re-cs-02]' 'LAN_IP = 192.168.8.1' \
  '' '[jdcloud_re-ss-01]' 'LAN_IP = 192.168.6.1' > "$tmp/lanips.ini"
mkdir -p "$tmp/f_lan"
sh "$sc" "$tmp/lanips.ini" "$tmp/f_lan" jdcloud jdcloud_re-cs-02 jdcloud_re-ss-01
nw="$tmp/f_lan/etc/uci-defaults/95-network"
syntax_ok "$nw"
run_generated "$nw" 'jdcloud,re-cs-02' | grep -qx "uci set network.lan.ipaddr=192.168.8.1" || { echo "FAIL: athena LAN address"; exit 1; }
run_generated "$nw" 'jdcloud,re-ss-01' | grep -qx "uci set network.lan.ipaddr=192.168.6.1" || { echo "FAIL: arthur LAN address"; exit 1; }
run_generated "$nw" 'jdcloud,re-ss-01' | grep -qx "uci commit network" || { echo "FAIL: uci commit missing"; exit 1; }

# an unconfigured board does nothing rather than inheriting some other box's
# address. The build-level value is empty, so this guard is genuinely needed --
# the opposite of the tr3000 case where everything is known at build time.
log=$(run_generated "$nw" 'someone,else')
echo "$log" | grep -q "uci set" && { echo "FAIL: an unconfigured board must not touch the LAN address (got: $log)"; exit 1; }

# uci-defaults run as 'sh $f && rm -f $f': a non-zero exit leaves the file in
# place and it runs again on every boot
( sed '/^\. \/lib\//d' "$nw" > "$tmp/rc.sh"
  board_name() { echo 'someone,else'; }
  uci() { :; }
  . "$tmp/rc.sh" ) || { echo "FAIL: 95-network must exit 0 on an unconfigured board"; exit 1; }

# ---- build-scope LAN_IP: shared by all, so no case, no variable, no guard ----
printf '%s\n' '[settings]' 'WIFI_SSID = R' 'WIFI_KEY = R' '' '[b]' 'LAN_IP = 10.0.0.1' > "$tmp/lanb.ini"
mkdir -p "$tmp/f_lanb"
sh "$sc" "$tmp/lanb.ini" "$tmp/f_lanb" b d_one d_two
nw="$tmp/f_lanb/etc/uci-defaults/95-network"
syntax_ok "$nw"
grep -q '^case ' "$nw" && { echo "FAIL: build-scope LAN_IP needs no case"; exit 1; }
grep -q '\[ -n ' "$nw" && { echo "FAIL: LAN_IP is set on every board, no guard expected"; exit 1; }
grep -qx "uci set network.lan.ipaddr='10.0.0.1'" "$nw" || { echo "FAIL: build-scope LAN address must be inlined"; exit 1; }

# ---- exactly one key varies in emptiness: only THAT key may get a runtime
# ---- test; WIFI_KEY is non-empty on every board here, and must never be
# ---- tested as a literal -- the build already knows the answer for it ----
printf '%s\n' '[settings]' 'WIFI_SSID = Rilakkuma' 'WIFI_KEY = pw' \
  '' '[e_one]' 'WIFI_SSID =' > "$tmp/onekey.ini"
mkdir -p "$tmp/f_onekey"
sh "$sc" "$tmp/onekey.ini" "$tmp/f_onekey" e e_one e_two
wf="$tmp/f_onekey/etc/board.d/05-wifi-defaults"
syntax_ok "$wf"
grep -q "\[ -n '" "$wf" && {
  echo "FAIL: WIFI_KEY never varies in emptiness, it must not be tested as a literal"; exit 1; }
# shellcheck disable=SC2016
grep -qx '\[ -n "\$WIFI_SSID" \] || exit 0' "$wf" || {
  echo "FAIL: WIFI_SSID alone varies in emptiness, it alone must be guarded"; exit 1; }
log=$(run_generated "$wf" 'e,one')
[ -z "$log" ] || { echo "FAIL: e_one has no SSID, the guard must exit before any call (got: $log)"; exit 1; }
run_generated "$wf" 'e,two' | grep -qx "ucidef_set_wireless all Rilakkuma sae-mixed pw" || {
  echo "FAIL: e_two keeps the inherited SSID and key"; exit 1; }

# ---- a value with a single quote would break the single quotes it gets
# ---- spliced into; ini_load only rejects '|' and treats '#' as a comment, so
# ---- the generator must catch this itself rather than shipping a first-boot
# ---- script that fails on the router ----
printf '%s\n' '[settings]' "WIFI_SSID = Eamon's WiFi" 'WIFI_KEY = pw' > "$tmp/quote.ini"
mkdir -p "$tmp/f_quote"
if sh "$sc" "$tmp/quote.ini" "$tmp/f_quote" 2>/dev/null; then
  echo "FAIL: a value containing a single quote must fail the generator"; exit 1
fi

echo "PASS: test-gen-firmware-defaults"
