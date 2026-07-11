#!/usr/bin/env bash
# sync-vendored.sh — keep vendored file copies byte-identical to their
# canonical sources. Plugins install as isolated copies with no way to
# reference each other's files, so shared scripts are vendored; this script
# is the single place that knows the pairs.
#
#   tools/sync-vendored.sh           copy canonical -> vendored
#   tools/sync-vendored.sh --check   fail (exit 1) on drift; used by CI

set -euo pipefail
cd "$(dirname "$0")/.."

# "canonical:vendored" pairs, repo-relative.
PAIRS="
github/scripts/wait-for-ci.sh:issues/scripts/wait-for-ci.sh
"

MODE="${1:---sync}"
STATUS=0
for pair in $PAIRS; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  case "$MODE" in
    --check)
      if ! cmp -s "$src" "$dst"; then
        echo "DRIFT: $dst differs from canonical $src — run tools/sync-vendored.sh" >&2
        STATUS=1
      fi
      ;;
    --sync)
      cp "$src" "$dst"
      chmod +x "$dst"
      echo "synced $src -> $dst"
      ;;
    *)
      echo "usage: sync-vendored.sh [--sync|--check]" >&2
      exit 1
      ;;
  esac
done
exit "$STATUS"
