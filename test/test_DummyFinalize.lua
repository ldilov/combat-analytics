-- test/test_DummyFinalize.lua
-- Training dummy sessions should finalize after idle even if combat has not
-- cleanly dropped yet, so they are persisted and visible in Summary.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:GetSetting() return false end
function AddonShim:Trace() end
function AddonShim:Warn() end
function AddonShim:Debug() end

local nowValue = 0

local ns = {
    Addon = setmetatable({
        runtime = {},
    }, AddonShim),
    Constants = {
        CLEU_FLAGS = {
            AFFILIATION_MINE = 0,
            TYPE_PLAYER = 0,
            REACTION_HOSTILE = 0,
        },
        CONTEXT = {
            ARENA = "arena",
            BATTLEGROUND = "battleground",
            DUEL = "duel",
            WORLD_PVP = "world_pvp",
            TRAINING_DUMMY = "training_dummy",
            GENERAL = "general",
        },
        DAMAGE_SETTLE_DELAY = {
            arena = 3.0,
            battleground = 2.0,
            duel = 1.0,
            world_pvp = 1.0,
            training_dummy = 0.5,
            general = 0.5,
        },
        WORLD_PVP_IDLE_TIMEOUT = 8,
        DUEL_IDLE_TIMEOUT = 6,
        TRAINING_DUMMY_IDLE_TIMEOUT = 2,
        GENERAL_IDLE_TIMEOUT = 3,
        IMPORT_AUTHORITY = {
            authoritative = {},
            estimated = {},
            failed = {},
        },
    },
    ApiCompat = {
        GetPlayerGUID = function() return "Player-self" end,
        IsGuidPet = function() return false end,
    },
    Helpers = {
        Now = function() return nowValue end,
    },
}

local chunk
do
    local f = io.open("CombatTracker.lua", "r")
    if not f then
        f = io.open("../CombatTracker.lua", "r")
    end
    if f then
        local src = f:read("*a")
        f:close()
        chunk = load(src, "@CombatTracker.lua")
    end
end

if chunk then
    chunk("CombatAnalytics", ns)
end

local Tracker = modules["CombatTracker"]

if not Tracker then
    describe("CombatTracker / dummy timeout finalization", function()
        it("module loads", function()
            error("CombatTracker module not loaded — check file path.")
        end)
    end)
    return
end

describe("CombatTracker / dummy timeout finalization", function()
    it("finalizes idle training dummy sessions even if playerInCombat is still true", function()
        local finalizedReason = nil
        Tracker.playerInCombat = true
        ns.Addon.runtime.currentSession = {
            id = "dummy-1",
            state = "active",
            context = ns.Constants.CONTEXT.TRAINING_DUMMY,
            lastRelevantAt = 0,
        }

        Tracker.FinalizeSession = function(_, _, reason)
            finalizedReason = reason
        end

        nowValue = 3
        Tracker:OnUpdate()

        expect(finalizedReason):toBe("timeout")
    end)

    it("does not timeout active arena sessions while playerInCombat remains true", function()
        local finalizedReason = nil
        Tracker.playerInCombat = true
        ns.Addon.runtime.currentSession = {
            id = "arena-1",
            state = "active",
            context = ns.Constants.CONTEXT.ARENA,
            lastRelevantAt = 0,
        }

        Tracker.FinalizeSession = function(_, _, reason)
            finalizedReason = reason
        end

        nowValue = 10
        Tracker:OnUpdate()

        expect(finalizedReason):toBeNil()
    end)
end)
