-- Insights/InsightsMatchupSummary.lua
-- Pure-logic builder for the "Matchup Plan" section of the new Insights tab.
--
-- Folds the old Strategy Spotlight + Matchup Memory cards into one summary
-- table. The UI section is a thin renderer; this module owns all of the
-- decision logic for how a matchup row is composed:
--
--   - Pick the spec name to display (opponent snapshot > guide > fallback).
--   - Cap recommended actions to the top N for the dense layout.
--   - Deduplicate CC family names.
--   - Compute win-rate text once (rounded, sign-aware).
--
-- The module is pure — no SavedVariables, no UI access. The caller is
-- expected to fetch the strategy guide via StrategyEngine.GetCounterGuide
-- (which already encapsulates CombatStore.aggregates.specs[specId]) and the
-- session payload, then pass them both in.

local _, ns = ...
ns = ns or {}

local InsightsMatchupSummary = {}

local DEFAULT_ACTION_LIMIT      = 3
local DEFAULT_TOP_SPELL_LIMIT   = 3
local DEFAULT_CC_FAMILY_LIMIT   = 4

local function safeNumber(v)
    return tonumber(v)
end

local function resolveOpponentSpecId(session)
    if type(session) ~= "table" then return nil end
    if session.primaryOpponent and session.primaryOpponent.specId then
        return safeNumber(session.primaryOpponent.specId)
    end
    return nil
end

local function resolveOpponentName(session, fallback)
    if type(session) ~= "table" then return fallback end
    local op = session.primaryOpponent
    if not op then return fallback end
    return op.name or op.specName or op.className or fallback
end

local function pickSpecLabel(guide, session, opponentName)
    if guide and guide.specName then return guide.specName end
    if opponentName then return opponentName end
    if session and session.primaryOpponent then
        return session.primaryOpponent.specName
            or session.primaryOpponent.className
            or tostring(resolveOpponentSpecId(session) or "unknown spec")
    end
    return "unknown spec"
end

local function dedupeCcFamilies(ccFamilies, limit)
    local out = {}
    if type(ccFamilies) ~= "table" then return out end
    local seen = {}
    for _, entry in ipairs(ccFamilies) do
        local name = type(entry) == "table" and entry.family or tostring(entry or "")
        if name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
            if limit and #out >= limit then break end
        end
    end
    return out
end

local function topN(list, n)
    local out = {}
    if type(list) ~= "table" then return out end
    for i, v in ipairs(list) do
        if i > n then break end
        out[i] = v
    end
    return out
end

local function buildWinRateText(guide)
    if not guide then return nil end
    local fights = safeNumber(guide.historicalFights) or 0
    local winRate = guide.historicalWinRate
    if fights == 0 or winRate == nil then return nil end
    return string.format(
        "Win rate %.0f%% across %d fight%s",
        winRate * 100, fights, fights == 1 and "" or "s"
    )
end

local function buildRecommendedActions(guide, limit)
    if not guide or type(guide.recommendedActions) ~= "table" then return {} end
    return topN(guide.recommendedActions, limit or DEFAULT_ACTION_LIMIT)
end

local function buildTopSpells(guide, limit)
    if not guide or type(guide.topSpellsFromOpponent) ~= "table" then return {} end
    return topN(guide.topSpellsFromOpponent, limit or DEFAULT_TOP_SPELL_LIMIT)
end

--- Compose a single deterministic table summarising the matchup.
--- @param session table?   finalised session (may be nil)
--- @param guide   table?   StrategyEngine.GetCounterGuide(specId, ...)
--- @param opts    table?   { actionLimit?, ccLimit?, spellLimit? }
--- @return table  matchup descriptor
function InsightsMatchupSummary.Build(session, guide, opts)
    opts = opts or {}
    local opponentName = resolveOpponentName(session, nil)
    local specId       = guide and guide.specId or resolveOpponentSpecId(session)

    local summary = {
        specId            = specId,
        specLabel         = pickSpecLabel(guide, session, opponentName),
        opponentName      = opponentName,
        archetypeLabel    = guide and guide.archetypeLabel or "unknown",
        rangeBucket       = guide and guide.rangeBucket or "unknown",
        threatScore       = guide and safeNumber(guide.baselineThreatScore) or nil,
        winRateText       = buildWinRateText(guide),
        historicalFights  = guide and safeNumber(guide.historicalFights) or 0,
        historicalWinRate = guide and guide.historicalWinRate or nil,
        ccFamilies        = dedupeCcFamilies(guide and guide.ccFamilies, opts.ccLimit or DEFAULT_CC_FAMILY_LIMIT),
        threatTags        = (guide and type(guide.threatTags) == "table") and guide.threatTags or {},
        recommendedActions = buildRecommendedActions(guide, opts.actionLimit),
        topSpells         = buildTopSpells(guide, opts.spellLimit),
        hasGuide          = guide ~= nil,
        hasData           = (guide ~= nil) or (specId ~= nil),
    }
    return summary
end

--- Convenience: returns true when we have enough data to show the section.
function InsightsMatchupSummary.HasMeaningfulData(summary)
    if type(summary) ~= "table" then return false end
    if not summary.hasGuide then return false end
    if (summary.historicalFights or 0) >= 1 then return true end
    if #(summary.recommendedActions or {}) > 0 then return true end
    if #(summary.ccFamilies or {}) > 0 then return true end
    if #(summary.threatTags or {}) > 0 then return true end
    if #(summary.topSpells or {}) > 0 then return true end
    return false
end

InsightsMatchupSummary._DEFAULT_ACTION_LIMIT    = DEFAULT_ACTION_LIMIT
InsightsMatchupSummary._DEFAULT_TOP_SPELL_LIMIT = DEFAULT_TOP_SPELL_LIMIT
InsightsMatchupSummary._DEFAULT_CC_FAMILY_LIMIT = DEFAULT_CC_FAMILY_LIMIT

ns.InsightsMatchupSummary = InsightsMatchupSummary
return InsightsMatchupSummary
