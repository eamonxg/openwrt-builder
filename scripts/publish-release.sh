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

TAG="${BUILD}-${DATE}"
body=$(prev_body)
# source SHA of the previous release; left empty when the source repo changed, so
# a compare link across unrelated histories is never offered
PREV_SHA=''
prev_src=$(printf '%s' "$body" | sed -n 's/.*<!-- source: \([^@]*\)@\([0-9a-f]\{40\}\) -->.*/\1@\2/p' | head -n 1)
if [ -n "$prev_src" ] && [ "${prev_src%%@*}" = "$SOURCE_REPO" ]; then PREV_SHA=${prev_src##*@}; fi
# plugin-repo SHAs the previous release recorded, for the per-repo diff
PREV_PKG_REPOS=$(printf '%s' "$body" | sed -n 's/.*<!-- packages: \(.*\) -->.*/\1/p' | head -n 1)
export PREV_SHA PREV_PKG_REPOS

notes=$(mktemp)
sh "$SCRIPT_DIR/release-notes.sh" "$meta" "$updir" "$settings" "$pkgini" "$template" "$custom" > "$notes"
# the tag keeps its machine-readable timestamp — prune-releases.sh, prev_body()
# and make-matrix.sh all match on it — while the title spells it out, since
# '20260720-2102' tells a reader nothing on its own
title="${BUILD} · kernel ${KERNEL:-unknown}"
if [ "${#DATE}" = 13 ]; then
  title="$title · ${DATE:0:4}-${DATE:4:2}-${DATE:6:2} ${DATE:9:2}:${DATE:11:2}"
else
  title="$title · ${DATE}"
fi
gh release create "$TAG" \
  --repo "$REPO" \
  --title "$title" \
  --notes-file "$notes" \
  "$updir"/*
log "published $TAG"
