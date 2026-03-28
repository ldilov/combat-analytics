local ADDON_NAME, ns = ...

local Events = CreateFrame("Frame")

local ONUPDATE_INTERVAL = 0.1
local _elapsed = 0

-- Modular event router: handlers registered per event name.
local _handlers = {}

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
    UNIT_AURA                            = "HandleUnitAura",
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

-- T028: UNIT_SPELLCAST_SUCCEEDED → PlayerCastProducer + spell stats
Events.RegisterHandler("UNIT_SPELLCAST_SUCCEEDED", function(event, unitTarget, castGUID, spellID)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleUnitSpellcastSucceeded then
        tp:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID)
    end
end)

-- T029: UNIT_AURA → VisibleAuraProducer + aura stats
Events.RegisterHandler("UNIT_AURA", function(event, unitTarget, updateInfo)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp and tp.HandleUnitAura then
        tp:HandleUnitAura(unitTarget, updateInfo)
    end
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

-- Expose for external handler registration.
ns.Events = Events
