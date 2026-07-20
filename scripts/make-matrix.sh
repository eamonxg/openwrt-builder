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
  # leaves an orphan overlay behind whichever build you happen to be running
  local allnames='|'
  while IFS='|' read -r name _; do allnames="$allnames$name|"; done <<<"$records"
  check_overlays "$allnames"
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
