#!/bin/bash
# Scratch-HOME harness for the ui-tester plugin's prune-runs.sh SessionStart hook
# and the run-folder location it shares with after-compact.sh (lib-paths.sh).
# Usage: bash ui-tester/tests/prune-runs.sh [repo-root]   (defaults to this checkout)
set -u

# The hook reads $HOME, $XDG_CACHE_HOME (off macOS) and $TESTER_SESSION. HOME and
# TESTER_SESSION are pinned per call below; XDG_CACHE_HOME is cleared here, so
# the run never reaches a contributor's real cache or Tester folders.
unset XDG_CACHE_HOME
WT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPTS="$WT/ui-tester/scripts"
HOOK="$SCRIPTS/prune-runs.sh"
AFTER="$SCRIPTS/after-compact.sh"

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

# Where the scripts must put run folders under the scratch HOME.
case "$(uname -s)" in
  Darwin) CACHE="$SCRATCH/Library/Caches" ;;
  *)      CACHE="$SCRATCH/.cache" ;;
esac
RUNS="$CACHE/claude-tester/runs"
OLDRUNS="$SCRATCH/.claude/tester/runs"
OLD=202001010000   # touch -t stamp well past the 7-day window
RECENT=202611010000 # a fixed stamp the migration must carry over unchanged

backdate() { # backdate <path...>: backdate every path given, and everything inside it
  local p
  for p in "$@"; do find "$p" -exec touch -h -t "$OLD" {} +; done
}
run_hook() { # run_hook <TESTER_SESSION value>
  env HOME="$SCRATCH" TESTER_SESSION="$1" bash "$HOOK" </dev/null
}
reset() { rm -rf "$SCRATCH/.claude" "$SCRATCH/Library" "$SCRATCH/.cache" "$SCRATCH/outside" "$SCRATCH/elsewhere"; }
fixture() {
  reset
  mkdir -p "$RUNS/old-run/sub" "$RUNS/fresh-run" "$RUNS/old-dir-fresh-file" "$RUNS/-dash-run"
  echo v >"$RUNS/old-run/verdict.md"; echo s >"$RUNS/old-run/sub/shot.png"
  echo v >"$RUNS/fresh-run/verdict.md"
  echo v >"$RUNS/old-dir-fresh-file/verdict.md"
  echo v >"$RUNS/-dash-run/verdict.md"
  echo x >"$RUNS/stray.txt"
  echo x >"$RUNS/.hidden-old"
  mkdir -p "$SCRATCH/outside"; echo keep >"$SCRATCH/outside/keep.txt"
  ln -s "$SCRATCH/outside" "$RUNS/link-run"
  backdate "$RUNS/old-run" "$RUNS/-dash-run" "$RUNS/stray.txt" "$RUNS/.hidden-old" "$RUNS/link-run" "$SCRATCH/outside"
  # The folder is old but a file inside it was written now (a recheck).
  touch -t "$OLD" "$RUNS/old-dir-fresh-file"
}

echo "== Run folders live in the cache folder =="
runs_dir() { # runs_dir [XDG_CACHE_HOME value]: what lib-paths.sh answers under the scratch HOME
  local lib="$SCRIPTS/lib-paths.sh"
  if [ $# -gt 0 ]; then
    env HOME="$SCRATCH" XDG_CACHE_HOME="$1" bash -c ". \"$lib\"; tester_runs_dir"
  else
    env HOME="$SCRATCH" bash -c ". \"$lib\"; tester_runs_dir"
  fi
}
expect_eq() { # expect_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}
if [ "$(uname -s)" = Darwin ]; then
  expect_eq "macOS: ~/Library/Caches" "$SCRATCH/Library/Caches/claude-tester/runs" "$(runs_dir)"
else
  expect_eq "default: ~/.cache" "$SCRATCH/.cache/claude-tester/runs" "$(runs_dir)"
  expect_eq "XDG_CACHE_HOME honoured" "$SCRATCH/xdg/claude-tester/runs" "$(runs_dir "$SCRATCH/xdg")"
  expect_eq "relative XDG_CACHE_HOME ignored" "$SCRATCH/.cache/claude-tester/runs" "$(runs_dir relative/dir)"
fi

echo "== after-compact.sh names the run folders =="
reset
out=$(env HOME="$SCRATCH" TESTER_SESSION=1 bash "$AFTER" </dev/null)
case "$out" in
  *"$RUNS"*) ok "prints the run folders' path" ;;
  *) fail "prints the run folders' path (got: $out)" ;;
esac

echo "== Not a Tester session: nothing is touched =="
fixture
mkdir -p "$OLDRUNS/legacy"
out=$(run_hook "")
assert "old run kept" test -d "$RUNS/old-run"
assert "legacy folder not migrated" test -d "$OLDRUNS/legacy"
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

echo "== No run folders anywhere: silent success =="
reset
out=$(run_hook 1); rc=$?
assert "exit 0 without runs/" test "$rc" -eq 0
assert "no output without runs/" test -z "$out"
refute "no cache folder created" test -e "$RUNS"

echo "== Symlinked runs/: left alone =="
reset
mkdir -p "$(dirname "$RUNS")" "$SCRATCH/elsewhere/old-run" "$OLDRUNS/legacy"
echo v >"$SCRATCH/elsewhere/old-run/verdict.md"
backdate "$SCRATCH/elsewhere/old-run"
ln -s "$SCRATCH/elsewhere" "$RUNS"
run_hook 1 >/dev/null
assert "old run behind a symlinked runs/ kept" test -f "$SCRATCH/elsewhere/old-run/verdict.md"
assert "legacy folder not moved into a symlinked runs/" test -d "$OLDRUNS/legacy"

echo "== One-time move from ~/.claude/tester/runs =="
reset
mkdir -p "$OLDRUNS/legacy-run" "$OLDRUNS/-dash-legacy" "$OLDRUNS/legacy-stale"
echo v >"$OLDRUNS/legacy-run/verdict.md"; echo v >"$OLDRUNS/-dash-legacy/verdict.md"; echo v >"$OLDRUNS/legacy-stale/verdict.md"
touch -t "$RECENT" "$OLDRUNS/legacy-run/verdict.md"
backdate "$OLDRUNS/legacy-stale"
echo mine >"$SCRATCH/.claude/tester/state.md"
out=$(run_hook 1)
assert "run moved to the cache folder" test -f "$RUNS/legacy-run/verdict.md"
assert "run named with a leading dash moved" test -f "$RUNS/-dash-legacy/verdict.md"
refute "old runs/ folder removed once empty" test -e "$OLDRUNS"
assert "the rest of ~/.claude/tester untouched" test -f "$SCRATCH/.claude/tester/state.md"
assert "modification times carried over" test -n "$(find "$RUNS/legacy-run/verdict.md" -newermt "2026-10-31" ! -newermt "2026-11-02" 2>/dev/null)"
refute "a moved run past 7 days is then pruned" test -e "$RUNS/legacy-stale"
case "$out" in
  "Moved 3 Tester run folder(s) from "*) ok "reports the move" ;;
  *) fail "reports the move (got: $out)" ;;
esac
out=$(run_hook 1)
assert "second start is silent" test -z "$out"

echo "== Move never overwrites a run already in the cache folder =="
reset
mkdir -p "$OLDRUNS/same-name" "$OLDRUNS/only-old" "$RUNS/same-name"
echo old >"$OLDRUNS/same-name/verdict.md"; echo old >"$OLDRUNS/only-old/verdict.md"
echo new >"$RUNS/same-name/verdict.md"
run_hook 1 >/dev/null
assert "cache copy kept as it was" test "$(cat "$RUNS/same-name/verdict.md")" = new
assert "colliding old copy stays behind" test -f "$OLDRUNS/same-name/verdict.md"
assert "non-colliding run still moved" test -f "$RUNS/only-old/verdict.md"

echo "== Symlinked ~/.claude/tester/runs: not followed =="
reset
mkdir -p "$SCRATCH/elsewhere/other-run" "$SCRATCH/.claude/tester"
echo v >"$SCRATCH/elsewhere/other-run/verdict.md"
ln -s "$SCRATCH/elsewhere" "$OLDRUNS"
run_hook 1 >/dev/null
assert "target of the old symlink untouched" test -f "$SCRATCH/elsewhere/other-run/verdict.md"
refute "nothing moved into the cache folder" test -e "$RUNS/other-run"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
