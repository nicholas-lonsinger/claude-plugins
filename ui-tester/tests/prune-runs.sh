#!/bin/bash
# Scratch-HOME harness for the ui-tester plugin's prune-runs.sh SessionStart hook.
# Usage: bash ui-tester/tests/prune-runs.sh [repo-root]   (defaults to this checkout)
set -u

# The hook reads $HOME (for ~/.claude/tester/runs) and $TESTER_SESSION; both
# are pinned per call below, so the run never reaches a contributor's real
# Tester folder.
WT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOOK="$WT/ui-tester/scripts/prune-runs.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/prune-runs-test.XXXXXX")" || { echo "FAIL: cannot create a scratch directory"; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "FAIL: cannot create a scratch directory"; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { # assert <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
refute() { # refute <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}

OLD=202001010000   # touch -t stamp well past the 7-day window
RUNS="$SCRATCH/.claude/tester/runs"

old() { # old <path...>: backdate every path given, and everything inside it
  local p
  for p in "$@"; do find "$p" -exec touch -h -t "$OLD" {} +; done
}
run_hook() { # run_hook <TESTER_SESSION value>
  env HOME="$SCRATCH" TESTER_SESSION="$1" bash "$HOOK" </dev/null
}
fixture() {
  rm -rf "$SCRATCH/.claude"
  mkdir -p "$RUNS/old-run/sub" "$RUNS/fresh-run" "$RUNS/old-dir-fresh-file" "$RUNS/-dash-run"
  echo v >"$RUNS/old-run/verdict.md"; echo s >"$RUNS/old-run/sub/shot.png"
  echo v >"$RUNS/fresh-run/verdict.md"
  echo v >"$RUNS/old-dir-fresh-file/verdict.md"
  echo v >"$RUNS/-dash-run/verdict.md"
  echo x >"$RUNS/stray.txt"
  echo x >"$RUNS/.hidden-old"
  mkdir -p "$SCRATCH/outside"; echo keep >"$SCRATCH/outside/keep.txt"
  ln -s "$SCRATCH/outside" "$RUNS/link-run"
  old "$RUNS/old-run" "$RUNS/-dash-run" "$RUNS/stray.txt" "$RUNS/.hidden-old" "$RUNS/link-run" "$SCRATCH/outside"
  # The folder is old but a file inside it was written now (a recheck).
  touch -t "$OLD" "$RUNS/old-dir-fresh-file"
}

echo "== Not a Tester session: nothing is touched =="
fixture
out=$(run_hook "")
assert "old run kept" test -d "$RUNS/old-run"
assert "no output" test -z "$out"

echo "== Tester session: old entries go, recent ones stay =="
fixture
out=$(run_hook 1); rc=$?
assert "exit 0" test "$rc" -eq 0
refute "old run removed" test -e "$RUNS/old-run"
refute "old run named with a leading dash removed" test -e "$RUNS/-dash-run"
refute "old stray file removed" test -e "$RUNS/stray.txt"
refute "old hidden file removed" test -e "$RUNS/.hidden-old"
refute "old symlink removed" test -L "$RUNS/link-run"
assert "symlink target untouched" test -f "$SCRATCH/outside/keep.txt"
assert "fresh run kept" test -f "$RUNS/fresh-run/verdict.md"
assert "old folder with a fresh file kept" test -f "$RUNS/old-dir-fresh-file/verdict.md"
assert "runs/ itself kept" test -d "$RUNS"
case "$out" in
  "Removed 5 Tester run folder(s) "*) ok "reports the count" ;;
  *) fail "reports the count (got: $out)" ;;
esac

echo "== Nothing to prune: silent =="
out=$(run_hook 1)
assert "no output on a second run" test -z "$out"

echo "== No runs/ folder: silent success =="
rm -rf "$SCRATCH/.claude"
out=$(run_hook 1); rc=$?
assert "exit 0 without runs/" test "$rc" -eq 0
assert "no output without runs/" test -z "$out"

echo "== Symlinked runs/: left alone =="
rm -rf "$SCRATCH/.claude" "$SCRATCH/elsewhere"
mkdir -p "$SCRATCH/.claude/tester" "$SCRATCH/elsewhere/old-run"
echo v >"$SCRATCH/elsewhere/old-run/verdict.md"
old "$SCRATCH/elsewhere/old-run"
ln -s "$SCRATCH/elsewhere" "$RUNS"
run_hook 1 >/dev/null
assert "old run behind a symlinked runs/ kept" test -f "$SCRATCH/elsewhere/old-run/verdict.md"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
