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

# ---- every named section in settings.ini must match a build name or device id ----
# One that matches nothing is a typo, and a typo's only symptom is that the
# whole section quietly stops applying.
recs=$(builds_load "$tmp/firmware/builds.ini")
scan_names "$recs"
[ "$BUILD_NAMES" = '|x86|jdcloud|' ] || { echo "FAIL: BUILD_NAMES (got=$BUILD_NAMES)"; exit 1; }
[ "$ALL_NAMES" = '|x86|jdcloud|jdcloud_re-ss-01|' ] || { echo "FAIL: ALL_NAMES must add device ids (got=$ALL_NAMES)"; exit 1; }

printf '%s\n' '[settings]' 'WIFI_SSID = R' '' '[jdcloud_re-ss-01]' 'LAN_IP = 192.168.6.1' > "$tmp/firmware/settings.ini"
check_settings "$ALL_NAMES" || { echo "FAIL: a section naming a real device must pass"; exit 1; }

printf '%s\n' '[settings]' 'WIFI_SSID = R' '' '[jdcloud]' 'WIFI_SSID = B' > "$tmp/firmware/settings.ini"
check_settings "$ALL_NAMES" || { echo "FAIL: a section naming a build must pass"; exit 1; }

# a typoed device id: one character off is still a miss
printf '%s\n' '[settings]' 'WIFI_SSID = R' '' '[jdcloud_re-ss-1]' 'LAN_IP = 192.168.6.1' > "$tmp/firmware/settings.ini"
( check_settings "$ALL_NAMES" ) 2>/dev/null && { echo "FAIL: a typoed device section must fail"; exit 1; }

# Same property as check_overlays: every section is checked regardless of which
# build is running, which is why the name set passed here is always the full
# ALL_NAMES rather than just the selected build.
printf '%s\n' '[settings]' 'WIFI_SSID = R' '' '[nope]' 'LAN_IP = 10.0.0.1' > "$tmp/firmware/settings.ini"
( check_settings "$ALL_NAMES" ) 2>/dev/null && { echo "FAIL: a section matching nothing must fail"; exit 1; }

# a typoed [settings] header is the headline case: it matches no build and no
# device, so it must die here -- this is the gap the loader deliberately left open
printf '%s\n' '[setings]' 'WIFI_SSID = R' > "$tmp/firmware/settings.ini"
( check_settings "$ALL_NAMES" ) 2>/dev/null && { echo "FAIL: a typoed [settings] header must fail"; exit 1; }

# a syntax error must not mask a section-name typo that follows it: ini_load
# stops at the first bad line, so every section after it goes unreported
printf '%s\n' '[settings]' 'WIFI_SSID = R' '' 'garbage line here' '' '[setings]' 'WIFI_SSID = B' > "$tmp/firmware/settings.ini"
( check_settings "$ALL_NAMES" ) 2>/dev/null && { echo "FAIL: a settings.ini syntax error must be fatal, not skipped"; exit 1; }

# a missing settings.ini is not an error: the whole feature is optional
rm -f "$tmp/firmware/settings.ini"
check_settings "$ALL_NAMES" || { echo "FAIL: a missing settings.ini must not be fatal"; exit 1; }

# ---- ambiguous names ----
# a name that is both a build and a device id leaves a same-named settings.ini
# section with no single meaning
clash=$(printf '%s\n' 'jdcloud_re-ss-01|x86/64|openwrt/openwrt||' \
                      'jdcloud|qualcommax/ipq60xx|openwrt/openwrt||jdcloud_re-ss-01')
( scan_names "$clash" ) 2>/dev/null && { echo "FAIL: a name that is both a build and a device must fail"; exit 1; }

# a build named 'settings' would collide with settings.ini's global section
named=$(printf '%s\n' 'settings|x86/64|openwrt/openwrt||')
( scan_names "$named" ) 2>/dev/null && { echo "FAIL: a build named [settings] must fail"; exit 1; }

# the same device in two builds is legal, not ambiguous: a section named after
# it applies to both
dup=$(printf '%s\n' 'a|x86/64|openwrt/openwrt||dev_one' 'b|x86/64|openwrt/openwrt||dev_one')
scan_names "$dup" || { echo "FAIL: the same device in two builds must be allowed"; exit 1; }
[ "$ALL_NAMES" = '|a|b|dev_one|' ] || { echo "FAIL: a repeated device must be listed once (got=$ALL_NAMES)"; exit 1; }

echo "PASS: test-make-matrix"
