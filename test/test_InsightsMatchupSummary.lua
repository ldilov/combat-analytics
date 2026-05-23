-- test/test_InsightsMatchupSummary.lua

local ns = {}
local loader = assert(loadfile("Insights/InsightsMatchupSummary.lua"))
local Summary = loader("CombatAnalytics", ns)

local function sampleGuide()
    return {
        specId               = 250,
        specName             = "Blood Death Knight",
        archetypeLabel       = "melee_sustain",
        classFile            = "DEATHKNIGHT",
        rangeBucket          = "melee",
        threatTags           = { "tank-busting", "self-sustain" },
        ccFamilies           = {
            { spellId = 47476, family = "silence" },
            { spellId = 49203, family = "root" },
            { spellId = 47476, family = "silence" },
        },
        topSpellsFromOpponent = {
            { spellId = 49998, label = "Death Strike" },
            { spellId = 47632, label = "Death Coil" },
            { spellId = 55078, label = "Blood Plague" },
            { spellId = 49184, label = "Howling Blast" },
        },
        historicalWinRate    = 0.42,
        historicalFights     = 12,
        baselineThreatScore  = 67,
        recommendedActions   = { "Pre-cast defensive before fear", "Stop Death Coil", "Save Trinket for Asphyxiate", "Kite during runic dump" },
    }
end

describe("InsightsMatchupSummary.Build / happy path", function()
    it("returns a summary populated from guide + session", function()
        local guide = sampleGuide()
        local session = { primaryOpponent = { specId = 250, name = "Sponge", specName = "Blood Death Knight" } }
        local out = Summary.Build(session, guide)

        expect(out.specId):toBe(250)
        expect(out.specLabel):toBe("Blood Death Knight")
        expect(out.archetypeLabel):toBe("melee_sustain")
        expect(out.opponentName):toBe("Sponge")
        expect(out.threatScore):toBe(67)
        expect(out.historicalFights):toBe(12)
        expect(out.hasGuide):toBe(true)
        expect(out.hasData):toBe(true)
    end)

    it("formats winRateText with rounded percentage and fight count", function()
        local guide = sampleGuide()
        local out = Summary.Build({}, guide)
        expect(out.winRateText):toBe("Win rate 42% across 12 fights")
    end)

    it("caps recommended actions to the default limit (3)", function()
        local guide = sampleGuide()
        local out = Summary.Build({}, guide)
        expect(#out.recommendedActions):toBe(3)
    end)

    it("respects opts.actionLimit override", function()
        local guide = sampleGuide()
        local out = Summary.Build({}, guide, { actionLimit = 2 })
        expect(#out.recommendedActions):toBe(2)
    end)

    it("deduplicates cc family names and respects ccLimit", function()
        local guide = sampleGuide()
        local out = Summary.Build({}, guide, { ccLimit = 5 })
        expect(#out.ccFamilies):toBe(2)
        expect(out.ccFamilies[1]):toBe("silence")
        expect(out.ccFamilies[2]):toBe("root")
    end)

    it("caps topSpells to spellLimit", function()
        local guide = sampleGuide()
        local out = Summary.Build({}, guide, { spellLimit = 2 })
        expect(#out.topSpells):toBe(2)
    end)
end)

describe("InsightsMatchupSummary.Build / sparse inputs", function()
    it("handles missing guide gracefully", function()
        local session = { primaryOpponent = { specId = 250, name = "Sponge" } }
        local out = Summary.Build(session, nil)
        expect(out.specId):toBe(250)
        expect(out.hasGuide):toBe(false)
        expect(out.hasData):toBe(true)
        expect(out.winRateText):toBe(nil)
        expect(#out.recommendedActions):toBe(0)
        expect(#out.ccFamilies):toBe(0)
    end)

    it("omits winRateText when no fights have been recorded", function()
        local out = Summary.Build({}, {
            specId = 250, historicalFights = 0, historicalWinRate = nil,
        })
        expect(out.winRateText):toBe(nil)
    end)

    it("returns a fallback specLabel when no spec name is present", function()
        local out = Summary.Build({ primaryOpponent = {} }, nil)
        expect(out.specLabel):toBe("unknown spec")
    end)
end)

describe("InsightsMatchupSummary.HasMeaningfulData", function()
    it("returns false when no guide attached", function()
        expect(Summary.HasMeaningfulData(Summary.Build({}, nil))):toBe(false)
    end)

    it("returns false for empty guide with no fights / actions", function()
        local out = Summary.Build({}, { specId = 250, historicalFights = 0 })
        expect(Summary.HasMeaningfulData(out)):toBe(false)
    end)

    it("returns true once any meaningful field is populated", function()
        local out = Summary.Build({}, {
            specId = 250,
            historicalFights = 1,
            historicalWinRate = 1.0,
        })
        expect(Summary.HasMeaningfulData(out)):toBe(true)
    end)
end)
