-- Insights/InsightsPriority.lua
-- Pure-logic priority scoring for the Insights tab.
--
-- Scores each emitted suggestion so the Next Queue Focus card can surface a
-- single highest-impact recommendation. The formula is published and every
-- component is preserved so the UI can show it on hover (mitigation M5 from
-- the Insights redesign plan):
--
--   priority = severity * confidence * recurrenceWeight * controllability
--
--   severity         0..1   from suggestion.severity ("high"=1.0, "medium"=0.55, "low"=0.2)
--   confidence       0..1   from suggestion.confidence, else fall back to 0.6
--   recurrenceWeight 1..3   1 + 0.5 * min(occurrences_last_7d, 4)
--   controllability  0..1   static lookup ns.Constants.CONTROLLABILITY[reasonCode]
--
-- This module reads only its arguments. It does not touch SavedVariables and
-- has no side effects, which keeps it cheap to unit-test in isolation.

local _, ns = ...
ns = ns or {}

local InsightsPriority = {}

-- Severity -> base weight. Mirrors the SEVERITY_FILL table used by the
-- existing SuggestionsView so visual severity and numeric severity agree.
local SEVERITY_VALUE = {
    high   = 1.0,
    medium = 0.55,
    low    = 0.2,
}

local DEFAULT_CONFIDENCE      = 0.6
local DEFAULT_CONTROLLABILITY = 0.5
local RECURRENCE_CAP          = 4
local RECURRENCE_STEP         = 0.5

local function severityValue(severity)
    return SEVERITY_VALUE[severity or "medium"] or SEVERITY_VALUE.medium
end

local function clamp01(v)
    if type(v) ~= "number" then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function controllabilityFor(reasonCode)
    local C = ns.Constants and ns.Constants.CONTROLLABILITY
    if not C then return DEFAULT_CONTROLLABILITY end
    local v = C[reasonCode]
    if type(v) == "number" then return v end
    return DEFAULT_CONTROLLABILITY
end

local function recurrenceWeight(count)
    local n = tonumber(count) or 0
    if n < 0 then n = 0 end
    if n > RECURRENCE_CAP then n = RECURRENCE_CAP end
    return 1 + RECURRENCE_STEP * n
end

--- Compute a priority breakdown for a single suggestion.
---
--- Recurrence resolution order:
---   1. recurrenceMap[reasonCode]   — explicit map passed in by caller
---   2. suggestion.recurrenceCount  — pre-baked count attached by SuggestionEngine
---   3. 0                            — no recurrence data → weight 1.0
---
--- @param suggestion    table   { reasonCode, severity, confidence?, recurrenceCount?, ... }
--- @param recurrenceMap table?  optional map of reasonCode -> occurrences in last 7d
--- @return table  { priority, severity, confidence, recurrenceWeight, controllability, reasonCode }
function InsightsPriority.Score(suggestion, recurrenceMap)
    if type(suggestion) ~= "table" then
        return {
            priority         = 0,
            severity         = 0,
            confidence       = 0,
            recurrenceWeight = 1,
            controllability  = DEFAULT_CONTROLLABILITY,
            reasonCode       = nil,
        }
    end

    local sev   = severityValue(suggestion.severity)
    local conf  = clamp01(suggestion.confidence) or DEFAULT_CONFIDENCE
    local rcode = suggestion.reasonCode

    local count = 0
    if recurrenceMap and rcode and recurrenceMap[rcode] ~= nil then
        -- Explicit map entry wins, even if the count is 0.
        count = tonumber(recurrenceMap[rcode]) or 0
    else
        count = tonumber(suggestion.recurrenceCount) or 0
    end

    local recur = recurrenceWeight(count)
    local ctrl  = controllabilityFor(rcode)
    local priority = sev * conf * recur * ctrl

    return {
        priority         = priority,
        severity         = sev,
        confidence       = conf,
        recurrenceWeight = recur,
        controllability  = ctrl,
        reasonCode       = rcode,
    }
end

--- Rank a list of suggestions. Higher priority first. Stable for equal scores.
---
--- The returned list does NOT mutate the input. Each entry is
---   { suggestion = <original>, scoring = <breakdown> }
--- so the caller can render the original payload but show the breakdown on
--- hover.
---
--- @param suggestions   table   list of suggestion tables
--- @param recurrenceMap table?  optional reasonCode -> count map
--- @return table  list of { suggestion, scoring }, highest priority first
function InsightsPriority.Rank(suggestions, recurrenceMap)
    local out = {}
    if type(suggestions) ~= "table" then return out end

    for i, s in ipairs(suggestions) do
        out[i] = {
            suggestion  = s,
            scoring     = InsightsPriority.Score(s, recurrenceMap),
            _stableIdx  = i,
        }
    end

    table.sort(out, function(a, b)
        if a.scoring.priority == b.scoring.priority then
            return a._stableIdx < b._stableIdx
        end
        return a.scoring.priority > b.scoring.priority
    end)

    for _, entry in ipairs(out) do
        entry._stableIdx = nil
    end
    return out
end

--- Convenience: return only the top-ranked suggestion + scoring, or nil.
function InsightsPriority.Top(suggestions, recurrenceMap)
    local ranked = InsightsPriority.Rank(suggestions, recurrenceMap)
    return ranked[1]
end

-- Expose constants so tests + UI hover can introspect formula behaviour.
InsightsPriority._SEVERITY_VALUE        = SEVERITY_VALUE
InsightsPriority._DEFAULT_CONFIDENCE    = DEFAULT_CONFIDENCE
InsightsPriority._DEFAULT_CONTROLLABILITY = DEFAULT_CONTROLLABILITY
InsightsPriority._RECURRENCE_CAP        = RECURRENCE_CAP
InsightsPriority._RECURRENCE_STEP       = RECURRENCE_STEP

ns.InsightsPriority = InsightsPriority
return InsightsPriority
