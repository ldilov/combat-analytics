# Baseline Threat Score Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a coefficient-derived estimated threat level immediately instead of "? (no data)" when the player has fewer than 3 personal fights against a spec.

**Architecture:** `ComputeBaselineThreatScore(specId)` is a pure local function added to `StrategyEngine.lua`. It reads already-loaded seed data (archetype, threat tags, range, CC families), applies a weighted sum, and clamps the result to [0.25, 0.90]. `GetCounterGuide()` adds the result as `baselineThreatScore` in its return table. `CounterGuideView.lua` falls back to that value when personal fight data is insufficient, rendering it with `~` prefix, muted text, and half-alpha bar fill so it reads as an estimate.

**Tech Stack:** Lua 5.1 (WoW), existing `ns.StaticPvpData` accessors, no new files or API calls.

---

### Task 1: Add coefficient constants to StrategyEngine.lua

**Files:**
- Modify: `StrategyEngine.lua:56` (after `DEFAULT_ACTIONS` block, before `GetCounterGuide`)

**Step 1: Insert the constant tables**

Add the following block immediately after the closing brace of `DEFAULT_ACTIONS` (after line 56) and before the `function StrategyEngine.GetCounterGuide` line:

```lua
-- ── Baseline threat score coefficients ───────────────────────────────────
-- Used to estimate threat when historicalFights < 3. Tune weights here.
local ARCHETYPE_THREAT_BONUS = {
    setup_burst      = 0.15,
    melee_pressure   = 0.10,
    skirmisher       = 0.08,
    sustained_caster = 0.05,
    sustained_ranged = 0.05,
    control_healer   = 0.05,
    reactive_healer  = 0.03,
    bruiser          = 0.00,
}
local TAG_THREAT_BONUS = {
    frequent_cc      = 0.10,
    execute_risk     = 0.08,
    immunity_risk    = 0.08,
    control_pressure = 0.08,
    mobility_heavy   = 0.06,
    purge_pressure   = 0.04,
}
local THREAT_MELEE_BONUS    = 0.05
local THREAT_CC_FAM_BONUS   = 0.03
local THREAT_CC_FAM_CAP     = 4
local THREAT_BASE           = 0.45
local THREAT_MIN            = 0.25
local THREAT_MAX            = 0.90
```

**Step 2: Verify the file still loads (syntax check)**

```bash
cd "D:\Workspace\repos\combat-analytics"
python3 -c "
import re, sys
src = open('StrategyEngine.lua', encoding='utf-8').read()
opens  = src.count('{')
closes = src.count('}')
print(f'braces: {opens} open, {closes} close, delta={opens-closes}')
"
```

Expected: `delta=0` (all braces balanced — Lua tables open/close symmetrically in this file).

**Step 3: Commit**

```bash
git add StrategyEngine.lua
git commit -m "feat(threat): add baseline threat score coefficient constants"
```

---

### Task 2: Add ComputeBaselineThreatScore function

**Files:**
- Modify: `StrategyEngine.lua` — add local function after the constants from Task 1

**Step 1: Insert the function**

Add immediately after the `THREAT_MAX` line from Task 1:

```lua
local function ComputeBaselineThreatScore(specId)
    local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype
        and ns.StaticPvpData.GetSpecArchetype(specId) or nil
    if not archetype then return THREAT_BASE end

    local score = THREAT_BASE
    score = score + (ARCHETYPE_THREAT_BONUS[archetype.archetype] or 0)

    for _, tag in ipairs(archetype.threatTags or {}) do
        score = score + (TAG_THREAT_BONUS[tag] or 0)
    end

    if archetype.rangeBucket == "melee" then
        score = score + THREAT_MELEE_BONUS
    end

    -- Count unique CC families from SeedArenaControl data.
    local ccFamilies = ns.StaticPvpData and ns.StaticPvpData.GetCCFamiliesForSpec
        and ns.StaticPvpData.GetCCFamiliesForSpec(specId) or {}
    local familySet = {}
    for _, entry in ipairs(ccFamilies) do
        if type(entry) == "table" and entry.family then
            familySet[entry.family] = true
        end
    end
    local familyCount = 0
    for _ in pairs(familySet) do familyCount = familyCount + 1 end
    score = score + math.min(familyCount, THREAT_CC_FAM_CAP) * THREAT_CC_FAM_BONUS

    return math.max(THREAT_MIN, math.min(THREAT_MAX, score))
end
```

**Step 2: Quick sanity check on expected outputs**

Run this in a Lua 5.1 interpreter (or just reason through it):

| Spec | archetype | tags | range | CC fams | Expected |
|---|---|---|---|---|---|
| Sub Rogue (261) | setup_burst (+0.15) | frequent_cc (+0.10) | melee (+0.05) | ~4 (+0.12) | 0.45+0.15+0.10+0.05+0.12 = **0.87** |
| Blood DK (250) | bruiser (+0.00) | execute_risk (+0.08) | melee (+0.05) | ~2 (+0.06) | 0.45+0.00+0.08+0.05+0.06 = **0.64** |
| BM Hunter (253) | sustained_ranged (+0.05) | mobility_heavy (+0.06) | ranged (0) | ~2 (+0.06) | 0.45+0.05+0.06+0.06 = **0.62** |

All within [0.25, 0.90]. ✓

**Step 3: Commit**

```bash
git add StrategyEngine.lua
git commit -m "feat(threat): add ComputeBaselineThreatScore local function"
```

---

### Task 3: Wire baselineThreatScore into GetCounterGuide return

**Files:**
- Modify: `StrategyEngine.lua:58-131` (`GetCounterGuide` function body)

**Step 1: Call the function inside GetCounterGuide**

After the existing `specWinRate`/`specFights` block (currently ends around line 84), add one line:

```lua
    local baselineThreat = ComputeBaselineThreatScore(specId)
```

**Step 2: Add field to the return table**

In the `return { ... }` block (currently lines 112–130), add after the `historicalFights` line:

```lua
        baselineThreatScore  = baselineThreat,
```

So the relevant portion of the return table looks like:

```lua
    return {
        specId = specId,
        ...
        historicalWinRate    = specWinRate,
        historicalFights     = specFights,
        baselineThreatScore  = baselineThreat,   -- NEW
        winRateByMMRBand     = winRateByMMR,
        ...
    }
```

**Step 3: Commit**

```bash
git add StrategyEngine.lua
git commit -m "feat(threat): expose baselineThreatScore in GetCounterGuide return"
```

---

### Task 4: Add optional alpha param to addBar in CounterGuideView.lua

**Files:**
- Modify: `UI/CounterGuideView.lua:252-267` (`addBar` local function)

**Step 1: Change the function signature and fill alpha**

Replace the existing `addBar` definition (lines 252–267):

```lua
    -- OLD:
    local function addBar(fillFraction, r, g, b)
        ...
        fill:SetColorTexture(r or 0.5, g or 0.5, b or 0.5, 0.85)
        ...
    end
```

With:

```lua
    local function addBar(fillFraction, r, g, b, alpha)
        local bg = canvas:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(BAR_W, BAR_H)
        bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
        bg:SetColorTexture(0.10, 0.10, 0.10, 0.9)
        el[#el + 1] = bg

        if fillFraction and fillFraction > 0 then
            local fill = canvas:CreateTexture(nil, "ARTWORK")
            fill:SetSize(math.max(2, math.floor(BAR_W * fillFraction)), BAR_H)
            fill:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
            fill:SetColorTexture(r or 0.5, g or 0.5, b or 0.5, alpha or 0.85)
            el[#el + 1] = fill
        end
        yPos = yPos - (BAR_H + 8)
    end
```

Only change: signature adds `, alpha` and the hardcoded `0.85` becomes `alpha or 0.85`. All existing `addBar(...)` call sites continue to work unchanged since `alpha` defaults to `0.85`.

**Step 2: Commit**

```bash
git add UI/CounterGuideView.lua
git commit -m "refactor(threat): add optional alpha param to addBar"
```

---

### Task 5: Replace the threat block in CounterGuideView.lua

**Files:**
- Modify: `UI/CounterGuideView.lua:320-347` (threat bar section)

**Step 1: Replace the entire threat block**

Find and replace from the `-- ── THREAT BAR ──` comment through the closing `end` of the `do` block (lines 320–347):

```lua
    -- ── THREAT BAR ───────────────────────────────────────────────────────────
    addRule(2)

    local fights       = guide.historicalFights or 0
    local threatScore, isEstimated
    if fights >= 3 and guide.historicalWinRate then
        threatScore = 1.0 - guide.historicalWinRate
        isEstimated = false
    elseif guide.baselineThreatScore then
        threatScore = guide.baselineThreatScore
        isEstimated = true
    else
        threatScore = 0.5
        isEstimated = true
    end

    local thrLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    thrLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
    thrLabel:SetTextColor(unpack(Theme.textMuted))
    thrLabel:SetText("Threat Level")
    el[#el + 1] = thrLabel

    local thrVal = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    thrVal:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + BAR_W + 6, yPos)
    if isEstimated then
        thrVal:SetText(string.format("~%.0f%%  est.", threatScore * 100))
        thrVal:SetTextColor(unpack(Theme.textMuted))
    else
        thrVal:SetText(string.format("%.0f%%", threatScore * 100))
        thrVal:SetTextColor(unpack(Theme.text))
    end
    el[#el + 1] = thrVal
    yPos = yPos - 18

    do
        local r, g, b = 0.90, 0.20, 0.15
        if threatScore < 0.45 then r, g, b = 0.25, 0.80, 0.35
        elseif threatScore < 0.70 then r, g, b = 0.90, 0.65, 0.10 end
        addBar(threatScore, r, g, b, isEstimated and 0.45 or 0.85)
    end
```

Key changes vs old code:
- Three-tier `threatScore` resolution replacing the one-liner
- `isEstimated` boolean drives display text and bar alpha
- Estimated: `"~68%  est."` in muted colour, bar at 45% alpha
- Personal data: `"68%"` in full white, bar at full 85% alpha
- `guide.baselineThreatScore` is always present (Task 3), so the `else` branch (true no-data) is now unreachable in practice but kept for safety

**Step 2: Commit**

```bash
git add UI/CounterGuideView.lua
git commit -m "feat(threat): show coefficient-based baseline threat when fights < 3"
```

---

### Task 6: Final verification

**Step 1: Check no syntax regressions**

```bash
cd "D:\Workspace\repos\combat-analytics"
python3 -c "
files = ['StrategyEngine.lua', 'UI/CounterGuideView.lua']
for f in files:
    src = open(f, encoding='utf-8').read()
    o = src.count('{'); c = src.count('}')
    print(f'{f}: braces open={o} close={c} delta={o-c}')
    ends = src.count(' end') + src.count('\nend')
    print(f'  rough end-count: {ends}')
"
```

**Step 2: Verify the three render states in CounterGuideView make sense**

Trace through the logic manually for three cases:
1. `fights = 0, baselineThreatScore = 0.64` → isEstimated=true, shows `"~64%  est."`, bar at 45% alpha ✓
2. `fights = 5, historicalWinRate = 0.30` → isEstimated=false, shows `"70%"`, bar at 85% alpha ✓
3. `baselineThreatScore = nil` (StaticPvpData unavailable) → falls back to `0.5`, shows `"~50%  est."` ✓

**Step 3: Push**

```bash
git push origin main
```
