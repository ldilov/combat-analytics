-- Insights/InsightsRecurringDrills.lua
-- Pure-logic builder for the "Practice Plan" section's recurring-drill list.
--
-- Walks a list of recent sessions, counts how many times each reason code
-- appears in `suggestions[]` inside a sliding window (default last 7 days),
-- and emits a drill descriptor for every reason code that recurs `>=
-- thresholdCount` times.
--
-- This is intentionally NOT the broader PracticePlannerService:GetWeakAreas
-- output: that function looks at long-term aggregates. Insights' "Practice
-- Plan" surfaces only patterns the player has demonstrably failed at over
-- the last few days — the things their next queue should focus on.
--
-- Pure module — no SavedVariables access, no UI. The caller is expected to
-- pass the session list (CombatStore:GetRecentSessionStreak) and a
-- timestamp to use as "now" so tests are deterministic.

local _, ns = ...
ns = ns or {}

local InsightsRecurringDrills = {}

local DEFAULT_WINDOW_DAYS    = 7
local DEFAULT_THRESHOLD      = 2
local DEFAULT_MAX_DRILLS     = 6
local SECONDS_PER_DAY        = 86400

local DRILL_TEMPLATES = {
    DIED_WITH_DEFENSIVES = {
        title    = "Trade defensive earlier into CC chains",
        action   = "Pre-cast a defensive cooldown before fear / stun chains land.",
        severity = "high",
    },
    DEFENSIVE_DRIFT = {
        title    = "Tighten defensive cooldown timing",
        action   = "Use defensives within 1s of CC break in your next 5 matches.",
        severity = "medium",
    },
    REACTIVE_DEFENSIVE_LATE = {
        title    = "Stop reacting late on defensives",
        action   = "Listen for enemy major casts; pre-cast on swap-target instead of waiting.",
        severity = "medium",
    },
    DEFENSIVE_UNUSED_ON_LOSS = {
        title    = "Spend defensives before you die",
        action   = "Use major defensive at 60% HP minimum next 5 matches.",
        severity = "medium",
    },
    DIED_IN_CC = {
        title    = "Avoid dying inside CC",
        action   = "Use trinket + defensive on the longest incoming CC, not the first one.",
        severity = "high",
    },
    TRINKET_TIMING_POOR = {
        title    = "Improve trinket timing",
        action   = "Hold trinket for fresh CC of the longest DR family.",
        severity = "medium",
    },
    CC_LATE_TRINKET = {
        title    = "Trinket earlier in the chain",
        action   = "Bind trinket on the same key as a defensive; pop both together.",
        severity = "medium",
    },
    HIGH_CC_UPTIME = {
        title    = "Reduce time spent in CC",
        action   = "Practice positioning to break LoS during your healer's CC instead of staring.",
        severity = "medium",
    },
    LATE_FIRST_GO = {
        title    = "Open the gate faster",
        action   = "Pop major offensive on the first valid trade window, not after the first CC.",
        severity = "medium",
    },
    SUBOPTIMAL_OPENER_SEQUENCE = {
        title    = "Drill a new opener vs this comp",
        action   = "Run 10 opener reps on a dummy. Lock in the highest-win-rate sequence.",
        severity = "medium",
    },
    LOW_PRESSURE_VS_BUILD_BASELINE = {
        title    = "Sustain pressure throughout the fight",
        action   = "Audit a recent loss vs your last win. Compare cast spacing in 30s blocks.",
        severity = "medium",
    },
    LOW_HEALER_PRESSURE = {
        title    = "Get more damage onto the healer",
        action   = "Practice swap mechanics for 5 dummy reps; use kick/silence on healer fast cast.",
        severity = "medium",
    },
    ROTATION_GAPS_OBSERVED = {
        title    = "Eliminate rotation dead space",
        action   = "Set a 1s GCD audit on your next 5 dummy reps. No idle GCDs.",
        severity = "low",
    },
    POOR_INTERRUPT_RATE = {
        title    = "Improve interrupt success",
        action   = "Practice fake-casting recognition; interrupt only confirmed casts.",
        severity = "medium",
    },
    PROC_WINDOWS_UNDERUSED = {
        title    = "Convert proc windows",
        action   = "Bind a proc-window addon trigger. Drill 10 reps on a dummy.",
        severity = "low",
    },
    HIGH_DAMAGE_TAKEN_VS_OPPONENT = {
        title    = "Reduce incoming damage vs this matchup",
        action   = "Watch the top opponent spell — pre-CD a defensive when it's available.",
        severity = "medium",
    },
}

local function safeNumber(v)
    return tonumber(v)
end

local function nowSecondsFallback(now)
    if now then return now end
    if time then return time() end
    if os and os.time then return os.time() end
    return 0
end

local function severityRank(severity)
    if severity == "high" then return 3 end
    if severity == "medium" then return 2 end
    if severity == "low" then return 1 end
    return 0
end

--- Build the recurrence count map from a list of sessions inside a window.
--- @return table  reasonCode -> count
function InsightsRecurringDrills.CountReasonCodes(sessions, windowDays, now)
    windowDays = windowDays or DEFAULT_WINDOW_DAYS
    now        = nowSecondsFallback(now)
    local cutoff = now - windowDays * SECONDS_PER_DAY

    local counts = {}
    if type(sessions) ~= "table" then return counts end

    for _, session in ipairs(sessions) do
        local ts = safeNumber(session and session.timestamp)
        if ts and ts >= cutoff then
            local seenInSession = {}
            for _, sug in ipairs(session.suggestions or {}) do
                local rc = sug and sug.reasonCode
                if rc and not seenInSession[rc] then
                    seenInSession[rc] = true
                    counts[rc] = (counts[rc] or 0) + 1
                end
            end
        end
    end

    return counts
end

--- Build the ordered drill list. Most severe + most recurrent first.
--- @param sessions   table  list of recent finalised sessions
--- @param opts       table? { windowDays?, threshold?, maxDrills?, now? }
--- @return table  list of { reasonCode, count, severity, title, action }
function InsightsRecurringDrills.Build(sessions, opts)
    opts = opts or {}
    local windowDays = opts.windowDays or DEFAULT_WINDOW_DAYS
    local threshold  = opts.threshold  or DEFAULT_THRESHOLD
    local maxDrills  = opts.maxDrills  or DEFAULT_MAX_DRILLS
    local now        = nowSecondsFallback(opts.now)

    local counts = InsightsRecurringDrills.CountReasonCodes(sessions, windowDays, now)
    local drills = {}
    for reasonCode, count in pairs(counts) do
        if count >= threshold then
            local template = DRILL_TEMPLATES[reasonCode]
            if template then
                drills[#drills + 1] = {
                    reasonCode = reasonCode,
                    count      = count,
                    severity   = template.severity,
                    title      = template.title,
                    action     = template.action,
                }
            else
                -- Unknown reason code: still surface it but with a generic body
                -- so a new code addition does not silently disappear from the
                -- coaching list before its template is added.
                drills[#drills + 1] = {
                    reasonCode = reasonCode,
                    count      = count,
                    severity   = "medium",
                    title      = reasonCode,
                    action     = "Recurring coaching note this week — drill it on the dummy.",
                }
            end
        end
    end

    table.sort(drills, function(a, b)
        if a.severity ~= b.severity then
            return severityRank(a.severity) > severityRank(b.severity)
        end
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.reasonCode < b.reasonCode
    end)

    local out = {}
    for i = 1, math.min(#drills, maxDrills) do
        out[i] = drills[i]
    end
    return out
end

InsightsRecurringDrills._DRILL_TEMPLATES     = DRILL_TEMPLATES
InsightsRecurringDrills._DEFAULT_WINDOW_DAYS = DEFAULT_WINDOW_DAYS
InsightsRecurringDrills._DEFAULT_THRESHOLD   = DEFAULT_THRESHOLD
InsightsRecurringDrills._DEFAULT_MAX_DRILLS  = DEFAULT_MAX_DRILLS

ns.InsightsRecurringDrills = InsightsRecurringDrills
return InsightsRecurringDrills
