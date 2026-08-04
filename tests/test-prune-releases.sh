#!/bin/bash
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/firmware"
# x86 and x86-canary prefix each other: exact matching must keep them apart
printf '%s\n' '[x86]' 'target = x86/64' '[x86-canary]' 'target = x86/64' > "$tmp/firmware/builds.ini"

# fake gh: list pipes the fixture in $GH_JSON through the --jq expression, the
# way real gh does; delete records to a file
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "release list" ]; then
  expr=""; prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  jq -r "$expr" < "$GH_JSON"
elif [ "$1 $2" = "release delete" ]; then
  echo "$3" >> "$GH_DELETED"
fi
FAKE
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" REPO=me/ci KEEP=2 ROOT="$tmp"
# shellcheck disable=SC1091
source "$here/../scripts/prune-releases.sh"

# Both scenarios must delete the same two: the oldest x86 releases. 'other-*' and
# 'x86-canary-*' are decoys that the exact tag regex has to leave alone.
printf '%s\n' 'x86-20260101-0000' 'x86-20260201-0000' > "$tmp/want"

run_case() { # $1 label, $2 fixture json
  GH_JSON="$tmp/json"; GH_DELETED="$tmp/deleted"
  export GH_JSON GH_DELETED
  printf '%s' "$2" > "$GH_JSON"; : > "$GH_DELETED"
  main
  sort "$GH_DELETED" > "$tmp/got"
  diff -u "$tmp/want" "$tmp/got" || {
    echo "FAIL: $1 — wrong delete set (want the oldest 2 x86 releases)"; exit 1; }
}

# distinct createdAt, oldest first — the ordinary case
run_case distinct-timestamps '[
  {"tagName":"x86-canary-20250101-0000","createdAt":"2025-01-01T00:00:00Z"},
  {"tagName":"x86-20260101-0000","createdAt":"2026-01-01T00:00:00Z"},
  {"tagName":"x86-20260201-0000","createdAt":"2026-02-01T00:00:00Z"},
  {"tagName":"x86-20260301-0000","createdAt":"2026-03-01T00:00:00Z"},
  {"tagName":"x86-20260401-0000","createdAt":"2026-04-01T00:00:00Z"},
  {"tagName":"other-20260501-0000","createdAt":"2026-05-01T00:00:00Z"}]'

# Regression: a release's createdAt is its TARGET COMMIT's date, not its publish
# time, so every release cut from an unchanged default branch carries the same
# value — and real `gh release list` returns newest first. Sorting on an
# all-equal key is a stable no-op, so anything that then reverses the list is
# holding it upside down and deletes the newest releases instead of the oldest.
# That destroyed a week of nightly firmware before it was noticed.
run_case identical-timestamps '[
  {"tagName":"other-20260501-0000","createdAt":"2026-07-25T20:33:43Z"},
  {"tagName":"x86-20260401-0000","createdAt":"2026-07-25T20:33:43Z"},
  {"tagName":"x86-20260301-0000","createdAt":"2026-07-25T20:33:43Z"},
  {"tagName":"x86-20260201-0000","createdAt":"2026-07-25T20:33:43Z"},
  {"tagName":"x86-20260101-0000","createdAt":"2026-07-25T20:33:43Z"},
  {"tagName":"x86-canary-20250101-0000","createdAt":"2026-07-25T20:33:43Z"}]'

echo "PASS: test-prune-releases"
