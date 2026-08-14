#!/bin/bash

# Read JSON session data from stdin
input=$(cat)

# Normalize once, so every `// default` below actually fires. On unparseable or
# empty stdin each individual jq call would otherwise fail separately, leaving
# every value an empty string rather than its default — which renders as debris
# ("📓 + -" for absent churn) instead of a clean zeroed line.
printf '%s\n' "$input" | jq -e . >/dev/null 2>&1 || input='{}'

# --- Model + effort ---
model_name=$(echo "$input" | jq -r '.model.display_name // "ERROR"' | sed 's/ ([^)]*context)$//')
# effort.level is low|medium|high|xhigh|max, reflects live /effort changes; absent if the model has no effort param
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$effort" ]; then
    model_section="$model_name ($effort)"
else
    model_section="$model_name"
fi

# --- Git Info (cached) ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // ""')

session_id=$(echo "$input" | jq -r '.session_id // "default"')
CACHE_FILE="/tmp/statusline-git-cache-${session_id}"
CACHE_MAX_AGE=5  # seconds

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]
}

if cache_is_stale; then
    touch "$CACHE_FILE"  # Claim the refresh to prevent cache stampede

    project_name=$(cd "$cwd" 2>/dev/null && basename "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "no-project")
    git_branch=$(cd "$cwd" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-git")

    # Worktree detection: check if cwd is a linked worktree (not the main working tree)
    main_tree=$(cd "$cwd" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
    this_tree=$(cd "$cwd" 2>/dev/null && git rev-parse --path-format=absolute --git-dir 2>/dev/null || echo "")
    if [ -n "$main_tree" ] && [ -n "$this_tree" ] && [ "$main_tree" != "$this_tree" ]; then
        is_worktree=1
        main_project=$(basename "$(dirname "$main_tree")")
        main_branch=$(git --git-dir="$main_tree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    else
        is_worktree=0
    fi

    # Modified (*) and untracked (+) flags
    git_status=$(cd "$cwd" 2>/dev/null && git status --porcelain 2>/dev/null || echo "")
    modified=$(echo "$git_status" | grep -qE "^.M|^M|^ M" && echo "*" || echo "")
    untracked=$(echo "$git_status" | grep -qE "^\?\?" && echo "+" || echo "")
    git_flags="$modified$untracked"

    # Ahead/behind upstream — only query if a tracking branch exists to avoid stale/misleading numbers
    ahead_behind=""
    if cd "$cwd" 2>/dev/null && git rev-parse --abbrev-ref "@{upstream}" >/dev/null 2>&1; then
        ahead_behind_counts=$(git rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null || echo "")
        if [ -n "$ahead_behind_counts" ]; then
            behind=$(echo "$ahead_behind_counts" | awk '{print $1}')
            ahead=$(echo "$ahead_behind_counts" | awk '{print $2}')
            ab=""
            [ "$ahead" != "0" ] && ab="↑${ahead}"
            [ "$behind" != "0" ] && ab="${ab}↓${behind}"
            [ -n "$ab" ] && ahead_behind=" $ab"
        fi
    fi

    if [ "$git_branch" = "no-git" ]; then
        git_icon="📦"
        git_section="no-git"
    elif [ "$is_worktree" = "1" ]; then
        git_icon="🌿"
        # Consistent project / branch format; append parent branch as trailing context
        git_section="$main_project / $git_branch$git_flags$ahead_behind ← $main_branch"
    else
        git_icon="📦"
        git_section="$project_name / $git_branch$git_flags$ahead_behind"
    fi

    printf '%s\n%s' "$git_icon" "$git_section" > "$CACHE_FILE"
else
    git_icon=$(head -1 "$CACHE_FILE")
    git_section=$(tail -1 "$CACHE_FILE")
fi

# --- Context Window ---
# Fixed-threshold coloring (context just fills up — no pace/reset window like rate limits)
color_context_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then
        printf '\033[31m%s%%\033[0m' "$pct"   # red: window nearly full
    elif [ "$pct" -ge 70 ]; then
        printf '\033[33m%s%%\033[0m' "$pct"   # yellow: filling up
    else
        printf '%s%%' "$pct"
    fi
}

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // "null"')
input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // "null"')

if [ "$used_pct" = "null" ] || [ "$window_size" = "null" ]; then
    context_info="0% ↑0K ↓0K / 0K"
elif ! [[ "$used_pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$window_size" =~ ^[0-9]+$ ]]; then
    context_info="ERROR"
else
    # The unit is chosen from the *rounded* thousands, not the raw value: at
    # k=999.999 the K branch would print "1000K" rather than promoting to "1M".
    fmt_tokens() {
        awk "BEGIN {k=$1/1000; if (k>=999.5) printf \"%.0fM\", k/1000; else printf \"%.0fK\", k}"
    }
    input_fmt=$(fmt_tokens "$input_tokens")
    output_fmt=$(fmt_tokens "$output_tokens")
    window_fmt=$(fmt_tokens "$window_size")
    pct_int=$(printf "%.0f" "$used_pct")
    context_info=$(printf "%s ↑%s ↓%s / %s" "$(color_context_pct "$pct_int")" "$input_fmt" "$output_fmt" "$window_fmt")
fi

# --- Rate Limits ---
color_for_pct() {
    local display_pct=$1    # rounded integer for display
    local raw_pct=$2        # full-resolution float for pace calculation
    local resets_at=$3      # epoch timestamp when window resets
    local window_secs=$4    # total window duration in seconds

    local now
    now=$(date +%s)
    local remaining=$(( resets_at - now ))
    [ "$remaining" -lt 0 ] && remaining=0

    # elapsed% of the time window
    local elapsed_pct
    elapsed_pct=$(awk "BEGIN {e = ($window_secs - $remaining) / $window_secs * 100; printf \"%.6f\", e}")

    # Compare raw usage % against pace
    local above_pace
    above_pace=$(awk "BEGIN {print ($raw_pct > 2 * $elapsed_pct) ? 2 : ($raw_pct > $elapsed_pct) ? 1 : 0}")

    if [ "$above_pace" = "2" ]; then
        printf '\033[31m%s%%\033[0m' "$display_pct"   # red: >2x pace
    elif [ "$above_pace" = "1" ]; then
        printf '\033[33m%s%%\033[0m' "$display_pct"   # yellow: above pace
    else
        printf '%s%%' "$display_pct"                   # normal: on/under pace
    fi
}

format_countdown() {
    local resets_at=$1
    local now
    now=$(date +%s)
    local delta=$(( resets_at - now ))
    [ "$delta" -lt 0 ] && delta=0

    if [ "$delta" -ge 86400 ]; then
        printf '↻%dd' $(( delta / 86400 ))
    elif [ "$delta" -ge 3600 ]; then
        printf '↻%dh' $(( delta / 3600 ))
    else
        printf '↻%dm' $(( delta / 60 ))
    fi
}

five_hour_pct_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Round float percentages to integers to avoid display like "28.999999999999996%"
[ -n "$five_hour_pct_raw" ] && five_hour_pct=$(printf "%.0f" "$five_hour_pct_raw") || five_hour_pct=""
[ -n "$seven_day_pct_raw" ] && seven_day_pct=$(printf "%.0f" "$seven_day_pct_raw") || seven_day_pct=""

# Each window is rendered on its own terms. Pacing a window needs both its
# percentage and its reset time, so a half-populated payload drops that half
# rather than rendering a bare "7d: %" off an empty arithmetic expression.
rate_window() { # rate_window <label> <pct> <raw pct> <resets_at> <window secs>
    [ -n "$2" ] && [ -n "$4" ] || return 0
    printf '%s: %s %s' "$1" "$(color_for_pct "$2" "$3" "$4" "$5")" "$(format_countdown "$4")"
}

rate_parts=()
five_part=$(rate_window "5h" "$five_hour_pct" "$five_hour_pct_raw" "$five_hour_resets" 18000)
seven_part=$(rate_window "7d" "$seven_day_pct" "$seven_day_pct_raw" "$seven_day_resets" 604800)
[ -n "$five_part" ] && rate_parts+=("$five_part")
[ -n "$seven_part" ] && rate_parts+=("$seven_part")

rate_section=""
for part in "${rate_parts[@]}"; do
    if [ -z "$rate_section" ]; then rate_section="🔋 $part"; else rate_section="$rate_section · $part"; fi
done

# --- Session churn (lines added/removed this session) ---
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
lines_section=""
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
    lines_section=$(printf '\033[32m+%s\033[0m \033[31m-%s\033[0m' "$lines_added" "$lines_removed")
fi

# --- Open PR for the current branch (mirrors the footer PR badge) ---
pr_number=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')
pr_section=""
if [ -n "$pr_number" ]; then
    case "$pr_state" in
        approved)          pr_glyph=$(printf ' \033[32m✓\033[0m') ;;   # green check
        changes_requested) pr_glyph=$(printf ' \033[31m✗\033[0m') ;;   # red x
        pending)           pr_glyph=$(printf ' \033[33m●\033[0m') ;;   # yellow dot: review pending
        draft)             pr_glyph=' ◌' ;;                            # hollow: draft
        *)                 pr_glyph='' ;;                              # unknown/absent review state
    esac
    pr_section="🔀 #${pr_number}${pr_glyph}"
fi

# --- Output: join non-empty segments with " | " ---
segments=("🤖 $model_section" "$git_icon $git_section")
[ -n "$pr_section" ] && segments+=("$pr_section")
[ -n "$lines_section" ] && segments+=("📓 $lines_section")
segments+=("💭 $context_info")
[ -n "$rate_section" ] && segments+=("$rate_section")

line=""
for seg in "${segments[@]}"; do
    if [ -z "$line" ]; then line="$seg"; else line="$line | $seg"; fi
done
printf '%s' "$line"
