-- test/test_InsightsPillarMapper.lua
-- Unit tests for Insights/InsightsPillarMapper.lua

local ns = {}
local loader = assert(loadfile("Insights/InsightsPillarMapper.lua"))
local PM = loader("CombatAnalytics", ns)

describe("InsightsPillarMapper.GetPillarForReason", function()
    it("returns pressure for offensive codes", function()
        expect(PM.GetPillarForReason("LOW_PRESSURE_VS_BUILD_BASELINE")):toBe(PM.PILLAR.PRESSURE)
        expect(PM.GetPillarForReason("LATE_FIRST_GO")):toBe(PM.PILLAR.PRESSURE)
        expect(PM.GetPillarForReason("LOW_HEALER_PRESSURE")):toBe(PM.PILLAR.PRESSURE)
    end)

    it("returns survival for defensive codes", function()
        expect(PM.GetPillarForReason("DIED_WITH_DEFENSIVES")):toBe(PM.PILLAR.SURVIVAL)
        expect(PM.GetPillarForReason("REACTIVE_DEFENSIVE_LATE")):toBe(PM.PILLAR.SURVIVAL)
    end)

    it("returns control for CC codes", function()
        expect(PM.GetPillarForReason("TRINKET_TIMING_POOR")):toBe(PM.PILLAR.CONTROL)
        expect(PM.GetPillarForReason("POOR_INTERRUPT_RATE")):toBe(PM.PILLAR.CONTROL)
        expect(PM.GetPillarForReason("CC_CHAIN_BREAK")):toBe(PM.PILLAR.CONTROL)
    end)

    it("returns consistency for rhythm codes", function()
        expect(PM.GetPillarForReason("ROTATION_GAPS_OBSERVED")):toBe(PM.PILLAR.CONSISTENCY)
        expect(PM.GetPillarForReason("TILT_WARNING")):toBe(PM.PILLAR.CONSISTENCY)
    end)

    it("returns nil for matchup-flavoured codes", function()
        expect(PM.GetPillarForReason("SPEC_WINRATE_DEFICIT")):toBeNil()
        expect(PM.GetPillarForReason("SPEC_WINRATE_STRENGTH")):toBeNil()
        expect(PM.GetPillarForReason("COMP_DEFICIT")):toBeNil()
    end)

    it("returns nil for meta codes", function()
        expect(PM.GetPillarForReason("MIDNIGHT_SAFE_LIMITS")):toBeNil()
        expect(PM.GetPillarForReason("RAW_EVENT_OVERFLOW")):toBeNil()
    end)

    it("returns nil for unknown / nil input", function()
        expect(PM.GetPillarForReason(nil)):toBeNil()
        expect(PM.GetPillarForReason("")):toBeNil()
        expect(PM.GetPillarForReason("NOT_A_REAL_CODE")):toBeNil()
        expect(PM.GetPillarForReason(123)):toBeNil()
    end)
end)

describe("InsightsPillarMapper.Bucket", function()
    it("groups suggestions by pillar", function()
        local suggestions = {
            { reasonCode = "DIED_WITH_DEFENSIVES" },
            { reasonCode = "TRINKET_TIMING_POOR" },
            { reasonCode = "LATE_FIRST_GO" },
            { reasonCode = "REACTIVE_DEFENSIVE_LATE" },
            { reasonCode = "ROTATION_GAPS_OBSERVED" },
        }
        local buckets = PM.Bucket(suggestions)
        expect(#buckets[PM.PILLAR.PRESSURE]):toBe(1)
        expect(#buckets[PM.PILLAR.SURVIVAL]):toBe(2)
        expect(#buckets[PM.PILLAR.CONTROL]):toBe(1)
        expect(#buckets[PM.PILLAR.CONSISTENCY]):toBe(1)
    end)

    it("isolates matchup + meta codes into unbucketed", function()
        local suggestions = {
            { reasonCode = "DIED_WITH_DEFENSIVES" },
            { reasonCode = "SPEC_WINRATE_DEFICIT" },
            { reasonCode = "MIDNIGHT_SAFE_LIMITS" },
        }
        local buckets, unbucketed = PM.Bucket(suggestions)
        expect(#buckets[PM.PILLAR.SURVIVAL]):toBe(1)
        expect(#unbucketed):toBe(2)
    end)

    it("returns empty buckets for nil input", function()
        local buckets, unbucketed = PM.Bucket(nil)
        expect(#buckets[PM.PILLAR.PRESSURE]):toBe(0)
        expect(#unbucketed):toBe(0)
    end)

    it("skips entries with missing reasonCode", function()
        local buckets, unbucketed = PM.Bucket({
            { foo = "bar" },
            { reasonCode = "TRINKET_TIMING_POOR" },
        })
        expect(#buckets[PM.PILLAR.CONTROL]):toBe(1)
        expect(#unbucketed):toBe(1)  -- the foo=bar entry has no reasonCode
    end)
end)

describe("InsightsPillarMapper.PillarValue", function()
    it("returns metric value for the pillar", function()
        local session = {
            metrics = {
                pressureScore             = 72,
                survivabilityScore        = 58,
                ccControlScore            = 81,
                rotationConsistencyScore  = 67,
            },
        }
        expect(PM.PillarValue(session, PM.PILLAR.PRESSURE)):toBe(72)
        expect(PM.PillarValue(session, PM.PILLAR.SURVIVAL)):toBe(58)
        expect(PM.PillarValue(session, PM.PILLAR.CONTROL)):toBe(81)
        expect(PM.PillarValue(session, PM.PILLAR.CONSISTENCY)):toBe(67)
    end)

    it("returns nil when session.metrics missing", function()
        expect(PM.PillarValue({}, PM.PILLAR.PRESSURE)):toBeNil()
        expect(PM.PillarValue(nil, PM.PILLAR.PRESSURE)):toBeNil()
    end)

    it("returns nil when metric key missing", function()
        expect(PM.PillarValue({ metrics = {} }, PM.PILLAR.PRESSURE)):toBeNil()
    end)
end)

describe("InsightsPillarMapper.PILLARS ordering", function()
    it("is stable and length 4", function()
        expect(#PM.PILLARS):toBe(4)
        expect(PM.PILLARS[1]):toBe(PM.PILLAR.PRESSURE)
        expect(PM.PILLARS[4]):toBe(PM.PILLAR.CONSISTENCY)
    end)
end)

describe("InsightsPillarMapper.GetLabel", function()
    it("returns human-readable labels", function()
        expect(PM.GetLabel(PM.PILLAR.PRESSURE)):toBe("Pressure")
        expect(PM.GetLabel(PM.PILLAR.CONSISTENCY)):toBe("Consistency")
    end)
end)
