-- Insights/InsightsEvidenceFilter.lua
-- Pure-logic filter for the "Evidence Drawer" section of the new Insights
-- tab. Maps reason codes to filter chips (Offense / Defense / CC / Matchup
-- / Consistency / Meta) and provides a deterministic per-chip filter.
--
-- The Evidence Drawer is the "show me everything" surface — full
-- session.suggestions[] dump — so this module keeps the chip routing in
-- one place rather than scattering string checks across the renderer.

local _, ns = ...
ns = ns or {}

local InsightsEvidenceFilter = {}

local CHIP = {
    ALL          = "all",
    OFFENSE      = "offense",
    DEFENSE      = "defense",
    CC           = "cc",
    MATCHUP      = "matchup",
    CONSISTENCY  = "consistency",
    META         = "meta",
}

local CHIP_ORDER = {
    CHIP.ALL,
    CHIP.OFFENSE,
    CHIP.DEFENSE,
    CHIP.CC,
    CHIP.MATCHUP,
    CHIP.CONSISTENCY,
    CHIP.META,
}

local CHIP_LABEL = {
    [CHIP.ALL]         = "All",
    [CHIP.OFFENSE]     = "Offense",
    [CHIP.DEFENSE]     = "Defense",
    [CHIP.CC]          = "CC",
    [CHIP.MATCHUP]     = "Matchup",
    [CHIP.CONSISTENCY] = "Consistency",
    [CHIP.META]        = "Meta",
}

local REASON_TO_CHIP = {
    LOW_PRESSURE_VS_BUILD_BASELINE = CHIP.OFFENSE,
    WEAK_BURST_FOR_CONTEXT         = CHIP.OFFENSE,
    LATE_FIRST_GO                  = CHIP.OFFENSE,
    SUBOPTIMAL_OPENER_SEQUENCE     = CHIP.OFFENSE,
    LOW_HEALER_PRESSURE            = CHIP.OFFENSE,
    DUMMY_OPENER_VARIANCE          = CHIP.OFFENSE,
    DUMMY_SUSTAINED_VARIANCE       = CHIP.OFFENSE,
    PROC_WINDOWS_UNDERUSED         = CHIP.OFFENSE,

    DEFENSIVE_UNUSED_ON_LOSS       = CHIP.DEFENSE,
    DEFENSIVE_DRIFT                = CHIP.DEFENSE,
    DIED_IN_CC                     = CHIP.DEFENSE,
    DIED_WITH_DEFENSIVES           = CHIP.DEFENSE,
    REACTIVE_DEFENSIVE_LATE        = CHIP.DEFENSE,
    HIGH_DAMAGE_TAKEN_VS_OPPONENT  = CHIP.DEFENSE,

    TRINKET_TIMING_POOR            = CHIP.CC,
    HIGH_CC_UPTIME                 = CHIP.CC,
    POOR_INTERRUPT_RATE            = CHIP.CC,
    CC_DR_WASTE                    = CHIP.CC,
    CC_LATE_TRINKET                = CHIP.CC,
    CC_MISSED_KILL_WINDOW          = CHIP.CC,
    CC_GOOD_TRINKET                = CHIP.CC,
    CC_CHAIN_BREAK                 = CHIP.CC,
    CC_HIGH_UPTIME                 = CHIP.CC,

    SPEC_WINRATE_DEFICIT           = CHIP.MATCHUP,
    SPEC_WINRATE_STRENGTH          = CHIP.MATCHUP,
    COMP_DEFICIT                   = CHIP.MATCHUP,

    ROTATION_GAPS_OBSERVED         = CHIP.CONSISTENCY,
    TILT_WARNING                   = CHIP.CONSISTENCY,

    MIDNIGHT_SAFE_LIMITS           = CHIP.META,
    RAW_EVENT_OVERFLOW             = CHIP.META,
}

local function safeReason(s)
    return type(s) == "table" and type(s.reasonCode) == "string" and s.reasonCode or nil
end

--- Return the chip key for a given reason code, or CHIP.META as fallback.
function InsightsEvidenceFilter.GetChipForReason(reasonCode)
    if type(reasonCode) ~= "string" then return CHIP.META end
    return REASON_TO_CHIP[reasonCode] or CHIP.META
end

--- Count how many suggestions land in each chip. Returns a map keyed by
--- chip plus a `total` entry for convenience.
function InsightsEvidenceFilter.CountByChip(suggestions)
    local counts = { total = 0 }
    for _, chip in ipairs(CHIP_ORDER) do counts[chip] = 0 end
    if type(suggestions) ~= "table" then return counts end

    for _, s in ipairs(suggestions) do
        local rc = safeReason(s)
        if rc then
            counts.total = counts.total + 1
            local chip = REASON_TO_CHIP[rc] or CHIP.META
            counts[chip] = (counts[chip] or 0) + 1
        end
    end
    counts[CHIP.ALL] = counts.total
    return counts
end

--- Filter a suggestions list to a single chip. `chip == CHIP.ALL` passes all
--- entries through. Returns a NEW list; the input is not mutated.
function InsightsEvidenceFilter.FilterByChip(suggestions, chip)
    local out = {}
    if type(suggestions) ~= "table" then return out end
    if chip == nil or chip == CHIP.ALL then
        for i, s in ipairs(suggestions) do out[i] = s end
        return out
    end
    for _, s in ipairs(suggestions) do
        local rc = safeReason(s)
        local mapped = rc and (REASON_TO_CHIP[rc] or CHIP.META) or CHIP.META
        if mapped == chip then
            out[#out + 1] = s
        end
    end
    return out
end

InsightsEvidenceFilter.CHIP        = CHIP
InsightsEvidenceFilter.CHIP_ORDER  = CHIP_ORDER
InsightsEvidenceFilter.CHIP_LABEL  = CHIP_LABEL
InsightsEvidenceFilter._REASON_MAP = REASON_TO_CHIP

ns.InsightsEvidenceFilter = InsightsEvidenceFilter
return InsightsEvidenceFilter
