#!/bin/sh
# release-notes.sh <meta-dir> <upload-dir> <settings.ini> <packages.ini> <template.md> [package/custom dir]
# Fill the release notes template. The template decides the prose; every value
# comes from the pipeline, so nothing has to be declared twice.
# Env inputs: BUILD TARGET DEVICES SOURCE_REPO SOURCE_REF SOURCE_SHA PREV_SHA
#             KERNEL DIGEST [PKG_REPOS] [PREV_PKG_REPOS]
#             [UPSTREAM_LOG] [UPSTREAM_TOTAL] [PLUGIN_LOG]
#
# The *_LOG inputs are commit subjects fetched by publish-release.sh. Rendering
# stays here, fetching stays there: this script keeps working offline, so the
# tests can feed it fixtures instead of a network.
#
# {{name}} is replaced by its value. A line holding a placeholder that resolves
# to empty is dropped whole — that is the only conditional the template needs
# (no Wi-Fi configured, no previous release, no third-party repos).
# An unknown placeholder is fatal, so a typo cannot quietly blank a line.
#
# {{images}} {{packages}} {{upstream}} {{plugin_changes}} are block
# placeholders: each owns a whole line and expands to many. A block emits its
# own heading, so one with nothing to say leaves no dangling heading behind.
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
if [ -f "$settings" ]; then vals=$(settings_load "$settings" "${BUILD:-}"); fi
get() { printf '%s\n' "$vals" | sed -n "s/^$1|//p" | head -n 1; }

# setting <key> [default] -> the value every device of this build agrees on,
# empty when they do not. A value that differs between devices cannot be stated
# as one string, and the template already drops a line whose placeholder is
# empty -- printing a value that is wrong for half the devices would be worse
# than printing none. The default is applied per device before comparing, so it
# cannot paper over a disagreement.
setting() {
  _sk=$1; _sdef=${2:-}
  if [ ! -f "$settings" ] || [ -z "${DEVICES:-}" ]; then
    # No devices listed -> the build-level value is literally what ships.
    _sv=$(get "$_sk"); [ -n "$_sv" ] || _sv=$_sdef
    printf '%s' "$_sv"
    return 0
  fi
  # With devices, what ships is each device's value; the build-level one is only
  # the fallback for a board that is none of them, and that is not a board this
  # image would be flashed onto. So the devices are compared against each other,
  # not against a baseline they may all deviate from -- devices that all set the
  # same value explicitly agree exactly as much as devices that all inherit it.
  _sv=''; _sfirst=1
  for _sdev in ${DEVICES:-}; do
    # captured before the pipe: a die() inside settings_load would be swallowed
    _srec=$(settings_load "$settings" "${BUILD:-}" "$_sdev")
    _sx=$(printf '%s\n' "$_srec" | sed -n "s/^$_sk|//p" | head -n 1)
    [ -n "$_sx" ] || _sx=$_sdef
    if [ "$_sfirst" = 1 ]; then
      _sv=$_sx; _sfirst=0
    elif [ "$_sx" != "$_sv" ]; then
      return 0
    fi
  done
  printf '%s' "$_sv"
}

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
# $ids_show drives the columns a human reads and stays in natural order.
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

# What a file is for, decided by filename alone. No per-model knowledge lives
# here: models come and go, these suffixes are how OpenWrt names things.
# Order matters twice over:
#   - an ubootmod initramfs is '...-initramfs-recovery.itb', and the initramfs
#     arm is the one that describes it correctly;
#   - the rootfs-specific x86 arms must precede the generic ones, or ext4 and
#     squashfs images collapse into one indistinguishable description — which is
#     exactly the choice a reader is trying to make.
use_of() { # $1 basename -> use key, empty when the name says nothing
  case "$1" in
    *-initramfs-*)                  printf 'tftp' ;;
    *-recovery.itb)                 printf 'recovery' ;;
    *preloader.bin)                 printf 'bl2' ;;
    *bl31-uboot.fip)                printf 'fip' ;;
    *-sysupgrade.*)                 printf 'upgrade' ;;
    *-factory.*)                    printf 'factory' ;;
    *-ext4-combined-efi.img.gz)     printf 'efi-ext4' ;;
    *-ext4-combined.img.gz)         printf 'bios-ext4' ;;
    *-squashfs-combined-efi.img.gz) printf 'efi-squashfs' ;;
    *-squashfs-combined.img.gz)     printf 'bios-squashfs' ;;
    *-combined-efi.img.gz)          printf 'efi-disk' ;;
    *-combined.img.gz)              printf 'bios-disk' ;;
    *-efi.iso)                      printf 'efi-iso' ;;
    *.iso)                          printf 'bios-iso' ;;
    mt[0-9]*-ram-*-bl2.bin)         printf 'ddr' ;;
  esac
}

use_meta() { # $1 use key -> "label|what to do with it"
  case "$1" in
    tftp)          printf 'First install|tftp-boot it from U-Boot; runs in RAM, writes nothing to flash' ;;
    upgrade)       printf 'Upgrade|flash from a running OpenWrt via LuCI or sysupgrade' ;;
    factory)       printf 'Factory|install from the vendor firmware' ;;
    recovery)      printf 'Recovery|U-Boot recovery image' ;;
    bl2)           printf 'BL2|bootloader stage 1, written to the BL2 partition (only when replacing U-Boot)' ;;
    fip)           printf 'FIP|ATF plus U-Boot itself, written to the FIP partition (only when replacing U-Boot)' ;;
    efi-ext4)      printf 'UEFI whole-disk, ext4|writable, resizable rootfs; dd to the target disk' ;;
    bios-ext4)     printf 'BIOS whole-disk, ext4|writable, resizable rootfs; dd to the target disk' ;;
    efi-squashfs)  printf 'UEFI whole-disk, squashfs|read-only rootfs plus overlay, supports failsafe reset; dd to the target disk' ;;
    bios-squashfs) printf 'BIOS whole-disk, squashfs|read-only rootfs plus overlay, supports failsafe reset; dd to the target disk' ;;
    efi-disk)      printf 'UEFI whole-disk|dd to the target disk' ;;
    bios-disk)     printf 'BIOS whole-disk|dd to the target disk' ;;
    efi-iso)       printf 'UEFI install media|bootable ISO, UEFI' ;;
    bios-iso)      printf 'BIOS install media|bootable ISO, legacy BIOS' ;;
    ddr)           printf 'DDR blob|MediaTek RAM training blob used by the ubootmod flow; only the one matching this board applies' ;;
  esac
}

# Rows follow install order, not the alphabet: a reader works down this list.
# A key with no file this build simply prints no row.
USE_ORDER='tftp upgrade factory recovery bl2 fip
efi-ext4 bios-ext4 efi-squashfs bios-squashfs efi-disk bios-disk efi-iso bios-iso ddr'

# Every artifact of a build shares one prefix, derived from TARGET rather than
# guessed by comparing filenames: x86/64 -> 'openwrt-x86-64-'. Stripping it is
# what keeps a transposed row narrow enough to read.
img_prefix() {
  [ -n "${TARGET:-}" ] || return 0
  printf 'openwrt-%s-' "$(printf '%s' "$TARGET" | tr '/' '-')"
}

# The image list is read from the upload dir, not from profiles.json: what we are
# about to publish is the only truth, so the notes cannot name a file that will
# not be there.
#
# Transposed on purpose. use_of() keys off the filename suffix, so every device
# of a build gets the SAME description for its same-type file — printed once per
# device it is pure repetition, and with three profiles it drowns the table. As
# a column header it is stated once, and the empty cells then say something the
# old per-device tables could not: only the ubootmod profile takes a BL2 or FIP.
images_block() {
  [ -n "$updir" ] && [ -d "$updir" ] || return 0
  _files=$(find "$updir" -maxdepth 1 -type f ! -name sha256sums -exec basename {} \; | sort)
  [ -n "$_files" ] || return 0

  _pfx=$(img_prefix)
  # rows are "device|usekey|filename"; device is empty when nothing claims it
  _rows=''
  for _f in $_files; do
    _rows="$_rows$(device_of "$_f")|$(use_of "$_f")|$_f
"
  done

  # columns: devices that actually got a file, in the order a human reads them.
  # Counted as they are collected — splitting the list again later to measure it
  # is the kind of thing that works until a device id contains a glob character.
  _cols=''; _ncols=0
  for _d in $ids_show; do
    case "
$_rows" in
      *"
$_d|"*) _cols="$_cols $_d"; _ncols=$((_ncols + 1)) ;;
    esac
  done

  printf '### Images & flashing\n\n'

  # One device needs no column of its own: there is nothing to tell apart, and
  # its name would only push the filenames further right.
  _multi=0
  if [ "$_ncols" -gt 1 ]; then _multi=1; fi

  if [ "$_multi" = 1 ]; then
    _hdr='| Use |'; _sep='|---|'
    for _d in $_cols; do
      _t=$(device_title "$_d"); [ -n "$_t" ] || _t=$_d
      _hdr="$_hdr $_t |"; _sep="$_sep---|"
    done
    printf '%s\n%s\n' "$_hdr" "$_sep"
  else
    printf '| Use | File |\n|---|---|\n'
  fi

  _stripped=0
  for _k in $USE_ORDER; do
    _lbl=$(use_meta "$_k")
    [ -n "$_lbl" ] || continue
    _line="| **${_lbl%%|*}** — ${_lbl#*|} |"
    _any=0
    for _d in $_cols; do
      _cell=''
      for _n in $(printf '%s' "$_rows" | sed -n "s/^$_d|$_k|//p"); do
        case "$_n" in
          "$_pfx"*) _short=${_n#"$_pfx"}; _stripped=1 ;;
          *) _short=$_n ;;
        esac
        _cell="$_cell${_cell:+<br>}\`$_short\`"
        _any=1
      done
      [ -n "$_cell" ] || _cell='—'
      _line="$_line $_cell |"
    done
    if [ "$_any" = 1 ]; then printf '%s\n' "$_line"; fi
  done

  # shellcheck disable=SC2016
  if [ "$_stripped" = 1 ]; then
    printf '\nAll filenames start with `%s`.\n' "$_pfx"
  fi

  # Files no device claimed. Surfacing them beats hiding them — an unexpected
  # artifact is exactly what someone needs to see — but a table of them, with a
  # blank Purpose column because no device gives them meaning, is worse than a
  # sentence. So: one line per use, and every name spelled out. A count with one
  # sample name would read as N copies of that file, and "only the one matching
  # this board applies" is advice nobody can act on without the full list.
  _unc=$(printf '%s' "$_rows" | sed -n 's/^|//p')
  if [ -n "$_unc" ]; then
    for _k in $USE_ORDER unknown; do
      if [ "$_k" = unknown ]; then
        _sel=$(printf '%s\n' "$_unc" | sed -n 's/^|//p')
        _desc='not claimed by any device of this build'
      else
        _sel=$(printf '%s\n' "$_unc" | sed -n "s/^$_k|//p")
        _lbl=$(use_meta "$_k"); _desc=${_lbl#*|}
      fi
      [ -n "$_sel" ] || continue
      _names=$(printf '%s\n' "$_sel" | awk 'NF { printf "%s`%s`", (n++ ? ", " : ""), $0 }')
      printf '\nPlus %s — %s.\n' "$_names" "$_desc"
    done
  fi
}

# --------------------------------------------------------------- packages ----

# manifest lines are "<name> - <version>"; match on fields so '+' and '.' in
# package names stay literal
pkgver() { awk -v p="$2" '$1 == p && $2 == "-" { print $3; exit }' "$1"; }

# Every package our third-party repos define, tagged with the repo that defines
# it. Candidates come from the Makefiles they ship; a name the firmware does not
# contain prints no row, so guessing wide here is harmless and no list needs
# maintaining. The repo tag is what lets one table answer both "what is
# installed" and "where did it come from".
custom_packages() { # -> repo|package
  [ -n "$custom" ] && [ -d "$custom" ] || return 0
  for repo in "$custom"/*; do
    [ -d "$repo" ] || continue
    _rn=$(basename "$repo")
    find "$repo" -maxdepth 3 -name Makefile 2>/dev/null | sort | while IFS= read -r mk; do
      # every 'define Package/<name>' the Makefile declares literally
      sed -n "s/^define Package\/\([A-Za-z0-9._+-]*\)[[:space:]]*$/$_rn|\1/p" "$mk"
      # luci packages declare none of their own — luci.mk names them after the dir
      printf '%s|%s\n' "$_rn" "$(basename "$(dirname "$mk")")"
    done
  done
}

gh_slug() { # $1 git url -> owner/repo, empty when it is not a github url
  case "$1" in
    https://github.com/*) _s=${1#https://github.com/}; printf '%s' "${_s%.git}" ;;
  esac
}

repo_url() { # $1 repo name -> git url from packages.ini
  [ -f "$pkgini" ] || return 0
  _u=$(packages_load "$pkgini" | sed -n "s/^$1|//p" | head -n 1)
  printf '%s' "${_u%%|*}"
}

repo_sha() { # $1 repo name -> "`abc1234`" plus ↑ when it moved since last build
  _rs=$(printf '%s' "${PKG_REPOS:-}" | tr ' ' '\n' | sed -n "s/^$1@//p" | head -n 1)
  [ -n "$_rs" ] || return 0
  # shellcheck disable=SC2016
  printf '`%s`' "$(printf '%s' "$_rs" | cut -c1-7)"
  _rp=$(printf '%s' "${PREV_PKG_REPOS:-}" | tr ' ' '\n' | sed -n "s/^$1@//p" | head -n 1)
  # first sighting is not a change: there is nothing to have changed from
  if [ -n "$_rp" ] && [ "$_rp" != "$_rs" ]; then printf ' ↑'; fi
}

# One row per package: what it is, which version shipped, and which repo it came
# from. When a build's devices do not all carry the same set — tr3000 gives nikki
# to the 256 MB variant only — a column per device shows who has what. When they
# do agree the extra columns say nothing, so they are dropped.
packages_block() {
  _cands=$(custom_packages | awk -F'|' 'NF == 2 && !seen[$2]++')
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

  # rows are "name|version|repo|flag flag ..." aligned to $_devs (no flags when
  # _lone). $_allflags accumulates just the flags: deciding "do the devices
  # differ?" by grepping whole rows would hit the '0' in a version string like
  # 1.1.1-r20260712
  _rows=''; _allflags=''; _seen_repos=''
  for _c in $_cands; do
    _rn=${_c%%|*}; _p=${_c#*|}
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
      _rows="$_rows$_p|$_ver|$_rn|$_flags
"
      _allflags="$_allflags$_flags"
      _seen_repos="$_seen_repos $_rn"
    fi
  done
  [ -n "$_rows" ] || return 0

  printf '### Packages\n\n'
  # every package on every device -> the per-device columns would say nothing
  case "$_allflags" in *0*) _differ=1 ;; *) _differ=0 ;; esac
  _hdr='| Package | Version | Source |'; _sep='|---|---|---|'
  if [ -z "$_lone" ] && [ "$_differ" = 1 ]; then
    for _d in $_devs; do
      _hdr="$_hdr $_d |"; _sep="$_sep---|"
    done
  fi
  printf '%s\n%s\n' "$_hdr" "$_sep"
  printf '%s' "$_rows" | while IFS='|' read -r _p _v _rn _fl; do
    [ -n "$_p" ] || continue
    _src=$_rn
    _rsha=$(repo_sha "$_rn")
    if [ -n "$_rsha" ]; then _src="$_rn $_rsha"; fi
    _line="| $_p | $_v | $_src |"
    if [ -z "$_lone" ] && [ "$_differ" = 1 ]; then
      for _f in $_fl; do
        if [ "$_f" = 1 ]; then _line="$_line ✓ |"; else _line="$_line — |"; fi
      done
    fi
    printf '%s\n' "$_line"
  done

  # A repo that shipped nothing has no row, and silence there reads as "not
  # cloned" when it actually means "cloned, but this build enables none of it" —
  # the difference between a config that is off and a config that is broken.
  _idle=''
  for _e in ${PKG_REPOS:-}; do
    _rn=${_e%@*}
    case " $_seen_repos " in
      *" $_rn "*) ;;
      *) _idle="$_idle${_idle:+, }$_rn $(repo_sha "$_rn")" ;;
    esac
  done
  # 'if', not '&& ...': as the function's last statement a false test would make
  # it return 1, and under set -e the caller's $(...) dies with it
  if [ -n "$_idle" ]; then
    printf '\n%s — cloned, not enabled in this build.\n' "$_idle"
  fi
}

# ---------------------------------------------------------------- changes ----

# Commit subjects, not a link. "What changed upstream" is the question a reader
# actually has, and a link answers it only after a trip off the page. Folded so
# a busy week cannot push the images out of sight.
upstream_block() {
  [ -n "${UPSTREAM_LOG:-}" ] || return 0
  _n=$(printf '%s\n' "$UPSTREAM_LOG" | grep -c .)
  # the compare API caps a page at 250; saying so beats a silent truncation
  if [ -n "${UPSTREAM_TOTAL:-}" ] && [ "$UPSTREAM_TOTAL" -gt "$_n" ] 2>/dev/null; then
    printf '<details>\n<summary>Upstream changes · %s of %s commits</summary>\n\n' "$_n" "$UPSTREAM_TOTAL"
  else
    printf '<details>\n<summary>Upstream changes · %s commits</summary>\n\n' "$_n"
  fi
  printf '%s\n' "$UPSTREAM_LOG" | sed 's/^/- /'
  if [ -n "${PREV_SHA:-}" ] && [ -n "${SOURCE_REPO:-}" ]; then
    printf '\n[full compare](https://github.com/%s/compare/%s...%s)\n' \
      "$SOURCE_REPO" "$PREV_SHA" "${SOURCE_SHA:-}"
  fi
  printf '</details>\n'
}

# The same question, asked of our own repos: the Packages table says a source
# moved, this says what moved in it. PLUGIN_LOG lines are "repo|subject".
plugin_changes_block() {
  [ -n "${PLUGIN_LOG:-}" ] || return 0
  _n=$(printf '%s\n' "$PLUGIN_LOG" | grep -c .)
  _repos=$(printf '%s\n' "$PLUGIN_LOG" | sed -n 's/|.*//p' | awk 'NF && !seen[$0]++')
  _rn=$(printf '%s\n' "$_repos" | grep -c .)
  printf '<details>\n<summary>Plugin changes · %s repos, %s commits</summary>\n\n' "$_rn" "$_n"
  for _r in $_repos; do
    _slug=$(gh_slug "$(repo_url "$_r")")
    _cur=$(printf '%s' "${PKG_REPOS:-}" | tr ' ' '\n' | sed -n "s/^$_r@//p" | head -n 1)
    _prev=$(printf '%s' "${PREV_PKG_REPOS:-}" | tr ' ' '\n' | sed -n "s/^$_r@//p" | head -n 1)
    # backticks below are markdown, not command substitution
    # shellcheck disable=SC2016
    if [ -n "$_slug" ] && [ -n "$_prev" ] && [ -n "$_cur" ]; then
      printf '**[%s](https://github.com/%s/compare/%s...%s)** `%s`\n' \
        "$_r" "$_slug" "$_prev" "$_cur" "$(printf '%s' "$_cur" | cut -c1-7)"
    else
      printf '**%s** `%s`\n' "$_r" "$(printf '%s' "$_cur" | cut -c1-7)"
    fi
    printf '%s\n' "$PLUGIN_LOG" | sed -n "s/^$_r|/- /p"
    printf '\n'
  done
  printf '</details>\n'
}

# ---------------------------------------------------------------- scalars ----

short=$(printf '%s' "${SOURCE_SHA:-}" | cut -c1-7)

lookup() { # $1 placeholder name -> value ('' means: drop the line)
  case "$1" in
    kernel)          printf '%s' "${KERNEL:-unknown}" ;;
    target)          printf '%s' "${TARGET:-}" ;;
    source)          printf "%s@\`%s\` (%s)" "${SOURCE_REPO:-}" "$short" "${SOURCE_REF:-}" ;;
    wifi_ssid)       setting WIFI_SSID ;;
    wifi_ssid_5g)    setting WIFI_SSID_5G ;;
    wifi_key)        setting WIFI_KEY ;;
    wifi_country)    setting WIFI_COUNTRY ;;
    wifi_encryption) setting WIFI_ENCRYPTION sae-mixed ;;
    # unset LAN_IP is not "unknown", it is OpenWrt's own default -- and the
    # address is the first thing a freshly flashed box needs, so the line that
    # used to vanish now states what actually answers.
    lan_ip)          setting LAN_IP 192.168.1.1 ;;
    *) die "unknown placeholder {{$1}} in $template" ;;
  esac
}

blk_images=$(images_block)
blk_packages=$(packages_block)
blk_upstream=$(upstream_block)
blk_plugins=$(plugin_changes_block)

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{images}}'*)         [ -n "$blk_images" ]   && printf '%s\n' "$blk_images";   continue ;;
    *'{{packages}}'*)       [ -n "$blk_packages" ] && printf '%s\n' "$blk_packages"; continue ;;
    *'{{upstream}}'*)       [ -n "$blk_upstream" ] && printf '%s\n' "$blk_upstream"; continue ;;
    *'{{plugin_changes}}'*) [ -n "$blk_plugins" ]  && printf '%s\n' "$blk_plugins";  continue ;;
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
