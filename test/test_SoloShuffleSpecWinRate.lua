-- test/test_SoloShuffleSpecWinRate.lua
-- Solo Shuffle per-spec win rate: the Counters tab derives win rate vs enemy
-- specs met only in Solo Shuffle rounds. Exercises the pure round-scan helper
-- CombatStore._computeSoloShuffleWinRate, which must exclude irregular,
-- nil-result and specsIncomplete rounds, count a spec once per round, and
-- report `matches` (distinct sessions) as an honest sample-size signal.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end

-- CombatStore only dereferences these inside functions, so empty-ish stubs are
-- enough to let the chunk load. Constants carries the enum values the pure
-- helper compares against.
local ns = {
    Addon     = setmetatable({}, AddonShim),
    ApiCompat = {},
    Helpers   = {},
    Constants = {
        SCHEMA_VERSION = 2,
        SUBCONTEXT    = { SOLO_SHUFFLE = "solo_shuffle" },
        SESSION_RESULT = { WON = "won", LOST = "lost" },
        AGGREGATE_KIND = { SPEC = "spec" },
        MMR_BANDS      = {},
        DEFAULT_SETTINGS = {},
    },
}

local function loadModule(path, chunkName)
    local f = io.open(path, "r")
    if not f then f = io.open("../" .. path, "r") end
    if not f then return false end
    local src = f:read("*a")
    f:close()
    local chunk = load(src, chunkName or ("@" .. path))
    if not chunk then return false end
    local ok = pcall(chunk, "CombatAnalytics", ns)
    return ok
end

loadModule("CombatStore.lua", "@CombatStore.lua")

local Store = modules["CombatStore"]
local compute = Store and Store._computeSoloShuffleWinRate

if not compute then
    describe("solo shuffle spec win rate", function()
        it("CombatStore._computeSoloShuffleWinRate is exported", function()
            error("CombatStore._computeSoloShuffleWinRate not loaded — check export.")
        end)
    end)
    return
end

-- ── mock builders ────────────────────────────────────────────────────────────
local function round(result, opponentSpecs, extra)
    local r = { result = result, opponentSpecs = opponentSpecs }
    if extra then
        for k, v in pairs(extra) do r[k] = v end
    end
    return r
end

local function ssSession(rounds)
    return { subcontext = "solo_shuffle", arena = { rounds = rounds } }
end

-- spec IDs used in tests
local MM, RESTO, FROST = 254, 105, 64

describe("CombatStore._computeSoloShuffleWinRate", function()
    it("returns zeroed result with nil winRate for an empty session list", function()
        local r = compute({}, MM)
        expect(r.rounds):toBe(0)
        expect(r.wins):toBe(0)
        expect(r.winRate):toBeNil()
        expect(r.matches):toBe(0)
    end)

    it("returns zeroed result when specId is nil", function()
        local r = compute({ ssSession({ round("won", { MM }) }) }, nil)
        expect(r.rounds):toBe(0)
        expect(r.winRate):toBeNil()
    end)

    it("counts wins and losses for rounds where the spec is present", function()
        local s = ssSession({
            round("won",  { MM, RESTO }),
            round("lost", { MM, FROST }),
            round("won",  { MM, RESTO }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(3)
        expect(r.wins):toBe(2)
        expect(r.losses):toBe(1)
        expect(r.winRate):toBe(2 / 3)
        expect(r.matches):toBe(1)
    end)

    it("ignores rounds where the spec is not present", function()
        local s = ssSession({
            round("won",  { RESTO, FROST }),
            round("lost", { MM, RESTO }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
        expect(r.losses):toBe(1)
    end)

    it("excludes irregular rounds from numerator and denominator", function()
        local s = ssSession({
            round("won",  { MM }),
            round("lost", { MM }, { irregular = true }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
        expect(r.wins):toBe(1)
        expect(r.winRate):toBe(1)
    end)

    it("excludes rounds with a nil result", function()
        local s = ssSession({
            round("won", { MM }),
            round(nil,   { MM }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
    end)

    it("excludes specsIncomplete rounds (unresolved enemy spec)", function()
        local s = ssSession({
            round("won",  { MM }),
            round("lost", { MM }, { specsIncomplete = true }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
        expect(r.wins):toBe(1)
    end)

    it("counts a spec at most once per round when it appears twice", function()
        local s = ssSession({
            round("won", { MM, MM, RESTO }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
        expect(r.wins):toBe(1)
    end)

    it("ignores sessions that are not Solo Shuffle", function()
        local arenaSession = { subcontext = "rated_arena", arena = { rounds = {
            round("won", { MM }),
        } } }
        local r = compute({ arenaSession }, MM)
        expect(r.rounds):toBe(0)
    end)

    it("matches counts distinct Solo Shuffle sessions the spec appeared in", function()
        local s1 = ssSession({ round("won", { MM }), round("lost", { MM }) })
        local s2 = ssSession({ round("won", { MM }) })
        local s3 = ssSession({ round("won", { RESTO }) })  -- MM absent
        local r = compute({ s1, s2, s3 }, MM)
        expect(r.rounds):toBe(3)
        expect(r.wins):toBe(2)
        expect(r.matches):toBe(2)
    end)

    it("does not crash on a session with nil arena", function()
        local r = compute({ { subcontext = "solo_shuffle" } }, MM)
        expect(r.rounds):toBe(0)
    end)

    it("does not crash on a session with nil arena.rounds", function()
        local r = compute({ { subcontext = "solo_shuffle", arena = {} } }, MM)
        expect(r.rounds):toBe(0)
    end)

    it("tolerates an empty opponentSpecs list on a round", function()
        local s = ssSession({
            round("won", {}),
            round("won", { MM }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(1)
    end)

    it("excludes a round whose result is neither won nor lost", function()
        -- A non-decisive result (Solo Shuffle has none in practice, but the
        -- isWin/isLoss guard must still drop it from rounds AND matches).
        local s = ssSession({
            round("draw", { MM }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(0)
        expect(r.matches):toBe(0)
    end)

    it("reports zero matches when the spec appears only in excluded rounds", function()
        local s = ssSession({
            round("won",  { MM }, { irregular = true }),
            round("lost", { MM }, { specsIncomplete = true }),
        })
        local r = compute({ s }, MM)
        expect(r.rounds):toBe(0)
        expect(r.matches):toBe(0)
        expect(r.winRate):toBeNil()
    end)
end)
