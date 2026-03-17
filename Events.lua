local ADDON_NAME, ns = ...

local Events = CreateFrame("Frame")

local function reportError(prefix, message)
    if ns and ns.Addon and ns.Addon.Warn then
        ns.Addon:Warn(string.format("%s: %s", prefix, tostring(message)))
    end
end

local function dispatch(tracker, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        tracker:HandlePlayerEnteringWorld(...)
    elseif event == "TRAIT_CONFIG_LIST_UPDATED" then
        tracker:HandleTraitConfigListUpdated(...)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        tracker:HandleCombatLogEvent()
    elseif event == "PLAYER_REGEN_DISABLED" then
        tracker:HandlePlayerRegenDisabled()
    elseif event == "PLAYER_REGEN_ENABLED" then
        tracker:HandlePlayerRegenEnabled()
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        tracker:HandleDamageMeterCombatSessionUpdated(...)
    elseif event == "DAMAGE_METER_CURRENT_SESSION_UPDATED" then
        tracker:HandleDamageMeterCurrentSessionUpdated(...)
    elseif event == "DAMAGE_METER_RESET" then
        tracker:HandleDamageMeterReset(...)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        tracker:HandleUnitSpellcastSucceeded(...)
    elseif event == "UNIT_AURA" then
        tracker:HandleUnitAura(...)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        tracker:HandlePlayerSpecializationChanged(...)
    elseif event == "PLAYER_JOINED_PVP_MATCH" then
        tracker:HandlePlayerJoinedPvpMatch(...)
    elseif event == "PVP_MATCH_ACTIVE" then
        tracker:HandlePvpMatchActive(...)
    elseif event == "PVP_MATCH_COMPLETE" then
        tracker:HandlePvpMatchComplete(...)
    elseif event == "PVP_MATCH_INACTIVE" then
        tracker:HandlePvpMatchInactive(...)
    elseif event == "PVP_MATCH_STATE_CHANGED" then
        tracker:HandlePvpMatchStateChanged(...)
    elseif event == "ARENA_OPPONENT_UPDATE" then
        tracker:HandleArenaOpponentUpdate(...)
    elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
        tracker:HandleArenaPrepOpponentSpecializations(...)
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        tracker:HandlePvpMatchStateChanged(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        tracker:HandleZoneChanged(...)
    elseif event == "DUEL_REQUESTED" then
        tracker:HandleDuelRequested(...)
    elseif event == "DUEL_TO_THE_DEATH_REQUESTED" then
        tracker:HandleDuelToTheDeathRequested(...)
    elseif event == "DUEL_INBOUNDS" then
        tracker:HandleDuelInbounds(...)
    elseif event == "DUEL_OUTOFBOUNDS" then
        tracker:HandleDuelOutOfBounds(...)
    elseif event == "DUEL_FINISHED" then
        tracker:HandleDuelFinished(...)
    elseif event == "PLAYER_PVP_TALENT_UPDATE" then
        tracker:HandlePlayerPvpTalentUpdate(...)
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

    local tracker = ns.Addon:GetModule("CombatTracker")
    if tracker then
        local ok, err = xpcall(function()
            tracker:OnUpdate(elapsed)
        end, debugstack)
        if not ok then
            reportError("OnUpdate failed", err)
        end
    end
end)

for _, event in ipairs(ns.Constants.ROUTER_EVENTS) do
    Events:RegisterEvent(event)
end
