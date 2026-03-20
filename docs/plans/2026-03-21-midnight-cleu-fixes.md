# Midnight CLEU Compatibility & Data Pipeline Fixes

> **For  :** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 4 critical bugs (0 damage, Unknown names, empty Rating tab, Lua warnings) caused by Midnight's restricted combat log model and deprecated constant removal.

**Architecture:** Hybrid approach — use `C_CombatLogInternal.GetCurrentEventInfo()` as primary CLEU source, replace all deprecated `COMBATLOG_OBJECT_*` globals with `Enum.CombatLogObject.*`, sanitize secret values in the CLEU normalization layer, ensure `C_DamageMeter` reconciliation fills gaps for restricted sessions, and backfill opponent names from `C_PvP.GetScoreInfo()` post-match scoreboard.

**Tech Stack:** WoW Lua (Midnight 11.2+), `C_CombatLogInternal`, `Enum.CombatLogObject`, `C_DamageMeter`, `C_PvP`

---

## Context for Implementer

### What broke and why

In WoW Midnight (11.2+), Blizzard made three changes that broke our combat data pipeline:

1. **Deprecated constants removed by default.** The old globals `COMBATLOG_OBJECT_AFFILIATION_MINE`, `COMBATLOG_OBJECT_TYPE_PLAYER`, `COMBATLOG_OBJECT_REACTION_HOSTILE` now only exist if `GetCVarBool("loadDeprecationFallbacks")` is true (it's false by default). Our code uses `or 0` fallback, so the flag bitmask checks silently always return false. The Midnight replacement is `Enum.CombatLogObject.AffiliationMine` (=1), `.TypePlayer` (=1024), `.ReactionHostile` (=64).

2. **CLEU data restricted in rated PvP.** When `C_CombatLog.IsCombatLogRestricted()` is true (rated arena/BG), `CombatLogGetCurrentEventInfo()` returns **secret values** for damage amounts, names, and GUIDs. Any arithmetic or string operation on a secret value throws an error. Our `NormalizeCombatLogEvent` assigns these directly, and later `UpdateSurvivalStats` does `session.localTotals.damageDone + eventRecord.amount` which blows up. The xpcall in `Events.lua` catches it, silently dropping the entire event.

3. **`CombatLogGetCurrentEventInfo` is a deprecated alias.** The function is defined in `Blizzard_DeprecatedCombatLog` as `CombatLogGetCurrentEventInfo = C_CombatLog.GetCurrentEventInfo`. The non-deprecated API is `C_CombatLogInternal.GetCurrentEventInfo()` (Environment: "All", non-restricted).

### Symptoms mapping

| Symptom | Root cause |
|---|---|
| 0 damage everywhere | Secret value arithmetic in `UpdateSurvivalStats` kills event handler |
| "Unknown" names in History | CLEU names are secret; flag-based player detection broken (constants=0) |
| Rating tab empty | Session finalization fails before rating data persists; old sessions lack rating snapshots |
| Lua warnings | `xpcall` catches secret value errors, prints via `ns.Addon:Warn()` |

### Key files

| File | What changes |
|---|---|
| `ApiCompat.lua` | Add `C_CombatLogInternal` wrapper, add `SanitizeCLEUValue()` |
| `CombatTracker.lua` | Replace deprecated constants, sanitize CLEU in `NormalizeCombatLogEvent`, add post-match name backfill, resilient finalization |
| `ArenaRoundTracker.lua` | Use `Enum.CombatLogObject` for any flag checks |
| `SessionClassifier.lua` | Use `Enum.CombatLogObject` for any flag checks |
| `Constants.lua` | Add canonical CLEU flag constants |
| `DamageMeterService.lua` | No changes needed (already works correctly) |
| `UI/CombatHistoryView.lua` | Minor: better "Unknown" fallback display |

### Verification after each task

After each task, the implementer should:
1. Confirm no syntax errors: open the file in a text editor or run a Lua linter
2. Grep for any remaining references to the old deprecated globals
3. Check that the code compiles (no WoW runtime available, but verify syntax)

### Final in-game verification

After all tasks:
1. `/reload` — no Lua errors on login
2. `/ca trace on` — enable trace logging
3. Queue a rated arena match
4. After match: `/ca` → check Summary tab shows damage > 0
5. Check History tab shows opponent name (not "Unknown")
6. Check Rating tab shows the new session
7. Check no warning messages in chat during combat

---

## Task 1: Add Midnight CLEU Constants to Constants.lua

**Files:**
- Modify: `Constants.lua`

**Why:** Centralize the `Enum.CombatLogObject` values so every module can reference them without depending on deprecated globals.

**Step 1: Add CLEU flag constants**

In `Constants.lua`, find where other constants are defined (near the top, after the enums). Add a new block:

```lua
-- ──────────────────────────────────────────────────────────────────────────────
-- Combat Log Object Flags (Midnight-native, replaces deprecated globals)
-- ──────────────────────────────────────────────────────────────────────────────
-- These are authoritative values from Enum.CombatLogObject. The old globals
-- (COMBATLOG_OBJECT_AFFILIATION_MINE, etc.) only exist when the CVar
-- "loadDeprecationFallbacks" is true, which is false by default in Midnight.
Constants.CLEU_FLAGS = {
    AFFILIATION_MINE     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationMine) or 1,
    AFFILIATION_PARTY    = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationParty) or 2,
    AFFILIATION_RAID     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationRaid) or 4,
    AFFILIATION_OUTSIDER = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.AffiliationOutsider) or 8,
    REACTION_FRIENDLY    = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionFriendly) or 16,
    REACTION_NEUTRAL     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionNeutral) or 32,
    REACTION_HOSTILE     = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ReactionHostile) or 64,
    CONTROL_PLAYER       = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ControlPlayer) or 256,
    CONTROL_NPC          = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.ControlNpc) or 512,
    TYPE_PLAYER          = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypePlayer) or 1024,
    TYPE_NPC             = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypeNpc) or 2048,
    TYPE_PET             = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypePet) or 4096,
    TYPE_GUARDIAN        = (Enum and Enum.CombatLogObject and Enum.CombatLogObject.TypeGuardian) or 8192,
}
```

**Step 2: Verify**

Grep the codebase for any remaining `COMBATLOG_OBJECT_` references to know what needs updating in later tasks:

```
grep -rn "COMBATLOG_OBJECT_" *.lua
```

**Step 3: Commit**

```
git add Constants.lua
git commit -m "feat: add Midnight-native CLEU flag constants from Enum.CombatLogObject"
```

---

## Task 2: Replace Deprecated Constants in CombatTracker.lua

**Files:**
- Modify: `CombatTracker.lua` (lines 11-13, 567-572)

**Why:** The three deprecated globals at the top of CombatTracker.lua are all 0 when `loadDeprecationFallbacks` is false. This breaks `hasFlag()` → breaks `sourceMine`/`destMine` flag detection → breaks hostile player identification → breaks everything.

**Step 1: Replace the constant declarations (lines 11-13)**

Change:
```lua
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0
local REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0
```

To:
```lua
local AFFILIATION_MINE = Constants.CLEU_FLAGS.AFFILIATION_MINE
local TYPE_PLAYER      = Constants.CLEU_FLAGS.TYPE_PLAYER
local REACTION_HOSTILE = Constants.CLEU_FLAGS.REACTION_HOSTILE
```

**Step 2: Verify all usages still compile**

The existing `hasFlag(sourceFlags, AFFILIATION_MINE)` calls remain unchanged — they now get the correct non-zero bitmask values (1, 1024, 64).

Search for any other files that reference the old globals:

```
grep -rn "COMBATLOG_OBJECT_AFFILIATION_MINE\|COMBATLOG_OBJECT_TYPE_PLAYER\|COMBATLOG_OBJECT_REACTION_HOSTILE" *.lua
```

Fix any other files found (likely `SessionClassifier.lua`, `ArenaRoundTracker.lua`, `SpellAttributionPipeline.lua`). Each should import from `Constants.CLEU_FLAGS` instead.

**Step 3: Commit**

```
git add CombatTracker.lua SessionClassifier.lua ArenaRoundTracker.lua SpellAttributionPipeline.lua
git commit -m "fix: replace deprecated COMBATLOG_OBJECT_* globals with Constants.CLEU_FLAGS"
```

---

## Task 3: Use C_CombatLogInternal.GetCurrentEventInfo() as Primary CLEU Source

**Files:**
- Modify: `ApiCompat.lua` (lines 12-20)

**Why:** `CombatLogGetCurrentEventInfo` is a deprecated alias only available when `loadDeprecationFallbacks` CVar is true. `C_CombatLog.GetCurrentEventInfo` may not be in the documented API. `C_CombatLogInternal.GetCurrentEventInfo()` is the Midnight-native, non-restricted, Environment="All" function.

**Step 1: Update `ApiCompat.GetCombatLogEventInfo()`**

Change the function (lines 12-20) from:
```lua
function ApiCompat.GetCombatLogEventInfo()
    if C_CombatLog and C_CombatLog.GetCurrentEventInfo then
        return C_CombatLog.GetCurrentEventInfo()
    end
    if CombatLogGetCurrentEventInfo then
        return CombatLogGetCurrentEventInfo()
    end
    return nil
end
```

To:
```lua
function ApiCompat.GetCombatLogEventInfo()
    -- Priority 1: Midnight-native non-restricted API (Environment: All).
    if C_CombatLogInternal and C_CombatLogInternal.GetCurrentEventInfo then
        return C_CombatLogInternal.GetCurrentEventInfo()
    end
    -- Priority 2: C_CombatLog namespace (may exist as undocumented internal).
    if C_CombatLog and C_CombatLog.GetCurrentEventInfo then
        return C_CombatLog.GetCurrentEventInfo()
    end
    -- Priority 3: Deprecated global (only available with loadDeprecationFallbacks CVar).
    if CombatLogGetCurrentEventInfo then
        return CombatLogGetCurrentEventInfo()
    end
    return nil
end
```

**Step 2: Commit**

```
git add ApiCompat.lua
git commit -m "fix: use C_CombatLogInternal.GetCurrentEventInfo as primary CLEU source"
```

---

## Task 4: Add Secret Value Sanitization to NormalizeCombatLogEvent

**Files:**
- Modify: `ApiCompat.lua` (add helper)
- Modify: `CombatTracker.lua` (lines 551-574, add sanitization)

**Why:** Even with `C_CombatLogInternal`, we don't know for certain that all values are non-secret in restricted sessions. Belt-and-suspenders: sanitize every CLEU field before storing it. This prevents the cascade failure where one secret value in `eventRecord.amount` kills the entire event handler chain.

**Step 1: Add `SanitizeNumber` and `SanitizeString` helpers to ApiCompat.lua**

Add after the `isSecretValue` function (after line 105):

```lua
-- Safely extract a number from a potentially secret value.
-- Returns 0 if the value is secret, nil, or non-numeric.
function ApiCompat.SanitizeNumber(val)
    if val == nil then return 0 end
    if isSecretValue(val) then return 0 end
    return tonumber(val) or 0
end

-- Safely extract a string from a potentially secret value.
-- Returns nil if the value is secret.
function ApiCompat.SanitizeString(val)
    if val == nil then return nil end
    if isSecretValue(val) then return nil end
    if type(val) ~= "string" then return tostring(val) end
    return val
end

-- Safely extract a boolean-ish value from a potentially secret value.
function ApiCompat.SanitizeBool(val)
    if val == nil then return false end
    if isSecretValue(val) then return false end
    return val and true or false
end
```

**Step 2: Sanitize the CLEU header fields in NormalizeCombatLogEvent**

In `CombatTracker.lua`, modify `NormalizeCombatLogEvent` (starting at line 551). The header extraction at line 552 and the eventRecord construction at lines 558-574 need sanitization.

Change the function start from:
```lua
function CombatTracker:NormalizeCombatLogEvent(...)
    local timestamp, subEvent, _, sourceGuid, sourceName, sourceFlags, _, destGuid, destName, destFlags = ...
    if not timestamp or not subEvent then
        return nil
    end

    local payload = { select(12, ...) }
    local eventRecord = {
        timestamp   = timestamp,
        subEvent    = subEvent,
        sourceGuid  = sourceGuid,
        sourceName  = sourceName,
        sourceFlags = sourceFlags or 0,
        destGuid    = destGuid,
        destName    = destName,
        destFlags   = destFlags or 0,
        sourceMine  = isMineGuid(sourceGuid) or hasFlag(sourceFlags or 0, AFFILIATION_MINE),
        destMine    = isMineGuid(destGuid)   or hasFlag(destFlags   or 0, AFFILIATION_MINE),
        sourcePlayer = ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags or 0, TYPE_PLAYER),
        destPlayer   = ApiCompat.IsGuidPlayer(destGuid)   or hasFlag(destFlags   or 0, TYPE_PLAYER),
        sourceHostilePlayer = (ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags or 0, TYPE_PLAYER)) and hasFlag(sourceFlags or 0, REACTION_HOSTILE),
        destHostilePlayer   = (ApiCompat.IsGuidPlayer(destGuid)   or hasFlag(destFlags   or 0, TYPE_PLAYER)) and hasFlag(destFlags   or 0, REACTION_HOSTILE),
        eventType   = "other",
    }
```

To:
```lua
function CombatTracker:NormalizeCombatLogEvent(...)
    local rawTimestamp, rawSubEvent, _, rawSrcGuid, rawSrcName, rawSrcFlags, _, rawDstGuid, rawDstName, rawDstFlags = ...

    -- Bail early if core fields are nil or secret.
    local timestamp = rawTimestamp
    local subEvent = ApiCompat.SanitizeString(rawSubEvent)
    if not timestamp or not subEvent then
        return nil
    end

    -- Sanitize all header fields: in restricted CLEU sessions, any of these
    -- may be secret values that crash on use.
    local sourceGuid  = ApiCompat.SanitizeString(rawSrcGuid)
    local sourceName  = ApiCompat.SanitizeString(rawSrcName)
    local sourceFlags = ApiCompat.SanitizeNumber(rawSrcFlags)
    local destGuid    = ApiCompat.SanitizeString(rawDstGuid)
    local destName    = ApiCompat.SanitizeString(rawDstName)
    local destFlags   = ApiCompat.SanitizeNumber(rawDstFlags)

    local payload = { select(12, ...) }
    local eventRecord = {
        timestamp   = timestamp,
        subEvent    = subEvent,
        sourceGuid  = sourceGuid,
        sourceName  = sourceName,
        sourceFlags = sourceFlags,
        destGuid    = destGuid,
        destName    = destName,
        destFlags   = destFlags,
        sourceMine  = isMineGuid(sourceGuid) or hasFlag(sourceFlags, AFFILIATION_MINE),
        destMine    = isMineGuid(destGuid)   or hasFlag(destFlags, AFFILIATION_MINE),
        sourcePlayer = ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags, TYPE_PLAYER),
        destPlayer   = ApiCompat.IsGuidPlayer(destGuid)   or hasFlag(destFlags, TYPE_PLAYER),
        sourceHostilePlayer = (ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags, TYPE_PLAYER)) and hasFlag(sourceFlags, REACTION_HOSTILE),
        destHostilePlayer   = (ApiCompat.IsGuidPlayer(destGuid)   or hasFlag(destFlags, TYPE_PLAYER)) and hasFlag(destFlags, REACTION_HOSTILE),
        eventType   = "other",
    }
```

**Step 3: Sanitize payload amounts**

In the same function, every `payload[N]` assignment for numeric amounts must be sanitized. Find each `eventRecord.amount = payload[N]` pattern and wrap with `ApiCompat.SanitizeNumber()`. Find each `eventRecord.spellId = payload[N]` and `eventRecord.spellName = payload[N]` and sanitize appropriately.

For the SWING_DAMAGE block (around line 582):
```lua
    if subEvent == "SWING_DAMAGE" then
        eventRecord.eventType  = "damage"
        eventRecord.spellId    = 6603
        eventRecord.spellName  = ApiCompat.GetSpellName(6603) or "Melee"
        eventRecord.amount     = ApiCompat.SanitizeNumber(payload[1])
        eventRecord.overkill   = ApiCompat.SanitizeNumber(payload[2])
        eventRecord.schoolMask = ApiCompat.SanitizeNumber(payload[3])
        eventRecord.resisted   = ApiCompat.SanitizeNumber(payload[4])
        eventRecord.blocked    = ApiCompat.SanitizeNumber(payload[5])
        eventRecord.absorbed   = ApiCompat.SanitizeNumber(payload[6])
        eventRecord.critical   = ApiCompat.SanitizeBool(payload[7])
        eventRecord.glancing   = ApiCompat.SanitizeBool(payload[8])
        eventRecord.crushing   = ApiCompat.SanitizeBool(payload[9])
        eventRecord.isOffHand  = ApiCompat.SanitizeBool(payload[10])
```

For SPELL_DAMAGE / RANGE_DAMAGE / SPELL_PERIODIC_DAMAGE (around line 601):
```lua
    elseif subEvent == "RANGE_DAMAGE" or subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_PERIODIC_DAMAGE" then
        eventRecord.eventType  = "damage"
        eventRecord.spellId    = ApiCompat.SanitizeNumber(payload[1])
        eventRecord.spellName  = ApiCompat.SanitizeString(payload[2])
        eventRecord.spellSchool = ApiCompat.SanitizeNumber(payload[3])
        eventRecord.amount     = ApiCompat.SanitizeNumber(payload[4])
        eventRecord.overkill   = ApiCompat.SanitizeNumber(payload[5])
        eventRecord.schoolMask = ApiCompat.SanitizeNumber(payload[6])
        eventRecord.resisted   = ApiCompat.SanitizeNumber(payload[7])
        eventRecord.absorbed   = ApiCompat.SanitizeNumber(payload[8])
        eventRecord.critical   = ApiCompat.SanitizeBool(payload[9])
        eventRecord.glancing   = ApiCompat.SanitizeBool(payload[10])
        eventRecord.crushing   = ApiCompat.SanitizeBool(payload[11])
        eventRecord.isOffHand  = ApiCompat.SanitizeBool(payload[12])
        eventRecord.hideCaster = ApiCompat.SanitizeBool(payload[13])
```

Apply the same pattern to ALL other payload blocks in this function:
- `ENVIRONMENTAL_DAMAGE` — sanitize amount fields
- `SPELL_HEAL` / `SPELL_PERIODIC_HEAL` — sanitize amount, overhealing, absorbed, critical
- `SPELL_CAST_SUCCESS` / `SPELL_CAST_START` / `SPELL_CAST_FAILED` — sanitize spellId (number), spellName (string)
- `SPELL_SUMMON` / `SPELL_CREATE` — sanitize spellId, spellName
- `SPELL_AURA_BROKEN` / `SPELL_AURA_BROKEN_SPELL` / generic AURA — sanitize spellId, spellName, stackCount
- `SWING_MISSED` / `SPELL_MISSED` — sanitize missType (string), amounts
- `SPELL_INTERRUPT` / `SPELL_DISPEL` — sanitize spellId, spellName, extraSpellId

**Rule of thumb:** `payload[N]` that represents a **number** → `ApiCompat.SanitizeNumber(payload[N])`. That represents a **string** → `ApiCompat.SanitizeString(payload[N])`. That represents a **boolean** → `ApiCompat.SanitizeBool(payload[N])`.

**Step 4: Commit**

```
git add ApiCompat.lua CombatTracker.lua
git commit -m "fix: sanitize all CLEU payload values against Midnight secret values"
```

---

## Task 5: Backfill Opponent Names from Post-Match Scoreboard

**Files:**
- Modify: `CombatTracker.lua` (in `HandlePvpMatchComplete`, the post-match score harvesting block around line 2033)

**Why:** In restricted arena/BG sessions, CLEU names are secret → opponents show as "Unknown". The `C_PvP.GetScoreInfo()` API returns reliable, non-secret names for all participants. We already harvest scores at line 2036. We just need to also backfill `primaryOpponent.name` and actor names from this data.

**Step 1: Add name backfill after score harvesting**

In the `scheduleAfter(0.5, function() ... end)` block that harvests scores (around line 2060), after the `if #scores > 0 then sessionForScores.postMatchScores = scores end` line, add:

```lua
            -- Backfill actor and opponent names from scoreboard.
            -- In restricted CLEU sessions, srcName/dstName are secret and never
            -- get stored.  The scoreboard provides authoritative non-secret names.
            if #scores > 0 then
                sessionForScores.postMatchScores = scores

                -- Backfill names into session actors from scoreboard GUIDs
                for _, entry in ipairs(scores) do
                    if entry.guid and entry.name and sessionForScores.actors then
                        local actor = sessionForScores.actors[entry.guid]
                        if actor and not actor.name then
                            actor.name = entry.name
                        end
                    end
                end

                -- Backfill primaryOpponent name if still missing
                local po = sessionForScores.primaryOpponent
                if po and not po.name and po.guid then
                    for _, entry in ipairs(scores) do
                        if entry.guid == po.guid and entry.name then
                            po.name = entry.name
                            break
                        end
                    end
                end

                -- If primaryOpponent is still nil but we have arena slots with
                -- GUID → score mappings, pick the best opponent from scores
                if not sessionForScores.primaryOpponent and sessionForScores.arena then
                    for _, slot in pairs(sessionForScores.arena.slots or {}) do
                        if slot.guid then
                            for _, entry in ipairs(scores) do
                                if entry.guid == slot.guid and entry.name then
                                    -- Only pick hostile players (not teammates)
                                    local myGuid = ApiCompat.GetPlayerGUID()
                                    if entry.guid ~= myGuid then
                                        sessionForScores.primaryOpponent = sessionForScores.actors[slot.guid] or {
                                            guid = slot.guid,
                                            name = entry.name,
                                            isPlayer = true,
                                            isHostile = true,
                                        }
                                        break
                                    end
                                end
                            end
                            if sessionForScores.primaryOpponent then break end
                        end
                    end
                end

                -- Also backfill arena slot names from scoreboard
                if sessionForScores.arena then
                    for _, slot in pairs(sessionForScores.arena.slots or {}) do
                        if slot.guid and not slot.name then
                            for _, entry in ipairs(scores) do
                                if entry.guid == slot.guid then
                                    slot.name = entry.name
                                    break
                                end
                            end
                        end
                    end
                end
            end
```

Note: Remove the old `if #scores > 0 then sessionForScores.postMatchScores = scores end` since we're incorporating it into the new block.

**Step 2: Commit**

```
git add CombatTracker.lua
git commit -m "fix: backfill opponent names from post-match scoreboard for restricted CLEU sessions"
```

---

## Task 6: Make Session Finalization Resilient to CLEU Failures

**Files:**
- Modify: `CombatTracker.lua` (in `FinalizeSession`, around line 1480)

**Why:** If CLEU processing partially fails (some events error, some succeed), the session may have corrupt `localTotals` values (e.g., a secret number leaked through). The finalization code does arithmetic on these totals and can crash, preventing rating data from being persisted.

**Step 1: Add totals sanitization at the start of FinalizeSession**

After the `session.endedAt = ApiCompat.GetServerTime()` line (line 1482), add:

```lua
    -- Sanitize totals: if CLEU was restricted, localTotals may contain secret
    -- values that leaked through despite our sanitization.  Force them to
    -- safe numbers before any arithmetic in finalization/metrics.
    for _, bucket in ipairs({ session.localTotals, session.totals, session.importedTotals }) do
        if bucket then
            for key, val in pairs(bucket) do
                if type(val) ~= "number" or ApiCompat.IsSecretValue(val) then
                    bucket[key] = 0
                end
            end
        end
    end
```

**Step 2: Ensure rating persistence happens before risky DamageMeter import**

Currently the flow is: DamageMeter import → retry logic → finalize. If DamageMeter import crashes, rating is never saved. Move the rating "after" snapshot capture to happen right at the top of `FinalizeSession`, before DamageMeter import. The "after" snapshot is captured in `HandlePvpMatchComplete` so it should already be set, but add a safety capture:

After the totals sanitization block, add:

```lua
    -- Safety: ensure the "after" rating snapshot is captured even if
    -- HandlePvpMatchComplete was not reached or errored.
    if session.isRated and session.ratingSnapshot and not session.ratingSnapshot.after then
        local ratedInfo = ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
        if ratedInfo then
            session.ratingSnapshot.after = {
                personalRating   = ratedInfo.personalRating,
                bestSeasonRating = ratedInfo.bestSeasonRating,
                seasonPlayed     = ratedInfo.seasonPlayed,
                seasonWon        = ratedInfo.seasonWon,
                weeklyPlayed     = ratedInfo.weeklyPlayed,
                weeklyWon        = ratedInfo.weeklyWon,
            }
        end
    end
```

**Step 3: Commit**

```
git add CombatTracker.lua
git commit -m "fix: sanitize session totals and ensure rating persistence in FinalizeSession"
```

---

## Task 7: Fix Remaining Deprecated Constant References

**Files:**
- Modify: Any file that still references `COMBATLOG_OBJECT_*` globals
- Likely: `SessionClassifier.lua`, `ArenaRoundTracker.lua`, `SpellAttributionPipeline.lua`

**Why:** Comprehensive cleanup — no file should depend on deprecated globals.

**Step 1: Search and fix**

Run:
```
grep -rn "COMBATLOG_OBJECT_" *.lua UI/*.lua Utils/*.lua
```

For each match:
- If it's a constant definition (like `local X = COMBATLOG_OBJECT_... or 0`), replace with `Constants.CLEU_FLAGS.*`
- If it's a direct usage in a `bit.band()` call, replace with `Constants.CLEU_FLAGS.*`
- Make sure the file has access to `ns.Constants` (most do via `local _, ns = ...`)

**Step 2: Commit**

```
git add -A
git commit -m "fix: replace all remaining deprecated COMBATLOG_OBJECT_* references"
```

---

## Task 8: Improve "Unknown" Display in History View

**Files:**
- Modify: `UI/CombatHistoryView.lua`

**Why:** Even with all fixes, some old sessions will have "Unknown" opponents. And future sessions in edge cases might too. Improve the fallback display to be more informative.

**Step 1: Improve the opponent name fallback**

Find the line (around line 159):
```lua
local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown"
```

Replace with:
```lua
local opponent = "Unknown"
if session.primaryOpponent then
    opponent = session.primaryOpponent.name
        or session.primaryOpponent.specName
        or session.primaryOpponent.className
        or session.primaryOpponent.guid
        or "Unknown"
end
-- Fallback: try to build name from arena slots or postMatchScores
if opponent == "Unknown" then
    if session.arena and session.arena.slots then
        for _, slot in pairs(session.arena.slots) do
            if slot.name then
                opponent = slot.name
                break
            elseif slot.prepSpecName then
                opponent = slot.prepSpecName
                break
            end
        end
    end
    if opponent == "Unknown" and session.postMatchScores then
        local myGuid = ns.ApiCompat.GetPlayerGUID()
        for _, entry in ipairs(session.postMatchScores) do
            if entry.guid ~= myGuid and entry.name then
                opponent = entry.name
                break
            end
        end
    end
end
```

**Step 2: Apply same pattern in SummaryView.lua**

Find the similar `opponent` assignment (around line 467):
```lua
local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown Opponent"
```

Apply the same fallback chain.

**Step 3: Commit**

```
git add UI/CombatHistoryView.lua UI/SummaryView.lua
git commit -m "fix: improve Unknown opponent fallback using arena slots and scoreboard data"
```

---

## Task 9: Store Engineering Context in Local Brain

**Why:** Index these findings for future sessions so the engineering brain knows about Midnight CLEU restrictions.

**Step 1: After all code changes are committed, re-index the workspace**

Use `mcp__local-engineering-brain__index_workspace` to re-index with the updated code.

**Step 2: Commit the plan itself**

```
git add docs/plans/2026-03-21-midnight-cleu-fixes.md
git commit -m "docs: add Midnight CLEU compatibility fix plan"
```

---

## Implementation Order

```
Task 1: Constants.lua — CLEU flag constants           (no deps)
Task 2: CombatTracker.lua — replace deprecated consts  (depends on Task 1)
Task 3: ApiCompat.lua — C_CombatLogInternal source     (no deps)
Task 4: ApiCompat + CombatTracker — sanitize CLEU      (depends on Task 3)
Task 5: CombatTracker — scoreboard name backfill       (no deps)
Task 6: CombatTracker — resilient finalization          (no deps)
Task 7: All files — remaining deprecated refs           (depends on Task 1)
Task 8: UI views — improved Unknown fallback            (no deps)
Task 9: Docs + brain — context storage                  (after all)
```

Tasks 1-4 are the **critical path** — they fix the root causes.
Tasks 5-6 are **high-value safety nets** — they ensure names and ratings survive.
Tasks 7-8 are **cleanup** — comprehensive polish.
Task 9 is **documentation**.

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| `C_CombatLogInternal.GetCurrentEventInfo()` also returns secret values | Task 4 sanitizes all fields regardless of source |
| `Enum.CombatLogObject` doesn't exist on older clients | `or <hardcoded_value>` fallback in Task 1 |
| DamageMeter not enabled by user | Already handled by existing `isDamageMeterEnabled()` check; CLEU fixes in Tasks 2-4 give us data even without DamageMeter |
| Post-match scores not available (timing) | `scheduleAfter(0.5)` already handles this; scoreboard is supplementary, not required |
| Old sessions still show "Unknown" | Task 8 adds fallback chain that checks multiple data sources |
