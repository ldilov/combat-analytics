-- Insights/InsightsPillarMapper.lua
-- Pure-logic mapper that consolidates the 30 reason codes into 4 pillars
-- (Pressure / Survival / Control / Consistency) used by the new Insights tab.
--
-- The pillars solve a UX complaint: a flat list of 8 cards drove the old
-- view, with no grouping. Pillars give the user a glanceable scoreboard
-- while still preserving the underlying reason codes one click away
-- (mitigation M1 from the redesign plan).
--
-- This module is pure — no SavedVariables access, no UI, no side effects.
-- It exposes:
--   * PILLARS                — ordered list of pillar keys, for stable UI
--   * GetPillarForReason()   — single-code lookup
--   * Bucket(suggestions)    — group a session's suggestions into pillars
--   * PillarValue(session, pillarKey) — pull the scalar metric for the
--                              pillar column from session.metrics
--
-- Matchup-flavoured codes (SPEC_WINRATE_*, COMP_DEFICIT, etc.) and
-- meta-codes (MIDNIGHT_SAFE_LIMITS, RAW_EVENT_OVERFLOW) intentionally
-- return nil so the caller can route them to the Matchup Plan section
-- and the Fidelity badge respectively.

local _, ns = ...
ns = ns or {}

local InsightsPillarMapper = {}

-- Canonical pillar keys. Lowercase string literals so they round-trip cleanly
-- through SavedVariables, telemetry, and SetText calls.
local PILLAR = {
    PRESSURE    = "pressure",
    SURVIVAL    = "survival",
    CONTROL     = "control",
    CONSISTENCY = "consistency",
}

-- Display order for the scoreboard left-to-right.
local PILLARS = {
    PILLAR.PRESSURE,
    PILLAR.SURVIVAL,
    PILLAR.CONTROL,
    PILLAR.CONSISTENCY,
}

-- Mapping table. Update here when a new reason code is introduced.
local REASON_TO_PILLAR = {
    -- Pressure: output / opener / proc execution
    LOW_PRESSURE_VS_BUILD_BASELINE = PILLAR.PRESSURE,
    WEAK_BURST_FOR_CONTEXT         = PILLAR.PRESSURE,
    LATE_FIRST_GO                  = PILLAR.PRESSURE,
    SUBOPTIMAL_OPENER_SEQUENCE     = PILLAR.PRESSURE,
    LOW_HEALER_PRESSURE            = PILLAR.PRESSURE,
    DUMMY_OPENER_VARIANCE          = PILLAR.PRESSURE,
    DUMMY_SUSTAINED_VARIANCE       = PILLAR.PRESSURE,
    PROC_WINDOWS_UNDERUSED         = PILLAR.PRESSURE,
    -- Survival: defensives, damage taken, deaths
    DEFENSIVE_UNUSED_ON_LOSS       = PILLAR.SURVIVAL,
    DEFENSIVE_DRIFT                = PILLAR.SURVIVAL,
    DIED_IN_CC                     = PILLAR.SURVIVAL,
    DIED_WITH_DEFENSIVES           = PILLAR.SURVIVAL,
    REACTIVE_DEFENSIVE_LATE        = PILLAR.SURVIVAL,
    HIGH_DAMAGE_TAKEN_VS_OPPONENT  = PILLAR.SURVIVAL,
    -- Control: CC, interrupts, trinket, DRs
    TRINKET_TIMING_POOR            = PILLAR.CONTROL,
    HIGH_CC_UPTIME                 = PILLAR.CONTROL,
    POOR_INTERRUPT_RATE            = PILLAR.CONTROL,
    CC_DR_WASTE                    = PILLAR.CONTROL,
    CC_LATE_TRINKET                = PILLAR.CONTROL,
    CC_MISSED_KILL_WINDOW          = PILLAR.CONTROL,
    CC_GOOD_TRINKET                = PILLAR.CONTROL,
    CC_CHAIN_BREAK                 = PILLAR.CONTROL,
    CC_HIGH_UPTIME                 = PILLAR.CONTROL,
    -- Consistency: rotation regularity, tilt detection
    ROTATION_GAPS_OBSERVED         = PILLAR.CONSISTENCY,
    TILT_WARNING                   = PILLAR.CONSISTENCY,
}

-- Metric-key map: which session.metrics field drives the pillar's main value.
local PILLAR_METRIC_KEY = {
    [PILLAR.PRESSURE]    = "pressureScore",
    [PILLAR.SURVIVAL]    = "survivabilityScore",
    [PILLAR.CONTROL]     = "ccControlScore",        -- may be nil on older sessions
    [PILLAR.CONSISTENCY] = "rotationConsistencyScore",
}

-- Human-readable labels, lowercase title case for the UI.
local PILLAR_LABEL = {
    [PILLAR.PRESSURE]    = "Pressure",
    [PILLAR.SURVIVAL]    = "Survival",
    [PILLAR.CONTROL]     = "Control",
    [PILLAR.CONSISTENCY] = "Consistency",
}

--- Return the pillar key for a given reason code, or nil when the code is
--- matchup- or meta-flavoured and should not appear in the scoreboard.
function InsightsPillarMapper.GetPillarForReason(reasonCode)
    if type(reasonCode) ~= "string" then return nil end
    return REASON_TO_PILLAR[reasonCode]
end

--- Bucket a list of suggestions into pillar groups.
--- Returns:
---   buckets[pillarKey] = { suggestion, suggestion, ... }
---   unbucketed         = { suggestion, ... }   -- matchup + meta codes
function InsightsPillarMapper.Bucket(suggestions)
    local buckets = {
        [PILLAR.PRESSURE]    = {},
        [PILLAR.SURVIVAL]    = {},
        [PILLAR.CONTROL]     = {},
        [PILLAR.CONSISTENCY] = {},
    }
    local unbucketed = {}
    if type(suggestions) ~= "table" then
        return buckets, unbucketed
    end
    for _, s in ipairs(suggestions) do
        local pillar = s and s.reasonCode and REASON_TO_PILLAR[s.reasonCode] or nil
        if pillar then
            local list = buckets[pillar]
            list[#list + 1] = s
        else
            unbucketed[#unbucketed + 1] = s
        end
    end
    return buckets, unbucketed
end

--- Pull the scalar metric value for a pillar column. Returns nil when the
--- session lacks the metric (e.g., very old session before ccControlScore
--- was added). The UI is expected to render an "—" state in that case.
function InsightsPillarMapper.PillarValue(session, pillarKey)
    if type(session) ~= "table" or not session.metrics then return nil end
    local key = PILLAR_METRIC_KEY[pillarKey]
    if not key then return nil end
    return tonumber(session.metrics[key])
end

--- Convenience: return the metric key driving a pillar.
function InsightsPillarMapper.GetMetricKey(pillarKey)
    return PILLAR_METRIC_KEY[pillarKey]
end

--- Convenience: pretty label for a pillar key.
function InsightsPillarMapper.GetLabel(pillarKey)
    return PILLAR_LABEL[pillarKey]
end

InsightsPillarMapper.PILLAR             = PILLAR
InsightsPillarMapper.PILLARS            = PILLARS
InsightsPillarMapper._REASON_TO_PILLAR  = REASON_TO_PILLAR
InsightsPillarMapper._PILLAR_METRIC_KEY = PILLAR_METRIC_KEY

ns.InsightsPillarMapper = InsightsPillarMapper
return InsightsPillarMapper
