local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local MatchupMemoryService = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local MIN_SESSIONS_FOR_FULL_CARD = 15
local MAX_DEATH_PATTERNS = 3
local MAX_DANGER_SPELLS = 5
local MAX_RECENT_RESULTS = 20
local MAX_DEATH_PATTERN_BUFFER = 50
local TREND_WINDOW = 10

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Filter sessions to those matching a specific opponent specId.
local function filterBySpec(sessions, specId)
    local filtered = {}
    for _, session in ipairs(sessions or {}) do
        local opp = session.primaryOpponent
        if opp and opp.specId == specId then
            filtered[#filtered + 1] = session
        end
    end
    return filtered
end

--- Compute adaptation trend from an ordered result array.
local function computeTrend(results)
    if #results < TREND_WINDOW * 2 then
        return "insufficient_data"
    end
    local window = math.min(TREND_WINDOW, math.floor(#results / 2))
    local firstWins, lastWins = 0, 0
    for i = 1, window do
        if results[i] == "won" then firstWins = firstWins + 1 end
    end
    for i = #results - window + 1, #results do
        if results[i] == "won" then lastWins = lastWins + 1 end
    end
    local delta = (lastWins / window) - (firstWins / window)
    if delta > 0.15 then return "improving" end
    if delta < -0.15 then return "declining" end
    return "stable"
end

--- Map session.result to string.
local function resultString(session)
    if session.result == Constants.SESSION_RESULT.WON then return "won" end
    if session.result == Constants.SESSION_RESULT.LOST then return "lost" end
    return "draw"
end

--- Extract first player_cast timing from timeline.
local function firstCastTiming(session)
    for _, evt in ipairs(session.timelineEvents or {}) do
        if evt.lane == Constants.TIMELINE_LANE.PLAYER_CAST then
            return evt.t or evt.offset or evt.timestampOffset or 0
        end
    end
    return nil
end

--- Build a death pattern key from a death cause entry.
local function deathPatternKey(cause)
    local parts = {}
    parts[#parts + 1] = cause.sourceName or "unknown"
    parts[#parts + 1] = cause.wasCCed and "cc" or "no_cc"
    if cause.ccSpellName then
        parts[#parts + 1] = cause.ccSpellName
    end
    return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- T113: BuildMatchupMemoryCard
-- ---------------------------------------------------------------------------

--- Filter sessions by player build hash (T119).
--- @param sessions table  Array of sessions.
--- @param buildHash string  Build hash to match.
--- @return table  Filtered sessions.
local function filterByBuild(sessions, buildHash)
    if not buildHash then return sessions end
    local filtered = {}
    for _, session in ipairs(sessions or {}) do
        local snap = session.playerSnapshot
        if snap and snap.buildHash == buildHash then
            filtered[#filtered + 1] = session
        end
    end
    return filtered
end

--- Build a personalized matchup memory card from session history.
--- @param specId number  The opponent spec ID.
--- @param sessions table  Array of all sessions (will be filtered internally).
--- @param buildHash string|nil  Optional build hash filter (T119).
--- @return table  MatchupMemoryCard.
function MatchupMemoryService:BuildMatchupMemoryCard(specId, sessions, buildHash)
    local filtered = filterBySpec(sessions, specId)
    filtered = filterByBuild(filtered, buildHash)
    local totalFights = #filtered

    -- T115: Insufficient data handling
    if totalFights < MIN_SESSIONS_FOR_FULL_CARD then
        local card = {
            specId = specId,
            totalFights = totalFights,
            insufficientData = true,
            neededSessions = MIN_SESSIONS_FOR_FULL_CARD - totalFights,
        }

        -- Fall back to generic archetype advice
        local archetypes = ns.StaticPvpData and ns.StaticPvpData.SPEC_ARCHETYPES or {}
        local archetype = archetypes[specId]
        if archetype then
            card.fallbackAdvice = {
                role = archetype.role,
                archetype = archetype.archetype or archetype.label,
                playStyle = archetype.playStyle or archetype.description,
            }
        end

        -- Still compute partial data from what we have
        if totalFights > 0 then
            local wins = 0
            for _, s in ipairs(filtered) do
                if s.result == Constants.SESSION_RESULT.WON then wins = wins + 1 end
            end
            card.winRate = Helpers.Round(wins / totalFights, 2)
            card.wins = wins
            card.losses = totalFights - wins
        end

        return card
    end

    -- Full card computation
    local wins, losses = 0, 0
    local firstGoTimings = {}
    local buildPerformance = {}
    local deathPatternCounts = {}
    local dangerSpellCounts = {}
    local results = {}

    for _, session in ipairs(filtered) do
        -- Win/loss
        local res = resultString(session)
        results[#results + 1] = res
        if res == "won" then
            wins = wins + 1
        elseif res == "lost" then
            losses = losses + 1
        end

        -- First go timing
        local castT = firstCastTiming(session)
        if castT then
            firstGoTimings[#firstGoTimings + 1] = castT
        end

        -- Build performance
        local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash
        if buildHash then
            if not buildPerformance[buildHash] then
                buildPerformance[buildHash] = { wins = 0, losses = 0, fights = 0 }
            end
            local bp = buildPerformance[buildHash]
            bp.fights = bp.fights + 1
            if res == "won" then bp.wins = bp.wins + 1
            elseif res == "lost" then bp.losses = bp.losses + 1 end
        end

        -- Death patterns
        for _, cause in ipairs(session.deathCauses or {}) do
            local key = deathPatternKey(cause)
            deathPatternCounts[key] = (deathPatternCounts[key] or 0) + 1
        end

        -- Danger spells from death causes
        for _, cause in ipairs(session.deathCauses or {}) do
            for _, dmg in ipairs(cause.recentDamage or {}) do
                if dmg.spellName then
                    dangerSpellCounts[dmg.spellName] = (dangerSpellCounts[dmg.spellName] or 0) + 1
                end
            end
        end
    end

    -- Compute common death patterns (top 3)
    local deathPatterns = {}
    for key, count in pairs(deathPatternCounts) do
        deathPatterns[#deathPatterns + 1] = { pattern = key, count = count }
    end
    table.sort(deathPatterns, function(a, b) return a.count > b.count end)
    local commonDeathPatterns = {}
    for i = 1, math.min(MAX_DEATH_PATTERNS, #deathPatterns) do
        commonDeathPatterns[#commonDeathPatterns + 1] = deathPatterns[i]
    end

    -- Average first go timing
    local avgFirstGo = nil
    if #firstGoTimings > 0 then
        local sum = 0
        for _, t in ipairs(firstGoTimings) do sum = sum + t end
        avgFirstGo = Helpers.Round(sum / #firstGoTimings, 2)
    end

    -- Best build
    local bestBuildHash, bestBuildWR = nil, 0
    for hash, bp in pairs(buildPerformance) do
        if bp.fights >= 3 then
            local wr = bp.wins / bp.fights
            if wr > bestBuildWR then
                bestBuildWR = wr
                bestBuildHash = hash
            end
        end
    end

    -- Top danger spells
    local dangerList = {}
    for spell, count in pairs(dangerSpellCounts) do
        dangerList[#dangerList + 1] = { spellName = spell, count = count }
    end
    table.sort(dangerList, function(a, b) return a.count > b.count end)
    local topDangerSpells = {}
    for i = 1, math.min(MAX_DANGER_SPELLS, #dangerList) do
        topDangerSpells[#topDangerSpells + 1] = dangerList[i]
    end

    -- Trend
    local recentTrend = computeTrend(results)

    return {
        specId = specId,
        totalFights = totalFights,
        winRate = Helpers.Round(wins / totalFights, 2),
        wins = wins,
        losses = losses,
        commonDeathPatterns = commonDeathPatterns,
        averageFirstGoTiming = avgFirstGo,
        bestBuildHash = bestBuildHash,
        bestBuildWR = bestBuildWR and Helpers.Round(bestBuildWR, 2) or nil,
        topDangerSpells = topDangerSpells,
        recentTrend = recentTrend,
        insufficientData = false,
    }
end

-- ---------------------------------------------------------------------------
-- T114: UpdateMatchupMemory
-- ---------------------------------------------------------------------------

--- Incrementally update matchup memory aggregates at session finalization.
--- @param session table  A finalized session.
function MatchupMemoryService:UpdateMatchupMemory(session)
    if not session then return end
    local opp = session.primaryOpponent
    if not opp or not opp.specId then return end
    local specId = opp.specId

    local store = ns.Addon:GetModule("CombatStore")
    if not store then return end
    local db = store:GetDB()
    if not db then return end

    db.aggregates = db.aggregates or {}
    db.aggregates.matchupMemory = db.aggregates.matchupMemory or {}

    local mem = db.aggregates.matchupMemory[specId]
    if not mem then
        mem = {
            specId = specId,
            specName = opp.specName,
            className = opp.className,
            classFile = opp.classFile,
            fights = 0,
            wins = 0,
            losses = 0,
            deathPatterns = {},
            buildPerformance = {},
            dangerSpells = {},
            recentResults = {},
        }
        db.aggregates.matchupMemory[specId] = mem
    end

    -- Update counts
    mem.fights = mem.fights + 1
    local res = resultString(session)
    if res == "won" then
        mem.wins = mem.wins + 1
    elseif res == "lost" then
        mem.losses = mem.losses + 1
    end

    -- Recent results ring buffer
    mem.recentResults[#mem.recentResults + 1] = res
    while #mem.recentResults > MAX_RECENT_RESULTS do
        table.remove(mem.recentResults, 1)
    end

    -- Death patterns ring buffer
    for _, cause in ipairs(session.deathCauses or {}) do
        local key = deathPatternKey(cause)
        mem.deathPatterns[#mem.deathPatterns + 1] = key
        while #mem.deathPatterns > MAX_DEATH_PATTERN_BUFFER do
            table.remove(mem.deathPatterns, 1)
        end
    end

    -- Build performance
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash
    if buildHash then
        if not mem.buildPerformance[buildHash] then
            mem.buildPerformance[buildHash] = { wins = 0, losses = 0, fights = 0 }
        end
        local bp = mem.buildPerformance[buildHash]
        bp.fights = bp.fights + 1
        if res == "won" then bp.wins = bp.wins + 1
        elseif res == "lost" then bp.losses = bp.losses + 1 end
    end

    -- Danger spells
    for _, cause in ipairs(session.deathCauses or {}) do
        for _, dmg in ipairs(cause.recentDamage or {}) do
            if dmg.spellName then
                mem.dangerSpells[dmg.spellName] = (mem.dangerSpells[dmg.spellName] or 0) + 1
            end
        end
    end

    -- Update metadata
    if opp.specName then mem.specName = opp.specName end
    if opp.className then mem.className = opp.className end
    if opp.classFile then mem.classFile = opp.classFile end
end

-- ---------------------------------------------------------------------------
-- Public query API
-- ---------------------------------------------------------------------------

--- Retrieve stored matchup memory aggregate for a spec.
--- @param specId number
--- @return table|nil
function MatchupMemoryService:GetStoredMemory(specId)
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return nil end
    local db = store:GetDB()
    if not db or not db.aggregates or not db.aggregates.matchupMemory then return nil end
    return db.aggregates.matchupMemory[specId]
end

--- Retrieve all stored matchup memory data.
--- @return table
function MatchupMemoryService:GetAllMemories()
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return {} end
    local db = store:GetDB()
    if not db or not db.aggregates or not db.aggregates.matchupMemory then return {} end
    return db.aggregates.matchupMemory
end

ns.Addon:RegisterModule("MatchupMemoryService", MatchupMemoryService)
