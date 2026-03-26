#!/bin/bash

# Read JSON session data from stdin
input=$(cat)

# --- Model & Style ---
model_name=$(echo "$input" | jq -r '.model.display_name // "ERROR"')
output_style=$(echo "$input" | jq -r '.output_style.name // "ERROR"')

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
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // "null"')
input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // "null"')

if [ "$used_pct" = "null" ] || [ "$window_size" = "null" ]; then
    context_info="0% ↑0K ↓0K / 0K"
elif ! [[ "$used_pct" =~ ^[0-9]+$ ]] || ! [[ "$window_size" =~ ^[0-9]+$ ]]; then
    context_info="ERROR"
else
    input_k=$(awk "BEGIN {printf \"%.0f\", $input_tokens/1000}")
    output_k=$(awk "BEGIN {printf \"%.0f\", $output_tokens/1000}")
    window_k=$(awk "BEGIN {printf \"%.0f\", $window_size/1000}")
    context_info=$(printf "%.0f%% ↑%sK ↓%sK / %sK" "$used_pct" "$input_k" "$output_k" "$window_k")
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

rate_section=""
if [ -n "$five_hour_pct" ]; then
    five_color=$(color_for_pct "$five_hour_pct" "$five_hour_pct_raw" "$five_hour_resets" 18000)
    five_countdown=$(format_countdown "$five_hour_resets")
    seven_color=$(color_for_pct "$seven_day_pct" "$seven_day_pct_raw" "$seven_day_resets" 604800)
    seven_countdown=$(format_countdown "$seven_day_resets")
    rate_section=$(printf '🔋 5h: %s %s · 7d: %s %s' "$five_color" "$five_countdown" "$seven_color" "$seven_countdown")
fi

# --- Output ---
if [ -n "$rate_section" ]; then
    printf "🤖 %s | 💬 %s | %s %s | 💭 %s | %s" "$model_name" "$output_style" "$git_icon" "$git_section" "$context_info" "$rate_section"
else
    printf "🤖 %s | 💬 %s | %s %s | 💭 %s" "$model_name" "$output_style" "$git_icon" "$git_section" "$context_info"
fi
