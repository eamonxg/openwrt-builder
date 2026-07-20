#!/bin/sh
# release-notes.sh <meta-dir> <upload-dir> <settings.ini> <packages.ini> <template.md> [package/custom dir]
# Fill the release notes template. The template decides the prose; every value
# comes from the pipeline, so nothing has to be declared twice.
# Env inputs: BUILD TARGET DEVICES SOURCE_REPO SOURCE_REF SOURCE_SHA PREV_SHA
#             KERNEL DIGEST [DATE] [PKG_REPOS] [PREV_PKG_REPOS]
#
# {{name}} is replaced by its value. A line holding a placeholder that resolves
# to empty is dropped whole — that is the only conditional the template needs
# (no Wi-Fi configured, no previous release, no third-party repos).
# An unknown placeholder is fatal, so a typo cannot quietly blank a line.
#
# {{images}} {{packages}} {{package_repos}} are block placeholders: each owns a
# whole line and expands to many. A block emits its own '###' heading, so one
# with nothing to say leaves no dangling heading behind.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
meta=${1:-/dev/null}
updir=${2:-}
settings=${3:-/dev/null}
pkgini=${4:-/dev/null}
template=${5:?usage: release-notes.sh <meta-dir> <upload-dir> <settings.ini> <packages.ini> <template.md> [package/custom dir]}
custom=${6:-}
[ -f "$template" ] || die "template not found: $template"

vals=''
if [ -f "$settings" ]; then vals=$(settings_load "$settings"); fi
get() { printf '%s\n' "$vals" | sed -n "s/^$1|//p" | head -n 1; }

# ---------------------------------------------------------------- devices ----

# Device ids, longest first. 'cudy_tr3000-v1' is a prefix of
# 'cudy_tr3000-v1-ubootmod', so a file must be claimed by the LONGEST id it
# matches — otherwise every ubootmod artifact lands under the stock profile.
# Sorting here is what makes the first hit in device_of() the longest one.
device_ids() {
  if [ -f "$meta/profiles.json" ]; then
    jq -r '.profiles | keys[]' "$meta/profiles.json" 2>/dev/null && return 0
  fi
  # shellcheck disable=SC2086
  printf '%s\n' ${DEVICES:-}
}
# two orders, two jobs: $ids drives matching and must be longest-first;
# $ids_show drives the headings a human reads and stays in natural order.
ids=$(device_ids | awk 'NF { print length($0), $0 }' | sort -rn | cut -d' ' -f2- || true)
ids_show=$(device_ids | awk 'NF' | sort || true)

device_title() { # $1 device id -> "Cudy TR3000 v1", empty when unknown
  [ -f "$meta/profiles.json" ] || return 0
  jq -r --arg d "$1" '
    (.profiles[$d].titles // [])
    | map([.vendor, .model, .variant] | map(select(. != null and . != "")) | join(" "))
    | map(select(. != ""))
    | first // ""' "$meta/profiles.json" 2>/dev/null || true
}

device_of() { # $1 basename -> owning device id, empty when none matches
  _d=''
  for _c in $ids; do
    case "$1" in
      *"-$_c-"*|*"-$_c") _d=$_c; break ;;
    esac
  done
  printf '%s' "$_d"
}

manifest_of() { # $1 device id -> its manifest path, empty when none
  for _m in "$meta"/*-"$1".manifest; do
    if [ -f "$_m" ]; then printf '%s' "$_m"; return 0; fi
  done
  # a build without per-device rootfs has one manifest covering everything
  _all=$(find "$meta" -maxdepth 1 -name '*.manifest' 2>/dev/null)
  if [ "$(printf '%s\n' "$_all" | grep -c .)" = 1 ]; then printf '%s' "$_all"; fi
}

# ----------------------------------------------------------------- images ----

# What each file is for, decided by filename alone. No per-model knowledge lives
# here: models come and go, these suffixes are how OpenWrt names things.
# Order matters — an ubootmod initramfs is '...-initramfs-recovery.itb' and the
# first arm is the one that describes it correctly.
purpose() {
  case "$1" in
    *-initramfs-*)         printf 'First install: tftp-boot it from U-Boot; runs in RAM, writes nothing to flash' ;;
    *-recovery.itb)        printf 'U-Boot recovery image' ;;
    *preloader.bin)        printf 'Bootloader stage 1, written to the BL2 partition (only when replacing U-Boot)' ;;
    *bl31-uboot.fip)       printf 'ATF plus U-Boot itself, written to the FIP partition (only when replacing U-Boot)' ;;
    *-sysupgrade.*)        printf 'Upgrade: flash from a running OpenWrt via LuCI or sysupgrade' ;;
    *-factory.*)           printf 'Install from the vendor firmware' ;;
    *-combined-efi.img.gz) printf 'UEFI whole-disk image, dd to the target disk' ;;
    *-combined.img.gz)     printf 'Legacy BIOS whole-disk image, dd to the target disk' ;;
    *-efi.iso)             printf 'UEFI bootable install media' ;;
    *.iso)                 printf 'Legacy BIOS bootable install media' ;;
  esac
}

# The image list is read from the upload dir, not from profiles.json: what we are
# about to publish is the only truth, so the notes cannot name a file that will
# not be there.
images_block() {
  [ -n "$updir" ] && [ -d "$updir" ] || return 0
  _files=$(find "$updir" -maxdepth 1 -type f ! -name sha256sums -exec basename {} \; | sort)
  [ -n "$_files" ] || return 0
  _pairs=''
  for _f in $_files; do
    _pairs="$_pairs$(device_of "$_f")|$_f
"
  done
  printf '### Images & flashing\n'
  # a single nameless profile (x86's 'generic') gets no heading: there is nothing
  # to tell apart, and '#### generic' would only take up room
  _bare=0
  if [ "$(printf '%s\n' "$ids_show" | grep -c .)" = 1 ] && [ -z "$(device_title "$ids_show")" ]; then
    _bare=1
  fi
  # '' last: files no device claimed. Surfacing them beats hiding them — an
  # unexpected artifact is exactly what someone needs to see.
  for _d in $ids_show ''; do
    _sel=$(printf '%s' "$_pairs" | sed -n "s/^$_d|//p")
    [ -n "$_sel" ] || continue
    # backticks here are markdown; keeping them in single quotes says so and
    # keeps them out of any printf format string
    if [ -z "$_d" ]; then
      printf '\n#### Unclassified\n'
    elif [ "$_bare" = 0 ]; then
      _h='`'$_d'`'
      _t=$(device_title "$_d")
      if [ -n "$_t" ]; then _h="$_t · $_h"; fi
      printf '\n#### %s\n' "$_h"
    fi
    printf '\n| File | Purpose |\n|---|---|\n'
    for _f in $_sel; do
      # shellcheck disable=SC2016
      printf '| `%s` | %s |\n' "$_f" "$(purpose "$_f")"
    done
  done
}

# --------------------------------------------------------------- packages ----

# manifest lines are "<name> - <version>"; match on fields so '+' and '.' in
# package names stay literal
pkgver() { awk -v p="$2" '$1 == p && $2 == "-" { print $3; exit }' "$1"; }

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

# One row per package. When a build's devices do not all carry the same set —
# tr3000 gives nikki to the 256 MB variant only — a column per device shows who
# has what. When they do agree the extra columns say nothing, so they are dropped.
packages_block() {
  _cands=$(custom_packages | awk '!seen[$0]++')
  [ -n "$_cands" ] || return 0
  _devs=''
  for _d in $ids_show; do
    if [ -n "$(manifest_of "$_d")" ]; then _devs="$_devs $_d"; fi
  done
  _lone=''
  if [ -z "$_devs" ]; then
    _lone=$(find "$meta" -maxdepth 1 -name '*.manifest' 2>/dev/null | head -n 1)
    [ -n "$_lone" ] || return 0
  fi

  # rows are "name|version|flag flag ..." aligned to $_devs (no flags when _lone).
  # $_allflags accumulates just the flags: deciding "do the devices differ?" by
  # grepping whole rows would hit the '0' in a version string like 1.1.1-r20260712
  _rows=''; _allflags=''
  for _p in $_cands; do
    _ver=''; _flags=''
    if [ -n "$_lone" ]; then
      _ver=$(pkgver "$_lone" "$_p")
    else
      for _d in $_devs; do
        _v=$(pkgver "$(manifest_of "$_d")" "$_p")
        if [ -n "$_v" ]; then
          [ -n "$_ver" ] || _ver=$_v
          _flags="$_flags 1"
        else
          _flags="$_flags 0"
        fi
      done
    fi
    # 'if', not '&& ...': a candidate missing from every manifest is the normal
    # case, and as the last one it would make the whole loop exit non-zero
    if [ -n "$_ver" ]; then
      _rows="$_rows$_p|$_ver|$_flags
"
      _allflags="$_allflags$_flags"
    fi
  done
  [ -n "$_rows" ] || return 0

  printf '### Bundled packages\n\n'
  # every package on every device -> the per-device columns would say nothing
  case "$_allflags" in *0*) _differ=1 ;; *) _differ=0 ;; esac
  if [ -n "$_lone" ] || [ "$_differ" = 0 ]; then
    printf '| Package | Version |\n|---|---|\n'
    printf '%s' "$_rows" | while IFS='|' read -r _p _v _; do
      [ -n "$_p" ] && printf '| %s | %s |\n' "$_p" "$_v"
    done
    return 0
  fi
  _hdr='| Package | Version |'; _sep='|---|---|'
  for _d in $_devs; do
    _hdr="$_hdr $_d |"; _sep="$_sep---|"
  done
  printf '%s\n%s\n' "$_hdr" "$_sep"
  printf '%s' "$_rows" | while IFS='|' read -r _p _v _fl; do
    [ -n "$_p" ] || continue
    _line="| $_p | $_v |"
    for _f in $_fl; do
      if [ "$_f" = 1 ]; then _line="$_line ✓ |"; else _line="$_line — |"; fi
    done
    printf '%s\n' "$_line"
  done
}

# ------------------------------------------------------------ plugin repos ----

gh_slug() { # $1 git url -> owner/repo, empty when it is not a github url
  case "$1" in
    https://github.com/*) _s=${1#https://github.com/}; printf '%s' "${_s%.git}" ;;
  esac
}

# PKG_REPOS is "name@sha ..." as resolved by make-matrix.sh; PREV_PKG_REPOS is
# the same list recorded by the previous release. Only a compare link is offered:
# a commit count would need one API call per repo and would cost this script its
# offline testability.
repos_block() {
  [ -n "${PKG_REPOS:-}" ] || return 0
  _urls=''
  if [ -f "$pkgini" ]; then _urls=$(packages_load "$pkgini"); fi
  _rows=''; _n=0; _changed=0
  for _e in $PKG_REPOS; do
    _name=${_e%@*}; _sha=${_e##*@}
    _n=$((_n + 1))
    _prev=$(printf '%s' "${PREV_PKG_REPOS:-}" | tr ' ' '\n' | sed -n "s/^$_name@//p" | head -n 1)
    _url=$(printf '%s\n' "$_urls" | sed -n "s/^$_name|//p" | head -n 1)
    _url=${_url%%|*}
    _slug=$(gh_slug "$_url")
    if [ -z "$_prev" ]; then
      _note='first recorded'
    elif [ "$_prev" = "$_sha" ]; then
      _note='unchanged'
    else
      _changed=$((_changed + 1))
      if [ -n "$_slug" ]; then
        _note="[compare with previous build](https://github.com/$_slug/compare/$_prev...$_sha)"
      else
        _note="$(printf '%s' "$_prev" | cut -c1-7) → $(printf '%s' "$_sha" | cut -c1-7)"
      fi
    fi
    _rows="$_rows| $_name | \`$(printf '%s' "$_sha" | cut -c1-7)\` | $_note |
"
  done
  [ -n "$_rows" ] || return 0
  printf '<details>\n<summary>Plugin sources (%s repos, %s updated)</summary>\n\n' "$_n" "$_changed"
  printf '| Repository | Version | Change |\n|---|---|---|\n%s\n</details>\n' "$_rows"
}

# ---------------------------------------------------------------- scalars ----

short=$(printf '%s' "${SOURCE_SHA:-}" | cut -c1-7)
changes=''
if [ -n "${PREV_SHA:-}" ] && [ "$PREV_SHA" != "${SOURCE_SHA:-}" ]; then
  changes="[upstream commits since previous build](https://github.com/${SOURCE_REPO}/compare/${PREV_SHA}...${SOURCE_SHA})"
fi
wifi_encryption=$(get WIFI_ENCRYPTION)
[ -n "$wifi_encryption" ] || wifi_encryption=sae-mixed
# DATE is YYYYMMDD-HHMM, the suffix that keeps same-day tags apart. Spelled out
# here so the '-2102' in a tag name means something to whoever reads the release.
built_at=${DATE:-}
case "${DATE:-}" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9])
    _dd=${DATE%-*}; _tt=${DATE#*-}
    built_at="$(printf %s "$_dd" | cut -c1-4)-$(printf %s "$_dd" | cut -c5-6)-$(printf %s "$_dd" | cut -c7-8)"
    built_at="$built_at $(printf %s "$_tt" | cut -c1-2):$(printf %s "$_tt" | cut -c3-4) (Asia/Shanghai)"
    ;;
esac

lookup() { # $1 placeholder name -> value ('' means: drop the line)
  case "$1" in
    build)           printf '%s' "${BUILD:-}" ;;
    kernel)          printf '%s' "${KERNEL:-unknown}" ;;
    built_at)        printf '%s' "$built_at" ;;
    target)          printf '%s' "${TARGET:-}" ;;
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

blk_images=$(images_block)
blk_packages=$(packages_block)
blk_repos=$(repos_block)

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{images}}'*)        [ -n "$blk_images" ]   && printf '%s\n' "$blk_images";   continue ;;
    *'{{packages}}'*)      [ -n "$blk_packages" ] && printf '%s\n' "$blk_packages"; continue ;;
    *'{{package_repos}}'*) [ -n "$blk_repos" ]    && printf '%s\n' "$blk_repos";    continue ;;
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

# consumed by make-matrix.sh (change detection) and publish-release.sh (previous
# source SHA and previous plugin-repo SHAs)
# shellcheck disable=SC2016
printf '\n<!-- builder-digest: `%s` -->\n<!-- source: %s@%s -->\n' \
  "${DIGEST:-}" "${SOURCE_REPO:-}" "${SOURCE_SHA:-}"
if [ -n "${PKG_REPOS:-}" ]; then
  printf '<!-- packages: %s -->\n' "$PKG_REPOS"
fi
