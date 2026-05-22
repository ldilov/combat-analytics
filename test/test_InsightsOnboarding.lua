-- test/test_InsightsOnboarding.lua

local ns = { Constants = {} }
local loader = assert(loadfile("Insights/InsightsOnboarding.lua"))
local Onb = loader("CombatAnalytics", ns)

describe("InsightsOnboarding.Classify", function()
    it("returns cold for zero / nil / negative session counts", function()
        expect(Onb.Classify(0)):toBe(Onb.STATE.COLD)
        expect(Onb.Classify(nil)):toBe(Onb.STATE.COLD)
        expect(Onb.Classify(-5)):toBe(Onb.STATE.COLD)
    end)

    it("returns sparse below the threshold", function()
        expect(Onb.Classify(1)):toBe(Onb.STATE.SPARSE)
        expect(Onb.Classify(2)):toBe(Onb.STATE.SPARSE)
    end)

    it("returns full at and above the threshold", function()
        expect(Onb.Classify(3)):toBe(Onb.STATE.FULL)
        expect(Onb.Classify(50)):toBe(Onb.STATE.FULL)
    end)

    it("honours ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD override", function()
        ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD = 10
        expect(Onb.Classify(9)):toBe(Onb.STATE.SPARSE)
        expect(Onb.Classify(10)):toBe(Onb.STATE.FULL)
        ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD = nil
    end)

    it("falls back to default threshold when override is invalid", function()
        ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD = "bogus"
        expect(Onb.Classify(3)):toBe(Onb.STATE.FULL)
        ns.Constants.INSIGHTS_ONBOARDING_THRESHOLD = nil
    end)
end)

describe("InsightsOnboarding.SectionVisibility", function()
    it("hides pillars and trends in cold state", function()
        local v = Onb.SectionVisibility(Onb.STATE.COLD)
        expect(v.pillarScoreboard):toBe(false)
        expect(v.trendsPeek):toBe(false)
        expect(v.matchupPlan):toBe(false)
        expect(v.fidelityBar):toBe(true)
    end)

    it("hides matchup + trends in sparse state but shows pillars", function()
        local v = Onb.SectionVisibility(Onb.STATE.SPARSE)
        expect(v.pillarScoreboard):toBe(true)
        expect(v.matchupPlan):toBe(false)
        expect(v.trendsPeek):toBe(false)
        expect(v.evidenceDrawer):toBe(true)
    end)

    it("shows everything in full state", function()
        local v = Onb.SectionVisibility(Onb.STATE.FULL)
        for _, key in ipairs({
            "fidelityBar", "nextQueueFocus", "fightTimelineRead",
            "pillarScoreboard", "matchupPlan", "trendsPeek",
            "practicePlan", "evidenceDrawer",
        }) do
            if not v[key] then
                error("expected key '"..key.."' to be true in full state")
            end
        end
    end)
end)

describe("InsightsOnboarding.OnboardingMessage", function()
    it("returns nil for full state", function()
        expect(Onb.OnboardingMessage(Onb.STATE.FULL)):toBeNil()
    end)

    it("returns a non-empty message for cold + sparse", function()
        expect(type(Onb.OnboardingMessage(Onb.STATE.COLD))):toBe("string")
        expect(type(Onb.OnboardingMessage(Onb.STATE.SPARSE))):toBe("string")
    end)
end)
