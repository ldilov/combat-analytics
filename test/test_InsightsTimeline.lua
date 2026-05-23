-- test/test_InsightsTimeline.lua
-- Unit tests for Insights/InsightsTimeline.lua

local ns = {
    Constants = {
        SESSION_RESULT = {
            WON     = "WON",
            LOST    = "LOST",
            UNKNOWN = "UNKNOWN",
        },
    },
}

local loader = assert(loadfile("Insights/InsightsTimeline.lua"))
local InsightsTimeline = loader("CombatAnalytics", ns)

local NODE   = InsightsTimeline.NODE
local STATUS = InsightsTimeline.STATUS

describe("InsightsTimeline.BuildNodes / empty session", function()
    it("returns five nodes for nil session, all unknown", function()
        local nodes = InsightsTimeline.BuildNodes(nil)
        expect(#nodes):toBe(5)
        for _, n in ipairs(nodes) do
            expect(n.status):toBe(STATUS.UNKNOWN)
        end
    end)

    it("preserves canonical node order", function()
        local nodes = InsightsTimeline.BuildNodes({})
        expect(nodes[1].key):toBe(NODE.OPENER)
        expect(nodes[2].key):toBe(NODE.GO1)
        expect(nodes[3].key):toBe(NODE.DEF1)
        expect(nodes[4].key):toBe(NODE.CC1)
        expect(nodes[5].key):toBe(NODE.END)
    end)

    it("emits human-readable labels", function()
        local nodes = InsightsTimeline.BuildNodes({})
        expect(nodes[1].label):toBe("Opener")
        expect(nodes[2].label):toBe("First Go")
        expect(nodes[3].label):toBe("First Defensive")
        expect(nodes[4].label):toBe("First CC")
        expect(nodes[5].label):toBe("End")
    end)
end)

describe("InsightsTimeline.BuildNodes / opener", function()
    it("marks opener good when casts present", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { openerCastCount = 3, engagementAt = 1.2 },
        })
        expect(nodes[1].status):toBe(STATUS.GOOD)
    end)

    it("marks opener unknown when no engagement and no casts", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { openerCastCount = 0, engagementAt = 0 },
        })
        expect(nodes[1].status):toBe(STATUS.UNKNOWN)
    end)
end)

describe("InsightsTimeline.BuildNodes / first go", function()
    it("is good when first major offensive is on time", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { firstMajorOffensiveRelative = 2.3 },
        })
        expect(nodes[2].status):toBe(STATUS.GOOD)
    end)

    it("is late when first major offensive exceeds threshold", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { firstMajorOffensiveRelative = 9.5 },
        })
        expect(nodes[2].status):toBe(STATUS.LATE)
    end)

    it("is miss when no offensive cooldown was used", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = {},
        })
        expect(nodes[2].status):toBe(STATUS.MISS)
    end)
end)

describe("InsightsTimeline.BuildNodes / first defensive", function()
    it("is good when defensive used on time", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { firstMajorDefensiveRelative = 3.0 },
        })
        expect(nodes[3].status):toBe(STATUS.GOOD)
    end)

    it("is late when defensive timing drifted past threshold", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = { firstMajorDefensiveRelative = 11.2 },
        })
        expect(nodes[3].status):toBe(STATUS.LATE)
    end)

    it("is miss when died with no defensive used", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = {},
            survival          = { deaths = 1, defensivesUsed = 0 },
        })
        expect(nodes[3].status):toBe(STATUS.MISS)
    end)

    it("is unknown when survived without major defensive timing data", function()
        local nodes = InsightsTimeline.BuildNodes({
            openerFingerprint = {},
            survival          = { deaths = 0, defensivesUsed = 0 },
        })
        expect(nodes[3].status):toBe(STATUS.UNKNOWN)
    end)
end)

describe("InsightsTimeline.BuildNodes / cc", function()
    it("is unknown when no metrics ccUptime is present", function()
        local nodes = InsightsTimeline.BuildNodes({ metrics = {} })
        expect(nodes[4].status):toBe(STATUS.UNKNOWN)
    end)

    it("is good when ccUptime is positive", function()
        local nodes = InsightsTimeline.BuildNodes({
            metrics = { ccUptime = 4.2 },
        })
        expect(nodes[4].status):toBe(STATUS.GOOD)
    end)
end)

describe("InsightsTimeline.BuildNodes / end", function()
    it("is good for wins", function()
        local nodes = InsightsTimeline.BuildNodes({
            duration = 120,
            result   = ns.Constants.SESSION_RESULT.WON,
        })
        expect(nodes[5].status):toBe(STATUS.GOOD)
    end)

    it("is loss for losses", function()
        local nodes = InsightsTimeline.BuildNodes({
            duration = 90,
            result   = ns.Constants.SESSION_RESULT.LOST,
        })
        expect(nodes[5].status):toBe(STATUS.LOSS)
    end)

    it("is unknown when result is unknown", function()
        local nodes = InsightsTimeline.BuildNodes({
            duration = 60,
            result   = ns.Constants.SESSION_RESULT.UNKNOWN,
        })
        expect(nodes[5].status):toBe(STATUS.UNKNOWN)
    end)
end)

describe("InsightsTimeline.GetReasonsForNode", function()
    it("returns suggestions matching the node's allowed reason codes", function()
        local suggestions = {
            { reasonCode = "LATE_FIRST_GO",         severity = "high" },
            { reasonCode = "DEFENSIVE_DRIFT",       severity = "medium" },
            { reasonCode = "ROTATION_GAPS_OBSERVED", severity = "low" },
        }
        local goReasons = InsightsTimeline.GetReasonsForNode(NODE.GO1, suggestions)
        expect(#goReasons):toBe(1)
        expect(goReasons[1].reasonCode):toBe("LATE_FIRST_GO")

        local defReasons = InsightsTimeline.GetReasonsForNode(NODE.DEF1, suggestions)
        expect(#defReasons):toBe(1)
        expect(defReasons[1].reasonCode):toBe("DEFENSIVE_DRIFT")
    end)

    it("returns empty list for unknown node or missing suggestions", function()
        expect(#InsightsTimeline.GetReasonsForNode("nope", {})):toBe(0)
        expect(#InsightsTimeline.GetReasonsForNode(NODE.OPENER, nil)):toBe(0)
    end)
end)
