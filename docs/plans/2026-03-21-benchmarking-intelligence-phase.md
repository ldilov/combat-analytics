# Benchmarking Intelligence Phase — Implementation Plan

> **For  :** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend CombatAnalytics with defensive economy tracking, kill window detection, comp archetype classification, weighted aggregate metrics, and Battle.net data-fetching scripts to power the full PvP benchmarking model described in the accompanying seed-data design documents.

**Architecture:** New session fields track greed deaths, defensive overlap, burst waste, and kill windows during combat via the existing CLEU pipeline (`HandleNormalizedEvent`) and `ARENA_CROWD_CONTROL_SPELL_UPDATE` (already registered). A new `CompArchetypeClassifier` module classifies enemy teams at finalization. `CombatStore` gains matchup-archetype and build-confidence aggregates plus a weighted win rate helper. Python scripts automate Battle.net API data fetching into Lua seed files.

**Tech Stack:** Lua 5.1 (WoW Midnight 11.2+, Interface 120001), `C_Spell`/`C_PvP` WoW APIs, Python 3.10+ with `requests` for data scripts, Battle.net OAuth2 REST API.

**Hard constraints:**
- Do NOT register or use `COMBAT_LOG_EVENT_UNFILTERED` as a frame event. CLEU data flows exclusively through the existing `HandleCombatLogEvent` → `NormalizeCombatLogEvent` → `HandleNormalizedEvent` pipeline already in `CombatTracker.lua`.
- Runtime-only tracking state (`session._runtime`) must be niled in `FinalizeSession` before SavedVariables persistence.
- All new seed files must be added to `CombatAnalytics.toc` **before** `StaticPvpData.lua`, which assembles the data.
- `Addon:Warn(msg)` takes a **single string**. `Addon:Trace(label, fields)` takes a label string and a **fields table**. Never use two-argument `Warn`.

---

## Task 1: Schema Migration v5 — New Session Fields

**Files:**
- Modify: `Constants.lua`
- Modify: `CombatTracker.lua`
- Modify: `CombatStore.lua`

---

### Step 1 — Bump SCHEMA_VERSION

In `Constants.lua`, change:

```lua
SCHEMA_VERSION = 4,
```

to:

```lua
SCHEMA_VERSION = 5,
```

---

### Step 2 — Extend session creation in CombatTracker.lua

Find the session creation block — the large table literal that contains `survival = { deaths=0, ... }`. Extend the `survival` subtable to include three new counters (v5 additions):

```lua
survival = {
    deaths = 0,
    defensivesUsed = 0,
    unusedDefensives = 0,
    totalAbsorbed = 0,
    selfHealing = 0,
    largestIncomingSpike = 0,
    -- v5: defensive economy
    greedDeaths = 0,           -- deaths where a major defensive was off cooldown
    defensiveOverlapCount = 0, -- times a second major defensive was activated while one was active
    burstWasteCount = 0,       -- major offensive used into an active enemy major defensive
},
```

Add two top-level session fields in the same creation block (alongside `survival`):

```lua
killWindows = {},        -- array of { openedAt, closedAt, healerSlot, converted }
killWindowConversions = 0,
```

Add a runtime-only subtable for transient state. This is **not** part of the schema and will be niled before the session is handed to CombatStore:

```lua
_runtime = {
    enemyActiveDefensives = {},  -- [destGuid] = { [spellId] = true }
    playerActiveDefensives = {}, -- [spellId] = timestampOffset
    killWindowOpen = false,
    killWindowStart = nil,
    killWindowHealerSlot = nil,
},
```

---

### Step 3 — Nil _runtime in FinalizeSession

Near the end of `FinalizeSession`, **before** `CombatStore` receives the session, add:

```lua
-- Runtime-only tracking tables must not persist to SavedVariables.
if session._runtime and session._runtime.killWindowOpen then
    -- Close any window still open at match end.
    session.killWindows[#session.killWindows + 1] = {
        openedAt   = session._runtime.killWindowStart,
        closedAt   = nil,
        healerSlot = session._runtime.killWindowHealerSlot,
        converted  = false,
    }
end
session._runtime = nil
```

---

### Step 4 — Add v4→v5 migration in CombatStore.lua

Find the session migration function — it runs on every session read and is keyed on a schema version integer. It follows the existing pattern (look for `schemaVersion < 4` or similar). Add a new block:

```lua
-- v4 → v5: greed death / defensive economy / kill window fields
if schemaVersion < 5 then
    if session.survival then
        session.survival.greedDeaths          = session.survival.greedDeaths          or 0
        session.survival.defensiveOverlapCount = session.survival.defensiveOverlapCount or 0
        session.survival.burstWasteCount       = session.survival.burstWasteCount       or 0
    end
    session.killWindows          = session.killWindows          or {}
    session.killWindowConversions = session.killWindowConversions or 0
end
```

Also update the guard that sets the session's stored schema version so v5 is recognized as current.

---

### Step 5 — Verify

```
/reload
```

No Lua errors in the trace log. Attack a training dummy to generate a session. Open `/ca` → Detail view. The session should finalize without errors. Verify via console:

```lua
/script local s=ns.Addon:GetModule("CombatTracker").activeSession; if s then print(s.survival.greedDeaths, s.killWindowConversions, s._runtime and "RUNTIME PRESENT" or "_runtime=nil") end
```

During active combat: expect `0  0  RUNTIME PRESENT`.
After finalize (check saved session): expect `_runtime` to be absent.

---

### Step 6 — Commit

```bash
git add Constants.lua CombatTracker.lua CombatStore.lua
git commit -m "feat(schema): v5 migration — greed deaths, defensive overlap, kill windows"
```

---

## Task 2: Extend SeedSpellIntelligence — cooldownSeconds and isPvPTrinket

**Files:**
- Modify: `seed/generated/SeedSpellIntelligence.lua`
- Modify: `StaticPvpData.lua`

The greed death check in Task 4 uses `C_Spell.IsSpellUsable(spellId)` for a live cooldown poll — no `cooldownSeconds` is needed at runtime. However, `cooldownSeconds` is valuable metadata for UI display ("this defensive has a 3-min CD") and for future export/analysis features. Add it now while editing these entries.

---

### Step 1 — Add cooldownSeconds to all isMajorDefensive entries

In `SeedSpellIntelligence.lua`, for every entry where `isMajorDefensive = true`, add a `cooldownSeconds` field. Representative values (fill all entries following this pattern):

```lua
-- Trinket
[42292]  = { category = "defensive", isMajorDefensive = true, isTrinketLike = true,
             breaksCC = true, cooldownSeconds = 120, isPvPTrinket = true, notesTag = "break_cc" },

-- Paladin
[642]    = { category = "defensive", isMajorDefensive = true, isImmunity = true,
             cooldownSeconds = 300, notesTag = "paladin_bubble" },            -- Divine Shield
[1022]   = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 25,  notesTag = "bop" },                       -- Blessing of Protection

-- Warrior
[871]    = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 240, notesTag = "shield_wall" },               -- Shield Wall

-- Rogue
[31224]  = { category = "defensive", isMajorDefensive = true, isImmunity = true,
             cooldownSeconds = 120, notesTag = "cloak" },                     -- Cloak of Shadows
[5277]   = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 90,  notesTag = "evasion" },                   -- Evasion

-- Druid
[22812]  = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 60,  notesTag = "barkskin" },                  -- Barkskin
[61336]  = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "survival_instincts" },        -- Survival Instincts

-- Warlock
[104773] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "unending_resolve" },          -- Unending Resolve

-- Demon Hunter
[196718] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "darkness" },                  -- Darkness

-- Death Knight
[48792]  = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "icebound_fortitude" },        -- Icebound Fortitude

-- Monk
[122278] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 120, notesTag = "dampen_harm" },               -- Dampen Harm
[116849] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 90,  notesTag = "life_cocoon" },               -- Life Cocoon (MW)

-- Priest
[47585]  = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "dispersion" },                -- Dispersion
[33206]  = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 120, notesTag = "pain_suppression" },          -- Pain Suppression

-- Shaman
[108271] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 90,  notesTag = "astral_shift" },              -- Astral Shift

-- Mage
[45438]  = { category = "defensive", isMajorDefensive = true, isImmunity = true,
             cooldownSeconds = 240, notesTag = "ice_block" },                 -- Ice Block

-- Hunter
[186265] = { category = "defensive", isMajorDefensive = true,
             cooldownSeconds = 180, notesTag = "aspect_turtle" },             -- Aspect of the Turtle
```

Add `isPvPTrinket = true` **only** to `[42292]`. Do not add it to any other entry.

---

### Step 2 — Build allSpells index in StaticPvpData.lua

In `StaticPvpData.lua`, after the existing `spellTaxonomy` construction loop (around line 66), add:

```lua
-- O(1) lookup index: any spellId present in spellIntelligence.
-- Avoids iterating all entries for basic "is this a known spell?" queries.
local allSpells = {}
for spellId, info in pairs(spellIntelligence) do
    allSpells[spellId] = info
end
```

Expose it in `ns.StaticPvpData`:

```lua
ns.StaticPvpData = {
    THEME_PRESETS    = themePresets,
    SPELL_TAXONOMY   = spellTaxonomy,
    SPELL_INTELLIGENCE = spellIntelligence,
    ALL_SPELLS       = allSpells,       -- ← add this line
    ...
}
```

Add a convenience accessor after the existing accessor functions:

```lua
function ns.StaticPvpData.GetSpellInfo(spellId)
    return spellId and ns.StaticPvpData.ALL_SPELLS[spellId] or nil
end
```

---

### Step 3 — Verify

```lua
/script print(ns.StaticPvpData.GetSpellInfo(642) ~= nil and "ok" or "MISSING")
-- Expected: ok  (Divine Shield entry exists)

/script local i = ns.StaticPvpData.GetSpellInfo(42292); print(i and i.isPvPTrinket and "trinket ok" or "FAIL")
-- Expected: trinket ok

/script local i = ns.StaticPvpData.GetSpellInfo(871); print(i and i.cooldownSeconds or "MISSING")
-- Expected: 240  (Shield Wall)
```

---

### Step 4 — Commit

```bash
git add seed/generated/SeedSpellIntelligence.lua StaticPvpData.lua
git commit -m "feat(seed): cooldownSeconds/isPvPTrinket on defensives, GetSpellInfo + ALL_SPELLS index"
```

---

## Task 3: New Seed Files — Maps, CompArchetypes, MetricThresholds

**Files:**
- Create: `seed/Maps.lua`
- Create: `seed/CompArchetypes.lua`
- Create: `seed/MetricThresholds.lua`
- Modify: `CombatAnalytics.toc`
- Modify: `StaticPvpData.lua`

---

### Step 1 — Create seed/Maps.lua

```lua
local _, ns = ...

-- Arena and battleground map seed data.
-- mapId = the instanceMapID returned by C_Map / zone context APIs.
-- losRating: 0=open, 1=partial, 2=heavy, 3=pillar-city
-- objectiveType: "elimination" | "flag" | "node" | "cart" | "teamfight"

ns.SeedMaps = ns.SeedMaps or {}

ns.SeedMaps.arenas = {
    [562]  = { name = "Blade's Edge Arena",        losRating = 2, objectiveType = "elimination" },
    [559]  = { name = "Nagrand Arena",              losRating = 1, objectiveType = "elimination" },
    [572]  = { name = "Ruins of Lordaeron",         losRating = 2, objectiveType = "elimination" },
    [617]  = { name = "Dalaran Arena",              losRating = 1, objectiveType = "elimination" },
    [618]  = { name = "Ring of Valor",              losRating = 1, objectiveType = "elimination" },
    [980]  = { name = "Tol'viron Arena",            losRating = 2, objectiveType = "elimination" },
    [1134] = { name = "Tiger's Peak",               losRating = 1, objectiveType = "elimination" },
    [1504] = { name = "Ashamane's Fall",            losRating = 2, objectiveType = "elimination" },
    [1552] = { name = "Mugambala",                  losRating = 2, objectiveType = "elimination" },
    [1911] = { name = "Hook Point",                 losRating = 2, objectiveType = "elimination" },
    [2167] = { name = "The Robodrome",              losRating = 0, objectiveType = "elimination" },
    [2373] = { name = "Empyrean Domain",            losRating = 2, objectiveType = "elimination" },
    [2509] = { name = "Nokhudon Proving Grounds",   losRating = 2, objectiveType = "elimination" },
    [2547] = { name = "Maldraxxus Coliseum",        losRating = 1, objectiveType = "elimination" },
}

ns.SeedMaps.battlegrounds = {
    [30]   = { name = "Alterac Valley",             objectiveType = "teamfight", isBG = true },
    [489]  = { name = "Warsong Gulch",              objectiveType = "flag",      isBG = true },
    [529]  = { name = "Arathi Basin",               objectiveType = "node",      isBG = true },
    [566]  = { name = "Eye of the Storm",           objectiveType = "flag",      isBG = true },
    [628]  = { name = "Isle of Conquest",           objectiveType = "teamfight", isBG = true },
    [726]  = { name = "Twin Peaks",                 objectiveType = "flag",      isBG = true },
    [761]  = { name = "The Battle for Gilneas",     objectiveType = "node",      isBG = true },
    [998]  = { name = "Temple of Kotmogu",          objectiveType = "teamfight", isBG = true },
    [1105] = { name = "Deepwind Gorge",             objectiveType = "node",      isBG = true },
    [1280] = { name = "Seething Shore",             objectiveType = "node",      isBG = true },
    [2118] = { name = "Silvershard Mines",          objectiveType = "cart",      isBG = true },
}
```

---

### Step 2 — Create seed/CompArchetypes.lua

The `CompArchetypeClassifier` module (Task 7) reads this table. Classification iterates `archetypes` in order — **first match wins**, so more specific patterns come first.

```lua
local _, ns = ...

-- Comp archetype classification rules.
-- Order matters: first match wins.
-- Roles used: "melee_dps", "ranged_dps", "healer"
-- Fields:
--   minMelee      (int)  — minimum melee DPS players required
--   minCaster     (int)  — minimum ranged/caster DPS required
--   minAnyDps     (int)  — minimum any DPS (melee or ranged) required
--   requiresHealer (bool) — archetype requires at least one healer
--   dangerProfile  (str)  — "early_burst" | "setup_mid" | "dampening" | "unknown"

ns.SeedCompArchetypes = ns.SeedCompArchetypes or {}

ns.SeedCompArchetypes.archetypes = {
    -- ── 3v3 ─────────────────────────────────────────────────────────────────
    {
        id             = "double_melee_healer",
        label          = "Double Melee Cleave",
        bracket        = "3v3",
        minMelee       = 2,
        requiresHealer = true,
        dangerProfile  = "early_burst",
    },
    {
        id             = "melee_caster_healer",
        label          = "Melee Caster",
        bracket        = "3v3",
        minMelee       = 1,
        minCaster      = 1,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "wizard_cleave",
        label          = "Wizard Cleave",
        bracket        = "3v3",
        minCaster      = 2,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "double_dps_healer",
        label          = "Double DPS + Healer",
        bracket        = "3v3",
        minAnyDps      = 2,
        requiresHealer = true,
        dangerProfile  = "unknown",
    },
    -- ── 2v2 ─────────────────────────────────────────────────────────────────
    {
        id             = "melee_healer",
        label          = "Melee + Healer",
        bracket        = "2v2",
        minMelee       = 1,
        requiresHealer = true,
        dangerProfile  = "early_burst",
    },
    {
        id             = "caster_healer",
        label          = "Caster + Healer",
        bracket        = "2v2",
        minCaster      = 1,
        requiresHealer = true,
        dangerProfile  = "setup_mid",
    },
    {
        id             = "double_dps",
        label          = "Double DPS",
        bracket        = "2v2",
        minAnyDps      = 2,
        requiresHealer = false,
        dangerProfile  = "early_burst",
    },
    -- ── Fallback ─────────────────────────────────────────────────────────────
    {
        id            = "unknown",
        label         = "Unknown Comp",
        dangerProfile = "unknown",
    },
}
```

---

### Step 3 — Create seed/MetricThresholds.lua

```lua
local _, ns = ...

-- Scoring bands for derived PvP metrics.
-- For "rate" metrics (lower = better): excellent < good < weak < critical.
-- For "conversion" metrics (higher = better): critical < weak < good < excellent.
-- Values are the LOWER BOUND of that band (i.e., rate >= value → in this band).

ns.SeedMetricThresholds = ns.SeedMetricThresholds or {}

ns.SeedMetricThresholds.bands = {
    -- Lower is better
    greedDeathRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    defensiveOverlapRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.20,
        critical  = 0.35,
    },
    burstWasteRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    drWasteRate = {
        excellent = 0.00,
        good      = 0.10,
        weak      = 0.25,
        critical  = 0.40,
    },
    -- Higher is better
    killWindowConversionRate = {
        critical  = 0.20,
        weak      = 0.40,
        good      = 0.60,
        excellent = 0.75,
    },
    winRate = {
        critical  = 0.40,
        weak      = 0.48,
        good      = 0.55,
        excellent = 0.65,
    },
}

-- Minimum sample sizes before a metric is considered meaningful.
ns.SeedMetricThresholds.minSamples = {
    build      = 10,  -- matches before build win rate is shown
    matchup    = 5,   -- matches against an archetype before reporting
    weighted   = 30,  -- rolling window size for weighted win rate
    buildFull  = 30,  -- target sample for full build confidence (sampleFactor = 1.0)
}
```

---

### Step 4 — Add new seed files to CombatAnalytics.toc

In `CombatAnalytics.toc`, insert three lines immediately before `StaticPvpData.lua`. The final order around that section must be:

```
seed\generated\SeedDummyCatalog.lua
seed\generated\SeedSpellIntelligence.lua
seed\generated\SeedSpecArchetypes.lua
seed\generated\SeedArenaControl.lua
seed\Maps.lua
seed\CompArchetypes.lua
seed\MetricThresholds.lua
StaticPvpData.lua
```

---

### Step 5 — Wire new seed tables into StaticPvpData.lua

In `StaticPvpData.lua`, after the existing `generated = ns.GeneratedSeedData or {}` line (around line 5), add:

```lua
local seedMaps             = ns.SeedMaps             or {}
local seedCompArchetypes   = ns.SeedCompArchetypes   or {}
local seedMetricThresholds = ns.SeedMetricThresholds or {}
```

Extend the `ns.StaticPvpData` table literal to expose them:

```lua
ns.StaticPvpData = {
    THEME_PRESETS      = themePresets,
    SPELL_TAXONOMY     = spellTaxonomy,
    SPELL_INTELLIGENCE = spellIntelligence,
    ALL_SPELLS         = allSpells,
    INSIGHT_RULES      = { ... },        -- existing
    DUMMY_CATALOG      = dummyCatalog,   -- existing
    SPEC_ARCHETYPES    = specArchetypes, -- existing
    ARENA_CONTROL      = arenaControl,   -- existing
    -- v5 additions
    MAPS               = seedMaps,
    COMP_ARCHETYPES    = seedCompArchetypes,
    METRIC_THRESHOLDS  = seedMetricThresholds,
}
```

Add a map lookup accessor after the existing accessors:

```lua
function ns.StaticPvpData.GetMapInfo(mapId)
    if not mapId then return nil end
    local m = ns.StaticPvpData.MAPS
    return (m.arenas       and m.arenas[mapId])
        or (m.battlegrounds and m.battlegrounds[mapId])
        or nil
end
```

---

### Step 6 — Verify

```lua
/script print(ns.StaticPvpData.GetMapInfo(562) and "maps ok" or "maps nil")
-- Expected: maps ok

/script print(ns.StaticPvpData.COMP_ARCHETYPES.archetypes and "comps ok" or "comps nil")
-- Expected: comps ok

/script print(ns.StaticPvpData.METRIC_THRESHOLDS.bands and "thresholds ok" or "thresholds nil")
-- Expected: thresholds ok
```

---

### Step 7 — Commit

```bash
git add seed/Maps.lua seed/CompArchetypes.lua seed/MetricThresholds.lua CombatAnalytics.toc StaticPvpData.lua
git commit -m "feat(seed): Maps, CompArchetypes, MetricThresholds seed files + StaticPvpData wiring"
```

---

## Task 4: Defensive Economy Tracking in CombatTracker

**Files:**
- Modify: `CombatTracker.lua`

All tracking uses `session._runtime` for transient state and writes to `session.survival.*` counters. CLEU events arrive via `HandleNormalizedEvent` — the `eventRecord` struct is already normalized by `NormalizeCombatLogEvent` before this function is called.

**Key eventRecord fields used:**
- `eventRecord.subEvent` — e.g. `"SPELL_AURA_APPLIED"`, `"SPELL_AURA_REMOVED"`, `"UNIT_DIED"`
- `eventRecord.spellId` — spell ID
- `eventRecord.destGuid` — destination unit GUID
- `eventRecord.destMine` — true if the destination is the player/their pet
- `eventRecord.timestampOffset` — seconds since session start

---

### Step 1 — Enemy defensive state tracking (SPELL_AURA_APPLIED)

In `HandleNormalizedEvent`, in the `SPELL_AURA_APPLIED` handling section, add after any existing aura logic:

```lua
-- Track enemy major defensive auras (for burst-waste detection in HandleUnitSpellcastSucceeded).
if eventRecord.subEvent == "SPELL_AURA_APPLIED" then
    local spellInfo = ns.StaticPvpData.GetSpellInfo(eventRecord.spellId)
    if spellInfo and spellInfo.isMajorDefensive and not eventRecord.destMine then
        local rt = session._runtime
        if rt then
            rt.enemyActiveDefensives[eventRecord.destGuid] =
                rt.enemyActiveDefensives[eventRecord.destGuid] or {}
            rt.enemyActiveDefensives[eventRecord.destGuid][eventRecord.spellId] = true
        end
    end
end
```

In the `SPELL_AURA_REMOVED` section, add:

```lua
-- Clear enemy major defensive aura on expiry.
if eventRecord.subEvent == "SPELL_AURA_REMOVED" then
    local spellInfo = ns.StaticPvpData.GetSpellInfo(eventRecord.spellId)
    if spellInfo and spellInfo.isMajorDefensive and not eventRecord.destMine then
        local rt = session._runtime
        if rt and rt.enemyActiveDefensives[eventRecord.destGuid] then
            rt.enemyActiveDefensives[eventRecord.destGuid][eventRecord.spellId] = nil
        end
    end
end
```

---

### Step 2 — Player defensive overlap tracking (SPELL_AURA_APPLIED / REMOVED)

In the same `SPELL_AURA_APPLIED` block, add player-side overlap detection **after** the enemy tracking block:

```lua
-- Track player major defensive auras for overlap detection.
if eventRecord.subEvent == "SPELL_AURA_APPLIED" then
    local spellInfo = ns.StaticPvpData.GetSpellInfo(eventRecord.spellId)
    if spellInfo and spellInfo.isMajorDefensive and eventRecord.destMine then
        local rt = session._runtime
        if rt then
            -- If another major defensive is already active → overlap event.
            if next(rt.playerActiveDefensives) ~= nil then
                session.survival.defensiveOverlapCount =
                    (session.survival.defensiveOverlapCount or 0) + 1
            end
            rt.playerActiveDefensives[eventRecord.spellId] = eventRecord.timestampOffset
        end
    end
end
```

In the `SPELL_AURA_REMOVED` block:

```lua
if eventRecord.subEvent == "SPELL_AURA_REMOVED" then
    local spellInfo = ns.StaticPvpData.GetSpellInfo(eventRecord.spellId)
    if spellInfo and spellInfo.isMajorDefensive and eventRecord.destMine then
        local rt = session._runtime
        if rt then
            rt.playerActiveDefensives[eventRecord.spellId] = nil
        end
    end
end
```

---

### Step 3 — Greed death tracking (UNIT_DIED)

Find the existing death handling block — where `session.survival.deaths` is incremented when `eventRecord.eventType == "death"` and `eventRecord.destMine`. **Immediately after** the deaths increment, add:

```lua
-- Greed death check: did the player have any major defensive available?
-- C_Spell.IsSpellUsable returns (isUsable, notEnoughPower) or nil for unknown spells.
-- A non-nil truthy first return = spell is known and off cooldown right now.
local spellIntel = ns.StaticPvpData.SPELL_INTELLIGENCE
if spellIntel then
    for spellId, info in pairs(spellIntel) do
        if info.isMajorDefensive then
            local isUsable = C_Spell.IsSpellUsable(spellId)
            if isUsable then
                session.survival.greedDeaths =
                    (session.survival.greedDeaths or 0) + 1
                break  -- one greed flag per death is sufficient
            end
        end
    end
end
```

---

### Step 4 — Burst waste tracking (HandleUnitSpellcastSucceeded)

`HandleUnitSpellcastSucceeded` is already called for `UNIT_SPELLCAST_SUCCEEDED` events. It receives `(self, unit, castGUID, spellId)` or similar. Find the existing player spellcast branch (likely `if unit == "player" then`).

Inside that branch, add after any existing major offensive tracking:

```lua
-- Burst waste: major offensive used while primary enemy's major defensive is active.
local spellInfo = ns.StaticPvpData.GetSpellInfo(spellId)
if spellInfo and spellInfo.isMajorOffensive and session and session._runtime then
    local primary = session.primaryOpponent
    local rt      = session._runtime
    if primary and primary.guid then
        local enemyDefs = rt.enemyActiveDefensives[primary.guid]
        if enemyDefs and next(enemyDefs) ~= nil then
            session.survival.burstWasteCount =
                (session.survival.burstWasteCount or 0) + 1
        end
    end
end
```

---

### Step 5 — Reload and smoke test

```
/reload
```

In a duel or arena:
- Pop a defensive, immediately pop a second → `survival.defensiveOverlapCount` increments.
- Die without using a defensive that was available → `survival.greedDeaths` increments.
- Use a major offensive while the enemy is immune (e.g. vs Ice Block) → `survival.burstWasteCount` increments.

Console verification during an active session:

```lua
/script local s=ns.Addon:GetModule("CombatTracker").activeSession; if s then print(s.survival.greedDeaths, s.survival.defensiveOverlapCount, s.survival.burstWasteCount) end
```

---

### Step 6 — Commit

```bash
git add CombatTracker.lua
git commit -m "feat(tracker): defensive economy — greed deaths, overlap, burst waste tracking"
```

---

## Task 5: Kill Window Tracking

**Files:**
- Modify: `CombatTracker.lua`

Kill windows open when an enemy **healer** is CCed (via `ARENA_CROWD_CONTROL_SPELL_UPDATE`) and close when the CC ends or an enemy dies. `HandleArenaCrowdControlUpdate` is already mapped in `Events.lua`'s `TRACKER_EVENT_MAP` and the event is already registered.

---

### Step 1 — Implement HandleArenaCrowdControlUpdate

Find `HandleArenaCrowdControlUpdate` in `CombatTracker.lua` (it likely has a stub or empty body). Replace or implement it:

```lua
function CombatTracker:HandleArenaCrowdControlUpdate(unitToken)
    local session = self.activeSession
    if not session or not session._runtime then return end

    -- Only track enemy arena slots (arena1..arena5).
    if not unitToken or not unitToken:match("^arena%d$") then return end

    -- Determine if this arena slot is a healer.
    local slotIndex = tonumber(unitToken:match("%d"))
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    local roster = art and art.GetCurrentRoster and art:GetCurrentRoster()
    local slotData = roster and roster[slotIndex]
    local specArchetype = slotData and slotData.specId
        and ns.StaticPvpData.GetSpecArchetype(slotData.specId)
    if not specArchetype or specArchetype.role ~= "healer" then return end

    -- Read current CC state for this unit.
    local ccInfo = C_PvP.GetArenaCrowdControlInfo
        and C_PvP.GetArenaCrowdControlInfo(unitToken)

    local rt  = session._runtime
    local now = GetTime() - (session.startTime or GetTime())  -- session-relative offset

    local isInCC = ccInfo and ccInfo.duration and ccInfo.duration > 0

    if isInCC then
        -- Open a kill window if not already open.
        if not rt.killWindowOpen then
            rt.killWindowOpen       = true
            rt.killWindowStart      = now
            rt.killWindowHealerSlot = slotIndex
        end
    else
        -- CC ended: close the kill window.
        if rt.killWindowOpen then
            session.killWindows[#session.killWindows + 1] = {
                openedAt   = rt.killWindowStart,
                closedAt   = now,
                healerSlot = rt.killWindowHealerSlot,
                converted  = false,
            }
            rt.killWindowOpen       = false
            rt.killWindowStart      = nil
            rt.killWindowHealerSlot = nil
        end
    end
end
```

**Note on `ArenaRoundTracker:GetCurrentRoster`:** Check whether this method exists; if not, use whatever accessor the module exposes for the current roster (e.g. `art.roster` or `art:GetRoster()`). Do not add the method if it is not already there — adapt the call site to the existing API.

---

### Step 2 — Mark conversions on enemy death

In the `UNIT_DIED` handling block (the same block modified in Task 4), add a section for **enemy** deaths (not `destMine`):

```lua
-- Kill window conversion: an enemy died while a kill window was open.
if eventRecord.eventType == "death" and not eventRecord.destMine then
    local rt = session and session._runtime
    if rt and rt.killWindowOpen then
        session.killWindows[#session.killWindows + 1] = {
            openedAt   = rt.killWindowStart,
            closedAt   = eventRecord.timestampOffset,
            healerSlot = rt.killWindowHealerSlot,
            converted  = true,
        }
        session.killWindowConversions = (session.killWindowConversions or 0) + 1
        rt.killWindowOpen       = false
        rt.killWindowStart      = nil
        rt.killWindowHealerSlot = nil
    end
end
```

---

### Step 3 — Verify open window is closed in FinalizeSession

The unclosed-window handling was already added to `FinalizeSession` in Task 1, Step 3. Confirm it is present:

```lua
-- Close any kill window still open at match end.
local rt = session._runtime
if rt and rt.killWindowOpen then
    session.killWindows[#session.killWindows + 1] = {
        openedAt   = rt.killWindowStart,
        closedAt   = nil,
        healerSlot = rt.killWindowHealerSlot,
        converted  = false,
    }
end
session._runtime = nil
```

---

### Step 4 — Verify

In a rated 3v3 arena against an enemy healer:
- CC the healer and land a kill during the CC → `session.killWindowConversions` should be 1 after the match.
- CC the healer but fail to land a kill before CC breaks → a window record with `converted = false` appears.

Console check after match:

```lua
/script local db=CombatAnalyticsDB; local s=db.sessions[#db.sessions]; print(s.killWindowConversions, #s.killWindows)
```

---

### Step 5 — Commit

```bash
git add CombatTracker.lua
git commit -m "feat(tracker): kill window tracking via ARENA_CROWD_CONTROL_SPELL_UPDATE"
```

---

## Task 6: New Derived Metrics in Utils/Metrics.lua

**Files:**
- Modify: `Utils/Metrics.lua`

`ComputeDerivedMetrics(session)` is the existing entry point. It already computes `ccDRState` via `computeCCDRState`. All new metrics are appended to the `derived` table it returns.

---

### Step 1 — Add greedDeathRate and defensiveOverlapRate

In `ComputeDerivedMetrics`, after the existing survivability score calculation, add:

```lua
-- Greed death rate: proportion of deaths where a major defensive was available.
local greedDeaths      = (session.survival and session.survival.greedDeaths) or 0
local totalDeaths      = (session.survival and session.survival.deaths)      or 0
derived.greedDeathRate = totalDeaths > 0 and (greedDeaths / totalDeaths) or 0

-- Defensive overlap rate: overlapping defensive trades / total defensive uses.
local overlapCount          = (session.survival and session.survival.defensiveOverlapCount) or 0
local defensivesUsed        = (session.survival and session.survival.defensivesUsed)        or 0
derived.defensiveOverlapRate = defensivesUsed > 0 and (overlapCount / defensivesUsed) or 0
```

---

### Step 2 — Add burstWasteRate

```lua
-- Burst waste rate: major offensive uses wasted into active enemy defensives.
local burstWasteCount    = (session.survival and session.survival.burstWasteCount) or 0
local majorOffCount      = derived.majorOffensiveCount or 0
derived.burstWasteRate   = majorOffCount > 0 and (burstWasteCount / majorOffCount) or 0
```

---

### Step 3 — Add killWindowConversionRate

```lua
-- Kill window conversion rate.
local totalWindows               = session.killWindows and #session.killWindows or 0
local converted                  = session.killWindowConversions or 0
derived.killWindowConversionRate = totalWindows > 0 and (converted / totalWindows) or 0
derived.killWindowCount          = totalWindows
```

---

### Step 4 — Add drWasteRate

The existing `computeCCDRState` returns a table keyed by family; each family has `.applications` (total applications) and `.immuneAt` (the application index at which immunity was reached, or nil). An immune application = a wasted CC.

Add after `ccDRState` is computed:

```lua
-- DR waste rate: immune-tier CC applications / total CC applications.
local drWasteCount       = 0
local drTotalApplications = 0
local ccDRState = derived.ccDRState or {}
for _, familyState in pairs(ccDRState) do
    local apps = familyState.applications or 0
    drTotalApplications = drTotalApplications + apps
    -- immuneAt is set to the index of the first immune application (every application
    -- at and after that index is wasted).
    if familyState.immuneAt then
        drWasteCount = drWasteCount + (apps - familyState.immuneAt + 1)
    end
end
derived.drWasteCount = drWasteCount
derived.drWasteRate  = drTotalApplications > 0
    and (drWasteCount / drTotalApplications) or 0
```

---

### Step 5 — Verify

Attack a training dummy, use a defensive twice (overlap), then check:

```lua
/script local s=ns.Addon:GetModule("CombatTracker").activeSession; if s then local d=ns.Metrics.ComputeDerivedMetrics(s); print(d.greedDeathRate, d.defensiveOverlapRate, d.burstWasteRate, d.killWindowConversionRate, d.drWasteRate) end
```

Expected: five numeric values (all 0.0 on a dummy, which is correct — no deaths, no windows).

---

### Step 6 — Commit

```bash
git add Utils/Metrics.lua
git commit -m "feat(metrics): greedDeathRate, defensiveOverlapRate, burstWasteRate, killWindowConversionRate, drWasteRate"
```

---

## Task 7: CompArchetypeClassifier Module

**Files:**
- Create: `CompArchetypeClassifier.lua`
- Modify: `CombatAnalytics.toc`
- Modify: `CombatTracker.lua`

---

### Step 1 — Create CompArchetypeClassifier.lua

```lua
local _, ns = ...

-- CompArchetypeClassifier
-- Classifies the enemy team's comp archetype from a list of known spec IDs.
-- Called in FinalizeSession. Writes to session.arena.compArchetype.

local Classifier = {}

-- Maps the role string from SeedSpecArchetypes to a simplified role key.
local function getSpecRole(specId)
    local archetype = ns.StaticPvpData.GetSpecArchetype(specId)
    if not archetype then return "unknown" end
    local role = archetype.role
    if role == "melee"  then return "melee_dps"  end
    if role == "ranged" then return "ranged_dps" end
    if role == "healer" then return "healer"     end
    if role == "tank"   then return "tank"       end
    return "unknown"
end

-- Classify an enemy team from an array of specId integers.
-- Returns an archetype id string (e.g. "double_melee_healer") or "unknown".
function Classifier.ClassifyComp(specIds)
    if not specIds or #specIds == 0 then return "unknown" end

    local meleeDps  = 0
    local casterDps = 0
    local anyDps    = 0
    local healers   = 0
    local totalKnown = 0

    for _, specId in ipairs(specIds) do
        if specId and specId > 0 then
            local role = getSpecRole(specId)
            totalKnown = totalKnown + 1
            if role == "melee_dps"  then meleeDps  = meleeDps  + 1; anyDps = anyDps + 1 end
            if role == "ranged_dps" then casterDps = casterDps + 1; anyDps = anyDps + 1 end
            if role == "healer"     then healers   = healers   + 1 end
        end
    end

    if totalKnown == 0 then return "unknown" end

    local archetypes = ns.StaticPvpData.COMP_ARCHETYPES
    if not archetypes or not archetypes.archetypes then return "unknown" end

    for _, arch in ipairs(archetypes.archetypes) do
        local match = true
        if arch.minMelee      and meleeDps  < arch.minMelee    then match = false end
        if arch.minCaster     and casterDps < arch.minCaster   then match = false end
        if arch.minAnyDps     and anyDps    < arch.minAnyDps   then match = false end
        if arch.requiresHealer and healers  < 1                then match = false end
        if match then return arch.id end
    end

    return "unknown"
end

ns.CompArchetypeClassifier = Classifier
```

---

### Step 2 — Add to CombatAnalytics.toc

In `CombatAnalytics.toc`, add one line immediately **before** `CombatTracker.lua`:

```
ArenaRoundTracker.lua
SpellAttributionPipeline.lua
CompArchetypeClassifier.lua
CombatTracker.lua
```

---

### Step 3 — Call classifier in FinalizeSession

In `CombatTracker.lua`, in `FinalizeSession`, after the arena `opposingTeam` is populated and **before** `session._runtime = nil`, add:

```lua
-- Classify enemy comp archetype from opposing team spec IDs.
if session.arena and session.arena.opposingTeam then
    local specIds = {}
    for _, member in ipairs(session.arena.opposingTeam) do
        specIds[#specIds + 1] = member.specId
    end
    local classifier = ns.CompArchetypeClassifier
    if classifier then
        session.arena.compArchetype = classifier.ClassifyComp(specIds)
    end
end
```

---

### Step 4 — Verify

Queue and complete a rated 3v3 arena. After the match:

```lua
/script local db=CombatAnalyticsDB; local s=db.sessions[#db.sessions]; print(s.arena and s.arena.compArchetype or "nil")
```

Expected: a non-`nil` string such as `"double_melee_healer"` or `"wizard_cleave"`.
If all enemy specs were detected: not `"unknown"`.

---

### Step 5 — Commit

```bash
git add CompArchetypeClassifier.lua CombatAnalytics.toc CombatTracker.lua
git commit -m "feat(classifier): CompArchetypeClassifier — enemy comp archetype at finalization"
```

---

## Task 8: New Aggregate Buckets in CombatStore

**Files:**
- Modify: `CombatStore.lua`

Three additions:
1. `matchupArchetypes` aggregate bucket (per enemy comp archetype stats)
2. Build confidence score on the existing build aggregate
3. Weighted win rate helper (lazy computation from session list)

---

### Step 1 — Initialize matchupArchetypes aggregate

Find the db defaults initialization block (where `db.aggregates.opponents`, `db.aggregates.builds`, etc. are defaulted with `or {}`). Add:

```lua
db.aggregates.matchupArchetypes = db.aggregates.matchupArchetypes or {}
```

---

### Step 2 — Apply session to matchupArchetypes bucket

In `applySessionToBucket` (or equivalent function that processes a finalized session into aggregates), add:

```lua
-- Matchup archetype aggregate
local compArchetype = session.arena and session.arena.compArchetype
if compArchetype and compArchetype ~= "unknown" then
    local agg = db.aggregates.matchupArchetypes
    if not agg[compArchetype] then
        agg[compArchetype] = {
            archetype                  = compArchetype,
            fights                     = 0,
            wins                       = 0,
            losses                     = 0,
            totalGreedDeaths           = 0,
            totalBurstWaste            = 0,
            totalKillWindows           = 0,
            totalKillWindowConversions = 0,
        }
    end
    local bucket = agg[compArchetype]
    bucket.fights  = bucket.fights  + 1
    if session.result == Constants.MATCH_RESULT.WIN then
        bucket.wins    = bucket.wins   + 1
    elseif session.result == Constants.MATCH_RESULT.LOSS then
        bucket.losses  = bucket.losses + 1
    end
    bucket.totalGreedDeaths           = bucket.totalGreedDeaths
        + ((session.survival and session.survival.greedDeaths) or 0)
    bucket.totalBurstWaste            = bucket.totalBurstWaste
        + ((session.survival and session.survival.burstWasteCount) or 0)
    bucket.totalKillWindows           = bucket.totalKillWindows
        + (session.killWindows and #session.killWindows or 0)
    bucket.totalKillWindowConversions = bucket.totalKillWindowConversions
        + (session.killWindowConversions or 0)
end
```

---

### Step 3 — Add build confidence score to build aggregate

In the build aggregate update section, after `bucket.wins` and `bucket.fights` are updated, add:

```lua
-- Build confidence score: sample-size-corrected win rate.
-- Formula: min(1.0, fights / targetSample) * winRate
-- Prevents a 5-for-5 build from outranking a stable 60% build with 80 games.
local thresholds = ns.StaticPvpData and ns.StaticPvpData.METRIC_THRESHOLDS
local targetSample = (thresholds and thresholds.minSamples and thresholds.minSamples.buildFull)
    or 30
local winRate     = bucket.fights > 0 and (bucket.wins / bucket.fights) or 0
local sampleFactor = math.min(1.0, bucket.fights / targetSample)
bucket.confidenceScore = sampleFactor * winRate
```

---

### Step 4 — Add weighted win rate helper

Add a module-level helper function (not method, just a local-turned-exported function):

```lua
-- ComputeWeightedWinRate
-- Computes an exponentially decay-weighted win rate over the most recent
-- `windowSize` matches that satisfy `filterFn` (optional).
-- Newest match has weight 1.0; each older match is multiplied by `decay`.
-- Returns: weightedWinRate (0-1), sampleCount (int)
local function ComputeWeightedWinRate(sessions, filterFn, windowSize, decay)
    windowSize = windowSize or 30
    decay      = decay      or 0.9

    -- Collect matching sessions, newest first.
    local matching = {}
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if not filterFn or filterFn(s) then
            matching[#matching + 1] = s
            if #matching >= windowSize then break end
        end
    end

    if #matching == 0 then return 0, 0 end

    local weightedSum = 0
    local totalWeight = 0
    for i, s in ipairs(matching) do
        local weight = decay ^ (i - 1)   -- i=1 is newest → weight=1.0
        local result = (s.result == Constants.MATCH_RESULT.WIN) and 1 or 0
        weightedSum = weightedSum + result * weight
        totalWeight = totalWeight + weight
    end

    return weightedSum / totalWeight, #matching
end
```

Expose it on the `CombatStore` module and add two convenience accessors:

```lua
ns.CombatStore.ComputeWeightedWinRate = ComputeWeightedWinRate

function ns.CombatStore.GetOverallWeightedWinRate()
    local sessions = ns.CombatStore.GetAllSessions()
    return ComputeWeightedWinRate(sessions, nil, 30, 0.9)
end

function ns.CombatStore.GetBuildWeightedWinRate(buildHash)
    local sessions = ns.CombatStore.GetAllSessions()
    return ComputeWeightedWinRate(sessions, function(s)
        return s.playerSnapshot and s.playerSnapshot.buildHash == buildHash
    end, 30, 0.9)
end
```

**Note:** `GetAllSessions` must already exist on `CombatStore`. If the actual method name is different (e.g. `GetSessions`, `GetSessionList`), adapt the call to match the existing API. Do not add a new method to CombatStore just to satisfy this call.

---

### Step 5 — Verify

After some test sessions:

```lua
/script local r, n = ns.Addon:GetModule("CombatStore"):GetOverallWeightedWinRate(); print(r, n)
-- Expected: a float between 0 and 1, plus a sample count integer

/script local agg = CombatAnalyticsDB.aggregates.matchupArchetypes; for k,v in pairs(agg) do print(k, v.fights) end
-- Expected: archetype names with fight counts (if arenas were played)
```

**Note:** `GetOverallWeightedWinRate` and `GetBuildWeightedWinRate` are implemented as methods (colon syntax), consistent with the rest of CombatStore's API. Calling with dot syntax (`ns.CombatStore.GetOverallWeightedWinRate()`) would fail because `self` would be nil.

---

### Step 6 — Commit

```bash
git add CombatStore.lua
git commit -m "feat(store): matchup archetype aggregate, build confidence score, weighted win rate"
```

---

## Task 9: Data Fetching Scripts — Battle.net API

**Files:**
- Create: `scripts/fetch_blizzard_data.py`
- Create: `scripts/generate_seed_from_api.py`
- Create: `scripts/requirements.txt`
- Create: `scripts/README.md`

These scripts are **developer tools only** — they are never loaded by WoW. They fetch official spec/talent data and generate Lua seed files. Raw JSON responses are committed to the repo so the Lua generator can be re-run offline.

---

### Step 1 — Create scripts/requirements.txt

```
requests>=2.31.0
```

---

### Step 2 — Create scripts/fetch_blizzard_data.py

```python
#!/usr/bin/env python3
"""
fetch_blizzard_data.py

Fetch playable-class, specialization, and PvP talent data from the
Battle.net Game Data API using OAuth2 client credentials.

Setup:
    Register an app at https://develop.battle.net/access
    export BNET_CLIENT_ID=your_client_id
    export BNET_CLIENT_SECRET=your_client_secret

Usage:
    python scripts/fetch_blizzard_data.py --region us --output data/raw/
"""

import os
import sys
import json
import argparse
import requests

OAUTH_URL = "https://oauth.battle.net/token"
API_BASE  = "https://{region}.api.blizzard.com"
NAMESPACE = "static-{region}"


def get_token(client_id: str, client_secret: str) -> str:
    resp = requests.post(
        OAUTH_URL,
        data={"grant_type": "client_credentials"},
        auth=(client_id, client_secret),
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def api_get(session: requests.Session, url: str, params: dict) -> dict:
    resp = session.get(url, params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch Battle.net API data for CombatAnalytics seed generation"
    )
    parser.add_argument("--region", default="us", choices=["us", "eu", "kr", "tw"])
    parser.add_argument("--output", default="data/raw/")
    args = parser.parse_args()

    client_id     = os.environ.get("BNET_CLIENT_ID")
    client_secret = os.environ.get("BNET_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("ERROR: BNET_CLIENT_ID and BNET_CLIENT_SECRET env vars are required.",
              file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    print("Acquiring OAuth2 token...")
    token = get_token(client_id, client_secret)

    http = requests.Session()
    http.headers["Authorization"] = f"Bearer {token}"

    base   = API_BASE.format(region=args.region)
    ns     = NAMESPACE.format(region=args.region)
    locale = "en_US"
    params = {"namespace": ns, "locale": locale}

    # ── Classes ──────────────────────────────────────────────────────────────
    print("Fetching playable classes...")
    index = api_get(http, f"{base}/data/wow/playable-class/index", params)
    classes = {}
    for cls in index.get("classes", []):
        detail = api_get(http, cls["key"]["href"], {"locale": locale})
        classes[cls["id"]] = detail
    out_path = os.path.join(args.output, "classes.json")
    with open(out_path, "w") as f:
        json.dump(classes, f, indent=2)
    print(f"  Saved {len(classes)} classes → {out_path}")

    # ── Specializations ───────────────────────────────────────────────────────
    print("Fetching specializations...")
    index = api_get(http, f"{base}/data/wow/playable-specialization/index", params)
    specs = {}
    for spec in index.get("character_specializations", []):
        detail = api_get(http, spec["key"]["href"], {"locale": locale})
        specs[spec["id"]] = detail
    out_path = os.path.join(args.output, "specs.json")
    with open(out_path, "w") as f:
        json.dump(specs, f, indent=2)
    print(f"  Saved {len(specs)} specs → {out_path}")

    # ── PvP Talents ───────────────────────────────────────────────────────────
    print("Fetching PvP talents...")
    index = api_get(http, f"{base}/data/wow/pvp-talent/index", params)
    pvp_talents = {}
    for talent in index.get("pvp_talents", []):
        detail = api_get(http, talent["key"]["href"], {"locale": locale})
        pvp_talents[talent["id"]] = detail
    out_path = os.path.join(args.output, "pvp_talents.json")
    with open(out_path, "w") as f:
        json.dump(pvp_talents, f, indent=2)
    print(f"  Saved {len(pvp_talents)} PvP talents → {out_path}")

    print(f"\nAll raw data saved to: {args.output}")


if __name__ == "__main__":
    main()
```

---

### Step 3 — Create scripts/generate_seed_from_api.py

```python
#!/usr/bin/env python3
"""
generate_seed_from_api.py

Convert raw Battle.net JSON data (from fetch_blizzard_data.py) into Lua
seed files for CombatAnalytics.

Usage:
    python scripts/generate_seed_from_api.py --input data/raw/ --output seed/generated/

Outputs:
    seed/generated/SeedSpecArchetypes.lua   — regenerated from API spec data
    seed/generated/SeedPvpTalentCatalog.lua — full PvP talent list by spec
"""

import os
import json
import argparse

# Spec IDs that are primarily melee DPS in PvP context.
# Used to override the generic API "DAMAGE" role type.
MELEE_SPEC_IDS = {
    71, 72, 73,       # Warrior (Arms, Fury, Protection)
    66, 70,           # Paladin (Protection, Retribution)
    250, 251, 252,    # Death Knight (Blood, Frost, Unholy)
    577, 581,         # Demon Hunter (Havoc, Vengeance)
    103, 104, 105,    # Druid (Feral, Guardian — Balance/Resto handled by API role)
    254, 255,         # Hunter (Beast Mastery, Survival)
    259, 260, 261,    # Rogue (Assassination, Outlaw, Subtlety)
    263,              # Shaman (Enhancement)
    268, 270,         # Monk (Brewmaster, Windwalker)
    72,               # Warrior Fury (duplicate safe — sets are deduped)
}


def spec_role(spec_id: int, api_role_type: str) -> str:
    if api_role_type == "TANK":   return "tank"
    if api_role_type == "HEALER": return "healer"
    if spec_id in MELEE_SPEC_IDS: return "melee"
    return "ranged"


def generate_spec_archetypes(specs: dict, classes: dict, output_path: str) -> None:
    lines = [
        "local _, ns = ...",
        "ns.GeneratedSeedData = ns.GeneratedSeedData or {}",
        "",
        "-- Auto-generated by scripts/generate_seed_from_api.py",
        "-- Source: Battle.net Playable Specialization API",
        "-- DO NOT EDIT MANUALLY — re-run the script to regenerate.",
        "",
        "ns.GeneratedSeedData.specArchetypes = {",
    ]

    for spec_id_str, spec in sorted(specs.items(), key=lambda kv: int(kv[0])):
        spec_id    = int(spec_id_str)
        name       = spec.get("name", {}).get("en_US", "Unknown")
        api_role   = spec.get("role", {}).get("type", "DAMAGE")
        class_id   = spec.get("playable_class", {}).get("id", 0)
        class_data = classes.get(str(class_id), {})
        class_name = class_data.get("name", {}).get("en_US", "Unknown")
        role       = spec_role(spec_id, api_role)

        lines.append(
            f"    [{spec_id:6}] = {{"
            f" specId = {spec_id:6},"
            f" name = {json.dumps(name):<40},"
            f" class = {json.dumps(class_name):<22},"
            f" classId = {class_id:3},"
            f" role = {json.dumps(role):<12} }},"
        )

    lines += ["}", ""]
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  Written: {output_path}")


def generate_pvp_talent_catalog(pvp_talents: dict, output_path: str) -> None:
    lines = [
        "local _, ns = ...",
        "ns.GeneratedSeedData = ns.GeneratedSeedData or {}",
        "",
        "-- Auto-generated by scripts/generate_seed_from_api.py",
        "-- Source: Battle.net PvP Talent API",
        "-- DO NOT EDIT MANUALLY — re-run the script to regenerate.",
        "",
        "ns.GeneratedSeedData.pvpTalentCatalog = {",
    ]

    for talent_id_str, talent in sorted(pvp_talents.items(), key=lambda kv: int(kv[0])):
        talent_id = int(talent_id_str)
        name      = talent.get("name", {}).get("en_US", "Unknown")
        spec_id   = talent.get("playable_specialization", {}).get("id", 0)
        spell_id  = talent.get("spell", {}).get("id", 0)

        lines.append(
            f"    [{talent_id:6}] = {{"
            f" name = {json.dumps(name):<45},"
            f" specId = {spec_id:6},"
            f" spellId = {spell_id:8} }},"
        )

    lines += ["}", ""]
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  Written: {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate Lua seed files from fetched Battle.net API JSON"
    )
    parser.add_argument("--input",  default="data/raw/")
    parser.add_argument("--output", default="seed/generated/")
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)

    specs      = json.load(open(os.path.join(args.input, "specs.json")))
    classes    = json.load(open(os.path.join(args.input, "classes.json")))
    pvp_talents = json.load(open(os.path.join(args.input, "pvp_talents.json")))

    print("Generating SeedSpecArchetypes.lua ...")
    generate_spec_archetypes(
        specs, classes,
        os.path.join(args.output, "SeedSpecArchetypes.lua")
    )

    print("Generating SeedPvpTalentCatalog.lua ...")
    generate_pvp_talent_catalog(
        pvp_talents,
        os.path.join(args.output, "SeedPvpTalentCatalog.lua")
    )

    print("Done.")


if __name__ == "__main__":
    main()
```

---

### Step 4 — Create scripts/README.md

````markdown
# CombatAnalytics Data Scripts

Developer tools for refreshing seed data from the official Battle.net Game Data API.
The raw JSON outputs are committed to the repo so the Lua generator can be re-run
without needing API credentials (useful for CI or offline environments).

## Prerequisites

```bash
pip install -r scripts/requirements.txt
```

Register a Battle.net developer app at https://develop.battle.net/access to obtain
a Client ID and Client Secret.

## Workflow

### Step 1: Fetch raw API data

```bash
export BNET_CLIENT_ID=your_client_id
export BNET_CLIENT_SECRET=your_client_secret
python scripts/fetch_blizzard_data.py --region us --output data/raw/
```

Fetches:
- `data/raw/classes.json`     — playable class index + details
- `data/raw/specs.json`       — specialization index + details
- `data/raw/pvp_talents.json` — PvP talent index + details

### Step 2: Generate Lua seed files

```bash
python scripts/generate_seed_from_api.py --input data/raw/ --output seed/generated/
```

Generates:
- `seed/generated/SeedSpecArchetypes.lua`   — replaces the existing file
- `seed/generated/SeedPvpTalentCatalog.lua` — new file (add to TOC if not already present)

### Step 3: Add new generated files to TOC (first time only)

If `SeedPvpTalentCatalog.lua` is new, add it to `CombatAnalytics.toc` before
`StaticPvpData.lua`:

```
seed\generated\SeedPvpTalentCatalog.lua
StaticPvpData.lua
```

Then wire it into `StaticPvpData.lua` following the existing pattern:

```lua
local generated = ns.GeneratedSeedData or {}
-- add:
local pvpTalentCatalog = Helpers.CopyTable(generated.pvpTalentCatalog or {}, true)
-- expose:
ns.StaticPvpData = { ..., PVP_TALENT_CATALOG = pvpTalentCatalog }
```

## When to Re-run

| Trigger | Action |
|---|---|
| New WoW patch | Re-run both scripts — specs/talents may have changed |
| New PvP season | Re-run to pick up new PvP talents |
| New class/spec added | Re-run both scripts |
| Offline Lua regen | Run `generate_seed_from_api.py` only (uses committed JSON) |

## Committed Files

`data/raw/*.json` files are committed to the repo. This means:
- Lua seed files can be regenerated without API credentials.
- Diffs are visible when the API data changes after a re-fetch.
````

---

### Step 5 — Create data/raw/ directory placeholder and add gitignore entry

Create `data/raw/.gitkeep` so the directory is tracked by git:

```bash
mkdir -p data/raw
touch data/raw/.gitkeep
```

If a `.gitignore` exists at the repo root, verify `data/raw/` is **not** excluded. If it is, add an explicit un-ignore:

```
# Keep raw API JSON for offline Lua seed generation
!data/raw/
!data/raw/*.json
```

---

### Step 6 — Commit

```bash
git add scripts/ data/raw/.gitkeep .gitignore
git commit -m "feat(scripts): Battle.net API fetch + Lua seed generation scripts"
```

---

## Out of Scope for This Phase

The following metrics require positional or client-side state that is not available through the WoW combat log API and are explicitly deferred:

- `healer_line_break_rate` — requires tracking player/healer positions
- `exposure_score` — requires positional distance calculations
- Pillar usage quality — requires 3D map geometry data

These may be revisited if Blizzard exposes unit position APIs in a future patch.
