#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/check-selected.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

printf '%s\n' 'CONFIG_PACKAGE_luci-app-passwall2=y' > "$tmp/frag.config"
cat > "$tmp/good.config" <<'EOF'
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y
CONFIG_PACKAGE_luci-app-passwall2=y
EOF
sh "$sc" "$tmp/good.config" qualcommax/ipq60xx "$tmp/frag.config" jdcloud_re-ss-01 \
  || { echo "FAIL: complete config must pass"; exit 1; }

# device dropped by defconfig -> must fail
cat > "$tmp/bad.iniig" <<'EOF'
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_PACKAGE_luci-app-passwall2=y
EOF
if sh "$sc" "$tmp/bad.iniig" qualcommax/ipq60xx "$tmp/frag.config" jdcloud_re-ss-01 2>/dev/null; then
  echo "FAIL: missing device must fail"; exit 1
fi

# package dropped by defconfig -> must fail
cat > "$tmp/noplug.config" <<'EOF'
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y
EOF
if sh "$sc" "$tmp/noplug.config" qualcommax/ipq60xx "$tmp/frag.config" jdcloud_re-ss-01 2>/dev/null; then
  echo "FAIL: missing package must fail"; exit 1
fi

# --- =m and per-device package lists (the cudy_tr3000-256mb-v1 shape) ---
tg=mediatek/filogic
cat > "$tmp/dev.config" <<'EOF'
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cudy_tr3000-v1=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1=y
CONFIG_PACKAGE_luci-app-nikki=m
EOF
cat > "$tmp/dev.frag" <<'EOF'
CONFIG_PACKAGE_luci-app-nikki=m
CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1="luci-app-nikki"
EOF
sh "$sc" "$tmp/dev.config" "$tg" "$tmp/dev.frag" cudy_tr3000-v1 cudy_tr3000-256mb-v1 \
  || { echo "FAIL: valid per-device list must pass"; exit 1; }

# =m dropped by defconfig -> must fail (the old guard only looked at =y)
grep -v 'CONFIG_PACKAGE_luci-app-nikki=m' "$tmp/dev.config" > "$tmp/nom.config"
if sh "$sc" "$tmp/nom.config" "$tg" "$tmp/dev.frag" cudy_tr3000-256mb-v1 2>/dev/null; then
  echo "FAIL: dropped =m package must fail"; exit 1
fi

# listed for a device this build does not select (typo in the device name) -> must fail
printf '%s\n' 'CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v2="luci-app-nikki"' > "$tmp/baddev.frag"
if sh "$sc" "$tmp/dev.config" "$tg" "$tmp/baddev.frag" cudy_tr3000-256mb-v1 2>/dev/null; then
  echo "FAIL: per-device list naming an unselected device must fail"; exit 1
fi

# named for a device but nothing builds it (the =m line forgotten) -> must fail
printf '%s\n' 'CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1="luci-app-ghost"' > "$tmp/unbuilt.frag"
if sh "$sc" "$tmp/dev.config" "$tg" "$tmp/unbuilt.frag" cudy_tr3000-256mb-v1 2>/dev/null; then
  echo "FAIL: package in a per-device list that nothing builds must fail"; exit 1
fi

# '-pkg' removes a package: there is nothing to build, so it must not be demanded
printf '%s\n' 'CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1="-wpad-mini luci-app-nikki"' > "$tmp/minus.frag"
sh "$sc" "$tmp/dev.config" "$tg" "$tmp/minus.frag" cudy_tr3000-256mb-v1 \
  || { echo "FAIL: '-pkg' removal entries must not be demanded as buildable"; exit 1; }

# multi-package value: every name is checked, so one bad name fails the lot
printf '%s\n' 'CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1="luci-app-nikki luci-app-ghost"' > "$tmp/multi.frag"
if sh "$sc" "$tmp/dev.config" "$tg" "$tmp/multi.frag" cudy_tr3000-256mb-v1 2>/dev/null; then
  echo "FAIL: every package in a multi-package value must be checked"; exit 1
fi
echo "PASS: test-check-selected"
