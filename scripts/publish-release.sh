#!/bin/bash
# publish-release.sh <manifest> <settings.ini> <release.md> <upload-dir> [package/custom dir] —
# generate release notes and publish the release as tag <BUILD>-<DATE>.
# Env inputs: REPO BUILD DATE (YYYYMMDD-HHMM) KERNEL, plus what
# release-notes.sh needs (TARGET DEVICES SOURCE_REPO SOURCE_REF SOURCE_SHA DIGEST).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
[ $# -ge 4 ] || die "usage: publish-release.sh <manifest> <settings.ini> <release.md> <upload-dir> [package/custom dir]"
manifest=$1; settings=$2; template=$3; updir=$4; custom=${5:-}
: "${REPO:?REPO env required}" "${BUILD:?}" "${DATE:?}" "${SOURCE_REPO:?}"
[ -d "$updir" ] || die "upload dir not found: $updir"

prev_sha() { # source SHA of this build's previous release (exact tag match; empty when the source repo changed)
  local tag src
  tag=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq "[.[].tagName|select(test(\"^${BUILD}-[0-9]{8}-[0-9]{4}\$\"))][0]" 2>/dev/null) || return 0
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 0
  src=$(gh release view "$tag" --repo "$REPO" --json body --jq .body 2>/dev/null \
    | sed -n 's/.*<!-- source: \([^@]*\)@\([0-9a-f]\{40\}\) -->.*/\1@\2/p' | head -n 1) || return 0
  if [ "${src%%@*}" = "$SOURCE_REPO" ]; then printf '%s' "${src##*@}"; fi
}

TAG="${BUILD}-${DATE}"
PREV_SHA=$(prev_sha)
export PREV_SHA
notes=$(mktemp)
sh "$SCRIPT_DIR/release-notes.sh" "$manifest" "$settings" "$template" "$custom" > "$notes"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "${BUILD} · kernel ${KERNEL:-unknown} · ${DATE}" \
  --notes-file "$notes" \
  "$updir"/*
log "published $TAG"
