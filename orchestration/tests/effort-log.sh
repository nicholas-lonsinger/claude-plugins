#!/usr/bin/env bash
# Fixture tests for the effort log: builds a task table per case, records
# baselines and runs through the script (`add` against a fake session whose
# subagent transcripts live under a scratch $HOME), then asserts on what `add`,
# `baseline` and `settings` print and on each row's tally cells. Entries that
# need a chosen time (two machines, late arrivals, legacy files, bad lines) are
# fixture lines written directly. Takes several seconds.
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
# A fixture line under HEADER ends with its note, then PAD's empty measure columns.
PAD=$'\t\t\t\t\t\t\t\t\t\t\t'
# fill <fields>: pad each line of stdin with empty fields to <fields>, as the
# script writes them (a line with fewer fields than its header does not parse).
fill() { awk -F '\t' -v OFS='\t' -v n="$1" '{ for (i = NF + 1; i <= n; i++) $i = "" } 1'; }
OPUS=claude-opus-5-5 SONNET=claude-sonnet-5-0 HAIKU=claude-haiku-4-5 FABLE=claude-fable-5-0

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
        printf '2000-01-01T%02d:%02d:%02dZ\trun\t%s\t%s\t%s\t%s\t%s\t%s%s\n' \
            $((TICK / 3600)) $((TICK / 60 % 60)) $((TICK % 60)) "$2" "$3" "$4" "${6:-single}" "$5" "${7:-}" "$PAD" \
            >>"$CASE/log/fixture.tsv"
    done
}

# at <file> <seconds> <kind> <model> <row> <level> <role> <outcome>: one fixture
# entry in log file <file>.tsv, stamped <seconds> (SS or SS.fff) past 2000-01-01T00:00.
at() {
    local file="$CASE/log/$1.tsv"
    [ -e "$file" ] || printf '%s\n' "$HEADER" >"$file"
    printf '2000-01-01T00:00:%sZ\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}" "$PAD" >>"$file"
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

# expect_cells <name> <row> <column>=<value>...: the row's tally cells, exactly.
# Columns: oracle baseline setting misses streak path reason.
expect_cells() {
    local what="$1" key="$2" out line spec column want got n
    shift 2
    out="$(python3 "$SCRIPT" tally 2>&1)"
    line="$(printf '%s\n' "$out" | grep -E "^$key  ")"
    for spec in "$@"; do
        column="${spec%%=*}" want="${spec#*=}"
        case "$column" in
            oracle) n=2 ;; baseline) n=3 ;; setting) n=4 ;; misses) n=5 ;; streak) n=6 ;; path) n=7 ;; reason) n=8 ;;
            *) fail "$what: no tally column '$column'"; continue ;;
        esac
        got="$(printf '%s\n' "$line" | awk -F '  +' -v n="$n" '{ print $n }')"
        if [ -n "$line" ] && [ "$got" = "$want" ]; then ok; else
            fail "$what: $key's $column wanted '$want', got '$got' in: ${line:-$out}"
        fi
    done
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

# adds <count> <model> <row> <level> <outcome> [args...]: that many launches through
# `add`; OUT is the last one's output, ALL every one's.
AGENT=0
adds() {
    local n count="$1" model="$2" key="$3" level="$4" outcome="$5"
    shift 5
    ALL=''
    for ((n = 0; n < count; n++)); do
        AGENT=$((AGENT + 1))
        OUT="$(add "g$AGENT" "$model" --row "$key" --level "$level" --outcome "$outcome" "$@")"
        ALL+="$OUT"$'\n'
    done
}

# base <row> <family> <level> [--carry]: a baseline from this session; OUT is its output.
base() {
    OUT="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --row "$1" --model "$2" --level "$3" \
        --note "set by the test" "${@:4}" 2>&1)"
}

echo "1. a late-arriving miss only adds evidence at its own setting"
new_case late
row late yes haiku medium
row wide yes opus medium
# Machine B: a baseline, five mets (the row steps down), a miss at low (back
# up), four more mets. Machine A's miss at medium, stamped inside B's first
# streak, arrives last.
for spec in "late haiku $HAIKU" "wide opus $OPUS"; do
    read -r key fam id <<<"$spec"
    at machine-b 00 baseline "$fam" "$key" medium fresh
    for t in 10 11 12 13 14; do at machine-b "$t" run "$id" "$key" medium single met; done
    at machine-b 20 run "$id" "$key" low single missed
    for t in 30 31 32 33; do at machine-b "$t" run "$id" "$key" medium single met; done
done
expect_cells "before A syncs, haiku low needs 10 after the low miss" late \
    setting='haiku medium' streak='4 of 10 for haiku low'
for spec in "late $HAIKU" "wide $OPUS"; do
    read -r key id <<<"$spec"
    at machine-a 12.500 run "$id" "$key" medium single missed
done
expect_cells "after A's late medium miss, B's low miss still counts after it: haiku low still needs 10" late \
    setting='haiku medium' path='haiku medium' misses='0/5' streak='4 of 10 for haiku low'
expect_cells "the opus row is not at opus low: sonnet medium, undominated by opus low, takes the streak after A's miss" wide \
    setting='sonnet medium' path='opus medium → sonnet medium' streak='0 of 10 for sonnet low'

echo "2. arrival order and file layout never change the result"
# The same entries, laid out three ways: one file in time order; one file per
# machine; and the machines' files swapped in name order with each file's lines
# reversed. Two entries share a time, so a tie must not break by file order.
LINES=(
    "a 00 baseline opus mix medium fresh"
    "b 01 baseline haiku tie low fresh"
    "a 10 run $OPUS mix medium single met" "b 11 run $OPUS mix medium single met"
    "a 12 run $OPUS mix medium single met" "b 12.500 run $SONNET mix low single missed"
    "b 13 run $OPUS mix medium single met" "a 14 run $OPUS mix medium single met"
    "b 14 run $OPUS mix medium single missed" "a 16 run $SONNET mix medium single met"
    "b 19 run $HAIKU tie low single missed" "a 20 run $HAIKU tie low single met"
    "b 20 run $HAIKU tie low single missed"
)
# layout <case> <mode>: write LINES into <case>'s log as mode one, split or swapped.
layout() {
    local spec file t rest
    new_case "$1"
    row mix yes opus medium
    row tie no haiku low
    rm "$CASE/log/fixture.tsv"
    for spec in "${LINES[@]}"; do
        read -r file t rest <<<"$spec"
        case "$2" in
            one) file=all ;;
            swapped) file="${file/a/z}" ;;
        esac
        # shellcheck disable=SC2086  # rest is the entry's fields
        at "$file" "$t" $rest
    done
    if [ "$2" = swapped ]; then
        for file in "$CASE"/log/*.tsv; do
            { head -1 "$file"; tail -n +2 "$file" | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }'; } >"$file.r" && mv "$file.r" "$file"
        done
    fi
}
layout order-one one; one="$(python3 "$SCRIPT" tally 2>/dev/null)"
layout order-split split; split="$(python3 "$SCRIPT" tally 2>/dev/null)"
layout order-swapped swapped; swapped="$(python3 "$SCRIPT" tally 2>/dev/null)"
if [ "$one" = "$split" ] && [ "$one" = "$swapped" ]; then ok; else
    fail "the layouts' tallies differ: one:
$one
split:
$split
swapped:
$swapped"
fi
layout order-subset swapped
mv "$CASE/log/z.tsv" "$CASE/z.tsv"
python3 "$SCRIPT" tally >/dev/null 2>&1
mv "$CASE/z.tsv" "$CASE/log/z.tsv"
if [ "$(python3 "$SCRIPT" tally 2>/dev/null)" = "$one" ]; then ok; else fail "a subset, then the full set, does not end at the full set's result"; fi
expect_cells "a tie orders by content: the met, then the miss, so the streak is 0" mix \
    setting='opus medium' streak='0 of 5 for opus low'
expect_cells "and tie's latest run is the miss, so low is failing" tie setting='haiku medium' path='haiku low → haiku medium'

echo "3. a failed probe retreats, and each retry waits for double the streak"
new_case backoff
row probe yes haiku medium
base probe haiku medium
adds 5 $HAIKU probe medium met
expect_out "five mets step down" '^STEP DOWN: probe haiku medium → haiku low \(streak 5 of 5\)$' "$OUT"
adds 1 $HAIKU probe low missed
expect_out "a low miss steps back up" '^STEP UP: probe haiku low → haiku medium \(streak 0 of 10 for haiku low\)$' "$OUT"
adds 9 $HAIKU probe medium met
expect_none "nine mets hold" '^(STEP|MOVE)' "$ALL"
expect_cells "nine of ten" probe setting='haiku medium' streak='9 of 10 for haiku low'
adds 1 $HAIKU probe medium met
expect_out "the tenth steps down" '^STEP DOWN: probe haiku medium → haiku low \(streak 10 of 10\)$' "$OUT"
adds 1 $HAIKU probe low missed
expect_out "another low miss steps back up" '^STEP UP: probe haiku low → haiku medium \(streak 0 of 20 for haiku low\)$' "$OUT"
expect_cells "the next retry needs 20" probe setting='haiku medium' streak='0 of 20 for haiku low'

echo "4. a carried long streak pays for the first probe only"
new_case carried
row long yes haiku medium
runs 100 $HAIKU long medium met
base long haiku medium --carry
expect_out "a carried streak of 100 steps down" '^STEP DOWN: long haiku medium → haiku low \(streak 100 of 5\)$' "$OUT"
adds 1 $HAIKU long low missed
expect_out "a low miss steps back up" '^STEP UP: long haiku low → haiku medium' "$OUT"
expect_cells "the retry needs 10 new mets" long setting='haiku medium' streak='0 of 10 for haiku low'
adds 9 $HAIKU long medium met
expect_none "nine new mets hold" '^(STEP|MOVE)' "$ALL"
adds 1 $HAIKU long medium met
expect_out "the tenth steps down" '^STEP DOWN: long haiku medium → haiku low \(streak 10 of 10\)$' "$OUT"

echo "5. an established setting below the baseline retreats on one miss"
new_case established
row est yes haiku medium
base est haiku medium
adds 5 $HAIKU est medium met
adds 30 $HAIKU est low met
expect_none "thirty mets at low hold" '^(STEP|MOVE)' "$ALL"
expect_cells "at the floor after thirty" est setting='haiku low' reason='at the floor'
adds 1 $HAIKU est low missed
expect_out "one miss steps back up" '^STEP UP: est haiku low → haiku medium \(streak 0 of 10 for haiku low\)$' "$OUT"

echo "6. a failing baseline steps up, comes back on the doubled need, and does not bounce"
new_case failing
row small yes haiku medium
base small haiku medium
adds 3 $HAIKU small medium met
adds 2 $HAIKU small medium missed
expect_out "two misses in five step up" \
    '^STEP UP: small haiku medium → haiku high \(2 of the last 5 runs at haiku medium missed\)$' "$OUT"
adds 19 $HAIKU small high met
expect_none "nineteen mets at high hold" '^(STEP|MOVE)' "$ALL"
expect_cells "haiku medium's two misses need 20" small setting='haiku high' streak='19 of 20 for haiku medium'
adds 1 $HAIKU small high met
expect_out "twenty mets step down" '^STEP DOWN: small haiku high → haiku medium \(streak 20 of 20\)$' "$OUT"
adds 1 $HAIKU small medium met
expect_none "the next met at medium holds" '^(STEP|MOVE)' "$OUT"
expect_cells "a met at medium ends its failing, so the walk never leaves it" small \
    setting='haiku medium' path='haiku medium' streak='1 of 5 for haiku low'
row eff yes haiku low
base eff haiku low
adds 2 $HAIKU eff low missed
expect_out "a failing low steps effort first" '^STEP UP: eff haiku low → haiku medium \(' "$OUT"
row chain yes haiku high
base chain haiku high
adds 2 $HAIKU chain high missed
expect_out "a failing high steps to the next model" '^STEP UP: chain haiku high → sonnet high \(' "$OUT"
row moved yes opus medium
base moved opus high
adds 3 $OPUS moved high met
base moved opus medium
adds 1 $OPUS moved medium missed
expect_none "one miss after a baseline down holds" '^(STEP|MOVE)' "$OUT"
expect_cells "the row stays where the baseline put it" moved setting='opus medium' misses='1/1'

echo "7. a failed setting bounds every setting it dominates, and only those"
new_case dominance
row dom yes opus medium
base dom opus medium
adds 5 $OPUS dom medium met
expect_out "five mets step down" '^STEP DOWN: dom opus medium → opus low \(streak 5 of 5\)$' "$OUT"
adds 1 $OPUS dom low missed
expect_out "the miss moves the row to sonnet medium, which opus low does not dominate: it needs 5" \
    '^MOVE: dom opus low → sonnet medium \(streak 5 of 5\)$' "$OUT"
expect_cells "sonnet low, which opus low dominates, needs 10" dom setting='sonnet medium' streak='0 of 10 for sonnet low'
adds 4 $SONNET dom medium met
expect_none "four sonnet mets hold" '^(STEP|MOVE)' "$ALL"
adds 1 $SONNET dom medium met
expect_out "the fifth steps to haiku medium, which opus low does not dominate" \
    '^STEP DOWN: dom sonnet medium → haiku medium \(streak 5 of 5\)$' "$OUT"
expect_cells "haiku low, which opus low dominates, needs 10" dom setting='haiku medium' streak='0 of 10 for haiku low'

echo "8. versions pool into their family, and a fresh baseline clears earlier misses"
new_case versions
row ver yes opus medium
base ver opus medium
adds 3 claude-opus-5-5 ver medium met
adds 2 claude-opus-5-6 ver medium met
expect_out "mets on 5-5 and 5-6 make one streak" '^STEP DOWN: ver opus medium → opus low \(streak 5 of 5\)$' "$OUT"
adds 1 claude-opus-5-5 ver low missed
adds 1 claude-opus-5-6 ver medium met
expect_cells "a run on 5-6 leaves 5-5's miss counted" ver setting='sonnet medium' streak='0 of 10 for sonnet low'
base ver opus medium
expect_cells "a fresh baseline starts the evidence over" ver \
    setting='opus medium' misses='0/0' streak='0 of 5 for opus low' baseline='opus medium fresh'

echo "9. a row without an oracle never steps down, and steps up when failing"
new_case no-oracle
row judge no opus medium
base judge opus medium
adds 20 $OPUS judge medium met
expect_none "twenty mets hold" '^(STEP|MOVE)' "$ALL"
expect_cells "no oracle" judge setting='opus medium' streak='-' reason='no oracle: refresh-ladder sets it'
adds 2 $OPUS judge medium missed
expect_out "two misses step up" '^STEP UP: judge opus medium → opus high \(2 of the last 5 runs at opus medium missed\)$' "$OUT"
row top no opus high
base top opus high
adds 2 $OPUS top high missed
expect_none "misses at the top hold" '^(STEP|MOVE)' "$ALL"
expect_cells "the top" top setting='opus high' reason='misses at the top of its ladder: refresh-ladder sets it'

echo "10. the log never moves a row onto or off fable"
new_case fable
row fab yes fable medium
base fab fable medium
adds 5 $FABLE fab medium met
expect_out "fable steps effort down" '^STEP DOWN: fab fable medium → fable low \(streak 5 of 5\)$' "$OUT"
adds 5 $FABLE fab low met
expect_none "fable low stays fable" '^(STEP|MOVE)' "$ALL"
expect_cells "fable low is the floor" fab setting='fable low' reason='at the floor'
row ftop yes fable high
base ftop fable high
adds 2 $FABLE ftop high missed
expect_cells "fable high misses at the top" ftop setting='fable high' reason='misses at the top of its ladder: refresh-ladder sets it'
row otop yes opus high
base otop opus high
adds 2 $OPUS otop high missed
expect_none "opus high never steps onto fable" '^(STEP|MOVE)' "$ALL"
expect_cells "opus high misses at the top" otop setting='opus high' reason='misses at the top of its ladder: refresh-ladder sets it'

echo "11. settings always prints its rows or what keeps it from them, and exits 0"
new_case settings
row set yes opus medium
row unset no fable medium
# settings_says <what> <regex> [env assignments]: exit 0, and stdout has a line matching.
settings_says() {
    local what="$1" want="$2" out code
    shift 2
    out="$(env "$@" python3 "$SCRIPT" settings 2>"$CASE/settings.err")"; code=$?
    if [ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -qE -- "$want" && ! grep -q Traceback "$CASE/settings.err"; then ok; else
        fail "settings with $what: exit $code, wanted /$want/ in: $out$(cat "$CASE/settings.err")"
    fi
}
NO_BASELINE='no row has a baseline yet: run effort-log baseline --from-table'
FIX='Fix the task table in the user CLAUDE.md\.$'
settings_says "the store missing" 'needs the claude-memory-sync plugin' -u EFFORT_LOG_DIR -u EFFORT_TABLE
settings_says "the table missing" "cannot read the task table.*$FIX" EFFORT_TABLE="$CASE/missing.md"
printf '| Row | Task |\n|---|---|\n| `set` | Task |\n' >"$CASE/no-oracle.md"
settings_says "a table without an Oracle column" "no task-table header with Row and Oracle.*$FIX" EFFORT_TABLE="$CASE/no-oracle.md"
{ cat "$EFFORT_TABLE"; printf '| `bad` | Task | maybe | opus | low |\n'; } >"$CASE/bad-oracle.md"
settings_says "a bad Oracle cell" "row \`bad\`.*Oracle cell 'maybe'.*$FIX" EFFORT_TABLE="$CASE/bad-oracle.md"
{ cat "$EFFORT_TABLE"; printf '| `set` | Again | yes | opus | low |\n'; } >"$CASE/duplicate.md"
settings_says "a duplicate key" "row \`set\` appears more than once.*$FIX" EFFORT_TABLE="$CASE/duplicate.md"
{ cat "$EFFORT_TABLE"; printf '| `piped` | Read a | b | yes | opus | low |\n'; } >"$CASE/piped.md"
settings_says "a Task cell with a pipe" "row \`piped\`.* has 6 cells where its header has 5.*$FIX" EFFORT_TABLE="$CASE/piped.md"
settings_says "the log dir missing" "$NO_BASELINE" EFFORT_LOG_DIR="$CASE/missing"
settings_says "no baselines" "$NO_BASELINE"
base set opus medium
out="$(python3 "$SCRIPT" settings 2>&1)"; code=$?
expect_out "a header line" "^The task-table rows' current model and effort, from the effort log:$" "$out"
expect_out "the table header" '^\| Row \| Model \| Effort \|$' "$out"
expect_out "a row with a setting" '^\| `set` \| opus \| medium \|$' "$out"
expect_out "rows without one" '^No setting in the effort log yet: `unset`\.$' "$out"
expect_none "a row without a setting is not in the table" '^\| `unset`' "$out"
expect_none "no skipped line on a clean log" 'skipped' "$out"
if [ "$code" -eq 0 ]; then ok; else fail "settings: exit $code"; fi
printf '2000-01-01T00:00:01Z\trun\t%s\tset\tmedium\tsingle\tmet\tcaf\351\n' $OPUS >>"$CASE/log/fixture.tsv"
settings_says "a non-UTF-8 line still prints the settings" '^\| `set` \| opus \| medium \|$'
settings_says "and names the line" 'skipped 1 log line that does not parse: fixture\.tsv:2 \(not UTF-8\)'
printf 'yesterday\trun\t%s\tset\tmedium\tsingle\tmet\t%s\n' $OPUS "$PAD" >>"$CASE/log/fixture.tsv"
settings_says "a bad time still prints the settings" '^\| `set` \| opus \| medium \|$'
settings_says "and names both lines" "skipped 2 log lines that do not parse: fixture\.tsv:2 \(not UTF-8\); fixture\.tsv:3 \(time 'yesterday' does not parse\)"

echo "12. tally and add survive lines that do not parse, and report them"
new_case bad-lines
row sturdy yes opus medium
base sturdy opus medium
# The session's own file gets the bad lines, so the append reads past them too.
{
    printf 'yesterday\trun\t%s\tsturdy\tmedium\tsingle\tmissed\t%s\n' $OPUS "$PAD"
    printf '2099-01-01T00:00:00Z\trun\t%s\tsturdy\tmedium\tsingle\tmissed\t\377\n' $OPUS
    printf 'too\tfew\n'
} >>"$CASE/log/$SESSION.tsv"
out="$(python3 "$SCRIPT" tally 2>&1)"; code=$?
if [ "$code" -eq 0 ]; then ok; else fail "tally with bad lines: exit $code, $out"; fi
expect_cells "the row still tallies, the bad lines' misses unread" sturdy setting='opus medium' misses='0/0'
expect_out "tally names the lines" \
    "^skipped 3 log lines that do not parse: $SESSION\.tsv:3 \(time 'yesterday' does not parse\); $SESSION\.tsv:4 \(not UTF-8\); $SESSION\.tsv:5 \(2 fields where its header has 19\)$" "$out"
adds 1 $OPUS sturdy medium met
if [ "$(grep -c "	g$AGENT	" "$CASE/log/$SESSION.tsv")" -eq 1 ] && ! grep -q 'Traceback\|effort-log:' "$CASE/add.err"; then ok; else
    fail "add with bad lines in its own file: $OUT $(cat "$CASE/add.err")"
fi
expect_out "add notes the skipped lines" "^note: skipped 3 log lines that do not parse: $SESSION\.tsv:3 " "$OUT"
expect_cells "the appended run reads" sturdy misses='0/1'
{
    printf '%s\n' "$LEGACY_HEADER"
    printf '2000-01-01T00:00:01Z\t%s\tsturdy\tmedium\tsingle\t\tmet\tl-1%s\n' $OPUS "${PAD#?}"
    printf '2000-01-01T00:00:02Z\t%s\tsturdy\tmedium\tsingle\t\tmet\tl-2\377\n' $OPUS
} >"$CASE/log/session-legacy.tsv"
SESSION=session-legacy
adds 1 $OPUS sturdy medium met
if LC_ALL=C grep -q $'l-2\377' "$CASE/log/$SESSION.tsv" && [ "$(head -1 "$CASE/log/$SESSION.tsv")" = "$HEADER	pair" ]; then ok; else
    fail "moving a legacy file onto the current header loses or mangles a line it cannot parse"
fi
expect_out "the kept line is still skipped" "session-legacy\.tsv:3 \(not UTF-8\)" "$OUT"

echo "13. add reports a move and a run at another setting; the table is never written"
new_case add-output
row esc yes opus medium
row none yes opus medium
printf '\nText after the table, | with | pipes |\n' >>"$EFFORT_TABLE"
cp "$EFFORT_TABLE" "$CASE/before.md"
base esc opus medium
adds 1 $OPUS esc medium missed
out="$(add e-1 $OPUS --row esc --level high --outcome met --role escalation)"
expect_out "an escalation at another setting is noted" '^note: this run was at opus high; esc is at opus medium$' "$out"
expect_none "and moves nothing" '^(STEP|MOVE)' "$out"
adds 1 $SONNET esc low met
expect_out "a stale session's run is noted" '^note: this run was at sonnet low; esc is at opus medium$' "$OUT"
adds 5 $OPUS esc medium met
expect_out "a step down is named" '^STEP DOWN: esc opus medium → opus low \(streak 5 of 5\)$' "$OUT"
expect_none "a run at the row's setting is not noted" '^note:' "$OUT"
adds 1 $OPUS esc low missed
expect_out "a lateral move is a MOVE" '^MOVE: esc opus low → sonnet medium \(streak 5 of 5\)$' "$OUT"
out="$(add u-1 $OPUS --row none --level medium --outcome met)"
expect_out "a row with no baseline warns" '^none has no setting yet: record one with effort-log baseline$' "$out"
if grep -q 'u-1' "$CASE/log/$SESSION.tsv"; then ok; else fail "the run of a row with no baseline is not logged"; fi
expect_cells "tally says so" none setting='no setting' reason='no baseline'
expect_out "tally lists the rows with no baseline" '^table rows with no baseline: none$'
if cmp -s "$EFFORT_TABLE" "$CASE/before.md"; then ok; else fail "add or baseline changed the table: $(diff "$CASE/before.md" "$EFFORT_TABLE")"; fi

echo "14. legacy entries: upper and lower count at their own setting, xhigh is ignored, old headers read"
new_case legacy
row pairs yes haiku medium
row later no haiku medium
row wide yes sonnet high
{
    printf '%s\n' "$LEGACY_HEADER"
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 1 $HAIKU 1 2 $HAIKU 2 3 $HAIKU 3
    printf '2000-01-01T00:00:04Z\t%s\tpairs\tmedium\tupper\tp1\tmet\tl-4\n' $HAIKU
    printf '2000-01-01T00:00:05Z\t%s\tpairs\tlow\tlower\tp1\tmissed\tl-5\n' $HAIKU
    printf '2000-01-01T00:00:0%dZ\t%s\tpairs\tmedium\tsingle\t\tmet\tl-%d\n' 6 $HAIKU 6 7 $HAIKU 7
    printf '2000-01-01T00:00:08Z\t%s\tpairs\tmedium\tupper\tp2\tmet\tl-8\n' $HAIKU
} | fill 18 >"$CASE/log/session-legacy.tsv"
{
    printf 'time\tmodel\trow\tlevel\trole\tpair\toutcome\ttokens\tsecs\n'
    printf '2000-01-01T00:00:09Z\t%s\tpairs\tmedium\tsingle\t\tmet\t100\t5\n' $HAIKU
} >"$CASE/log/session-oldest.tsv"
base pairs haiku medium --carry
expect_cells "the lower's miss at low doubles the need; upper and single mets after it count" pairs \
    setting='haiku medium' baseline='haiku medium carry' streak='4 of 10 for haiku low'
# sonnet high's candidates: sonnet medium (a miss there needs 10) and haiku high,
# which a haiku xhigh miss would bound if xhigh counted.
runs 1 $SONNET wide medium missed
runs 1 $HAIKU wide xhigh missed escalation
runs 5 $SONNET wide high met
base wide sonnet high --carry
expect_out "an xhigh miss bounds nothing" '^STEP DOWN: wide sonnet high → haiku high \(streak 5 of 5\)$' "$OUT"
SESSION=session-legacy
add l-9 $HAIKU --row later --level medium --outcome met --note 'a note' >/dev/null
if [ "$(head -1 "$CASE/log/$SESSION.tsv")" = "$HEADER	pair" ]; then ok; else
    fail "a legacy session file appended to keeps every column under the current header: $(head -1 "$CASE/log/$SESSION.tsv")"
fi
expect_cells "the legacy file still reads after the append" pairs streak='4 of 10 for haiku low'
expect_cells "the appended entry reads" later setting='no setting'
if [ "$(grep -c '	l-9	' "$CASE/log/$SESSION.tsv")" -eq 1 ]; then ok; else fail "the appended run is not in the file once"; fi

echo "15. kept: briefs, one entry per agent, the table's parsing, baselines"
new_case brief
row brief yes opus medium
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no fixture path"
runs 2 $OPUS brief medium met
runs 1 $OPUS brief medium brief single "no failing test named"
runs 1 $OPUS brief medium met
base brief opus medium --carry
expect_out "briefs neither count nor break a streak" \
    '^STEP DOWN: brief opus medium → opus low \(streak 5 of 5\)$' "$OUT"
expect_out "cluster line" '^brief misses: brief 2 of the last 7 runs$'
expect_out "cluster note" '^  brief: no fixture path$'
expect_out "cluster note" '^  brief: no failing test named$'
row once no opus medium
runs 1 $OPUS once medium brief single "only one"
expect_none "one brief in 20 is not flagged" 'brief misses: once' "$(python3 "$SCRIPT" tally 2>&1)"
add b-none $OPUS --row once --level medium --outcome brief >/dev/null; code=$?
if [ "$code" -ne 0 ] && ! grep -q b-none "$CASE"/log/*.tsv; then ok; else
    fail "brief without --note: exit $code, logged: $(grep -c b-none "$CASE"/log/*.tsv)"
fi
add b-note $OPUS --row once --level medium --outcome brief --note $'the brief\tlacked\n the  path' >/dev/null
expect_out "note is collapsed to spaces" '^  once: the brief lacked the path$'

new_case continuation
row other no opus medium
add c-1 $OPUS --row other --level medium --outcome missed >/dev/null
add c-1 $OPUS --row other --level medium --outcome met >/dev/null; code=$?
if [ "$code" -ne 0 ] && [ "$(grep -c c-1 "$CASE/log/$SESSION.tsv")" -eq 1 ]; then ok; else
    fail "an agent already logged: exit $code, entries $(grep -c c-1 "$CASE/log/$SESSION.tsv")"
fi

new_case table
cat >"$EFFORT_TABLE" <<'EOF'
# Rows

| Effort | Oracle | Row | Task |
|---|---|---|---|
|  high  |  no  |  `reordered`  | Columns in another order |

Text after the table: | `prose` | is | not | a | row
EOF
base reordered opus high
expect_cells "columns are found by name" reordered oracle=no setting='opus high'
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

new_case baselines
row fresh yes opus medium
row carry yes opus medium
row mixed yes opus medium
{
    printf '%s\n' "$LEGACY_HEADER"
    for r in fresh carry; do
        for n in 1 2 3 4 5; do printf '2000-01-01T00:0%d:0%dZ\t%s\t%s\tmedium\tsingle\t\tmet\t%s-%d\n' "$n" "${#r}" $OPUS $r $r $n; done
    done
    printf '2000-01-01T00:01:09Z\t%s\tmixed\tmedium\tsingle\t\tmet\tb-1\n' $OPUS
    printf '2000-01-01T00:02:09Z\t%s\tmixed\tlow\tsingle\t\tmet\tb-2\n' $OPUS
    printf '2000-01-01T00:03:09Z\t%s\tmixed\tmedium\tsingle\t\tmet\tb-3\n' $OPUS
    printf '2000-01-01T00:04:09Z\t%s\tmixed\tmedium\tsingle\t\tbrief\tb-4\n' $OPUS
    printf '2000-01-01T00:05:09Z\t%s\tmixed\tmedium\tsingle\t\tmet\tb-5\n' $OPUS
} | fill 18 >"$CASE/log/session-legacy.tsv"
base fresh opus medium
expect_none "a fresh baseline does not step" '^(STEP|MOVE)' "$OUT"
expect_cells "a fresh baseline counts no earlier run" fresh \
    setting='opus medium' baseline='opus medium fresh' misses='0/0' streak='0 of 5 for opus low'
base carry opus medium --carry
expect_out "a carried streak steps at the baseline" '^STEP DOWN: carry opus medium → opus low \(streak 5 of 5\)$' "$OUT"
expect_cells "the carried row is down" carry setting='opus low' path='opus medium → opus low'
base mixed opus medium --carry
expect_cells "carry counts every earlier run at its own setting" mixed \
    setting='opus medium' misses='0/3' streak='3 of 5 for opus low'
new_case from-table
row live no opus 'high, unpaired'
row small yes haiku medium
out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --from-table --note "from the table" 2>&1)"
expect_cells "--from-table reads past , unpaired" live setting='opus high' baseline='opus high fresh'
expect_cells "--from-table sets every row" small setting='haiku medium'
if [ "$(grep -c '	baseline	' "$CASE/log/$SESSION.tsv")" -eq 2 ]; then ok; else fail "--from-table wrote $(grep -c '	baseline	' "$CASE/log/$SESSION.tsv") baselines: $out"; fi
printf '| Row | Task | Oracle |\n|---|---|---|\n| `bare` | Task | yes |\n' >"$EFFORT_TABLE"
out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --from-table --note x 2>&1)"; code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q "needs Model and Effort columns"; then ok; else fail "--from-table without Model and Effort: exit $code, $out"; fi
new_case refusals
row none yes opus medium
# refused <what> <row> <family> <level> <note>: baseline exits non-zero and writes nothing.
refused() {
    local out code
    out="$(CLAUDE_CODE_SESSION_ID="$SESSION" python3 "$SCRIPT" baseline --row "$2" --model "$3" --level "$4" --note "$5" 2>&1)"
    code=$?
    if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q '^effort-log: ' && ! grep -qs '	baseline	' "$CASE/log/$SESSION.tsv"; then ok; else
        fail "baseline with $1: exit $code, $out"
    fi
}
refused "an unknown row" nope opus low x
refused "an exact id for a family" none claude-opus-5-5 low x
refused "xhigh" none opus xhigh x
refused "an empty note" none opus low '  '

echo "effort-log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
