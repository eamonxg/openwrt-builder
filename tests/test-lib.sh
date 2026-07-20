#!/bin/sh
# basic lib.sh functions
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib.sh"

out=$(printf 'hello' | sha256)
[ "$out" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ] \
  || { echo "FAIL: sha256 got $out"; exit 1; }

( die "boom" 2>/dev/null ) && { echo "FAIL: die should exit 1"; exit 1; }
echo "PASS: test-lib"
