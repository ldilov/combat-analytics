-- test/test_DummyPvpAnalytics.lua
-- Training dummy sessions should remain dummy-tagged while still feeding PvP analytics.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:Trace() end
function AddonShim:Warn() end
function AddonShim:GetLatestPlayerSnapshot()
    return {
        guid = "Player-self",
        name = "Self",
        realm = "Realm",
    }
end

date = date or function(format, value)
    if format == "%V" then
        return "14"
    end
    return os.date(format, value)
end
time = time or os.time
C_Timer = C_Timer or {
    After = function(_, callback)
        if callback then
            callback()
        end
    end,
}

local ns = {
    Addon = setmetatable({}, AddonShim),
    ApiCompat = {
        GetServerTime = function() return 123456 end,
        GetPlayerGUID = function() return "Player-self" end,
        GetPlayerName = function() return "Self" end,
        GetNormalizedRealmName = function() return "Realm" end,
        GetCurrentZoneName = function() return "Valdrakken", 1 end,
        GetPersonalRatedSoloShuffleSpecStats = function() return nil end,
        GetPersonalRatedBGBlitzSpecStats = function() return nil end,
    },
    StaticPvpData = {
        METRIC_THRESHOLDS = {
            minSamples = {
                buildFull = 30,
            },
        },
    },
}

local function loadModule(path, chunkName)
    local f = io.open(path, "r")
    if not f then
        f = io.open("../" .. path, "r")
    end
    if not f then
        return false
    end

    local src = f:read("*a")
    f:close()
    local chunk = load(src, chunkName or ("@" .. path))
    if not chunk then
        return false
    end
    chunk("CombatAnalytics", ns)
    return true
end

loadModule("Constants.lua", "@Constants.lua")
loadModule("Utils/Helpers.lua", "@Utils/Helpers.lua")
loadModule("CombatStore.lua", "@CombatStore.lua")

local Store = modules["CombatStore"]

if not Store then
    describe("training dummy PvP analytics", function()
        it("module loads", function()
            error("CombatStore module not loaded — check file path.")
        end)
    end)
    return
end

local function resetStore()
    CombatAnalyticsDB = nil
    Store:Initialize()
end

local function makeDummySession()
    return {
        id = "session-dummy-1",
        context = ns.Constants.CONTEXT.TRAINING_DUMMY,
        result = ns.Constants.SESSION_RESULT.UNKNOWN,
        timestamp = 123456,
        duration = 18,
        totals = {
            damageDone = 250000,
            healingDone = 0,
            damageTaken = 0,
        },
        survival = {
            deaths = 0,
        },
        metrics = {
            pressureScore = 0.82,
            burstScore = 0.61,
            survivabilityScore = 0.74,
            sustainedDps = 13888,
            burstDps = 25400,
            openerDamage = 94000,
            rotationalConsistencyScore = 0.88,
        },
        playerSnapshot = {
            guid = "Player-self",
            name = "Self",
            realm = "Realm",
            buildHash = "build-abc",
            specId = 577,
            specName = "Havoc",
            classFile = "DEMONHUNTER",
        },
        primaryOpponent = {
            guid = "Creature-dummy",
            name = "Raider's Training Dummy",
            specId = 577,
            specName = "Havoc",
            classFile = "DEMONHUNTER",
            className = "Demon Hunter",
        },
        openerSequence = {
            hash = "opener-hash",
            spellIds = { 198013, 162794, 258920 },
        },
        rawEvents = {},
        spells = {},
    }
end

describe("training dummy PvP analytics", function()
    it("treats training dummy as PvP analytics eligible without changing the context", function()
        expect(ns.Helpers.IsPvpAnalyticsContext(ns.Constants.CONTEXT.TRAINING_DUMMY)):toBe(true)
        expect(ns.Helpers.IsPvpAnalyticsContext(ns.Constants.CONTEXT.GENERAL)):toBe(false)
    end)

    it("feeds build and opener aggregates from dummy sessions", function()
        resetStore()
        local session = makeDummySession()

        Store:PersistSession(session)

        local buildEntry = Store:GetBuildEffectivenessVsSpec("build-abc", 577)
        expect(buildEntry):toNotBeNil()
        expect(buildEntry.fights):toBe(1)
        expect(buildEntry.other):toBe(1)

        local openerBuckets = Store:GetOpenerSequenceEffectiveness(577)
        expect(openerBuckets["opener-hash"]):toNotBeNil()
        expect(openerBuckets["opener-hash"].attempts):toBe(1)

        local characterKey = Store:GetSessionCharacterKey(session)
        local dummyBenchmarks = Store:GetDummyBenchmarks(characterKey)
        expect(#dummyBenchmarks):toBe(1)
        expect(dummyBenchmarks[1].dummyName):toBe("Raider's Training Dummy")
    end)
end)
