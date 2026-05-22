-- test/test_InsightsPriority.lua
-- Unit tests for Insights/InsightsPriority.lua
--
-- Run from repo root with:
--   lua test/TestRunner.lua && lua test/test_InsightsPriority.lua && lua -e "TestRunner.RunAll()"

-- ---------------------------------------------------------------------------
-- Minimal ns shim — InsightsPriority only reads ns.Constants.CONTROLLABILITY.
-- ---------------------------------------------------------------------------
local ns = {
    Constants = {
        CONTROLLABILITY = {
            DIED_WITH_DEFENSIVES  = 1.0,
            TRINKET_TIMING_POOR   = 0.9,
            HIGH_DAMAGE_TAKEN_VS_OPPONENT = 0.4,
            LOW_PRESSURE_VS_BUILD_BASELINE = 0.8,
        },
    },
}

-- The module is shipped as `local _, ns = ...; ns = ns or {}` so we have to
-- load it via the same vararg convention used by the WoW addon loader.
local loader = assert(loadfile("Insights/InsightsPriority.lua"))
local InsightsPriority = loader("CombatAnalytics", ns)

describe("InsightsPriority.Score", function()
    it("returns zero priority for non-table suggestion", function()
        local out = InsightsPriority.Score(nil)
        expect(out.priority):toBe(0)
        expect(out.severity):toBe(0)
        expect(out.confidence):toBe(0)
    end)

    it("uses severity table mapping", function()
        local out = InsightsPriority.Score({
            reasonCode = "DIED_WITH_DEFENSIVES",
            severity   = "high",
            confidence = 1.0,
        })
        -- sev 1.0 * conf 1.0 * recur 1.0 * ctrl 1.0 = 1.0
        expect(out.severity):toBe(1.0)
        expect(out.priority):toBe(1.0)
    end)

    it("falls back to medium severity for unknown labels", function()
        local out = InsightsPriority.Score({
            reasonCode = "TRINKET_TIMING_POOR",
            severity   = "unknown_label",
            confidence = 1.0,
        })
        expect(out.severity):toBe(0.55)
    end)

    it("clamps confidence into 0..1", function()
        local highOut = InsightsPriority.Score({
            reasonCode = "TRINKET_TIMING_POOR",
            severity   = "high",
            confidence = 2.5,
        })
        expect(highOut.confidence):toBe(1.0)

        local lowOut = InsightsPriority.Score({
            reasonCode = "TRINKET_TIMING_POOR",
            severity   = "high",
            confidence = -0.5,
        })
        expect(lowOut.confidence):toBe(0)
    end)

    it("uses default confidence when suggestion.confidence missing", function()
        local out = InsightsPriority.Score({
            reasonCode = "TRINKET_TIMING_POOR",
            severity   = "high",
        })
        expect(out.confidence):toBe(InsightsPriority._DEFAULT_CONFIDENCE)
    end)

    it("uses default controllability when reasonCode missing from table", function()
        local out = InsightsPriority.Score({
            reasonCode = "UNMAPPED_CODE",
            severity   = "high",
            confidence = 1.0,
        })
        expect(out.controllability):toBe(InsightsPriority._DEFAULT_CONTROLLABILITY)
    end)

    it("applies recurrence weight up to the cap", function()
        local recur = { TRINKET_TIMING_POOR = 100 }
        local out = InsightsPriority.Score({
            reasonCode = "TRINKET_TIMING_POOR",
            severity   = "high",
            confidence = 1.0,
        }, recur)
        -- count clamped to cap=4, weight = 1 + 0.5*4 = 3
        expect(out.recurrenceWeight):toBe(3.0)
    end)

    it("preserves reasonCode in the breakdown", function()
        local out = InsightsPriority.Score({
            reasonCode = "DIED_WITH_DEFENSIVES",
            severity   = "high",
        })
        expect(out.reasonCode):toBe("DIED_WITH_DEFENSIVES")
    end)
end)

describe("InsightsPriority.Rank", function()
    it("returns empty for non-table input", function()
        expect(#InsightsPriority.Rank(nil)):toBe(0)
    end)

    it("sorts highest priority first", function()
        local suggestions = {
            { reasonCode = "HIGH_DAMAGE_TAKEN_VS_OPPONENT", severity = "high",   confidence = 1.0 },
            { reasonCode = "DIED_WITH_DEFENSIVES",          severity = "high",   confidence = 1.0 },
            { reasonCode = "LOW_PRESSURE_VS_BUILD_BASELINE", severity = "medium", confidence = 1.0 },
        }
        local ranked = InsightsPriority.Rank(suggestions)
        expect(ranked[1].suggestion.reasonCode):toBe("DIED_WITH_DEFENSIVES")
        -- HIGH_DAMAGE has ctrl 0.4, so it drops below LOW_PRESSURE (0.8 ctrl * 0.55 sev = 0.44)
        -- vs HIGH_DAMAGE (1.0 sev * 1.0 conf * 1.0 recur * 0.4 ctrl = 0.40).
        expect(ranked[2].suggestion.reasonCode):toBe("LOW_PRESSURE_VS_BUILD_BASELINE")
        expect(ranked[3].suggestion.reasonCode):toBe("HIGH_DAMAGE_TAKEN_VS_OPPONENT")
    end)

    it("is stable on ties", function()
        local suggestions = {
            { reasonCode = "DIED_WITH_DEFENSIVES", severity = "high", confidence = 1.0, _id = "a" },
            { reasonCode = "DIED_WITH_DEFENSIVES", severity = "high", confidence = 1.0, _id = "b" },
            { reasonCode = "DIED_WITH_DEFENSIVES", severity = "high", confidence = 1.0, _id = "c" },
        }
        local ranked = InsightsPriority.Rank(suggestions)
        expect(ranked[1].suggestion._id):toBe("a")
        expect(ranked[2].suggestion._id):toBe("b")
        expect(ranked[3].suggestion._id):toBe("c")
    end)

    it("applies recurrence map across suggestions", function()
        local suggestions = {
            { reasonCode = "TRINKET_TIMING_POOR",  severity = "medium", confidence = 1.0 },
            { reasonCode = "DIED_WITH_DEFENSIVES", severity = "medium", confidence = 1.0 },
        }
        local recur = { TRINKET_TIMING_POOR = 4, DIED_WITH_DEFENSIVES = 0 }
        local ranked = InsightsPriority.Rank(suggestions, recur)
        -- TRINKET: 0.55 * 1 * 3.0 * 0.9 = 1.485
        -- DIED:    0.55 * 1 * 1.0 * 1.0 = 0.55
        expect(ranked[1].suggestion.reasonCode):toBe("TRINKET_TIMING_POOR")
    end)
end)

describe("InsightsPriority recurrence fallback", function()
    it("reads suggestion.recurrenceCount when no map passed", function()
        local out = InsightsPriority.Score({
            reasonCode      = "TRINKET_TIMING_POOR",
            severity        = "medium",
            confidence      = 1.0,
            recurrenceCount = 4,
        })
        -- weight = 1 + 0.5*4 = 3.0
        expect(out.recurrenceWeight):toBe(3.0)
    end)

    it("prefers explicit map over suggestion-attached count", function()
        local out = InsightsPriority.Score({
            reasonCode      = "TRINKET_TIMING_POOR",
            severity        = "medium",
            confidence      = 1.0,
            recurrenceCount = 4,
        }, { TRINKET_TIMING_POOR = 0 })
        -- map takes precedence; weight = 1.0
        expect(out.recurrenceWeight):toBe(1.0)
    end)
end)

describe("InsightsPriority.Top", function()
    it("returns nil for empty list", function()
        expect(InsightsPriority.Top({})):toBeNil()
    end)

    it("returns the single highest entry", function()
        local top = InsightsPriority.Top({
            { reasonCode = "LOW_PRESSURE_VS_BUILD_BASELINE", severity = "low",  confidence = 1.0 },
            { reasonCode = "DIED_WITH_DEFENSIVES",           severity = "high", confidence = 1.0 },
        })
        expect(top.suggestion.reasonCode):toBe("DIED_WITH_DEFENSIVES")
    end)
end)
