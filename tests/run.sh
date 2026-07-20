#!/bin/sh
# run all unit tests; any single failure fails the suite
set -eu
cd "$(dirname "$0")"
fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  echo "== $t"
  # bash-only tests (source/arrays) dispatch by shebang; ubuntu's sh (dash) cannot run them
  case "$(head -n1 "$t")" in
    *bash*) bash "$t" || fail=1 ;;
    *)      sh "$t"   || fail=1 ;;
  esac
done
exit $fail
