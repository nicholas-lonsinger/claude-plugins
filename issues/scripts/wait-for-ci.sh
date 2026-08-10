#!/usr/bin/env bash
# wait-for-ci.sh — block until a pull request's CI is verifiably green.
#
# Encodes the full wait-for-green choreography so callers never improvise it:
#   1. Pin the expected head SHA and wait for the PR to report it
#      (catches pushes that silently didn't land).
#   2. Wait until the expected checks are actually registered for that SHA
#      (a watch started too early sees no/partial checks: false green).
#   3. Run one unpiped `gh pr checks --watch --fail-fast`.
#   4. Verify the final status rollup directly — the watch's exit code is
#      never trusted (it is 0 for "no checks yet" and for cancelled runs).
#
# The verdict gates on the base branch's REQUIRED checks (discovered from
# rulesets and legacy branch protection); if none are configured, it gates
# on ALL reported checks.
#
# Exit codes:
#   0  verified green on the expected head SHA — safe to merge
#   1  usage or environment error
#   2  definitively not green (failed / cancelled / timed-out check)
#   3  deadline expired with checks still pending — re-run to keep waiting
#   4  PR head never became the expected SHA — the push may not have landed
#   5  PR head moved off the expected SHA mid-wait (a new push happened)
#   6  PR is not open (merged or closed)
#
# Progress goes to stderr; the last stdout line is machine-readable:
#   wait-for-ci: verdict=<green|failed|pending|head-mismatch|...> pr=N sha=... elapsed=Ns

set -u

usage() {
  cat <<'EOF'
Usage: wait-for-ci.sh [<pr-number>] [--sha <sha>] [--timeout <seconds>] [--repo <owner/repo>]

  <pr-number>   PR to watch. Default: the PR for the current branch.
  --sha         Head SHA the PR must be at. Default: git rev-parse HEAD.
  --timeout     Overall deadline in seconds (default 3600). On expiry the
                script exits 3; re-run it to keep waiting.
  --repo        owner/repo (default: inferred from the working directory).

Exit codes: 0 green | 1 usage | 2 failed | 3 still pending | 4 push never
landed | 5 head moved | 6 PR not open. Merge only on exit 0. See the header
of this script for details.
EOF
}

PR=""
EXPECTED_SHA=""
TIMEOUT=3600
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sha) EXPECTED_SHA="${2:?--sha needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'wait-for-ci: unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) PR="$1"; shift ;;
  esac
done

say() { printf 'wait-for-ci: %s\n' "$*" >&2; }

finish() { # <exit-code> <verdict-word> [message]
  code="$1"; verdict="$2"; shift 2
  [ $# -gt 0 ] && say "$*"
  printf 'wait-for-ci: verdict=%s pr=%s sha=%s elapsed=%ss\n' \
    "$verdict" "${PR:-?}" "${EXPECTED_SHA:-?}" "$SECONDS"
  exit "$code"
}

# Retry transient gh/network failures a few times before giving up.
ghq() {
  _i=0
  while [ "$_i" -lt 3 ]; do
    if _out=$(gh "$@" 2>/dev/null); then printf '%s\n' "$_out"; return 0; fi
    _i=$((_i + 1))
    sleep 5
  done
  return 1
}

# Join a newline-separated list into "a, b, c".
oneline() { printf '%s\n' "$1" | grep . | paste -sd ',' - | sed 's/,/, /g'; }

command -v gh >/dev/null 2>&1 || { say "gh CLI not found"; exit 1; }
[ -n "$REPO" ] && export GH_REPO="$REPO"

if [ -z "$PR" ]; then
  PR=$(ghq pr view --json number --jq .number) \
    || { say "no PR number given and none resolvable from the current branch"; exit 1; }
fi

if [ -z "$EXPECTED_SHA" ]; then
  EXPECTED_SHA=$(git rev-parse HEAD 2>/dev/null) \
    || { say "not inside a git repository — pass --sha explicitly"; exit 1; }
else
  # Expand a short SHA when a repo is available; otherwise take it as-is.
  EXPECTED_SHA=$(git rev-parse "$EXPECTED_SHA" 2>/dev/null || printf '%s' "$EXPECTED_SHA")
fi

DEADLINE=$((SECONDS + TIMEOUT))

# --- snapshot: one API call per poll -> SNAP_HEAD, SNAP_STATE, SNAP_ROLLUP ---
# SNAP_ROLLUP is "name<TAB>result" lines; result is normalized so that
# anything unfinished reads PENDING and finished states keep their GraphQL
# names (SUCCESS, FAILURE, CANCELLED, ...). Handles both rollup node shapes
# (CheckRun and commit-status StatusContext).
snapshot() {
  _snap=$(ghq pr view "$PR" --json headRefOid,state,statusCheckRollup --jq '
    .headRefOid, .state,
    (.statusCheckRollup[]? |
      [ (.name // .context // "?"),
        (if .__typename == "CheckRun"
         then (if .status != "COMPLETED" then "PENDING" else (.conclusion // "PENDING") end)
         else (if .state == "EXPECTED" then "PENDING" else (.state // "PENDING") end)
         end) ] | @tsv)') || return 1
  SNAP_HEAD=$(printf '%s\n' "$_snap" | sed -n 1p)
  SNAP_STATE=$(printf '%s\n' "$_snap" | sed -n 2p)
  SNAP_ROLLUP=$(printf '%s\n' "$_snap" | sed -n '3,$p' | sort -u)
}

classify() {
  NAMES=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' 'NF {print $1}')
  PENDING_LIST=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' 'NF && $2 == "PENDING" {print $1}')
  FAILED_LIST=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' \
    'NF && $2 != "PENDING" && $2 != "SUCCESS" && $2 != "SKIPPED" && $2 != "NEUTRAL" {print $1 " (" $2 ")"}')
}

# Required checks not yet present in the rollup at all.
missing_required() {
  [ -z "$REQUIRED" ] && return 0
  while IFS= read -r _ctx; do
    [ -z "$_ctx" ] && continue
    printf '%s\n' "$NAMES" | grep -Fxq -- "$_ctx" || printf '%s\n' "$_ctx"
  done <<EOF
$REQUIRED
EOF
}

# Failures that gate the verdict: required-only when a required list exists,
# otherwise every failure.
gating_failures() {
  if [ -z "$REQUIRED" ]; then printf '%s\n' "$FAILED_LIST" | grep . || true; return 0; fi
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _name=${_line% (*}
    printf '%s\n' "$REQUIRED" | grep -Fxq -- "$_name" && printf '%s\n' "$_line"
  done <<EOF
$FAILED_LIST
EOF
  return 0
}

deadline_check() { # <what we're still waiting for>
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    finish 3 pending "deadline (${TIMEOUT}s) reached — $1 — re-run to keep waiting"
  fi
}

# One unpiped watch, bounded by the overall deadline. Its exit code is
# intentionally ignored; the caller re-verifies the rollup afterwards.
bounded_watch() {
  gh pr checks "$PR" --watch --fail-fast >/dev/null 2>&1 &
  _wpid=$!
  while kill -0 "$_wpid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
      kill "$_wpid" 2>/dev/null
      break
    fi
    sleep 10
  done
  wait "$_wpid" 2>/dev/null
  return 0
}

report_table() {
  [ -z "$SNAP_ROLLUP" ] && return 0
  say "check status:"
  printf '%s\n' "$SNAP_ROLLUP" | while IFS="$(printf '\t')" read -r _n _r; do
    [ -z "$_n" ] && continue
    case "$_r" in
      SUCCESS|SKIPPED|NEUTRAL) _mark="ok " ;;
      PENDING) _mark=".. " ;;
      *) _mark="XX " ;;
    esac
    _req=""
    if [ -n "$REQUIRED" ] && printf '%s\n' "$REQUIRED" | grep -Fxq -- "$_n"; then
      _req=" (required)"
    fi
    printf '  %s%s: %s%s\n' "$_mark" "$_n" "$_r" "$_req" >&2
  done
}

# --- stage 1: confirm the PR is open and its head is the expected SHA -------
say "watching PR #$PR for head $(printf '%.8s' "$EXPECTED_SHA") (timeout ${TIMEOUT}s)"
HEAD_BARRIER=$((SECONDS + 180))
while :; do
  snapshot || { say "could not query PR #$PR"; exit 1; }
  case "$SNAP_STATE" in
    OPEN) ;;
    MERGED) finish 6 already-merged "PR #$PR is already merged" ;;
    *) finish 6 not-open "PR #$PR state is $SNAP_STATE" ;;
  esac
  [ "$SNAP_HEAD" = "$EXPECTED_SHA" ] && break
  if [ "$SECONDS" -ge "$HEAD_BARRIER" ]; then
    finish 4 head-mismatch "PR head is $SNAP_HEAD, expected $EXPECTED_SHA — did the push land? (a bare 'git push' with mismatched local/remote branch names silently no-ops; push with an explicit refspec and re-run)"
  fi
  say "PR head is $(printf '%.8s' "$SNAP_HEAD"), waiting for the push to land…"
  sleep 5
done
say "head SHA confirmed on PR #$PR"

# --- stage 2: discover the base branch's required checks --------------------
BASE=$(ghq pr view "$PR" --json baseRefName --jq .baseRefName) || BASE=""
REQUIRED=""
if [ -n "$BASE" ]; then
  # Capture each call and discard its output on failure — gh api prints the
  # error body (JSON) to stdout on a 404, which would pollute the list.
  RULESET_REQ=$(gh api "repos/{owner}/{repo}/rules/branches/$BASE" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null) \
    || RULESET_REQ=""
  LEGACY_REQ=$(gh api "repos/{owner}/{repo}/branches/$BASE/protection/required_status_checks" \
    --jq '.checks[]?.context // empty' 2>/dev/null) \
    || LEGACY_REQ=""
  REQUIRED=$(printf '%s\n%s\n' "$RULESET_REQ" "$LEGACY_REQ" | sort -u | grep . || true)
fi
if [ -n "$REQUIRED" ]; then
  say "required checks on $BASE: $(oneline "$REQUIRED")"
else
  say "no required-check list found for $BASE — gating on ALL reported checks"
fi

# --- stage 3+4: barrier, watch, verify — loop until a definitive verdict ----
PREV_COUNT=-1
while :; do
  snapshot || { say "could not query PR #$PR"; exit 1; }
  case "$SNAP_STATE" in
    OPEN) ;;
    MERGED) finish 6 already-merged "PR #$PR was merged while waiting" ;;
    *) finish 6 not-open "PR #$PR state became $SNAP_STATE" ;;
  esac
  if [ "$SNAP_HEAD" != "$EXPECTED_SHA" ]; then
    finish 5 head-moved "PR head moved to $(printf '%.8s' "$SNAP_HEAD") (a new push happened) — re-run against the new head"
  fi
  classify

  # Barrier: don't trust anything until the expected checks are registered.
  if [ -n "$REQUIRED" ]; then
    MISSING=$(missing_required)
    if [ -n "$MISSING" ]; then
      deadline_check "required check(s) never registered: $(oneline "$MISSING")"
      say "waiting for required check(s) to register: $(oneline "$MISSING")"
      sleep 10
      continue
    fi
  else
    COUNT=$(printf '%s\n' "$SNAP_ROLLUP" | grep -c .)
    if [ "$COUNT" -eq 0 ] || [ "$COUNT" != "$PREV_COUNT" ]; then
      deadline_check "checks still registering ($COUNT reported)"
      say "waiting for the reported check set to settle ($COUNT so far)…"
      PREV_COUNT=$COUNT
      sleep 15
      continue
    fi
  fi

  # A required check already failed: no point waiting for the rest.
  GATING=$(gating_failures)
  if [ -n "$GATING" ]; then
    report_table
    finish 2 failed "not green — failing: $(oneline "$GATING")"
  fi

  if [ -n "$PENDING_LIST" ]; then
    say "$(printf '%s\n' "$PENDING_LIST" | grep -c .) check(s) pending (elapsed ${SECONDS}s) — watching…"
    bounded_watch
    deadline_check "still pending: $(oneline "$PENDING_LIST")"
    sleep 5
    continue
  fi

  # Nothing pending, everything registered: final verdict.
  report_table
  if [ -n "$FAILED_LIST" ]; then
    say "note: non-required check(s) not green: $(oneline "$FAILED_LIST")"
  fi
  finish 0 green "verified green on $(printf '%.8s' "$EXPECTED_SHA")"
done
