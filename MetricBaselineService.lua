local _, ns = ...

local MetricBaselineService = ns.Addon:NewModule("MetricBaselineService")
local Math = nil
local Constants = nil

function MetricBaselineService:OnInitialize()
    Math = ns.Math
    Constants = ns.Constants
end

local ROLLING_WINDOW_SIZE = 20
local DEFAULT_PRIOR_WEIGHT = 7

-- Population defaults per metric (fallback when player has no history)
local POPULATION_DEFAULTS = {
    pressureScore = 55,
    burstScore = 45,
    survivabilityScore = 60,
    rotationConsistencyScore = 50,
    ccUptimePct = 0.20,
    avoidableDamagePct = 0.30,
}

function MetricBaselineService:GetBaselinesDB()
    local ok, db = pcall(function()
        return ns.Addon:GetModule("CombatStore"):GetDB()
    end)
    if not ok or not db or not db.aggregates then return nil end
    db.aggregates.metricBaselines = db.aggregates.metricBaselines or {}
    return db.aggregates.metricBaselines
end

function MetricBaselineService:RecordMetric(context, metricName, value)
    if not context or not metricName or not value then return end
    local baselines = self:GetBaselinesDB()
    if not baselines then return end

    local contextKey = tostring(context):lower()
    baselines[contextKey] = baselines[contextKey] or {}
    local bucket = baselines[contextKey][metricName]
    if not bucket then
        bucket = { values = {}, count = 0, mean = 0, stdDev = 0, p25 = 0, p50 = 0, p75 = 0, lastUpdated = 0 }
        baselines[contextKey][metricName] = bucket
    end

    -- FIFO insert
    table.insert(bucket.values, value)
    if #bucket.values > ROLLING_WINDOW_SIZE then
        table.remove(bucket.values, 1)
    end
    bucket.count = (bucket.count or 0) + 1

    -- Recompute stats
    bucket.mean = Math.Average(bucket.values)
    bucket.stdDev = Math.StandardDeviation(bucket.values)
    bucket.p25 = Math.Percentile(bucket.values, 0.25)
    bucket.p50 = Math.Percentile(bucket.values, 0.50)
    bucket.p75 = Math.Percentile(bucket.values, 0.75)
    bucket.lastUpdated = ns.ApiCompat and ns.ApiCompat.GetServerTime() or time()
end

function MetricBaselineService:GetThreshold(context, metricName, percentileKey)
    percentileKey = percentileKey or "p25"
    local baselines = self:GetBaselinesDB()
    local contextKey = tostring(context or ""):lower()
    local bucket = baselines and baselines[contextKey] and baselines[contextKey][metricName]
    local populationDefault = POPULATION_DEFAULTS[metricName] or 50

    if not bucket or not bucket.values or #bucket.values < 1 then
        return populationDefault
    end

    local playerValue = bucket[percentileKey] or bucket.p25 or bucket.mean or 0
    local sampleCount = #bucket.values

    return Math.BayesianShrinkage(playerValue, sampleCount, populationDefault, DEFAULT_PRIOR_WEIGHT)
end

function MetricBaselineService:GetBaseline(context, metricName)
    local baselines = self:GetBaselinesDB()
    local contextKey = tostring(context or ""):lower()
    return baselines and baselines[contextKey] and baselines[contextKey][metricName]
end

function MetricBaselineService:GetSampleCount(context, metricName)
    local baseline = self:GetBaseline(context, metricName)
    return baseline and baseline.count or 0
end
