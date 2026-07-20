#!/bin/bash
# stub functions are called indirectly by the sourced script; shellcheck
# versions disagree on SC2317 vs SC2329 for that
# shellcheck disable=SC2317,SC2329
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# mini repo layout; the package repo is a local git repo so repo_digest can do real ls-remote
mkdir -p "$tmp/firmware/config" "$tmp/srcrepo"
( cd "$tmp/srcrepo" && git init -q -b main && echo hi > Makefile \
  && git add . && git -c user.email=t@t -c user.name=t commit -qm init )
printf '%s\n' '[x86]' 'target = x86/64' '' '[jdcloud]' 'target = qualcommax/ipq60xx' \
  'devices = jdcloud_re-ss-01' > "$tmp/firmware/builds.ini"
printf '%s\n' '[mypkg]' "repo = file://$tmp/srcrepo" 'ref = main' > "$tmp/firmware/packages.ini"

export ROOT="$tmp" BUILDS=all EVENT_NAME=workflow_dispatch OVERRIDE_REPO='' OVERRIDE_REF='' REPO=me/ci
export GITHUB_OUTPUT="$tmp/out"
# shellcheck disable=SC1091
source "$here/../scripts/make-matrix.sh"

# pkg_repos with real resolution (unstubbed): the SHAs it returns feed both the
# change-detection digest and the release notes' per-repo diff
real_sha=$(git -C "$tmp/srcrepo" rev-parse HEAD)
pkgs=$(pkg_repos); pkgs=${pkgs% }
[ "$pkgs" = "mypkg@$real_sha" ] || { echo "FAIL: pkg_repos must resolve the real ref (got=$pkgs)"; exit 1; }

want=$(printf '%s\n' 'openwrt/openwrt@1111111111111111111111111111111111111111' \
  "mypkg@$real_sha" | sha256 | cut -c1-16)
got=$(repo_digest openwrt/openwrt 1111111111111111111111111111111111111111 "$pkgs")
[ "$got" = "$want" ] || { echo "FAIL: repo_digest must cover source plus every package repo (got=$got want=$want)"; exit 1; }
# a moved package repo must change the digest, or a schedule run would skip the rebuild
moved=$(repo_digest openwrt/openwrt 1111111111111111111111111111111111111111 "mypkg@deadbeef")
[ "$moved" != "$got" ] || { echo "FAIL: a package repo SHA change must move the digest"; exit 1; }

# last_digest matches the build exactly: the newer x86-old release must not match x86
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "release list" ]; then
  json='[{"tagName":"x86-old-20260401-0000"},{"tagName":"x86-20260301-0000"}]'
  expr=""; prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  echo "$json" | jq -r "$expr"
elif [ "$1 $2" = "release view" ]; then
  case "$3" in
    x86-20260301-0000)     printf 'body <!-- builder-digest: `1111222233334444` -->\n' ;;
    x86-old-20260401-0000) printf 'body <!-- builder-digest: `9999999999999999` -->\n' ;;
  esac
fi
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
got=$(last_digest x86)
[ "$got" = 1111222233334444 ] || { echo "FAIL: last_digest must match the build exactly (got=$got)"; exit 1; }

resolve_default_branch() { echo master; }
resolve_sha() { echo 1111111111111111111111111111111111111111; }
last_digest() { echo none; }
main

matrix=$(sed -n 's/^matrix=//p' "$tmp/out")
[ "$(jq -r '.include|length' <<<"$matrix")" = 2 ] || { echo "FAIL: expected 2 entries"; exit 1; }
[ "$(jq -r '.include[0].source_repo' <<<"$matrix")" = "openwrt/openwrt" ] || { echo "FAIL: default source"; exit 1; }
[ "$(jq -r '.include[0].source_ref' <<<"$matrix")" = "master" ] || { echo "FAIL: default branch resolution"; exit 1; }
[ "$(jq -r '.include[0].build' <<<"$matrix")" = "x86" ] || { echo "FAIL: build name"; exit 1; }
# the resolved package SHAs travel to the build job, which hands them to the
# notes. resolve_sha is stubbed above, so this is the stub's value, not real_sha
[ "$(jq -r '.include[0].pkg_repos' <<<"$matrix")" = "mypkg@1111111111111111111111111111111111111111" ] \
  || { echo "FAIL: pkg_repos must reach the matrix entry"; exit 1; }

# BUILDS filter (by section name)
: > "$tmp/out"
BUILDS=jdcloud main
[ "$(sed -n 's/^count=//p' "$tmp/out")" = 1 ] || { echo "FAIL: filter"; exit 1; }

# schedule + same digest -> skip (behavioral: run once for the digest, then stub last_digest to return it)
: > "$tmp/out"
BUILDS=x86 EVENT_NAME=workflow_dispatch main
got=$(sed -n 's/^matrix=//p' "$tmp/out" | jq -r '.include[0].digest')
: > "$tmp/out"
last_digest() { echo "$got"; }
BUILDS=x86 EVENT_NAME=schedule main
[ "$(sed -n 's/^count=//p' "$tmp/out")" = 0 ] || { echo "FAIL: unchanged upstream must be skipped"; exit 1; }

# overlays are picked up by filename, so one matching no section must fail loudly
: > "$tmp/out"
touch "$tmp/firmware/config/common.config" "$tmp/firmware/config/x86.config"
BUILDS=all main >/dev/null 2>&1 || { echo "FAIL: common.config and a matching overlay must pass"; exit 1; }
touch "$tmp/firmware/config/x87.config"
( BUILDS=all main >/dev/null 2>&1 ) && { echo "FAIL: orphan overlay must fail"; exit 1; }
# ...and it must fail even when building an unrelated build, since the orphan is still orphaned
( BUILDS=jdcloud main >/dev/null 2>&1 ) && { echo "FAIL: orphan overlay must fail regardless of the build filter"; exit 1; }
rm -f "$tmp/firmware/config/x87.config"
echo "PASS: test-make-matrix"
