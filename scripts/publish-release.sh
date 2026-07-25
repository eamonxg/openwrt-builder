#!/bin/bash
# publish-release.sh <meta-dir> <upload-dir> <settings.ini> <packages.ini> <release.md> [package/custom dir] —
# generate release notes and publish the release as tag <BUILD>-<DATE>.
# Env inputs: REPO BUILD DATE (YYYYMMDD-HHMM) KERNEL, plus what release-notes.sh
# needs (TARGET DEVICES SOURCE_REPO SOURCE_REF SOURCE_SHA DIGEST PKG_REPOS).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
[ $# -ge 5 ] || die "usage: publish-release.sh <meta-dir> <upload-dir> <settings.ini> <packages.ini> <release.md> [package/custom dir]"
meta=$1; updir=$2; settings=$3; pkgini=$4; template=$5; custom=${6:-}
: "${REPO:?REPO env required}" "${BUILD:?}" "${DATE:?}" "${SOURCE_REPO:?}"
[ -d "$updir" ] || die "upload dir not found: $updir"

prev_body() { # body of this build's previous release (exact tag match, empty when none)
  local tag
  tag=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq "[.[].tagName|select(test(\"^${BUILD}-[0-9]{8}-[0-9]{4}\$\"))][0]" 2>/dev/null) || return 0
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 0
  gh release view "$tag" --repo "$REPO" --json body --jq .body 2>/dev/null || return 0
}

# commit subjects between two revisions of a github repo, one per line.
# Every network call in the pipeline lives here rather than in release-notes.sh:
# that script stays renderer-only and therefore stays testable offline.
commit_log() { # $1 owner/repo  $2 base sha  $3 head sha  -> subjects on stdout
  gh api "repos/$1/compare/$2...$3" \
    --jq '.commits[].commit.message | split("\n")[0]' 2>/dev/null || true
}

TAG="${BUILD}-${DATE}"
body=$(prev_body)
# source SHA of the previous release; left empty when the source repo changed, so
# a compare across unrelated histories is never attempted
PREV_SHA=''
prev_src=$(printf '%s' "$body" | sed -n 's/.*<!-- source: \([^@]*\)@\([0-9a-f]\{40\}\) -->.*/\1@\2/p' | head -n 1)
if [ -n "$prev_src" ] && [ "${prev_src%%@*}" = "$SOURCE_REPO" ]; then PREV_SHA=${prev_src##*@}; fi
# plugin-repo SHAs the previous release recorded, for the per-repo diff
PREV_PKG_REPOS=$(printf '%s' "$body" | sed -n 's/.*<!-- packages: \(.*\) -->.*/\1/p' | head -n 1)
export PREV_SHA PREV_PKG_REPOS

# what changed upstream, spelled out rather than linked
UPSTREAM_LOG=''; UPSTREAM_TOTAL=''
if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "${SOURCE_SHA:-}" ]; then
  if cmp_json=$(gh api "repos/$SOURCE_REPO/compare/$PREV_SHA...${SOURCE_SHA:-}" 2>/dev/null); then
    UPSTREAM_TOTAL=$(printf '%s' "$cmp_json" | jq -r '.total_commits // ""')
    UPSTREAM_LOG=$(printf '%s' "$cmp_json" | jq -r '.commits[].commit.message | split("\n")[0]')
  else
    # the release is still worth publishing without it, but a block that vanishes
    # silently is indistinguishable from "nothing changed upstream"
    log "warning: cannot read $SOURCE_REPO compare $PREV_SHA...${SOURCE_SHA:-}; omitting the upstream block"
  fi
fi
export UPSTREAM_LOG UPSTREAM_TOTAL

# the same, for the third-party repos whose SHA moved since the last build.
# Lines are "repo|subject"; a repo we cannot resolve to a github slug is skipped
# rather than guessed at.
PLUGIN_LOG=''
if [ -n "${PKG_REPOS:-}" ] && [ -n "$PREV_PKG_REPOS" ] && [ -f "$pkgini" ]; then
  urls=$(packages_load "$pkgini")
  for entry in $PKG_REPOS; do
    name=${entry%@*}; sha=${entry##*@}
    prev=$(printf '%s' "$PREV_PKG_REPOS" | tr ' ' '\n' | sed -n "s/^${name}@//p" | head -n 1)
    [ -n "$prev" ] && [ "$prev" != "$sha" ] || continue
    url=$(printf '%s\n' "$urls" | sed -n "s/^${name}|//p" | head -n 1)
    url=${url%%|*}
    case "$url" in
      https://github.com/*) slug=${url#https://github.com/}; slug=${slug%.git} ;;
      *) log "note: $name is not on github, its commits cannot be listed"; continue ;;
    esac
    subjects=$(commit_log "$slug" "$prev" "$sha")
    if [ -z "$subjects" ]; then
      log "warning: cannot read $slug compare $prev...$sha; omitting its commits"
      continue
    fi
    PLUGIN_LOG="${PLUGIN_LOG}$(printf '%s' "$subjects" | sed "s|^|${name}\||")
"
  done
fi
export PLUGIN_LOG

notes=$(mktemp)
sh "$SCRIPT_DIR/release-notes.sh" "$meta" "$updir" "$settings" "$pkgini" "$template" "$custom" > "$notes"
# the tag keeps its machine-readable timestamp — prune-releases.sh, prev_body()
# and make-matrix.sh all match on it — while the title spells out the date the
# release list is sorted by. The kernel version lives in the body: it is near
# identical across a device's builds, and in the sidebar it ate the width the
# date needed, leaving same-day rebuilds indistinguishable.
if [ "${#DATE}" = 13 ]; then
  title="${BUILD} ${DATE:4:2}-${DATE:6:2} ${DATE:9:2}:${DATE:11:2}"
else
  title="${BUILD} ${DATE}"
fi
gh release create "$TAG" \
  --repo "$REPO" \
  --title "$title" \
  --notes-file "$notes" \
  "$updir"/*
log "published $TAG"
