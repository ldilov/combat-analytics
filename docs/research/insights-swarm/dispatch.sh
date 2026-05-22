#!/usr/bin/env bash
set -u
ENDPOINT="http://nia.smelt-vega.ts.net:8000/v1/chat/completions"
MODEL="RedHatAI/gemma-4-31B-it-NVFP4"
DIR="$(cd "$(dirname "$0")" && pwd)"
CTX=$(cat "$DIR/context.txt")

run_agent() {
  local slot="$1" persona_name="$2" persona="$3" temp="$4" seed="$5"
  local payload="$DIR/payload-$slot.json"
  local raw="$DIR/raw-$slot.json"
  local md="$DIR/proposal-$slot-$persona_name.md"

  jq -n \
    --arg model "$MODEL" \
    --arg sys "$persona" \
    --arg user "$CTX" \
    --argjson temp "$temp" \
    --argjson seed "$seed" \
    '{
      model: $model,
      messages: [{role:"system", content:$sys},{role:"user", content:$user}],
      temperature: $temp,
      seed: $seed,
      max_tokens: 1400,
      top_p: 0.95
    }' > "$payload"

  echo "[$slot/$persona_name] dispatch temp=$temp seed=$seed"
  local t0=$(date +%s)
  curl -sf -m 240 -X POST "$ENDPOINT" -H 'Content-Type: application/json' -d @"$payload" -o "$raw"
  local rc=$? t1=$(date +%s)
  if [ $rc -ne 0 ]; then
    echo "[$slot/$persona_name] FAIL rc=$rc after $((t1-t0))s"
    echo "FAIL rc=$rc" > "$md"
    return 1
  fi
  jq -r '.choices[0].message.content // .error.message // "EMPTY"' "$raw" > "$md"
  local len=$(wc -c < "$md")
  echo "[$slot/$persona_name] OK ${len}B in $((t1-t0))s"
}

P1_SYS='You are an ex-Rank-1 PvP coach who has shoutcasted WoW arena. You think in moments: openers, kill windows, defensive trades, peel sequences. You judge insights by "would I tell my student this between games?" You hate generic stats; you love specific timed callouts. You despise UI clutter. Output a redesign that puts ACTIONABLE TIMING FIXES front and center. Use a "next game checklist" framing.'
P2_SYS='You are a quantitative game-analytics researcher (PhD stats). You think in baselines, deltas, z-scores, percentile bands. You love confidence intervals, sample size disclosure, and comparison against cohort. You distrust single-session noise. Output a redesign anchored around STATISTICAL COMPARISON, distribution charts, and cohort percentiles.'
P3_SYS='You are a senior game-UX designer (Riot/Blizzard). You think in visual hierarchy, glanceability, emotional pacing. You hate vertical card stacks. You love editorial layouts, bento grids, headline-plus-evidence framing. Output a redesign that nails LAYOUT, INFORMATION DENSITY, SCANNABILITY. Describe specific frame regions, sizes, eye flow.'
P4_SYS='You are a skeptical engineer who has burned hours debugging fantasy features. You only trust insights backed by data the addon ACTUALLY has reliably. You reject anything requiring opponent inspection mid-fight or party sync. You insist on graceful degradation. Output a redesign optimized for REALISM: every section maps to a real data source, every section degrades gracefully.'
P5_SYS='You are a competitive streamer who reviews VODs with viewers. You care about narrative beats, shareable moments, turning points. You hate spreadsheets. You love timeline-driven storytelling. Output a redesign anchored on TIMELINE REPLAY + MOMENT CARDS, with insights anchored to specific seconds.'
P6_SYS='You are an esports analyst writing weekly meta reports. You think in PATTERNS over sessions: matchup trends, comp mastery curves, learning velocity. You believe a single session is noise; value is in cross-session synthesis. Output a redesign that re-balances Insights toward LONGITUDINAL PATTERN DETECTION.'

run_agent 1 "coach"      "$P1_SYS" 0.55 1117 &
run_agent 2 "datasci"    "$P2_SYS" 0.40 2241 &
run_agent 3 "uxdesigner" "$P3_SYS" 0.85 3359 &
run_agent 4 "skeptic"    "$P4_SYS" 0.30 4473 &
run_agent 5 "streamer"   "$P5_SYS" 0.90 5587 &
run_agent 6 "analyst"    "$P6_SYS" 0.65 6691 &

wait
echo "ALL AGENTS COMPLETE"
ls -la "$DIR"/proposal-*.md
