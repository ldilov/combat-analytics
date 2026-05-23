-- test/test_InsightsRecurringDrills.lua

local ns = {}
local loader = assert(loadfile("Insights/InsightsRecurringDrills.lua"))
local Drills = loader("CombatAnalytics", ns)

local NOW       = 1700000000
local DAY       = 86400

local function session(offsetDays, suggestions)
    return {
        timestamp   = NOW - offsetDays * DAY,
        suggestions = suggestions,
    }
end

describe("InsightsRecurringDrills.CountReasonCodes", function()
    it("returns empty table for nil sessions", function()
        local c = Drills.CountReasonCodes(nil, 7, NOW)
        local n = 0
        for _ in pairs(c) do n = n + 1 end
        expect(n):toBe(0)
    end)

    it("counts a reason code once per session even if it appears multiple times", function()
        local sessions = {
            session(1, {
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "TRINKET_TIMING_POOR" },
            }),
        }
        local c = Drills.CountReasonCodes(sessions, 7, NOW)
        expect(c.DEFENSIVE_DRIFT):toBe(1)
        expect(c.TRINKET_TIMING_POOR):toBe(1)
    end)

    it("filters sessions outside the window", function()
        local sessions = {
            session(1,  { { reasonCode = "DEFENSIVE_DRIFT" } }),
            session(2,  { { reasonCode = "DEFENSIVE_DRIFT" } }),
            session(10, { { reasonCode = "DEFENSIVE_DRIFT" } }),  -- outside 7d
        }
        local c = Drills.CountReasonCodes(sessions, 7, NOW)
        expect(c.DEFENSIVE_DRIFT):toBe(2)
    end)
end)

describe("InsightsRecurringDrills.Build", function()
    it("returns empty list when no reason code crosses threshold", function()
        local sessions = {
            session(1, { { reasonCode = "DEFENSIVE_DRIFT" } }),
        }
        local d = Drills.Build(sessions, { now = NOW })
        expect(#d):toBe(0)
    end)

    it("surfaces a drill for any reason code recurring >= threshold (2 by default)", function()
        local sessions = {
            session(1, { { reasonCode = "DEFENSIVE_DRIFT" } }),
            session(2, { { reasonCode = "DEFENSIVE_DRIFT" } }),
        }
        local d = Drills.Build(sessions, { now = NOW })
        expect(#d):toBe(1)
        expect(d[1].reasonCode):toBe("DEFENSIVE_DRIFT")
        expect(d[1].count):toBe(2)
        expect(d[1].severity):toBe("medium")
    end)

    it("orders high severity before medium / low", function()
        local sessions = {
            session(1, {
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "DIED_WITH_DEFENSIVES" },
                { reasonCode = "ROTATION_GAPS_OBSERVED" },
            }),
            session(2, {
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "DIED_WITH_DEFENSIVES" },
                { reasonCode = "ROTATION_GAPS_OBSERVED" },
            }),
        }
        local d = Drills.Build(sessions, { now = NOW })
        expect(d[1].reasonCode):toBe("DIED_WITH_DEFENSIVES")
        expect(d[1].severity):toBe("high")
    end)

    it("caps drills at maxDrills", function()
        local sessions = {
            session(1, {
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "TRINKET_TIMING_POOR" },
                { reasonCode = "LATE_FIRST_GO" },
            }),
            session(2, {
                { reasonCode = "DEFENSIVE_DRIFT" },
                { reasonCode = "TRINKET_TIMING_POOR" },
                { reasonCode = "LATE_FIRST_GO" },
            }),
        }
        local d = Drills.Build(sessions, { now = NOW, maxDrills = 2 })
        expect(#d):toBe(2)
    end)

    it("emits a fallback drill for an unknown reason code", function()
        local sessions = {
            session(1, { { reasonCode = "BRAND_NEW_CODE" } }),
            session(2, { { reasonCode = "BRAND_NEW_CODE" } }),
        }
        local d = Drills.Build(sessions, { now = NOW })
        expect(#d):toBe(1)
        expect(d[1].reasonCode):toBe("BRAND_NEW_CODE")
        expect(d[1].title):toBe("BRAND_NEW_CODE")
    end)
end)
