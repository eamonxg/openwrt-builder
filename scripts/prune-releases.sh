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
  # Sort on the tag, not a timestamp: the regex above guarantees a fixed-width
  # <name>-YYYYMMDD-HHMM, so lexicographic order is chronological order. A
  # release's createdAt is its *target commit's* date, which is identical for
  # every release built off an unchanged main — sorting on it is a no-op that
  # leaves the newest builds at the far end of the list, to be deleted.
  gh release list --repo "$REPO" --limit 200 --json tagName \
    --jq "[.[].tagName|select(test(\"^$1-[0-9]{8}-[0-9]{4}\$\"))]|sort|reverse|.[$KEEP:]|.[]" \
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
