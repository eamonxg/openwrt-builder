#!/bin/sh
# clone-packages.sh <packages.ini> <openwrt-dir>
# Shallow-clone every third-party repo (themes/plugins/dependencies) into package/custom/.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"
list=$1; owrt=$2
dest=$owrt/package/custom
mkdir -p "$dest"
records=$(packages_load "$list") || die "parse failed: $list"
# records are name|url|ref
printf '%s\n' "$records" | while IFS='|' read -r name url ref; do
  if [ -n "$ref" ]; then
    git clone -q --depth=1 --single-branch --branch "$ref" "$url" "$dest/$name"
  else
    git clone -q --depth=1 "$url" "$dest/$name"
  fi
  rm -rf "$dest/$name/.git"
  echo "added $name <- $url ${ref:-<default branch>}"
done
