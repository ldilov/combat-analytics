local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local DuelLabService = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local MAX_RECENT_RESULTS = 20
local TREND_WINDOW = 5
local MIN_DUELS_FOR_TREND = 10

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build an opponent key from a session's primaryOpponent.
--- Prefers GUID for stability; falls back to name.
local function opponentKey(session)
    local opp = session and session.primaryOpponent
    if not opp then return nil end
    if opp.guid and opp.guid ~= "" then return opp.guid end
    if opp.name and opp.name ~= "" then return opp.name end
    return nil
end

--- Determine if the session is a duel.
local function isDuel(session)
    return session and session.context == Constants.CONTEXT.DUEL
end

--- Compute adaptation trend from an ordered result list.
--- Compares WR of the first TREND_WINDOW results to the last TREND_WINDOW.
--- Returns "improving", "declining", or "stable".
local function computeTrend(results)
    if #results < MIN_DUELS_FOR_TREND then
        return "insufficient_data"
    end
    local firstWins, lastWins = 0, 0
    local window = math.min(TREND_WINDOW, math.floor(#results / 2))
    for i = 1, window do
        if results[i] == "won" then firstWins = firstWins + 1 end
    end
    for i = #results - window + 1, #results do
        if results[i] == "won" then lastWins = lastWins + 1 end
    end
    local firstWR = firstWins / window
    local lastWR = lastWins / window
    local delta = lastWR - firstWR
    if delta > 0.15 then return "improving" end
    if delta < -0.15 then return "declining" end
    return "stable"
end

--- Extract first player_cast timestamp from timeline events.
local function firstCastOffset(session)
    for _, evt in ipairs(session.timelineEvents or {}) do
        if evt.lane == Constants.TIMELINE_LANE.PLAYER_CAST then
            return evt.t or evt.offset or evt.timestampOffset or 0
        end
    end
    return nil
end

--- Determine if player dealt damage first (opener advantage).
local function hadOpenerAdvantage(session)
    local castT = firstCastOffset(session)
    return castT ~= nil and castT < 3.0
end

--- Map session.result to a simple string.
local function resultString(session)
    local r = session.result
    if r == Constants.SESSION_RESULT.WON then return "won" end
    if r == Constants.SESSION_RESULT.LOST then return "lost" end
    return "draw"
end

-- ---------------------------------------------------------------------------
-- T107: GroupDuelsByOpponent
-- ---------------------------------------------------------------------------

--- Group duel sessions by opponent, computing per-opponent analytics.
--- @param sessions table  Array of all sessions.
--- @return table  Keyed by opponentKey.
function DuelLabService:GroupDuelsByOpponent(sessions)
    local groups = {}

    for _, session in ipairs(sessions or {}) do
        if isDuel(session) then
            local key = opponentKey(session)
            if key then
                if not groups[key] then
                    local opp = session.primaryOpponent or {}
                    groups[key] = {
                        opponentKey = key,
                        opponentName = opp.name or "Unknown",
                        opponentClass = opp.classFile or opp.className or "UNKNOWN",
                        opponentSpec = opp.specName,
                        setScore = { wins = 0, losses = 0, draws = 0 },
                        totalDuration = 0,
                        openerSuccessCount = 0,
                        firstGoTimings = {},
                        results = {},
                        totalDuels = 0,
                        sessions = {},
                    }
                end
                local g = groups[key]
                g.totalDuels = g.totalDuels + 1
                g.sessions[#g.sessions + 1] = session.id

                -- Set score
                local res = resultString(session)
                g.results[#g.results + 1] = res
                if res == "won" then
                    g.setScore.wins = g.setScore.wins + 1
                elseif res == "lost" then
                    g.setScore.losses = g.setScore.losses + 1
                else
                    g.setScore.draws = g.setScore.draws + 1
                end

                -- Duration
                g.totalDuration = g.totalDuration + (session.duration or 0)

                -- Opener advantage
                if hadOpenerAdvantage(session) then
                    g.openerSuccessCount = g.openerSuccessCount + 1
                end

                -- First major go timing
                local castT = firstCastOffset(session)
                if castT then
                    g.firstGoTimings[#g.firstGoTimings + 1] = castT
                end
            end
        end
    end

    -- Compute derived fields
    for _, g in pairs(groups) do
        g.averageDuration = g.totalDuels > 0 and (g.totalDuration / g.totalDuels) or 0

        g.openerSuccessRate = g.totalDuels > 0
            and Helpers.Round(g.openerSuccessCount / g.totalDuels, 2) or 0

        if #g.firstGoTimings > 0 then
            local sum = 0
            for _, t in ipairs(g.firstGoTimings) do sum = sum + t end
            g.firstMajorGoTiming = Helpers.Round(sum / #g.firstGoTimings, 2)
        else
            g.firstMajorGoTiming = nil
        end

        g.adaptationTrend = computeTrend(g.results)

        -- Clean up working fields
        g.totalDuration = nil
        g.openerSuccessCount = nil
        g.firstGoTimings = nil
    end

    return groups
end

-- ---------------------------------------------------------------------------
-- T108: UpdateDuelSeriesAggregates
-- ---------------------------------------------------------------------------

--- Incrementally update duel series aggregates at session finalization.
--- @param session table  A finalized duel session.
function DuelLabService:UpdateDuelSeriesAggregates(session)
    if not isDuel(session) then return end
    local key = opponentKey(session)
    if not key then return end

    local store = ns.Addon:GetModule("CombatStore")
    if not store then return end
    local db = store:GetDB()
    if not db then return end

    db.aggregates = db.aggregates or {}
    db.aggregates.duelSeries = db.aggregates.duelSeries or {}

    local series = db.aggregates.duelSeries[key]
    if not series then
        local opp = session.primaryOpponent or {}
        series = {
            opponentKey = key,
            opponentName = opp.name or "Unknown",
            opponentClass = opp.classFile or "UNKNOWN",
            opponentSpec = opp.specName,
            totalDuels = 0,
            wins = 0,
            losses = 0,
            draws = 0,
            totalDuration = 0,
            recentResults = {},
            lastPlayed = 0,
        }
        db.aggregates.duelSeries[key] = series
    end

    series.totalDuels = series.totalDuels + 1
    series.totalDuration = series.totalDuration + (session.duration or 0)

    local res = resultString(session)
    if res == "won" then
        series.wins = series.wins + 1
    elseif res == "lost" then
        series.losses = series.losses + 1
    else
        series.draws = series.draws + 1
    end

    -- Ring buffer of recent results
    series.recentResults[#series.recentResults + 1] = res
    while #series.recentResults > MAX_RECENT_RESULTS do
        table.remove(series.recentResults, 1)
    end

    series.lastPlayed = session.endTime or os.time()

    -- Update name/spec if newer data available
    local opp = session.primaryOpponent or {}
    if opp.name then series.opponentName = opp.name end
    if opp.specName then series.opponentSpec = opp.specName end
end

-- ---------------------------------------------------------------------------
-- Public query API
-- ---------------------------------------------------------------------------

--- Retrieve stored aggregate for a specific opponent.
--- @param opponentKeyStr string  The opponent key (GUID or name).
--- @return table|nil
function DuelLabService:GetDuelSeries(opponentKeyStr)
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return nil end
    local db = store:GetDB()
    if not db or not db.aggregates or not db.aggregates.duelSeries then return nil end
    return db.aggregates.duelSeries[opponentKeyStr]
end

--- Retrieve all stored duel series aggregates.
--- @return table  Full duelSeries table (may be empty).
function DuelLabService:GetAllSeries()
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return {} end
    local db = store:GetDB()
    if not db or not db.aggregates or not db.aggregates.duelSeries then return {} end
    return db.aggregates.duelSeries
end

ns.Addon:RegisterModule("DuelLabService", DuelLabService)
