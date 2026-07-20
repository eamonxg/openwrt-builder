#!/bin/sh
set -eu
gen="$(dirname "$0")/../scripts/gen-config.sh"

out=$(sh "$gen" qualcommax/ipq60xx jdcloud_re-cs-02 jdcloud_re-ss-01)
echo "$out" | grep -qx 'CONFIG_TARGET_qualcommax=y' || { echo "FAIL: board"; exit 1; }
echo "$out" | grep -qx 'CONFIG_TARGET_qualcommax_ipq60xx=y' || { echo "FAIL: subtarget"; exit 1; }
echo "$out" | grep -qx 'CONFIG_TARGET_MULTI_PROFILE=y' || { echo "FAIL: multi-profile"; exit 1; }
echo "$out" | grep -qx 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y' \
  || { echo "FAIL: device line"; exit 1; }

out=$(sh "$gen" x86/64)
echo "$out" | grep -qx 'CONFIG_TARGET_x86_64=y' || { echo "FAIL: x86 subtarget"; exit 1; }
echo "$out" | grep -q 'MULTI_PROFILE' && { echo "FAIL: x86 must not enable MULTI_PROFILE"; exit 1; }
echo "PASS: test-gen-config"
