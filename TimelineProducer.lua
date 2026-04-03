local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local TimelineProducer = {}

-- ---------------------------------------------------------------------------
-- Core: event append + session accessor
-- ---------------------------------------------------------------------------

--- Append a timeline event to the active session's timelineEvents list.
--- Required fields: t, lane, type, source.
--- Auto-defaulted fields: confidence → "confirmed", guid → nil, ownerGUID → nil.
function TimelineProducer:AppendTimelineEvent(session, event)
    if not session or not session.timelineEvents then return end
    if not event then return end

    -- T014: Validate required fields; log and drop on violation.
    if not event.t or not event.lane or not event.type or not event.source then
        ns.Addon:Trace("timeline.schema_violation", {
            missing_t          = not event.t      and true or nil,
            missing_lane       = not event.lane   and true or nil,
            missing_type       = not event.type   and true or nil,
            missing_source     = not event.source and true or nil,
        })
        return
    end

    -- Apply canonical defaults for optional tracking fields.
    if event.confidence == nil then event.confidence = "confirmed" end
    -- T010: Default chronology to "realtime" for all observed events.
    -- Callers must explicitly set chronology = "summary" for DM-derived rows.
    if event.chronology == nil then event.chronology = "realtime" end
    if event.guid       == nil then event.guid       = nil end  -- explicit nil for schema clarity
    if event.ownerGUID  == nil then event.ownerGUID  = nil end

    session.timelineEvents[#session.timelineEvents + 1] = event
end

--- Retrieve the current active session from CombatTracker.
function TimelineProducer:GetCurrentSession()
    local tracker = ns.Addon:GetModule("CombatTracker")
    return tracker and tracker:GetCurrentSession() or nil
end

-- ---------------------------------------------------------------------------
-- T016: PlayerCastProducer — forwarding shim
-- Actual logic lives in VisibleCastProducer (extracted by T016).
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp then vcp:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID) end
end

-- ---------------------------------------------------------------------------
-- T015: VisibleAuraProducer — forwarding shim
-- Actual logic lives in AuraReconciliationService (extracted by T015).
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleUnitAura(unitTarget, updateInfo)
    local ars = ns.Addon:GetModule("AuraReconciliationService")
    if ars then ars:HandleUnitAura(unitTarget, updateInfo) end
end

-- ---------------------------------------------------------------------------
-- T022: CCReceivedProducer
-- Handles LOSS_OF_CONTROL_ADDED, PLAYER_CONTROL_LOST, PLAYER_CONTROL_GAINED.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleLossOfControlAdded()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    -- Attempt to read the latest LOC data for context.
    local locCount = ApiCompat.GetActiveLossOfControlDataCount("player")
    local locData = nil
    if locCount and locCount > 0 then
        locData = ApiCompat.GetActiveLossOfControlData("player", locCount)
    end

    local meta = {}
    if locData then
        meta.locType = ApiCompat.SanitizeString(locData.locType)
        meta.spellID = ApiCompat.SanitizeNumber(locData.spellID)
        meta.displayText = ApiCompat.SanitizeString(locData.displayText)
        meta.duration = ApiCompat.SanitizeNumber(locData.duration)
        meta.startTime = ApiCompat.SanitizeNumber(locData.startTime)
        meta.timeRemaining = ApiCompat.SanitizeNumber(locData.timeRemaining)
    end

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.CC_RECEIVED,
        type = "start",
        source = Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL,
        confidence = "confirmed",
        meta = meta,
    })
end

function TimelineProducer:HandlePlayerControlLost()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.CC_RECEIVED,
        type = "start",
        source = Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL,
        confidence = "confirmed",
    })
end

function TimelineProducer:HandlePlayerControlGained()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.CC_RECEIVED,
        type = "end",
        source = Constants.PROVENANCE_SOURCE.LOSS_OF_CONTROL,
        confidence = "confirmed",
    })
end

-- ---------------------------------------------------------------------------
-- T023: DRUpdateProducer
-- Handles UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED for arena units.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleDiminishStateUpdated(unitTarget, trackerInfo)
    if not unitTarget or type(unitTarget) ~= "string" then return end
    -- Only track arena units (arena1, arena2, ...).
    if not Helpers.StartsWith(unitTarget, "arena") then return end

    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    local meta = {}
    if trackerInfo then
        local okInfo, parsed = pcall(function()
            return {
                category = ApiCompat.SanitizeString(trackerInfo.category),
                startTime = ApiCompat.SanitizeNumber(trackerInfo.startTime),
                duration = ApiCompat.SanitizeNumber(trackerInfo.duration),
                isImmune = ApiCompat.SanitizeBool(trackerInfo.isImmune),
                showCountdown = ApiCompat.SanitizeBool(trackerInfo.showCountdown),
            }
        end)
        if okInfo and parsed then
            meta = parsed
        end
    end

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.DR_UPDATE,
        type = "dr_state_change",
        source = Constants.PROVENANCE_SOURCE.SPELL_DIMINISH,
        confidence = "confirmed",
        unitToken = unitTarget,
        meta = meta,
    })
end

-- ---------------------------------------------------------------------------
-- T024: MatchStateProducer
-- Handles PVP_MATCH_ACTIVE, PVP_MATCH_COMPLETE, DUEL_INBOUNDS,
-- DUEL_FINISHED, PLAYER_REGEN_DISABLED, PLAYER_REGEN_ENABLED.
-- ---------------------------------------------------------------------------

local MATCH_STATE_TYPE_MAP = {
    PLAYER_REGEN_DISABLED  = "combat_start",
    PLAYER_REGEN_ENABLED   = "combat_end",
    PVP_MATCH_ACTIVE       = "match_active",
    PVP_MATCH_COMPLETE     = "match_complete",
    DUEL_INBOUNDS          = "duel_start",
    DUEL_FINISHED          = "duel_end",
}

function TimelineProducer:HandleMatchStateEvent(eventName)
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    local eventType = MATCH_STATE_TYPE_MAP[eventName]
    if not eventType then return end

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.MATCH_STATE,
        type = eventType,
        source = Constants.PROVENANCE_SOURCE.STATE,
        confidence = "confirmed",
        meta = { eventName = eventName },
    })
end

-- ---------------------------------------------------------------------------
-- T025: InspectProducer
-- Handles INSPECT_READY as a timeline marker.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleInspectReady()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.INSPECT,
        type = "inspect_ready",
        source = Constants.PROVENANCE_SOURCE.INSPECT,
        confidence = "confirmed",
    })
end

-- ---------------------------------------------------------------------------
-- T026: DamageMeterCheckpointProducer
-- Handles DAMAGE_METER_COMBAT_SESSION_UPDATED and
-- DAMAGE_METER_CURRENT_SESSION_UPDATED.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleDamageMeterCombatSessionUpdated()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.DM_CHECKPOINT,
        type = "dm_checkpoint",
        source = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
        confidence = "confirmed",
        meta = { updateType = "combat_session" },
    })
end

function TimelineProducer:HandleDamageMeterCurrentSessionUpdated()
    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.DM_CHECKPOINT,
        type = "dm_checkpoint",
        source = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
        confidence = "confirmed",
        meta = { updateType = "current_session" },
    })
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("TimelineProducer", TimelineProducer)
