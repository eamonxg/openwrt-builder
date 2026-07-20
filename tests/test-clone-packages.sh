#!/bin/sh
set -eu
sc="$(dirname "$0")/../scripts/clone-packages.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# local git repo standing in for a remote
mkdir -p "$tmp/srcrepo"
( cd "$tmp/srcrepo" && git init -q -b main && echo hi > Makefile \
  && git add . && git -c user.email=t@t -c user.name=t commit -qm init )

mkdir -p "$tmp/openwrt"
cat > "$tmp/pkgs.ini" <<EOF
# comment
[mytheme]
repo = file://$tmp/srcrepo

[mypin]
repo = file://$tmp/srcrepo
ref = main
EOF
sh "$sc" "$tmp/pkgs.ini" "$tmp/openwrt"
[ -f "$tmp/openwrt/package/custom/mytheme/Makefile" ] || { echo "FAIL: default-branch clone"; exit 1; }
[ -f "$tmp/openwrt/package/custom/mypin/Makefile" ] || { echo "FAIL: pinned-ref clone"; exit 1; }
[ ! -d "$tmp/openwrt/package/custom/mytheme/.git" ] || { echo "FAIL: .git must be removed"; exit 1; }

# a section missing repo must fail
printf '%s\n' '[onlyname]' > "$tmp/bad.ini"
if sh "$sc" "$tmp/bad.ini" "$tmp/openwrt" 2>/dev/null; then
  echo "FAIL: bad section must fail"; exit 1
fi
echo "PASS: test-clone-packages"
