#!/bin/bash
# prune-caches.sh — keep the latest KEEP Actions caches per build, per kind.
#
# The two kinds age differently. A toolchain cache is content-addressed, so its
# key only moves when the toolchain really changes and old entries pile up
# slowly; a ccache entry is written on every run and would otherwise fill the
# repo's 10 GB quota within days, evicting the toolchain caches with it.
#
# Prefixes carry a trailing '-' so build names may prefix each other:
# 'ccache-jdcloud-' must not match 'ccache-jdcloud_nss-...'.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
KEEP=${KEEP:-2}

prune_prefix() { # $1 key prefix
  gh cache list --repo "$REPO" --limit 100 --key "$1" --json id,key,createdAt \
    --jq "sort_by(.createdAt)|reverse|.[$KEEP:]|.[]|\"\(.id)\t\(.key)\"" \
  | while IFS=$'\t' read -r id key; do
      [ -n "$id" ] || continue
      log "deleting expired cache: $key"
      gh cache delete "$id" --repo "$REPO"
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
    prune_prefix "toolchain-$name-"
    prune_prefix "ccache-$name-"
  done <<<"$records"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
