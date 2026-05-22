#!/usr/bin/env bash
set -u
ENDPOINT="http://nia.smelt-vega.ts.net:8000/v1/chat/completions"
MODEL="RedHatAI/gemma-4-31B-it-NVFP4"
DIR="$(cd "$(dirname "$0")" && pwd)"
CTX=$(cat "$DIR/debate-input.txt")

run_critic() {
  local slot="$1" name="$2" sys="$3" temp="$4" seed="$5"
  local md="$DIR/debate-$slot-$name.md"
  jq -n --arg model "$MODEL" --arg sys "$sys" --arg user "$CTX" --argjson temp "$temp" --argjson seed "$seed" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:$user}], temperature:$temp, seed:$seed, max_tokens:900, top_p:0.95}' \
    > "$DIR/debate-payload-$slot.json"
  echo "[$slot/$name] dispatch"
  curl -sf -m 180 -X POST "$ENDPOINT" -H 'Content-Type: application/json' -d @"$DIR/debate-payload-$slot.json" -o "$DIR/debate-raw-$slot.json"
  local rc=$?
  if [ $rc -ne 0 ]; then echo "[$slot] FAIL rc=$rc"; echo "FAIL" > "$md"; return 1; fi
  jq -r '.choices[0].message.content // "EMPTY"' "$DIR/debate-raw-$slot.json" > "$md"
  echo "[$slot/$name] OK $(wc -c < "$md")B"
}

C1='You are a brutal Lua/WoW addon code-quality reviewer who has watched too many ambitious UI redesigns die under FrameXML constraints. You attack any design that ignores anchor management, frame pooling, OnUpdate cost, and SavedVariables size. Hunt engineering cost the consensus underestimated.'
C2='You are a UX-skeptic who has watched users abandon dense dashboards. You attack information density, scroll fatigue, and "everything on one screen" maximalism. You suspect single-scrollview is a mistake here.'
C3='You are an outlier-personas critic who suspects the consensus killed the best ideas (Option D cohort z-scores, Option C VOD timeline). You argue what was wrongly dismissed and what value is being left on the table.'

run_critic 1 "engcost"   "$C1" 0.45 7711 &
run_critic 2 "uxskeptic" "$C2" 0.55 8821 &
run_critic 3 "outlier"   "$C3" 0.75 9933 &
wait
echo "DEBATE DONE"
ls -la "$DIR"/debate-*.md
