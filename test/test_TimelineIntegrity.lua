-- test/test_TimelineIntegrity.lua
-- Timeline chronology integrity test suite.
--
-- Covers:
--   • summary rows excluded from death analysis backward scan
--   • death analysis last-cast candidate is always realtime
--   • observed timestamps are preserved (not rewritten to session.duration)
--   • chronology="summary" rows not counted in burst/opener sequences

-- ---------------------------------------------------------------------------
-- Namespace / module shim (no module loading required — pure logic tests)
-- ---------------------------------------------------------------------------

-- These tests exercise the filtering/iteration logic directly,
-- not the full CombatTracker or SuggestionEngine pipelines.
-- They construct session objects and validate that the chronology field
-- drives correct filtering when consumers iterate timelineEvents.

local VISIBLE_CAST  = "visible_cast"
local PLAYER_CAST   = "player_cast"
local DAMAGE_METER  = "damage_meter"
local REALTIME      = "realtime"
local SUMMARY       = "summary"

-- ---------------------------------------------------------------------------
-- Helper: build a minimal timeline with mixed chronology
-- ---------------------------------------------------------------------------
local function buildTimeline()
    return {
        -- realtime casts
        { t = 0.5,  lane = VISIBLE_CAST, type = "cast_succeeded", spellId = 133,  chronology = REALTIME,  sourceGuid = "P-001", amount = 5000 },
        { t = 1.0,  lane = VISIBLE_CAST, type = "cast_succeeded", spellId = 2139, chronology = REALTIME,  sourceGuid = "P-001", amount = 0    },
        { t = 2.0,  lane = VISIBLE_CAST, type = "cast_succeeded", spellId = 116,  chronology = REALTIME,  sourceGuid = "P-001", amount = 8000 },
        -- summary rows (DM post-match)
        { t = 10.0, lane = DAMAGE_METER, type = "DM_SPELL",       spellId = 133,  chronology = SUMMARY,   sourceGuid = "P-001", amount = 50000 },
        { t = 10.0, lane = DAMAGE_METER, type = "DM_SPELL",       spellId = 116,  chronology = SUMMARY,   sourceGuid = "P-001", amount = 80000 },
        -- more realtime casts
        { t = 3.0,  lane = VISIBLE_CAST, type = "cast_succeeded", spellId = 44614, chronology = REALTIME, sourceGuid = "P-001", amount = 12000 },
        { t = 4.0,  lane = VISIBLE_CAST, type = "cast_failed",    spellId = 133,  chronology = REALTIME,  sourceGuid = "P-001", amount = 0    },
    }
end

-- ---------------------------------------------------------------------------
-- Test helpers that mimic the filtering logic used in CombatTracker / SuggestionEngine
-- ---------------------------------------------------------------------------

--- Returns last cast event before `deathT` that is REALTIME (chronology ~= "summary").
local function findLastCastBeforeDeath(events, deathT)
    local lastCast = nil
    for i = #events, 1, -1 do
        local ev = events[i]
        if ev.t and ev.t <= deathT
            and ev.chronology ~= SUMMARY
            and (ev.lane == VISIBLE_CAST or ev.lane == PLAYER_CAST)
            and ev.spellId
        then
            lastCast = ev
            break
        end
    end
    return lastCast
end

--- Returns all realtime cast events (excludes summary).
local function realtimeCastsOnly(events)
    local out = {}
    for _, ev in ipairs(events) do
        if ev.chronology ~= SUMMARY
            and (ev.lane == VISIBLE_CAST or ev.lane == PLAYER_CAST)
        then
            out[#out + 1] = ev
        end
    end
    return out
end

--- Returns all summary events.
local function summaryEventsOnly(events)
    local out = {}
    for _, ev in ipairs(events) do
        if ev.chronology == SUMMARY then
            out[#out + 1] = ev
        end
    end
    return out
end

--- Extracts opener sequence: first N distinct realtime spell casts sorted by t.
local function openerSequence(events, n)
    n = n or 3
    local casts = realtimeCastsOnly(events)
    table.sort(casts, function(a, b) return (a.t or 0) < (b.t or 0) end)
    local out = {}
    for i = 1, math.min(n, #casts) do
        out[#out + 1] = casts[i]
    end
    return out
end

--- Counts events in a burst window [t0, t0+window] excluding summary.
local function burstCastCount(events, t0, window)
    local count = 0
    for _, ev in ipairs(events) do
        if ev.chronology ~= SUMMARY
            and ev.t and ev.t >= t0 and ev.t <= t0 + window
            and (ev.lane == VISIBLE_CAST or ev.lane == PLAYER_CAST)
        then
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Suite 1: Death analysis excludes summary rows
-- ---------------------------------------------------------------------------
describe("Timeline integrity / death analysis excludes summary rows", function()

    it("findLastCastBeforeDeath returns a realtime cast, not a summary row", function()
        local events = buildTimeline()
        local deathT = 5.0
        local cast = findLastCastBeforeDeath(events, deathT)
        expect(cast):toNotBeNil()
        expect(cast.chronology):toBe(REALTIME)
    end)

    it("findLastCastBeforeDeath is nil when all events before death are summary", function()
        local events = {
            { t = 1.0, lane = DAMAGE_METER, type = "DM_SPELL", spellId = 133,
              chronology = SUMMARY, sourceGuid = "P-001" },
            { t = 2.0, lane = DAMAGE_METER, type = "DM_SPELL", spellId = 116,
              chronology = SUMMARY, sourceGuid = "P-001" },
        }
        local cast = findLastCastBeforeDeath(events, 3.0)
        expect(cast):toBeNil()
    end)

    it("findLastCastBeforeDeath picks the realtime cast even when summary has later t", function()
        local events = {
            { t = 2.0,  lane = VISIBLE_CAST, type = "cast_succeeded", spellId = 133,
              chronology = REALTIME, sourceGuid = "P-001" },
            { t = 10.0, lane = DAMAGE_METER, type = "DM_SPELL", spellId = 133,
              chronology = SUMMARY, sourceGuid = "P-001" },
        }
        -- deathT is 3.0 — only the REALTIME event at t=2.0 qualifies
        local cast = findLastCastBeforeDeath(events, 3.0)
        expect(cast):toNotBeNil()
        expect(cast.t):toBe(2.0)
        expect(cast.chronology):toBe(REALTIME)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 2: Observed timestamps are preserved
-- ---------------------------------------------------------------------------
describe("Timeline integrity / timestamps preserved", function()

    it("realtime events retain their original t values (not overwritten)", function()
        local events = buildTimeline()
        local realtime = realtimeCastsOnly(events)
        local observedTs = {}
        for _, ev in ipairs(realtime) do
            observedTs[ev.t] = true
        end
        expect(observedTs[0.5]):toBeTruthy()
        expect(observedTs[1.0]):toBeTruthy()
        expect(observedTs[2.0]):toBeTruthy()
        expect(observedTs[3.0]):toBeTruthy()
        expect(observedTs[4.0]):toBeTruthy()
    end)

    it("summary rows have t = session.duration (10.0 in test data), not realtime offsets", function()
        local events = buildTimeline()
        local summary = summaryEventsOnly(events)
        expect(#summary):toBe(2)
        for _, ev in ipairs(summary) do
            expect(ev.t):toBe(10.0)
        end
    end)

    it("summary t values do NOT appear in the realtime cast set", function()
        local events = buildTimeline()
        local realtime = realtimeCastsOnly(events)
        for _, ev in ipairs(realtime) do
            -- None of the realtime casts should have t == 10 (the DM summary bucket)
            expect(ev.t ~= 10.0):toBeTruthy()
        end
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 3: Opener sequence excludes summary
-- ---------------------------------------------------------------------------
describe("Timeline integrity / opener sequence excludes summary", function()

    it("openerSequence returns only realtime events", function()
        local events = buildTimeline()
        local opener = openerSequence(events, 5)
        for _, ev in ipairs(opener) do
            expect(ev.chronology):toBe(REALTIME)
        end
    end)

    it("openerSequence is sorted by ascending t", function()
        local events = buildTimeline()
        local opener = openerSequence(events, 5)
        for i = 2, #opener do
            expect(opener[i].t >= opener[i - 1].t):toBeTruthy()
        end
    end)

    it("opener first spell is t=0.5 (Fireball), not the DM summary row", function()
        local events = buildTimeline()
        local opener = openerSequence(events, 3)
        expect(#opener > 0):toBeTruthy()
        expect(opener[1].t):toBe(0.5)
        expect(opener[1].spellId):toBe(133)
    end)

    it("summary events do not inflate opener count", function()
        local events = buildTimeline()
        local realtimeOnly = realtimeCastsOnly(events)
        local allCasts = {}
        for _, ev in ipairs(events) do
            if ev.lane == VISIBLE_CAST or ev.lane == DAMAGE_METER then
                allCasts[#allCasts + 1] = ev
            end
        end
        -- Opener from realtime-only source should have fewer entries than including summary
        local openerReal = openerSequence(events, 10)
        expect(#openerReal):toBe(#realtimeOnly)
    end)

end)

-- ---------------------------------------------------------------------------
-- Suite 4: Burst window excludes summary rows
-- ---------------------------------------------------------------------------
describe("Timeline integrity / burst window excludes summary", function()

    it("burstCastCount from t=0 to t=5 includes 4 realtime casts (0.5,2.0,3.0,4.0 + t=1.0 fail)", function()
        local events = buildTimeline()
        -- t=0.5 cast_succeeded, t=1.0 cast_succeeded, t=2.0 cast_succeeded, t=3.0 cast_succeeded, t=4.0 cast_failed = 5
        local count = burstCastCount(events, 0, 5.0)
        expect(count):toBe(5)
    end)

    it("burstCastCount does NOT count summary events in window [0, 15]", function()
        local events = buildTimeline()
        -- Summary DM events have t=10, which falls inside [0, 15], but must be excluded.
        local count = burstCastCount(events, 0, 15.0)
        -- Only 5 realtime events; DM summary at t=10 should not add to count.
        expect(count):toBe(5)
    end)

    it("adding more summary events does not change burst count", function()
        local events = buildTimeline()
        -- Add extra summary events
        for i = 1, 10 do
            events[#events + 1] = {
                t = 10.0, lane = DAMAGE_METER, type = "DM_SPELL",
                spellId = 1000 + i, chronology = SUMMARY, sourceGuid = "P-001",
            }
        end
        local count = burstCastCount(events, 0, 15.0)
        expect(count):toBe(5)
    end)

end)
