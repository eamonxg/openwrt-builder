#!/bin/bash
set -euo pipefail
command -v jq >/dev/null || { echo "SKIP: jq not installed (CI runs it)"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/firmware"
# jdcloud and jdcloud_nss prefix each other: the trailing '-' in the key prefix
# is what keeps 'ccache-jdcloud-' from swallowing 'ccache-jdcloud_nss-*'
printf '%s\n' '[jdcloud]' 'target = qualcommax/ipq60xx' \
              '[jdcloud_nss]' 'target = qualcommax/ipq60xx' > "$tmp/firmware/builds.ini"

# fake gh: list filters the fixture by the --key prefix, delete records to a file
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1 $2" = "cache list" ]; then
  json='[{"id":1,"key":"ccache-jdcloud-100","createdAt":"2026-01-01T00:00:00Z"},
         {"id":2,"key":"ccache-jdcloud-200","createdAt":"2026-02-01T00:00:00Z"},
         {"id":3,"key":"ccache-jdcloud-300","createdAt":"2026-03-01T00:00:00Z"},
         {"id":4,"key":"ccache-jdcloud-400","createdAt":"2026-04-01T00:00:00Z"},
         {"id":5,"key":"ccache-jdcloud_nss-500","createdAt":"2026-01-01T00:00:00Z"},
         {"id":6,"key":"toolchain-jdcloud-aaaa","createdAt":"2026-01-01T00:00:00Z"},
         {"id":7,"key":"toolchain-jdcloud-bbbb","createdAt":"2026-02-01T00:00:00Z"},
         {"id":8,"key":"toolchain-jdcloud-cccc","createdAt":"2026-03-01T00:00:00Z"}]'
  expr=""; key=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && expr=$a
    [ "$prev" = "--key" ] && key=$a
    prev=$a
  done
  # real `gh cache list --key` is a prefix filter
  echo "$json" | jq --arg k "$key" '[.[]|select(.key|startswith($k))]' | jq -r "$expr"
elif [ "$1 $2" = "cache delete" ]; then
  echo "$3" >> "$GH_DELETED"
fi
FAKE
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" REPO=me/ci KEEP=2 GH_DELETED="$tmp/deleted" ROOT="$tmp"
# shellcheck disable=SC1091
source "$here/../scripts/prune-caches.sh"
main

sort "$tmp/deleted" > "$tmp/got"
# oldest ccache-jdcloud (1,2) and oldest toolchain-jdcloud (6); the lone
# jdcloud_nss entry (5) is within KEEP for its own prefix and must survive
printf '%s\n' 1 2 6 > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || { echo "FAIL: wrong delete set"; exit 1; }
echo "PASS: test-prune-caches"
