-- test/test_DamageMeterBaseline.lua
-- Guards against late session autodiscovery resetting the DM baseline.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:Trace() end

local apiState = {
    sessions = {},
}

local ns = {
    Addon = setmetatable({
        runtime = {},
    }, AddonShim),
    Constants = {},
    ApiCompat = {
        GetAvailableCombatSessions = function()
            return apiState.sessions
        end,
        IsDamageMeterAvailable = function()
            return true
        end,
        GetPlayerGUID = function()
            return "Player-self"
        end,
        GetPlayerName = function()
            return "Self"
        end,
    },
    Helpers = {},
}

Enum = Enum or {}
Enum.DamageMeterType = Enum.DamageMeterType or {}
C_DamageMeter = C_DamageMeter or {}

GetCVarBool = GetCVarBool or function()
    return true
end

local chunk
do
    local f = io.open("DamageMeterService.lua", "r")
    if not f then
        f = io.open("../DamageMeterService.lua", "r")
    end
    if f then
        local src = f:read("*a")
        f:close()
        chunk = load(src, "@DamageMeterService.lua")
    end
end

if chunk then
    chunk("CombatAnalytics", ns)
end

local Service = modules["DamageMeterService"]

if not Service then
    describe("DamageMeterService / baseline reuse", function()
        it("module loads", function()
            error("DamageMeterService module not loaded — check file path.")
        end)
    end)
    return
end

describe("DamageMeterService / baseline reuse", function()
    it("preserves the earliest combat baseline across late session discovery", function()
        apiState.sessions = {
            { sessionID = 10 },
        }
        Service:Initialize()
        Service:MarkSessionStart()

        expect(Service.activeSessionBaselineId):toBe(10)

        Service.currentSessionSnapshot = { damageDone = 12345 }
        Service.sessionUpdateSignals = {
            [11] = { count = 1 },
        }

        apiState.sessions = {
            { sessionID = 10 },
            { sessionID = 11 },
        }

        Service:MarkSessionStart()

        expect(Service.activeSessionBaselineId):toBe(10)
        expect(Service.currentSessionSnapshot.damageDone):toBe(12345)
        expect(Service.sessionUpdateSignals[11].count):toBe(1)
    end)
end)

describe("DamageMeterService / scoreboard player damage", function()
    it("returns the player's damageDone from the post-match scoreboard row", function()
        local session = {
            postMatchScores = {
                { guid = "Player-enemy", name = "Foe", damageDone = 999 },
                { guid = "Player-self", name = "Self", damageDone = 250000 },
            },
        }
        expect(Service:GetScoreboardPlayerDamage(session)):toBe(250000)
    end)

    it("returns nil when the session has no post-match scoreboard", function()
        expect(Service:GetScoreboardPlayerDamage({})):toBeNil()
    end)

    it("returns nil when the player's scoreboard damage is zero (secret-sanitized)", function()
        local session = {
            postMatchScores = {
                { guid = "Player-self", name = "Self", damageDone = 0 },
            },
        }
        expect(Service:GetScoreboardPlayerDamage(session)):toBeNil()
    end)

    it("matches the player row by name when guid is absent", function()
        local session = {
            postMatchScores = {
                { guid = nil, name = "Self", damageDone = 71000 },
            },
        }
        expect(Service:GetScoreboardPlayerDamage(session)):toBe(71000)
    end)

    it("returns nil when no row belongs to the player", function()
        local session = {
            postMatchScores = {
                { guid = "Player-enemy", name = "Foe", damageDone = 123 },
            },
        }
        expect(Service:GetScoreboardPlayerDamage(session)):toBeNil()
    end)
end)
