#!/bin/sh
# gen-config.sh <board/subtarget> [device...] — print the target/device selection config fragment
set -eu
[ $# -ge 1 ] || { echo "usage: gen-config.sh <board/subtarget> [device...]" >&2; exit 1; }
tgt=$1; shift
board=${tgt%%/*}
sub=${tgt#*/}
printf 'CONFIG_TARGET_%s=y\n' "$board"
printf 'CONFIG_TARGET_%s_%s=y\n' "$board" "$sub"
if [ $# -gt 0 ]; then
  printf 'CONFIG_TARGET_MULTI_PROFILE=y\n'
  printf 'CONFIG_TARGET_PER_DEVICE_ROOTFS=y\n'
  for d in "$@"; do
    printf 'CONFIG_TARGET_DEVICE_%s_%s_DEVICE_%s=y\n' "$board" "$sub" "$d"
  done
fi
