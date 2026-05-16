local _, ns = ...

local Math = {}

function Math.HashString32(value)
    local hash = 2166136261
    local text = tostring(value or "")
    for index = 1, #text do
        hash = bit.bxor(hash, string.byte(text, index))
        hash = (hash * 16777619) % 4294967296
    end
    return hash
end

function Math.Sum(values)
    local total = 0
    for _, value in ipairs(values or {}) do
        total = total + (tonumber(value) or 0)
    end
    return total
end

function Math.Average(values)
    if not values or #values == 0 then
        return 0
    end
    return Math.Sum(values) / #values
end

function Math.Median(values)
    if not values or #values == 0 then
        return 0
    end
    local sorted = ns.Helpers.CopyTable(values, false)
    table.sort(sorted)
    local middle = math.floor(#sorted / 2)
    if #sorted % 2 == 0 then
        return (sorted[middle] + sorted[middle + 1]) / 2
    end
    return sorted[middle + 1]
end

function Math.Variance(values)
    if not values or #values <= 1 then
        return 0
    end
    local average = Math.Average(values)
    local total = 0
    for _, value in ipairs(values) do
        local delta = value - average
        total = total + delta * delta
    end
    return total / (#values - 1)
end

function Math.StandardDeviation(values)
    return math.sqrt(Math.Variance(values))
end

function Math.Percentile(values, percentile)
    if not values or #values == 0 then
        return 0
    end
    percentile = ns.Helpers.Clamp(percentile or 0.5, 0, 1)
    local sorted = ns.Helpers.CopyTable(values, false)
    table.sort(sorted)
    local rank = (#sorted - 1) * percentile + 1
    local lower = math.floor(rank)
    local upper = math.ceil(rank)
    if lower == upper then
        return sorted[lower]
    end
    local weight = rank - lower
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
end

function Math.WeightedAverage(items, valueKey, weightKey)
    local numerator = 0
    local denominator = 0
    for _, item in ipairs(items or {}) do
        local weight = tonumber(item[weightKey]) or 0
        numerator = numerator + ((tonumber(item[valueKey]) or 0) * weight)
        denominator = denominator + weight
    end
    if denominator <= 0 then
        return 0
    end
    return numerator / denominator
end

function Math.LinearTrendSlope(points, xKey, yKey)
    if not points or #points <= 1 then
        return 0
    end

    local count = 0
    local sumX = 0
    local sumY = 0
    local sumXY = 0
    local sumXX = 0

    for _, point in ipairs(points) do
        local x = tonumber(point[xKey]) or 0
        local y = tonumber(point[yKey]) or 0
        count = count + 1
        sumX = sumX + x
        sumY = sumY + y
        sumXY = sumXY + (x * y)
        sumXX = sumXX + (x * x)
    end

    local denominator = (count * sumXX) - (sumX * sumX)
    if denominator == 0 then
        return 0
    end
    return ((count * sumXY) - (sumX * sumY)) / denominator
end

function Math.BayesianShrinkage(playerMean, sampleCount, populationMean, priorWeight)
    priorWeight = priorWeight or 7
    sampleCount = sampleCount or 0
    if sampleCount <= 0 then
        return populationMean or 0
    end
    return ((priorWeight * (populationMean or 0)) + (sampleCount * playerMean)) / (priorWeight + sampleCount)
end

function Math.LinearRegression(xValues, yValues)
    if not xValues or not yValues or #xValues < 2 or #xValues ~= #yValues then
        return { slope = 0, intercept = 0, rSquared = 0 }
    end
    local n = #xValues
    local sumX, sumY, sumXY, sumXX, sumYY = 0, 0, 0, 0, 0
    for i = 1, n do
        local x = tonumber(xValues[i]) or 0
        local y = tonumber(yValues[i]) or 0
        sumX = sumX + x
        sumY = sumY + y
        sumXY = sumXY + x * y
        sumXX = sumXX + x * x
        sumYY = sumYY + y * y
    end
    local denomX = n * sumXX - sumX * sumX
    if denomX == 0 then
        return { slope = 0, intercept = 0, rSquared = 0 }
    end
    local slope = (n * sumXY - sumX * sumY) / denomX
    local intercept = (sumY - slope * sumX) / n
    local denomR = math.sqrt((n * sumXX - sumX * sumX) * (n * sumYY - sumY * sumY))
    local rSquared = 0
    if denomR > 0 then
        local r = (n * sumXY - sumX * sumY) / denomR
        rSquared = r * r
    end
    return { slope = slope, intercept = intercept, rSquared = rSquared }
end

function Math.ExponentialMovingAverage(currentValue, previousEma, alpha)
    alpha = alpha or 0.3
    if previousEma == nil then
        return currentValue
    end
    return alpha * currentValue + (1 - alpha) * previousEma
end

ns.Math = Math
