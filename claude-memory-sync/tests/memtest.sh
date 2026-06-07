#!/bin/bash
# Scratch-HOME verification harness for claude-memory-sync.
# Usage: bash tests/memtest.sh [repo-root]   (defaults to this checkout)
# Exercises claude-sync.sh / install-check.sh from the worktree against a
# throwaway HOME with a local bare repo as origin. No network, no real state.
set -u

WT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPTS="$WT/claude-memory-sync/scripts"
TPL="$WT/claude-memory-sync/templates"
SYNC="$SCRIPTS/claude-sync.sh"
CHECK="$SCRIPTS/install-check.sh"

SCRATCH="$(mktemp -d /private/tmp/memsync-test.XXXXXX)"
STORE="$SCRATCH/.claude-memory-sync"
PROJECTS="$SCRATCH/.claude/projects"
DATA="$SCRATCH/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins"
REMOTE="$SCRATCH/remotes/testowner/teststate.git"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { # assert <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

slug() { printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9]/-/g'; }

run_sync() { # run_sync <projdir> <pull|push>
  env HOME="$SCRATCH" CLAUDE_PROJECT_DIR="$1" bash "$SYNC" "$2" </dev/null
}
run_check() { # run_check <projdir>
  env HOME="$SCRATCH" CLAUDE_PROJECT_DIR="$1" bash "$CHECK" </dev/null
}

# ---------- setup ----------
echo "== setup (SCRATCH=$SCRATCH) =="
mkdir -p "$SCRATCH" "$PROJECTS" "$DATA" "$(dirname "$REMOTE")"
cat > "$SCRATCH/.gitconfig" <<EOF
[user]
	name = Mem Test
	email = memtest@example.invalid
[init]
	defaultBranch = main
EOF
git init --bare -q "$REMOTE"
mkdir -p "$STORE/memory"
cp "$TPL/gitignore" "$STORE/.gitignore"
cp "$TPL/gitattributes" "$STORE/.gitattributes"
cp "$TPL/README.md" "$STORE/README.md"
env HOME="$SCRATCH" git -C "$STORE" init -q -b main
env HOME="$SCRATCH" git -C "$STORE" add -A
env HOME="$SCRATCH" git -C "$STORE" commit -q -m "init"
env HOME="$SCRATCH" git -C "$STORE" remote add origin "$REMOTE"
env HOME="$SCRATCH" git -C "$STORE" push -q -u origin main
printf '%s\n' "testowner/teststate" > "$DATA/state-repo"

# ---------- 1: adopt a git project ----------
echo "== 1: adoption of a git project =="
PROJ="$SCRATCH/dev/kernova-sim"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" remote add origin "https://github.com/TestOwner/Kernova-Sim.git"
PSLUG="$(slug "$PROJ")"
mkdir -p "$PROJECTS/$PSLUG/memory"
printf '# Memory index\n- fact one\n' > "$PROJECTS/$PSLUG/memory/MEMORY.md"
printf 'topic body\n' > "$PROJECTS/$PSLUG/memory/topic_a.md"
run_sync "$PROJ" push
SDIR="$STORE/memory/github-testowner-kernova-sim"
assert "store dir created with normalized name" test -d "$SDIR"
assert ".origin normalized (lowercase, no .git)" test "$(head -n1 "$SDIR/.origin")" = "github.com/testowner/kernova-sim"
assert "memory files moved into store" test -f "$SDIR/MEMORY.md" -a -f "$SDIR/topic_a.md"
assert "projects memory is now a symlink" test -L "$PROJECTS/$PSLUG/memory"
assert "symlink resolves to store dir" test "$(cd "$PROJECTS/$PSLUG/memory" && pwd -P)" = "$(cd "$SDIR" && pwd -P)"
assert "adoption committed" test -z "$(env HOME="$SCRATCH" git -C "$STORE" status --porcelain)"
assert "pushed to origin" test "$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)"

# ---------- 2: idempotence ----------
echo "== 2: idempotence =="
BEFORE="$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)"
run_sync "$PROJ" push
run_sync "$PROJ" pull
assert "no new commits on repeat runs" test "$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)" = "$BEFORE"
assert "still a symlink" test -L "$PROJECTS/$PSLUG/memory"

# ---------- 3: second clone, same origin ----------
echo "== 3: two clones, one origin =="
PROJ2="$SCRATCH/dev/copy2"
git clone -q "$PROJ" "$PROJ2"
git -C "$PROJ2" remote set-url origin "git@github.com:TestOwner/Kernova-Sim.git"
P2SLUG="$(slug "$PROJ2")"
run_sync "$PROJ2" pull
assert "second clone slug linked" test -L "$PROJECTS/$P2SLUG/memory"
assert "links to the SAME store dir" test "$(cd "$PROJECTS/$P2SLUG/memory" && pwd -P)" = "$(cd "$SDIR" && pwd -P)"
assert "no duplicate store dir" test "$(ls "$STORE/memory" | wc -l | tr -d ' ')" = "1"

# ---------- 4: worktree resolves to main root ----------
echo "== 4: worktree unification =="
( cd "$PROJ" && git commit -q --allow-empty -m base && git worktree add -q ../kernova-sim-wt -b tbranch )
run_sync "$SCRATCH/dev/kernova-sim-wt" push
WSLUG="$(slug "$SCRATCH/dev/kernova-sim-wt")"
assert "no link created at worktree slug" test ! -e "$PROJECTS/$WSLUG/memory"
assert "main slug still linked" test -L "$PROJECTS/$PSLUG/memory"
assert "still a single store dir" test "$(ls "$STORE/memory" | wc -l | tr -d ' ')" = "1"

# ---------- 5: non-git project ----------
echo "== 5: non-git project =="
PLAIN="$SCRATCH/plain dir"
mkdir -p "$PLAIN"
PLSLUG="$(slug "$PLAIN")"
mkdir -p "$PROJECTS/$PLSLUG/memory"
printf '# Memory index\n- plain fact\n' > "$PROJECTS/$PLSLUG/memory/MEMORY.md"
run_sync "$PLAIN" push
assert "slug-named store dir" test -d "$STORE/memory/$PLSLUG"
assert "path: breadcrumb" test "$(head -n1 "$STORE/memory/$PLSLUG/.origin")" = "path:$PLAIN"
assert "linked" test -L "$PROJECTS/$PLSLUG/memory"

# ---------- 6: hand-renamed store dir heals via .origin ----------
echo "== 6: hand-rename heal =="
env HOME="$SCRATCH" git -C "$STORE" mv memory/github-testowner-kernova-sim memory/renamed-by-hand -q 2>/dev/null \
  || mv "$SDIR" "$STORE/memory/renamed-by-hand"
run_sync "$PROJ" push
assert "symlink repointed to renamed dir" test "$(cd "$PROJECTS/$PSLUG/memory" && pwd -P)" = "$(cd "$STORE/memory/renamed-by-hand" && pwd -P)"
assert "no duplicate dir adopted" test ! -d "$STORE/memory/github-testowner-kernova-sim"
RENAMED="$STORE/memory/renamed-by-hand"

# ---------- 7: severed link (empty real dir shadows store) ----------
echo "== 7: severed-link heal =="
rm "$PROJECTS/$PSLUG/memory"
mkdir "$PROJECTS/$PSLUG/memory"   # harness-style fresh empty dir
run_sync "$PROJ" pull
assert "empty real dir replaced by symlink" test -L "$PROJECTS/$PSLUG/memory"
assert "store payload intact" test -f "$RENAMED/MEMORY.md"

# ---------- 8: conflict is never auto-resolved ----------
echo "== 8: conflict handling =="
rm "$PROJECTS/$PSLUG/memory"
mkdir "$PROJECTS/$PSLUG/memory"
printf '# divergent\n' > "$PROJECTS/$PSLUG/memory/MEMORY.md"
run_sync "$PROJ" push
assert "local real dir untouched" test ! -L "$PROJECTS/$PSLUG/memory"
assert "local payload untouched" grep -q divergent "$PROJECTS/$PSLUG/memory/MEMORY.md"
assert "store payload untouched" test -f "$RENAMED/MEMORY.md"
NUDGE="$(run_check "$PROJ")"
assert "install-check nudges on conflict" sh -c "printf '%s' \"$NUDGE\" | grep -q 'both locally'"
# restore linked state for later tests
rm -rf "$PROJECTS/$PSLUG/memory"
run_sync "$PROJ" pull
assert "relinked after conflict cleared" test -L "$PROJECTS/$PSLUG/memory"

# ---------- 9: self-reference guard ----------
echo "== 9: self-reference guard =="
COUNT_BEFORE="$(ls "$STORE/memory" | wc -l | tr -d ' ')"
run_sync "$STORE" push
assert "no store dir for the store itself" test "$(ls "$STORE/memory" | wc -l | tr -d ' ')" = "$COUNT_BEFORE"

# ---------- 10: stdin-JSON cwd fallback ----------
echo "== 10: stdin cwd fallback =="
PROJ3="$SCRATCH/dev/third_proj"
mkdir -p "$PROJ3"
P3SLUG="$(slug "$PROJ3")"
mkdir -p "$PROJECTS/$P3SLUG/memory"
printf '# Memory index\n- stdin fact\n' > "$PROJECTS/$P3SLUG/memory/MEMORY.md"
printf '{"session_id":"x","cwd":"%s","hook_event_name":"SessionEnd"}' "$PROJ3" \
  | env HOME="$SCRATCH" bash "$SYNC" push
assert "adopted via stdin cwd" test -L "$PROJECTS/$P3SLUG/memory"
assert "store dir exists for stdin project" test -d "$STORE/memory/$P3SLUG"

# ---------- 11: new-machine simulation ----------
echo "== 11: new machine =="
SCRATCH2="$(mktemp -d /private/tmp/memsync-test2.XXXXXX)"
cp "$SCRATCH/.gitconfig" "$SCRATCH2/.gitconfig"
DATA2="$SCRATCH2/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins"
mkdir -p "$SCRATCH2/.claude/projects" "$DATA2"
printf '%s\n' "testowner/teststate" > "$DATA2/state-repo"
env HOME="$SCRATCH2" git clone -q "$REMOTE" "$SCRATCH2/.claude-memory-sync"
M2PROJ="$SCRATCH2/code/kernova-sim-here"   # different path than machine 1
mkdir -p "$M2PROJ"
git -C "$M2PROJ" init -q -b main
git -C "$M2PROJ" remote add origin "https://github.com/testowner/kernova-sim.git"
env HOME="$SCRATCH2" CLAUDE_PROJECT_DIR="$M2PROJ" bash "$SYNC" pull </dev/null
M2SLUG="$(slug "$M2PROJ")"
assert "new machine linked by origin identity" test -L "$SCRATCH2/.claude/projects/$M2SLUG/memory"
assert "memory readable through link" grep -q "fact one" "$SCRATCH2/.claude/projects/$M2SLUG/memory/MEMORY.md"

# ---------- 12: uninstall restoration semantics ----------
echo "== 12: uninstall restore =="
TGT="$(cd "$PROJECTS/$PSLUG/memory" && pwd -P)"
rm "$PROJECTS/$PSLUG/memory"
cp -a "$TGT" "$PROJECTS/$PSLUG/memory"
rm -f "$PROJECTS/$PSLUG/memory/.origin"
assert "restored real dir" test -d "$PROJECTS/$PSLUG/memory" -a ! -L "$PROJECTS/$PSLUG/memory"
assert "contents match store payload" diff -r -x .origin "$TGT" "$PROJECTS/$PSLUG/memory"
rm -f "$DATA/state-repo"; touch "$DATA/uninstalled"
assert "install-check silent after uninstall" test -z "$(run_check "$PROJ")"
assert "sync inert after uninstall" sh -c "env HOME='$SCRATCH' CLAUDE_PROJECT_DIR='$PROJ' bash '$SYNC' push </dev/null && true"

# ---------- 13: install-check silent when healthy ----------
echo "== 13: install-check healthy/quiet =="
rm -f "$DATA/uninstalled"; printf '%s\n' "testowner/teststate" > "$DATA/state-repo"
OUT="$(run_check "$PROJ3")"
assert "no output for healthy linked project" test -z "$OUT"

# ---------- summary ----------
echo "=================================="
echo "PASS=$PASS FAIL=$FAIL  (scratch: $SCRATCH)"
[ "$FAIL" -eq 0 ]
