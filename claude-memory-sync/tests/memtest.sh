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
mkdir -p "$STORE/memory" "$STORE/user"
cp "$TPL/gitignore" "$STORE/.gitignore"
cp "$TPL/gitattributes" "$STORE/.gitattributes"
cp "$TPL/README.md" "$STORE/README.md"
cp "$TPL/user/CLAUDE.md" "$STORE/user/CLAUDE.md"
cp "$TPL/user/MEMORY.md" "$STORE/user/MEMORY.md"
env HOME="$SCRATCH" git -C "$STORE" init -q -b main
env HOME="$SCRATCH" git -C "$STORE" add -A
env HOME="$SCRATCH" git -C "$STORE" commit -q -m "init"
env HOME="$SCRATCH" git -C "$STORE" remote add origin "$REMOTE"
env HOME="$SCRATCH" git -C "$STORE" push -q -u origin main
printf '%s\n' "testowner/teststate" > "$DATA/state-repo"
# User-scope chain on this machine (stamped hub + @ line in the user's
# CLAUDE.md), so the healthy-quiet install-check assertions below exercise
# the full integrity chain end to end.
sed "s|{{STORE}}|$STORE|g" "$TPL/instructions.md" > "$DATA/CLAUDE.md"
printf '<!-- claude-memory-sync: synced user-scope context -->\n@%s/CLAUDE.md\n' "$DATA" > "$SCRATCH/.claude/CLAUDE.md"

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

# ---------- 14: custom store path via state-dir marker ----------
# Proves both hooks honor a non-default store location: the store lives at
# an arbitrary path named by $DATA/state-dir, and the default
# ~/.claude-memory-sync is never created or consulted.
echo "== 14: custom store path =="
SCRATCH3="$(mktemp -d /private/tmp/memsync-test3.XXXXXX)"
cp "$SCRATCH/.gitconfig" "$SCRATCH3/.gitconfig"
DATA3="$SCRATCH3/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins"
CUSTOM_STORE="$SCRATCH3/xdg/memstore"   # deliberately not ~/.claude-memory-sync
mkdir -p "$SCRATCH3/.claude/projects" "$DATA3" "$(dirname "$CUSTOM_STORE")"
printf '%s\n' "testowner/teststate" > "$DATA3/state-repo"
printf '%s\n' "$CUSTOM_STORE" > "$DATA3/state-dir"
# Deliberately stale hub: the sync run below must re-render it with the
# CUSTOM store path from state-dir, not the default.
printf 'stale hub awaiting re-stamp\n' > "$DATA3/CLAUDE.md"
printf '@%s/CLAUDE.md\n' "$DATA3" > "$SCRATCH3/.claude/CLAUDE.md"
env HOME="$SCRATCH3" git clone -q "$REMOTE" "$CUSTOM_STORE"
M3PROJ="$SCRATCH3/code/kernova-sim-custom"
mkdir -p "$M3PROJ"
git -C "$M3PROJ" init -q -b main
git -C "$M3PROJ" remote add origin "https://github.com/testowner/kernova-sim.git"
env HOME="$SCRATCH3" CLAUDE_PROJECT_DIR="$M3PROJ" bash "$SYNC" pull </dev/null
M3SLUG="$(slug "$M3PROJ")"
M3LINK="$SCRATCH3/.claude/projects/$M3SLUG/memory"
assert "linked into the custom store" test -L "$M3LINK"
assert "symlink target is under custom store" sh -c "case \"\$(cd '$M3LINK' && pwd -P)\" in '$CUSTOM_STORE'/*) exit 0;; *) exit 1;; esac"
assert "default store path never created" test ! -e "$SCRATCH3/.claude-memory-sync"
assert "hub re-stamped with the custom store path" grep -qF "@$CUSTOM_STORE/user/CLAUDE.md" "$DATA3/CLAUDE.md"
assert "install-check quiet for custom-store project" test -z "$(env HOME="$SCRATCH3" CLAUDE_PROJECT_DIR="$M3PROJ" bash "$CHECK" </dev/null)"

# ---------- 15: identical local copy auto-relinks (uninstall→reinstall) ----------
# A uninstall (restores a real local dir from the store) followed by a
# reinstall (re-clones the still-populated remote) leaves byte-identical
# payload on both sides. That must NOT read as CONFLICT — the redundant copy
# is dropped and the symlink restored automatically. Divergent payload (test
# 8) still conflicts.
echo "== 15: identical-copy auto-relink =="
RPROJ="$SCRATCH/dev/reinstall-sim"
mkdir -p "$RPROJ"
git -C "$RPROJ" init -q -b main
git -C "$RPROJ" remote add origin "https://github.com/testowner/reinstall-sim.git"
RSLUG="$(slug "$RPROJ")"
mkdir -p "$PROJECTS/$RSLUG/memory"
printf '# Memory index\n- reinstall fact\n' > "$PROJECTS/$RSLUG/memory/MEMORY.md"
printf 'detail body\n' > "$PROJECTS/$RSLUG/memory/detail.md"
run_sync "$RPROJ" push                       # adopt → store dir + symlink
RSDIR="$STORE/memory/github-testowner-reinstall-sim"
assert "reinstall: adopted to store" test -L "$PROJECTS/$RSLUG/memory" -a -d "$RSDIR"
# simulate uninstall restore: byte-identical real dir, .origin stripped
RTGT="$(cd "$PROJECTS/$RSLUG/memory" && pwd -P)"
rm "$PROJECTS/$RSLUG/memory"
cp -a "$RTGT" "$PROJECTS/$RSLUG/memory"
rm -f "$PROJECTS/$RSLUG/memory/.origin"
assert "reinstall: restored real dir matches store" sh -c "test ! -L '$PROJECTS/$RSLUG/memory' && diff -r -x .origin '$RSDIR' '$PROJECTS/$RSLUG/memory'"
assert "install-check quiet for identical copy" test -z "$(run_check "$RPROJ")"
run_sync "$RPROJ" pull                        # should auto-relink, not conflict
assert "identical local copy auto-relinked" test -L "$PROJECTS/$RSLUG/memory"
assert "relink points back to store dir" test "$(cd "$PROJECTS/$RSLUG/memory" && pwd -P)" = "$(cd "$RSDIR" && pwd -P)"
assert "store payload intact after relink" test -f "$RSDIR/MEMORY.md" -a -f "$RSDIR/detail.md"

# A PATH-stubbed `claude` keeps merge-driver tests hermetic: the real CLI
# must never run inside the harness. Tests 16-18 use the failing stub so any
# driver invocation falls back to deterministic git merge-file.
STUB="$SCRATCH/bin"
mkdir -p "$STUB"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$STUB/claude"
chmod +x "$STUB/claude"
run_sync_stub() { # run_sync_stub <projdir> <pull|push>
  env HOME="$SCRATCH" PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$1" bash "$SYNC" "$2" </dev/null
}

# ---------- 16: stranded commit pushed on pull ----------
# SessionEnd is the unreliable boundary: a crash or offline push leaves a
# local commit stranded. The next pull must publish it, not skip out at the
# already-current check.
echo "== 16: stranded commit pushed on pull =="
printf -- '- stranded fact\n' >> "$RSDIR/MEMORY.md"
env HOME="$SCRATCH" git -C "$STORE" add -A
env HOME="$SCRATCH" git -C "$STORE" commit -q -m "stranded"
assert "precondition: local ahead of origin" sh -c "test \"\$(env HOME='$SCRATCH' git -C '$STORE' rev-parse HEAD)\" != \"\$(git -C '$REMOTE' rev-parse main)\""
run_sync "$RPROJ" pull
assert "pull pushed the stranded commit" test "$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)"

# ---------- 17: diverged histories merge on pull and publish ----------
echo "== 17: diverged merge + push =="
TMP2="$SCRATCH/machine2-store"
env HOME="$SCRATCH" git clone -q "$REMOTE" "$TMP2"
printf 'note from machine two\n' > "$TMP2/memory/github-testowner-reinstall-sim/other_machine.md"
env HOME="$SCRATCH" git -C "$TMP2" add -A
env HOME="$SCRATCH" git -C "$TMP2" commit -q -m "machine two"
env HOME="$SCRATCH" git -C "$TMP2" push -q origin main
printf -- '- local divergent fact\n' >> "$PROJECTS/$RSLUG/memory/MEMORY.md"
run_sync_stub "$RPROJ" pull
assert "histories merged and pushed" test "$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)"
assert "their file arrived" test -f "$RSDIR/other_machine.md"
assert "local fact survived the merge" grep -q 'local divergent fact' "$RSDIR/MEMORY.md"

# ---------- 18: interrupted-merge recovery ----------
# A run killed mid-merge leaves MERGE_HEAD + conflict markers. The next sync
# must abort that stale merge instead of letting commit_local blindly commit
# the markers and complete the half-done merge.
echo "== 18: interrupted-merge recovery =="
env HOME="$SCRATCH" git -C "$TMP2" pull -q origin main
printf '# Memory index (machine two title)\n' > "$TMP2/memory/github-testowner-reinstall-sim/MEMORY.md"
env HOME="$SCRATCH" git -C "$TMP2" add -A
env HOME="$SCRATCH" git -C "$TMP2" commit -q -m "machine two retitle"
env HOME="$SCRATCH" git -C "$TMP2" push -q origin main
printf '# Memory index (machine one title)\n' > "$PROJECTS/$RSLUG/memory/MEMORY.md"
env HOME="$SCRATCH" git -C "$STORE" add -A
env HOME="$SCRATCH" git -C "$STORE" commit -q -m "machine one retitle"
env HOME="$SCRATCH" git -C "$STORE" fetch -q origin main
env HOME="$SCRATCH" PATH="$STUB:$PATH" git -C "$STORE" merge origin/main >/dev/null 2>&1
assert "precondition: merge stopped mid-way" test -f "$STORE/.git/MERGE_HEAD"
run_sync_stub "$RPROJ" pull
assert "stale MERGE_HEAD cleared" test ! -f "$STORE/.git/MERGE_HEAD"
assert "working tree clean after recovery" test -z "$(env HOME="$SCRATCH" git -C "$STORE" status --porcelain)"
assert "no conflict markers in memory file" sh -c "! grep -q '<<<<<<<' '$RSDIR/MEMORY.md'"
assert "no conflict markers committed" sh -c "! env HOME='$SCRATCH' git -C '$STORE' grep -q '<<<<<<<' HEAD"
assert "recovery logged" grep -q 'stale merge state' "$DATA/sync.log"
# converge for the remaining tests (the real conflict stays deferred here)
env HOME="$SCRATCH" git -C "$STORE" reset -q --hard origin/main

# ---------- 19: renamed/transferred origin → CONFLICT, never auto-healed ----------
echo "== 19: renamed-origin conflict =="
git -C "$RPROJ" remote set-url origin "https://github.com/testowner/reinstall-sim-renamed.git"
run_sync "$RPROJ" pull
assert "symlink left in place" test -L "$PROJECTS/$RSLUG/memory"
assert "still points at the old store dir" test "$(cd "$PROJECTS/$RSLUG/memory" && pwd -P)" = "$(cd "$RSDIR" && pwd -P)"
assert "no fresh store dir adopted" test ! -e "$STORE/memory/github-testowner-reinstall-sim-renamed"
RNUDGE="$(run_check "$RPROJ")"
assert "install-check explains the rename" sh -c "printf '%s' \"$RNUDGE\" | grep -q 'renamed or transferred'"
# apply the prescribed fix: update the breadcrumb to the new identity
printf 'github.com/testowner/reinstall-sim-renamed\n' > "$RSDIR/.origin"
run_sync "$RPROJ" push
assert "relinked under updated .origin" test "$(cd "$PROJECTS/$RSLUG/memory" && pwd -P)" = "$(cd "$RSDIR" && pwd -P)"
assert "install-check quiet after .origin fix" test -z "$(run_check "$RPROJ")"
assert "breadcrumb fix committed" test -z "$(env HOME="$SCRATCH" git -C "$STORE" status --porcelain)"

# ---------- 20: merge-driver plausibility guard ----------
# A hallucinated/truncated AI merge (far smaller than the smaller input)
# must be rejected in favor of git merge-file; a plausible union is accepted.
echo "== 20: merge-driver output guard =="
MD="$SCRATCH/mergetest"
mkdir -p "$MD"
{ printf '# Memory index\n'; for i in 1 2 3 4 5 6 7 8; do printf -- '- long-standing fact number %s\n' "$i"; done; } > "$MD/base"
{ printf -- '- ours leading fact\n'; cat "$MD/base"; } > "$MD/ours"
{ cat "$MD/base"; printf -- '- theirs trailing fact\n'; } > "$MD/theirs"
printf '#!/bin/sh\ncat >/dev/null\nprintf "<<<MERGED>>>\\ntiny\\n<<<END>>>\\n"\n' > "$STUB/claude"
cp "$MD/ours" "$MD/ours.run"
env HOME="$SCRATCH" PATH="$STUB:$PATH" bash "$SCRIPTS/claude-merge.sh" "$MD/base" "$MD/ours.run" "$MD/theirs" "memtest.md"
assert "tiny output rejected (merge-file ran)" sh -c "! grep -q tiny '$MD/ours.run'"
assert "deterministic union kept both sides" sh -c "grep -q 'ours leading fact' '$MD/ours.run' && grep -q 'theirs trailing fact' '$MD/ours.run'"
{ printf '<<<MERGED>>>\n'; printf -- '- ours leading fact\n'; cat "$MD/base"; printf -- '- theirs trailing fact\n'; printf '<<<END>>>\n'; } > "$MD/plausible"
printf '#!/bin/sh\ncat >/dev/null\ncat "%s"\n' "$MD/plausible" > "$STUB/claude"
cp "$MD/ours" "$MD/ours.run"
env HOME="$SCRATCH" PATH="$STUB:$PATH" bash "$SCRIPTS/claude-merge.sh" "$MD/base" "$MD/ours.run" "$MD/theirs" "memtest.md"
assert "plausible AI merge accepted" sh -c "grep -q 'ours leading fact' '$MD/ours.run' && grep -q 'theirs trailing fact' '$MD/ours.run' && grep -q 'fact number 8' '$MD/ours.run'"

# ---------- 21: instruction hub stamping ----------
# The hub is refresh-only: a stale hub (the template changed under a plugin
# update) is re-rendered with the store path baked in; an absent hub (user
# scope never enabled on this machine) is never created by the hook.
echo "== 21: instruction hub stamping =="
printf 'stale hub from an older plugin version\n' > "$DATA/CLAUDE.md"
run_sync "$PROJ3" pull
assert "stale hub re-stamped with store imports" grep -qF "@$STORE/user/CLAUDE.md" "$DATA/CLAUDE.md"
assert "no placeholder left unrendered" sh -c "! grep -q '{{STORE}}' '$DATA/CLAUDE.md'"
assert "re-stamp logged" grep -q 'instruction hub re-stamped' "$DATA/sync.log"
HUB_SUM="$(cksum < "$DATA/CLAUDE.md")"
run_sync "$PROJ3" pull
assert "re-stamp is content-stable" test "$(cksum < "$DATA/CLAUDE.md")" = "$HUB_SUM"
assert "no tmp litter" test ! -e "$DATA/CLAUDE.md.tmp"
rm "$DATA/CLAUDE.md"
run_sync "$PROJ3" pull
assert "absent hub not created by the hook" test ! -e "$DATA/CLAUDE.md"
sed "s|{{STORE}}|$STORE|g" "$TPL/instructions.md" > "$DATA/CLAUDE.md"   # restore

# ---------- 22: user-scope integrity nudges ----------
# install-check validates the whole import chain and nudges on the first gap;
# every gap re-asserts each session and the fix is the idempotent install
# skill (or, for the @ line, a consented one-line edit).
echo "== 22: user-scope integrity nudges =="
printf '# only my own machine-local stuff\n' > "$SCRATCH/.claude/CLAUDE.md"
run_check "$PROJ3" > "$SCRATCH/out22a"
assert "edited-out @ line nudges with the exact line" grep -qF "@$DATA/CLAUDE.md" "$SCRATCH/out22a"
printf '<!-- claude-memory-sync: synced user-scope context -->\n@%s/CLAUDE.md\n' "$DATA" >> "$SCRATCH/.claude/CLAUDE.md"
assert "quiet once @ line restored" test -z "$(run_check "$PROJ3")"
mv "$DATA/CLAUDE.md" "$SCRATCH/hub-aside"            # pre-0.5.0 machine: no hub
run_check "$PROJ3" > "$SCRATCH/out22b"
assert "missing hub nudges (the upgrade path)" grep -q 'instruction hub' "$SCRATCH/out22b"
assert "missing-hub nudge points at install" grep -q 'claude-memory-sync:install' "$SCRATCH/out22b"
mv "$SCRATCH/hub-aside" "$DATA/CLAUDE.md"
mv "$STORE/user" "$SCRATCH/user-aside"               # pre-0.5.0 store: no user/
run_check "$PROJ3" > "$SCRATCH/out22c"
assert "missing store user files nudges install" grep -q 'claude-memory-sync:install' "$SCRATCH/out22c"
mv "$SCRATCH/user-aside" "$STORE/user"
assert "quiet when the chain is fully healthy" test -z "$(run_check "$PROJ3")"

# ---------- 23: user-scope content round-trips ----------
echo "== 23: user-scope content round-trips =="
printf -- '- [Round-trip fact](round-trip-fact.md) — global memory test\n' >> "$STORE/user/MEMORY.md"
printf 'a global fact that must reach every machine\n' > "$STORE/user/round-trip-fact.md"
run_sync "$PROJ3" push
assert "user-scope change committed and pushed" test "$(env HOME="$SCRATCH" git -C "$STORE" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)"
env HOME="$SCRATCH" git -C "$TMP2" pull -q origin main
assert "second machine sees the global memory" grep -q 'a global fact' "$TMP2/user/round-trip-fact.md"
assert "second machine sees the index line" grep -q 'Round-trip fact' "$TMP2/user/MEMORY.md"

# ---------- summary ----------
echo "=================================="
echo "PASS=$PASS FAIL=$FAIL  (scratch: $SCRATCH)"
[ "$FAIL" -eq 0 ]
