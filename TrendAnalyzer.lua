local _, ns = ...

-- Math bound at file scope (Utils\Math.lua loads earlier in the .toc). The
-- framework RegisterModule's modules but never calls OnInitialize, so the
-- old OnInitialize-based binding never ran and left Math nil.
local Math = ns.Math

local TrendAnalyzer = {}

local CORE_METRICS = { "pressureScore", "burstScore", "survivabilityScore", "rotationConsistencyScore" }
local MIN_SAMPLES_FOR_TREND = 10
local R_SQUARED_THRESHOLD = 0.3

function TrendAnalyzer:AnalyzeTrends(context)
    local trends = {}
    local ok, mbs = pcall(function()
        return ns.Addon:GetModule("MetricBaselineService", true)
    end)
    if not ok or not mbs then return trends end

    for _, metricName in ipairs(CORE_METRICS) do
        local baseline = mbs:GetBaseline(context, metricName)
        if baseline and baseline.values and #baseline.values >= MIN_SAMPLES_FOR_TREND then
            local xValues = {}
            local yValues = {}
            for i, v in ipairs(baseline.values) do
                xValues[i] = i
                yValues[i] = v
            end

            local reg = Math.LinearRegression(xValues, yValues)
            if reg.rSquared >= R_SQUARED_THRESHOLD then
                local firstVal = baseline.values[1]
                local lastVal = baseline.values[#baseline.values]
                local pctChange = 0
                if firstVal and firstVal ~= 0 then
                    pctChange = ((lastVal - firstVal) / math.abs(firstVal)) * 100
                end

                local direction = reg.slope > 0 and "improving" or "declining"
                local label = metricName:gsub("(%u)", " %1"):gsub("^%s", ""):gsub("Score$", " Score")

                trends[#trends + 1] = {
                    metricName = metricName,
                    direction = direction,
                    slope = reg.slope,
                    rSquared = reg.rSquared,
                    pctChange = pctChange,
                    sampleCount = #baseline.values,
                    message = string.format("%s %s %+.0f%% over last %d sessions",
                        label, direction, pctChange, #baseline.values),
                }
            end
        end
    end

    return trends
end

function TrendAnalyzer:DetectTilt(context, recentSessions)
    if not recentSessions or #recentSessions < 3 then return nil end

    local ok, mbs = pcall(function()
        return ns.Addon:GetModule("MetricBaselineService", true)
    end)
    if not ok or not mbs then return nil end

    local baseline = mbs:GetBaseline(context, "pressureScore")
    if not baseline or not baseline.mean or baseline.mean <= 0 then return nil end

    -- Check consecutive losses
    local consecutiveLosses = 0
    for i = #recentSessions, 1, -1 do
        local s = recentSessions[i]
        if s and s.result == ns.Constants.SESSION_RESULT.LOST then
            consecutiveLosses = consecutiveLosses + 1
        else
            break
        end
    end

    if consecutiveLosses < 3 then return nil end

    -- Compute EMA of recent pressure scores
    local ema = nil
    for _, s in ipairs(recentSessions) do
        local pressure = s.metrics and s.metrics.pressureScore
        if pressure then
            ema = Math.ExponentialMovingAverage(pressure, ema, 0.3)
        end
    end

    if not ema then return nil end

    local threshold = baseline.mean * 0.85
    if ema < threshold then
        return {
            reasonCode = "TILT_WARNING",
            severity = "medium",
            confidence = 0.7,
            controllability = "outcome_based",
            effort = 1,
            message = string.format("Performance declining — %d consecutive losses with pressure EMA %.0f vs baseline %.0f. Consider taking a break.",
                consecutiveLosses, ema, baseline.mean),
            evidence = {
                consecutiveLosses = consecutiveLosses,
                ema = ema,
                baselineMean = baseline.mean,
            },
        }
    end

    return nil
end

ns.Addon:RegisterModule("TrendAnalyzer", TrendAnalyzer)
