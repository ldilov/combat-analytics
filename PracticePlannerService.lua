local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local PracticePlannerService = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local MIN_SPEC_SESSIONS = 10
local WEAK_WR_THRESHOLD = 0.40
local OPENER_WEAK_WR = 0.35
local LATE_TRINKET_FREQUENCY_THRESHOLD = 0.30
local DUMMY_HIGH_VARIANCE_THRESHOLD = 0.25
local DEFENSIVE_DRIFT_FREQUENCY_THRESHOLD = 0.25
local MAX_PRACTICE_SUGGESTIONS = 10
local RECENT_SESSION_COUNT = 30

-- ---------------------------------------------------------------------------
-- Severity scoring
-- ---------------------------------------------------------------------------

local SEVERITY_SCORES = {
    high = 3,
    medium = 2,
    low = 1,
}

local function severityScore(severity)
    return SEVERITY_SCORES[severity] or 1
end

-- ---------------------------------------------------------------------------
-- Internal: Weak area detectors
-- ---------------------------------------------------------------------------

--- Detect specs with low win rate.
local function detectWeakMatchups(aggregates)
    local weakAreas = {}
    local specs = aggregates and aggregates.specs or {}
    for specId, bucket in pairs(specs) do
        if (bucket.fights or 0) >= MIN_SPEC_SESSIONS then
            local wr = bucket.fights > 0 and ((bucket.wins or 0) / bucket.fights) or 0
            if wr < WEAK_WR_THRESHOLD then
                weakAreas[#weakAreas + 1] = {
                    category = "matchup",
                    severity = wr < 0.25 and "high" or "medium",
                    title = string.format("Improve vs %s", bucket.specName or ("Spec " .. tostring(specId))),
                    action = string.format(
                        "Review your last %d losses vs %s. Focus on death patterns and pressure timing.",
                        math.min(3, bucket.losses or 0),
                        bucket.specName or "this spec"
                    ),
                    evidence = {
                        specId = specId,
                        specName = bucket.specName,
                        wins = bucket.wins or 0,
                        losses = bucket.losses or 0,
                        wrPct = Helpers.Round(wr * 100, 1),
                        fights = bucket.fights,
                    },
                    linkedMatchup = "spec:" .. tostring(specId),
                }
            end
        end
    end
    return weakAreas
end

--- Detect weak openers from opener lab aggregates.
local function detectWeakOpeners(aggregates)
    local weakAreas = {}
    local openers = aggregates and aggregates.openers or {}
    for matchupKey, openerData in pairs(openers) do
        if type(openerData) == "table" and (openerData.totalSessions or 0) >= MIN_SPEC_SESSIONS then
            local wr = openerData.totalSessions > 0
                and ((openerData.wins or 0) / openerData.totalSessions) or 0
            if wr < OPENER_WEAK_WR then
                weakAreas[#weakAreas + 1] = {
                    category = "opener",
                    severity = "medium",
                    title = string.format("Improve opener vs %s", matchupKey),
                    action = "Practice 10 opener reps on a target dummy using your current build. Focus on consistent burst.",
                    evidence = {
                        matchupKey = matchupKey,
                        wins = openerData.wins or 0,
                        totalSessions = openerData.totalSessions or 0,
                        wrPct = Helpers.Round(wr * 100, 1),
                    },
                    linkedMatchup = matchupKey,
                }
            end
        end
    end
    return weakAreas
end

--- Detect bad trinket timing from recent session suggestions.
local function detectBadTrinketTiming(recentSessions)
    local weakAreas = {}
    local lateTrinketCount = 0
    local totalWithCC = 0

    for _, session in ipairs(recentSessions or {}) do
        local hasCCEvents = false
        for _, evt in ipairs(session.timelineEvents or {}) do
            if evt.lane == Constants.TIMELINE_LANE.CC_RECEIVED then
                hasCCEvents = true
                break
            end
        end
        if hasCCEvents then
            totalWithCC = totalWithCC + 1
            for _, sug in ipairs(session.suggestions or {}) do
                if sug.reasonCode == "TRINKET_TIMING_POOR"
                    or sug.reasonCode == "CC_LATE_TRINKET" then
                    lateTrinketCount = lateTrinketCount + 1
                    break
                end
            end
        end
    end

    if totalWithCC >= 5 then
        local frequency = lateTrinketCount / totalWithCC
        if frequency > LATE_TRINKET_FREQUENCY_THRESHOLD then
            weakAreas[#weakAreas + 1] = {
                category = "cc",
                severity = frequency > 0.50 and "high" or "medium",
                title = "Improve trinket timing in CC chains",
                action = string.format(
                    "In your next 5 arena matches, save trinket for fresh CC (not diminished). Late trinkets in %.0f%% of recent matches.",
                    frequency * 100
                ),
                evidence = {
                    lateTrinketCount = lateTrinketCount,
                    totalWithCC = totalWithCC,
                    frequency = Helpers.Round(frequency * 100, 1),
                },
            }
        end
    end

    return weakAreas
end

--- Detect inconsistent dummy DPS from benchmark aggregates.
local function detectInconsistentDummy(aggregates)
    local weakAreas = {}
    local benchmarks = aggregates and aggregates.dummyBenchmarks or {}
    for buildHash, bench in pairs(benchmarks) do
        if (bench.sessions or 0) >= 5 and bench.bestDps and bench.worstDps and bench.bestDps > 0 then
            local variance = (bench.bestDps - bench.worstDps) / bench.bestDps
            if variance > DUMMY_HIGH_VARIANCE_THRESHOLD then
                weakAreas[#weakAreas + 1] = {
                    category = "rotation",
                    severity = variance > 0.40 and "high" or "medium",
                    title = "Reduce rotation variance on dummies",
                    action = string.format(
                        "Do 5 dummy pulls. Focus on minimizing gaps between casts. Variance is %.0f%% (best %.0f vs worst %.0f DPS).",
                        variance * 100,
                        bench.bestDps,
                        bench.worstDps
                    ),
                    evidence = {
                        buildHash = buildHash,
                        bestDps = bench.bestDps,
                        worstDps = bench.worstDps,
                        variance = Helpers.Round(variance * 100, 1),
                        sessions = bench.sessions,
                    },
                }
            end
        end
    end
    return weakAreas
end

--- Detect defensive drift from recent session suggestions.
local function detectDefensiveDrift(recentSessions)
    local weakAreas = {}
    local driftCount = 0
    local totalArena = 0

    for _, session in ipairs(recentSessions or {}) do
        if session.context == Constants.CONTEXT.ARENA then
            totalArena = totalArena + 1
            for _, sug in ipairs(session.suggestions or {}) do
                if sug.reasonCode == "DEFENSIVE_DRIFT"
                    or sug.reasonCode == "REACTIVE_DEFENSIVE_LATE" then
                    driftCount = driftCount + 1
                    break
                end
            end
        end
    end

    if totalArena >= 5 then
        local frequency = driftCount / totalArena
        if frequency > DEFENSIVE_DRIFT_FREQUENCY_THRESHOLD then
            weakAreas[#weakAreas + 1] = {
                category = "defensive",
                severity = "medium",
                title = "Improve defensive cooldown timing",
                action = string.format(
                    "In your next 5 arena matches, use defensives within 1s of CC break. Late defensives in %.0f%% of recent arena matches.",
                    frequency * 100
                ),
                evidence = {
                    driftCount = driftCount,
                    totalArena = totalArena,
                    frequency = Helpers.Round(frequency * 100, 1),
                },
            }
        end
    end

    return weakAreas
end

-- ---------------------------------------------------------------------------
-- T110: GetWeakAreas — raw weak area list
-- ---------------------------------------------------------------------------

--- Identify all weak areas from aggregates and recent sessions.
--- @param aggregates table  The db.aggregates table.
--- @param recentSessions table  Array of recent sessions (last 20-50).
--- @return table  Array of raw weak area entries.
function PracticePlannerService:GetWeakAreas(aggregates, recentSessions)
    local areas = {}

    local matchupAreas = detectWeakMatchups(aggregates)
    for _, a in ipairs(matchupAreas) do areas[#areas + 1] = a end

    local openerAreas = detectWeakOpeners(aggregates)
    for _, a in ipairs(openerAreas) do areas[#areas + 1] = a end

    local trinketAreas = detectBadTrinketTiming(recentSessions)
    for _, a in ipairs(trinketAreas) do areas[#areas + 1] = a end

    local dummyAreas = detectInconsistentDummy(aggregates)
    for _, a in ipairs(dummyAreas) do areas[#areas + 1] = a end

    local defensiveAreas = detectDefensiveDrift(recentSessions)
    for _, a in ipairs(defensiveAreas) do areas[#areas + 1] = a end

    return areas
end

-- ---------------------------------------------------------------------------
-- T111: GeneratePracticePlan — sorted, capped suggestions
-- ---------------------------------------------------------------------------

--- Generate a practice plan from weak areas analysis.
--- @param aggregates table  The db.aggregates table.
--- @param recentSessions table  Array of recent sessions.
--- @return table  Array of PracticeSuggestion, sorted by severity (highest first).
function PracticePlannerService:GeneratePracticePlan(aggregates, recentSessions)
    local areas = self:GetWeakAreas(aggregates or {}, recentSessions or {})

    -- Sort by severity descending
    table.sort(areas, function(a, b)
        return severityScore(a.severity) > severityScore(b.severity)
    end)

    -- Cap at MAX_PRACTICE_SUGGESTIONS
    local plan = {}
    for i = 1, math.min(#areas, MAX_PRACTICE_SUGGESTIONS) do
        local area = areas[i]
        plan[#plan + 1] = {
            category = area.category,
            severity = area.severity,
            title = area.title,
            action = area.action,
            evidence = area.evidence,
            linkedMatchup = area.linkedMatchup,
            linkedSessions = area.linkedSessions,
        }
    end

    return plan
end

ns.Addon:RegisterModule("PracticePlannerService", PracticePlannerService)
