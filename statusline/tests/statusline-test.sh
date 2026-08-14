#!/bin/bash
# Rendering harness for the statusline plugin.
# Usage: bash statusline/tests/statusline-test.sh [repo-root]   (defaults to this checkout)
# Feeds hand-built session JSON to statusline.sh and subagent-statusline.sh and
# asserts on the rendered text. Hermetic: scratch git repos under $TMPDIR, no
# network and no real session state. The only writes outside the scratch dir are
# the renderer's own /tmp git cache files, removed on exit.
#
# set -u without set -e, so one failed assertion reports and the run continues;
# the exit status is the FAIL count, which is what lets CI consume this harness
# as a plain `run:` step.
set -u

WT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
MAIN="$WT/statusline/scripts/statusline.sh"
SUB="$WT/statusline/scripts/subagent-statusline.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this harness"; exit 1; }

# mktemp + symlink-resolve: macOS's /tmp and $TMPDIR live behind /private, and
# the git assertions compare rendered basenames against $SCRATCH-built paths.
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")" && pwd -P)"
SESSIONS=()
cleanup() {
  local s
  for s in ${SESSIONS[@]+"${SESSIONS[@]}"}; do rm -f "/tmp/statusline-git-cache-$s"; done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      %s\n' "$(printf '%s' "$2" | cat -v)"; return 0; }

# Assertions read the last render from $OUT unless a haystack is passed.
OUT=""; RC=0
assert_eq() { # assert_eq <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
assert_has() { # assert_has <desc> <literal> [haystack]
  if printf '%s' "${3-$OUT}" | grep -qF -- "$2"; then ok "$1"; else fail "$1" "missing [$2] in [${3-$OUT}]"; fi
}
assert_lacks() { # assert_lacks <desc> <literal> [haystack]
  if printf '%s' "${3-$OUT}" | grep -qF -- "$2"; then fail "$1" "unexpected [$2] in [${3-$OUT}]"; else ok "$1"; fi
}
assert_re() { # assert_re <desc> <ere> [haystack]
  if printf '%s' "${3-$OUT}" | grep -qE -- "$2"; then ok "$1"; else fail "$1" "no match /$2/ in [${3-$OUT}]"; fi
}

ESC=$'\033'
RED="${ESC}[31m"; YEL="${ESC}[33m"; GRN="${ESC}[32m"; OFF="${ESC}[0m"

# Read at each use, never captured once: the harness runs for tens of seconds,
# and a startup timestamp would drift every elapsed/countdown assertion. Read
# through jq rather than `date +%s`, for the sub-second resolution the boundary
# cases need — a whole-second clock sits up to a second behind the renderer's
# own, which is enough to push a 59.5s payload over the minute boundary.
now_s()  { jq -n 'now | floor'; }
now_ms() { jq -n '(now * 1000) | floor'; }

# ---------- renderers ----------
# Every render runs with the harness's cwd inside $SCRATCH, so a payload that
# carries no workspace path resolves git state against a non-repo directory
# rather than against whatever checkout the harness was launched from. HOME
# points there too: statusline.sh shells out to git, and the invoking user's
# global gitconfig would otherwise decide what `git status --porcelain` reports.
render() { # render <tag> <cwd> <json-object>; sets $OUT/$RC
  local sid="sltest-$$-$1" cwd="$2" body="$3"
  SESSIONS+=("$sid")
  printf '%s' "$body" \
    | jq -c --arg s "$sid" --arg c "$cwd" '. + {session_id: $s, workspace: {current_dir: $c}}' \
    > "$SCRATCH/in.json" || { fail "render $1: test payload is not valid JSON"; return 0; }
  OUT=$(cd "$SCRATCH" && env HOME="$SCRATCH" bash "$MAIN" < "$SCRATCH/in.json" 2>"$SCRATCH/err"); RC=$?
}
render_raw() { # render_raw <raw-stdin>; sets $OUT/$RC
  OUT=$(printf '%s' "$1" | (cd "$SCRATCH" && env HOME="$SCRATCH" bash "$MAIN") 2>"$SCRATCH/err"); RC=$?
}
SESSIONS+=("default" "")   # ids the degenerate-input payloads fall back to
sub_render() { # sub_render <raw-stdin>; sets $OUT/$RC
  OUT=$(printf '%s' "$1" | bash "$SUB" 2>"$SCRATCH/err"); RC=$?
}
row() { printf '%s\n' "$OUT" | jq -r --arg id "$1" 'select(.id == $id) | .content'; }

g() { env HOME="$SCRATCH" git -C "$1" "${@:2}"; }

# ---------- setup ----------
echo "== setup (SCRATCH=$SCRATCH) =="
cat > "$SCRATCH/.gitconfig" <<'EOF'
[user]
	name = Statusline Test
	email = statusline@example.invalid
[init]
	defaultBranch = main
EOF
PLAIN="$SCRATCH/not-a-repo"
mkdir -p "$PLAIN"
REPO="$SCRATCH/demo-proj"
mkdir -p "$REPO"
g "$REPO" init -q -b main
printf 'hello\n' > "$REPO/README"
g "$REPO" add README
g "$REPO" commit -q -m "base"

# ---------- 1: degenerate input never breaks the line ----------
# A non-zero exit makes Claude Code discard the whole status line, so every
# input shape has to exit 0 — and render defaults rather than debris.
echo "== 1: degenerate input =="
render_raw ''
assert_eq "empty stdin exits 0" 0 "$RC"
assert_has "empty stdin still renders the git segment" "📦 no-git"
assert_has "empty stdin renders a zeroed context window" "💭 0% ↑0K ↓0K / 0K"
assert_lacks "empty stdin renders no churn segment" "📓"
render_raw '{"session_id": "x", '
assert_eq "truncated JSON exits 0" 0 "$RC"
assert_has "truncated JSON renders a zeroed context window" "💭 0% ↑0K ↓0K / 0K"
assert_lacks "truncated JSON renders no churn segment" "📓"
render_raw 'not json at all'
assert_eq "non-JSON stdin exits 0" 0 "$RC"
assert_has "non-JSON stdin renders the git segment" "📦 no-git"
render 2 "$PLAIN" '{}'
assert_eq "empty object exits 0" 0 "$RC"
assert_has "absent optional fields render defaults" "💭 0% ↑0K ↓0K / 0K"
assert_lacks "no PR segment without a PR" "🔀"
assert_lacks "no rate-limit segment without rate limits" "🔋"

# ---------- 2: model and effort ----------
echo "== 2: model + effort =="
render 3 "$PLAIN" '{"model": {"display_name": "Opus 5 (1M context)"}}'
assert_has "context-size suffix stripped from the display name" "🤖 Opus 5 |"
render 4 "$PLAIN" '{"model": {"display_name": "Opus 5 (1M context)"}, "effort": {"level": "xhigh"}}'
assert_has "effort level appended when present" "🤖 Opus 5 (xhigh) |"
render 5 "$PLAIN" '{"model": {"display_name": "Haiku 4.5"}}'
assert_has "display name without a suffix survives intact" "🤖 Haiku 4.5 |"

# ---------- 3: git state ----------
echo "== 3: git state =="
render 6 "$PLAIN" '{}'
assert_has "non-repo cwd reads as no-git" "📦 no-git"
render 7 "$REPO" '{}'
assert_has "clean repo renders project / branch" "📦 demo-proj / main |"

echo "-- worktree --"
g "$REPO" worktree add -q "$SCRATCH/demo-wt" -b feature
render 8 "$SCRATCH/demo-wt" '{}'
assert_has "worktree renders the leaf icon and parent branch" "🌿 demo-proj / feature ← main"

echo "-- ahead/behind --"
CLONE="$SCRATCH/demo-clone"
env HOME="$SCRATCH" git clone -q "$REPO" "$CLONE"
render 9 "$CLONE" '{}'
assert_has "in sync with upstream shows no counts" "📦 demo-clone / main |"
g "$CLONE" commit -q --allow-empty -m "local work"
render 10 "$CLONE" '{}'
assert_has "one local commit renders ahead" "demo-clone / main ↑1"
g "$REPO" commit -q --allow-empty -m "upstream work"
g "$CLONE" fetch -q origin
render 11 "$CLONE" '{}'
assert_has "diverged renders ahead and behind" "demo-clone / main ↑1↓1"

echo "-- dirty flags --"
DIRTY="$SCRATCH/dirty-proj"
mkdir -p "$DIRTY"
g "$DIRTY" init -q -b main
printf 'one\n' > "$DIRTY/tracked"
g "$DIRTY" add tracked
g "$DIRTY" commit -q -m "base"
printf 'two\n' > "$DIRTY/tracked"
render 12 "$DIRTY" '{}'
assert_has "modified tracked file renders *" "dirty-proj / main*"
printf 'new\n' > "$DIRTY/untracked"
render 13 "$DIRTY" '{}'
assert_has "modified plus untracked renders *+" "dirty-proj / main*+"
g "$DIRTY" checkout -q -- tracked
render 14 "$DIRTY" '{}'
assert_has "untracked alone renders +" "dirty-proj / main+"

# ---------- 4: context window ----------
echo "== 4: context window =="
ctx() { # ctx <tag> <used_pct> <in> <out> <window>
  render "$1" "$PLAIN" "$(printf '{"context_window": {"used_percentage": %s, "total_input_tokens": %s, "total_output_tokens": %s, "context_window_size": %s}}' "$2" "$3" "$4" "$5")"
}
ctx 20 69.4 1000 1000 200000
assert_has "just under 70% is uncolored" "💭 69% "
ctx 21 69.6 1000 1000 200000
assert_has "rounding up to 70% turns yellow" "💭 ${YEL}70%${OFF} "
ctx 22 89 1000 1000 200000
assert_has "just under 90% stays yellow" "💭 ${YEL}89%${OFF} "
ctx 23 90 1000 1000 200000
assert_has "90% turns red" "💭 ${RED}90%${OFF} "
ctx 24 0 0 0 200000
assert_has "0% renders uncolored with a real window" "💭 0% ↑0K ↓0K / 200K"

echo "-- token unit boundaries --"
ctx 25 10 999400 500 200000
assert_has "just under 1M stays in K" "↑999K"
assert_has "window size formats in K" "/ 200K"
ctx 26 10 999999 1000000 1000000
assert_has "999,999 tokens round into M, not 1000K" "↑1M"
assert_has "exactly 1M tokens renders M" "↓1M"
assert_has "1M window renders M" "/ 1M"
ctx 27 10 1500 0 200000
assert_has "sub-K counts round to the nearest K" "↑2K"
assert_has "zero renders as 0K" "↓0K"

echo "-- type errors --"
render 28 "$PLAIN" '{"model": {"display_name": "Opus 5"}, "context_window": {"used_percentage": "lots", "context_window_size": 200000}, "cost": {"total_lines_added": 3, "total_lines_removed": 1}}'
assert_eq "a bad field type still exits 0" 0 "$RC"
assert_has "the bad field reports ERROR" "💭 ERROR"
assert_has "segments before the bad field still render" "🤖 Opus 5"
assert_has "segments after the bad field still render" "📓 ${GRN}+3${OFF} ${RED}-1${OFF}"

# ---------- 5: rate limits ----------
# Pace coloring compares the *raw* percentage against elapsed window time, so
# these payloads set resets_at to the midpoint: half the window elapsed.
echo "== 5: rate limits =="
rl() { # rl <tag> <five_pct> <five_reset_delta> <seven_pct> <seven_reset_delta>
  render "$1" "$PLAIN" "$(printf '{"rate_limits": {"five_hour": {"used_percentage": %s, "resets_at": %s}, "seven_day": {"used_percentage": %s, "resets_at": %s}}}' \
    "$2" "$(( $(now_s) + $3 ))" "$4" "$(( $(now_s) + $5 ))")"
}
rl 30 49.5 9000 10 302400
assert_has "under pace is uncolored" "5h: 50% "
assert_lacks "under pace emits no color escape for 5h" "${YEL}50%"
rl 31 50.5 9000 10 302400
assert_has "above pace turns yellow" "5h: ${YEL}50%${OFF}"
rl 32 99.5 9000 10 302400
assert_has "just under twice pace stays yellow" "5h: ${YEL}100%${OFF}"
rl 33 100.5 9000 10 302400
assert_has "past twice pace turns red" "5h: ${RED}100%${OFF}"
rl 34 10 9000 60 302400
assert_has "the 7d window is paced independently" "7d: ${YEL}60%${OFF}"

echo "-- countdown units --"
rl 35 10 3570 10 302400
assert_re "under an hour counts down in minutes" '5h: 10% ↻[0-9]+m '
rl 36 10 3630 10 302400
assert_has "an hour and up counts down in hours" "5h: 10% ↻1h "
rl 37 10 9000 10 86430
assert_has "a day and up counts down in days" "7d: 10% ↻1d"
rl 38 10 9000 10 3630
assert_has "under a day counts down in hours" "7d: 10% ↻1h"
rl 39 10 -60 10 302400
assert_has "an elapsed reset clamps at zero" "5h: 10% ↻0m"

echo "-- partial payloads --"
render 40 "$PLAIN" "$(printf '{"rate_limits": {"five_hour": {"used_percentage": 40, "resets_at": %s}}}' "$(( $(now_s) + 9000 ))")"
assert_eq "a five-hour-only payload exits 0" 0 "$RC"
assert_has "the present window still renders" "🔋 5h: 40%"
assert_lacks "the absent window renders nothing" "7d:"
assert_eq "the absent window logs no errors" "" "$(cat "$SCRATCH/err")"
render 41 "$PLAIN" "$(printf '{"rate_limits": {"seven_day": {"used_percentage": 40, "resets_at": %s}}}' "$(( $(now_s) + 302400 ))")"
assert_has "a seven-day-only payload renders its window" "🔋 7d: 40%"
assert_lacks "and omits the absent five-hour window" "5h:"
render 42 "$PLAIN" '{"rate_limits": {"five_hour": {"used_percentage": 40}}}'
assert_eq "a window without resets_at exits 0" 0 "$RC"
assert_lacks "a window without resets_at is dropped, not half-rendered" "🔋"

# ---------- 6: churn and PR segments ----------
echo "== 6: churn + PR =="
render 50 "$PLAIN" '{"cost": {"total_lines_added": 0, "total_lines_removed": 0}}'
assert_lacks "an untouched session renders no churn segment" "📓"
render 51 "$PLAIN" '{"cost": {"total_lines_added": 120, "total_lines_removed": 4}}'
assert_has "churn renders green added and red removed" "📓 ${GRN}+120${OFF} ${RED}-4${OFF}"
pr() { render "$1" "$PLAIN" "$(printf '{"pr": {"number": 42, "review_state": "%s"}}' "$2")"; }
pr 52 approved
assert_has "an approved PR renders a green check" "🔀 #42 ${GRN}✓${OFF}"
pr 53 changes_requested
assert_has "changes requested renders a red cross" "🔀 #42 ${RED}✗${OFF}"
pr 54 pending
assert_has "a pending review renders a yellow dot" "🔀 #42 ${YEL}●${OFF}"
pr 55 draft
assert_has "a draft renders a hollow dot" "🔀 #42 ◌"
pr 56 unheard_of
assert_has "an unknown review state renders the number alone" "🔀 #42 |"
render 57 "$PLAIN" '{"pr": {"review_state": "approved"}}'
assert_lacks "a review state without a number renders nothing" "🔀"

echo "-- segment order --"
render 58 "$REPO" "$(printf '{"model": {"display_name": "Opus 5"}, "effort": {"level": "high"}, "pr": {"number": 7, "review_state": "draft"}, "cost": {"total_lines_added": 2, "total_lines_removed": 1}, "context_window": {"used_percentage": 12, "total_input_tokens": 24000, "total_output_tokens": 1000, "context_window_size": 200000}, "rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": %s}, "seven_day": {"used_percentage": 10, "resets_at": %s}}}' "$(( $(now_s) + 9000 ))" "$(( $(now_s) + 302400 ))")"
assert_re "a full payload renders every segment in order" \
  '^🤖 Opus 5 \(high\) \| 📦 demo-proj / main \| 🔀 #7 ◌ \| 📓 .*\+2.*-1.* \| 💭 12% ↑24K ↓1K / 200K \| 🔋 5h: 10% ↻[0-9]+h · 7d: 10% ↻[0-9]+d$'
assert_eq "a full payload logs nothing to stderr" "" "$(cat "$SCRATCH/err")"

# ---------- 7: subagent rows — degenerate input ----------
# Emitting no line for a task leaves that row with its default rendering, so
# dropping a row we cannot render is always safe; exiting non-zero is not.
echo "== 7: subagent rows, degenerate input =="
sub_render ''
assert_eq "empty stdin exits 0" 0 "$RC"
assert_eq "empty stdin emits no rows" "" "$OUT"
sub_render 'not json'
assert_eq "non-JSON stdin exits 0" 0 "$RC"
assert_eq "non-JSON stdin emits no rows" "" "$OUT"
sub_render '{"tasks": []}'
assert_eq "no tasks emits no rows" "" "$OUT"
sub_render '{"tasks": [{"description": "no id here"}, {"id": "t1", "description": "has one"}]}'
assert_eq "an id-less task is skipped" "" "$(row 'null')"
assert_has "its sibling still renders" "has one" "$(row t1)"
sub_render '{"tasks": [{"id": "t1"}, {"id": "t2", "description": "identified"}]}'
assert_eq "a task with no description or label is skipped" "" "$(row t1)"
assert_has "its sibling still renders" "identified" "$(row t2)"

echo "-- per-task type errors --"
# jq aborts its whole stream on a type error: without the per-task try/catch a
# single odd task would take out every row after it, not just its own.
sub_render '{"tasks": [
  {"id": "t1", "description": "before"},
  {"id": "t2", "description": "bad ctx", "tokenCount": 10, "contextWindowSize": "enormous"},
  {"id": "t3", "description": "after"}
]}'
assert_eq "a type error still exits 0" 0 "$RC"
assert_has "rows before the bad task render" "before" "$(row t1)"
assert_has "rows after the bad task render" "after" "$(row t3)"
assert_eq "only the bad row is dropped" 2 "$(printf '%s\n' "$OUT" | grep -c .)"
sub_render '{"tasks": [{"id": "t1", "description": "odd label", "label": 12345, "status": "running", "startTime": '"$(now_ms)"'}]}'
assert_eq "a non-string label still exits 0" 0 "$RC"
assert_has "a non-string label does not suppress the fields before it" "odd label" "$(row t1)"

# ---------- 8: subagent rows — model ids ----------
echo "== 8: subagent model ids =="
sub_render '{"tasks": [
  {"id": "a", "description": "x", "model": "claude-opus-5"},
  {"id": "b", "description": "x", "model": "claude-opus-5[1m]"},
  {"id": "c", "description": "x", "model": "claude-haiku-4-5-20251001"},
  {"id": "d", "description": "x", "model": "us.anthropic.claude-opus-5-v1:0"},
  {"id": "e", "description": "x", "model": "claude-3-5-sonnet-20241022"},
  {"id": "f", "description": "x", "model": "claude-fable-5"},
  {"id": "g", "description": "x", "model": "some-other-model"},
  {"id": "h", "description": "x"}
]}'
assert_has "a bare id maps to a display name" "🤖 Opus 5" "$(row a)"
assert_has "a [1m] marker is stripped" "🤖 Opus 5" "$(row b)"
assert_has "a dated suffix becomes a dotted version" "🤖 Haiku 4.5" "$(row c)"
assert_has "a provider prefix and version suffix are stripped" "🤖 Opus 5" "$(row d)"
assert_has "a version before the family name still resolves" "🤖 Sonnet 3.5" "$(row e)"
assert_has "every family is recognized" "🤖 Fable 5" "$(row f)"
assert_has "an unrecognized id passes through raw" "🤖 some-other-model" "$(row g)"
assert_lacks "an absent model renders no model column" "🤖" "$(row h)"
sub_render '{"tasks": [
  {"id": "a", "description": "x", "model": "claude-opus-5", "effort": "xhigh"},
  {"id": "b", "description": "x", "model": "claude-opus-5", "effort": 12000}
]}'
assert_has "a level effort is appended" "🤖 Opus 5 (xhigh)" "$(row a)"
assert_has "a numeric effort budget is appended" "🤖 Opus 5 (12000)" "$(row b)"

# ---------- 9: subagent rows — context column ----------
echo "== 9: subagent context column =="
sctx() { # sctx <tokens> <window>
  sub_render "$(printf '{"tasks": [{"id": "a", "description": "x", "tokenCount": %s, "contextWindowSize": %s}]}' "$1" "$2")"
}
sctx 138000 200000
assert_has "just under 70% is uncolored" "💭 69% / 200K" "$(row a)"
sctx 140000 200000
assert_has "70% turns yellow" "💭 ${YEL}70%${OFF} / 200K" "$(row a)"
sctx 178000 200000
assert_has "just under 90% stays yellow" "💭 ${YEL}89%${OFF}" "$(row a)"
sctx 180000 200000
assert_has "90% turns red" "💭 ${RED}90%${OFF}" "$(row a)"
sctx 100 0
assert_lacks "a zero window renders no context column" "💭" "$(row a)"
sctx 999999 999999
assert_has "999,999 tokens round into M, not 1000K" "/ 1M" "$(row a)"
sctx 500 999400
assert_has "just under 1M stays in K" "/ 999K" "$(row a)"

# ---------- 10: subagent rows — state and elapsed ----------
# Assertions match the *unit*, not the digits: jq reads its own clock, so a
# value pinned to the exact boundary would flake by a second.
echo "== 10: subagent state column =="
elapsed() { # elapsed <ms-ago>
  sub_render "$(printf '{"tasks": [{"id": "a", "description": "x", "status": "running", "startTime": %s}]}' "$(( $(now_ms) - $1 ))")"
}
elapsed 59500
assert_re "under a minute renders seconds" '⏱ [0-9]+s' "$(row a)"
elapsed 60500
assert_re "a minute and up renders minutes and seconds" '⏱ [0-9]+m[0-9]+s' "$(row a)"
elapsed 3599500
assert_re "just under an hour stays in minutes" '⏱ [0-9]+m[0-9]+s' "$(row a)"
elapsed 3600500
assert_re "an hour and up renders hours and minutes" '⏱ [0-9]+h[0-9]+m' "$(row a)"
elapsed 86399500
assert_re "just under a day stays in hours" '⏱ [0-9]+h[0-9]+m' "$(row a)"
elapsed 86400500
assert_re "a day and up renders days and hours" '⏱ [0-9]+d[0-9]+h' "$(row a)"
elapsed -60000
assert_has "a start time in the future clamps to zero" "⏱ 0s" "$(row a)"
sub_render '{"tasks": [
  {"id": "a", "description": "x", "status": "completed"},
  {"id": "b", "description": "x", "status": "failed"},
  {"id": "c", "description": "x", "status": "killed"},
  {"id": "d", "description": "x", "status": "queued"}
]}'
assert_has "completed renders a green check" "${GRN}✓${OFF} completed" "$(row a)"
assert_has "failed renders a red cross" "${RED}✗${OFF} failed" "$(row b)"
assert_has "killed renders a red cross" "${RED}✗${OFF} killed" "$(row c)"
assert_lacks "an unknown status renders no state" "⏱" "$(row d)"

# ---------- 11: subagent rows — identity, tail, layout ----------
echo "== 11: subagent identity + layout =="
sub_render '{"cwd": "/work/main", "tasks": [
  {"id": "a", "description": "desc only", "label": "desc only"},
  {"id": "b", "name": "scout", "description": "with a handle"},
  {"id": "c", "label": "label only"},
  {"id": "d", "description": "in a worktree", "cwd": "/work/side-checkout"},
  {"id": "e", "description": "the task", "label": "the live activity"}
]}'
assert_has "description carries identity on its own" "📋 desc only" "$(row a)"
assert_lacks "a label equal to the description is not repeated" "desc only | desc only" "$(row a)"
assert_has "a name prefixes the identity" "📋 scout / with a handle" "$(row b)"
assert_has "a label stands in for a missing description" "📋 label only" "$(row c)"
assert_has "a differing cwd renders its basename in the tail" "🌿 side-checkout" "$(row d)"
assert_lacks "the session's own cwd is not repeated in the tail" "🌿 main" "$(row a)"
assert_re "a differing label trails the identity" '📋 the task +\| the live activity$' "$(row e)"

sub_render '{"tasks": [
  {"id": "a", "description": "x", "model": "claude-opus-5"},
  {"id": "b", "description": "x", "model": "claude-haiku-4-5"}
]}'
col1() { printf '%s' "$1" | awk -F' \\| ' '{print $1}' | wc -c | tr -d ' '; }
assert_eq "columns pad to a common width across rows" \
  "$(col1 "$(row a)")" "$(col1 "$(row b)")"
sub_render '{"columns": 120, "tasks": [{"id": "a", "description": "an extravagantly long description that would otherwise push every column that follows it clean off the right edge of the panel"}]}'
assert_has "an overlong identity is clipped" "…" "$(row a)"
assert_eq "the clip is capped well inside the terminal width" 1 \
  "$(row a | awk '{print (length($0) <= 60) ? 1 : 0}')"
# Written as JSON \u escapes rather than raw bytes: a control character in
# the source does not survive editing reliably.
sub_render '{"tasks": [{"id": "a", "description": "control\u0007chars\u001b[31m here"}]}'
assert_lacks "control characters are flattened out of task text" "${ESC}[31m" "$(row a)"
assert_has "the surrounding text survives flattening" "control chars" "$(row a)"
assert_eq "no trailing separator on a row with empty columns" 1 \
  "$(row a | awk '{print ($0 ~ /[ |]$/) ? 0 : 1}')"

# ---------- summary ----------
echo "=================================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
