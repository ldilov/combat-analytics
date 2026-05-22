-- Insights/InsightsOnboarding.lua
-- Pure-logic onboarding-state classifier for the Insights tab.
--
-- Solves the new-player wall-of-N/A complaint raised during the debate gate
-- (mitigation M3). For every section of the new Insights view, the UI must
-- be able to ask "do I have enough data to render this, or should I show a
-- guided onboarding state?".
--
-- States:
--   "cold"    — 0 sessions for the character. Pillars and Practice Plan
--               must be hidden. Next Queue Focus shows a static guide.
--   "sparse"  — 1..(threshold-1) sessions. Pillars show absolute values
--               with dummyBenchmark deltas only (no personal baseline).
--               Trends Peek is hidden; Practice Plan falls back to a single
--               "play a few more sessions" placeholder.
--   "full"    — sessions >= threshold. Every section renders normally.
--
-- The threshold defaults to 3 but can be overridden through
-- ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD so it can be tuned later
-- without touching this file.
--
-- This module is intentionally side-effect free; it accepts the session
-- count as an argument and returns a string. The caller is responsible
-- for resolving the count from CombatStore.

local _, ns = ...
ns = ns or {}

local InsightsOnboarding = {}

local STATE = {
    COLD   = "cold",
    SPARSE = "sparse",
    FULL   = "full",
}

local DEFAULT_THRESHOLD = 3

local function threshold()
    local v = ns.Constants and tonumber(ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD)
    if v and v > 0 then return v end
    return DEFAULT_THRESHOLD
end

--- Classify a character's onboarding state from its stored session count.
--- @param sessionCount number  number of stored sessions for the character
--- @return string  one of "cold" | "sparse" | "full"
function InsightsOnboarding.Classify(sessionCount)
    local n = tonumber(sessionCount) or 0
    if n <= 0 then return STATE.COLD end
    if n < threshold() then return STATE.SPARSE end
    return STATE.FULL
end

--- Returns a section-visibility map for the given onboarding state.
--- The Insights UI calls this once per refresh and toggles each section's
--- visibility from the result.
---
--- Adding a new section is a one-line change here; the UI does not need
--- a parallel switch table.
function InsightsOnboarding.SectionVisibility(state)
    if state == STATE.COLD then
        return {
            fidelityBar         = true,
            nextQueueFocus      = true,    -- shows static guide
            fightTimelineRead   = false,
            pillarScoreboard    = false,
            matchupPlan         = false,
            trendsPeek          = false,
            practicePlan        = false,
            evidenceDrawer      = false,
        }
    elseif state == STATE.SPARSE then
        return {
            fidelityBar         = true,
            nextQueueFocus      = true,
            fightTimelineRead   = true,
            pillarScoreboard    = true,    -- absolute values, no personal delta
            matchupPlan         = false,
            trendsPeek          = false,
            practicePlan        = true,    -- shows "more data needed" stub
            evidenceDrawer      = true,
        }
    else
        return {
            fidelityBar         = true,
            nextQueueFocus      = true,
            fightTimelineRead   = true,
            pillarScoreboard    = true,
            matchupPlan         = true,
            trendsPeek          = true,
            practicePlan        = true,
            evidenceDrawer      = true,
        }
    end
end

--- Returns a human-readable headline that the UI can show under the
--- Fidelity Bar when the character is not yet at the full state.
--- Returns nil for the full state — the UI should skip the banner.
function InsightsOnboarding.OnboardingMessage(state)
    if state == STATE.COLD then
        return "No sessions stored yet for this character. Play any PvP match or use a dummy benchmark to unlock the dashboard."
    elseif state == STATE.SPARSE then
        return "Collecting data — play a few more sessions to unlock matchup memory, trends, and personal-baseline deltas."
    end
    return nil
end

InsightsOnboarding.STATE             = STATE
InsightsOnboarding.DEFAULT_THRESHOLD = DEFAULT_THRESHOLD

ns.InsightsOnboarding = InsightsOnboarding
return InsightsOnboarding
