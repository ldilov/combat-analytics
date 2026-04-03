local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers   = ns.Helpers

local AuraReconciliationService = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function getTimelineProducer()
    return ns.Addon:GetModule("TimelineProducer")
end

-- T025: Resolve source identity (GUID, name, classFile, arenaSlot) for the
-- given unit token using UnitGraphService as the primary source with a direct
-- ApiCompat.GetUnitGUID fallback. Returns four values; all nil on failure.
local function resolveActorIdentity(unitToken)
    local ugs = ns.Addon:GetModule("UnitGraphService")
    local guid, name, classFile, arenaSlot

    local ok = pcall(function()
        if ugs then
            guid = ugs:GetGUIDForToken(unitToken)
            if guid then
                local node = ugs:GetNode(guid)
                if node then
                    name      = node.name
                    classFile = node.classFile
                    arenaSlot = node.arenaSlot
                end
            end
        end
        -- Fallback: direct API lookup when UGS did not resolve the GUID.
        if not guid then
            guid = ApiCompat.GetUnitGUID(unitToken)
        end
    end)
    if not ok then
        guid = nil; name = nil; classFile = nil; arenaSlot = nil
    end

    return guid, name, classFile, arenaSlot
end

-- Enumerate all current auras on a unit from live game state.
-- Returns a list of raw aura data tables. Each table is wrapped in pcall to
-- avoid crashing on secret values present on arena opponent auras in Midnight.
local function enumLiveAuras(unitToken)
    local results = {}
    if not AuraUtil or not AuraUtil.ForEachAura then return results end

    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local ok = pcall(function()
            AuraUtil.ForEachAura(unitToken, filter, nil, function(auraData)
                if auraData then
                    results[#results + 1] = auraData
                end
            end)
        end)
        if not ok then
            ns.Addon:Trace("aura_reconciliation.enum_failed", { unit = unitToken, filter = filter })
        end
    end
    return results
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Incremental update path — called from the coalesced UNIT_AURA handler
--- (Events.lua _flushPendingAura). Processes addedAuras and
--- removedAuraInstanceIDs from the merged updateInfo for a single unit.
function AuraReconciliationService:HandleUnitAura(unitTarget, updateInfo)
    if not unitTarget or not Constants.TRACKED_UNITS[unitTarget] then return end

    local tp = getTimelineProducer()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    if not updateInfo then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    -- Process added auras.
    if updateInfo.addedAuras then
        for _, auraData in ipairs(updateInfo.addedAuras) do
            local okAura, auraEvent = pcall(function()
                local auraSpellId    = auraData.spellId
                local auraName       = auraData.name
                local auraInstanceID = auraData.auraInstanceID
                local isHelpful      = auraData.isHelpful
                local sourceUnit     = auraData.sourceUnit
                local duration       = auraData.duration
                local expirationTime = auraData.expirationTime

                auraSpellId    = ApiCompat.SanitizeNumber(auraSpellId)
                auraName       = ApiCompat.SanitizeString(auraName)
                auraInstanceID = ApiCompat.SanitizeNumber(auraInstanceID)

                -- T025: Resolve actor identity for the unit that has the aura.
                local srcGuid, srcName, srcClassFile, srcSlot = resolveActorIdentity(unitTarget)

                return {
                    t               = t,
                    lane            = Constants.TIMELINE_LANE.VISIBLE_AURA,
                    type            = "applied",
                    source          = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
                    confidence      = Constants.ATTRIBUTION_CONFIDENCE.confirmed,
                    sourceGuid      = srcGuid,
                    sourceName      = srcName,
                    sourceClassFile = srcClassFile,
                    sourceSlot      = srcSlot,
                    sourceUnitToken = unitTarget,
                    spellId         = auraSpellId ~= 0 and auraSpellId or nil,
                    spellName       = auraName,
                    unitToken       = unitTarget,
                    meta = {
                        auraInstanceID = auraInstanceID ~= 0 and auraInstanceID or nil,
                        isHelpful      = isHelpful and true or false,
                        sourceUnit     = ApiCompat.SanitizeString(sourceUnit),
                        duration       = ApiCompat.SanitizeNumber(duration),
                        expirationTime = ApiCompat.SanitizeNumber(expirationTime),
                    },
                }
            end)

            if okAura and auraEvent then
                tp:AppendTimelineEvent(session, auraEvent)
            end
        end
    end

    -- Process removed auras.
    if updateInfo.removedAuraInstanceIDs then
        for _, instanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            local okRemoved, removedEvent = pcall(function()
                local sanitizedId = ApiCompat.SanitizeNumber(instanceID)
                -- T025: Resolve actor identity for the unit whose aura was removed.
                local srcGuid, srcName, srcClassFile, srcSlot = resolveActorIdentity(unitTarget)
                return {
                    t               = t,
                    lane            = Constants.TIMELINE_LANE.VISIBLE_AURA,
                    type            = "removed",
                    source          = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
                    confidence      = Constants.ATTRIBUTION_CONFIDENCE.confirmed,
                    sourceGuid      = srcGuid,
                    sourceName      = srcName,
                    sourceClassFile = srcClassFile,
                    sourceSlot      = srcSlot,
                    sourceUnitToken = unitTarget,
                    unitToken       = unitTarget,
                    meta = {
                        auraInstanceID = sanitizedId ~= 0 and sanitizedId or nil,
                    },
                }
            end)

            if okRemoved and removedEvent then
                tp:AppendTimelineEvent(session, removedEvent)
            end
        end
    end
end

--- Full-rescan path — enumerate all live auras on unitToken from game state.
--- Records pre-existing auras as confidence = "observed_active" so that no
--- fabricated application time is emitted for auras that were already active
--- when the unit entered observation.
--- Called by: T019 NAME_PLATE_UNIT_ADDED hook, arena slot resolution.
function AuraReconciliationService:HandleFullRescan(unitToken)
    if not unitToken then return end

    local tp = getTimelineProducer()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    local liveAuras = enumLiveAuras(unitToken)
    for _, auraData in ipairs(liveAuras) do
        local okAura, auraEvent = pcall(function()
            local auraSpellId    = auraData.spellId
            local auraName       = auraData.name
            local auraInstanceID = auraData.auraInstanceID
            local isHelpful      = auraData.isHelpful
            local sourceUnit     = auraData.sourceUnit
            local duration       = auraData.duration
            local expirationTime = auraData.expirationTime

            auraSpellId    = ApiCompat.SanitizeNumber(auraSpellId)
            auraName       = ApiCompat.SanitizeString(auraName)
            auraInstanceID = ApiCompat.SanitizeNumber(auraInstanceID)

            -- T025: Resolve actor identity; confidence = "inferred" for rescan-
            -- detected auras (aura was already active, application not witnessed).
            local srcGuid, srcName, srcClassFile, srcSlot = resolveActorIdentity(unitToken)

            return {
                t               = t,
                lane            = Constants.TIMELINE_LANE.VISIBLE_AURA,
                type            = "observed_active",
                source          = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
                -- confidence = "inferred": aura was already present when observed;
                -- application time is unknown. Actor identity inferred from unit state.
                confidence      = Constants.ATTRIBUTION_CONFIDENCE.inferred,
                sourceGuid      = srcGuid,
                sourceName      = srcName,
                sourceClassFile = srcClassFile,
                sourceSlot      = srcSlot,
                sourceUnitToken = unitToken,
                spellId         = auraSpellId ~= 0 and auraSpellId or nil,
                spellName       = auraName,
                unitToken       = unitToken,
                meta = {
                    auraInstanceID = auraInstanceID ~= 0 and auraInstanceID or nil,
                    isHelpful      = isHelpful and true or false,
                    sourceUnit     = ApiCompat.SanitizeString(sourceUnit),
                    duration       = ApiCompat.SanitizeNumber(duration),
                    expirationTime = ApiCompat.SanitizeNumber(expirationTime),
                },
            }
        end)

        if okAura and auraEvent then
            tp:AppendTimelineEvent(session, auraEvent)
        end
    end

    ns.Addon:Trace("aura_reconciliation.full_rescan", {
        unit   = unitToken,
        count  = #liveAuras,
        offset = t,
    })
end

--- Unit-removed path — emits a visibility-lost marker so timeline consumers
--- know that subsequent aura data for this unit may be stale.
--- Called by: T019 NAME_PLATE_UNIT_REMOVED hook.
function AuraReconciliationService:HandleUnitRemoved(unitToken)
    if not unitToken then return end

    local tp = getTimelineProducer()
    if not tp then return end

    local session = tp:GetCurrentSession()
    if not session then return end

    local now = Helpers.Now()
    local t   = now - (session.startedAt or now)

    -- T025: Resolve actor identity for the departing unit.
    local srcGuid, srcName, srcClassFile, srcSlot = resolveActorIdentity(unitToken)

    tp:AppendTimelineEvent(session, {
        t               = t,
        lane            = Constants.TIMELINE_LANE.VISIBLE_AURA,
        type            = "unit_left_visibility",
        source          = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT,
        confidence      = Constants.ATTRIBUTION_CONFIDENCE.confirmed,
        sourceGuid      = srcGuid,
        sourceName      = srcName,
        sourceClassFile = srcClassFile,
        sourceSlot      = srcSlot,
        sourceUnitToken = unitToken,
        unitToken       = unitToken,
    })

    ns.Addon:Trace("aura_reconciliation.unit_removed", {
        unit   = unitToken,
        offset = t,
    })
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("AuraReconciliationService", AuraReconciliationService)
