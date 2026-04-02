local ADDON_NAME, ns = ...

local Events = CreateFrame("Frame")

local ONUPDATE_INTERVAL = 0.1
local _elapsed = 0

-- Modular event router: handlers registered per event name.
local _handlers = {}

-- T013: UNIT_AURA coalescing — multiple UNIT_AURA events can fire for the same
-- unit within a single frame (e.g. several auras applied at cast-time). Buffer
-- per-unit updateInfo and flush once per OnUpdate tick so downstream handlers
-- (CombatTracker, TimelineProducer) each process one merged call per unit.
local _pendingAura = {}  -- [unitTarget] = { addedAuras={}, removedAuraInstanceIDs={} }

local function _accumulateUnitAura(unitTarget, updateInfo)
    if not unitTarget then return end
    local pending = _pendingAura[unitTarget]
    if not pending then
        pending = { addedAuras = {}, removedAuraInstanceIDs = {} }
        _pendingAura[unitTarget] = pending
    end
    if updateInfo then
        if updateInfo.addedAuras then
            for _, v in ipairs(updateInfo.addedAuras) do
                pending.addedAuras[#pending.addedAuras + 1] = v
            end
        end
        if updateInfo.removedAuraInstanceIDs then
            for _, v in ipairs(updateInfo.removedAuraInstanceIDs) do
                pending.removedAuraInstanceIDs[#pending.removedAuraInstanceIDs + 1] = v
            end
        end
    end
end

local function _flushPendingAura()
    if not next(_pendingAura) then return end
    local tracker = ns.Addon:GetModule("CombatTracker")
    local tp      = ns.Addon:GetModule("TimelineProducer")
    for unit, merged in pairs(_pendingAura) do
        if tracker and tracker.HandleUnitAura then
            local ok, err = xpcall(function()
                tracker:HandleUnitAura(unit, merged)
            end, debugstack)
            if not ok then reportError("UNIT_AURA flush (CombatTracker)", err) end
        end
        if tp and tp.HandleUnitAura then
            local ok, err = xpcall(function()
                tp:HandleUnitAura(unit, merged)
            end, debugstack)
            if not ok then reportError("UNIT_AURA flush (TimelineProducer)", err) end
        end
    end
    wipe(_pendingAura)
end

local function reportError(prefix, message)
    if ns and ns.Addon and ns.Addon.Warn then
        ns.Addon:Warn(string.format("%s: %s", prefix, tostring(message)))
    end
end

function Events.RegisterHandler(eventName, handler)
    if not _handlers[eventName] then
        _handlers[eventName] = {}
    end
    _handlers[eventName][#_handlers[eventName] + 1] = handler
end

-- Build default handler table from CombatTracker method names.
-- This replaces the old elseif dispatch chain.
local TRACKER_EVENT_MAP = {
    PLAYER_ENTERING_WORLD               = "HandlePlayerEnteringWorld",
    TRAIT_CONFIG_LIST_UPDATED            = "HandleTraitConfigListUpdated",
    TRAIT_CONFIG_UPDATED                 = "HandleTraitConfigUpdated",
    -- COMBAT_LOG_EVENT_UNFILTERED is not routed here: registering that event
    -- via Frame:RegisterEvent() is forbidden in Midnight arena and raises a
    -- Lua error. Damage data flows from C_DamageMeter instead.
    PLAYER_REGEN_DISABLED                = "HandlePlayerRegenDisabled",
    PLAYER_REGEN_ENABLED                 = "HandlePlayerRegenEnabled",
    DAMAGE_METER_COMBAT_SESSION_UPDATED  = "HandleDamageMeterCombatSessionUpdated",
    DAMAGE_METER_CURRENT_SESSION_UPDATED = "HandleDamageMeterCurrentSessionUpdated",
    DAMAGE_METER_RESET                   = "HandleDamageMeterReset",
    UNIT_SPELLCAST_SUCCEEDED             = "HandleUnitSpellcastSucceeded",
    SPELL_DATA_LOAD_RESULT               = "HandleSpellDataLoadResult",
    -- UNIT_AURA is NOT dispatched via TRACKER_EVENT_MAP; it is coalesced per
    -- unit per frame by _flushPendingAura() called from OnUpdate (T013).
    -- UNIT_AURA                            = "HandleUnitAura",
    PLAYER_SPECIALIZATION_CHANGED        = "HandlePlayerSpecializationChanged",
    PLAYER_JOINED_PVP_MATCH              = "HandlePlayerJoinedPvpMatch",
    PVP_MATCH_ACTIVE                     = "HandlePvpMatchActive",
    PVP_MATCH_COMPLETE                   = "HandlePvpMatchComplete",
    PVP_MATCH_INACTIVE                   = "HandlePvpMatchInactive",
    PVP_MATCH_STATE_CHANGED              = "HandlePvpMatchStateChanged",
    ARENA_OPPONENT_UPDATE                = "HandleArenaOpponentUpdate",
    ARENA_PREP_OPPONENT_SPECIALIZATIONS  = "HandleArenaPrepOpponentSpecializations",
    UPDATE_BATTLEFIELD_STATUS            = "HandlePvpMatchStateChanged",
    ZONE_CHANGED_NEW_AREA                = "HandleZoneChanged",
    DUEL_REQUESTED                       = "HandleDuelRequested",
    DUEL_TO_THE_DEATH_REQUESTED          = "HandleDuelToTheDeathRequested",
    DUEL_INBOUNDS                        = "HandleDuelInbounds",
    DUEL_OUTOFBOUNDS                     = "HandleDuelOutOfBounds",
    DUEL_FINISHED                        = "HandleDuelFinished",
    PLAYER_PVP_TALENT_UPDATE             = "HandlePlayerPvpTalentUpdate",
    ARENA_CROWD_CONTROL_SPELL_UPDATE     = "HandleArenaCrowdControlUpdate",
    LOSS_OF_CONTROL_ADDED                = "HandleLossOfControlAdded",
    LOSS_OF_CONTROL_UPDATE               = "HandleLossOfControlUpdate",
    PLAYER_CONTROL_LOST                  = "HandlePlayerControlLost",
    PLAYER_CONTROL_GAINED                = "HandlePlayerControlGained",
    PLAYER_TARGET_CHANGED                = "HandlePlayerTargetChanged",
    PLAYER_FOCUS_CHANGED                 = "HandlePlayerFocusChanged",
    UNIT_PET                             = "HandleUnitPet",
    NAME_PLATE_UNIT_ADDED                = "HandleNamePlateUnitAdded",
    ADDON_RESTRICTION_STATE_CHANGED      = "HandleRestrictionStateChanged",
    INSPECT_READY                        = nil, -- handled via registered handler below
    CHAT_MSG_ADDON                       = nil, -- handled via registered handler below
}

local function dispatch(tracker, event, ...)
    -- Run registered external handlers first.
    local registered = _handlers[event]
    if registered then
        for _, handler in ipairs(registered) do
            handler(event, ...)
        end
    end

    -- Run built-in tracker method.
    local methodName = TRACKER_EVENT_MAP[event]
    if methodName then
        if type(tracker[methodName]) == "function" then
            tracker[methodName](tracker, ...)
        else
            -- Negative-space guard: TRACKER_EVENT_MAP maps this event to a
            -- method that does not exist (or is not a function) on the tracker.
            -- This is a programming error — the map and the module are out of sync.
            reportError("Events.dispatch",
                string.format("event '%s' mapped to missing method '%s'", event, methodName))
        end
    end

    -- Negative-space guard: event reached dispatch with no registered handler
    -- and no TRACKER_EVENT_MAP entry. This is a programming error — the event
    -- is registered but has no dispatch target. Check ROUTER_EVENTS against
    -- TRACKER_EVENT_MAP and Events.RegisterHandler() calls.
    if not registered and not methodName then
        if ns and ns.Addon and ns.Addon.Warn then
            ns.Addon:Warn(string.format(
                "dispatch: event '%s' has no handler — check ROUTER_EVENTS vs TRACKER_EVENT_MAP",
                event
            ))
        end
    end
end

Events:SetScript("OnEvent", function(_, event, ...)
    local args = { ... }

    if event == "ADDON_LOADED" then
        local addonName = args[1]
        if addonName ~= ADDON_NAME then
            return
        end
        local ok, err = xpcall(function()
            ns.Addon:InitializeCore()
        end, debugstack)
        if not ok then
            reportError("Initialization failed", err)
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        local ok, err = xpcall(function()
            ns.Addon:InitializeRuntime()
        end, debugstack)
        if not ok then
            reportError("Runtime initialization failed", err)
        end
        return
    end

    if not ns.Addon.runtimeInitialized then
        return
    end

    local tracker = ns.Addon:GetModule("CombatTracker")
    if tracker then
        local ok, err = xpcall(function()
            dispatch(tracker, event, unpack(args))
        end, debugstack)
        if not ok then
            reportError("Event handler failed for " .. event, err)
        end
    end
end)

Events:SetScript("OnUpdate", function(_, elapsed)
    if not ns.Addon.initialized then
        return
    end

    _elapsed = _elapsed + elapsed
    if _elapsed < ONUPDATE_INTERVAL then
        return
    end

    local tracker = ns.Addon:GetModule("CombatTracker")
    if tracker then
        local ok, err = xpcall(function()
            tracker:OnUpdate(_elapsed)
        end, debugstack)
        if not ok then
            reportError("OnUpdate failed", err)
        end
    end

    -- T013: Flush coalesced UNIT_AURA events once per tick.
    _flushPendingAura()

    -- Process inspect queue for PvP talent capture (Task 1.4).
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art and art.ProcessInspectQueue then
        art:ProcessInspectQueue(_elapsed)
    end

    _elapsed = 0
end)

for _, event in ipairs(ns.Constants.ROUTER_EVENTS) do
    Events:RegisterEvent(event)
end

-- Register CHAT_MSG_ADDON handler for Party Sync (Task 6.3).
Events.RegisterHandler("CHAT_MSG_ADDON", function(event, prefix, payload, channel, sender)
    local sync = ns.Addon:GetModule("PartySyncService")
    if sync and sync.HandleAddonMessage then
        sync:HandleAddonMessage(prefix, payload, channel, sender)
    end
end)

-- Register INSPECT_READY handler for ArenaRoundTracker PvP talent capture.
Events.RegisterHandler("INSPECT_READY", function()
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art and art.HandleInspectReady then
        art:HandleInspectReady()
    end
end)

-- ── Timeline Producer Wiring ─────────────────────────────────────────────────
-- T027-T030: Route sanctioned events to TimelineProducer for timeline event creation.

-- T028/T016: UNIT_SPELLCAST_SUCCEEDED → VisibleCastProducer (via TimelineProducer shim)
Events.RegisterHandler("UNIT_SPELLCAST_SUCCEEDED", function(event, unitTarget, castGUID, spellID, castBarID)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleUnitSpellcastSucceeded then
        tp:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID, castBarID)
    end
end)

-- T016: Arena cast lifecycle events → VisibleCastProducer.
-- NOTE: Some of these events may be forbidden in Midnight restricted sessions;
-- the ADDON_ACTION_BLOCKED handler will log the violation if so.
Events.RegisterHandler("UNIT_SPELLCAST_START", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastStart then
        vcp:HandleUnitSpellcastStart(unitTarget, castGUID, spellID, castBarID)
    end
end)

Events.RegisterHandler("UNIT_SPELLCAST_STOP", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastStop then
        vcp:HandleUnitSpellcastStop(unitTarget, castGUID, spellID, castBarID)
    end
end)

Events.RegisterHandler("UNIT_SPELLCAST_INTERRUPTED", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastInterrupted then
        vcp:HandleUnitSpellcastInterrupted(unitTarget, castGUID, spellID, castBarID)
    end
end)

Events.RegisterHandler("UNIT_SPELLCAST_CHANNEL_START", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastChannelStart then
        vcp:HandleUnitSpellcastChannelStart(unitTarget, castGUID, spellID, castBarID)
    end
end)

Events.RegisterHandler("UNIT_SPELLCAST_CHANNEL_STOP", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastChannelStop then
        vcp:HandleUnitSpellcastChannelStop(unitTarget, castGUID, spellID, castBarID)
    end
end)

-- T005: UNIT_SPELLCAST_FAILED — cast failed with a reason (e.g. LoS, range, interrupted).
-- Registered in ROUTER_EVENTS; forwarded to VisibleCastProducer for lifecycle tracking.
-- NOTE: May be forbidden in Midnight restricted sessions; ADDON_ACTION_BLOCKED will surface violations.
Events.RegisterHandler("UNIT_SPELLCAST_FAILED", function(event, unitTarget, castGUID, spellID, castBarID)
    local vcp = ns.Addon:GetModule("VisibleCastProducer")
    if vcp and vcp.HandleUnitSpellcastFailed then
        vcp:HandleUnitSpellcastFailed(unitTarget, castGUID, spellID, castBarID)
    end
end)

-- T013/T029: UNIT_AURA → coalescing accumulator.
-- Downstream dispatch (CombatTracker + TimelineProducer) happens in
-- _flushPendingAura() called from OnUpdate, once per unit per frame.
Events.RegisterHandler("UNIT_AURA", function(event, unitTarget, updateInfo)
    _accumulateUnitAura(unitTarget, updateInfo)
end)

-- T030: LOSS_OF_CONTROL_ADDED → CCReceivedProducer
Events.RegisterHandler("LOSS_OF_CONTROL_ADDED", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleLossOfControlAdded then
        tp:HandleLossOfControlAdded(...)
    end
end)

-- PLAYER_CONTROL_LOST → CCReceivedProducer
Events.RegisterHandler("PLAYER_CONTROL_LOST", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandlePlayerControlLost then
        tp:HandlePlayerControlLost(...)
    end
end)

-- PLAYER_CONTROL_GAINED → CCReceivedProducer (end marker)
Events.RegisterHandler("PLAYER_CONTROL_GAINED", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandlePlayerControlGained then
        tp:HandlePlayerControlGained(...)
    end
end)

-- PVP_MATCH_ACTIVE → MatchStateProducer
Events.RegisterHandler("PVP_MATCH_ACTIVE", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandlePvpMatchActive then
        tp:HandlePvpMatchActive(...)
    end
end)

-- PVP_MATCH_COMPLETE → MatchStateProducer
Events.RegisterHandler("PVP_MATCH_COMPLETE", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandlePvpMatchComplete then
        tp:HandlePvpMatchComplete(...)
    end
end)

-- DUEL_INBOUNDS → MatchStateProducer
Events.RegisterHandler("DUEL_INBOUNDS", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleDuelInbounds then
        tp:HandleDuelInbounds(...)
    end
end)

-- DUEL_FINISHED → MatchStateProducer
Events.RegisterHandler("DUEL_FINISHED", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleDuelFinished then
        tp:HandleDuelFinished(...)
    end
end)

-- DAMAGE_METER_COMBAT_SESSION_UPDATED → DamageMeterCheckpointProducer
Events.RegisterHandler("DAMAGE_METER_COMBAT_SESSION_UPDATED", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleDamageMeterCombatSessionUpdated then
        tp:HandleDamageMeterCombatSessionUpdated(...)
    end
end)

-- DAMAGE_METER_CURRENT_SESSION_UPDATED → DamageMeterCheckpointProducer
Events.RegisterHandler("DAMAGE_METER_CURRENT_SESSION_UPDATED", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleDamageMeterCurrentSessionUpdated then
        tp:HandleDamageMeterCurrentSessionUpdated(...)
    end
end)

-- INSPECT_READY → InspectProducer (timeline marker)
Events.RegisterHandler("INSPECT_READY", function(event, ...)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleInspectReady then
        tp:HandleInspectReady(...)
    end
end)

-- Register UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED for native DR tracking.
Events.RegisterHandler("UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED", function(event, unitTarget, trackerInfo)
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art and art.HandleDiminishStateUpdated then
        art:HandleDiminishStateUpdated(unitTarget, trackerInfo)
    end
end)

-- UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED → DRUpdateProducer
Events.RegisterHandler("UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED", function(event, unitTarget, trackerInfo)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleDiminishStateUpdated then
        tp:HandleDiminishStateUpdated(unitTarget, trackerInfo)
    end
end)

-- Diagnostic: log exactly which function triggered ADDON_ACTION_BLOCKED or
-- ADDON_ACTION_FORBIDDEN so the culprit can be identified in the trace log.
-- These events fire with (addonName, blockedFunctionName).
local function handleAddonActionBlocked(event, addonName, funcName)
    if addonName ~= ns.Constants.ADDON_NAME then return end
    if ns and ns.Addon and ns.Addon.Warn then
        ns.Addon:Warn(string.format("%s: blocked call to '%s'", event, tostring(funcName or "?")))
    end
end
Events:RegisterEvent("ADDON_ACTION_BLOCKED")
Events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
Events.RegisterHandler("ADDON_ACTION_BLOCKED",   handleAddonActionBlocked)
Events.RegisterHandler("ADDON_ACTION_FORBIDDEN",  handleAddonActionBlocked)

-- UnitGraphService handlers — identity graph for GUID↔token resolution.
Events.RegisterHandler("ARENA_OPPONENT_UPDATE", function(event, unitToken)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandleArenaOpponentUpdate then
        ugs:HandleArenaOpponentUpdate(unitToken)
    end
end)

Events.RegisterHandler("PLAYER_TARGET_CHANGED", function()
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandlePlayerTargetChanged then
        ugs:HandlePlayerTargetChanged()
    end
end)

Events.RegisterHandler("PLAYER_FOCUS_CHANGED", function()
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandlePlayerFocusChanged then
        ugs:HandlePlayerFocusChanged()
    end
end)

Events.RegisterHandler("GROUP_ROSTER_UPDATE", function()
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandleGroupRosterUpdate then
        ugs:HandleGroupRosterUpdate()
    end
end)

Events.RegisterHandler("UNIT_PET", function(event, unitId)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandleUnitPet then
        ugs:HandleUnitPet(unitId)
    end
end)

Events.RegisterHandler("NAME_PLATE_UNIT_ADDED", function(event, unitToken)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandleNamePlateAdded then
        ugs:HandleNamePlateAdded(unitToken)
    end
end)

Events.RegisterHandler("NAME_PLATE_UNIT_REMOVED", function(event, unitToken)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.HandleNamePlateRemoved then
        ugs:HandleNamePlateRemoved(unitToken)
    end
end)

-- T019: AuraReconciliationService nameplate hooks.
-- NAME_PLATE_UNIT_ADDED → full aura rescan for newly visible unit.
-- NAME_PLATE_UNIT_REMOVED → clean up stale aura records for that unit.
Events.RegisterHandler("NAME_PLATE_UNIT_ADDED", function(event, unitToken)
    local ars = ns.Addon:GetModule("AuraReconciliationService")
    if ars and ars.HandleFullRescan then
        ars:HandleFullRescan(unitToken)
    end
end)

Events.RegisterHandler("NAME_PLATE_UNIT_REMOVED", function(event, unitToken)
    local ars = ns.Addon:GetModule("AuraReconciliationService")
    if ars and ars.HandleUnitRemoved then
        ars:HandleUnitRemoved(unitToken)
    end
end)

-- ADDON_RESTRICTION_STATE_CHANGED → CombatTracker restriction awareness (12.0.0+)
Events.RegisterHandler("ADDON_RESTRICTION_STATE_CHANGED", function(event, ...)
    local tracker = ns.Addon:GetModule("CombatTracker")
    if tracker and tracker.HandleRestrictionStateChanged then
        tracker:HandleRestrictionStateChanged(...)
    end
end)

-- Expose for external handler registration.
ns.Events = Events
