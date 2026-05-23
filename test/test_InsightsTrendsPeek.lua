-- test/test_InsightsTrendsPeek.lua

local ns = {}
local loader = assert(loadfile("Insights/InsightsTrendsPeek.lua"))
local TrendsPeek = loader("CombatAnalytics", ns)

local NOW       = 1700000000
local DAY       = 86400

local function sessionAt(offsetDays, pressure)
    return {
        timestamp = NOW - offsetDays * DAY,
        metrics   = { pressureScore = pressure },
    }
end

local function ratingAt(offsetDays, change)
    return {
        timestamp = NOW - offsetDays * DAY,
        change    = change,
    }
end

describe("InsightsTrendsPeek.ComputeSparkline", function()
    it("returns empty series for nil sessions", function()
        local s = TrendsPeek.ComputeSparkline(nil, "pressureScore", 14, NOW)
        expect(s.sampleCount):toBe(0)
        expect(#s.values):toBe(0)
    end)

    it("filters sessions outside the window", function()
        local sessions = {
            sessionAt(1, 70),
            sessionAt(20, 90),  -- outside 14d window
            sessionAt(7, 80),
        }
        local s = TrendsPeek.ComputeSparkline(sessions, "pressureScore", 14, NOW)
        expect(s.sampleCount):toBe(2)
    end)

    it("orders sparkline values chronologically (oldest first)", function()
        local sessions = {
            sessionAt(2, 80),
            sessionAt(5, 60),
            sessionAt(1, 70),
        }
        local s = TrendsPeek.ComputeSparkline(sessions, "pressureScore", 14, NOW)
        expect(s.values[1]):toBe(60)
        expect(s.values[2]):toBe(80)
        expect(s.values[3]):toBe(70)
    end)

    it("tracks min and max", function()
        local sessions = {
            sessionAt(1, 30),
            sessionAt(2, 70),
            sessionAt(3, 50),
        }
        local s = TrendsPeek.ComputeSparkline(sessions, "pressureScore", 14, NOW)
        expect(s.min):toBe(30)
        expect(s.max):toBe(70)
    end)

    it("supports custom metric key", function()
        local sessions = {
            { timestamp = NOW - DAY, metrics = { survivabilityScore = 88 } },
        }
        local s = TrendsPeek.ComputeSparkline(sessions, "survivabilityScore", 14, NOW)
        expect(s.values[1]):toBe(88)
    end)
end)

describe("InsightsTrendsPeek.ComputeRatingDelta", function()
    it("returns zero delta for nil entries", function()
        local r = TrendsPeek.ComputeRatingDelta(nil, 14, NOW)
        expect(r.totalDelta):toBe(0)
        expect(r.sampleCount):toBe(0)
    end)

    it("sums changes within the window", function()
        local entries = {
            ratingAt(2, 18),
            ratingAt(5, -7),
            ratingAt(20, 50),  -- outside window
        }
        local r = TrendsPeek.ComputeRatingDelta(entries, 14, NOW)
        expect(r.totalDelta):toBe(11)
        expect(r.sampleCount):toBe(2)
    end)

    it("captures first and last timestamps", function()
        local entries = {
            ratingAt(10, 5),
            ratingAt(2, 1),
        }
        local r = TrendsPeek.ComputeRatingDelta(entries, 14, NOW)
        expect(r.firstAt):toBe(NOW - 10 * DAY)
        expect(r.lastAt):toBe(NOW - 2 * DAY)
    end)
end)

describe("InsightsTrendsPeek.Build", function()
    it("populates a headline for the rating delta case", function()
        local out = TrendsPeek.Build(
            { sessionAt(1, 70), sessionAt(3, 60) },
            { ratingAt(2, 12), ratingAt(4, -2) },
            { now = NOW }
        )
        expect(out.hasSparkline):toBe(true)
        expect(out.hasRating):toBe(true)
        expect(out.headline):toBe("Rating +10 over last 14 days (2 matches).")
    end)

    it("falls back to a sparkline headline when rating data is empty", function()
        local out = TrendsPeek.Build(
            { sessionAt(1, 70), sessionAt(3, 60) },
            nil,
            { now = NOW }
        )
        expect(out.hasSparkline):toBe(true)
        expect(out.hasRating):toBe(false)
        expect(out.headline):toBe("2 sessions in last 14 days. Rating data unavailable.")
    end)

    it("returns hasData=false when nothing in window", function()
        local out = TrendsPeek.Build({}, {}, { now = NOW })
        expect(out.hasData):toBe(false)
    end)

    it("respects custom window days in headline", function()
        local out = TrendsPeek.Build(
            { sessionAt(1, 70) },
            { ratingAt(1, 5) },
            { now = NOW, windowDays = 7 }
        )
        expect(out.headline):toBe("Rating +5 over last 7 days (1 match).")
    end)
end)
