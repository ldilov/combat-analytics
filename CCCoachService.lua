local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local CCCoachService = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local TRINKET_SPELL_ID = 42292
local LANE = Constants.TIMELINE_LANE

-- DR decay timer: standard WoW DR resets after 18 seconds of no re-application.
local DR_RESET_SECONDS = 18.0

-- Thresholds for insight generation.
local LATE_TRINKET_THRESHOLD_SECONDS = 1.0
local HIGH_CC_UPTIME_THRESHOLD = 0.25
local TRINKET_FULL_DR_REMAINING_THRESHOLD = 3.0
local KILL_WINDOW_FOLLOW_UP_MAX_SECONDS = 5.0
local KILL_WINDOW_CORRELATION_SECONDS = 2.0

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Collect all timeline events matching a given lane, sorted by timestamp.
--- Returns a new table (no mutation of session.timelineEvents).
local function collectLaneEvents(session, lane)
    local results = {}
    for _, event in ipairs(session.timelineEvents or {}) do
        if event.lane == lane then
            results[#results + 1] = event
        end
    end
    table.sort(results, function(a, b)
        return (a.t or 0) < (b.t or 0)
    end)
    return results
end

--- Collect player_cast events matching a specific spellId.
local function collectCastsBySpellId(session, spellId)
    local results = {}
    for _, event in ipairs(session.timelineEvents or {}) do
        if event.lane == LANE.PLAYER_CAST and event.spellId == spellId then
            results[#results + 1] = event
        end
    end
    table.sort(results, function(a, b)
        return (a.t or 0) < (b.t or 0)
    end)
    return results
end

--- Determine the DR level label for a given application count within a chain.
--- WoW DR: 1st = full (100%), 2nd = half (50%), 3rd = quarter (25%), 4th+ = immune (0%).
local function drLevelForCount(count)
    if count <= 1 then return 1.0 end
    if count == 2 then return 0.5 end
    if count == 3 then return 0.25 end
    return 0.0
end

--- Check whether a DR level represents a wasted application (50% or immune).
local function isDRWaste(drLevel)
    return drLevel ~= nil and drLevel <= 0.5
end

-- ---------------------------------------------------------------------------
-- T097: AnalyzeCCChains
-- ---------------------------------------------------------------------------

--- Analyze CC chains and DR waste from timeline events.
--- Groups CC events by DR category, computes chain length, DR waste,
--- total CC duration, and trinket timing.
---
--- @param session table  A finalized session with timelineEvents and duration.
--- @return table ccAnalysis  Structured analysis result.
function CCCoachService:AnalyzeCCChains(session)
    if not session or not session.timelineEvents then
        return {
            chains = {},
            trinketUsages = {},
            totalCCUptime = 0,
            totalDRWaste = 0,
            ccUptimePct = 0,
        }
    end

    local ccEvents = collectLaneEvents(session, LANE.CC_RECEIVED)
    local drEvents = collectLaneEvents(session, LANE.DR_UPDATE)
    local trinketCasts = collectCastsBySpellId(session, TRINKET_SPELL_ID)

    -- Build a lookup of DR category by timestamp range from dr_update events.
    -- Each dr_update carries meta.category and meta.isImmune.
    -- We use these to enrich cc_received events that may lack category info.
    local drSnapshots = {}
    for _, drEvt in ipairs(drEvents) do
        local meta = drEvt.meta or {}
        if meta.category then
            drSnapshots[#drSnapshots + 1] = {
                t = drEvt.t or 0,
                category = meta.category,
                isImmune = meta.isImmune,
                duration = meta.duration,
                startTime = meta.startTime,
            }
        end
    end

    -- Resolve the DR category for a CC event. Prefer the CC event's own
    -- meta.drCategory; fall back to the closest preceding dr_update.
    local function resolveDRCategory(ccEvt)
        local meta = ccEvt.meta or {}
        if meta.drCategory and meta.drCategory ~= "" then
            return meta.drCategory
        end

        -- Find the closest dr_update within 1 second before or after this CC.
        local bestSnap = nil
        local bestDelta = math.huge
        local ccTime = ccEvt.t or 0
        for _, snap in ipairs(drSnapshots) do
            local delta = math.abs(snap.t - ccTime)
            if delta < bestDelta and delta <= 1.0 then
                bestDelta = delta
                bestSnap = snap
            end
        end
        return bestSnap and bestSnap.category or "unknown"
    end

    -- Group CC events into chains per DR category.
    -- A chain resets when the gap between successive CCs in the same category
    -- exceeds DR_RESET_SECONDS.
    local categoryBuckets = {}

    for _, ccEvt in ipairs(ccEvents) do
        local category = resolveDRCategory(ccEvt)
        local ccTime = ccEvt.t or 0
        local ccDuration = (ccEvt.meta and ccEvt.meta.duration) or ccEvt.duration or 0
        local drLevel = (ccEvt.meta and ccEvt.meta.drLevel) or nil

        if not categoryBuckets[category] then
            categoryBuckets[category] = {
                chainLength = 0,
                drWaste = 0,
                totalDuration = 0,
                events = {},
                lastEventEnd = -math.huge,
            }
        end

        local bucket = categoryBuckets[category]

        -- Detect chain break: if the gap from the end of the last CC in this
        -- category exceeds the DR reset window, start a new chain count.
        if (ccTime - bucket.lastEventEnd) > DR_RESET_SECONDS then
            bucket.chainLength = 0
        end

        bucket.chainLength = bucket.chainLength + 1
        bucket.totalDuration = bucket.totalDuration + ccDuration

        -- Infer DR level from chain position if not provided by the event.
        local effectiveDR = drLevel or drLevelForCount(bucket.chainLength)
        if isDRWaste(effectiveDR) then
            bucket.drWaste = bucket.drWaste + 1
        end

        bucket.events[#bucket.events + 1] = {
            t = ccTime,
            spellId = ccEvt.spellId or (ccEvt.meta and ccEvt.meta.spellID) or nil,
            duration = ccDuration,
            drLevel = effectiveDR,
            category = category,
        }

        bucket.lastEventEnd = ccTime + ccDuration
    end

    -- Compute trinket usages correlated with CC events.
    local trinketUsages = {}
    for _, ccEvt in ipairs(ccEvents) do
        local ccTime = ccEvt.t or 0
        local ccDuration = (ccEvt.meta and ccEvt.meta.duration) or ccEvt.duration or 0
        local ccSpellId = ccEvt.spellId or (ccEvt.meta and ccEvt.meta.spellID) or nil
        local drLevel = (ccEvt.meta and ccEvt.meta.drLevel) or nil

        for _, trinketEvt in ipairs(trinketCasts) do
            local trinketTime = trinketEvt.t or 0
            -- Trinket must have been used during this CC window.
            if trinketTime >= ccTime and trinketTime <= (ccTime + ccDuration) then
                local lagSeconds = trinketTime - ccTime
                trinketUsages[#trinketUsages + 1] = {
                    ccSpellId = ccSpellId,
                    ccStart = ccTime,
                    trinketTime = trinketTime,
                    lagSeconds = Helpers.Round(lagSeconds, 3),
                    drLevel = drLevel,
                }
                break -- One trinket correlation per CC event.
            end
        end
    end

    -- Compute totals.
    local totalCCUptime = 0
    local totalDRWaste = 0
    local chains = {}

    for category, bucket in pairs(categoryBuckets) do
        totalCCUptime = totalCCUptime + bucket.totalDuration
        totalDRWaste = totalDRWaste + bucket.drWaste
        chains[category] = {
            chainLength = bucket.chainLength,
            drWaste = bucket.drWaste,
            totalDuration = Helpers.Round(bucket.totalDuration, 2),
            events = bucket.events,
        }
    end

    local sessionDuration = math.max(session.duration or 1, 1)
    local ccUptimePct = Helpers.Round(totalCCUptime / sessionDuration, 4)

    return {
        chains = chains,
        trinketUsages = trinketUsages,
        totalCCUptime = Helpers.Round(totalCCUptime, 2),
        totalDRWaste = totalDRWaste,
        ccUptimePct = ccUptimePct,
    }
end

-- ---------------------------------------------------------------------------
-- T098: IdentifyHealerCCWindows
-- ---------------------------------------------------------------------------

--- Correlate CC received events with kill windows to identify healer CC
--- patterns and missed opportunities.
---
--- @param session table  A finalized session with timelineEvents.
--- @return table healerCCWindows  Array of healer CC window entries.
function CCCoachService:IdentifyHealerCCWindows(session)
    if not session or not session.timelineEvents then
        return {}
    end

    local ccEvents = collectLaneEvents(session, LANE.CC_RECEIVED)
    local killWindows = collectLaneEvents(session, LANE.KILL_WINDOW)

    local results = {}

    -- For each CC event on the player, check for correlated kill windows.
    for _, ccEvt in ipairs(ccEvents) do
        local ccTime = ccEvt.t or 0
        local ccDuration = (ccEvt.meta and ccEvt.meta.duration) or ccEvt.duration or 0
        local ccSpellId = ccEvt.spellId or (ccEvt.meta and ccEvt.meta.spellID) or nil

        -- Look for a kill window that opened within KILL_WINDOW_CORRELATION_SECONDS
        -- of the CC start (pattern: "healer CC opened kill attempt") or within
        -- KILL_WINDOW_FOLLOW_UP_MAX_SECONDS (pattern: "CC wasted").
        local nearestWindow = nil
        local nearestDelta = math.huge

        for _, kwEvt in ipairs(killWindows) do
            local kwTime = kwEvt.t or 0
            local delta = kwTime - ccTime
            -- Kill window must start after CC begins (or at most 1s before).
            if delta >= -1.0 and delta < nearestDelta then
                nearestDelta = delta
                nearestWindow = kwEvt
            end
        end

        local killWindowOpened = false
        local killWindowConverted = false
        local pattern

        if nearestWindow and nearestDelta <= KILL_WINDOW_CORRELATION_SECONDS then
            -- Kill window opened within tight correlation of CC.
            killWindowOpened = true
            killWindowConverted = (nearestWindow.meta and nearestWindow.meta.converted) and true or false
            pattern = "healer_cc_opened_kill_attempt"
        elseif not nearestWindow or nearestDelta > KILL_WINDOW_FOLLOW_UP_MAX_SECONDS then
            -- No kill window followed within the follow-up threshold.
            pattern = "cc_wasted_no_followup"
        else
            -- Kill window opened but outside tight correlation, within follow-up.
            killWindowOpened = true
            killWindowConverted = (nearestWindow.meta and nearestWindow.meta.converted) and true or false
            pattern = "healer_cc_opened_kill_attempt"
        end

        results[#results + 1] = {
            ccSpellId = ccSpellId,
            ccStart = Helpers.Round(ccTime, 2),
            ccDuration = Helpers.Round(ccDuration, 2),
            killWindowOpened = killWindowOpened,
            killWindowConverted = killWindowConverted,
            pattern = pattern,
        }
    end

    -- Also check for kill windows that had NO preceding CC ("raw pressure").
    for _, kwEvt in ipairs(killWindows) do
        local kwTime = kwEvt.t or 0
        local hasPriorCC = false

        for _, ccEvt in ipairs(ccEvents) do
            local ccTime = ccEvt.t or 0
            local ccDuration = (ccEvt.meta and ccEvt.meta.duration) or ccEvt.duration or 0
            local ccEnd = ccTime + ccDuration
            -- CC must overlap or closely precede the kill window.
            if ccEnd >= (kwTime - KILL_WINDOW_CORRELATION_SECONDS) and ccTime <= kwTime then
                hasPriorCC = true
                break
            end
        end

        if not hasPriorCC then
            results[#results + 1] = {
                ccSpellId = nil,
                ccStart = nil,
                ccDuration = nil,
                killWindowOpened = true,
                killWindowConverted = (kwEvt.meta and kwEvt.meta.converted) and true or false,
                pattern = "raw_pressure_kill_attempt",
            }
        end
    end

    return results
end

-- ---------------------------------------------------------------------------
-- T099: GenerateCCInsights
-- ---------------------------------------------------------------------------

--- Build an insight entry with consistent structure.
local function buildInsight(insightType, severity, title, message, evidence, drCategory)
    return {
        type = insightType,
        severity = severity,
        title = title,
        message = message,
        evidence = evidence or {},
        drCategory = drCategory,
    }
end

--- Generate coaching insights by combining CC chain analysis and healer CC
--- window correlation. Returns an array of insight entries suitable for
--- display in the Insights tab or consumption by SuggestionEngine.
---
--- @param session table  A finalized session with timelineEvents and duration.
--- @return table insights  Array of insight entries.
function CCCoachService:GenerateCCInsights(session)
    if not session or not session.timelineEvents then
        return {}
    end

    local ccAnalysis = self:AnalyzeCCChains(session)
    local healerWindows = self:IdentifyHealerCCWindows(session)

    local insights = {}

    -- ── Rule 1: Trinket at full DR with significant time remaining ──────
    for _, usage in ipairs(ccAnalysis.trinketUsages) do
        local drLevel = usage.drLevel
        -- "Full DR" means the CC was at 100% effectiveness (first in chain).
        if drLevel and drLevel >= 1.0 then
            -- Check if there was significant CC time remaining when trinket
            -- was used. We approximate remaining time from the CC event that
            -- correlated with this trinket.
            local ccEventsInChains = {}
            for _, chain in pairs(ccAnalysis.chains) do
                for _, evt in ipairs(chain.events) do
                    ccEventsInChains[#ccEventsInChains + 1] = evt
                end
            end

            for _, ccEvt in ipairs(ccEventsInChains) do
                if ccEvt.t == usage.ccStart and ccEvt.spellId == usage.ccSpellId then
                    local remaining = (ccEvt.t + ccEvt.duration) - usage.trinketTime
                    if remaining > TRINKET_FULL_DR_REMAINING_THRESHOLD then
                        insights[#insights + 1] = buildInsight(
                            "dr_waste",
                            "high",
                            "Trinketed at full DR -- save for fresh CC",
                            string.format(
                                "You used trinket at full DR effectiveness with %.1fs remaining. "
                                .. "Consider saving trinket for a more critical CC in a follow-up chain.",
                                remaining
                            ),
                            {
                                ccSpellId = usage.ccSpellId,
                                trinketTime = usage.trinketTime,
                                drLevel = drLevel,
                                remainingSeconds = Helpers.Round(remaining, 1),
                            },
                            ccEvt.category
                        )
                    end
                    break
                end
            end
        end
    end

    -- ── Rule 2: Overlapping CC on same DR category (DR waste) ───────────
    for category, chain in pairs(ccAnalysis.chains) do
        if chain.drWaste > 1 then
            insights[#insights + 1] = buildInsight(
                "dr_waste",
                "medium",
                "Overlapping CC on same DR category",
                string.format(
                    "In the '%s' DR category, %d CC applications hit at diminished or immune DR levels. "
                    .. "Enemies can stagger CC across different DR categories for better coverage.",
                    category,
                    chain.drWaste
                ),
                {
                    drCategory = category,
                    drWaste = chain.drWaste,
                    chainLength = chain.chainLength,
                    totalDuration = chain.totalDuration,
                },
                category
            )
        end
    end

    -- ── Rule 3: Healer CC opened kill window but no burst followed ──────
    for _, window in ipairs(healerWindows) do
        if window.pattern == "healer_cc_opened_kill_attempt"
            and window.killWindowOpened
            and not window.killWindowConverted
        then
            insights[#insights + 1] = buildInsight(
                "missed_cc_kill",
                "high",
                "Healer CC opened kill window but no burst followed",
                string.format(
                    "CC landed at %.1fs and a kill window opened, but the target survived. "
                    .. "Coordinate burst cooldowns with CC chains to convert kill attempts.",
                    window.ccStart or 0
                ),
                {
                    ccSpellId = window.ccSpellId,
                    ccStart = window.ccStart,
                    ccDuration = window.ccDuration,
                    killWindowConverted = false,
                },
                nil
            )
        end

        if window.pattern == "cc_wasted_no_followup" then
            insights[#insights + 1] = buildInsight(
                "missed_cc_kill",
                "medium",
                "CC wasted -- no follow-up pressure",
                string.format(
                    "CC landed at %.1fs but no kill window opened within %.0fs. "
                    .. "Use CC windows to set up coordinated burst, not as isolated control.",
                    window.ccStart or 0,
                    KILL_WINDOW_FOLLOW_UP_MAX_SECONDS
                ),
                {
                    ccSpellId = window.ccSpellId,
                    ccStart = window.ccStart,
                    ccDuration = window.ccDuration,
                    followUpWindowSeconds = KILL_WINDOW_FOLLOW_UP_MAX_SECONDS,
                },
                nil
            )
        end
    end

    -- ── Rule 4: Fast trinket -- good reaction ───────────────────────────
    for _, usage in ipairs(ccAnalysis.trinketUsages) do
        if usage.lagSeconds < LATE_TRINKET_THRESHOLD_SECONDS then
            -- Only praise fast trinkets on meaningful CCs (not instant-break effects).
            local ccDuration = nil
            for _, chain in pairs(ccAnalysis.chains) do
                for _, evt in ipairs(chain.events) do
                    if evt.t == usage.ccStart and evt.spellId == usage.ccSpellId then
                        ccDuration = evt.duration
                        break
                    end
                end
                if ccDuration then break end
            end

            -- Only count as "meaningful" if the CC was 2+ seconds.
            if ccDuration and ccDuration >= 2.0 then
                insights[#insights + 1] = buildInsight(
                    "good_trinket",
                    "low",
                    "Fast trinket -- good reaction",
                    string.format(
                        "You trinketed a %.1fs CC in %.2fs. Quick reactions minimize the enemy's "
                        .. "window to capitalize on your crowd control.",
                        ccDuration,
                        usage.lagSeconds
                    ),
                    {
                        ccSpellId = usage.ccSpellId,
                        ccDuration = ccDuration,
                        lagSeconds = usage.lagSeconds,
                    },
                    nil
                )
            end
        end
    end

    -- ── Rule 5: High CC uptime ──────────────────────────────────────────
    if ccAnalysis.ccUptimePct > HIGH_CC_UPTIME_THRESHOLD then
        insights[#insights + 1] = buildInsight(
            "cc_chain_break",
            "high",
            "High CC uptime",
            string.format(
                "You spent %.0f%% of the fight under crowd control (%.1fs total). "
                .. "Position to avoid CC chains, or trinket earlier to break extended chains.",
                ccAnalysis.ccUptimePct * 100,
                ccAnalysis.totalCCUptime
            ),
            {
                ccUptimePct = ccAnalysis.ccUptimePct,
                totalCCUptime = ccAnalysis.totalCCUptime,
                totalDRWaste = ccAnalysis.totalDRWaste,
                chainCount = Helpers.CountMapEntries(ccAnalysis.chains),
            },
            nil
        )
    end

    -- ── Rule 6: Late trinket on impactful CC ────────────────────────────
    for _, usage in ipairs(ccAnalysis.trinketUsages) do
        if usage.lagSeconds >= LATE_TRINKET_THRESHOLD_SECONDS then
            insights[#insights + 1] = buildInsight(
                "late_trinket",
                "medium",
                "Late trinket usage",
                string.format(
                    "Trinket was used %.1fs into a CC. Faster reactions give your team more "
                    .. "time to capitalize before the enemy can re-CC.",
                    usage.lagSeconds
                ),
                {
                    ccSpellId = usage.ccSpellId,
                    lagSeconds = usage.lagSeconds,
                    trinketTime = usage.trinketTime,
                    ccStart = usage.ccStart,
                },
                nil
            )
            break -- One late trinket insight per session.
        end
    end

    return insights
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("CCCoachService", CCCoachService)
