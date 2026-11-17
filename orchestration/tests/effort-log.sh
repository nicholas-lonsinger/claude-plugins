#!/usr/bin/env bash
# Fixture tests for the effort log: builds a task table per case, records
# baselines and runs through the script (`add` against a fake session whose
# subagent transcripts live under a scratch $HOME), then asserts on what `add`
# and `baseline` print and on each row's tally line. Legacy files and clusters
# use fixture entries written directly. Takes several seconds.
# EFFORT_LOG_SCRIPT points the run at another copy of the script.
# shellcheck disable=SC2016  # backticks in single quotes are the table's own key markup

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
HEADER="time	kind	model	row	level	role	outcome	note	$MEASURES"
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
row() { printf '| `%s` | task %s | %s | %s | %s |\n' "$1" "$1" "$2" "$3" "$4" >>"$EFFORT_TABLE"; }

# runs <count> <model> <row> <level> <outcome> [role] [note]: fixture run entries
# dated 2000, each one second after the last, so they precede everything the
# script records.
TICK=0
runs() {
    local n
    for ((n = 0; n < $1; n++)); do
        TICK=$((TICK + 1))
        printf '2000-01-01T%02d:%02d:%02dZ\trun\t%s\t%s\t%s\t%s\t%s\t%s\n' \
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

# expect_none <name> <regex> <text>: no line of the text matches.
expect_none() {
    if printf '%s\n' "$3" | grep -qE -- "$2"; then fail "$1: wanted no /$2/ in: $3"; else ok; fi
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

# adds <count> <model> <row> <level> <outcome>: that many launches through `add`;
# OUT is the last one's output, ALL every one's.
AGENT=0
adds() {
    local n
    ALL=''
    for ((n = 0; n < $1; n++)); do
        AGENT=$((AGENT + 1))
        OUT="$(add "g$AGENT" "$2" --row "$3" --level "$4" --outcome "$5")"
        ALL+="$OUT"$'\n'
    done
}

# base <row> <family> <level> [--carry]: a baseline from this session; OUT is its output.
base() {
    OUT="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --row "$1" --model "$2" --level "$3" \
        --note "set by the test" "${@:4}" 2>&1)"
}

echo "1. brief misses neither count nor break a streak, and recurring ones are flagged"
new_case brief
row brief yes opus medium
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no fixture path"
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no failing test named"
runs 1 $OPUS brief medium met
base brief opus medium --carry
expect_out "a carried streak with briefs in it steps at the baseline" \
    '^STEP DOWN: brief opus medium → opus low \(streak 5 of 5\)$' "$OUT"
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

echo "2. one log entry per agent"
new_case continuation
row other no opus medium
add c-1 $OPUS --row other --level medium --outcome missed >/dev/null
add c-1 $OPUS --row other --level medium --outcome met >/dev/null; code=$?
if [ "$code" -ne 0 ] && [ "$(grep -c c-1 "$CASE/log/$SESSION.tsv")" -eq 1 ]; then ok; else
    fail "an agent already logged: exit $code, entries $(grep -c c-1 "$CASE/log/$SESSION.tsv")"
fi

echo "3. legacy pair entries read: a lower run's miss counts at its setting, off the row's tenure"
new_case legacy
row pairs yes haiku medium
row later no haiku medium
{
    printf '%s\n' "$LEGACY_HEADER"
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 1 $HAIKU 1 2 $HAIKU 2 3 $HAIKU 3
    printf '2000-01-01T00:00:04Z\t%s\tpairs\tmedium\tupper\tp1\tmet\tl-4\n' $HAIKU
    printf '2000-01-01T00:00:05Z\t%s\tpairs\tlow\tlower\tp1\tmissed\tl-5\n' $HAIKU
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 6 $HAIKU 6 7 $HAIKU 7
} >"$CASE/log/session-legacy.tsv"
base pairs haiku medium --carry
expect "upper and singles carried, the lower's miss doubles the need" pairs \
    'haiku medium +baseline +6 +6 +0/5  hold \(streak 6 of 10 for haiku low\)'
SESSION=session-legacy
add l-8 $HAIKU --row later --level medium --outcome met --note 'a note' >/dev/null
if [ "$(head -1 "$CASE/log/$SESSION.tsv")" = "$HEADER	pair" ]; then ok; else
    fail "a legacy session file appended to keeps every column under the current header: $(head -1 "$CASE/log/$SESSION.tsv")"
fi
expect "the legacy file still reads after the append" pairs ' hold \(streak 6 of 10 for haiku low\)'
expect "the appended entry reads" later 'no setting'
if [ "$(grep -c '	l-8	' "$CASE/log/$SESSION.tsv")" -eq 1 ]; then ok; else fail "the appended run is not in the file once"; fi

echo "4. the table parses by header; a bad cell, a duplicate key or no Oracle column fails"
new_case table
cat >"$EFFORT_TABLE" <<'EOF'
# Rows

| Effort | Oracle | Row | Task |
|---|---|---|---|
|  high  |  no  |  `reordered`  | Columns in another order |

Text after the table: | `prose` | is | not | a | row
EOF
base reordered opus high
expect "columns are found by name" reordered '^reordered +no +opus high'
expect_none "text after the table is no row" '^prose ' "$(python3 "$SCRIPT" tally 2>&1)"
printf '| no | maybe | `bad` | Task |\n' >"$CASE/extra"
sed -i.bak '/`reordered`/r '"$CASE/extra" "$EFFORT_TABLE"
out="$(python3 "$SCRIPT" tally 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "row \`bad\`.*Oracle cell 'maybe'"; then ok; else
    fail "a bad Oracle cell: exit $code, $out"
fi
mv "$EFFORT_TABLE.bak" "$EFFORT_TABLE"
printf '| high | yes | `reordered` | Again |\n' >"$CASE/extra"
sed -i.bak '/`reordered`/r '"$CASE/extra" "$EFFORT_TABLE"
out="$(python3 "$SCRIPT" tally 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "row \`reordered\` appears more than once"; then ok; else
    fail "a duplicate key: exit $code, $out"
fi
printf '| Row | Task | Model | Effort |\n|---|---|---|---|\n| `old` | Task | opus | medium |\n' >"$EFFORT_TABLE"
out="$(python3 "$SCRIPT" tally 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "no task-table header with Row and Oracle"; then ok; else
    fail "no Oracle column: exit $code, $out"
fi

echo "5. no oracle never steps down; misses at the top of the ladder hold; an escalation is no evidence"
new_case no-oracle
row judge no opus medium
base judge opus medium
adds 20 $OPUS judge medium met
expect "20 met without an oracle" judge ' hold \(no oracle: refresh-ladder sets it\)'
row top no opus high
base top opus high
adds 2 $OPUS top high missed
expect "2 misses at opus high" top ' hold \(misses at the top of its ladder: refresh-ladder sets it\)'
row esc yes opus medium
base esc opus medium
adds 1 $OPUS esc medium missed
out="$(add e-1 $OPUS --row esc --level high --outcome met --role escalation)"
expect_none "an escalation is not called off-setting" '^off-setting' "$out"
adds 4 $OPUS esc medium met
expect "the escalation is off the tenure" esc 'opus medium +baseline +5 +4 +1/5'
adds 1 $OPUS esc medium met
expect_out "five mets after the miss step down" '^STEP DOWN: esc opus medium → opus low \(streak 5 of 5\)$' "$OUT"

echo "A. a step up's misses stay behind: met×3, missed×2 up, back down on the doubled need, then a met holds"
new_case finding2
row small yes haiku medium
base small haiku medium
adds 3 $HAIKU small medium met
adds 2 $HAIKU small medium missed
expect_out "two misses in five step up" '^STEP UP: small haiku medium → haiku high \(' "$OUT"
adds 9 $HAIKU small high met
expect_none "nine mets at high hold" '^STEP' "$ALL"
expect "haiku medium's failure doubles its need" small 'streak 9 of 10 for haiku medium'
adds 1 $HAIKU small high met
expect_out "ten mets step down" '^STEP DOWN: small haiku high → haiku medium \(streak 10 of 10\)' "$OUT"
adds 1 $HAIKU small medium met
expect_none "the next met at medium holds" '^STEP' "$OUT"
expect "the old misses are out of the new tenure" small 'haiku medium +down +1 +1 +0/1  hold'

echo "B. a stale session's run at the old setting is evidence only"
new_case stale
row stale yes opus medium
# A legacy failure at sonnet low keeps opus low from stepping down within the eight runs below.
runs 1 $SONNET stale low missed lower
base stale opus medium
adds 5 $OPUS stale medium met
expect_out "five mets step down" '^STEP DOWN: stale opus medium → opus low \(streak 5 of 5\)' "$OUT"
adds 4 $OPUS stale low met
adds 1 $OPUS stale medium met
expect_out "the old setting's run is called off-setting" \
    '^off-setting: stale runs at opus low; this run is evidence only$' "$OUT"
adds 3 $OPUS stale low met
adds 1 $OPUS stale low missed
expect_none "a miss past probation does not step up" '^STEP' "$OUT"
expect "the tenure runs through the stale run" stale \
    'opus low +down +8 +0 +1/5  hold \(streak 0 of 10 for sonnet low\)'
row cadence yes opus low
base cadence opus low
adds 4 $OPUS cadence low met
adds 1 $OPUS cadence medium met
adds 1 $OPUS cadence low met
expect_out "an off-setting fifth run leaves the streak whole" \
    '^STEP DOWN: cadence opus low → sonnet low \(streak 5 of 5\)' "$OUT"

echo "C. an off-setting run never becomes the setting a row returns to"
new_case off-prev
row probe yes haiku low
base probe haiku low
adds 1 $OPUS probe low met
expect_out "the opus run is off-setting" '^off-setting: probe runs at haiku low' "$OUT"
adds 2 $HAIKU probe low met
adds 1 $HAIKU probe low missed
expect_none "a miss after a baseline does not step to opus low" '^STEP' "$OUT"
expect "the row holds at the floor" probe 'haiku low +baseline +3 +0 +1/3  hold \(at the floor\)'

echo "D. a baseline's move down is not undone by its first miss"
new_case baseline-down
row move yes opus medium
base move opus high
adds 3 $OPUS move high met
base move opus medium
adds 1 $OPUS move medium missed
expect_none "the miss holds" '^STEP' "$OUT"
expect "the row stays where the baseline put it" move 'opus medium +baseline +1 +0 +1/1  hold'

echo "E. misses past probation step up effort first, not back to the model stepped down from"
new_case effort-first
row ladder yes opus low
base ladder opus low
adds 5 $OPUS ladder low met
expect_out "opus low steps to sonnet low" '^STEP DOWN: ladder opus low → sonnet low \(streak 5 of 5\)' "$OUT"
adds 5 $SONNET ladder low met
expect_out "sonnet low steps to haiku low" '^STEP DOWN: ladder sonnet low → haiku low \(streak 5 of 5\)' "$OUT"
adds 15 $HAIKU ladder low met
adds 1 $HAIKU ladder low missed
expect_none "15 mets and a miss hold" '^STEP' "$ALL"
adds 1 $HAIKU ladder low missed
expect_out "a second miss steps effort up" '^STEP UP: ladder haiku low → haiku medium \(' "$OUT"

echo "F. a failed setting bounds every setting it dominates"
new_case dominance
row dom yes opus medium
base dom opus medium
adds 5 $OPUS dom medium met
adds 1 $OPUS dom low missed
expect_out "a probation miss steps back up" '^STEP UP: dom opus low → opus medium \(' "$OUT"
adds 4 $OPUS dom medium met
expect "opus low needs 10" dom 'streak 4 of 10 for opus low'
adds 1 $OPUS dom medium met
expect_out "sonnet medium is not dominated by opus low" \
    '^STEP DOWN: dom opus medium → sonnet medium \(streak 5 of 5\)' "$OUT"
adds 4 $SONNET dom medium met
expect "sonnet low is dominated by opus low" dom 'streak 4 of 10 for sonnet low'

echo "G. failures count on the family's highest version only"
new_case versions
row ver yes opus medium
base ver opus medium
adds 5 claude-opus-5-5 ver medium met
adds 1 claude-opus-5-5 ver low missed
adds 1 claude-opus-5-5 ver medium met
expect "a failure on 5-5" ver 'streak 1 of 10 for opus low'
adds 1 claude-opus-5-6 ver medium met
expect "a run on 5-6 starts the failures over" ver 'streak 2 of 5 for opus low'
adds 1 claude-opus-5-5 ver medium met
expect "a later run on 5-5 does not bring them back" ver 'streak 3 of 5 for opus low'

echo "H. two machines' sessions fold in time order"
new_case machines
row two yes opus low
row three yes opus low
A=session-z-machine-a B=session-b-machine-b  # B's file sorts first by name
SESSION=$A; base two opus low
adds 2 $OPUS two low met; first="$ALL"
SESSION=$B; adds 1 $OPUS two low missed
SESSION=$A; adds 3 $OPUS two low met
expect_none "a miss from B inside A's streak stops the step" '^STEP' "$first$ALL"
expect "the miss sits inside the streak" two 'opus low +baseline +6 +3 +1/5'
base three opus low
adds 5 $OPUS three low met
expect_out "A's five mets step down" '^STEP DOWN: three opus low → sonnet low' "$OUT"
SESSION=$B; adds 1 $SONNET three low missed
expect_out "B's later miss is probation" '^STEP UP: three sonnet low → opus low \(a miss within' "$OUT"

echo "I. the script never writes the table"
new_case bytes
row bytes yes opus medium
printf '\nText after the table, | with | pipes |\n' >>"$EFFORT_TABLE"
base bytes opus medium
adds 4 $OPUS bytes medium met
cp "$EFFORT_TABLE" "$CASE/before.md"
adds 1 $OPUS bytes medium met
expect_out "the add steps" '^STEP DOWN: bytes opus medium → opus low' "$OUT"
if cmp -s "$EFFORT_TABLE" "$CASE/before.md"; then ok; else fail "a step changed the table: $(diff "$CASE/before.md" "$EFFORT_TABLE")"; fi

echo "J. baselines: fresh, carry, from the table, and none"
new_case baselines
row fresh yes opus medium
row carry yes opus medium
row block yes opus medium
{
    printf '%s\n' "$LEGACY_HEADER"
    for r in fresh carry; do
        for n in 1 2 3 4 5; do printf '2000-01-01T00:0%d:0%dZ\t%s\t%s\tmedium\tsingle\t\tmet\t%s-%d\n' "$n" "${#r}" $OPUS $r $r $n; done
    done
    printf '2000-01-01T00:01:09Z\t%s\tblock\tmedium\tsingle\t\tmet\tb-1\n' $OPUS
    printf '2000-01-01T00:02:09Z\t%s\tblock\tlow\tsingle\t\tmet\tb-2\n' $OPUS
    printf '2000-01-01T00:03:09Z\t%s\tblock\tmedium\tsingle\t\tmet\tb-3\n' $OPUS
    printf '2000-01-01T00:04:09Z\t%s\tblock\tmedium\tsingle\t\tbrief\tb-4\n' $OPUS
    printf '2000-01-01T00:05:09Z\t%s\tblock\tmedium\tsingle\t\tmet\tb-5\n' $OPUS
} >"$CASE/log/session-legacy.tsv"
base fresh opus medium
expect_none "a fresh baseline does not step" '^STEP' "$OUT"
expect "a fresh baseline starts an empty tenure" fresh 'opus medium +baseline +0 +0 +0/0  hold \(streak 0 of 5 for opus low\)'
base carry opus medium --carry
expect_out "a carried streak steps at the baseline" '^STEP DOWN: carry opus medium → opus low \(streak 5 of 5\)$' "$OUT"
expect "the carried row is down" carry 'opus low +down +0'
base block opus medium --carry
expect "carry stops at the first run at another setting" block 'opus medium +baseline +2 +2 +0/2  hold \(streak 2 of 5 for opus low\)'
new_case from-table
row live no opus 'high, unpaired'
row small yes haiku medium
out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --from-table --note "from the table" 2>&1)"
expect "--from-table reads past , unpaired" live 'opus high +baseline'
expect "--from-table sets every row" small 'haiku medium +baseline'
if [ "$(grep -c '	baseline	' "$CASE/log/$SESSION.tsv")" -eq 2 ]; then ok; else fail "--from-table wrote $(grep -c '	baseline	' "$CASE/log/$SESSION.tsv") baselines: $out"; fi
printf '| Row | Task | Oracle |\n|---|---|---|\n| `bare` | Task | yes |\n' >"$EFFORT_TABLE"
out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --from-table --note x 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "needs Model and Effort columns"; then ok; else fail "--from-table without Model and Effort: exit $code, $out"; fi
new_case unset
row none yes opus medium
out="$(add u-1 $OPUS --row none --level medium --outcome met)"
expect_out "a row with no baseline warns" '^none has no setting yet: record one with effort-log baseline$' "$out"
if grep -q 'u-1' "$CASE/log/$SESSION.tsv"; then ok; else fail "the run of a row with no baseline is not logged"; fi
expect "tally says so" none 'no setting'
expect_out "tally lists the rows with no baseline" '^table rows with no baseline: none$'
# refused <what> <row> <family> <level> <note>: baseline exits non-zero and writes nothing.
refused() {
    local out code
    out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --row "$2" --model "$3" --level "$4" --note "$5" 2>&1)"
    code=$?
    if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q '^effort-log: ' && ! grep -q '	baseline	' "$CASE/log/$SESSION.tsv"; then ok; else
        fail "baseline with $1: exit $code, $out"
    fi
}
refused "an unknown row" nope opus low x
refused "an exact id for a family" none claude-opus-5-5 low x
refused "xhigh" none opus xhigh x
refused "an empty note" none opus low '  '

echo "K. settings prints the rows' settings for a SessionStart hook, and nothing when it cannot"
new_case settings
row set yes opus medium
row unset no fable medium
base set opus medium
out="$(python3 "$SCRIPT" settings 2>&1)"; code=$?
expect_out "a header line" "^The task-table rows' current model and effort, from the effort log:$" "$out"
expect_out "the table header" '^\| Row \| Model \| Effort \|$' "$out"
expect_out "a row with a setting" '^\| `set` \| opus \| medium \|$' "$out"
expect_out "rows without one" '^No setting in the effort log yet: `unset`\.$' "$out"
expect_none "a row without a setting is not in the table" '^\| `unset`' "$out"
if [ "$code" -eq 0 ]; then ok; else fail "settings: exit $code"; fi
# silent <what> [env assignments]: settings exits 0, prints nothing, and reports nothing of its own on stderr.
silent() {
    local what="$1" out code
    shift
    out="$(env "$@" python3 "$SCRIPT" settings 2>"$CASE/settings.err")"; code=$?
    if [ "$code" -eq 0 ] && [ -z "$out" ] && ! grep -q 'effort-log\|Traceback' "$CASE/settings.err"; then ok; else
        fail "settings with $what: exit $code, output: $out$(cat "$CASE/settings.err")"
    fi
}
silent "the store missing" -u EFFORT_LOG_DIR -u EFFORT_TABLE
silent "the table missing" EFFORT_TABLE="$CASE/missing.md"
silent "the log missing" EFFORT_LOG_DIR="$CASE/missing"
printf '| Row | Task |\n|---|---|\n| `set` | Task |\n' >"$CASE/no-oracle.md"
silent "a table without an Oracle column" EFFORT_TABLE="$CASE/no-oracle.md"

echo "effort-log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
