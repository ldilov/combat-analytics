-- test/test_SchemaNormalization.lua
-- TimelineProducer schema normalization test suite.
--
-- Covers:
--   • Top-level fields present on VISIBLE_CAST events
--     (sourceGuid, sourceName, sourceClassFile, sourceSlot, confidence, chronology)
--   • DM_ENEMY_SPELL has sourceGuid/sourceName at top-level AND in meta
--   • Uniform sourceGuid/sourceName read path across event types
--   • chronology field defaults to "realtime" when not set by caller

-- ---------------------------------------------------------------------------
-- Minimal ns / addon shim
-- ---------------------------------------------------------------------------

local capturedEvents = {}

local modules = {}
local AddonShim = {}
AddonShim.__index = AddonShim
function AddonShim:GetModule(name) return modules[name] end
function AddonShim:RegisterModule(n, m) modules[n] = m end

local Constants = {
    TIMELINE_LANE = {
        VISIBLE_CAST  = "visible_cast",
        PLAYER_CAST   = "player_cast",
        VISIBILITY    = "visibility",
        DAMAGE_METER  = "damage_meter",
        AURA          = "aura",
        DEATH         = "death",
    },
    ATTRIBUTION_CONFIDENCE = {
        confirmed       = "confirmed",
        owner_confirmed = "owner_confirmed",
        slot_confirmed  = "slot_confirmed",
        inferred        = "inferred",
        summary_derived = "summary_derived",
        unknown         = "unknown",
    },
    PROVENANCE_SOURCE = {
        VISIBLE_UNIT_CAST  = "visible_unit_cast",
        ARENA_SLOT_MAPPING = "arena_slot_mapping",
        DAMAGE_METER       = "damage_meter",
    },
    TIMELINE_SCHEMA_VERSION = 7,
    TRACKED_UNITS = { player=true, pet=true, arena1=true, arena2=true, arena3=true },
}

local ApiCompat = {
    GetUnitGUID  = function(_) return nil end,
    GetSpellInfo = function(id) return "Spell"..id, nil, 0, 0, 0, 0 end,
}
local Helpers = { FormatNumber = tostring, FormatDuration = tostring }

local ns = {
    Constants = Constants,
    ApiCompat = ApiCompat,
    Helpers   = Helpers,
    StaticPvpData = nil,
}
ns.Addon = setmetatable({}, AddonShim)

-- Load TimelineProducer
local tpChunk
do
    local paths = { "TimelineProducer.lua", "../TimelineProducer.lua" }
    for _, p in ipairs(paths) do
        local f = io.open and io.open(p, "r")
        if f then
            local src = f:read("*a")
            f:close()
            tpChunk = load(src, "@TimelineProducer.lua")
            break
        end
    end
end

if tpChunk then
    tpChunk("CombatAnalytics", ns)
end

local TP = modules["TimelineProducer"]

if not TP then
    describe("TimelineProducer schema normalization", function()
        it("module loads", function()
            error("TimelineProducer module not loaded — check file path.")
        end)
    end)
    return
end

-- ---------------------------------------------------------------------------
-- Session factory
-- ---------------------------------------------------------------------------
local function makeSession(overrides)
    local s = {
        id            = "test-session",
        startedAt     = 0,
        context       = "arena",
        timelineEvents = {},
    }
    if overrides then
        for k, v in pairs(overrides) do s[k] = v end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Helper: invoke AppendTimelineEvent and return the stored event
-- ---------------------------------------------------------------------------
local function appendAndGet(session, event)
    TP:AppendTimelineEvent(session, event)
    return session.timelineEvents[#session.timelineEvents]
end

-- ---------------------------------------------------------------------------
-- Suite 1: VISIBLE_CAST top-level field presence
-- ---------------------------------------------------------------------------
describe("TimelineProducer / VISIBLE_CAST top-level fields", function()

    it("AppendTimelineEvent stores the event in session.timelineEvents", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "visible_cast",
            type       = "cast_succeeded",
            t          = 1.5,
            spellId    = 133,
            sourceGuid = "Player-100",
            sourceName = "Mage",
            chronology = "realtime",
            confidence = "confirmed",
        })
        expect(ev):toNotBeNil()
        expect(ev.spellId):toBe(133)
    end)

    it("sourceGuid is preserved on VISIBLE_CAST event", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "visible_cast",
            type       = "cast_succeeded",
            t          = 2.0,
            spellId    = 2139,
            sourceGuid = "Player-200",
            sourceName = "Enemy",
            chronology = "realtime",
            confidence = "slot_confirmed",
        })
        expect(ev.sourceGuid):toBe("Player-200")
    end)

    it("sourceName is preserved on VISIBLE_CAST event", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "visible_cast",
            type       = "cast_start",
            t          = 3.0,
            spellId    = 774,
            sourceGuid = "Player-201",
            sourceName = "EnemyDruid",
            chronology = "realtime",
        })
        expect(ev.sourceName):toBe("EnemyDruid")
    end)

    it("sourceClassFile is preserved on VISIBLE_CAST event", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane            = "visible_cast",
            type            = "cast_succeeded",
            t               = 4.0,
            spellId         = 48181,
            sourceGuid      = "Player-202",
            sourceClassFile = "DEATHKNIGHT",
            chronology      = "realtime",
        })
        expect(ev.sourceClassFile):toBe("DEATHKNIGHT")
    end)

    it("sourceSlot is preserved on VISIBLE_CAST event", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "visible_cast",
            type       = "cast_start",
            t          = 5.0,
            spellId    = 20271,
            sourceGuid = "Player-203",
            sourceSlot = 2,
            chronology = "realtime",
        })
        expect(ev.sourceSlot):toBe(2)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 2: chronology defaults
-- ---------------------------------------------------------------------------
describe("TimelineProducer / chronology defaults", function()

    it("chronology defaults to 'realtime' when not provided", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane    = "visible_cast",
            type    = "cast_succeeded",
            t       = 1.0,
            spellId = 133,
        })
        -- After normalization, chronology should be "realtime".
        expect(ev.chronology):toBe("realtime")
    end)

    it("explicit chronology = 'summary' is preserved", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "damage_meter",
            type       = "DM_SPELL",
            t          = session.duration or 10.0,
            spellId    = 133,
            chronology = "summary",
        })
        expect(ev.chronology):toBe("summary")
    end)

    it("explicit chronology = 'realtime' is preserved", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "visible_cast",
            type       = "cast_succeeded",
            t          = 2.0,
            spellId    = 774,
            chronology = "realtime",
        })
        expect(ev.chronology):toBe("realtime")
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 3: DM_ENEMY_SPELL — top-level and meta field presence
-- ---------------------------------------------------------------------------
describe("TimelineProducer / DM_ENEMY_SPELL field promotion", function()

    it("DM_ENEMY_SPELL event with sourceGuid in meta exposes sourceGuid at top level", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "damage_meter",
            type       = "DM_ENEMY_SPELL",
            t          = 10.0,
            spellId    = 686,
            chronology = "summary",
            sourceGuid = "Player-300",   -- already at top level after T012 migration
            sourceName = "EnemyWarlock",
            meta       = {
                sourceGuid = "Player-300",
                sourceName = "EnemyWarlock",
            },
        })
        -- Top-level read path:
        expect(ev.sourceGuid):toBe("Player-300")
    end)

    it("DM_ENEMY_SPELL meta copy is preserved for backward compat", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "damage_meter",
            type       = "DM_ENEMY_SPELL",
            t          = 11.0,
            spellId    = 686,
            chronology = "summary",
            sourceGuid = "Player-301",
            sourceName = "EnemyWarlock2",
            meta       = {
                sourceGuid = "Player-301",
                sourceName = "EnemyWarlock2",
            },
        })
        -- Legacy read path via meta:
        expect(ev.meta and ev.meta.sourceGuid):toBe("Player-301")
    end)

    it("DM_ENEMY_SPELL has chronology = summary", function()
        local session = makeSession()
        local ev = appendAndGet(session, {
            lane       = "damage_meter",
            type       = "DM_ENEMY_SPELL",
            t          = 12.0,
            spellId    = 686,
            chronology = "summary",
            sourceGuid = "Player-302",
        })
        expect(ev.chronology):toBe("summary")
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 4: Uniform sourceGuid read path across event types
-- ---------------------------------------------------------------------------
describe("TimelineProducer / uniform sourceGuid read path", function()

    local eventTypes = {
        { lane = "visible_cast",  type = "cast_succeeded",  spellId = 133,    chronology = "realtime", sourceGuid = "P-400" },
        { lane = "aura",          type = "aura_applied",    spellId = 33786,   chronology = "realtime", sourceGuid = "P-401" },
        { lane = "damage_meter",  type = "DM_SPELL",        spellId = 133,     chronology = "summary",  sourceGuid = "P-402" },
        { lane = "damage_meter",  type = "DM_ENEMY_SPELL",  spellId = 686,     chronology = "summary",  sourceGuid = "P-403" },
        { lane = "death",         type = "death",           spellId = nil,     chronology = "realtime", sourceGuid = "P-404" },
    }

    for i, spec in ipairs(eventTypes) do
        it(string.format("event[%d] lane=%s type=%s has sourceGuid at top level", i, spec.lane, spec.type), function()
            local session = makeSession()
            local evData = {
                lane       = spec.lane,
                type       = spec.type,
                t          = i * 1.0,
                spellId    = spec.spellId,
                chronology = spec.chronology,
                sourceGuid = spec.sourceGuid,
            }
            if spec.type == "DM_ENEMY_SPELL" then
                evData.meta = { sourceGuid = spec.sourceGuid }
            end
            local ev = appendAndGet(session, evData)
            expect(ev.sourceGuid):toBe(spec.sourceGuid)
        end)
    end

end)
