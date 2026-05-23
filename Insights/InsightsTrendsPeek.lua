-- Insights/InsightsTrendsPeek.lua
-- Pure-logic builder for the "Trends Peek" section of the new Insights tab.
--
-- The section is intentionally compact: it shows a tiny sparkline of the
-- chosen metric over the last `windowDays` along with a rating delta over
-- the same window, with a "see full Rating tab" affordance.
--
-- This module owns all of the numeric work so the UI is a pure renderer:
--   ComputeSparkline(sessions, metric, windowDays, nowSeconds)
--   ComputeRatingDelta(ratingEntries, windowDays, nowSeconds)
--   Build(sessions, ratingEntries, opts)
--
-- No SavedVariables access, no UI, no side effects. Pass the sessions list
-- and the rating-history list in. The caller is expected to fetch them via
-- CombatStore:GetRecentSessionStreak(n) and CombatStore:GetRatingTrend(...).

local _, ns = ...
ns = ns or {}

local InsightsTrendsPeek = {}

local DEFAULT_WINDOW_DAYS = 14
local DEFAULT_METRIC      = "pressureScore"
local SECONDS_PER_DAY     = 86400

local function safeNumber(v)
    return tonumber(v)
end

local function nowSecondsFallback(now)
    if now then return now end
    if time then return time() end
    if os and os.time then return os.time() end
    return 0
end

local function windowFloor(now, windowDays)
    return now - windowDays * SECONDS_PER_DAY
end

-- ---------------------------------------------------------------------------
-- Sparkline
-- ---------------------------------------------------------------------------

--- Reduce a list of finalised sessions into a sparkline series for a metric.
--- Returns:
---   { values = { v1, v2, ... }, min = number, max = number, sampleCount = N }
--- Values are in chronological order; older first.
function InsightsTrendsPeek.ComputeSparkline(sessions, metric, windowDays, now)
    metric     = metric     or DEFAULT_METRIC
    windowDays = windowDays or DEFAULT_WINDOW_DAYS
    now        = nowSecondsFallback(now)

    local cutoff = windowFloor(now, windowDays)
    local series = {}

    if type(sessions) == "table" then
        for _, s in ipairs(sessions) do
            local ts = safeNumber(s and s.timestamp)
            local v  = s and s.metrics and safeNumber(s.metrics[metric])
            if ts and v and ts >= cutoff then
                series[#series + 1] = { timestamp = ts, value = v }
            end
        end
    end

    table.sort(series, function(a, b) return a.timestamp < b.timestamp end)

    local values = {}
    local minV, maxV
    for i, e in ipairs(series) do
        values[i] = e.value
        if not minV or e.value < minV then minV = e.value end
        if not maxV or e.value > maxV then maxV = e.value end
    end

    return {
        values      = values,
        min         = minV,
        max         = maxV,
        sampleCount = #values,
        metric      = metric,
        windowDays  = windowDays,
    }
end

-- ---------------------------------------------------------------------------
-- Rating delta
-- ---------------------------------------------------------------------------

function InsightsTrendsPeek.ComputeRatingDelta(ratingEntries, windowDays, now)
    windowDays = windowDays or DEFAULT_WINDOW_DAYS
    now        = nowSecondsFallback(now)
    local cutoff = windowFloor(now, windowDays)

    local total = 0
    local samples = 0
    local first, last

    if type(ratingEntries) == "table" then
        for _, e in ipairs(ratingEntries) do
            local ts = safeNumber(e and e.timestamp)
            local change = safeNumber(e and e.change)
            if ts and change and ts >= cutoff then
                total = total + change
                samples = samples + 1
                if not first or ts < first then first = ts end
                if not last  or ts > last  then last  = ts end
            end
        end
    end

    return {
        totalDelta  = total,
        sampleCount = samples,
        firstAt     = first,
        lastAt      = last,
        windowDays  = windowDays,
    }
end

-- ---------------------------------------------------------------------------
-- Composite
-- ---------------------------------------------------------------------------

--- Compose a single descriptor the UI can render in one call.
--- @param sessions       table?  list of finalised session payloads
--- @param ratingEntries  table?  list of rating-history entries
--- @param opts           table?  { metric?, windowDays?, now? }
function InsightsTrendsPeek.Build(sessions, ratingEntries, opts)
    opts = opts or {}
    local metric     = opts.metric     or DEFAULT_METRIC
    local windowDays = opts.windowDays or DEFAULT_WINDOW_DAYS
    local now        = nowSecondsFallback(opts.now)

    local sparkline  = InsightsTrendsPeek.ComputeSparkline(sessions, metric, windowDays, now)
    local rating     = InsightsTrendsPeek.ComputeRatingDelta(ratingEntries, windowDays, now)

    local hasSparkline = (sparkline.sampleCount or 0) >= 2
    local hasRating    = (rating.sampleCount or 0) >= 1

    local headline
    if hasRating then
        local sign = rating.totalDelta > 0 and "+" or ""
        headline = string.format("Rating %s%d over last %d day%s (%d match%s).",
            sign, rating.totalDelta, windowDays,
            windowDays == 1 and "" or "s",
            rating.sampleCount, rating.sampleCount == 1 and "" or "es")
    elseif hasSparkline then
        headline = string.format("%d session%s in last %d day%s. Rating data unavailable.",
            sparkline.sampleCount, sparkline.sampleCount == 1 and "" or "s",
            windowDays, windowDays == 1 and "" or "s")
    else
        headline = string.format("No data for the last %d day%s yet.",
            windowDays, windowDays == 1 and "" or "s")
    end

    return {
        metric      = metric,
        windowDays  = windowDays,
        sparkline   = sparkline,
        rating      = rating,
        headline    = headline,
        hasSparkline = hasSparkline,
        hasRating    = hasRating,
        hasData      = hasSparkline or hasRating,
    }
end

InsightsTrendsPeek._DEFAULT_WINDOW_DAYS = DEFAULT_WINDOW_DAYS
InsightsTrendsPeek._DEFAULT_METRIC      = DEFAULT_METRIC

ns.InsightsTrendsPeek = InsightsTrendsPeek
return InsightsTrendsPeek
