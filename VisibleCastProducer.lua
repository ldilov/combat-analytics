local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers   = ns.Helpers

local VisibleCastProducer = {}

-- ---------------------------------------------------------------------------
-- Spell classification helper (shared with TimelineProducer via ns.StaticPvpData)
-- ---------------------------------------------------------------------------

local function classifySpell(spellID)
    local category = Constants.SPELL_CATEGORIES and Constants.SPELL_CATEGORIES[spellID] or nil

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
        return { isOffensive=false, isDefensive=false, isCrowdControl=false,
                 isMobility=false, isUtility=false, category=nil }
    end

    return {
        isOffensive    = category == "offensive",
        isDefensive    = category == "defensive",
        isCrowdControl = category == "crowd_control",
        isMobility     = category == "mobility",
        isUtility      = category == "utility",
        category       = category,
    }
end

local function isTrackedVisibleUnit(unitTarget)
    return Constants.TRACKED_UNITS[unitTarget]
        or (unitTarget and unitTarget:match("^nameplate%d+$") ~= nil)
end

local function isObservedEnemyUnit(unitTarget)
    if not unitTarget then
        return false
    end
    if unitTarget:match("^arena%dpet?$") ~= nil then
        return true
    end
    if unitTarget == "target" or unitTarget == "focus" or unitTarget:match("^nameplate%d+$") ~= nil then
        return ApiCompat.UnitCanAttack("player", unitTarget)
            or ApiCompat.UnitIsEnemy("player", unitTarget)
    end
    return false
end

local function getTP()
    return ns.Addon:GetModule("TimelineProducer")
end

-- ---------------------------------------------------------------------------
-- T008/T009: Actor identity resolution
-- Resolves normalized top-level source identity fields from UnitGraphService.
-- Returns: guid, sourceName, sourceClassFile, sourceSlot,
--          ownerGuid, ownerName, ownerSlot, ownershipConfidence
-- ---------------------------------------------------------------------------

local function resolveActorIdentity(unitTarget)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    local guid, sourceName, sourceClassFile, sourceSlot
    local ownerGuid, ownerName, ownerSlot, ownershipConfidence

    local ok = pcall(function()
        if unitTarget == "player" then
            -- T008: Player's own casts — GUID from API, no owner.
            guid = ApiCompat.GetPlayerGUID()

        elseif unitTarget == "pet" then
            -- T009: Player pet — use pet GUID as source, player as owner (confirmed).
            guid      = ApiCompat.GetUnitGUID("pet")
            ownerGuid = ApiCompat.GetPlayerGUID()
            ownershipConfidence = "confirmed"
            if ownerGuid and ugs then
                local ownerNode = ugs:GetNode(ownerGuid)
                if ownerNode then
                    ownerName = ownerNode.name
                    ownerSlot = ownerNode.arenaSlot  -- nil until Phase 4
                end
            end

        else
            -- Arena unit or arena pet: resolve via UnitGraphService.
            if ugs then guid = ugs:GetGUIDForToken(unitTarget) end

            -- T009: Arena pet tokens (arena1pet–arena5pet) — owner is the matching
            -- arena slot unit. Use confirmed ownership since slot correspondence is direct.
            if unitTarget:find("pet$") then
                local ownerToken = unitTarget:gsub("pet$", "")
                if ugs then
                    ownerGuid = ugs:GetGUIDForToken(ownerToken)
                end
                if ownerGuid and ugs then
                    local ownerNode = ugs:GetNode(ownerGuid)
                    if ownerNode then
                        ownerName = ownerNode.name
                        ownerSlot = ownerNode.arenaSlot  -- nil until Phase 4
                    end
                    ownershipConfidence = "confirmed"
                else
                    ownershipConfidence = "unresolved"
                end
            end
        end

        -- T008: Enrich source identity from the UnitGraphService node record.
        if guid and ugs then
            local node = ugs:GetNode(guid)
            if node then
                sourceName      = node.name
                sourceClassFile = node.classFile
                sourceSlot      = node.arenaSlot  -- populated in Phase 4
            end
        end
    end)

    if not ok then
        guid = nil; ownerGuid = nil
    end

    return guid, sourceName, sourceClassFile, sourceSlot,
           ownerGuid, ownerName, ownerSlot, ownershipConfidence
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_SUCCEEDED — confirmed cast completion
-- Handles player, pet, arena1–5, arena1–5pet.
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellID, castBarID)
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    -- Resolve spell name; field may be secret on arena units in restricted sessions.
    local spellName = nil
    local okName, nameResult = pcall(function()
        return ApiCompat.GetSpellName(spellID)
    end)
    if okName then spellName = nameResult end

    -- Sanitize spellID — may be a secret value for arena opponents.
    local safeSpellId = ApiCompat.SanitizeNumber(spellID)

    local classification = classifySpell(safeSpellId or 0)

    -- T008/T009: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        -- T006: VISIBLE_CAST lane for all visible spellcast lifecycle events.
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "cast_succeeded",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "confirmed",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        spellName      = spellName,
        -- T008: Normalized top-level source identity fields.
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        -- T009: Pet owner linkage (populated when source is a pet unit).
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases (legacy consumers may read these field names).
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
        meta = {
            isOffensive    = classification.isOffensive,
            isDefensive    = classification.isDefensive,
            isCrowdControl = classification.isCrowdControl,
            isMobility     = classification.isMobility,
            isUtility      = classification.isUtility,
            category       = classification.category,
            castBarId      = castBarID,
        },
    })
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_START — cast begin (confidence = partial)
-- Player/pet casts are tracked via SUCCEEDED; START captures arena units for
-- early cast visibility before completion is confirmed.
-- NOTE: These events may be forbidden in Midnight restricted sessions;
-- ADDON_ACTION_BLOCKED diagnostic in Events.lua will surface any violation.
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastStart(unitTarget, castGUID, spellID, castBarID)
    -- Only emit partial events for arena units; player/pet casts use SUCCEEDED.
    if not isObservedEnemyUnit(unitTarget) then return end
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    -- spellID may be secret on restricted arena units.
    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    local spellName = nil
    if safeSpellId and safeSpellId ~= 0 then
        pcall(function() spellName = ApiCompat.GetSpellName(safeSpellId) end)
    end

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "cast_start",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        -- "partial": cast has started but completion is not yet confirmed.
        confidence     = "partial",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        spellName      = spellName,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_INTERRUPTED — cast was interrupted
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastInterrupted(unitTarget, castGUID, spellID, castBarID)
    if not isObservedEnemyUnit(unitTarget) then return end
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    local spellName = nil
    if safeSpellId and safeSpellId ~= 0 then
        pcall(function() spellName = ApiCompat.GetSpellName(safeSpellId) end)
    end

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "cast_interrupted",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "confirmed",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        spellName      = spellName,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_STOP — cast stopped (cancelled/stopped, arena units only)
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastStop(unitTarget, castGUID, spellID, castBarID)
    if not isObservedEnemyUnit(unitTarget) then return end
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "cast_stop",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "confirmed",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- T007: UNIT_SPELLCAST_FAILED — cast failed with a reason (all tracked units)
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastFailed(unitTarget, castGUID, spellID, castBarID)
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    local spellName = nil
    if safeSpellId and safeSpellId ~= 0 then
        pcall(function() spellName = ApiCompat.GetSpellName(safeSpellId) end)
    end

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "cast_failed",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "confirmed",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        spellName      = spellName,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_CHANNEL_START — channel begin (partial confidence)
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastChannelStart(unitTarget, castGUID, spellID, castBarID)
    if not isObservedEnemyUnit(unitTarget) then return end
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    local spellName = nil
    if safeSpellId and safeSpellId ~= 0 then
        pcall(function() spellName = ApiCompat.GetSpellName(safeSpellId) end)
    end

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "channel_start",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "partial",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        spellName      = spellName,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- UNIT_SPELLCAST_CHANNEL_STOP — channel ended
-- ---------------------------------------------------------------------------

function VisibleCastProducer:HandleUnitSpellcastChannelStop(unitTarget, castGUID, spellID, castBarID)
    if not isObservedEnemyUnit(unitTarget) then return end
    if not isTrackedVisibleUnit(unitTarget) then return end

    local tp = getTP()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local safeSpellId = nil
    pcall(function() safeSpellId = ApiCompat.SanitizeNumber(spellID) end)

    -- T008: Resolve normalized actor identity.
    local sourceGuid, sourceName, sourceClassFile, sourceSlot,
          ownerGuid, ownerName, ownerSlot, ownershipConfidence =
        resolveActorIdentity(unitTarget)

    tp:AppendTimelineEvent(session, {
        t              = t,
        lane           = Constants.TIMELINE_LANE.VISIBLE_CAST,
        type           = "channel_stop",
        source         = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence     = "confirmed",
        chronology     = "realtime",
        spellId        = safeSpellId ~= 0 and safeSpellId or nil,
        sourceGuid      = sourceGuid,
        sourceName      = sourceName,
        sourceClassFile = sourceClassFile,
        sourceSlot      = sourceSlot,
        sourceUnitToken = unitTarget,
        ownerGuid           = ownerGuid,
        ownerName           = ownerName,
        ownerSlot           = ownerSlot,
        ownershipConfidence = ownershipConfidence,
        castGUID            = castGUID,
        castBarId           = castBarID,  -- non-secret cast sequence counter (12.0.0+)
        -- Backward-compat aliases.
        guid      = sourceGuid,
        unitToken = unitTarget,
        ownerGUID = ownerGuid,
    })
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("VisibleCastProducer", VisibleCastProducer)
