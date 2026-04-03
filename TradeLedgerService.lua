local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local TradeLedgerService = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local PVP_TRINKET_SPELL_ID = 42292
local DEATH_RECAP_WINDOW_SECONDS = 5

-- Categories for trade ledger entries.
local CATEGORY_OFFENSIVE = "offensive"
local CATEGORY_DEFENSIVE = "defensive"
local CATEGORY_TRINKET = "trinket"
local CATEGORY_CC_RECEIVED = "cc_received"
local CATEGORY_KILL_WINDOW = "kill_window"
local CATEGORY_DEATH = "death"

-- Confidence levels for death recaps.
local CONFIDENCE_FULL = "full"
local CONFIDENCE_PARTIAL = "partial"
local CONFIDENCE_MINIMAL = "minimal"

-- ---------------------------------------------------------------------------
-- Internal: Spell classification
-- ---------------------------------------------------------------------------

--- Determine the SPELL_CATEGORIES category for a given spellId.
--- Checks Constants.SPELL_CATEGORIES first, then falls back to
--- ns.StaticPvpData.SPELL_INTELLIGENCE for the enriched seed catalogue.
--- Returns the category string or nil if unknown.
local function resolveSpellCategory(spellId)
    if not spellId then
        return nil
    end

    local category = Constants.SPELL_CATEGORIES and Constants.SPELL_CATEGORIES[spellId] or nil
    if category then
        return category
    end

    local staticPvp = ns.StaticPvpData
    if staticPvp and staticPvp.GetSpellInfo then
        local seedInfo = staticPvp.GetSpellInfo(spellId)
        if seedInfo and seedInfo.category then
            return seedInfo.category
        end
    end

    return nil
end

--- Returns true when the spell is classified as a significant event worth
--- including in the trade ledger (major offensive CD, major defensive CD,
--- trinket, or crowd control).
local function isSignificantSpell(spellId, category)
    if spellId == PVP_TRINKET_SPELL_ID then
        return true
    end

    if category == "offensive" or category == "defensive" or category == "crowd_control" then
        return true
    end

    -- Also check the enriched seed data for major offensive/defensive flags.
    local staticPvp = ns.StaticPvpData
    if staticPvp and staticPvp.GetSpellInfo then
        local seedInfo = staticPvp.GetSpellInfo(spellId)
        if seedInfo then
            if seedInfo.isMajorOffensive or seedInfo.isMajorDefensive or seedInfo.isPvPTrinket then
                return true
            end
        end
    end

    return false
end

--- Safely resolve a spell name from a timeline event, falling back to the
--- C_Spell API when the event does not carry a name.
local function resolveSpellName(event)
    if event.spellName then
        return event.spellName
    end

    if event.spellId then
        local ok, name = pcall(function()
            return ApiCompat.GetSpellName(event.spellId)
        end)
        if ok and name then
            return name
        end
    end

    return nil
end

--- Resolve a source name from event metadata.
local function resolveSourceName(event)
    if event.meta then
        if event.meta.sourceName then
            return event.meta.sourceName
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- T091: BuildTradeLedger
-- ---------------------------------------------------------------------------

--- Classify a player_cast timeline event into a trade ledger category.
--- Returns (category, isPlayerAction) or nil if the event should be filtered.
local function classifyPlayerCast(event)
    local spellId = event.spellId
    if not spellId then
        return nil, true
    end

    -- PvP Trinket takes priority.
    if spellId == PVP_TRINKET_SPELL_ID then
        return CATEGORY_TRINKET, true
    end

    local category = resolveSpellCategory(spellId)
    if not isSignificantSpell(spellId, category) then
        return nil, true
    end

    if category == "offensive" then
        return CATEGORY_OFFENSIVE, true
    end
    if category == "defensive" then
        return CATEGORY_DEFENSIVE, true
    end
    if category == "crowd_control" then
        -- Player-cast CC is offensive pressure; classify as offensive.
        return CATEGORY_OFFENSIVE, true
    end

    return nil, true
end

--- Build the complete trade ledger from a session's timelineEvents.
--- Returns a timestamp-sorted array of TradeLedgerEntry tables.
function TradeLedgerService:BuildTradeLedger(session)
    if not session then
        return {}
    end

    local timeline = session.timelineEvents
    if not timeline or #timeline == 0 then
        return {}
    end

    local LANE = Constants.TIMELINE_LANE
    local entries = {}

    for _, event in ipairs(timeline) do
        local lane = event.lane
        local entry = nil

        if lane == LANE.PLAYER_CAST then
            local category, isPlayerAction = classifyPlayerCast(event)
            if category then
                entry = {
                    timestamp = event.t or 0,
                    category = category,
                    lane = lane,
                    spellId = event.spellId,
                    spellName = resolveSpellName(event),
                    source = event.source or Constants.PROVENANCE_SOURCE.STATE,
                    targetName = nil,
                    duration = nil,
                    amount = event.amount or nil,
                    isPlayerAction = isPlayerAction,
                }
            end

        elseif lane == LANE.CC_RECEIVED then
            -- Only include "start" events to avoid duplicate end markers.
            if event.type == "start" then
                local spellId = event.meta and event.meta.spellID or event.spellId or nil
                local duration = event.meta and event.meta.duration or nil
                entry = {
                    timestamp = event.t or 0,
                    category = CATEGORY_CC_RECEIVED,
                    lane = lane,
                    spellId = spellId,
                    spellName = event.meta and event.meta.displayText or resolveSpellName(event),
                    source = event.source or Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL,
                    targetName = nil,
                    duration = duration,
                    amount = nil,
                    isPlayerAction = false,
                }
            end

        elseif lane == LANE.KILL_WINDOW then
            entry = {
                timestamp = event.t or 0,
                category = CATEGORY_KILL_WINDOW,
                lane = lane,
                spellId = nil,
                spellName = nil,
                source = event.source or Constants.PROVENANCE_SOURCE.ESTIMATED,
                targetName = event.meta and event.meta.targetName or nil,
                duration = event.meta and event.meta.duration or nil,
                amount = event.meta and event.meta.totalDamage or nil,
                isPlayerAction = true,
            }

        elseif lane == LANE.DEATH then
            entry = {
                timestamp = event.t or 0,
                category = CATEGORY_DEATH,
                lane = lane,
                spellId = event.spellId or nil,
                spellName = resolveSpellName(event),
                source = event.source or Constants.PROVENANCE_SOURCE.STATE,
                targetName = nil,
                duration = nil,
                amount = nil,
                isPlayerAction = false,
            }

        elseif lane == LANE.DM_ENEMY_SPELL then
            -- Enemy spells from the Damage Meter; only include significant ones
            -- or those with meaningful damage.
            local spellId = event.spellId
            local amount = event.amount or 0
            local category = resolveSpellCategory(spellId)
            local significant = isSignificantSpell(spellId, category) or amount > 0

            if significant then
                entry = {
                    timestamp = event.t or 0,
                    category = CATEGORY_OFFENSIVE,
                    lane = lane,
                    spellId = spellId,
                    spellName = resolveSpellName(event),
                    source = event.source or Constants.PROVENANCE_SOURCE.DAMAGE_METER,
                    targetName = nil,
                    duration = nil,
                    amount = amount > 0 and amount or nil,
                    isPlayerAction = false,
                }
            end
        end

        if entry then
            entries[#entries + 1] = entry
        end
    end

    -- Sort by timestamp ascending; stable tiebreak on insertion order
    -- preserved by using the index as secondary key.
    for i, e in ipairs(entries) do
        e._sortIndex = i
    end

    table.sort(entries, function(a, b)
        local ta = a.timestamp or 0
        local tb = b.timestamp or 0
        if ta ~= tb then
            return ta < tb
        end
        return (a._sortIndex or 0) < (b._sortIndex or 0)
    end)

    -- Strip internal sort key.
    for _, e in ipairs(entries) do
        e._sortIndex = nil
    end

    return entries
end

-- ---------------------------------------------------------------------------
-- T092/T093: BuildDeathRecap
-- ---------------------------------------------------------------------------

--- Find the last timeline event matching a lane before a given timestamp.
local function findLastEventBefore(timeline, lane, beforeTimestamp)
    local best = nil
    for _, event in ipairs(timeline) do
        if event.lane == lane and (event.t or 0) <= beforeTimestamp then
            if not best or (event.t or 0) > (best.t or 0) then
                best = event
            end
        end
    end
    return best
end

--- Collect all dm_enemy_spell events within the window preceding deathTime.
local function collectEnemySpellsInWindow(timeline, deathTime, windowSeconds)
    local windowStart = deathTime - windowSeconds
    local results = {}
    for _, event in ipairs(timeline) do
        if event.lane == Constants.TIMELINE_LANE.DM_ENEMY_SPELL then
            local t = event.t or 0
            if t >= windowStart and t <= deathTime then
                results[#results + 1] = event
            end
        end
    end
    return results
end

--- Find the CC entry from CC_RECEIVED timeline lane events active at deathTime.
local function findCCAtDeathFromTimeline(timeline, deathTime)
    -- Build a list of active CC windows from start/end pairs.
    local activeWindows = {}
    for _, event in ipairs(timeline) do
        if event.lane == Constants.TIMELINE_LANE.CC_RECEIVED then
            if event.type == "start" then
                local duration = event.meta and event.meta.duration or 0
                local spellId = event.meta and event.meta.spellID or event.spellId or nil
                activeWindows[#activeWindows + 1] = {
                    spellId = spellId,
                    spellName = event.meta and event.meta.displayText or nil,
                    startTime = event.t or 0,
                    duration = duration,
                    source = event.source,
                }
            end
        end
    end

    -- Find the most recent CC window that covers deathTime.
    for i = #activeWindows, 1, -1 do
        local w = activeWindows[i]
        local endTime = w.startTime + (w.duration or 0)
        if deathTime >= w.startTime and deathTime <= endTime then
            return w
        end
    end

    return nil
end

--- Find the last player defensive cast before deathTime.
local function findLastDefensiveBefore(timeline, deathTime)
    local best = nil
    for _, event in ipairs(timeline) do
        if event.lane == Constants.TIMELINE_LANE.PLAYER_CAST and (event.t or 0) <= deathTime then
            local meta = event.meta
            if meta and meta.isDefensive then
                if not best or (event.t or 0) > (best.t or 0) then
                    best = event
                end
            end
        end
    end
    return best
end

--- Build a death recap for the first player death in the session.
--- Merges data from dm_enemy_spell events, CC timeline, and defensive usage.
function TradeLedgerService:BuildDeathRecap(session)
    if not session then
        return nil
    end

    local survival = session.survival
    if not survival or (survival.deaths or 0) == 0 then
        return nil
    end

    local timeline = session.timelineEvents
    if not timeline then
        return self:BuildPartialDeathRecap(session)
    end

    -- Find the death timestamp from the timeline.
    local deathTime = nil
    for _, event in ipairs(timeline) do
        if event.lane == Constants.TIMELINE_LANE.DEATH then
            -- Use the first death event found (player death).
            deathTime = event.t or 0
            break
        end
    end

    -- If no death event in timeline, fall back to session duration.
    if not deathTime then
        deathTime = session.duration or 0
    end

    -- Collect enemy spells in the last window.
    local enemySpells = collectEnemySpellsInWindow(timeline, deathTime, DEATH_RECAP_WINDOW_SECONDS)
    local hasDMData = #enemySpells > 0

    -- T093: If no DM enemy spell data, build a partial recap.
    if not hasDMData then
        return self:BuildPartialDeathRecap(session)
    end

    -- Determine the killing blow (last enemy spell before death).
    local killingBlowEvent = nil
    local maxT = -1
    for _, event in ipairs(enemySpells) do
        local t = event.t or 0
        if t > maxT then
            maxT = t
            killingBlowEvent = event
        end
    end

    local killingBlow = nil
    if killingBlowEvent then
        killingBlow = {
            spellId = killingBlowEvent.spellId,
            spellName = resolveSpellName(killingBlowEvent),
            sourceName = resolveSourceName(killingBlowEvent),
            amount = killingBlowEvent.amount or 0,
        }
    end

    -- Sum total damage in the window.
    local totalDamageLastWindow = 0
    for _, event in ipairs(enemySpells) do
        totalDamageLastWindow = totalDamageLastWindow + (event.amount or 0)
    end

    -- Check for CC at death time.
    local ccAtDeath = nil
    local ccEntry = findCCAtDeath(session, deathTime)
    if not ccEntry then
        ccEntry = findCCAtDeathFromTimeline(timeline, deathTime)
    end

    if ccEntry then
        local family = nil
        local staticPvp = ns.StaticPvpData
        if staticPvp and staticPvp.GetCCFamily and ccEntry.spellId then
            family = staticPvp.GetCCFamily(ccEntry.spellId)
        end

        ccAtDeath = {
            spellId = ccEntry.spellId,
            family = family,
            duration = ccEntry.duration or 0,
            source = ccEntry.sourceName or ccEntry.source or nil,
        }
    end

    -- Last defensive used before death.
    local lastDefensive = nil
    local defEvent = findLastDefensiveBefore(timeline, deathTime)
    if defEvent then
        lastDefensive = {
            spellId = defEvent.spellId,
            spellName = resolveSpellName(defEvent),
            usedAt = defEvent.t or 0,
        }
    end

    -- Unused defensives count from session survival data.
    local unusedDefensives = survival.unusedDefensives or 0

    -- Build provenance table.
    local provenance = {
        killingBlow = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
        ccAtDeath = ccEntry and Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL or nil,
        lastDefensive = defEvent and Constants.PROVENANCE_SOURCE.STATE or nil,
        unusedDefensives = Constants.PROVENANCE_SOURCE.ESTIMATED,
        totalDamageLastWindow = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
    }

    -- Determine confidence level.
    local confidence = CONFIDENCE_FULL
    if not killingBlow then
        confidence = CONFIDENCE_PARTIAL
    end
    if not killingBlow and not ccAtDeath and not lastDefensive then
        confidence = CONFIDENCE_MINIMAL
    end

    return {
        killingBlow = killingBlow,
        ccAtDeath = ccAtDeath,
        lastDefensive = lastDefensive,
        unusedDefensives = unusedDefensives,
        totalDamageLastWindow = totalDamageLastWindow,
        provenance = provenance,
        confidence = confidence,
    }
end

-- ---------------------------------------------------------------------------
-- T093: Partial death recap fallback
-- ---------------------------------------------------------------------------

--- Build a partial death recap when no dm_enemy_spell events are available.
--- Uses only CC and defensive data from the timeline + session totals.
function TradeLedgerService:BuildPartialDeathRecap(session)
    if not session then
        return nil
    end

    local survival = session.survival
    if not survival or (survival.deaths or 0) == 0 then
        return nil
    end

    local timeline = session.timelineEvents or {}

    -- Find death time from timeline or session duration.
    local deathTime = nil
    for _, event in ipairs(timeline) do
        if event.lane == Constants.TIMELINE_LANE.DEATH then
            deathTime = event.t or 0
            break
        end
    end
    deathTime = deathTime or session.duration or 0

    -- CC at death from CC_RECEIVED lane.
    local ccAtDeath = nil
    local ccEntry = findCCAtDeathFromTimeline(timeline, deathTime)

    if ccEntry then
        local family = nil
        local staticPvp = ns.StaticPvpData
        if staticPvp and staticPvp.GetCCFamily and ccEntry.spellId then
            family = staticPvp.GetCCFamily(ccEntry.spellId)
        end

        ccAtDeath = {
            spellId = ccEntry.spellId,
            family = family,
            duration = ccEntry.duration or 0,
            source = ccEntry.sourceName or ccEntry.source or nil,
        }
    end

    -- Last defensive before death.
    local lastDefensive = nil
    local defEvent = findLastDefensiveBefore(timeline, deathTime)
    if defEvent then
        lastDefensive = {
            spellId = defEvent.spellId,
            spellName = resolveSpellName(defEvent),
            usedAt = defEvent.t or 0,
        }
    end

    -- Estimate damage from session totals if available.
    local totalDamageLastWindow = 0
    local totals = session.totals
    if totals and (totals.damageTaken or 0) > 0 then
        -- Use total damage taken as a rough estimate; the full recap window
        -- is unknown without per-event timestamps.
        totalDamageLastWindow = totals.damageTaken or 0
    end

    local unusedDefensives = survival.unusedDefensives or 0

    local provenance = {
        killingBlow = nil,
        ccAtDeath = ccEntry and Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL or nil,
        lastDefensive = defEvent and Constants.PROVENANCE_SOURCE.STATE or nil,
        unusedDefensives = Constants.PROVENANCE_SOURCE.ESTIMATED,
        totalDamageLastWindow = totals and Constants.PROVENANCE_SOURCE.ESTIMATED or nil,
    }

    local confidence = CONFIDENCE_PARTIAL
    if not ccAtDeath and not lastDefensive then
        confidence = CONFIDENCE_MINIMAL
    end

    return {
        killingBlow = nil,
        ccAtDeath = ccAtDeath,
        lastDefensive = lastDefensive,
        unusedDefensives = unusedDefensives,
        totalDamageLastWindow = totalDamageLastWindow,
        provenance = provenance,
        confidence = confidence,
    }
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("TradeLedgerService", TradeLedgerService)
