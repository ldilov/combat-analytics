-- test/test_CounterGuide.lua
-- Build filter resolution for the Counters tab: the "All Builds" / "Current
-- Build" toggle must swap the threat / win-rate gauge inputs correctly and
-- fall back to all-builds data (never crash) when the current build is unplayed.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end

local ns = {
    Addon     = setmetatable({}, AddonShim),
    ApiCompat = {},
    Helpers   = {},
    Widgets   = { THEME = {} },
}

local function loadModule(path, chunkName)
    local f = io.open(path, "r")
    if not f then f = io.open("../" .. path, "r") end
    if not f then return false end
    local src = f:read("*a")
    f:close()
    local chunk = load(src, chunkName or ("@" .. path))
    if not chunk then return false end
    chunk("CombatAnalytics", ns)
    return true
end

loadModule("UI/CounterGuideView.lua", "@UI/CounterGuideView.lua")

local View = modules["CounterGuideView"]

if not View or not View._resolveBuildFilter then
    describe("counter guide build filter", function()
        it("module exposes _resolveBuildFilter", function()
            error("CounterGuideView._resolveBuildFilter not loaded — check file path / export.")
        end)
    end)
    return
end

local resolve = View._resolveBuildFilter

describe("CounterGuideView build filter resolution", function()
    it("all-builds mode uses the spec aggregate", function()
        local guide = { historicalFights = 10, historicalWinRate = 0.6 }
        local useCurrent, _, _, noData, fights, winRate = resolve("all", "hashA", guide)
        expect(useCurrent):toBe(false)
        expect(noData):toBe(false)
        expect(fights):toBe(10)
        expect(winRate):toBe(0.6)
    end)

    it("current mode with no build hash falls back to all-builds", function()
        local guide = { historicalFights = 12, historicalWinRate = 0.5 }
        local useCurrent, _, _, noData, fights, winRate = resolve("current", nil, guide)
        expect(useCurrent):toBe(false)
        expect(noData):toBe(false)
        expect(fights):toBe(12)
        expect(winRate):toBe(0.5)
    end)

    it("current mode with build data uses the current-build record", function()
        local guide = {
            historicalFights = 30, historicalWinRate = 0.5,
            currentBuildEffectiveness = { fights = 8, wins = 6 },
        }
        local useCurrent, _, cbeFights, noData, fights, winRate =
            resolve("current", "hashA", guide)
        expect(useCurrent):toBe(true)
        expect(cbeFights):toBe(8)
        expect(noData):toBe(false)
        expect(fights):toBe(8)
        expect(winRate):toBe(0.75)
    end)

    it("current mode with nil currentBuildEffectiveness flags noBuildData and falls back", function()
        local guide = { historicalFights = 20, historicalWinRate = 0.55 }
        local useCurrent, _, cbeFights, noData, fights, winRate =
            resolve("current", "hashA", guide)
        expect(useCurrent):toBe(true)
        expect(cbeFights):toBe(0)
        expect(noData):toBe(true)
        expect(fights):toBe(20)        -- fell back to the all-builds aggregate
        expect(winRate):toBe(0.55)
    end)

    it("current mode with zero build fights flags noBuildData", function()
        local guide = {
            historicalFights = 9, historicalWinRate = 0.4,
            currentBuildEffectiveness = { fights = 0, wins = 0 },
        }
        local _, _, cbeFights, noData, fights = resolve("current", "hashA", guide)
        expect(cbeFights):toBe(0)
        expect(noData):toBe(true)
        expect(fights):toBe(9)
    end)

    it("does not divide by zero or crash when build wins is nil", function()
        local guide = { currentBuildEffectiveness = { fights = 4 } }  -- wins absent
        local _, _, cbeFights, noData, fights, winRate =
            resolve("current", "hashA", guide)
        expect(cbeFights):toBe(4)
        expect(noData):toBe(false)
        expect(fights):toBe(4)
        expect(winRate):toBe(0)        -- (nil wins) coerced to 0
    end)

    it("all-builds mode tolerates a nil historicalWinRate", function()
        local guide = {}  -- no aggregate recorded at all
        local _, _, _, noData, fights, winRate = resolve("all", "hashA", guide)
        expect(noData):toBe(false)
        expect(fights):toBe(0)
        expect(winRate):toBeNil()
    end)
end)
