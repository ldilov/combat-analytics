local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local OpenerLabService = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local MAX_OPENER_SPELLS = 5
local MIN_SAMPLES_FOR_RANKING = 3
local MIN_SESSIONS_FOR_MATCHUP = 10

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Extract the first N player_cast timeline events from a session, sorted by
--- timestamp.  Returns an ordered array of spell IDs (up to MAX_OPENER_SPELLS).
--- @param session table  A finalized session with timelineEvents.
--- @return table|nil  Ordered spell ID array, or nil if no casts found.
local function extractOpenerSpells(session)
    if not session or not session.timelineEvents then
        return nil
    end

    local playerCasts = {}
    for _, event in ipairs(session.timelineEvents) do
        if event.lane == Constants.TIMELINE_LANE.PLAYER_CAST and event.spellId then
            playerCasts[#playerCasts + 1] = event
        end
    end

    if #playerCasts == 0 then
        return nil
    end

    -- Sort by relative timestamp ascending (earliest casts first).
    table.sort(playerCasts, function(a, b)
        return (a.t or 0) < (b.t or 0)
    end)

    -- Take the first MAX_OPENER_SPELLS entries.
    local spells = {}
    local limit = math.min(#playerCasts, MAX_OPENER_SPELLS)
    for i = 1, limit do
        spells[#spells + 1] = playerCasts[i].spellId
    end

    return spells
end

--- Build a deterministic hash string from an ordered array of spell IDs.
--- Example: {12042, 31884, 1766} -> "12042-31884-1766"
--- @param spellSequence table  Ordered spell ID array.
--- @return string
local function buildSequenceHash(spellSequence)
    local parts = {}
    for _, spellId in ipairs(spellSequence) do
        parts[#parts + 1] = tostring(spellId)
    end
    return table.concat(parts, "-")
end

--- Derive the matchup key from a session's primary opponent.
--- Returns the opponent specId as a string, or "unknown" when unavailable.
--- @param session table
--- @return string
local function buildMatchupKey(session)
    local opponent = session.primaryOpponent
    if opponent and opponent.specId then
        return tostring(opponent.specId)
    end
    return "unknown"
end

--- Derive the build hash from a session's player snapshot.
--- @param session table
--- @return string
local function buildHashFromSession(session)
    local snapshot = session.playerSnapshot
    if snapshot and snapshot.buildHash then
        return snapshot.buildHash
    end
    return "unknown"
end

--- Determine whether a session passes the optional filter criteria.
--- @param session table
--- @param filters table|nil  Optional: {specId, buildHash, context, minSessions}
--- @return boolean
local function sessionPassesFilter(session, filters)
    if not filters then
        return true
    end

    if filters.specId then
        local opponent = session.primaryOpponent
        if not opponent or opponent.specId ~= filters.specId then
            return false
        end
    end

    if filters.buildHash then
        local snapshot = session.playerSnapshot
        if not snapshot or snapshot.buildHash ~= filters.buildHash then
            return false
        end
    end

    if filters.context then
        if session.context ~= filters.context then
            return false
        end
    end

    return true
end

--- Build the composite group key used to index opener groups.
--- Format: "sequenceHash|matchupKey|buildHash"
--- @param sequenceHash string
--- @param matchupKey string
--- @param buildHash string
--- @return string
local function buildGroupKey(sequenceHash, matchupKey, buildHash)
    return sequenceHash .. "|" .. matchupKey .. "|" .. buildHash
end

-- ---------------------------------------------------------------------------
-- T102: AggregateOpeners
-- ---------------------------------------------------------------------------

--- Extracts opener spell sequences from a collection of sessions and groups
--- them by sequence hash + matchup key + build hash.
---
--- @param sessions table  Array or id-keyed map of finalized sessions.
--- @param filters table|nil  Optional filter: {specId, buildHash, context, minSessions}
--- @return table  openerGroups keyed by groupKey.
function OpenerLabService:AggregateOpeners(sessions, filters)
    if not sessions then
        return {}
    end

    local openerGroups = {}

    -- Support both array-style and map-style session collections.
    local sessionList = {}
    if sessions[1] ~= nil then
        -- Array of sessions
        for _, session in ipairs(sessions) do
            sessionList[#sessionList + 1] = session
        end
    else
        -- Map keyed by ID or arbitrary key
        for _, session in pairs(sessions) do
            if type(session) == "table" then
                sessionList[#sessionList + 1] = session
            end
        end
    end

    for _, session in ipairs(sessionList) do
        if sessionPassesFilter(session, filters) then
            local spellSequence = extractOpenerSpells(session)
            if spellSequence and #spellSequence > 0 then
                local sequenceHash = buildSequenceHash(spellSequence)
                local matchupKey = buildMatchupKey(session)
                local buildHash = buildHashFromSession(session)
                local groupKey = buildGroupKey(sequenceHash, matchupKey, buildHash)

                local group = openerGroups[groupKey]
                if not group then
                    group = {
                        spellSequence = spellSequence,
                        sequenceHash = sequenceHash,
                        matchupKey = matchupKey,
                        buildHash = buildHash,
                        sessions = {},
                        wins = 0,
                        losses = 0,
                        totalPressure = 0,
                        totalOpenerDamage = 0,
                        killWindowConversions = 0,
                    }
                    openerGroups[groupKey] = group
                end

                group.sessions[#group.sessions + 1] = session.id

                if session.result == Constants.SESSION_RESULT.WON then
                    group.wins = group.wins + 1
                elseif session.result == Constants.SESSION_RESULT.LOST then
                    group.losses = group.losses + 1
                end

                local metrics = session.metrics or {}
                group.totalPressure = group.totalPressure
                    + (metrics.pressureScore or 0)
                group.totalOpenerDamage = group.totalOpenerDamage
                    + (metrics.openerDamage or 0)
                group.killWindowConversions = group.killWindowConversions
                    + (session.killWindowConversions or 0)
            end
        end
    end

    -- Post-filter: if minSessions is specified, remove groups below threshold.
    if filters and filters.minSessions and filters.minSessions > 0 then
        local minSessions = filters.minSessions
        for key, group in pairs(openerGroups) do
            if #group.sessions < minSessions then
                openerGroups[key] = nil
            end
        end
    end

    return openerGroups
end

-- ---------------------------------------------------------------------------
-- T103: RankOpeners
-- ---------------------------------------------------------------------------

--- Computes per-group metrics and returns a sorted array of ranked entries.
--- Groups with fewer than MIN_SAMPLES_FOR_RANKING samples are included but
--- flagged with isReliable = false.
---
--- @param openerGroups table  Output from AggregateOpeners.
--- @return table  Sorted array of ranked opener entries with computed metrics.
function OpenerLabService:RankOpeners(openerGroups)
    if not openerGroups then
        return {}
    end

    local ranked = {}

    for groupKey, group in pairs(openerGroups) do
        local total = #group.sessions
        if total <= 0 then
            -- Skip degenerate empty groups (should not occur, but defensive).
        else
            local winRate = group.wins / total
            local avgPressure = group.totalPressure / total
            local avgOpenerDamage = group.totalOpenerDamage / total
            local conversionRate = group.killWindowConversions / total

            ranked[#ranked + 1] = {
                groupKey = groupKey,
                spellSequence = group.spellSequence,
                sequenceHash = group.sequenceHash,
                matchupKey = group.matchupKey,
                buildHash = group.buildHash,
                sessions = group.sessions,
                wins = group.wins,
                losses = group.losses,
                sampleSize = total,
                winRate = Helpers.Round(winRate, 4),
                avgPressure = Helpers.Round(avgPressure, 2),
                avgOpenerDamage = Helpers.Round(avgOpenerDamage, 0),
                conversionRate = Helpers.Round(conversionRate, 4),
                isReliable = total >= MIN_SAMPLES_FOR_RANKING,
                totalPressure = group.totalPressure,
                totalOpenerDamage = group.totalOpenerDamage,
                killWindowConversions = group.killWindowConversions,
            }
        end
    end

    -- Primary sort: winRate descending, secondary: avgPressure descending.
    table.sort(ranked, function(a, b)
        if a.winRate ~= b.winRate then
            return a.winRate > b.winRate
        end
        return a.avgPressure > b.avgPressure
    end)

    -- T106: Annotate matchup-level insufficient data.
    -- Collect total sessions per matchupKey across all groups.
    local matchupTotals = {}
    for _, entry in ipairs(ranked) do
        local mk = entry.matchupKey
        matchupTotals[mk] = (matchupTotals[mk] or 0) + entry.sampleSize
    end

    for _, entry in ipairs(ranked) do
        local matchupTotal = matchupTotals[entry.matchupKey] or 0
        if matchupTotal < MIN_SESSIONS_FOR_MATCHUP then
            entry.insufficientData = true
            entry.neededSessions = MIN_SESSIONS_FOR_MATCHUP - matchupTotal
        else
            entry.insufficientData = false
            entry.neededSessions = 0
        end
    end

    return ranked
end

-- ---------------------------------------------------------------------------
-- T104: UpdateOpenerAggregates
-- ---------------------------------------------------------------------------

--- Called at session finalization to incrementally update the persistent
--- opener aggregates in db.aggregates.openers.
---
--- @param session table  A finalized session with timelineEvents.
function OpenerLabService:UpdateOpenerAggregates(session)
    if not session then
        return
    end

    local spellSequence = extractOpenerSpells(session)
    if not spellSequence or #spellSequence == 0 then
        return
    end

    local store = ns.Addon:GetModule("CombatStore")
    if not store then
        return
    end

    local db = store:GetDB()
    if not db or not db.aggregates then
        return
    end

    db.aggregates.openers = db.aggregates.openers or {}
    local openers = db.aggregates.openers

    local sequenceHash = buildSequenceHash(spellSequence)
    local matchupKey = buildMatchupKey(session)
    local buildHash = buildHashFromSession(session)
    local groupKey = buildGroupKey(sequenceHash, matchupKey, buildHash)

    local entry = openers[groupKey]
    if not entry then
        entry = {
            spellSequence = spellSequence,
            sequenceHash = sequenceHash,
            matchupKey = matchupKey,
            buildHash = buildHash,
            sessions = {},
            wins = 0,
            losses = 0,
            totalPressure = 0,
            totalOpenerDamage = 0,
            killWindowConversions = 0,
        }
        openers[groupKey] = entry
    end

    entry.sessions[#entry.sessions + 1] = session.id

    if session.result == Constants.SESSION_RESULT.WON then
        entry.wins = entry.wins + 1
    elseif session.result == Constants.SESSION_RESULT.LOST then
        entry.losses = entry.losses + 1
    end

    local metrics = session.metrics or {}
    entry.totalPressure = entry.totalPressure
        + (metrics.pressureScore or 0)
    entry.totalOpenerDamage = entry.totalOpenerDamage
        + (metrics.openerDamage or 0)
    entry.killWindowConversions = entry.killWindowConversions
        + (session.killWindowConversions or 0)
end

-- ---------------------------------------------------------------------------
-- Public helper: extract opener from a session (for external callers)
-- ---------------------------------------------------------------------------

--- Extract opener spell sequence from a session. Useful for UI display and
--- external modules that need opener data without full aggregation.
--- @param session table
--- @return table|nil  Ordered array of spell IDs, or nil.
function OpenerLabService:ExtractOpener(session)
    return extractOpenerSpells(session)
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("OpenerLabService", OpenerLabService)
