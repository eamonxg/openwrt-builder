#!/bin/bash
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/firmware"
# x86 and x86-canary prefix each other: exact matching must keep them apart
printf '%s\n' '[x86]' 'target = x86/64' '[x86-canary]' 'target = x86/64' > "$tmp/firmware/builds.ini"

# fake gh: list returns 6 releases (incl. a prefixing decoy), delete records to a file
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "release list" ]; then
  # raw JSON piped through the --jq expression, matching real gh behavior
  json='[{"tagName":"x86-canary-20250101-0000","createdAt":"2025-01-01T00:00:00Z"},
         {"tagName":"x86-20260101-0000","createdAt":"2026-01-01T00:00:00Z"},
         {"tagName":"x86-20260201-0000","createdAt":"2026-02-01T00:00:00Z"},
         {"tagName":"x86-20260301-0000","createdAt":"2026-03-01T00:00:00Z"},
         {"tagName":"x86-20260401-0000","createdAt":"2026-04-01T00:00:00Z"},
         {"tagName":"other-20260501-0000","createdAt":"2026-05-01T00:00:00Z"}]'
  # extract the expression following --jq
  expr=""; prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  echo "$json" | jq -r "$expr"
elif [ "$1 $2" = "release delete" ]; then
  echo "$3" >> "$GH_DELETED"
fi
FAKE
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" REPO=me/ci KEEP=2 GH_DELETED="$tmp/deleted" ROOT="$tmp"
# shellcheck disable=SC1091
source "$here/../scripts/prune-releases.sh"
main

sort "$tmp/deleted" > "$tmp/got"
printf '%s\n' 'x86-20260101-0000' 'x86-20260201-0000' > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || { echo "FAIL: wrong delete set (oldest 2 of x86 only; other-* and x86-canary-* untouched)"; exit 1; }
echo "PASS: test-prune-releases"
