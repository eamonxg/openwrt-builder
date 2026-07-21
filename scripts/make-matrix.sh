#!/bin/bash
# make-matrix.sh — plan stage: enumerate builds -> pin source SHAs ->
# change detection -> write matrix JSON to $GITHUB_OUTPUT (matrix=, count=).
# Env inputs: REPO BUILDS EVENT_NAME OVERRIDE_REPO OVERRIDE_REF [ROOT GITHUB_OUTPUT]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}

resolve_default_branch() { # $1 git url -> default branch name
  git ls-remote --symref "$1" HEAD | sed -n 's|^ref: refs/heads/\(.*\)	HEAD$|\1|p' | head -n1
}

resolve_sha() { # $1 git url  $2 ref (branch/tag/40-hex) -> 40-hex
  if printf '%s' "$2" | grep -qE '^[0-9a-f]{40}$'; then
    printf '%s' "$2"
    return
  fi
  git ls-remote "$1" "refs/heads/$2" "refs/tags/$2" | head -n1 | cut -f1
}

last_digest() { # $1 build -> builder-digest recorded by its latest release (empty if none)
  local tag
  # shellcheck disable=SC2153
  tag=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq "[.[].tagName|select(test(\"^$1-[0-9]{8}-[0-9]{4}\$\"))][0]" 2>/dev/null) || return 0
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 0
  # shellcheck disable=SC2153,SC2016
  gh release view "$tag" --repo "$REPO" --json body --jq .body 2>/dev/null \
    | sed -n 's/.*builder-digest: `\([0-9a-f]\{16\}\)`.*/\1/p' | head -n1
}

pkg_repos() { # -> "name@sha ..." for every third-party repo, resolved once
  # records are name|url|ref
  packages_load "$ROOT/firmware/packages.ini" | while IFS='|' read -r name url ref; do
    r=${ref:-$(resolve_default_branch "$url")}
    printf '%s@%s ' "$name" "$(resolve_sha "$url" "$r")"
  done
}

repo_digest() { # $1 source_repo $2 source_sha $3 pkg_repos — fingerprint of source + package repos
  {
    printf '%s@%s\n' "$1" "$2"
    printf '%s\n' "$3" | tr ' ' '\n' | grep . || true
  } | sha256 | cut -c1-16
}

check_overlays() { # $1 = |name|name|... — every <name>.config must belong to a section
  local f base
  for f in "$ROOT"/firmware/config/*.config; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .config)
    [ "$base" = common ] && continue
    case "$1" in
      *"|$base|"*) ;;
      *) die "firmware/config/$base.config matches no [$base] section in builds.ini — the build job picks overlays up by filename, so this one would be skipped in silence (every-build options belong in common.config)" ;;
    esac
  done
}

# scan_names <records> -> sets BUILD_NAMES and ALL_NAMES to |name|name|... .
# Two sets, because an overlay is named after a build only while a settings.ini
# section may name either a build or one of its devices.
# Globals rather than a return value on purpose: a die() inside a command
# substitution runs in a subshell and its exit would never reach the caller.
BUILD_NAMES=''; ALL_NAMES=''
scan_names() {
  local records=$1 name devs d
  BUILD_NAMES='|'
  while IFS='|' read -r name _ _ _ devs; do
    [ "$name" != settings ] || die "builds.ini must not define a section named [settings]: settings.ini uses that name for its global scope"
    BUILD_NAMES="$BUILD_NAMES$name|"
  done <<<"$records"
  # devices in a second pass, so every build name is known before one is
  # compared against them
  ALL_NAMES=$BUILD_NAMES
  while IFS='|' read -r name _ _ _ devs; do
    for d in $devs; do
      case "$BUILD_NAMES" in
        *"|$d|"*) die "'$d' is both a build name and a device id — a settings.ini section named after it would have no single meaning" ;;
      esac
      # the same device may appear in two builds; a section named after it
      # applies to both, so list it once rather than calling that a clash
      case "$ALL_NAMES" in *"|$d|"*) ;; *) ALL_NAMES="$ALL_NAMES$d|" ;; esac
    done
  done <<<"$records"
}

check_settings() { # $1 = |name|name|... — every settings.ini section must name a build or a device
  local f="$ROOT/firmware/settings.ini" out secs bad sec
  [ -f "$f" ] || return 0
  # Captured before anything is piped: a die() inside ini_load on the left of a
  # pipe would be swallowed by the shell. The ERR| check earns its place for a
  # second reason -- ini_load stops at the first syntax error, so a stray line
  # early in the file would otherwise hide every section header after it and
  # this guard would pass a typoed section in silence, which is the exact
  # failure it exists to prevent.
  out=$(ini_load "$f") || die "parse failed: $f"
  if printf '%s\n' "$out" | grep -q '^ERR|'; then
    die "$(printf '%s\n' "$out" | sed -n 's/^ERR|//p' | head -n 1)"
  fi
  secs=$(printf '%s\n' "$out" | sed -n 's/^SEC|//p')
  bad=''
  for sec in $secs; do
    [ "$sec" != settings ] || continue
    case "$1" in
      *"|$sec|"*) ;;
      *) bad="$bad $sec" ;;
    esac
  done
  [ -z "$bad" ] || die "firmware/settings.ini section(s) match no build or device in builds.ini:$bad — a section nobody selects is ignored in silence, so every value in it would go missing (defaults for every build belong in [settings])"
}

main() {
  local sel out repo ref url sha digest entry count pkgs
  sel=${BUILDS:-all}
  out=${GITHUB_OUTPUT:-/dev/stdout}
  # the third-party repos are the same for every build, so resolve them once;
  # the SHAs feed both the change-detection digest and the release notes
  pkgs=$(pkg_repos)
  pkgs=${pkgs% }
  local entries=()
  local records
  records=$(builds_load "$ROOT/firmware/builds.ini") || die "builds.ini parse failed"
  local name target prepo pref devs
  # checked against every section, not just the selected ones: a renamed section
  # leaves an orphan behind whichever build you happen to be running
  scan_names "$records"
  check_overlays "$BUILD_NAMES"
  check_settings "$ALL_NAMES"
  while IFS='|' read -r name target prepo pref devs; do
    if [ "$sel" != all ]; then
      case ",$sel," in *",$name,"*) ;; *) continue ;; esac
    fi
    repo=${OVERRIDE_REPO:-$prepo}
    ref=${OVERRIDE_REF:-$pref}
    url="https://github.com/$repo.git"
    [ -n "$ref" ] || ref=$(resolve_default_branch "$url")
    [ -n "$ref" ] || die "cannot resolve default branch of $repo"
    sha=$(resolve_sha "$url" "$ref")
    [ -n "$sha" ] || die "cannot resolve $repo@$ref"
    digest=$(repo_digest "$repo" "$sha" "$pkgs")
    if [ "${EVENT_NAME:-}" = schedule ] && [ "$(last_digest "$name")" = "$digest" ]; then
      log "skip $name: upstream unchanged (digest $digest)"
      continue
    fi
    entry=$(jq -nc --arg p "$name" --arg repo "$repo" --arg ref "$ref" --arg sha "$sha" \
      --arg t "$target" --arg d "$devs" --arg g "$digest" --arg k "$pkgs" \
      '{build:$p,source_repo:$repo,source_ref:$ref,source_sha:$sha,target:$t,devices:$d,digest:$g,pkg_repos:$k}')
    entries+=("$entry")
  done <<<"$records"
  local matrix
  if [ ${#entries[@]} -eq 0 ]; then
    matrix='{"include":[]}'
  else
    matrix=$(printf '%s\n' "${entries[@]}" | jq -sc '{include:.}')
  fi
  count=$(jq -r '.include|length' <<<"$matrix")
  {
    echo "matrix=$matrix"
    echo "count=$count"
  } >> "$out"
  log "matrix: $count build(s) to run"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
