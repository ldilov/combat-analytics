-- test/test_DamageMeterHeuristics.lua
-- Regression tests for DamageMeter-only damage heuristics.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:Trace() end
function AddonShim:Warn() end
function AddonShim:Debug() end

local Constants = {
    CONTEXT = {
        ARENA = "arena",
        BATTLEGROUND = "battleground",
        DUEL = "duel",
        TRAINING_DUMMY = "training_dummy",
    },
    SPELL_CATEGORY = {
        OFFENSIVE = "offensive",
    },
    SPELL_CATEGORIES = {},
    PROVENANCE_SOURCE = {
        DAMAGE_METER = "damage_meter",
        ESTIMATED = "estimated",
    },
    IMPORT_STATUS = {
        IMPORTED_AUTHORITATIVE = "imported_authoritative",
        IMPORTED_CURRENT_SNAPSHOT = "imported_current_snapshot",
        IMPORTED_ENEMY_DAMAGE_TAKEN_FALLBACK = "imported_enemy_damage_taken_fallback",
        ESTIMATED_FROM_CASTS = "estimated_from_casts",
    },
}

local ns = {
    Addon = setmetatable({
        runtime = {},
    }, AddonShim),
    Constants = Constants,
    ApiCompat = {
        IsDamageMeterAvailable = function() return true end,
        GetAvailableCombatSessions = function() return {} end,
        GetPlayerGUID = function() return "Player-self" end,
        GetPlayerName = function() return "Self" end,
        GetSpellInfo = function(spellId)
            return { name = "Spell " .. tostring(spellId), iconID = 1 }
        end,
    },
    Helpers = {
        CountMapEntries = function(map)
            local count = 0
            for _ in pairs(map or {}) do
                count = count + 1
            end
            return count
        end,
    },
}

Enum = Enum or {}
Enum.DamageMeterType = Enum.DamageMeterType or {
    DamageDone = 1,
    EnemyDamageTaken = 2,
    HealingDone = 3,
    Absorbs = 4,
    Interrupts = 5,
    Dispels = 6,
    DamageTaken = 7,
    Deaths = 8,
    AvoidableDamageTaken = 9,
}
C_DamageMeter = C_DamageMeter or {}
GetCVarBool = GetCVarBool or function() return true end

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
    describe("DamageMeterService / heuristics", function()
        it("module loads", function()
            error("DamageMeterService module not loaded — check file path.")
        end)
    end)
    return
end

local function makeSpellAggregate(spellId, castCount)
    return {
        spellId = spellId,
        castCount = castCount or 0,
        executeCount = 0,
        hitCount = 0,
        critCount = 0,
        missCount = 0,
        totalDamage = 0,
        totalHealing = 0,
        overkill = 0,
        overhealing = 0,
        absorbed = 0,
        minHit = nil,
        maxHit = 0,
        minCrit = nil,
        maxCrit = 0,
        firstUse = nil,
        lastUse = nil,
        lastCastOffset = nil,
        totalInterval = 0,
        intervalCount = 0,
        averageInterval = 0,
    }
end

local function makeSession()
    return {
        id = "session-1",
        context = Constants.CONTEXT.ARENA,
        totals = {},
        importedTotals = {},
        localTotals = {},
        utility = {},
        survival = {},
        import = {},
        rawEvents = {},
        spells = {
            [123] = makeSpellAggregate(123, 3),
        },
    }
end

describe("DamageMeterService / heuristics", function()
    it("backfills cast-only spells from enemy damage taken in arena sessions", function()
        local session = makeSession()
        local ok = Service:ApplySnapshotToSession(session, {
            duration = 12,
            damageDone = 0,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
            interrupts = 0,
            dispels = 0,
            deaths = 0,
            damageSpells = {},
            healingSpells = {},
            absorbSpells = {},
            enemyDamageTaken = 180,
            enemyDamageSpells = {},
            localDamageSpellTotal = 0,
            enemyDamageSpellTotal = 0,
        })

        expect(ok):toBe(true)
        expect(session.totals.damageDone):toBe(180)
        expect(session.damageBreakdownSource):toBe("estimated_from_casts")
        expect(session.spells[123].totalDamage):toBe(180)
        expect(session.spells[123].estimated):toBe(true)
    end)

    it("keeps environmental damage as its own spell row when Damage Meter exposes spellID 0", function()
        local session = makeSession()
        session.spells = {}

        local ok = Service:ApplySnapshotToSession(session, {
            duration = 9,
            damageDone = 90,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
            interrupts = 0,
            dispels = 0,
            deaths = 0,
            damageSpells = {
                { spellID = 0, totalAmount = 90, overkillAmount = 0 },
            },
            healingSpells = {},
            absorbSpells = {},
            enemyDamageTaken = 0,
            enemyDamageSpells = {},
            localDamageSpellTotal = 90,
            enemyDamageSpellTotal = 0,
        })

        expect(ok):toBe(true)
        expect(session.spells[0].name):toBe("Environmental")
        expect(session.spells[0].totalDamage):toBe(90)
        expect(session.spells[0].syntheticKind):toBe("environmental")
    end)

    it("creates an unattributed bucket when total damage exists but no spell rows can explain it", function()
        local session = makeSession()
        session.spells = {}

        local ok = Service:ApplySnapshotToSession(session, {
            duration = 11,
            damageDone = 140,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
            interrupts = 0,
            dispels = 0,
            deaths = 0,
            damageSpells = {},
            healingSpells = {},
            absorbSpells = {},
            enemyDamageTaken = 0,
            enemyDamageSpells = {},
            localDamageSpellTotal = 0,
            enemyDamageSpellTotal = 0,
        })

        expect(ok):toBe(true)
        expect(session.spells[-1].name):toBe("Unattributed Damage")
        expect(session.spells[-1].totalDamage):toBe(140)
        expect(session.spells[-1].syntheticKind):toBe("unattributed_damage")
    end)

    it("prefers the current snapshot when historical candidates have no usable damage", function()
        local session = makeSession()

        Service.currentSessionSnapshot = nil
        Service.activeSessionBaselineId = 10
        Service.lastSeenSessionId = 10

        Service.IsSupported = function() return true end
        Service.IsAvailable = function() return true end
        Service.CaptureCurrentSessionSnapshot = function(self)
            self.currentSessionSnapshot = {
                duration = 14,
                damageDone = 0,
                healingDone = 0,
                damageTaken = 0,
                absorbed = 0,
                interrupts = 0,
                dispels = 0,
                deaths = 0,
                damageSpells = {},
                healingSpells = {},
                absorbSpells = {},
                enemyDamageTaken = 240,
                enemyDamageSpells = {},
                localDamageSpellTotal = 0,
                enemyDamageSpellTotal = 0,
            }
            return true
        end
        Service.FindSessionsForImport = function()
            return {
                { sessionID = 11 },
            }
        end
        Service.BuildHistoricalSnapshot = function(_, _, candidate, candidateId)
            return {
                snapshot = {
                    duration = 14,
                    damageDone = 0,
                    healingDone = 45,
                    damageTaken = 0,
                    absorbed = 0,
                    interrupts = 0,
                    dispels = 0,
                    deaths = 0,
                    damageSpells = {},
                    healingSpells = {},
                    absorbSpells = {},
                    enemyDamageTaken = 0,
                    enemyDamageSpells = {},
                    localDamageSpellTotal = 0,
                    enemyDamageSpellTotal = 0,
                },
                score = 96,
                damageEvidenceScore = 0,
                sessionId = candidateId,
                sessionInfo = candidate,
                durationDelta = 0,
                signalScore = 0,
                opponentFitScore = 0,
                enemySources = {},
            }
        end
        Service.ApplyPrimaryOpponent = function() end
        Service.GetLatestSessionId = function() return 12 end

        local ok = Service:ImportSession(session)

        expect(ok):toBe(true)
        expect(session.import.source):toBe("current")
        expect(session.totals.damageDone):toBe(240)
        expect(session.damageBreakdownSource):toBe("estimated_from_casts")
        expect(session.spells[123].totalDamage):toBe(240)
    end)
end)
