-- test/test_SessionDiscovery.lua
-- SessionClassifier discovery tests for Midnight-safe non-CLEU state surfaces.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end

local Constants = {
    CONTEXT = {
        DUEL = "duel",
        ARENA = "arena",
        BATTLEGROUND = "battleground",
        WORLD_PVP = "world_pvp",
        TRAINING_DUMMY = "training_dummy",
        GENERAL = "general",
    },
    SUBCONTEXT = {
        TO_THE_DEATH = "to_the_death",
        UNKNOWN_ARENA = "unknown_arena",
        RANDOM_BATTLEGROUND = "random_battleground",
        TRAINING_GROUNDS = "training_grounds",
    },
    TRAINING_DUMMY_PROMOTION_THRESHOLD = 70,
    TRAINING_DUMMY_PATTERNS = {
        "training dummy",
    },
    TRAINING_DUMMY_CREATURE_IDS = {
        [111111] = true,
    },
    PRACTICE_ZONE_MAP_IDS = {
        [110] = true,  -- Silvermoon City (test stand-in)
    },
}

local ns = {
    Addon = setmetatable({
        runtime = {},
        GetSetting = function(_, key)
            if key == "includeGeneralCombat" then
                return false
            end
            return nil
        end,
    }, AddonShim),
    Constants = Constants,
    Helpers = {
        Now = function() return 100 end,
        IsBlank = function(value)
            return tostring(value or ""):match("^%s*$") ~= nil
        end,
        Trim = function(value)
            return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
        ContainsIgnoreCase = function(haystack, needle)
            return tostring(haystack or ""):lower():find(tostring(needle or ""):lower(), 1, true) ~= nil
        end,
    },
    StaticPvpData = {
        IsTrainingDummyName = function(name)
            return tostring(name or ""):lower():find("training dummy", 1, true) ~= nil
        end,
    },
}

local apiState = {
    arena = false,
    battleground = false,
    soloShuffle = false,
    trainingGrounds = false,
}

local currentZone = { name = "Test Zone", mapId = 1 }

ns.ApiCompat = {
    GetCurrentZoneName = function() return currentZone.name, currentZone.mapId end,
    GetServerTime = function() return 1000 end,
    GetPlayerGUID = function() return "Player-self" end,
    IsGuidPet = function(guid) return type(guid) == "string" and guid:sub(1, 4) == "Pet-" end,
    IsGuidPlayer = function(guid) return type(guid) == "string" and guid:sub(1, 7) == "Player-" end,
    IsMatchConsideredArena = function() return apiState.arena end,
    IsSoloShuffle = function() return apiState.soloShuffle end,
    IsBattleground = function() return apiState.battleground end,
    IsWargame = function() return false end,
    IsRatedArena = function() return false end,
    IsArenaSkirmish = function() return false end,
    IsInBrawl = function() return false end,
    IsRatedSoloRBG = function() return false end,
    IsSoloRBG = function() return false end,
    IsRatedBattleground = function() return false end,
    AreTrainingGroundsEnabled = function() return apiState.trainingGrounds end,
    UnitExists = function(unitToken) return WowMock.units[unitToken] ~= nil end,
    GetUnitGUID = function(unitToken) return WowMock.units[unitToken] and WowMock.units[unitToken].guid or nil end,
    GetUnitName = function(unitToken) return WowMock.units[unitToken] and WowMock.units[unitToken].name or nil end,
    UnitIsPlayer = function(unitToken) return WowMock.units[unitToken] and WowMock.units[unitToken].isPlayer or false end,
    UnitCanAttack = function(_, unitToken) return WowMock.units[unitToken] and WowMock.units[unitToken].isHostile or false end,
    UnitIsEnemy = function(_, unitToken) return WowMock.units[unitToken] and WowMock.units[unitToken].isHostile or false end,
    GetCreatureIdFromGUID = function(guid)
        for _, unit in pairs(WowMock.units) do
            if unit.guid == guid then
                return unit.creatureId
            end
        end
        return nil
    end,
}

modules["UnitGraphService"] = {
    GetHostileCandidates = function(_, preferredToken)
        local candidates = {}
        local ordered = {}
        if preferredToken then
            ordered[#ordered + 1] = preferredToken
        end
        ordered[#ordered + 1] = "target"
        ordered[#ordered + 1] = "focus"
        ordered[#ordered + 1] = "nameplate1"
        ordered[#ordered + 1] = "nameplate2"
        for _, token in ipairs(ordered) do
            local unit = WowMock.units[token]
            if unit and unit.isHostile then
                candidates[#candidates + 1] = {
                    unitToken = token,
                    guid = unit.guid,
                    isPlayer = unit.isPlayer,
                    isPet = unit.isPet,
                }
            end
        end
        return candidates
    end,
}

local chunk
do
    local f = io.open("SessionClassifier.lua", "r")
    if not f then
        f = io.open("../SessionClassifier.lua", "r")
    end
    if f then
        local src = f:read("*a")
        f:close()
        chunk = load(src, "@SessionClassifier.lua")
    end
end

if chunk then
    chunk("CombatAnalytics", ns)
end

local Classifier = modules["SessionClassifier"]

if not Classifier then
    describe("SessionClassifier / discovery", function()
        it("module loads", function()
            error("SessionClassifier module not loaded — check file path.")
        end)
    end)
    return
end

local function resetState()
    WowMock.Reset()
    ns.Addon.runtime.pendingDuel = nil
    apiState.arena = false
    apiState.battleground = false
    apiState.soloShuffle = false
    apiState.trainingGrounds = false
    currentZone.name = "Test Zone"
    currentZone.mapId = 1
    if Classifier and Classifier.RefreshZone then
        Classifier:RefreshZone()
    end
end

describe("SessionClassifier / state-surface discovery", function()
    it("resolves world PvP from a hostile visible nameplate when target/focus is absent", function()
        resetState()
        WowMock.SetUnit("nameplate1", {
            guid = "Player-123",
            name = "EnemyRogue",
            class = "Rogue",
            classFile = "ROGUE",
            isPlayer = true,
            isHostile = true,
        })

        local context, subcontext, unitToken = Classifier:ResolveContextFromState()
        expect(context):toBe(Constants.CONTEXT.WORLD_PVP)
        expect(subcontext):toBeNil()
        expect(unitToken):toBe("nameplate1")
    end)

    it("resolves training dummy from a hostile visible nameplate when target/focus is absent", function()
        resetState()
        WowMock.SetUnit("nameplate1", {
            guid = "Creature-0-0-0-0-111111-0000000000",
            name = "Raider's Training Dummy",
            class = nil,
            classFile = nil,
            isPlayer = false,
            isHostile = true,
            creatureId = 111111,
        })

        local context, subcontext, unitToken = Classifier:ResolveContextFromState()
        expect(context):toBe(Constants.CONTEXT.TRAINING_DUMMY)
        expect(subcontext):toBeNil()
        expect(unitToken):toBe("nameplate1")
    end)

    it("ignores hostile pets for top-level context discovery", function()
        resetState()
        WowMock.SetUnit("nameplate1", {
            guid = "Pet-777",
            name = "Felguard",
            class = nil,
            classFile = nil,
            isPlayer = false,
            isHostile = true,
            isPet = true,
        })

        local context = Classifier:ResolveContextFromState()
        expect(context):toBeNil()
    end)

    it("promotes name-matched dummy with 'normal' classification (12.0.5 regression fix)", function()
        resetState()
        -- CID 222222 is NOT in TRAINING_DUMMY_CREATURE_IDS, only name matches.
        WowMock.SetUnit("target", {
            guid = "Creature-0-0-0-0-222222-0000000000",
            name = "Training Dummy",
            isPlayer = false,
            isHostile = true,
            creatureId = 222222,
            classification = "normal",
        })

        local context, _, unitToken = Classifier:ResolveContextFromState()
        expect(context):toBe(Constants.CONTEXT.TRAINING_DUMMY)
        expect(unitToken):toBe("target")
    end)

    it("rejects name-matched 'elite' NPC (avoid false positive on real combatants)", function()
        resetState()
        WowMock.SetUnit("target", {
            guid = "Creature-0-0-0-0-333333-0000000000",
            name = "Training Dummy Overseer",
            isPlayer = false,
            isHostile = true,
            creatureId = 333333,
            classification = "elite",
        })

        local context = Classifier:ResolveContextFromState()
        expect(context):toBeNil()
    end)

    it("promotes unknown 'dummy'-named NPC via practice-zone fallback", function()
        resetState()
        currentZone.mapId = 110  -- Silvermoon
        Classifier:RefreshZone()
        WowMock.SetUnit("target", {
            guid = "Creature-0-0-0-0-444444-0000000000",
            name = "Combat Dummy",  -- doesn't match "training dummy" pattern
            isPlayer = false,
            isHostile = true,
            creatureId = 444444,
            classification = "normal",
        })

        local context, _, unitToken = Classifier:ResolveContextFromState()
        expect(context):toBe(Constants.CONTEXT.TRAINING_DUMMY)
        expect(unitToken):toBe("target")
    end)

    it("does NOT zone-promote unknown 'dummy' NPC with elite classification", function()
        resetState()
        currentZone.mapId = 110
        Classifier:RefreshZone()
        WowMock.SetUnit("target", {
            guid = "Creature-0-0-0-0-555555-0000000000",
            name = "Dummy Champion",
            isPlayer = false,
            isHostile = true,
            creatureId = 555555,
            classification = "elite",
        })

        local context = Classifier:ResolveContextFromState()
        expect(context):toBeNil()
    end)

    it("does NOT zone-promote outside a practice zone", function()
        resetState()
        currentZone.mapId = 9999  -- not in PRACTICE_ZONE_MAP_IDS
        Classifier:RefreshZone()
        WowMock.SetUnit("target", {
            guid = "Creature-0-0-0-0-666666-0000000000",
            name = "Combat Dummy",
            isPlayer = false,
            isHostile = true,
            creatureId = 666666,
            classification = "normal",
        })

        local context = Classifier:ResolveContextFromState()
        expect(context):toBeNil()
    end)
end)
