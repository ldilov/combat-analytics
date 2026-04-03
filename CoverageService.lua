local _, ns = ...

local Constants = ns.Constants

local CoverageService = {}

-- ---------------------------------------------------------------------------
-- Lane definitions
-- ---------------------------------------------------------------------------
-- Each entry maps a logical coverage lane name to:
--   tlLane    — the TIMELINE_LANE constant value to count events in
--   minEvents — minimum event count to score 1.0 (nil = any > 0 is full)
--   label     — human-readable lane name for debug output
-- ---------------------------------------------------------------------------

local LANE_DEFS = {
    -- T013: Recognize VISIBLE_CAST (v7+) as the primary cast lane.
    -- PLAYER_CAST is the legacy alias; count both so sessions recorded before
    -- the lane rename still score correctly.
    visibleCasts = {
        tlLane    = Constants.TIMELINE_LANE.VISIBLE_CAST,
        tlLaneFallback = Constants.TIMELINE_LANE.PLAYER_CAST,
        label     = "Visible casts",
    },
    -- T013: Coverage lane for actor visibility/identity transition events (v7+).
    visibilityTransitions = {
        tlLane    = Constants.TIMELINE_LANE.VISIBILITY,
        label     = "Visibility transitions",
    },
    auras = {
        tlLane    = Constants.TIMELINE_LANE.VISIBLE_AURA,
        label     = "Aura state",
    },
    ccReceived = {
        tlLane    = Constants.TIMELINE_LANE.CC_RECEIVED,
        label     = "CC received",
    },
    drState = {
        tlLane    = Constants.TIMELINE_LANE.DR_UPDATE,
        label     = "DR state",
    },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function makeRecord(score, eventCount, droppedCount, summary)
    return {
        score        = score,
        eventCount   = eventCount,
        droppedCount = droppedCount,
        summary      = summary,
    }
end

-- Count timeline events matching a specific lane.
local function countLaneEvents(timelineEvents, laneValue)
    local total    = 0
    local dropped  = 0
    for _, ev in ipairs(timelineEvents) do
        if ev.lane == laneValue then
            total = total + 1
            if ev.confidence == "dropped" then
                dropped = dropped + 1
            end
        end
    end
    return total, dropped
end

-- Binary score: 1.0 if any events present, 0.0 if none.
local function binaryScore(count)
    return count > 0 and 1.0 or 0.0
end

-- ---------------------------------------------------------------------------
-- Per-lane coverage computations
-- ---------------------------------------------------------------------------

-- damage: based on whether damageDone is populated and from which source.
local function computeDamageCoverage(session)
    local imported = session.importedTotals and (session.importedTotals.damageDone or 0) or 0
    local local_   = session.localTotals   and (session.localTotals.damageDone   or 0) or 0
    local final    = session.totals        and (session.totals.damageDone        or 0) or 0

    local dmEvents = 0
    for _, ev in ipairs(session.timelineEvents or {}) do
        if ev.lane == Constants.TIMELINE_LANE.DM_CHECKPOINT
        or ev.lane == Constants.TIMELINE_LANE.DM_SPELL then
            dmEvents = dmEvents + 1
        end
    end

    if final > 0 and (imported > 0 or local_ > 0) then
        return makeRecord(1.0, dmEvents, 0,
            string.format("%.0f dmg captured (imported=%d, local=%d)", final, imported, local_))
    elseif dmEvents > 0 then
        return makeRecord(0.5, dmEvents, 0,
            string.format("DM events present but totals missing (%d events)", dmEvents))
    else
        return makeRecord(0.0, 0, 0, "No damage data captured")
    end
end

-- identity: fraction of arena slots (1–5) that have a known GUID in the
-- session's identity record or arena roster.
local function computeIdentityCoverage(session)
    local known  = 0
    local total  = 5  -- assume up to 5 arena opponents

    -- Check arena roster from ArenaRoundTracker state stored on session.
    local roster = session.arena and session.arena.roster or {}
    local seenSlots = {}
    for _, entry in ipairs(roster) do
        if entry.guid and entry.guid ~= "" then
            local slot = entry.slot or entry.slotIndex
            if slot and not seenSlots[slot] then
                seenSlots[slot] = true
                known = known + 1
            end
        end
    end

    -- Fallback: count unique opponent GUIDs from primaryOpponent + actors.
    if known == 0 then
        if session.primaryOpponent and session.primaryOpponent.guid then
            known = 1
        end
    end

    if total == 0 then
        return makeRecord(0.0, 0, 0, "No arena context")
    end

    local score = math.min(1.0, known / total)
    return makeRecord(score, known, 0,
        string.format("%d/%d arena identities resolved", known, total))
end

-- postMatchMeta: whether C_PvP score data was harvested after the match.
local function computePostMatchMetaCoverage(session)
    local scores = session.postMatchScores or session._postMatchScores
    if scores and next(scores) then
        local count = 0
        for _ in pairs(scores) do count = count + 1 end
        return makeRecord(1.0, count, 0,
            string.format("Post-match scores: %d entries", count))
    end
    return makeRecord(0.0, 0, 0, "No post-match score data")
end

-- replayFidelity: ratio of confirmed events to all timeline events.
-- Partial or inferred events reduce fidelity.
local function computeReplayFidelityCoverage(session)
    local total      = 0
    local confirmed  = 0
    for _, ev in ipairs(session.timelineEvents or {}) do
        total = total + 1
        if ev.confidence == "confirmed" then
            confirmed = confirmed + 1
        end
    end
    if total == 0 then
        return makeRecord(0.0, 0, 0, "No timeline events")
    end
    local score = confirmed / total
    return makeRecord(score, total, total - confirmed,
        string.format("%d/%d events confirmed (%.0f%%)", confirmed, total, score * 100))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Compute per-lane coverage for the given session and write session.coverage.
--- Called at the end of FinalizeSession.
function CoverageService:Finalize(session)
    if not session then return end

    local events = session.timelineEvents or {}
    local coverage = {}

    -- Event-count-based lanes
    for laneName, def in pairs(LANE_DEFS) do
        local count, dropped = countLaneEvents(events, def.tlLane)
        -- T013: For lanes with a fallback (e.g. visibleCasts uses VISIBLE_CAST
        -- but falls back to legacy PLAYER_CAST for old sessions), add both counts.
        if def.tlLaneFallback and count == 0 then
            local fbCount, fbDropped = countLaneEvents(events, def.tlLaneFallback)
            count   = count   + fbCount
            dropped = dropped + fbDropped
        end
        local score = binaryScore(count)
        local summary
        if count == 0 then
            summary = def.label .. ": no events captured"
        else
            summary = string.format("%s: %d events", def.label, count)
            if dropped > 0 then
                summary = summary .. string.format(", %d dropped", dropped)
            end
        end
        coverage[laneName] = makeRecord(score, count, dropped, summary)
    end

    -- Special-cased lanes
    coverage.damage        = computeDamageCoverage(session)
    coverage.identity      = computeIdentityCoverage(session)
    coverage.postMatchMeta = computePostMatchMetaCoverage(session)
    coverage.replayFidelity = computeReplayFidelityCoverage(session)

    session.coverage = coverage
end

--- Return the coverage score for a named lane, or nil if not computed yet.
function CoverageService:GetLaneScore(session, laneName)
    if not session or not session.coverage then return nil end
    local record = session.coverage[laneName]
    return record and record.score or nil
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("CoverageService", CoverageService)
