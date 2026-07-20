#!/bin/sh
# check-selected.sh <.config> <board/subtarget> <fragment> [device...]
# fragment = a config fragment we appended to .config (common.config or a build
# overlay). defconfig silently drops symbols the source tree does not know —
# this guard turns "silently wrong firmware" into an early failure.
# Checked: the target, each device, every CONFIG_PACKAGE_*=y/=m line, and every
# package named in a per-device list — that last symbol carries no 'select', so
# a package nothing else builds would go missing without a word.
set -eu
cfg=$1; tgt=$2; frag=$3; shift 3
board=${tgt%%/*}
sub=${tgt#*/}
fail=0

require() { # $1 expected exact line  $2 reason
  if ! grep -qx "$1" "$cfg"; then
    echo "guard failed: $2 ($1)" >&2
    fail=1
  fi
}

require "CONFIG_TARGET_${board}_${sub}=y" "target ${tgt} not supported by this source tree"
for d in "$@"; do
  require "CONFIG_TARGET_DEVICE_${board}_${sub}_DEVICE_${d}=y" \
    "device ${d} not supported by this source tree, check source/ref of its builds.ini section"
done

# =y lands in every rootfs of this build; =m only builds the .ipk so a
# per-device list below can pick it up. Both must survive defconfig.
# config lines contain no whitespace, per-line word splitting is safe
# shellcheck disable=SC2013
for line in $(sed -n 's/^\(CONFIG_PACKAGE_[A-Za-z0-9_-]*=[ym]\)$/\1/p' "$frag"); do
  require "$line" "package dropped by defconfig (missing dependency or nonexistent)"
done

# per-device lists: CONFIG_TARGET_DEVICE_PACKAGES_<board>_<sub>_DEVICE_<dev>="pkg pkg"
# Values hold spaces, so read line by line instead of word-splitting the file.
pdp_prefix="CONFIG_TARGET_DEVICE_PACKAGES_${board}_${sub}_DEVICE_"
pdp=$(grep "^${pdp_prefix}" "$frag" || true)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  dev=${line#"$pdp_prefix"}; dev=${dev%%=*}
  pkgs=$(printf '%s' "${line#*=}" | tr -d '"')
  require "CONFIG_TARGET_DEVICE_${board}_${sub}_DEVICE_${dev}=y" \
    "per-device package list targets ${dev}, which this build does not select"
  for p in $pkgs; do
    case "$p" in -*) continue ;; esac   # '-pkg' removes a package, nothing to build
    if ! grep -qx "CONFIG_PACKAGE_${p}=y" "$cfg" && ! grep -qx "CONFIG_PACKAGE_${p}=m" "$cfg"; then
      echo "guard failed: ${p} is listed for device ${dev} but nothing builds it, add CONFIG_PACKAGE_${p}=m (CONFIG_PACKAGE_${p})" >&2
      fail=1
    fi
  done
done <<EOF
$pdp
EOF
exit $fail
