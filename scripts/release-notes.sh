#!/bin/sh
# release-notes.sh <manifest> <settings.ini> <template.md> [package/custom dir]
# Fill the release notes template. The template decides layout and wording; every
# value comes from the pipeline, so nothing has to be declared twice.
# Env inputs: BUILD TARGET DEVICES SOURCE_REPO SOURCE_REF SOURCE_SHA PREV_SHA KERNEL DIGEST [DATE]
#
# {{name}} is replaced by its value. A line holding a placeholder that resolves
# to empty is dropped whole — that is the only conditional the template needs
# (no Wi-Fi configured, no previous release, a generic image with no devices).
# An unknown placeholder is fatal, so a typo cannot quietly blank a line.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
manifest=${1:-/dev/null}
settings=${2:-/dev/null}
template=${3:?usage: release-notes.sh <manifest> <settings.ini> <template.md> [package/custom dir]}
custom=${4:-}
[ -f "$template" ] || die "template not found: $template"

vals=''
if [ -f "$settings" ]; then vals=$(settings_load "$settings"); fi
get() { printf '%s\n' "$vals" | sed -n "s/^$1|//p" | head -n 1; }

# manifest lines are "<name> - <version>"; match on fields so '+' and '.' in
# package names stay literal
pkgver() { awk -v p="$1" '$1 == p && $2 == "-" { print $3; exit }' "$manifest"; }

# Every package our third-party repos define. Candidates come from the Makefiles
# they ship; a name the firmware does not contain prints no row, so guessing wide
# here is harmless and no list needs maintaining.
custom_packages() {
  [ -n "$custom" ] && [ -d "$custom" ] || return 0
  for repo in "$custom"/*; do
    [ -d "$repo" ] || continue
    find "$repo" -maxdepth 3 -name Makefile 2>/dev/null | sort | while IFS= read -r mk; do
      # every 'define Package/<name>' the Makefile declares literally
      sed -n 's/^define Package\/\([A-Za-z0-9._+-]*\)[[:space:]]*$/\1/p' "$mk"
      # luci packages declare none of their own — luci.mk names them after the dir
      basename "$(dirname "$mk")"
    done
  done
}

packages_table() {
  # 'if', not '&& printf': a candidate missing from the manifest is the normal
  # case, and as the last one it would make the whole loop exit non-zero
  custom_packages | awk '!seen[$0]++' | while IFS= read -r p; do
    v=$(pkgver "$p")
    if [ -n "$v" ]; then printf '| %s | %s |\n' "$p" "$v"; fi
  done
}

short=$(printf '%s' "${SOURCE_SHA:-}" | cut -c1-7)
devices=''
generic=''
if [ -n "${DEVICES:-}" ]; then
  for d in $DEVICES; do devices="$devices \`$d\`"; done
  devices=${devices# }
else
  generic="\`${TARGET:-}\`"
fi
changes=''
if [ -n "${PREV_SHA:-}" ] && [ "$PREV_SHA" != "${SOURCE_SHA:-}" ]; then
  changes="[upstream commits since previous build](https://github.com/${SOURCE_REPO}/compare/${PREV_SHA}...${SOURCE_SHA})"
fi
wifi_encryption=$(get WIFI_ENCRYPTION)
[ -n "$wifi_encryption" ] || wifi_encryption=sae-mixed

lookup() { # $1 placeholder name -> value ('' means: drop the line)
  case "$1" in
    build)           printf '%s' "${BUILD:-}" ;;
    kernel)          printf '%s' "${KERNEL:-unknown}" ;;
    date)            printf '%s' "${DATE:-}" ;;
    target)          printf '%s' "${TARGET:-}" ;;
    devices)         printf '%s' "$devices" ;;
    generic)         printf '%s' "$generic" ;;
    source)          printf "%s@\`%s\` (%s)" "${SOURCE_REPO:-}" "$short" "${SOURCE_REF:-}" ;;
    changes)         printf '%s' "$changes" ;;
    wifi_ssid)       get WIFI_SSID ;;
    wifi_key)        get WIFI_KEY ;;
    wifi_country)    get WIFI_COUNTRY ;;
    wifi_encryption) printf '%s' "$wifi_encryption" ;;
    build_by)        get BUILD_BY ;;
    *) die "unknown placeholder {{$1}} in $template" ;;
  esac
}

rows=$(packages_table)
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{packages}}'*) printf '%s\n' "$rows"; continue ;;
  esac
  drop=0
  while :; do
    case "$line" in *'{{'*'}}'*) ;; *) break ;; esac
    key=${line#*\{\{}; key=${key%%\}\}*}
    val=$(lookup "$key")
    [ -n "$val" ] || drop=1
    line="${line%%\{\{"$key"\}\}*}${val}${line#*\{\{"$key"\}\}}"
  done
  [ "$drop" = 1 ] && continue
  printf '%s\n' "$line"
done < "$template"

# consumed by make-matrix.sh (change detection) and publish-release.sh (previous SHA)
# shellcheck disable=SC2016
printf '\n<!-- builder-digest: `%s` -->\n<!-- source: %s@%s -->\n' \
  "${DIGEST:-}" "${SOURCE_REPO:-}" "${SOURCE_SHA:-}"
