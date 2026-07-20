#!/bin/bash
# prune-releases.sh — keep the latest KEEP releases per build, delete the rest
# including their tags. Tags are matched exactly as <name>-YYYYMMDD-HHMM, so
# build names may prefix each other without collateral deletions.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
KEEP=${KEEP:-3}

prune_build() { # $1 build
  gh release list --repo "$REPO" --limit 200 --json tagName,createdAt \
    --jq "[.[]|select(.tagName|test(\"^$1-[0-9]{8}-[0-9]{4}\$\"))]|sort_by(.createdAt)|reverse|.[$KEEP:]|.[].tagName" \
  | while read -r tag; do
      [ -n "$tag" ] || continue
      log "deleting expired release: $tag"
      gh release delete "$tag" --repo "$REPO" --cleanup-tag --yes
    done
}

main() {
  : "${REPO:?REPO env required}"
  case "$KEEP" in
    ''|*[!0-9]*) die "KEEP must be a non-negative integer, got: $KEEP" ;;
  esac
  local records name
  records=$(builds_load "$ROOT/firmware/builds.ini") || die "builds.ini parse failed"
  while IFS='|' read -r name _; do
    prune_build "$name"
  done <<<"$records"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
