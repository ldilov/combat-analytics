-- test/test_ScoreboardAnchor.lua
-- Regression coverage for the arena scoreboard-anchor stickiness fix.
--
-- Background: ApplyScoreboardAnchorIfNeeded substitutes the post-match PvP
-- scoreboard damage row when a C_DamageMeter import produces no usable total.
-- ANCHORED_FROM_SCOREBOARD maps to the `estimated` authority tier. A bug in the
-- post-finalization retry paths (T021 + the deferred re-import) allowed a late
-- DAMAGE_METER_COMBAT_SESSION_UPDATED event to re-import a positive-but-WORSE
-- estimated DM total over an already-anchored authoritative scoreboard total —
-- ApplyScoreboardAnchorIfNeeded's `damageDone > 0` guard returns early, so the
-- regression sticks. RestoreScoreboardAnchorIfRegressed is the targeted fix.
--
-- WHAT THIS TEST COVERS:
--   * ApplyScoreboardAnchorIfNeeded decision logic — anchors on zero/failed,
--     no-ops on a healthy positive estimated total (first-import behavior).
--   * RestoreScoreboardAnchorIfRegressed — restores the anchor when an
--     already-anchored session was downgraded by an estimated re-import;
--     no-ops for a never-anchored session, and yields to an authoritative
--     re-import.
--
-- WHAT THIS TEST DOES NOT COVER:
--   * The live T021 / deferred-reimport `scheduleAfter` closures themselves
--     (timer-driven, depend on DamageMeterService:ImportSession + CombatStore).
--     The harness cannot drive WoW timers, so this exercises the pure decision
--     functions those closures call. It asserts the fix's logic, not the wiring.

local modules = {}

local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(name, module) modules[name] = module end
function AddonShim:GetSetting() return false end
function AddonShim:Trace() end
function AddonShim:Warn() end
function AddonShim:Debug() end

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
        SUBCONTEXT = {
            SOLO_SHUFFLE = "solo_shuffle",
        },
        DAMAGE_SETTLE_DELAY = {
            arena = 3.0, battleground = 2.0, duel = 1.0,
            world_pvp = 1.0, training_dummy = 0.5, general = 0.5,
        },
        WORLD_PVP_IDLE_TIMEOUT = 8,
        DUEL_IDLE_TIMEOUT = 6,
        TRAINING_DUMMY_IDLE_TIMEOUT = 2,
        GENERAL_IDLE_TIMEOUT = 3,
        IMPORT_STATUS = {
            IMPORTED_AUTHORITATIVE    = "imported_authoritative",
            IMPORTED_CURRENT_SNAPSHOT = "imported_current_snapshot",
            ESTIMATED_FROM_CASTS      = "estimated_from_casts",
            ANCHORED_FROM_SCOREBOARD  = "anchored_from_scoreboard",
            FAILED_NO_CANDIDATE       = "failed_no_candidate",
        },
        IMPORT_AUTHORITY = {
            authoritative = { imported_authoritative = true },
            estimated = {
                imported_current_snapshot = true,
                estimated_from_casts      = true,
                anchored_from_scoreboard  = true,
            },
            failed = { failed_no_candidate = true },
        },
    },
    ApiCompat = {
        GetPlayerGUID = function() return "Player-self" end,
        IsGuidPet = function() return false end,
    },
    Helpers = {
        Now = function() return 0 end,
    },
}

-- Stub DamageMeterService: the scoreboard row is the authoritative total.
local SCOREBOARD_TOTAL = 250000
modules["DamageMeterService"] = {
    GetScoreboardPlayerDamage = function(_, session)
        if session and session.postMatchScores then
            return SCOREBOARD_TOTAL
        end
        return nil
    end,
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
    describe("CombatTracker / scoreboard anchor stickiness", function()
        it("module loads", function()
            error("CombatTracker module not loaded — check file path.")
        end)
    end)
    return
end

local C = ns.Constants

local function newArenaSession()
    return {
        id = "arena-anchor-test",
        context = C.CONTEXT.ARENA,
        totals = {},
        importedTotals = {},
        postMatchScores = {
            { guid = "Player-enemy", name = "Foe",  damageDone = 9999 },
            { guid = "Player-self",  name = "Self", damageDone = SCOREBOARD_TOTAL },
        },
    }
end

describe("CombatTracker / scoreboard anchor stickiness", function()
    it("anchors an arena session whose DM import produced zero total", function()
        local session = newArenaSession()
        local applied = Tracker:ApplyScoreboardAnchorIfNeeded(session)
        expect(applied):toBe(true)
        expect(session.totals.damageDone):toBe(SCOREBOARD_TOTAL)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.ANCHORED_FROM_SCOREBOARD)
        expect(session.importedTotals.totalAuthority):toBe("estimated")
    end)

    it("anchors over a positive total left at a failed authority tier", function()
        local session = newArenaSession()
        session.totals.damageDone = 12345  -- positive but untrusted
        session.importedTotals = {
            damageDone = 12345,
            importStatus = C.IMPORT_STATUS.FAILED_NO_CANDIDATE,
            totalAuthority = "failed",
        }
        local applied = Tracker:ApplyScoreboardAnchorIfNeeded(session)
        expect(applied):toBe(true)
        expect(session.totals.damageDone):toBe(SCOREBOARD_TOTAL)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.ANCHORED_FROM_SCOREBOARD)
    end)

    it("does NOT re-anchor a fresh, healthy estimated DM import (first-import behavior preserved)", function()
        -- A first-time successful estimated DM import carries per-spell data.
        -- ApplyScoreboardAnchorIfNeeded must leave it untouched: the scoreboard
        -- total has no per-spell breakdown, so overwriting would create a
        -- spells-sum != total inconsistency. Only zero/failed totals anchor.
        local session = newArenaSession()
        session.totals.damageDone = 180000
        session.importedTotals = {
            damageDone = 180000,
            importStatus = C.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT,
            totalAuthority = "estimated",
        }
        local applied = Tracker:ApplyScoreboardAnchorIfNeeded(session)
        expect(applied):toBe(false)
        expect(session.totals.damageDone):toBe(180000)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT)
    end)

    it("restores the anchor when a retry overwrote it with a worse estimated total", function()
        -- Reproduce the bug: a session is anchored, then a late
        -- DAMAGE_METER_COMBAT_SESSION_UPDATED retry re-imports a positive but
        -- worse estimated total (imported_current_snapshot). The caller passes
        -- wasAnchored=true (captured BEFORE the re-import).
        local session = newArenaSession()
        Tracker:ApplyScoreboardAnchorIfNeeded(session)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.ANCHORED_FROM_SCOREBOARD)

        local wasAnchored = session.importedTotals.importStatus
            == C.IMPORT_STATUS.ANCHORED_FROM_SCOREBOARD
        expect(wasAnchored):toBe(true)

        -- Simulate the retry's ImportSession + SetImportAuthority overwriting
        -- the anchored total with a stale partial DM estimate.
        session.totals.damageDone = 64000
        session.importedTotals.damageDone = 64000
        Tracker:SetImportAuthority(session, C.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT)
        expect(session.totals.damageDone):toBe(64000)  -- regression present

        -- Without the fix, ApplyScoreboardAnchorIfNeeded would early-return
        -- here (damage > 0, authority "estimated") and the regression sticks.
        local guardSkipped = Tracker:ApplyScoreboardAnchorIfNeeded(session)
        expect(guardSkipped):toBe(false)
        expect(session.totals.damageDone):toBe(64000)  -- still regressed

        -- The fix: RestoreScoreboardAnchorIfRegressed reinstates the anchor.
        local restored = Tracker:RestoreScoreboardAnchorIfRegressed(session, wasAnchored)
        expect(restored):toBe(true)
        expect(session.totals.damageDone):toBe(SCOREBOARD_TOTAL)
        expect(session.importedTotals.damageDone):toBe(SCOREBOARD_TOTAL)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.ANCHORED_FROM_SCOREBOARD)
        expect(session.importedTotals.totalAuthority):toBe("estimated")
    end)

    it("does NOT restore when the session was never anchored", function()
        -- A never-anchored session whose re-import produced an estimated total
        -- must keep that data — wasAnchored=false is a strict no-op.
        local session = newArenaSession()
        session.totals.damageDone = 90000
        Tracker:SetImportAuthority(session, C.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT)
        local restored = Tracker:RestoreScoreboardAnchorIfRegressed(session, false)
        expect(restored):toBe(false)
        expect(session.totals.damageDone):toBe(90000)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT)
    end)

    it("yields to an authoritative re-import — that outcome is strictly better", function()
        -- An authoritative DM import gives the same total PLUS per-spell data,
        -- so an anchored session should accept it and NOT be restored.
        local session = newArenaSession()
        Tracker:ApplyScoreboardAnchorIfNeeded(session)
        local wasAnchored = true

        session.totals.damageDone = SCOREBOARD_TOTAL  -- authoritative total
        Tracker:SetImportAuthority(session, C.IMPORT_STATUS.IMPORTED_AUTHORITATIVE)

        local restored = Tracker:RestoreScoreboardAnchorIfRegressed(session, wasAnchored)
        expect(restored):toBe(false)
        expect(session.importedTotals.importStatus):toBe(C.IMPORT_STATUS.IMPORTED_AUTHORITATIVE)
        expect(session.importedTotals.totalAuthority):toBe("authoritative")
    end)
end)
