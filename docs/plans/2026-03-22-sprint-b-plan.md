# Sprint B Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix two silent P0 data bugs (aggregate lookup, snapshot accessor) and ship two new features (Visual Timeline Replay, Build Comparator tab).

**Architecture:** All changes are in pure Lua WoW addon code. Two new UI module files. Two existing modules patched. No new data is collected — all features use data already stored in existing session and aggregate fields.

**Tech Stack:** Lua 5.1, WoW Midnight 11.2+ API, WoW frame system (CreateFrame / CreateTexture / FontString). No test runner — verification is manual in-game plus Lua syntax checks with `luac -p`.

**Design doc:** `docs/plans/2026-03-22-sprint-b-design.md`

---

## Orientation

This is a WoW PvP analytics addon. All code is Lua. The addon root is at `D:\Workspace\repos\combat-analytics\`.

Key concepts you must know before touching any file:

- **`ns`** — the addon namespace table. Every file starts with `local _, ns = ...`.
- **Modules** — registered with `ns.Addon:RegisterModule("Name", table)` and retrieved with `ns.Addon:GetModule("Name")`.
- **`ns.Widgets`** — shared UI helpers. `CreateButton`, `CreateSectionTitle`, `CreateCaption`, `CreateScrollCanvas`, `SetCanvasHeight`.
- **`ns.Widgets.THEME`** — color table. Keys: `text`, `textMuted`, `accent`, `success`, `warning`, `border`, `borderStrong`, `panel`, `background`.
- **Aggregate buckets** — `db.aggregates.specs["261"]` is a table `{kind, key, label, fights, wins, losses, totalDamageDone, totalDamageTaken, totalDeaths, totalPressureScore, totalBurstScore, topSpells, lastSessionId, ...}`. The `.key` field always equals the map key.
- **`GetAggregateBuckets(kind)`** — returns a **sorted list** `[{...}, {...}]`. The list items have `.key` but the list itself has no string keys. This is the root of P0 Bug 1.
- **`ns.Addon:GetLatestPlayerSnapshot()`** — the canonical accessor for the current player's talent/build snapshot. Three files currently call `ns.Addon.runtime.playerSnapshot` (a field that is never written) instead.
- **rawEvents** — each entry: `{timestampOffset, eventType, spellId, sourceMine, destMine, isCooldownCast, ...}`. `timestampOffset` is seconds from session start. `eventType` is one of: `"cast"`, `"damage"`, `"healing"`, `"aura"`, `"death"`, `"interrupt"`, `"dispel"`, `"miss"`, `"summon"`.
- **ccReceived** — each entry: `{spellId, startOffset, duration}`. `startOffset` is seconds from session start.
- **killWindows** — each entry: `{openedAt, closedAt, healerSlot, converted}`. `openedAt`/`closedAt` are seconds from session start (returned by `getSessionRelativeOffset`).

---

## Task 1: Add aggregate lookup helpers to CombatStore

**Files:**
- Modify: `CombatStore.lua` — insert after line 985 (after the closing `end` of `GetAggregateBuckets`)

**Background:** `GetAggregateBuckets(kind)` returns a sorted list. Four consumers treat it as a keyed map, so their lookups always return nil. The fix is two new helpers that do a linear scan by `bucket.key`.

**Step 1: Open `CombatStore.lua` and locate the insertion point**

Find line 985 — it is the closing `end` of `GetAggregateBuckets`. The function ends:
```lua
    Helpers.SortByField(list, "fights", true)
    return list
end
```

The new functions go immediately after this `end` (before the blank line that precedes `GetDummyBenchmarks` at line 987).

**Step 2: Insert the two new functions**

Add this block after line 985:

```lua
function CombatStore:GetAggregateBucketByKey(kind, key, characterKey)
    if not key then return nil end
    local list = self:GetAggregateBuckets(kind, characterKey)
    local searchKey = tostring(key)
    for _, bucket in ipairs(list) do
        if bucket.key == searchKey then
            return bucket
        end
    end
    return nil
end

function CombatStore:GetSpecBucket(specId, characterKey)
    return self:GetAggregateBucketByKey("specs", specId, characterKey)
end
```

**Step 3: Syntax-check the file**

```bash
luac -p "D:\Workspace\repos\combat-analytics\CombatStore.lua"
```

Expected: no output (clean parse). If `luac` is not on PATH, skip to in-game verification.

**Step 4: In-game smoke test**

```
/reload
/ca
```

Expected: addon loads without Lua errors. The new functions are not called yet so no visible change. Proceed to Task 2 to wire up call sites.

**Step 5: Commit**

```bash
git add CombatStore.lua
git commit -m "feat(store): add GetAggregateBucketByKey and GetSpecBucket helpers"
```

---

## Task 2: Fix StrategyEngine broken aggregate lookups

**Files:**
- Modify: `StrategyEngine.lua:133-142` (historical win rate block)
- Modify: `StrategyEngine.lua:195-201` (`HasSufficientData` function)

**Background:** Both sites call `store:GetAggregateBuckets("specs")` and index the result as a map. The result is a list, so indexing by spec ID string always returns nil.

**Step 1: Fix the historical win-rate block (lines 133–142)**

Current code (lines 133–142):
```lua
    if store and store.GetAggregateBuckets then
        local specBuckets = store:GetAggregateBuckets("specs")
        local specKey = tostring(specId)
        if specBuckets and specBuckets[specKey] then
            local bucket = specBuckets[specKey]
            specFights = bucket.fights or 0
            if specFights > 0 then
                specWinRate = (bucket.wins or 0) / specFights
            end
        end
    end
```

Replace with:
```lua
    if store and store.GetAggregateBucketByKey then
        local bucket = store:GetAggregateBucketByKey("specs", specId)
        if bucket then
            specFights = bucket.fights or 0
            if specFights > 0 then
                specWinRate = (bucket.wins or 0) / specFights
            end
        end
    end
```

**Step 2: Fix `HasSufficientData` (lines 195–201)**

Current code:
```lua
function StrategyEngine.HasSufficientData(specId, characterKey)
    local store = ns.Addon:GetModule("CombatStore")
    if not store or not store.GetAggregateBuckets then return false end
    local specBuckets = store:GetAggregateBuckets("specs")
    local specKey = tostring(specId)
    return specBuckets and specBuckets[specKey] and (specBuckets[specKey].fights or 0) >= 5
end
```

Replace with:
```lua
function StrategyEngine.HasSufficientData(specId, characterKey)
    local store = ns.Addon:GetModule("CombatStore")
    if not store or not store.GetAggregateBucketByKey then return false end
    local bucket = store:GetAggregateBucketByKey("specs", specId, characterKey)
    return bucket ~= nil and (bucket.fights or 0) >= 5
end
```

**Step 3: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\StrategyEngine.lua"
```

**Step 4: Commit**

```bash
git add StrategyEngine.lua
git commit -m "fix(strategy): use GetAggregateBucketByKey for spec win-rate and HasSufficientData"
```

---

## Task 3: Fix SuggestionEngine broken aggregate lookup

**Files:**
- Modify: `SuggestionEngine.lua:237-239`

**Background:** `SPEC_WINRATE_DEFICIT` and `SPEC_WINRATE_STRENGTH` rules look up spec history by treating the bucket list as a map.

**Step 1: Find the broken block (lines 237–239)**

Current code:
```lua
        local specBuckets = store.GetAggregateBuckets and store:GetAggregateBuckets("specs") or {}
        local specKey = tostring(opponent.specId)
        local specBucket = specBuckets[specKey]
```

**Step 2: Replace with new helper**

```lua
        local specBucket = store.GetAggregateBucketByKey
            and store:GetAggregateBucketByKey("specs", opponent.specId) or nil
```

The `specKey` variable is no longer needed — delete that line too. The `specBucket` variable name remains the same so all downstream code (`specBucket.fights`, `specBucket.wins`, etc.) continues to work unchanged.

**Step 3: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\SuggestionEngine.lua"
```

**Step 4: In-game verify**

After `/reload`, complete or review a session against a spec you have ≥10 fights of history against. Open Insights tab. If your win rate is < 40% against that spec, `SPEC_WINRATE_DEFICIT` should now appear. If > 70%, `SPEC_WINRATE_STRENGTH` should appear.

**Step 5: Commit**

```bash
git add SuggestionEngine.lua
git commit -m "fix(suggestions): use GetAggregateBucketByKey for SPEC_WINRATE rules"
```

---

## Task 4: Fix CounterGuideView broken aggregate lookup

**Files:**
- Modify: `UI/CounterGuideView.lua:66-71` (`getSpecWinLoss` local function)

**Background:** The left-panel W/L badges always show 0W 0L because `getSpecWinLoss` indexes the bucket list as a map.

**Step 1: Find the function (lines 66–71)**

Current code:
```lua
local function getSpecWinLoss(store, specId)
    if not store or not store.GetAggregateBuckets then return 0, 0 end
    local buckets = store:GetAggregateBuckets("specs")
    local key     = tostring(specId)
    if not buckets or not buckets[key] then return 0, 0 end
    return buckets[key].wins or 0, buckets[key].losses or 0
end
```

**Step 2: Replace**

```lua
local function getSpecWinLoss(store, specId)
    if not store or not store.GetAggregateBucketByKey then return 0, 0 end
    local bucket = store:GetAggregateBucketByKey("specs", specId)
    if not bucket then return 0, 0 end
    return bucket.wins or 0, bucket.losses or 0
end
```

**Step 3: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\CounterGuideView.lua"
```

**Step 4: In-game verify**

```
/reload
/ca
```

Navigate to the Counters tab. Click a spec you have history against. The left-panel badge should now show non-zero W/L numbers (e.g. "6W 4L").

**Step 5: Commit**

```bash
git add "UI\CounterGuideView.lua"
git commit -m "fix(ui): CounterGuideView W/L badges now use GetAggregateBucketByKey"
```

---

## Task 5: Fix snapshot accessor inconsistency (P0 Fix 2)

**Files:**
- Modify: `UI/CounterGuideView.lua:197`
- Modify: `UI/MatchupDetailView.lua:59`
- Modify: `CombatTracker.lua:2527`

**Background:** `ns.Addon.runtime.playerSnapshot` is never written anywhere. The correct field is `runtime.latestPlayerSnapshot`, exposed via `ns.Addon:GetLatestPlayerSnapshot()`. Three files read the wrong field, so `buildHash` is always nil in build-aware features.

**Step 1: Fix `UI/CounterGuideView.lua` line 197**

Current:
```lua
    local snapshot       = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot or nil
```

Replace with:
```lua
    local snapshot       = ns.Addon:GetLatestPlayerSnapshot()
```

**Step 2: Fix `UI/MatchupDetailView.lua` line 59**

Current:
```lua
    local snapshot = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot or nil
```

Replace with:
```lua
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
```

**Step 3: Fix `CombatTracker.lua` line 2527**

Current:
```lua
            local snapshot = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot or nil
```

Replace with:
```lua
            local snapshot = ns.Addon:GetLatestPlayerSnapshot()
```

**Step 4: Syntax-check all three**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\CounterGuideView.lua"
luac -p "D:\Workspace\repos\combat-analytics\UI\MatchupDetailView.lua"
luac -p "D:\Workspace\repos\combat-analytics\CombatTracker.lua"
```

**Step 5: In-game verify**

Log in (or `/reload`) with an active spec. Open the Counters tab, select any spec. The top of the counter guide right panel should now reflect your current build's effectiveness data if you have build vs spec history. No Lua errors.

**Step 6: Commit**

```bash
git add "UI\CounterGuideView.lua" "UI\MatchupDetailView.lua" CombatTracker.lua
git commit -m "fix: replace runtime.playerSnapshot with GetLatestPlayerSnapshot() in 3 consumers"
```

---

## Task 6: Create `UI/ReplayView.lua`

**Files:**
- Create: `UI/ReplayView.lua`

**Background:** A standalone floating frame that renders a session timeline with 4 lanes (offensive casts, defensive casts, CC received, kill windows), a death marker, a time axis, and 3 coaching cards. It is opened externally via `ns.ReplayView:Show(session)`. Does not use CLEU — all data from `session.rawEvents`, `session.ccReceived`, `session.killWindows`.

**Data contract:**
- `session.rawEvents[i]` — `{timestampOffset, eventType, spellId, sourceMine, destMine, isCooldownCast}`
  - Use `eventType == "cast" and sourceMine == true` for offensive lane
  - Use `eventType == "cast" and sourceMine == true and isCooldownCast == true` for defensive lane
  - Use `eventType == "death" and destMine == true` for death marker offset
- `session.ccReceived[i]` — `{spellId, startOffset, duration}` (all session-relative seconds)
- `session.killWindows[i]` — `{openedAt, closedAt, converted}` (all session-relative seconds)
- `session.duration` — total session length in seconds
- `keepRawEvents` defaults to `true` so rawEvents are populated in normal play

**Step 1: Create `UI/ReplayView.lua` with the full implementation**

```lua
local _, ns = ...

local Theme = ns.Widgets.THEME

local ReplayView = {}

-- Layout constants
local FRAME_W     = 760
local FRAME_H     = 440
local CANVAS_W    = 700
local LABEL_W     = 72
local LANE_H      = 26
local LANE_GAP    = 8
local BAR_H       = 16
local DOT_SIZE    = 7
local TICK_COUNT  = 6
local DISPLAY_CAP = 90   -- clamp timeline display to 90 s

local LANE_DEFS = {
    { label = "Offense",    r = 0.40, g = 0.78, b = 1.00, a = 0.90 },
    { label = "Defense",    r = 0.44, g = 0.82, b = 0.60, a = 0.85 },
    { label = "CC In",      r = 0.96, g = 0.40, b = 0.32, a = 0.85 },
    { label = "Kill Win",   r = 0.96, g = 0.74, b = 0.38, a = 0.85 },
}

-- ─── private helpers ─────────────────────────────────────────────────────────

local function laneY(index)
    return 48 + (index - 1) * (LANE_H + LANE_GAP)
end

local function buildToPx(plotW, displayDuration)
    return function(offset)
        return LABEL_W + (math.min(offset, displayDuration) / displayDuration) * plotW
    end
end

-- ─── element pool ────────────────────────────────────────────────────────────

function ReplayView:_clear()
    for _, el in ipairs(self._elements or {}) do
        if el and el.Hide then el:Hide() end
    end
    self._elements = {}
end

function ReplayView:_add(el)
    self._elements[#self._elements + 1] = el
    return el
end

function ReplayView:_dot(x, y, r, g, b, a)
    local t = self.canvas:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT",
        x - math.floor(DOT_SIZE / 2),
        -(y + math.floor((LANE_H - DOT_SIZE) / 2)))
    t:SetSize(DOT_SIZE, DOT_SIZE)
    self:_add(t)
end

function ReplayView:_bar(x1, x2, y, r, g, b, a)
    local w = math.max(3, x2 - x1)
    local t = self.canvas:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT",
        x1,
        -(y + math.floor((LANE_H - BAR_H) / 2)))
    t:SetSize(w, BAR_H)
    self:_add(t)
end

function ReplayView:_label(x, y, text, font, cr, cg, cb, ca)
    local fs = self.canvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", x, -y)
    fs:SetTextColor(cr or unpack(Theme.textMuted))
    fs:SetText(text)
    self:_add(fs)
    return fs
end

-- ─── initialization ───────────────────────────────────────────────────────────

function ReplayView:Initialize()
    self.frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    self.frame:SetSize(FRAME_W, FRAME_H)
    self.frame:SetPoint("CENTER")
    self.frame:SetMovable(true)
    self.frame:EnableMouse(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", self.frame.StartMoving)
    self.frame:SetScript("OnDragStop", self.frame.StopMovingOrSizing)
    self.frame:Hide()
    ns.Widgets.ApplyBackdrop(
        self.frame,
        Theme.background,
        Theme.borderStrong,
        { left = 1, right = 1, top = 1, bottom = 1 }
    )

    -- Header
    self.titleText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.titleText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 16, -14)
    self.titleText:SetTextColor(unpack(Theme.text))

    self.closeBtn = ns.Widgets.CreateButton(self.frame, "Close", 64, 22)
    self.closeBtn:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -10, -12)
    self.closeBtn:SetScript("OnClick", function() self.frame:Hide() end)

    -- Legend strip
    self.legendText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.legendText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 16, -42)
    self.legendText:SetTextColor(unpack(Theme.textMuted))
    self.legendText:SetText(
        "|cff66c8ffOffense|r  "
        .. "|cff70d099Defense|r  "
        .. "|cfff56651CC In|r  "
        .. "|cfff5bd61Kill Window|r  "
        .. "|cffff3333◆ Death|r"
    )

    -- Canvas (timeline drawing area)
    local canvasH = laneY(5) + 28  -- 4 lanes + time axis
    self.canvas = CreateFrame("Frame", nil, self.frame)
    self.canvas:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 20, -58)
    self.canvas:SetSize(CANVAS_W, canvasH)

    -- Coaching cards area
    self.cardArea = CreateFrame("Frame", nil, self.frame)
    self.cardArea:SetPoint("TOPLEFT", self.canvas, "BOTTOMLEFT", 0, -14)
    self.cardArea:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 12)

    self._elements = {}
end

-- ─── rendering ────────────────────────────────────────────────────────────────

function ReplayView:Render(session)
    self:_clear()

    if not session then
        self:_label(8, 0, "No session data.", "GameFontHighlight",
            unpack(Theme.textMuted))
        return
    end

    local duration       = math.max(1, session.duration or 60)
    local displayDuration = math.min(duration, DISPLAY_CAP)
    local plotW          = CANVAS_W - LABEL_W - 4
    local toPx           = buildToPx(plotW, displayDuration)

    -- Session label in title
    local opponentName = ns.Helpers.ResolveOpponentName(session, "Unknown")
    local resultLabel  = string.lower(tostring(session.result or "unknown"))
    self.titleText:SetText(string.format(
        "Replay  —  %s  ·  %s  ·  %s",
        opponentName,
        resultLabel,
        ns.Helpers.FormatDuration(duration)
    ))

    -- Lane backgrounds + labels
    for i, lane in ipairs(LANE_DEFS) do
        local y = laneY(i)
        -- Lane background
        local bg = self.canvas:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.07, 0.09, 0.13, 0.7)
        bg:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", LABEL_W, -y)
        bg:SetSize(plotW, LANE_H)
        self:_add(bg)
        -- Lane label
        self:_label(0, y + 4, lane.label, "GameFontHighlightSmall")
    end

    local rawEvents = session.rawEvents or {}

    -- === Lane 1: Offensive cast dots ===
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[1]
                self:_dot(toPx(off), laneY(1), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- === Lane 2: Defensive cast dots ===
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine and ev.isCooldownCast then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[2]
                self:_dot(toPx(off), laneY(2), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- === Lane 3: CC Received bars ===
    local d3 = LANE_DEFS[3]
    for _, cc in ipairs(session.ccReceived or {}) do
        local start = cc.startOffset or 0
        local dur   = cc.duration or 2
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(start + dur, displayDuration))
            self:_bar(x1, x2, laneY(3), d3.r, d3.g, d3.b, d3.a)
        end
    end

    -- === Lane 4: Kill window bars ===
    local d4 = LANE_DEFS[4]
    for _, kw in ipairs(session.killWindows or {}) do
        local start = kw.openedAt or 0
        local stop  = kw.closedAt or (start + 5)
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(stop, displayDuration))
            -- Converted kill windows glow green
            local r, g, b, a = d4.r, d4.g, d4.b, d4.a
            if kw.converted then r, g, b = 0.44, 0.82, 0.60 end
            self:_bar(x1, x2, laneY(4), r, g, b, a)
        end
    end

    -- === Death marker (vertical red line) ===
    local deathOffset = nil
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "death" and ev.destMine then
            deathOffset = ev.timestampOffset
            break
        end
    end
    if deathOffset and deathOffset <= displayDuration then
        local dx     = toPx(deathOffset)
        local totalH = laneY(4) + LANE_H - laneY(1)
        local marker = self.canvas:CreateTexture(nil, "OVERLAY")
        marker:SetColorTexture(1.0, 0.20, 0.20, 0.88)
        marker:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", dx - 1, -laneY(1))
        marker:SetSize(2, totalH)
        self:_add(marker)
    end

    -- === Time axis ===
    local axisY = laneY(5)
    for i = 0, TICK_COUNT do
        local t  = math.floor(displayDuration * i / TICK_COUNT)
        local px = toPx(t)
        -- Tick mark
        local tick = self.canvas:CreateTexture(nil, "ARTWORK")
        tick:SetColorTexture(0.35, 0.44, 0.55, 0.7)
        tick:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", px, -axisY)
        tick:SetSize(1, 5)
        self:_add(tick)
        -- Label
        self:_label(px - 8, axisY + 7, tostring(t) .. "s")
    end

    -- === Coaching cards ===
    self:_renderCards(session, rawEvents, deathOffset)
end

function ReplayView:_renderCards(session, rawEvents, deathOffset)
    -- Clear card area children by tracking them in _elements
    local cardArea = self.cardArea
    local function addCard(x, title, body)
        local W = 218
        local bg = cardArea:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.08, 0.10, 0.15, 0.85)
        bg:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x, 0)
        bg:SetSize(W, 72)
        self:_add(bg)

        local titleFs = cardArea:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        titleFs:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x + 7, -7)
        titleFs:SetTextColor(unpack(Theme.accent))
        titleFs:SetText(title)
        self:_add(titleFs)

        local bodyFs = cardArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bodyFs:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x + 7, -26)
        bodyFs:SetWidth(W - 14)
        bodyFs:SetTextColor(unpack(Theme.text))
        bodyFs:SetText(body)
        self:_add(bodyFs)
    end

    -- Card 1: Opener
    local openerCount = 0
    local firstSpell  = nil
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine then
            local off = ev.timestampOffset or 0
            if off <= 8 then
                openerCount = openerCount + 1
                if not firstSpell then firstSpell = ev.spellId end
            end
        end
    end
    local openerBody
    if openerCount > 0 then
        openerBody = string.format("%d casts in first 8s", openerCount)
        if firstSpell then
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(firstSpell)
            local name = info and info.name or ("Spell #" .. tostring(firstSpell))
            openerBody = openerBody .. "\nOpener: " .. name
        end
    else
        openerBody = "No cast data (enable raw events)"
    end
    addCard(0, "Opener", openerBody)

    -- Card 2: CC Pressure
    local ccList    = session.ccReceived or {}
    local ccCount   = #ccList
    local ccTotal   = 0
    for _, cc in ipairs(ccList) do ccTotal = ccTotal + (cc.duration or 0) end
    local ccBody = ccCount > 0
        and string.format("%d CC windows\n~%.0fs total under CC", ccCount, ccTotal)
        or "No CC events recorded"
    addCard(226, "CC Pressure", ccBody)

    -- Card 3: Death context
    local deathBody
    if deathOffset then
        local preDeath = 0
        for _, ev in ipairs(rawEvents) do
            if ev.eventType == "cast" and ev.sourceMine
            and (ev.timestampOffset or 0) < deathOffset then
                preDeath = preDeath + 1
            end
        end
        deathBody = string.format("Died at %.0fs\n%d player casts tracked before death",
            deathOffset, preDeath)
    else
        deathBody = "No player death recorded"
    end
    addCard(452, "Death Context", deathBody)
end

-- ─── public API ───────────────────────────────────────────────────────────────

function ReplayView:Show(session)
    if not self.frame then
        self:Initialize()
    end
    self:Render(session)
    self.frame:Show()
    self.frame:Raise()
end

function ReplayView:Hide()
    if self.frame then self.frame:Hide() end
end

ns.ReplayView = ReplayView
```

**Step 2: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\ReplayView.lua"
```

Expected: no output.

**Step 3: Commit (file only — not wired yet)**

```bash
git add "UI\ReplayView.lua"
git commit -m "feat(ui): add ReplayView — session timeline canvas with 4 lanes and coaching cards"
```

---

## Task 7: Wire Replay button and register ReplayView

**Files:**
- Modify: `UI/CombatHistoryView.lua` — add Replay button per row
- Modify: `CombatAnalytics.toc` — add `UI\ReplayView.lua` to load order

**Step 1: Add `UI\ReplayView.lua` to the TOC**

Open `CombatAnalytics.toc`. It currently ends:
```
UI\MatchupDetailView.lua
UI\MainFrame.lua
```

Insert `UI\ReplayView.lua` before `UI\MainFrame.lua`:
```
UI\MatchupDetailView.lua
UI\ReplayView.lua
UI\MainFrame.lua
```

**Step 2: Add Replay buttons to CombatHistoryView**

In `CombatHistoryView:Build`, the row-creation loop runs from lines 93–110. Each row is created with `ns.Widgets.CreateHistoryRow(self.canvas, 750, 58)` and anchored.

Add a `replayButtons` array and create one small button per row. After the loop's closing `end` (line 110), **before** the `ns.Widgets.SetCanvasHeight` call, add:

```lua
    self.replayButtons = {}
    for index = 1, self.rowCount do
        local row = self.rows[index]
        local btn = ns.Widgets.CreateButton(self.canvas, "Replay", 60, 20)
        btn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)
        btn:Hide()
        btn:SetScript("OnClick", function()
            if btn.sessionId then
                local store = ns.Addon:GetModule("CombatStore")
                local session = store and store:GetSessionById(btn.sessionId)
                if session and ns.ReplayView then
                    ns.ReplayView:Show(session)
                end
            end
        end)
        self.replayButtons[index] = btn
    end
```

**Important:** `CombatStore:GetSessionById` may not exist yet. Check with:

```bash
grep -n "GetSessionById" "D:\Workspace\repos\combat-analytics\CombatStore.lua"
```

If it exists, use it. If not, add this minimal helper at the bottom of `CombatStore.lua` (before `ns.Addon:RegisterModule`):

```lua
function CombatStore:GetSessionById(sessionId)
    local db = self:GetDB()
    return db.combats.byId and db.combats.byId[sessionId] or nil
end
```

**Step 3: Update `CombatHistoryView:Refresh` to show/hide Replay buttons**

In the `Refresh` method, inside the `for index = 1, self.rowCount do` loop (around line 153), after `row.sessionId = session.id`, add:

```lua
            -- Replay button
            local rBtn = self.replayButtons and self.replayButtons[index]
            if rBtn then
                rBtn.sessionId = session.id
                rBtn:Show()
            end
```

And in the `else` branch (when `session` is nil, hiding the row), add:
```lua
            local rBtn = self.replayButtons and self.replayButtons[index]
            if rBtn then
                rBtn:Hide()
                rBtn.sessionId = nil
            end
```

**Step 4: Syntax-check both files**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\CombatHistoryView.lua"
luac -p "D:\Workspace\repos\combat-analytics\CombatStore.lua"
```

**Step 5: In-game verify**

```
/reload
/ca
```

Open History tab. Each row should now have a small "Replay" button in the top-right corner. Click one — a floating timeline frame should appear showing 4 lanes. Drag it to move. Click Close to dismiss. No Lua errors.

If rawEvents are empty (old sessions), the lanes will be blank but the frame should still show without errors. The coaching cards will show "No cast data (enable raw events)" / "No CC events recorded" etc.

**Step 6: Commit**

```bash
git add "UI\CombatHistoryView.lua" CombatStore.lua CombatAnalytics.toc
git commit -m "feat(ui): wire Replay button in history view; add ReplayView to TOC"
```

---

## Task 8: Create `UI/BuildComparatorView.lua`

**Files:**
- Create: `UI/BuildComparatorView.lua`

**Background:** A standard tab panel (like other views) that presents two build selectors (cycle with < / > buttons) and a side-by-side metrics table. Uses `GetAggregateBuckets("builds")` for the list and `GetAggregateBucketByKey("builds", hash)` for per-build data. Depends on Task 1 (new helpers in CombatStore).

**Metrics shown:**

| Metric | Source field | Lower is better? |
|---|---|---|
| Record | `wins` / `losses` | neutral |
| Win Rate | `wins / fights` | no |
| Avg Pressure | `totalPressureScore / fights` | no |
| Avg Damage | `totalDamageDone / fights` | no |
| Avg Deaths | `totalDeaths / fights` | yes |
| Avg Dmg Taken | `totalDamageTaken / fights` | yes |

Cells with fewer than 5 fights get a `~` prefix (low-confidence).

**Step 1: Create `UI/BuildComparatorView.lua`**

```lua
local _, ns = ...

local Helpers = ns.Helpers
local Theme   = ns.Widgets.THEME

local BuildComparatorView = {
    viewId  = "builds",
    _indexA = 1,
    _indexB = 2,
    _list   = nil,
    _elems  = {},
}

-- ─── helpers ─────────────────────────────────────────────────────────────────

local function buildLabel(bucket)
    if not bucket then return "(none)" end
    local hash  = string.sub(bucket.key or "unknown", 1, 8)
    local f     = bucket.fights or 0
    return string.format("Build %s  (%dF)", hash, f)
end

local METRIC_DEFS = {
    { label = "Record",       field = "record",   neutral = true  },
    { label = "Win Rate",     field = "winRate",  low = false     },
    { label = "Avg Pressure", field = "pressure", low = false     },
    { label = "Avg Damage",   field = "damage",   low = false     },
    { label = "Avg Deaths",   field = "deaths",   low = true      },
    { label = "Avg Dmg Taken",field = "taken",    low = true      },
}

local function computeMetrics(bucket)
    if not bucket then return nil end
    local f = bucket.fights or 0
    if f == 0 then return nil end
    local prefix = f < 5 and "~" or ""
    local wr  = (bucket.wins or 0) / f
    local pr  = (bucket.totalPressureScore or 0) / f
    local dmg = (bucket.totalDamageDone or 0) / f
    local dt  = (bucket.totalDeaths or 0) / f
    local tk  = (bucket.totalDamageTaken or 0) / f
    return {
        record   = string.format("%s%dW %dL", prefix, bucket.wins or 0, bucket.losses or 0),
        winRate  = string.format("%s%.1f%%", prefix, wr * 100),
        pressure = string.format("%s%.1f", prefix, pr),
        damage   = string.format("%s%s", prefix, Helpers.FormatNumber(dmg)),
        deaths   = string.format("%s%.1f", prefix, dt),
        taken    = string.format("%s%s", prefix, Helpers.FormatNumber(tk)),
        -- raw for comparison
        _wr = wr, _pr = pr, _dmg = dmg, _dt = dt, _tk = tk,
    }
end

local RAW = { winRate="_wr", pressure="_pr", damage="_dmg", deaths="_dt", taken="_tk" }

-- ─── element pool ─────────────────────────────────────────────────────────────

function BuildComparatorView:_clear()
    for _, el in ipairs(self._elems) do
        if el and el.Hide then el:Hide() end
    end
    self._elems = {}
end

function BuildComparatorView:_track(el)
    self._elems[#self._elems + 1] = el
    return el
end

-- ─── Build ────────────────────────────────────────────────────────────────────

function BuildComparatorView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.frame:Hide()

    self.title = ns.Widgets.CreateSectionTitle(
        self.frame, "Build Comparator",
        "TOPLEFT", self.frame, "TOPLEFT", 16, -16)

    self.caption = ns.Widgets.CreateCaption(
        self.frame,
        "Compare talent builds side-by-side using your historical performance data. "
            .. "Values prefixed with ~ have fewer than 5 sessions.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Build A row
    self.labelA = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.labelA:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -18)
    self.labelA:SetTextColor(0.40, 0.78, 1.00, 1.0)   -- blue
    self.labelA:SetText("Build A:")

    self.prevA = ns.Widgets.CreateButton(self.frame, "<", 24, 22)
    self.prevA:SetPoint("LEFT", self.labelA, "RIGHT", 8, 0)
    self.prevA:SetScript("OnClick", function()
        self._indexA = math.max(1, self._indexA - 1)
        self:Refresh()
    end)

    self.nameA = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.nameA:SetPoint("LEFT", self.prevA, "RIGHT", 6, 0)
    self.nameA:SetWidth(240)
    self.nameA:SetJustifyH("LEFT")

    self.nextA = ns.Widgets.CreateButton(self.frame, ">", 24, 22)
    self.nextA:SetPoint("LEFT", self.nameA, "RIGHT", 6, 0)
    self.nextA:SetScript("OnClick", function()
        self._indexA = self._indexA + 1
        self:Refresh()
    end)

    -- Build B row
    self.labelB = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.labelB:SetPoint("TOPLEFT", self.labelA, "BOTTOMLEFT", 0, -10)
    self.labelB:SetTextColor(0.96, 0.74, 0.38, 1.0)   -- amber
    self.labelB:SetText("Build B:")

    self.prevB = ns.Widgets.CreateButton(self.frame, "<", 24, 22)
    self.prevB:SetPoint("LEFT", self.labelB, "RIGHT", 8, 0)
    self.prevB:SetScript("OnClick", function()
        self._indexB = math.max(1, self._indexB - 1)
        self:Refresh()
    end)

    self.nameB = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.nameB:SetPoint("LEFT", self.prevB, "RIGHT", 6, 0)
    self.nameB:SetWidth(240)
    self.nameB:SetJustifyH("LEFT")

    self.nextB = ns.Widgets.CreateButton(self.frame, ">", 24, 22)
    self.nextB:SetPoint("LEFT", self.nameB, "RIGHT", 6, 0)
    self.nextB:SetScript("OnClick", function()
        self._indexB = self._indexB + 1
        self:Refresh()
    end)

    -- Scrollable table canvas
    self.shell, self.scrollFrame, self.canvas =
        ns.Widgets.CreateScrollCanvas(self.frame, 680, 300)
    self.shell:SetPoint("TOPLEFT", self.labelB, "BOTTOMLEFT", 0, -14)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    return self.frame
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

function BuildComparatorView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return end

    -- Prefer per-character build list; fall back to global
    local charKey = store:GetCurrentCharacterKey()
    local list    = store:GetAggregateBuckets("builds", charKey)
    if #list == 0 then
        list = store:GetAggregateBuckets("builds")
    end
    self._list = list

    self:_clear()

    local count = #list

    if count == 0 then
        self.nameA:SetText("(no build history)")
        self.nameB:SetText("(no build history)")
        self.prevA:SetEnabled(false)
        self.nextA:SetEnabled(false)
        self.prevB:SetEnabled(false)
        self.nextB:SetEnabled(false)
        local fs = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -8)
        fs:SetTextColor(unpack(Theme.textMuted))
        fs:SetText("No build history yet. Complete combat sessions to populate this view.")
        self:_track(fs)
        ns.Widgets.SetCanvasHeight(self.canvas, 40)
        return
    end

    self._indexA = Helpers.Clamp(self._indexA, 1, count)
    self._indexB = Helpers.Clamp(self._indexB, 1, count)

    local bucketA = list[self._indexA]
    local bucketB = list[self._indexB]

    self.nameA:SetText(buildLabel(bucketA))
    self.nameB:SetText(buildLabel(bucketB))
    self.prevA:SetEnabled(self._indexA > 1)
    self.nextA:SetEnabled(self._indexA < count)
    self.prevB:SetEnabled(self._indexB > 1)
    self.nextB:SetEnabled(self._indexB < count)

    local mA = computeMetrics(bucketA)
    local mB = computeMetrics(bucketB)

    self:_renderTable(mA, mB)
end

-- ─── table rendering ──────────────────────────────────────────────────────────

function BuildComparatorView:_renderTable(mA, mB)
    local canvas  = self.canvas
    local C0, C1, C2 = 0, 180, 380   -- column x offsets
    local ROW_H   = 24
    local y       = 0

    local function cell(text, x, color)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, -y)
        if color then
            fs:SetTextColor(unpack(color))
        else
            fs:SetTextColor(unpack(Theme.text))
        end
        fs:SetText(text)
        self:_track(fs)
    end

    -- Column headers
    cell("Metric",  C0, Theme.textMuted)
    cell("Build A", C1, { 0.40, 0.78, 1.00, 1.0 })
    cell("Build B", C2, { 0.96, 0.74, 0.38, 1.0 })
    y = y + ROW_H

    -- Separator
    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(580, 1)
    self:_track(sep)
    y = y + 6

    local winsA, winsB = 0, 0

    for rowIdx, m in ipairs(METRIC_DEFS) do
        local valA = mA and mA[m.field] or "—"
        local valB = mB and mB[m.field] or "—"
        local colA = Theme.text
        local colB = Theme.text

        -- Color-code the winning side for non-neutral metrics
        if not m.neutral and mA and mB then
            local rawField = RAW[m.field]
            if rawField then
                local rA = mA[rawField] or 0
                local rB = mB[rawField] or 0
                local aBetter = m.low and (rA < rB) or (rA > rB)
                local bBetter = m.low and (rB < rA) or (rB > rA)
                if aBetter then colA = Theme.success; winsA = winsA + 1
                elseif bBetter then colB = Theme.success; winsB = winsB + 1
                end
            end
        end

        -- Alternating row background
        if rowIdx % 2 == 0 then
            local bg = canvas:CreateTexture(nil, "BACKGROUND")
            bg:SetColorTexture(0.08, 0.10, 0.14, 0.45)
            bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", -4, -y)
            bg:SetSize(588, ROW_H - 2)
            self:_track(bg)
        end

        cell(m.label, C0, Theme.textMuted)
        cell(valA,    C1, colA)
        cell(valB,    C2, colB)
        y = y + ROW_H
    end

    -- Verdict
    y = y + 10
    local sep2 = canvas:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(unpack(Theme.border))
    sep2:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep2:SetSize(580, 1)
    self:_track(sep2)
    y = y + 8

    local totalNonNeutral = 5  -- win rate, pressure, damage, deaths, taken
    local verdict
    if mA and mB then
        if winsA > winsB then
            verdict = string.format(
                "Build A outperforms Build B on %d of %d tracked metrics.",
                winsA, totalNonNeutral)
        elseif winsB > winsA then
            verdict = string.format(
                "Build B outperforms Build A on %d of %d tracked metrics.",
                winsB, totalNonNeutral)
        else
            verdict = "Builds are evenly matched across all tracked metrics."
        end
    else
        verdict = "Insufficient data for one or both builds."
    end

    cell(verdict, 0, Theme.accent)
    y = y + ROW_H

    ns.Widgets.SetCanvasHeight(canvas, y + 16)
end

ns.Addon:RegisterModule("BuildComparatorView", BuildComparatorView)
```

**Step 2: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\BuildComparatorView.lua"
```

**Step 3: Commit**

```bash
git add "UI\BuildComparatorView.lua"
git commit -m "feat(ui): add BuildComparatorView — side-by-side build performance comparison"
```

---

## Task 9: Register Builds tab and add to TOC

**Files:**
- Modify: `UI/MainFrame.lua` — add entry to `tabs` table
- Modify: `CombatAnalytics.toc` — add `UI\BuildComparatorView.lua`

**Step 1: Add the "Builds" tab to `MainFrame.lua`**

Open `UI/MainFrame.lua`. The `tabs` table is at lines 4–16:

```lua
local MainFrame = {
    tabs = {
        { id = "summary",      label = "Summary",  module = "SummaryView" },
        { id = "history",      label = "History",  module = "CombatHistoryView" },
        { id = "detail",       label = "Detail",   module = "CombatDetailView" },
        { id = "opponents",    label = "Opponent", module = "OpponentStatsView" },
        { id = "classspec",    label = "Specs",    module = "ClassSpecView" },
        { id = "matchup",      label = "Matchup",  module = "MatchupDetailView", hidden = true },
        { id = "dummy",        label = "Dummy",    module = "DummyBenchmarkView" },
        { id = "rating",       label = "Rating",   module = "RatingView" },
        { id = "insights",     label = "Insights", module = "SuggestionsView" },
        { id = "counterguide", label = "Counters", module = "CounterGuideView" },
        { id = "cleanup",      label = "Cleanup",  module = "CleanupView" },
    },
}
```

Add the new entry after `"counterguide"` and before `"cleanup"`:

```lua
        { id = "builds",       label = "Builds",   module = "BuildComparatorView" },
```

The full updated list becomes:
```lua
    tabs = {
        { id = "summary",      label = "Summary",  module = "SummaryView" },
        { id = "history",      label = "History",  module = "CombatHistoryView" },
        { id = "detail",       label = "Detail",   module = "CombatDetailView" },
        { id = "opponents",    label = "Opponent", module = "OpponentStatsView" },
        { id = "classspec",    label = "Specs",    module = "ClassSpecView" },
        { id = "matchup",      label = "Matchup",  module = "MatchupDetailView", hidden = true },
        { id = "dummy",        label = "Dummy",    module = "DummyBenchmarkView" },
        { id = "rating",       label = "Rating",   module = "RatingView" },
        { id = "insights",     label = "Insights", module = "SuggestionsView" },
        { id = "counterguide", label = "Counters", module = "CounterGuideView" },
        { id = "builds",       label = "Builds",   module = "BuildComparatorView" },
        { id = "cleanup",      label = "Cleanup",  module = "CleanupView" },
    },
```

**Step 2: Add `UI\BuildComparatorView.lua` to `CombatAnalytics.toc`**

Current end of TOC (with ReplayView already added in Task 7):
```
UI\ReplayView.lua
UI\MainFrame.lua
```

Insert `UI\BuildComparatorView.lua` before `UI\MainFrame.lua`:
```
UI\ReplayView.lua
UI\BuildComparatorView.lua
UI\MainFrame.lua
```

**Step 3: Syntax-check**

```bash
luac -p "D:\Workspace\repos\combat-analytics\UI\MainFrame.lua"
```

**Step 4: In-game verify**

```
/reload
/ca
```

- The tab bar should now show a "Builds" tab between "Counters" and "Cleanup".
- Click "Builds". If you have build history (any prior sessions with playerSnapshot), you should see two build selectors and a comparison table.
- If you have only one build, both selectors will show the same build — that is correct behavior.
- If you have no sessions at all, you should see "No build history yet." without Lua errors.
- Use `<` / `>` buttons to cycle through available builds. The table should update live.
- Verify no Lua errors in the chat frame throughout.

**Step 5: Commit**

```bash
git add "UI\MainFrame.lua" CombatAnalytics.toc
git commit -m "feat(ui): register Builds tab in MainFrame and add BuildComparatorView to TOC"
```

---

## Final Verification Checklist

Run these in-game after all 9 tasks are complete:

1. `/reload` — no Lua errors on load
2. Open Counters tab → select a spec with history → left-panel W/L badges show non-zero numbers
3. Open Counters tab → your build hash is now used for build-personalized effectiveness (no nil errors)
4. Open Insights tab after a session vs a spec you have low win-rate history against → `SPEC_WINRATE_DEFICIT` suggestion appears
5. Open History tab → each row has a "Replay" button → click one → floating timeline appears, drag to move, Close dismisses
6. Timeline lanes: Offense and Defense show dots for sessions with raw events; CC and Kill lanes show bars if those events occurred
7. Open Builds tab → selector shows available builds → comparison table renders → verdict line appears
8. Pre-match advisory (triggered on arena enter after logging in) → no nil errors in trace output (`/ca trace on`)
