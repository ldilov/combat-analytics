-- test/test_MetricProvenance.lua
-- v10: per-metric provenance model.
--
-- Covers Phase A (Metrics.ComputeDerivedMetrics builds session.metrics.provenance)
-- and Phase B (SuggestionEngine suppresses a damage-derived suggestion when the
-- backing metric's provenance is LOW confidence).
--
-- The harness loads the REAL Constants/Math/Helpers/Metrics modules — these are
-- self-contained for ComputeDerivedMetrics (no GetModule / seed-data reads on
-- that path) — so the tests assert against genuine enum values and the real
-- metric arithmetic, guaranteeing the additive-only invariant is observable.

-- ---------------------------------------------------------------------------
-- Module loader
-- ---------------------------------------------------------------------------

local function loadModule(relPath, ns)
    local f = io.open(relPath, "r")
    if not f then
        f = io.open("../" .. relPath, "r")
    end
    if not f then return false end
    local src = f:read("*a")
    f:close()
    local chunk = load(src, "@" .. relPath)
    if not chunk then return false end
    chunk("CombatAnalytics", ns)
    return true
end

-- ---------------------------------------------------------------------------
-- Shared namespace — real Constants/Math/Helpers/Metrics
-- ---------------------------------------------------------------------------

local modules = {}
local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:Trace() end
function AddonShim:Debug() end
function AddonShim:Warn() end

-- Math.lua references a bare `Math` global table.
Math = Math or {}

local ns = {
    Addon = setmetatable({}, AddonShim),
    ApiCompat = {
        AuraIsBigDefensive = function() return false end,
    },
}

local loadedConstants = loadModule("Constants.lua", ns)
local loadedMath      = loadModule("Utils/Math.lua", ns)
ns.Math = ns.Math or Math
local loadedHelpers   = loadModule("Utils/Helpers.lua", ns)
local loadedMetrics   = loadModule("Utils/Metrics.lua", ns)

local Constants = ns.Constants
local Metrics   = ns.Metrics

-- ---------------------------------------------------------------------------
-- Session factory
-- ---------------------------------------------------------------------------

-- Build a minimal finalized-shape session sufficient for ComputeDerivedMetrics.
-- importAuthority — value for session.importedTotals.totalAuthority
-- castCoverage    — score for session.coverage.visibleCasts (nil = no coverage)
local function makeSession(importAuthority, castCoverage)
    local session = {
        id = "test-session",
        duration = 30,
        activeTime = 30,
        rawEvents = {
            { eventType = "damage", amount = 1000, sourceMine = true, timestampOffset = 1 },
            { eventType = "damage", amount = 1500, sourceMine = true, timestampOffset = 5 },
        },
        totals = { damageDone = 60000, damageTaken = 20000, healingDone = 5000 },
        effectiveDamageDone = 60000,
        windows = {},
        spells = {},
        survival = { defensivesUsed = 1, totalAbsorbed = 0 },
        utility = {},
        importedTotals = { totalAuthority = importAuthority },
    }
    if castCoverage ~= nil then
        session.coverage = {
            visibleCasts = { score = castCoverage },
            ccReceived   = { score = castCoverage },
        }
    end
    return session
end

-- ---------------------------------------------------------------------------
-- Phase A — provenance model
-- ---------------------------------------------------------------------------

describe("MetricProvenance / damage-derived confidence", function()
    if not loadedMetrics then
        it("modules load", function()
            error("Metrics module chain failed to load — check file paths.")
        end)
        return
    end

    it("rates damage metrics HIGH when the import is authoritative", function()
        local session = makeSession("authoritative", 0.9)
        Metrics.ComputeDerivedMetrics(session)
        local prov = session.metrics.provenance
        expect(prov):toNotBeNil()
        expect(prov.pressureScore.confidence):toBe(Constants.METRIC_CONFIDENCE.HIGH)
        expect(prov.burstScore.confidence):toBe(Constants.METRIC_CONFIDENCE.HIGH)
        expect(prov.sustainedDps.confidence):toBe(Constants.METRIC_CONFIDENCE.HIGH)
        expect(prov.pressureScore.basis):toBe("damage_meter_authoritative")
    end)

    it("rates damage metrics ESTIMATED for a scoreboard-anchored import", function()
        local session = makeSession("estimated", 0.9)
        Metrics.ComputeDerivedMetrics(session)
        local prov = session.metrics.provenance
        expect(prov.pressureScore.confidence):toBe(Constants.METRIC_CONFIDENCE.ESTIMATED)
        expect(prov.burstScore.confidence):toBe(Constants.METRIC_CONFIDENCE.ESTIMATED)
        expect(prov.pressureScore.basis):toBe("scoreboard_or_estimate")
    end)

    it("rates damage metrics LOW when the import failed", function()
        local session = makeSession("failed", 0.9)
        Metrics.ComputeDerivedMetrics(session)
        local prov = session.metrics.provenance
        expect(prov.pressureScore.confidence):toBe(Constants.METRIC_CONFIDENCE.LOW)
        expect(prov.sustainedDps.confidence):toBe(Constants.METRIC_CONFIDENCE.LOW)
        expect(prov.pressureScore.basis):toBe("no_damage_data")
    end)

    it("rates damage metrics LOW when there is no import record at all", function()
        local session = makeSession(nil, 0.9)
        Metrics.ComputeDerivedMetrics(session)
        expect(session.metrics.provenance.pressureScore.confidence)
            :toBe(Constants.METRIC_CONFIDENCE.LOW)
    end)
end)

describe("MetricProvenance / timeline-derived confidence", function()
    if not loadedMetrics then return end

    it("rates timeline metrics LOW when cast coverage is poor", function()
        local session = makeSession("authoritative", 0.2)
        Metrics.ComputeDerivedMetrics(session)
        local prov = session.metrics.provenance
        expect(prov.rotationalConsistencyScore.confidence)
            :toBe(Constants.METRIC_CONFIDENCE.LOW)
        expect(prov.procConversionScore.confidence)
            :toBe(Constants.METRIC_CONFIDENCE.LOW)
    end)

    it("rates timeline metrics HIGH when cast coverage is strong", function()
        local session = makeSession("authoritative", 0.85)
        Metrics.ComputeDerivedMetrics(session)
        expect(session.metrics.provenance.rotationalConsistencyScore.confidence)
            :toBe(Constants.METRIC_CONFIDENCE.HIGH)
    end)

    it("defaults timeline metrics to UNKNOWN when coverage is absent", function()
        local session = makeSession("authoritative", nil)
        Metrics.ComputeDerivedMetrics(session)
        expect(session.metrics.provenance.rotationalConsistencyScore.confidence)
            :toBe(Constants.METRIC_CONFIDENCE.UNKNOWN)
    end)
end)

describe("MetricProvenance / additive-only invariant", function()
    if not loadedMetrics then return end

    it("does not change metric VALUES — only adds the provenance table", function()
        -- Same inputs, two finalizations: numbers must be byte-identical.
        local a = makeSession("authoritative", 0.9)
        local b = makeSession("failed", 0.2)
        Metrics.ComputeDerivedMetrics(a)
        Metrics.ComputeDerivedMetrics(b)
        -- pressureScore arithmetic must not branch on provenance.
        expect(a.metrics.pressureScore):toBe(b.metrics.pressureScore)
        expect(a.metrics.burstScore):toBe(b.metrics.burstScore)
        expect(a.metrics.survivabilityScore):toBe(b.metrics.survivabilityScore)
        -- limitedBySource is still present for backward-compat.
        expect(a.metrics.limitedBySource ~= nil):toBeTruthy()
    end)
end)

-- ---------------------------------------------------------------------------
-- Phase B — SuggestionEngine gating
-- ---------------------------------------------------------------------------
-- The real SuggestionEngine is loaded into an isolated namespace with stubbed
-- modules so only the provenance gate is exercised.

describe("MetricProvenance / SuggestionEngine gating", function()
    -- Isolated namespace for SuggestionEngine.
    local seModules = {}
    local SEAddon = setmetatable({}, {
        __index = {
            GetModule = function(_, name) return seModules[name] end,
            RegisterModule = function(_, name, mod) seModules[name] = mod end,
            Trace = function() end, Debug = function() end, Warn = function() end,
        },
    })

    -- A build baseline well above the session's pressureScore so the
    -- LOW_PRESSURE_VS_BUILD_BASELINE suggestion would fire if not gated.
    local stubStore = {
        GetSessionCharacterKey = function() return "char" end,
        GetBuildBaseline = function()
            return { fights = 10, averagePressureScore = 90 }
        end,
        GetContextBaseline = function() return nil end,
        GetSessionBaseline = function() return nil end,
        GetDummyBenchmarks = function() return {} end,
        -- Post-processing dependencies (tilt warning, comp deficit, RICE counts).
        GetRecentSessionStreak = function() return {} end,
        GetPressureBaseline = function() return 0 end,
        GetCompWinRates = function() return {} end,
    }

    seModules.CombatStore = stubStore

    local seNs = {
        Addon = SEAddon,
        Constants = Constants,
        Helpers = ns.Helpers,
        ApiCompat = { GetSpellName = function() return "Spell" end },
    }
    local loadedSE = loadModule("SuggestionEngine.lua", seNs)
    local Engine = seModules.SuggestionEngine

    -- Build a session whose pressureScore is below the baseline.
    local function suggestionSession(pressureConfidence)
        return {
            id = "se-test",
            context = "arena",
            rawEvents = { { eventType = "damage", amount = 1 } },
            spells = {},
            survival = {},
            totals = { damageDone = 100, damageTaken = 100 },
            playerSnapshot = { buildHash = "bh" },
            metrics = {
                pressureScore = 10,  -- far below baseline 90
                provenance = {
                    pressureScore = { confidence = pressureConfidence, basis = "test" },
                },
            },
        }
    end

    local function hasReason(results, reasonCode)
        for _, s in ipairs(results or {}) do
            if s.reasonCode == reasonCode then return s end
        end
        return nil
    end

    if not loadedSE or not Engine then
        it("SuggestionEngine loads", function()
            error("SuggestionEngine failed to load — check file path / shims.")
        end)
        return
    end

    -- Assert against session.allSuggestions (the full unfiltered list) — the
    -- returned display list caps at 3 and drops early_signal-tier entries,
    -- which is unrelated to the provenance gate under test.
    it("suppresses a damage-derived suggestion when provenance is LOW", function()
        local session = suggestionSession(Constants.METRIC_CONFIDENCE.LOW)
        Engine:BuildSessionSuggestions(session)
        expect(hasReason(session.allSuggestions, "LOW_PRESSURE_VS_BUILD_BASELINE")):toBeNil()
    end)

    it("keeps the suggestion when provenance is HIGH", function()
        local session = suggestionSession(Constants.METRIC_CONFIDENCE.HIGH)
        Engine:BuildSessionSuggestions(session)
        local s = hasReason(session.allSuggestions, "LOW_PRESSURE_VS_BUILD_BASELINE")
        expect(s):toNotBeNil()
        expect(s.severity):toBe("medium")
    end)

    it("downgrades severity when provenance is ESTIMATED", function()
        local session = suggestionSession(Constants.METRIC_CONFIDENCE.ESTIMATED)
        Engine:BuildSessionSuggestions(session)
        local s = hasReason(session.allSuggestions, "LOW_PRESSURE_VS_BUILD_BASELINE")
        expect(s):toNotBeNil()
        -- medium downgraded one step → low
        expect(s.severity):toBe("low")
    end)
end)
