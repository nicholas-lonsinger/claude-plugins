#!/bin/bash

# Renders the body of each subagent row in the agent panel, for the `subagentStatusLine`
# setting. Wired up by statusline-setup.sh, which points that settings key at a stable
# symlink to this file.
#
# Renders each row in the main status line's visual grammar: " | "-joined segments,
# one emoji per segment, K/M token formatting, and the same 70%/90% context coloring.
# The bounded columns lead — model, context — because their widths barely move, so the
# eye can scan straight down them; identity and the free-flowing tail follow. The state
# column — the elapsed clock or a terminal glyph — is flushed to the right edge instead:
# the payload's `columns` field is the usable row width, so padding the gap out to
# exactly that width hangs every row's clock off the same edge. The renderer eats
# overflow from the right — exactly where the state now sits — so the fit is guaranteed
# here rather than left to it: the volatile tail is clipped to whatever width the row
# has left before the gap is padded, and a row too narrow to align at all falls back to
# joining the state in sequence.
#
# Columns line up across rows. Every visible row arrives in a single payload, so the widths
# are measured from the actual content on each tick rather than guessed at — no static
# column sizes to outgrow. Padding is by display width, not character count: the emoji
# prefixes occupy two terminal cells each and the colored percentage carries zero-width
# escapes, so counting characters would misalign every row that is colored.
#
# Contract: stdin is one JSON object; stdout is JSONL, one {"id","content"} per line.
# Emitting no line for a task leaves that row with its default rendering, so skipping a row
# we cannot render is always safe. A non-zero exit discards every decoration, so this
# always exits 0.

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

printf '%s\n' "$input" | jq -c '
  # Built from its code point rather than written as a literal byte: a raw control
  # character in the source does not survive editing reliably, and when it is lost the
  # colors degrade silently into visible "[33m" text rather than failing outright.
  def esc: [27] | implode;

  # Claude Code parses this ANSI into React props rather than forwarding the bytes, so a
  # full reset only clears the style tracked by that parser: it cannot unwind the dim/bold
  # the panel wraps the row in. Matches statusline.sh, and stays correct if content ever
  # spans multiple lines, where escape state is deliberately carried forward line to line.
  def color($code; $text): esc + "[" + $code + "m" + $text + esc + "[0m";

  # Task text is model-authored. Control characters would either inject raw ANSI into the
  # row or break the single-line box, so they are flattened to spaces. \p{Cntrl} is the
  # class jq/Oniguruma actually honors — a [ -] range silently matches letters.
  def clean: if type == "string" then gsub("\\p{Cntrl}"; " ") else null end;

  # Anchors on the model family wherever it sits in the id, so provider-prefixed and
  # date-suffixed ids survive: "us.anthropic.claude-opus-5-v1:0" and "claude-3-5-sonnet-
  # 20241022" both resolve, rather than being split positionally into nonsense.
  def pretty_model:
    if type != "string" or . == "" then null
    else
      . as $raw
      | ( ascii_downcase
          | sub("^[a-z]+\\.anthropic\\."; "") | sub("^anthropic\\."; "")
          | sub("^claude-"; "")
          | sub("\\[1m\\]"; "")
          | sub("[-@][0-9]{8}"; "")
          | sub("-v[0-9]+:[0-9]+$"; "")
        ) as $id
      # The family must be bound before the pipe: inside contains(), "." would rebind to
      # $id and the test would degenerate into "$id contains $id" — always the first entry.
      | ( ["opus", "sonnet", "haiku", "fable"]
          | map(. as $f | select($id | contains($f))) | first ) as $fam
      | if $fam == null then $raw
        else
          ($id | split($fam)) as $p
          | ( (($p[1] // "") | capture("^[^0-9]*(?<n>[0-9]+(-[0-9]+)*)") | .n) // "" ) as $after
          | ( (($p[0] // "") | capture("(?<n>[0-9]+(-[0-9]+)*)[^0-9]*$") | .n) // "" ) as $before
          | (if $after != "" then $after else $before end) as $ver
          | (($fam[0:1] | ascii_upcase) + $fam[1:])
            + (if $ver == "" then "" else " " + ($ver | gsub("-"; ".")) end)
        end
    end;

  # Terminal cells, not characters: escapes are stripped, and the ranges below cover the
  # codepoints that occupy two cells. Misc-symbols (U+2600..U+27BF) is deliberately absent:
  # the glyphs used here from that block — the check, the cross, the stopwatch — default to
  # text presentation and render one cell wide, so counting them as two shifts every row
  # that reaches a terminal state.
  def strip_ansi: gsub(esc + "\\[[0-9;]*m"; "");
  def dwidth:
    ( strip_ansi | explode
      | map( if   (. >=   4352 and . <=   4447)    # Hangul jamo
                or (. >=  11904 and . <=  42191)    # CJK and friends
                or (. >=  44032 and . <=  55203)    # Hangul syllables
                or (. >=  63744 and . <=  64255)    # CJK compatibility ideographs
                or (. >=  65072 and . <=  65135)    # CJK compatibility forms
                or (. >=  65280 and . <=  65376)    # fullwidth forms
                or (. >= 127744 and . <= 129791)    # emoji
             then 2 else 1 end )
      | add ) // 0;
  def pad($w): . + (($w - dwidth) as $n | if $n > 0 then " " * $n else "" end);
  def clip($w):
    if dwidth <= $w then .
    else (explode | .[0:($w - 1)] | implode) + "\u2026" end;

  # The unit is chosen from the *rounded* thousands, not the raw value: at
  # $k = 999.999 the K branch would render "1000K" rather than promoting to "1M".
  def fmt_tokens:
    (. / 1000) as $k
    | if ($k | round) >= 1000 then (($k / 1000 | round | tostring) + "M")
      else (($k | round | tostring) + "K") end;

  # Fixed thresholds, matching the main line: context just fills up, there is no pace to beat.
  def pct_seg($pct):
    if   $pct >= 90 then color("31"; ($pct | tostring) + "%")
    elif $pct >= 70 then color("33"; ($pct | tostring) + "%")
    else ($pct | tostring) + "%" end;

  # Clamped at zero: a startTime skewed into the future would otherwise render "-1s".
  def elapsed($ms):
    ($ms / 1000 | floor) as $raw
    | (if $raw < 0 then 0 else $raw end) as $s
    | if   $s >= 86400 then (($s / 86400 | floor) | tostring) + "d" + ((($s % 86400) / 3600 | floor) | tostring) + "h"
      elif $s >= 3600  then (($s / 3600  | floor) | tostring) + "h" + ((($s % 3600)  / 60   | floor) | tostring) + "m"
      elif $s >= 60    then (($s / 60    | floor) | tostring) + "m" + (($s % 60) | tostring) + "s"
      else ($s | tostring) + "s" end;

  (now * 1000) as $now
  | .cwd as $session_cwd
  # Documented as the usable row width — the value to fill to, not the raw terminal width.
  | (.columns // 120) as $cols

  # Collected rather than streamed, because a column cannot be sized until every row that
  # shares it has been built.
  | [ .tasks[]?
      | . as $t

  # jq aborts its whole stream on a type error, which would drop this row AND every row
  # after it. Per-task try/catch keeps one odd task from taking down its neighbours.
      | try (
        ($t.description | clean) as $desc
      | ($t.label | clean) as $label
      | (($t.name | clean) // "") as $name
      | ($desc // $label) as $ident

      # No id means we cannot address the row; no identity means we would render a
      # placeholder. Both are better left to the default renderer.
      | select(($t.id | type) == "string" and $ident != null and $ident != "")

      | {
          id: $t.id,

          # Model leads: it is short and near-fixed-width, so rows align down the panel.
          # effort is a level string ("xhigh") OR a numeric token budget, hence tostring.
          model: ( ($t.model | pretty_model) as $m
                   | if $m == null then ""
                     else "🤖 " + $m
                          + (if ($t.effort // "") != "" then " (" + ($t.effort | tostring) + ")" else "" end)
                     end ),

          # `name` is the SendMessage-addressable handle. Present for fork and background-skill
          # spawns, absent for a plain subagent — so description carries identity on its own.
          # Padded despite being the last column, so the tail after it starts square.
          ident: ( "📋 " + (if $name != "" then $name + " / " + $ident else $ident end) ),

          # Percentage against the window, without the absolute count: the count is exactly
          # the product of the two figures shown, so printing it spends width on a number
          # the reader can already derive.
          ctx: ( if ($t.contextWindowSize // 0) > 0 then
                   (($t.tokenCount // 0) * 100 / $t.contextWindowSize | round) as $pct
                   | "💭 " + pct_seg($pct) + " / " + ($t.contextWindowSize | fmt_tokens)
                 else "" end ),

          # Terminal states borrow the PR glyphs from the main line. They cannot show a
          # duration: the task carries an endTime internally, but it is never serialized
          # into this payload. Rendered flush right in the final assembly, not joined here.
          state: ( if   $t.status == "running"   then "⏱ " + elapsed($now - ($t.startTime // $now))
                   elif $t.status == "completed" then color("32"; "✓") + " completed"
                   elif ($t.status == "failed" or $t.status == "killed") then color("31"; "✗") + " " + $t.status
                   else "" end ),

          # Free-flowing tail: never padded, and clipped away first in the final assembly
          # when the row runs short, which is why the volatile activity label lives here.
          tail: ( [ ( ($t.cwd // "") as $c
                      | if ($c | type) == "string" and $c != "" and $c != $session_cwd
                        then (($c | split("/") | map(select(. != "")) | last) // "") as $b
                             | if $b != "" then "🌿 " + $b else empty end
                        else empty end ),
                    ( if ($label // "") != "" and $label != $desc then $label else empty end )
                  ] | join(" | ") )
        }
    ) catch empty ] as $rows

  # Identity is the one unbounded column, so it is capped before it is measured — a single
  # long description must not push every other column off the right edge.
  | (([($cols / 3 | floor), 46] | min)) as $ident_cap
  | ($rows | map(.ident |= clip($ident_cap))) as $rows
  | (($rows | map(.model | dwidth) | max) // 0) as $w_model
  | (($rows | map(.ident | dwidth) | max) // 0) as $w_ident
  | (($rows | map(.ctx   | dwidth) | max) // 0) as $w_ctx

  # A row missing a column still reserves its width, so the columns beside it stay true —
  # but a column empty on EVERY row has zero width, and joining it would leave orphaned
  # leading separators, so those are dropped rather than joined.
  | $rows[]
  | ( [ (.model | pad($w_model)),
        (.ctx   | pad($w_ctx)),
        (.ident | pad($w_ident)) ]
      | map(select(. != "")) | join(" | ") ) as $head

  # The state is flushed right: the tail may only spend what the head and the state
  # leave over (their " | " and two-space gutters included), and is clipped to that
  # before the gap is measured, so the state always lands inside the usable width.
  | (.state | dwidth) as $state_w
  | ($cols - ($head | dwidth) - 3 - (if .state == "" then 0 else $state_w + 2 end)) as $tail_room
  | (if .tail == "" or $tail_room < 2 then "" else (.tail | clip($tail_room)) end) as $tail
  | ( ($head + (if $tail == "" then "" else " | " + $tail end)) | sub("[ |]+$"; "") ) as $left
  | ($cols - ($left | dwidth) - $state_w) as $gap
  | { id: .id,
      content: ( if .state == "" then $left
                 elif $gap >= 2 then $left + (" " * $gap) + .state
                 # No room to align — an oversized model id, a tiny terminal. Fall back
                 # to joining in sequence and let the renderer truncate the overflow.
                 else $left + " | " + .state end ) }
' 2>/dev/null

exit 0
