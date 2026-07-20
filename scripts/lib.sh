#!/bin/sh
# lib.sh — shared functions; sourced by other scripts, never executed directly.
# Loader output must be captured via command substitution before piping:
# a die() on the left side of a pipeline would be swallowed by the shell.
log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# sha256: stdin -> 64-char hex (macOS lacks sha256sum, fall back to shasum)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# ini_load <file>: normalize INI into a line stream of SEC|name and
# KV|section|key|value records; syntax errors become ERR| lines for the caller.
# Syntax: [name] (A-Za-z0-9_- only) / key = value / # comment.
# Values must not contain '|'.
ini_load() {
  _f=$1
  [ -f "$_f" ] || die "config file not found: $_f"
  awk '
    { sub(/#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
    /^$/ { next }
    /^\[[A-Za-z0-9_-]+\]$/ {
      sec = substr($0, 2, length($0)-2)
      if (sec in seen) { printf "ERR|duplicate section: %s\n", sec; exit 0 }
      seen[sec] = 1; print "SEC|" sec; next
    }
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
      if (sec == "") { printf "ERR|key before any section: %s\n", $0; exit 0 }
      eq = index($0, "="); key = substr($0, 1, eq-1); val = substr($0, eq+1)
      gsub(/[ \t]+$/, "", key); gsub(/^[ \t]+/, "", val)
      if (index(val, "|") > 0) { printf "ERR|value must not contain |: %s\n", $0; exit 0 }
      print "KV|" sec "|" key "|" val; next
    }
    { printf "ERR|unparsable line: %s\n", $0; exit 0 }
  ' "$_f"
}

# builds_load <builds.ini>: emit records name|board/subtarget|source-repo|ref|devices.
# target is required and must contain '/'; unknown keys die. Section names may
# prefix each other — release tag matching is exact on <name>-date-time.
builds_load() {
  _bl_out=$(ini_load "$1") || die "parse failed: $1"
  printf '%s\n' "$_bl_out" | grep -q '^ERR|' && die "$(printf '%s\n' "$_bl_out" | sed -n 's/^ERR|//p' | head -n 1)"
  _emit() {
    [ -n "$_sec" ] || return 0
    [ -n "$_target" ] || die "section [$_sec] missing target"
    case "$_target" in */*) ;; *) die "target in section [$_sec] must be board/subtarget: $_target" ;; esac
    printf '%s|%s|%s|%s|%s\n' "$_sec" "$_target" "$_repo" "$_ref" "$_devs"
  }
  _sec=''; _target=''; _repo=openwrt/openwrt; _ref=''; _devs=''
  while IFS='|' read -r _tag _a _b _c; do
    case "$_tag" in
      SEC)
        _emit
        _sec=$_a; _target=''; _repo=openwrt/openwrt; _ref=''; _devs=''
        ;;
      KV)
        case "$_b" in
          target)  _target=$_c ;;
          devices) _devs=$_c ;;
          source)  _repo=$_c ;;
          ref)     _ref=$_c ;;
          *) die "unknown key in section [$_a]: $_b (allowed: target/devices/source/ref)" ;;
        esac
        ;;
    esac
  done <<EOF3
$_bl_out
EOF3
  _emit
}

# settings_load <settings.ini>: emit records key|value. Only the [settings]
# section and known keys are allowed, so a typoed key fails loudly instead of
# silently doing nothing. Values arrive trimmed by ini_load.
settings_load() {
  _sl_out=$(ini_load "$1") || die "parse failed: $1"
  printf '%s\n' "$_sl_out" | grep -q '^ERR|' && die "$(printf '%s\n' "$_sl_out" | sed -n 's/^ERR|//p' | head -n 1)"
  while IFS='|' read -r _tag _a _b _c; do
    case "$_tag" in
      SEC) [ "$_a" = settings ] || die "settings.ini allows only the [settings] section, got: [$_a]" ;;
      KV)
        case "$_b" in
          BUILD_BY|WIFI_SSID|WIFI_KEY|WIFI_COUNTRY|WIFI_ENCRYPTION) printf '%s|%s\n' "$_b" "$_c" ;;
          *) die "unknown key in settings.ini: $_b (allowed: BUILD_BY/WIFI_SSID/WIFI_KEY/WIFI_COUNTRY/WIFI_ENCRYPTION)" ;;
        esac
        ;;
    esac
  done <<EOF5
$_sl_out
EOF5
}

# packages_load <packages.ini>: emit records name|git-url|ref
# (ref may be empty; repo is required, unknown keys die).
# This file only declares where code comes from. What ships is decided by
# common.config / firmware/config/<name>.config, and the release notes table discovers
# each repo's packages by itself — so no key here controls either.
packages_load() {
  _pl_out=$(ini_load "$1") || die "parse failed: $1"
  printf '%s\n' "$_pl_out" | grep -q '^ERR|' && die "$(printf '%s\n' "$_pl_out" | sed -n 's/^ERR|//p' | head -n 1)"
  _emit_pkg() {
    [ -n "$_psec" ] || return 0
    [ -n "$_purl" ] || die "section [$_psec] missing repo"
    printf '%s|%s|%s\n' "$_psec" "$_purl" "$_pref"
  }
  _psec=''; _purl=''; _pref=''
  while IFS='|' read -r _tag _a _b _c; do
    case "$_tag" in
      SEC) _emit_pkg; _psec=$_a; _purl=''; _pref='' ;;
      KV)
        case "$_b" in
          repo) _purl=$_c ;;
          ref)  _pref=$_c ;;
          select) die "select was removed: enable packages in common.config (every build) or firmware/config/<name>.config (one build)" ;;
          cores)  die "cores was removed: the release notes table now discovers packages from the cloned repos, and its layout lives in firmware/release.md" ;;
          *) die "unknown key in section [$_a]: $_b (allowed: repo/ref)" ;;
        esac
        ;;
    esac
  done <<EOF4
$_pl_out
EOF4
  _emit_pkg
}
