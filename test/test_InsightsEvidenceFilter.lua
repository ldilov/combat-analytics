-- test/test_InsightsEvidenceFilter.lua

local ns = {}
local loader = assert(loadfile("Insights/InsightsEvidenceFilter.lua"))
local EvidenceFilter = loader("CombatAnalytics", ns)

local CHIP = EvidenceFilter.CHIP

describe("InsightsEvidenceFilter.GetChipForReason", function()
    it("returns offense for opener / pressure codes", function()
        expect(EvidenceFilter.GetChipForReason("LATE_FIRST_GO")):toBe(CHIP.OFFENSE)
        expect(EvidenceFilter.GetChipForReason("LOW_HEALER_PRESSURE")):toBe(CHIP.OFFENSE)
    end)

    it("returns defense for survival codes", function()
        expect(EvidenceFilter.GetChipForReason("DEFENSIVE_DRIFT")):toBe(CHIP.DEFENSE)
        expect(EvidenceFilter.GetChipForReason("DIED_WITH_DEFENSIVES")):toBe(CHIP.DEFENSE)
    end)

    it("returns cc for trinket / interrupt / DR codes", function()
        expect(EvidenceFilter.GetChipForReason("TRINKET_TIMING_POOR")):toBe(CHIP.CC)
        expect(EvidenceFilter.GetChipForReason("CC_DR_WASTE")):toBe(CHIP.CC)
    end)

    it("returns matchup for spec / comp codes", function()
        expect(EvidenceFilter.GetChipForReason("SPEC_WINRATE_DEFICIT")):toBe(CHIP.MATCHUP)
        expect(EvidenceFilter.GetChipForReason("COMP_DEFICIT")):toBe(CHIP.MATCHUP)
    end)

    it("returns consistency for rotation / tilt codes", function()
        expect(EvidenceFilter.GetChipForReason("ROTATION_GAPS_OBSERVED")):toBe(CHIP.CONSISTENCY)
        expect(EvidenceFilter.GetChipForReason("TILT_WARNING")):toBe(CHIP.CONSISTENCY)
    end)

    it("returns meta for unmapped codes", function()
        expect(EvidenceFilter.GetChipForReason("NEW_UNMAPPED_CODE")):toBe(CHIP.META)
        expect(EvidenceFilter.GetChipForReason(nil)):toBe(CHIP.META)
    end)
end)

describe("InsightsEvidenceFilter.CountByChip", function()
    it("counts each chip and provides total", function()
        local suggestions = {
            { reasonCode = "LATE_FIRST_GO" },
            { reasonCode = "DEFENSIVE_DRIFT" },
            { reasonCode = "DEFENSIVE_DRIFT" },
            { reasonCode = "ROTATION_GAPS_OBSERVED" },
            { reasonCode = "MIDNIGHT_SAFE_LIMITS" },
        }
        local c = EvidenceFilter.CountByChip(suggestions)
        expect(c.total):toBe(5)
        expect(c[CHIP.OFFENSE]):toBe(1)
        expect(c[CHIP.DEFENSE]):toBe(2)
        expect(c[CHIP.CONSISTENCY]):toBe(1)
        expect(c[CHIP.META]):toBe(1)
        expect(c[CHIP.ALL]):toBe(5)
    end)

    it("handles non-table input safely", function()
        local c = EvidenceFilter.CountByChip(nil)
        expect(c.total):toBe(0)
        expect(c[CHIP.OFFENSE]):toBe(0)
    end)
end)

describe("InsightsEvidenceFilter.FilterByChip", function()
    local suggestions = {
        { reasonCode = "LATE_FIRST_GO" },
        { reasonCode = "DEFENSIVE_DRIFT" },
        { reasonCode = "DEFENSIVE_DRIFT" },
        { reasonCode = "ROTATION_GAPS_OBSERVED" },
    }

    it("returns full list for CHIP.ALL (or nil)", function()
        expect(#EvidenceFilter.FilterByChip(suggestions, CHIP.ALL)):toBe(4)
        expect(#EvidenceFilter.FilterByChip(suggestions, nil)):toBe(4)
    end)

    it("filters to a single chip", function()
        local filtered = EvidenceFilter.FilterByChip(suggestions, CHIP.DEFENSE)
        expect(#filtered):toBe(2)
        expect(filtered[1].reasonCode):toBe("DEFENSIVE_DRIFT")
    end)

    it("returns empty list when chip is absent", function()
        expect(#EvidenceFilter.FilterByChip(suggestions, CHIP.CC)):toBe(0)
    end)

    it("does not mutate the original list", function()
        local out = EvidenceFilter.FilterByChip(suggestions, CHIP.OFFENSE)
        expect(#suggestions):toBe(4)
        expect(#out):toBe(1)
    end)
end)
