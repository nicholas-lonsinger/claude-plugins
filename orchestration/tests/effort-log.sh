#!/usr/bin/env bash
# Fixture tests for the effort log: builds a task table and log entries per
# case, then asserts each row's tally verdict (hold, step down, step up) and
# what `add` logs, refuses and rewrites. `add` runs against a fake session
# whose subagent transcripts live under a scratch $HOME. Takes a few seconds.
# EFFORT_LOG_SCRIPT points the run at another copy of the script.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${EFFORT_LOG_SCRIPT:-$ROOT/orchestration/scripts/effort-log}"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/effort-log-test.XXXXXX")" || { echo "FAIL: cannot create a scratch directory"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Pin everything the script resolves from the environment, so no run reaches
# the real sync store, transcripts, or session.
export HOME="$tmp/home"
mkdir -p "$HOME"
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID EFFORT_LOG_DIR EFFORT_TABLE

MEASURES='agent	requests	tool_calls	input_tokens	output_tokens	cache_read_tokens	cache_write_5m_tokens	cache_write_1h_tokens	model_secs	tool_secs	idle_secs'
HEADER="time	model	row	level	role	outcome	note	$MEASURES"
LEGACY_HEADER="time	model	row	level	role	pair	outcome	$MEASURES"
OPUS=claude-opus-5-5 SONNET=claude-sonnet-5-0 HAIKU=claude-haiku-4-5

# new_case <name>: an empty table and log of its own, and a session to `add` from.
new_case() {
    CASE="$tmp/$1"
    SESSION="session-$1"
    mkdir -p "$CASE/log"
    export EFFORT_LOG_DIR="$CASE/log" EFFORT_TABLE="$CASE/table.md"
    printf '%s\n' "$HEADER" >"$CASE/log/fixture.tsv"
    printf '# Rows\n\n| Row | Task | Oracle | Model | Effort |\n|---|---|---|---|---|\n' >"$EFFORT_TABLE"
}

# row <key> <oracle> <model> <effort>
# shellcheck disable=SC2016  # the backticks are the table's own key markup
row() { printf '| `%s` | task %s | %s | %s | %s |\n' "$1" "$1" "$2" "$3" "$4" >>"$EFFORT_TABLE"; }

# runs <count> <model> <row> <level> <outcome> [role] [note]: fixture entries, each one second after the last.
TICK=0
runs() {
    local n
    for ((n = 0; n < $1; n++)); do
        TICK=$((TICK + 1))
        printf '2000-01-01T%02d:%02d:%02dZ\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            $((TICK / 3600)) $((TICK / 60 % 60)) $((TICK % 60)) "$2" "$3" "$4" "${6:-single}" "$5" "${7:-}" \
            >>"$CASE/log/fixture.tsv"
    done
}

# expect <name> <row> <regex>: the row's tally line matches.
expect() {
    local out line
    out="$(python3 "$SCRIPT" tally 2>&1)"
    line="$(printf '%s\n' "$out" | grep -E "^$2 ")"
    if printf '%s' "$line" | grep -qE -- "$3"; then ok; else fail "$1: wanted /$3/ in: ${line:-$out}"; fi
}

# expect_out <name> <regex> [text]: the text (default: the whole tally) has a line matching.
expect_out() {
    local out="${3-$(python3 "$SCRIPT" tally 2>&1)}"
    if printf '%s\n' "$out" | grep -qE -- "$2"; then ok; else fail "$1: wanted /$2/ in: $out"; fi
}

# add <agent> <model> [args...]: log a run of a fake subagent that ran on <model>;
# its stdout is the output, its stderr lands in $CASE/add.err.
add() {
    local agent="$1" model="$2" dir="$HOME/.claude/projects/project/$SESSION/subagents"
    shift 2
    mkdir -p "$dir"
    printf '{"type":"assistant","timestamp":"2000-01-01T00:00:00Z","message":{"id":"m-%s","model":"%s","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}\n' \
        "$agent" "$model" >"$dir/agent-$agent.jsonl"
    CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" add --agent "$agent" --model "$model" "$@" 2>"$CASE/add.err"
}

echo "1. a clean streak steps an oracle row down one effort level"
new_case clean
row impl yes opus medium
runs 4 $OPUS impl medium met
expect "4 met" impl ' hold \(streak 4 of 5 for opus low\)'
runs 1 $OPUS impl medium met
expect "5 met" impl ' step down → opus low '

echo "2. at the effort floor the model steps down"
new_case floor
row edit yes opus low
runs 5 $OPUS edit low met
expect "opus low, 5 met" edit ' step down → sonnet low '

echo "3. a miss early at a setting stepped down to steps back up"
new_case probation
row level yes opus low
runs 5 $OPUS level medium met
runs 1 $OPUS level low missed
expect "effort step" level ' step up → opus medium '
row model yes sonnet low
runs 5 $OPUS model low met
runs 1 $SONNET model low missed
expect "model step" model ' step up → opus low '

echo "4. each miss at the rung below on the current version doubles the streak it needs"
new_case backoff
row small yes haiku medium
runs 5 $HAIKU small medium met
runs 1 $HAIKU small low missed
runs 9 $HAIKU small medium met
expect "haiku, 9 met" small ' hold \(streak 9 of 10 for haiku low\)'
runs 1 $HAIKU small medium met
expect "haiku, 10 met" small ' step down → haiku low '
row big yes opus medium
runs 5 $OPUS big medium met
runs 1 $OPUS big low missed
runs 5 $OPUS big medium met
expect "opus, 5 met" big ' step down → sonnet medium '

echo "5. brief misses neither count nor break a streak, and recurring ones are flagged"
new_case brief
row brief yes opus medium
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no fixture path"
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no failing test named"
runs 1 $OPUS brief medium met
expect "briefs among 5 met" brief ' step down → opus low '
expect_out "cluster line" '^brief misses: brief 2 of the last 7 runs$'
expect_out "cluster note" '^  brief: no fixture path$'
expect_out "cluster note" '^  brief: no failing test named$'
row once no opus medium
runs 1 $OPUS once medium brief single "only one"
if python3 "$SCRIPT" tally 2>&1 | grep -q 'brief misses: once'; then fail "one brief in 20 is flagged"; else ok; fi
add b-none $OPUS --row once --level medium --outcome brief >/dev/null; code=$?
if [ "$code" -ne 0 ] && ! grep -q b-none "$CASE"/log/*.tsv; then ok; else
    fail "brief without --note: exit $code, logged: $(grep -c b-none "$CASE"/log/*.tsv)"
fi
add b-note $OPUS --row once --level medium --outcome brief --note $'the brief\tlacked\n the  path' >/dev/null
expect_out "note is collapsed to spaces" '^  once: the brief lacked the path$'

echo "6. a continued near miss: one log entry per agent, one miss holds"
new_case continuation
row near yes opus medium
runs 4 $OPUS near medium met
runs 1 $OPUS near medium missed
runs 4 $OPUS near medium met
expect "met×4, missed, met×4" near ' 1/5  hold \(streak 4 of 5 for opus low\)'
row other no opus medium
add c-1 $OPUS --row other --level medium --outcome missed >/dev/null
add c-1 $OPUS --row other --level medium --outcome met >/dev/null; code=$?
if [ "$code" -ne 0 ] && [ "$(grep -c c-1 "$CASE/log/$SESSION.tsv")" -eq 1 ]; then ok; else
    fail "an agent already logged: exit $code, entries $(grep -c c-1 "$CASE/log/$SESSION.tsv")"
fi

echo "7. evidence carries across versions; misses below count on the current version only"
new_case version
row deep yes fable medium
row research no fable medium
runs 5 claude-fable-5-1 deep medium met
runs 1 claude-fable-5-1 deep low missed
runs 5 claude-fable-5-1 deep medium met
runs 1 claude-fable-5-1 deep low missed
runs 5 claude-fable-5-1 deep medium met
expect "2 misses below on the current version" deep ' hold \(streak 5 of 20 for fable low\)'
runs 1 claude-fable-5-2 research medium met
expect "a newer version anywhere resets them" deep ' step down → fable low '
row carry yes opus medium
runs 3 claude-opus-5-5 carry medium met
runs 2 claude-opus-5-6 carry medium met
expect "3 + 2 met across versions" carry ' step down → opus low '

echo "8. a row without an oracle never steps down but steps up on misses"
new_case no-oracle
row judge no opus medium
runs 20 $OPUS judge medium met
expect "20 met" judge ' hold \(no oracle: refresh-ladder sets it\)'
runs 1 $OPUS judge medium missed
runs 1 $OPUS judge medium met
runs 1 $OPUS judge medium missed
expect "2 misses in the last 5" judge ' step up → opus high '
row top no opus high
runs 5 $OPUS top high met
runs 2 $OPUS top high missed
expect "2 misses at opus high" top ' hold \(2 of the last 5 runs at opus high missed, at the top of the ladder'

echo "9. an escalation is off the row's line"
new_case escalation
row esc yes opus medium
runs 1 $OPUS esc medium missed
runs 1 $OPUS esc high met escalation
runs 5 $OPUS esc medium met
expect "miss, escalation, 5 met" esc ' 6 +5 +0/5  step down → opus low '
row late yes opus medium
runs 5 $OPUS late medium met
runs 1 $OPUS late medium missed
runs 1 $OPUS late high met escalation
runs 4 $OPUS late medium met
runs 1 $OPUS late medium missed
expect "a miss after an escalation is no early miss" late ' hold \(streak 0 of 5 for opus low\)'

echo "10. legacy pair entries read: a lower run's miss counts below, off the row's line"
new_case legacy
row pairs yes haiku medium
row later no haiku medium
SESSION=session-legacy
{
    printf '%s\n' "$LEGACY_HEADER"
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 1 $HAIKU 1 2 $HAIKU 2 3 $HAIKU 3
    printf '2000-01-01T00:00:04Z\t%s\tpairs\tmedium\tupper\tp1\tmet\tl-4\n' $HAIKU
    printf '2000-01-01T00:00:05Z\t%s\tpairs\tlow\tlower\tp1\tmissed\tl-5\n' $HAIKU
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 6 $HAIKU 6 7 $HAIKU 7
} >"$CASE/log/$SESSION.tsv"
expect "upper and singles in the streak, the lower's miss doubles it" pairs ' hold \(streak 6 of 10 for haiku low\)'
add l-8 $HAIKU --row later --level medium --outcome met --note 'a note' >/dev/null
if [ "$(head -1 "$CASE/log/$SESSION.tsv")" = "$HEADER	pair" ]; then ok; else
    fail "a legacy session file appended to keeps every column under the current header: $(head -1 "$CASE/log/$SESSION.tsv")"
fi
expect "the legacy file still reads after the append" pairs ' hold \(streak 6 of 10 for haiku low\)'
expect "the appended entry reads" later ' 1 +1 +0/1  hold '

echo "11. a step rewrites exactly the row's Model and Effort cells; a bad cell fails"
new_case rewrite
cat >"$EFFORT_TABLE" <<'EOF'
# Rows

| Row | Task | Oracle | Model | Effort |
|---|---|---|---|---|
|  `step`  | Task |  yes  |  opus  |  medium  |
| `stay` | Same cells | yes | opus | medium |

Text after the table: | `prose` | is | not | a | row
EOF
sed 's/|  opus  |  medium  |$/|  opus  |  low  |/' "$EFFORT_TABLE" >"$CASE/expected.md"
runs 4 $OPUS step medium met
runs 4 $OPUS stay medium met
cp "$EFFORT_TABLE" "$CASE/before.md"
python3 "$SCRIPT" tally >/dev/null 2>&1
if cmp -s "$EFFORT_TABLE" "$CASE/before.md"; then ok; else fail "tally changed the table"; fi
out="$(add r-1 $OPUS --row step --level medium --outcome met)"
expect_out "add announces the step" '^STEP DOWN: step opus medium → opus low \(streak 5 of 5 for opus low\); the table now says so\.$' "$out"
if cmp -s "$EFFORT_TABLE" "$CASE/expected.md"; then ok; else fail "table after the step: $(diff "$CASE/expected.md" "$EFFORT_TABLE")"; fi
out="$(add r-2 $OPUS --row stay --level medium --outcome missed)"
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] && cmp -s "$EFFORT_TABLE" "$CASE/expected.md"; then ok; else
    fail "a hold printed more than the logged line, or changed the table: $out"
fi
row bad maybe opus low
out="$(python3 "$SCRIPT" tally 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "row \`bad\`.*Oracle cell 'maybe'"; then ok; else
    fail "a bad Oracle cell: exit $code, $out"
fi

echo "effort-log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
