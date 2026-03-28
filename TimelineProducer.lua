local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local TimelineProducer = {}

-- ---------------------------------------------------------------------------
-- Core: event append + session accessor
-- ---------------------------------------------------------------------------

--- Append a timeline event to the active session's timelineEvents list.
--- Required fields: t, lane, type, source, confidence.
--- Optional fields: spellId, spellName, unitToken, guid, amount, meta.
function TimelineProducer:AppendTimelineEvent(session, event)
    if not session or not session.timelineEvents then return end
    if not event or not event.t or not event.lane or not event.type then return end
    session.timelineEvents[#session.timelineEvents + 1] = event
end

--- Retrieve the current active session from CombatTracker.
function TimelineProducer:GetCurrentSession()
    local tracker = ns.Addon:GetModule("CombatTracker")
    return tracker and tracker:GetCurrentSession() or nil
end

-- ---------------------------------------------------------------------------
-- Spell classification helper
-- ---------------------------------------------------------------------------

--- Look up spell category from Constants.SPELL_CATEGORIES and
--- ns.StaticPvpData.SPELL_INTELLIGENCE (the enriched seed catalogue).
--- Returns a table with isOffensive, isDefensive, isCrowdControl,
--- isMobility, isUtility booleans.
local function classifySpell(spellID)
    local category = Constants.SPELL_CATEGORIES and Constants.SPELL_CATEGORIES[spellID] or nil

    -- Fallback: consult the enriched seed data if present.
    if not category then
        local staticPvp = ns.StaticPvpData
        if staticPvp and staticPvp.GetSpellInfo then
            local seedInfo = staticPvp.GetSpellInfo(spellID)
            if seedInfo and seedInfo.category then
                category = seedInfo.category
            end
        end
    end

    if not category then
        return {
            isOffensive = false,
            isDefensive = false,
            isCrowdControl = false,
            isMobility = false,
            isUtility = false,
            category = nil,
        }
    end

    return {
        isOffensive = category == "offensive",
        isDefensive = category == "defensive",
        isCrowdControl = category == "crowd_control",
        isMobility = category == "mobility",
        isUtility = category == "utility",
        category = category,
    }
end

-- ---------------------------------------------------------------------------
-- T020: PlayerCastProducer
-- Handles UNIT_SPELLCAST_SUCCEEDED for player and pet units.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID)
    if unitTarget ~= "player" and unitTarget ~= "pet" then return end

    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    -- Resolve spell name via pcall-wrapped C_Spell API.
    local spellName = nil
    local okName, nameResult = pcall(function()
        return ApiCompat.GetSpellName(spellID)
    end)
    if okName then
        spellName = nameResult
    end

    local classification = classifySpell(spellID)

    self:AppendTimelineEvent(session, {
        t = t,
        lane = Constants.TIMELINE_LANE.PLAYER_CAST,
        type = "cast",
        source = Constants.PROVENANCE_SOURCE.STATE,
        confidence = "confirmed",
        spellId = spellID,
        spellName = spellName,
        unitToken = unitTarget,
        guid = ApiCompat.GetPlayerGUID(),
        castGUID = castGUID,
        meta = {
            isOffensive = classification.isOffensive,
            isDefensive = classification.isDefensive,
            isCrowdControl = classification.isCrowdControl,
            isMobility = classification.isMobility,
            isUtility = classification.isUtility,
            category = classification.category,
        },
    })
end

-- ---------------------------------------------------------------------------
-- T021: VisibleAuraProducer
-- Handles UNIT_AURA for tracked units. Records aura applied/removed events.
-- ---------------------------------------------------------------------------

function TimelineProducer:HandleUnitAura(unitTarget, updateInfo)
    if not unitTarget or not Constants.TRACKED_UNITS[unitTarget] then return end

    local session = self:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t = now - (session.startedAt or now)

    if not updateInfo then return end

    -- Process added auras.
    if updateInfo.addedAuras then
        for _, auraData in ipairs(updateInfo.addedAuras) do
            -- Guard against secret values on arena opponent auras.
            local okAura, auraEvent = pcall(function()
                local auraSpellId = auraData.spellId
                local auraName = auraData.name
                local auraInstanceID = auraData.auraInstanceID
                local isHelpful = auraData.isHelpful
                local sourceUnit = auraData.sourceUnit
                local duration = auraData.duration
                local expirationTime = auraData.expirationTime

                -- Sanitize values that may be secret in Midnight arena.
                auraSpellId = ApiCompat.SanitizeNumber(auraSpellId)
                auraName = ApiCompat.SanitizeString(auraName)
                auraInstanceID = ApiCompat.SanitizeNumber(auraInstanceID)

                return {
                    t = t,
                    lane = Constants.TIMELINE_LANE.VISIBLE_AURA,
                    type = "applied",
                    source = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
                    confidence = "confirmed",
                    spellId = auraSpellId ~= 0 and auraSpellId or nil,
                    spellName = auraName,
                    unitToken = unitTarget,
                    meta = {
                        auraInstanceID = auraInstanceID ~= 0 and auraInstanceID or nil,
                        isHelpful = isHelpful and true or false,
                        sourceUnit = ApiCompat.SanitizeString(sourceUnit),
                        duration = ApiCompat.SanitizeNumber(duration),
                        expirationTime = ApiCompat.SanitizeNumber(expirationTime),
                    },
                }
            end)

            if okAura and auraEvent then
                self:AppendTimelineEvent(session, auraEvent)
            end
        end
    end

    -- Process removed auras.
    if updateInfo.removedAuraInstanceIDs then
        for _, instanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            local okRemoved, removedEvent = pcall(function()
                local sanitizedId = ApiCompat.SanitizeNumber(instanceID)
                return {
                    t = t,
                    lane = Constants.TIMELINE_LANE.VISIBLE_AURA,
                    type = "removed",
                    source = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
                    confidence = "confirmed",
                    unitToken = unitTarget,
                    meta = {
                        auraInstanceID = sanitizedId ~= 0 and sanitizedId or nil,
                    },
                }
            end)

            if okRemoved and removedEvent then
                self:AppendTimelineEvent(session, removedEvent)
            end
        end
    end
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
