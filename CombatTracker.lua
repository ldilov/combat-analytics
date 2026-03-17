local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local CombatTracker = {
    playerInCombat = false,
}

local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0
local REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0

local function hasFlag(value, flag)
    return flag ~= 0 and value ~= nil and bit.band(value, flag) > 0
end

local function isMineGuid(guid)
    if not guid then
        return false
    end
    return guid == ApiCompat.GetPlayerGUID() or ApiCompat.IsGuidPet(guid)
end

local function createSpellAggregate(spellId)
    return {
        spellId = spellId,
        castCount = 0,
        executeCount = 0,
        hitCount = 0,
        critCount = 0,
        missCount = 0,
        totalDamage = 0,
        totalHealing = 0,
        overkill = 0,
        overhealing = 0,
        absorbed = 0,
        minHit = nil,
        maxHit = 0,
        minCrit = nil,
        maxCrit = 0,
        firstUse = nil,
        lastUse = nil,
        lastCastOffset = nil,
        totalInterval = 0,
        intervalCount = 0,
        averageInterval = 0,
    }
end

local function createAuraAggregate(auraId)
    return {
        auraId = auraId,
        totalUptime = 0,
        applications = 0,
        refreshCount = 0,
        stacksObserved = 0,
        maxStacksObserved = 0,
        procCount = 0,
        damageDuringWindows = 0,
        healingDuringWindows = 0,
        damageTakenDuringWindows = 0,
        castsDuringWindows = 0,
        isProc = false,
    }
end

local function createCooldownAggregate(spellId, category)
    return {
        spellId = spellId,
        category = category,
        useCount = 0,
        firstUsedAt = nil,
        lastUsedAt = nil,
        totalSpacing = 0,
        spacingCount = 0,
        averageSpacing = 0,
        damageDuringWindows = 0,
        healingDuringWindows = 0,
        damageTakenDuringWindows = 0,
        castsDuringWindows = 0,
    }
end

local function buildActorStub(guid, name, flags)
    return {
        guid = guid,
        name = name,
        isMine = isMineGuid(guid) or hasFlag(flags, AFFILIATION_MINE),
        isPlayer = ApiCompat.IsGuidPlayer(guid) or hasFlag(flags, TYPE_PLAYER),
        isHostile = hasFlag(flags, REACTION_HOSTILE),
    }
end

local function scheduleAfter(delaySeconds, callback)
    if C_Timer and C_Timer.After then
        C_Timer.After(delaySeconds, callback)
        return true
    end
    return false
end

local function getSessionRelativeOffset(session)
    if not session or not session.startedAt then
        return 0
    end
    return math.max(0, Helpers.Now() - session.startedAt)
end

local function getRecordedCastCount(session)
    local total = 0
    for _, aggregate in pairs(session and session.spells or {}) do
        total = total + (aggregate.castCount or 0)
    end
    return total
end

local function isSuccessfulCastEvent(eventRecord)
    return eventRecord
        and eventRecord.eventType == "cast"
        and eventRecord.sourceMine
        and eventRecord.subEvent ~= "SPELL_CAST_FAILED"
end

local function isProcCandidate(unitToken, auraData)
    if not auraData or not auraData.spellId or not auraData.isHelpful then
        return false
    end
    if unitToken ~= "player" and unitToken ~= "pet" then
        return false
    end
    local category = Constants.SPELL_CATEGORIES[auraData.spellId]
    if auraData.duration and auraData.duration > 0 and auraData.duration <= 20 then
        return true
    end
    if category == Constants.SPELL_CATEGORY.OFFENSIVE or category == Constants.SPELL_CATEGORY.DEFENSIVE or category == Constants.SPELL_CATEGORY.MOBILITY then
        return true
    end
    return not category
end

function CombatTracker:Initialize()
    ns.Addon:GetModule("SessionClassifier"):Initialize()
end

function CombatTracker:InvalidatePendingFinalize(session)
    if not session then
        return
    end
    session.pendingFinalizeAt = nil
    session.finalizeToken = (session.finalizeToken or 0) + 1
end

function CombatTracker:ScheduleFinalize(session, delay, reason)
    if not session or session.state ~= "active" then
        return
    end

    session.finalizeToken = (session.finalizeToken or 0) + 1
    local finalizeToken = session.finalizeToken
    session.pendingFinalizeAt = Helpers.Now() + delay

    scheduleAfter(delay, function()
        local current = self:GetCurrentSession()
        if current ~= session or current.state ~= "active" then
            return
        end
        if current.finalizeToken ~= finalizeToken then
            return
        end
        if reason == "regen_end" and self.playerInCombat then
            return
        end
        self:FinalizeSession(nil, reason)
    end)
end

function CombatTracker:GetCurrentSession()
    return ns.Addon.runtime.currentSession
end

function CombatTracker:SetCurrentSession(session)
    ns.Addon.runtime.currentSession = session
end

function CombatTracker:GetCurrentMatch()
    return ns.Addon.runtime.currentMatch
end

function CombatTracker:SetCurrentMatch(matchRecord)
    ns.Addon.runtime.currentMatch = matchRecord
end

function CombatTracker:FlushSessionForInspection()
    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        return false
    end

    local now = Helpers.Now()
    local idleFor = session.lastRelevantAt and (now - session.lastRelevantAt) or 0

    if not self.playerInCombat then
        self:FinalizeSession(nil, "manual_flush")
        return true
    end

    if (session.context == Constants.CONTEXT.TRAINING_DUMMY or session.context == Constants.CONTEXT.GENERAL) and idleFor >= 1.5 then
        self:FinalizeSession(nil, "manual_flush")
        return true
    end

    return false
end

function CombatTracker:AddTimelineMarker(session, markerType, payload)
    session.timeline = session.timeline or {}
    session.timeline[#session.timeline + 1] = {
        markerType = markerType,
        timestampOffset = session.lastEventOffset or 0,
        payload = payload,
    }
end

function CombatTracker:RefreshSessionIdentity(session, preferredUnitToken, source)
    if not session then
        return
    end

    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier and classifier.RefreshSessionIdentity then
        classifier:RefreshSessionIdentity(session, preferredUnitToken, source)
    end
end

function CombatTracker:CreateSession(context, subcontext, identitySource)
    ns.Addon:Trace("session.create.begin", {
        context = context or "nil",
        subcontext = subcontext or "nil",
    })

    local snapshotService = ns.Addon:GetModule("SnapshotService")
    local classifier = ns.Addon:GetModule("SessionClassifier")
    local zoneName, mapId = ApiCompat.GetCurrentZoneName()
    local matchRecord = self:GetCurrentMatch()
    local session = {
        id = Helpers.GenerateId("combat"),
        schemaVersion = Constants.SCHEMA_VERSION,
        rawEventVersion = Constants.RAW_EVENT_VERSION,
        timestamp = ApiCompat.GetServerTime(),
        startedAt = Helpers.Now(),
        startLogTimestamp = nil,
        lastLogTimestamp = nil,
        lastEventOffset = 0,
        duration = 0,
        context = context,
        subcontext = subcontext,
        parentMatchId = matchRecord and matchRecord.id or nil,
        zoneName = zoneName,
        mapId = mapId,
        bracket = matchRecord and matchRecord.metadata and matchRecord.metadata.bracket or nil,
        result = Constants.SESSION_RESULT.UNKNOWN,
        actors = {},
        trackedActorGuids = {},
        rawEvents = {},
        spells = {},
        auras = {},
        cooldowns = {},
        visibleAuras = {},
        activeAuraWindows = {},
        utility = {
            interrupts = 0,
            successfulInterrupts = 0,
            failedInterrupts = 0,
            dispels = 0,
            ccApplied = 0,
            ccDuration = 0,
            mobilityUses = 0,
        },
        survival = {
            deaths = 0,
            defensivesUsed = 0,
            unusedDefensives = 0,
            totalAbsorbed = 0,
            selfHealing = 0,
            largestIncomingSpike = 0,
        },
        totals = {
            damageDone = 0,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
            overhealing = 0,
            overkill = 0,
        },
        localTotals = {
            damageDone = 0,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
            overhealing = 0,
            overkill = 0,
        },
        importedTotals = {
            damageDone = 0,
            healingDone = 0,
            damageTaken = 0,
            absorbed = 0,
        },
        windows = {},
        metrics = {},
        suggestions = {},
        timeline = {},
        primaryOpponent = nil,
        identity = classifier and classifier:BuildIdentity(context or Constants.CONTEXT.GENERAL, subcontext, identitySource or "state") or nil,
        import = {
            source = "none",
            damageMeterSessionId = nil,
            confidence = 0,
            durationDelta = nil,
            signalScore = 0,
            score = 0,
        },
        captureQuality = {
            rawEvents = Constants.CAPTURE_QUALITY.OK,
            enemyBuild = Constants.CAPTURE_QUALITY.DEGRADED,
        },
        state = "active",
        idleTime = 0,
        lastPlayerActionOffset = nil,
        pendingFinalizeAt = nil,
    }

    if classifier and classifier.InitializeSessionIdentity then
        classifier:InitializeSessionIdentity(session, context or Constants.CONTEXT.GENERAL, subcontext, identitySource or "state")
    end

    ns.Addon:Trace("session.snapshot.request", { reason = "session_start" })
    session.playerSnapshot = snapshotService:GetSessionPlayerSnapshot("session_start")
    ns.Addon:Trace("session.snapshot.ready", {
        buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown",
        quality = session.playerSnapshot and session.playerSnapshot.captureFlags and session.playerSnapshot.captureFlags.buildSnapshot or "ok",
        specId = session.playerSnapshot and session.playerSnapshot.specId or 0,
    })
    snapshotService:UpdateSessionActor(session, "player", "session_start")
    snapshotService:UpdateSessionActor(session, "pet", "session_start")
    self:SetCurrentSession(session)
    ns.Addon:Trace("session.create.ready", {
        context = session.context or "nil",
        id = session.id or "unknown",
    })
    ns.Addon:Debug("Started session %s context=%s subcontext=%s", session.id, tostring(context), tostring(subcontext))
    return session
end

function CombatTracker:CreateOrRefreshMatch(context, subcontext)
    local current = self:GetCurrentMatch()
    if current and current.state ~= "complete" then
        return current
    end

    local store = ns.Addon:GetModule("CombatStore")
    local matchRecord = store:CreateMatchRecord(context, subcontext)
    matchRecord.metadata = matchRecord.metadata or {}
    if context == Constants.CONTEXT.ARENA then
        matchRecord.metadata.isSoloShuffle = ApiCompat.IsSoloShuffle()
        matchRecord.metadata.isRatedArena = ApiCompat.IsRatedArena()
        matchRecord.metadata.isSkirmish = ApiCompat.IsArenaSkirmish()
        matchRecord.metadata.isBrawl = ApiCompat.IsInBrawl()
        matchRecord.metadata.bracket = ApiCompat.GetNumArenaOpponentSpecs()
    end
    self:SetCurrentMatch(matchRecord)
    return matchRecord
end

function CombatTracker:EnsureSpellAggregate(session, spellId)
    session.spells[spellId] = session.spells[spellId] or createSpellAggregate(spellId)
    return session.spells[spellId]
end

function CombatTracker:EnsureAuraAggregate(session, auraId)
    session.auras[auraId] = session.auras[auraId] or createAuraAggregate(auraId)
    return session.auras[auraId]
end

function CombatTracker:EnsureCooldownAggregate(session, spellId, category)
    session.cooldowns[spellId] = session.cooldowns[spellId] or createCooldownAggregate(spellId, category)
    return session.cooldowns[spellId]
end

function CombatTracker:GetSpellCategory(spellId)
    local category = Constants.SPELL_CATEGORIES[spellId]
    if category then
        return category
    end

    local taxonomy = ns.StaticPvpData and ns.StaticPvpData.SPELL_TAXONOMY or nil
    if taxonomy and taxonomy.majorOffensive and taxonomy.majorOffensive[spellId] then
        return Constants.SPELL_CATEGORY.OFFENSIVE
    end
    if taxonomy and taxonomy.majorDefensive and taxonomy.majorDefensive[spellId] then
        return Constants.SPELL_CATEGORY.DEFENSIVE
    end
    if ApiCompat.AuraIsBigDefensive and ApiCompat.AuraIsBigDefensive(spellId) then
        return Constants.SPELL_CATEGORY.DEFENSIVE
    end

    return nil
end

function CombatTracker:AppendRawEvent(session, eventRecord)
    if not ns.Addon:GetSetting("keepRawEvents") then
        return
    end

    if #session.rawEvents >= Constants.MAX_RAW_EVENTS_PER_SESSION then
        session.captureQuality.rawEvents = Constants.CAPTURE_QUALITY.OVERFLOW
        return
    end

    session.rawEvents[#session.rawEvents + 1] = {
        timestampOffset = eventRecord.timestampOffset,
        subEvent = eventRecord.subEvent,
        eventType = eventRecord.eventType,
        sourceGuid = eventRecord.sourceGuid,
        destGuid = eventRecord.destGuid,
        sourceFlags = eventRecord.sourceFlags,
        destFlags = eventRecord.destFlags,
        spellId = eventRecord.spellId,
        auraId = eventRecord.auraId,
        extraSpellId = eventRecord.extraSpellId,
        amount = eventRecord.amount,
        overkill = eventRecord.overkill,
        overhealing = eventRecord.overhealing,
        absorbed = eventRecord.absorbed,
        missType = eventRecord.missType,
        auraType = eventRecord.auraType,
        critical = eventRecord.critical,
        sourceMine = eventRecord.sourceMine,
        destMine = eventRecord.destMine,
        sourcePlayer = eventRecord.sourcePlayer,
        destPlayer = eventRecord.destPlayer,
        sourceHostilePlayer = eventRecord.sourceHostilePlayer,
        destHostilePlayer = eventRecord.destHostilePlayer,
        isCooldownCast = eventRecord.isCooldownCast,
    }
end

function CombatTracker:MergeActor(session, guid, name, flags)
    if not guid then
        return nil
    end

    session.actors[guid] = session.actors[guid] or buildActorStub(guid, name, flags)
    local actor = session.actors[guid]
    if name and not actor.name then
        actor.name = name
    end
    if flags then
        actor.isMine = actor.isMine or hasFlag(flags, AFFILIATION_MINE) or isMineGuid(guid)
        actor.isPlayer = actor.isPlayer or hasFlag(flags, TYPE_PLAYER) or ApiCompat.IsGuidPlayer(guid)
        actor.isHostile = actor.isHostile or hasFlag(flags, REACTION_HOSTILE)
    end
    return actor
end

function CombatTracker:TrackActorGuid(session, guid)
    if guid then
        session.trackedActorGuids[guid] = true
    end
end

function CombatTracker:UpdatePrimaryOpponent(session, eventRecord)
    local actor = nil
    if eventRecord.sourceMine and eventRecord.destGuid and not isMineGuid(eventRecord.destGuid) then
        actor = self:MergeActor(session, eventRecord.destGuid, eventRecord.destName, eventRecord.destFlags)
    elseif eventRecord.destMine and eventRecord.sourceGuid and not isMineGuid(eventRecord.sourceGuid) then
        actor = self:MergeActor(session, eventRecord.sourceGuid, eventRecord.sourceName, eventRecord.sourceFlags)
    end

    if actor and not actor.isMine then
        session.primaryOpponent = session.primaryOpponent or actor
        self:TrackActorGuid(session, actor.guid)
    end
end

function CombatTracker:NormalizeCombatLogEvent(...)
    local timestamp, subEvent, _, sourceGuid, sourceName, sourceFlags, _, destGuid, destName, destFlags = ...
    if not timestamp or not subEvent then
        return nil
    end

    local payload = { select(12, ...) }
    local eventRecord = {
        timestamp = timestamp,
        subEvent = subEvent,
        sourceGuid = sourceGuid,
        sourceName = sourceName,
        sourceFlags = sourceFlags or 0,
        destGuid = destGuid,
        destName = destName,
        destFlags = destFlags or 0,
        sourceMine = isMineGuid(sourceGuid) or hasFlag(sourceFlags or 0, AFFILIATION_MINE),
        destMine = isMineGuid(destGuid) or hasFlag(destFlags or 0, AFFILIATION_MINE),
        sourcePlayer = ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags or 0, TYPE_PLAYER),
        destPlayer = ApiCompat.IsGuidPlayer(destGuid) or hasFlag(destFlags or 0, TYPE_PLAYER),
        sourceHostilePlayer = (ApiCompat.IsGuidPlayer(sourceGuid) or hasFlag(sourceFlags or 0, TYPE_PLAYER)) and hasFlag(sourceFlags or 0, REACTION_HOSTILE),
        destHostilePlayer = (ApiCompat.IsGuidPlayer(destGuid) or hasFlag(destFlags or 0, TYPE_PLAYER)) and hasFlag(destFlags or 0, REACTION_HOSTILE),
        eventType = "other",
    }

    if subEvent == "SWING_DAMAGE" then
        eventRecord.eventType = "damage"
        eventRecord.spellId = 6603
        eventRecord.amount = payload[1]
        eventRecord.overkill = payload[2]
        eventRecord.absorbed = payload[5]
        eventRecord.critical = payload[6]
    elseif subEvent == "RANGE_DAMAGE" or subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_PERIODIC_DAMAGE" then
        eventRecord.eventType = "damage"
        eventRecord.spellId = payload[1]
        eventRecord.amount = payload[4]
        eventRecord.overkill = payload[5]
        eventRecord.absorbed = payload[8]
        eventRecord.critical = payload[9]
    elseif subEvent == "ENVIRONMENTAL_DAMAGE" then
        eventRecord.eventType = "damage"
        eventRecord.spellId = 0
        eventRecord.amount = payload[2]
        eventRecord.overkill = payload[3]
        eventRecord.absorbed = payload[6]
        eventRecord.critical = payload[7]
    elseif subEvent == "SPELL_HEAL" or subEvent == "SPELL_PERIODIC_HEAL" then
        eventRecord.eventType = "healing"
        eventRecord.spellId = payload[1]
        eventRecord.amount = payload[4]
        eventRecord.overhealing = payload[5]
        eventRecord.absorbed = payload[6]
        eventRecord.critical = payload[7]
    elseif subEvent == "SPELL_CAST_SUCCESS" or subEvent == "SPELL_CAST_START" or subEvent == "SPELL_CAST_FAILED" then
        eventRecord.eventType = "cast"
        eventRecord.spellId = payload[1]
        eventRecord.failedReason = payload[4]
    elseif string.find(subEvent, "AURA") then
        eventRecord.eventType = "aura"
        eventRecord.spellId = payload[1]
        eventRecord.auraId = payload[1]
        eventRecord.auraType = payload[4]
        eventRecord.stackCount = payload[5]
    elseif string.find(subEvent, "MISSED") then
        eventRecord.eventType = "miss"
        if subEvent == "SWING_MISSED" then
            eventRecord.spellId = 6603
            eventRecord.missType = payload[1]
            eventRecord.absorbed = payload[2]
        else
            eventRecord.spellId = payload[1]
            eventRecord.missType = payload[4]
            eventRecord.absorbed = payload[5]
        end
    elseif subEvent == "SPELL_INTERRUPT" then
        eventRecord.eventType = "interrupt"
        eventRecord.spellId = payload[1]
        eventRecord.extraSpellId = payload[4]
    elseif subEvent == "SPELL_DISPEL" or subEvent == "SPELL_STOLEN" then
        eventRecord.eventType = "dispel"
        eventRecord.spellId = payload[1]
        eventRecord.extraSpellId = payload[4]
    elseif subEvent == "UNIT_DIED" or subEvent == "UNIT_DESTROYED" or subEvent == "PARTY_KILL" then
        eventRecord.eventType = "death"
    end

    return eventRecord
end

function CombatTracker:ShouldTrackEvent(session, eventRecord)
    if not eventRecord then
        return false
    end
    if eventRecord.sourceMine or eventRecord.destMine then
        return true
    end
    if not session then
        return false
    end
    return (eventRecord.sourceGuid and session.trackedActorGuids[eventRecord.sourceGuid]) or (eventRecord.destGuid and session.trackedActorGuids[eventRecord.destGuid]) or false
end

function CombatTracker:StartSessionFromEvent(eventRecord, context, subcontext)
    if context == Constants.CONTEXT.ARENA or context == Constants.CONTEXT.BATTLEGROUND then
        self:CreateOrRefreshMatch(context, subcontext)
    end

    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService then
        damageMeterService:MarkSessionStart()
    end

    local session = self:CreateSession(context, subcontext, "cleu")
    session.startLogTimestamp = eventRecord.timestamp
    session.lastLogTimestamp = eventRecord.timestamp
    self:UpdatePrimaryOpponent(session, eventRecord)
    self:TrackActorGuid(session, ApiCompat.GetPlayerGUID())
    self:TrackActorGuid(session, eventRecord.sourceGuid)
    self:TrackActorGuid(session, eventRecord.destGuid)
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier and classifier.AccumulateEvidence then
        classifier:AccumulateEvidence(session, eventRecord)
    end
    return session
end

function CombatTracker:UpdateSpellStats(session, eventRecord)
    if not eventRecord.spellId then
        return
    end

    local aggregate = self:EnsureSpellAggregate(session, eventRecord.spellId)
    if not aggregate.firstUse then
        aggregate.firstUse = eventRecord.timestampOffset
    end
    aggregate.lastUse = eventRecord.timestampOffset

    if isSuccessfulCastEvent(eventRecord) then
        aggregate.castCount = aggregate.castCount + 1
        if aggregate.lastCastOffset and eventRecord.timestampOffset > aggregate.lastCastOffset then
            local gap = eventRecord.timestampOffset - aggregate.lastCastOffset
            aggregate.totalInterval = aggregate.totalInterval + gap
            aggregate.intervalCount = aggregate.intervalCount + 1
            aggregate.averageInterval = aggregate.totalInterval / aggregate.intervalCount
        end
        aggregate.lastCastOffset = eventRecord.timestampOffset

        if session.lastPlayerActionOffset and eventRecord.timestampOffset > session.lastPlayerActionOffset then
            local gap = eventRecord.timestampOffset - session.lastPlayerActionOffset
            if gap > 1.5 then
                session.idleTime = session.idleTime + gap
            end
        end
        session.lastPlayerActionOffset = eventRecord.timestampOffset
    elseif eventRecord.eventType == "damage" and eventRecord.sourceMine then
        aggregate.executeCount = aggregate.executeCount + 1
        aggregate.hitCount = aggregate.hitCount + 1
        aggregate.totalDamage = aggregate.totalDamage + (eventRecord.amount or 0)
        aggregate.overkill = aggregate.overkill + (eventRecord.overkill or 0)
        aggregate.absorbed = aggregate.absorbed + (eventRecord.absorbed or 0)
        aggregate.maxHit = math.max(aggregate.maxHit, eventRecord.amount or 0)
        aggregate.minHit = aggregate.minHit and math.min(aggregate.minHit, eventRecord.amount or 0) or (eventRecord.amount or 0)
        if eventRecord.critical then
            aggregate.critCount = aggregate.critCount + 1
            aggregate.maxCrit = math.max(aggregate.maxCrit, eventRecord.amount or 0)
            aggregate.minCrit = aggregate.minCrit and math.min(aggregate.minCrit, eventRecord.amount or 0) or (eventRecord.amount or 0)
        end
        session.lastPlayerActionOffset = eventRecord.timestampOffset
    elseif eventRecord.eventType == "healing" and eventRecord.sourceMine then
        aggregate.executeCount = aggregate.executeCount + 1
        aggregate.hitCount = aggregate.hitCount + 1
        aggregate.totalHealing = aggregate.totalHealing + (eventRecord.amount or 0)
        aggregate.overhealing = aggregate.overhealing + (eventRecord.overhealing or 0)
        aggregate.absorbed = aggregate.absorbed + (eventRecord.absorbed or 0)
        if eventRecord.critical then
            aggregate.critCount = aggregate.critCount + 1
        end
        session.lastPlayerActionOffset = eventRecord.timestampOffset
    elseif eventRecord.eventType == "miss" and eventRecord.sourceMine then
        aggregate.missCount = aggregate.missCount + 1
    end
end

function CombatTracker:OpenAuraWindow(session, guid, auraId, timestampOffset, isProc, stackCount)
    session.activeAuraWindows[guid] = session.activeAuraWindows[guid] or {}
    local current = session.activeAuraWindows[guid][auraId]
    if current then
        return current
    end

    local aggregate = self:EnsureAuraAggregate(session, auraId)
    aggregate.applications = aggregate.applications + 1
    aggregate.procCount = aggregate.procCount + (isProc and 1 or 0)
    aggregate.isProc = aggregate.isProc or isProc
    aggregate.stacksObserved = aggregate.stacksObserved + (stackCount or 0)
    aggregate.maxStacksObserved = math.max(aggregate.maxStacksObserved, stackCount or 0)

    current = {
        startedAt = timestampOffset,
        stackCount = stackCount or 0,
    }
    session.activeAuraWindows[guid][auraId] = current
    return current
end

function CombatTracker:CloseAuraWindow(session, guid, auraId, timestampOffset)
    local guidWindows = session.activeAuraWindows[guid]
    if not guidWindows or not guidWindows[auraId] then
        return
    end

    local activeWindow = guidWindows[auraId]
    local aggregate = self:EnsureAuraAggregate(session, auraId)
    aggregate.totalUptime = aggregate.totalUptime + math.max(0, timestampOffset - (activeWindow.startedAt or timestampOffset))
    guidWindows[auraId] = nil
end

function CombatTracker:UpdateAuraStats(session, eventRecord)
    if not eventRecord.auraId then
        return
    end

    local guid = eventRecord.destGuid or eventRecord.sourceGuid
    if not guid then
        return
    end

    local aggregate = self:EnsureAuraAggregate(session, eventRecord.auraId)
    aggregate.maxStacksObserved = math.max(aggregate.maxStacksObserved, eventRecord.stackCount or 0)

    if eventRecord.subEvent == "SPELL_AURA_APPLIED" or eventRecord.subEvent == "SPELL_AURA_APPLIED_DOSE" then
        local isProc = eventRecord.destMine and eventRecord.auraType == "BUFF"
        self:OpenAuraWindow(session, guid, eventRecord.auraId, eventRecord.timestampOffset, isProc, eventRecord.stackCount)
    elseif eventRecord.subEvent == "SPELL_AURA_REFRESH" then
        aggregate.refreshCount = aggregate.refreshCount + 1
    elseif eventRecord.subEvent == "SPELL_AURA_REMOVED" or eventRecord.subEvent == "SPELL_AURA_REMOVED_DOSE" or eventRecord.subEvent == "SPELL_AURA_BROKEN" or eventRecord.subEvent == "SPELL_AURA_BROKEN_SPELL" then
        self:CloseAuraWindow(session, guid, eventRecord.auraId, eventRecord.timestampOffset)
    end
end

function CombatTracker:UpdateCooldownStats(session, eventRecord)
    if not isSuccessfulCastEvent(eventRecord) or not eventRecord.spellId then
        return
    end

    local category = self:GetSpellCategory(eventRecord.spellId)
    if not category then
        return
    end

    eventRecord.isCooldownCast = true
    local aggregate = self:EnsureCooldownAggregate(session, eventRecord.spellId, category)
    aggregate.useCount = aggregate.useCount + 1
    if aggregate.lastUsedAt then
        local spacing = eventRecord.timestampOffset - aggregate.lastUsedAt
        if spacing > 0 then
            aggregate.totalSpacing = aggregate.totalSpacing + spacing
            aggregate.spacingCount = aggregate.spacingCount + 1
            aggregate.averageSpacing = aggregate.totalSpacing / aggregate.spacingCount
        end
    else
        aggregate.firstUsedAt = eventRecord.timestampOffset
    end
    aggregate.lastUsedAt = eventRecord.timestampOffset

    if category == Constants.SPELL_CATEGORY.DEFENSIVE then
        session.survival.defensivesUsed = session.survival.defensivesUsed + 1
    elseif category == Constants.SPELL_CATEGORY.MOBILITY then
        session.utility.mobilityUses = session.utility.mobilityUses + 1
    end
end

function CombatTracker:UpdateUtilityStats(session, eventRecord)
    if eventRecord.eventType == "interrupt" and eventRecord.sourceMine then
        session.utility.interrupts = session.utility.interrupts + 1
        session.utility.successfulInterrupts = session.utility.successfulInterrupts + 1
    elseif eventRecord.eventType == "dispel" and eventRecord.sourceMine then
        session.utility.dispels = session.utility.dispels + 1
    elseif eventRecord.eventType == "cast" and eventRecord.subEvent == "SPELL_CAST_FAILED" and eventRecord.sourceMine then
        local category = self:GetSpellCategory(eventRecord.spellId)
        if category == Constants.SPELL_CATEGORY.UTILITY then
            session.utility.failedInterrupts = session.utility.failedInterrupts + 1
        end
    elseif eventRecord.eventType == "aura" and eventRecord.sourceMine and eventRecord.destHostilePlayer then
        local category = self:GetSpellCategory(eventRecord.auraId or eventRecord.spellId)
        if category == Constants.SPELL_CATEGORY.CROWD_CONTROL and eventRecord.subEvent == "SPELL_AURA_APPLIED" then
            session.utility.ccApplied = session.utility.ccApplied + 1
        end
    end
end

function CombatTracker:UpdateSurvivalStats(session, eventRecord)
    if eventRecord.eventType == "damage" and eventRecord.destMine then
        session.localTotals.damageTaken = (session.localTotals.damageTaken or 0) + (eventRecord.amount or 0)
        session.localTotals.absorbed = (session.localTotals.absorbed or 0) + (eventRecord.absorbed or 0)
        session.totals.damageTaken = session.localTotals.damageTaken
        session.totals.absorbed = session.localTotals.absorbed
        session.survival.totalAbsorbed = session.localTotals.absorbed
        session.survival.largestIncomingSpike = math.max(session.survival.largestIncomingSpike, eventRecord.amount or 0)
    elseif eventRecord.eventType == "healing" and eventRecord.sourceMine then
        session.localTotals.healingDone = (session.localTotals.healingDone or 0) + (eventRecord.amount or 0)
        session.localTotals.overhealing = (session.localTotals.overhealing or 0) + (eventRecord.overhealing or 0)
        session.totals.healingDone = session.localTotals.healingDone
        session.totals.overhealing = session.localTotals.overhealing
        if eventRecord.destMine then
            session.survival.selfHealing = session.survival.selfHealing + (eventRecord.amount or 0)
        end
    elseif eventRecord.eventType == "damage" and eventRecord.sourceMine then
        session.localTotals.damageDone = (session.localTotals.damageDone or 0) + (eventRecord.amount or 0)
        session.localTotals.overkill = (session.localTotals.overkill or 0) + (eventRecord.overkill or 0)
        session.totals.damageDone = session.localTotals.damageDone
        session.totals.overkill = session.localTotals.overkill
    elseif eventRecord.eventType == "death" then
        if eventRecord.destMine then
            session.survival.deaths = session.survival.deaths + 1
        elseif session.primaryOpponent and eventRecord.destGuid == session.primaryOpponent.guid then
            session.primaryOpponent.isDead = true
        end
    end
end

function CombatTracker:UpdateAuraWindowContribution(session, eventRecord)
    if eventRecord.eventType ~= "damage" and eventRecord.eventType ~= "healing" and eventRecord.eventType ~= "cast" then
        return
    end

    for _, auraMap in pairs(session.activeAuraWindows or {}) do
        for auraId in pairs(auraMap) do
            local aggregate = self:EnsureAuraAggregate(session, auraId)
            if eventRecord.sourceMine and eventRecord.eventType == "damage" then
                aggregate.damageDuringWindows = aggregate.damageDuringWindows + (eventRecord.amount or 0)
            elseif eventRecord.sourceMine and eventRecord.eventType == "healing" then
                aggregate.healingDuringWindows = aggregate.healingDuringWindows + (eventRecord.amount or 0)
            elseif eventRecord.sourceMine and eventRecord.eventType == "cast" then
                aggregate.castsDuringWindows = aggregate.castsDuringWindows + 1
            elseif eventRecord.destMine and eventRecord.eventType == "damage" then
                aggregate.damageTakenDuringWindows = aggregate.damageTakenDuringWindows + (eventRecord.amount or 0)
            end
        end
    end

    for _, cooldown in pairs(session.cooldowns or {}) do
        if cooldown.lastUsedAt and eventRecord.timestampOffset >= cooldown.lastUsedAt and eventRecord.timestampOffset <= (cooldown.lastUsedAt + 8) then
            if eventRecord.sourceMine and eventRecord.eventType == "damage" then
                cooldown.damageDuringWindows = cooldown.damageDuringWindows + (eventRecord.amount or 0)
            elseif eventRecord.sourceMine and eventRecord.eventType == "healing" then
                cooldown.healingDuringWindows = cooldown.healingDuringWindows + (eventRecord.amount or 0)
            elseif eventRecord.sourceMine and eventRecord.eventType == "cast" then
                cooldown.castsDuringWindows = cooldown.castsDuringWindows + 1
            elseif eventRecord.destMine and eventRecord.eventType == "damage" then
                cooldown.damageTakenDuringWindows = cooldown.damageTakenDuringWindows + (eventRecord.amount or 0)
            end
        end
    end
end

function CombatTracker:HandleNormalizedEvent(eventRecord)
    local classifier = ns.Addon:GetModule("SessionClassifier")
    local session = self:GetCurrentSession()
    local shouldStart, context, subcontext = classifier:ShouldStartNewSession(session, eventRecord)
    if shouldStart or session or eventRecord.sourceMine or eventRecord.destMine then
        ns.Addon:Trace("cleu.route", {
            context = context or "nil",
            destMine = eventRecord.destMine and true or false,
            session = session and session.id or "none",
            shouldStart = shouldStart and true or false,
            sourceMine = eventRecord.sourceMine and true or false,
            subEvent = eventRecord.subEvent or "unknown",
            subcontext = subcontext or "nil",
        })
    end

    if not session and not shouldStart then
        return
    end

    if shouldStart then
        if session and session.state == "active" then
            self:FinalizeSession(nil, "context_transition")
        end
        session = self:StartSessionFromEvent(eventRecord, context, subcontext)
    end

    if not self:ShouldTrackEvent(session, eventRecord) then
        ns.Addon:Trace("cleu.untracked", {
            context = session and session.context or "none",
            subEvent = eventRecord.subEvent or "unknown",
        })
        return
    end

    self:MergeActor(session, eventRecord.sourceGuid, eventRecord.sourceName, eventRecord.sourceFlags)
    self:MergeActor(session, eventRecord.destGuid, eventRecord.destName, eventRecord.destFlags)
    self:TrackActorGuid(session, eventRecord.sourceGuid)
    self:TrackActorGuid(session, eventRecord.destGuid)
    self:UpdatePrimaryOpponent(session, eventRecord)
    if classifier and classifier.AccumulateEvidence then
        classifier:AccumulateEvidence(session, eventRecord)
    end
    self:RefreshSessionIdentity(session, nil, "cleu")

    if not session.startLogTimestamp then
        session.startLogTimestamp = eventRecord.timestamp
    end
    session.lastLogTimestamp = eventRecord.timestamp
    session.lastEventOffset = math.max(0, (eventRecord.timestamp or 0) - (session.startLogTimestamp or eventRecord.timestamp or 0))
    eventRecord.timestampOffset = session.lastEventOffset

    session.duration = session.lastEventOffset
    session.lastRelevantAt = Helpers.Now()
    self:InvalidatePendingFinalize(session)

    self:UpdateSpellStats(session, eventRecord)
    self:UpdateAuraStats(session, eventRecord)
    self:UpdateCooldownStats(session, eventRecord)
    self:UpdateUtilityStats(session, eventRecord)
    self:UpdateSurvivalStats(session, eventRecord)
    self:UpdateAuraWindowContribution(session, eventRecord)
    self:AppendRawEvent(session, eventRecord)
end

function CombatTracker:CloseOpenAuras(session)
    for guid, auraMap in pairs(session.activeAuraWindows or {}) do
        for auraId in pairs(auraMap) do
            self:CloseAuraWindow(session, guid, auraId, session.duration or 0)
        end
    end
end

function CombatTracker:DeriveResult(session, explicitResult, reason)
    if explicitResult then
        return explicitResult
    end
    if session.result and session.result ~= Constants.SESSION_RESULT.UNKNOWN then
        return session.result
    end
    if session.context == Constants.CONTEXT.TRAINING_DUMMY then
        return Constants.SESSION_RESULT.UNKNOWN
    end
    if session.survival.deaths and session.survival.deaths > 0 then
        return Constants.SESSION_RESULT.LOST
    end
    if session.primaryOpponent and session.primaryOpponent.isDead then
        return Constants.SESSION_RESULT.WON
    end
    if reason == "timeout" then
        return Constants.SESSION_RESULT.DISENGAGED
    end
    return Constants.SESSION_RESULT.UNKNOWN
end

function CombatTracker:EstimateUnusedDefensives(session)
    if session.survival.defensivesUsed > 0 then
        return 0
    end
    if session.result == Constants.SESSION_RESULT.LOST or session.survival.deaths > 0 then
        return 1
    end
    return 0
end

function CombatTracker:ResolveFinalDamageSource(session)
    local localDamage = session.localTotals and session.localTotals.damageDone or 0
    local importedDamage = session.importedTotals and session.importedTotals.damageDone or 0
    local hint = session.import and session.import.finalDamageSourceHint or nil

    if localDamage > 0 then
        return "local"
    end
    if hint then
        return hint
    end
    if importedDamage > 0 then
        return "damage_meter"
    end
    if (session.damageBreakdownSource or "") == "estimated_from_casts" or (session.totals.damageDone or 0) > 0 then
        return "estimated"
    end
    return "damage_meter"
end

function CombatTracker:ResolveAnalysisConfidence(session)
    local hasRawTimeline = #(session.rawEvents or {}) > 0
    local identityConfidence = session.identity and session.identity.confidence or 0
    local finalDamageSource = session.finalDamageSource or "damage_meter"

    if not hasRawTimeline then
        return "limited"
    end
    if identityConfidence >= 90 and finalDamageSource == "local" then
        return "high"
    end
    return "medium"
end

function CombatTracker:FinalizeSession(explicitResult, reason)
    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        return nil
    end

    self:CloseOpenAuras(session)
    session.endedAt = ApiCompat.GetServerTime()
    session.damageMeterImportAttempts = session.damageMeterImportAttempts or 0
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and not (InCombatLockdown and InCombatLockdown()) then
        local okImport, importedOrError = xpcall(function()
            return damageMeterService:ImportSession(session)
        end, debugstack)
        if not okImport then
            session.captureQuality = session.captureQuality or {}
            session.captureQuality.damageMeter = Constants.CAPTURE_QUALITY.DEGRADED
            ns.Addon:Warn("Damage Meter import failed; storing limited session data.")
            ns.Addon:Debug("%s", importedOrError)
        elseif not importedOrError then
            session.captureQuality = session.captureQuality or {}
            session.captureQuality.damageMeter = Constants.CAPTURE_QUALITY.DEGRADED
        end
    end

    local localDamageDone = session.localTotals and session.localTotals.damageDone or 0
    local shouldRetryImport =
        not self.playerInCombat
        and damageMeterService
        and (session.totals.damageDone or 0) <= 0
        and session.damageMeterImportAttempts < 3
        and (
            localDamageDone > 0
            or getRecordedCastCount(session) > 0
            or session.primaryOpponent ~= nil
            or (session.duration or 0) >= 1
        )

    if shouldRetryImport then
        session.damageMeterImportAttempts = session.damageMeterImportAttempts + 1
        ns.Addon:Trace("damage_meter.import.retry", {
            attempt = session.damageMeterImportAttempts,
            casts = getRecordedCastCount(session),
            localDamage = localDamageDone,
            reason = reason or "unknown",
        })
        self:ScheduleFinalize(session, 0.75, "damage_meter_retry")
        return nil
    end

    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier and classifier.SyncSessionIdentityFromOpponent and session.primaryOpponent then
        classifier:SyncSessionIdentityFromOpponent(session, session.primaryOpponent, "finalize")
    end

    session.result = self:DeriveResult(session, explicitResult, reason)
    session.survival.unusedDefensives = self:EstimateUnusedDefensives(session)

    local okWindows, errWindows = xpcall(function()
        ns.Metrics.DeriveWindows(session)
        ns.Metrics.ComputeDerivedMetrics(session)
    end, debugstack)
    if not okWindows then
        session.captureQuality.metrics = Constants.CAPTURE_QUALITY.DEGRADED
        session.metrics = session.metrics or {}
        ns.Addon:Warn("Metrics derivation failed; storing raw session only.")
        ns.Addon:Debug("%s", errWindows)
    end

    local okSuggestions, errSuggestions = xpcall(function()
        session.suggestions = ns.Addon:GetModule("SuggestionEngine"):BuildSessionSuggestions(session)
    end, debugstack)
    if not okSuggestions then
        session.suggestions = {}
        ns.Addon:Warn("Suggestion generation failed for a session.")
        ns.Addon:Debug("%s", errSuggestions)
    end

    session.finalDamageSource = self:ResolveFinalDamageSource(session)
    session.analysisConfidence = self:ResolveAnalysisConfidence(session)
    session.state = "finalized"

    ns.Addon:Trace("session.finalized", {
        context = session.context or "unknown",
        identityConfidence = session.identity and session.identity.confidence or 0,
        importConfidence = session.import and session.import.confidence or 0,
        localDamage = session.localTotals and session.localTotals.damageDone or 0,
        importedDamage = session.importedTotals and session.importedTotals.damageDone or 0,
        finalDamage = session.totals and session.totals.damageDone or 0,
        finalDamageSource = session.finalDamageSource or "unknown",
        analysisConfidence = session.analysisConfidence or "unknown",
    })

    local okPersist, errPersist = xpcall(function()
        ns.Addon:GetModule("CombatStore"):PersistSession(session)
    end, debugstack)
    if not okPersist then
        ns.Addon:Warn("Session persistence failed.")
        ns.Addon:Debug("%s", errPersist)
        return nil
    end

    ns.Addon:Debug(
        "Finalized session %s reason=%s raw=%d dmg=%d stored_sessions=%d",
        session.id,
        tostring(reason),
        #(session.rawEvents or {}),
        session.totals.damageDone or 0,
        ns.Addon:GetModule("CombatStore"):GetStorageStats().sessions or 0
    )
    self:SetCurrentSession(nil)

    if ns.Addon:GetSetting("showSummaryAfterCombat") then
        ns.Addon:ShowSummary(session.id)
    end

    return session
end

function CombatTracker:HandleCombatLogEvent()
    local isRestricted = ApiCompat.IsCombatLogRestricted()
    local eventRecord = self:NormalizeCombatLogEvent(ApiCompat.GetCombatLogEventInfo())
    if not eventRecord then
        return
    end

    local currentSession = self:GetCurrentSession()
    if currentSession or eventRecord.sourceMine or eventRecord.destMine then
        ns.Addon:Trace("cleu.begin", {
            destMine = eventRecord.destMine and true or false,
            restricted = isRestricted and true or false,
            session = currentSession and currentSession.id or "none",
            sourceMine = eventRecord.sourceMine and true or false,
            spellId = eventRecord.spellId or 0,
            subEvent = eventRecord.subEvent or "unknown",
        })
    end

    self:HandleNormalizedEvent(eventRecord)

    if isRestricted then
        local session = self:GetCurrentSession()
        if session then
            session.captureQuality.rawEvents = Constants.CAPTURE_QUALITY.RESTRICTED
        end
    end

    currentSession = self:GetCurrentSession()
    if currentSession or eventRecord.sourceMine or eventRecord.destMine then
        ns.Addon:Trace("cleu.end", {
            context = currentSession and currentSession.context or "none",
            session = currentSession and currentSession.id or "none",
            subEvent = eventRecord.subEvent or "unknown",
        })
    end
end

function CombatTracker:HandleUnitSpellcastSucceeded(unitTarget, _, spellId)
    if unitTarget ~= "player" and unitTarget ~= "pet" then
        return
    end

    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" or not spellId then
        return
    end

    local eventRecord = {
        eventType = "cast",
        subEvent = "UNIT_SPELLCAST_SUCCEEDED",
        spellId = spellId,
        sourceMine = true,
        destMine = false,
        timestampOffset = getSessionRelativeOffset(session),
    }

    session.lastRelevantAt = Helpers.Now()
    session.lastEventOffset = eventRecord.timestampOffset
    session.duration = math.max(session.duration or 0, eventRecord.timestampOffset)

    self:UpdateSpellStats(session, eventRecord)
    self:UpdateCooldownStats(session, eventRecord)
    self:UpdateAuraWindowContribution(session, eventRecord)
end

function CombatTracker:HandleUnitAura(unitTarget, updateInfo)
    local session = self:GetCurrentSession()
    if not session or not ApiCompat.UnitExists(unitTarget) then
        return
    end
    if not Constants.TRACKED_UNITS[unitTarget] and not string.find(unitTarget, "^arena") then
        return
    end

    local snapshotService = ns.Addon:GetModule("SnapshotService")
    local actor = snapshotService:UpdateSessionActor(session, unitTarget, "unit_aura")
    if not actor or not actor.guid then
        return
    end

    self:RefreshSessionIdentity(session, unitTarget, "unit_aura")

    session.visibleAuras[actor.guid] = session.visibleAuras[actor.guid] or {}
    local auraState = session.visibleAuras[actor.guid]
    local timestampOffset = getSessionRelativeOffset(session)

    local function removeAuraState(auraInstanceId)
        local previous = auraState[auraInstanceId]
        if previous and previous.spellId then
            self:CloseAuraWindow(session, actor.guid, previous.spellId, timestampOffset)
        end
        auraState[auraInstanceId] = nil
    end

    if updateInfo and updateInfo.removedAuraInstanceIDs then
        for _, auraInstanceId in ipairs(updateInfo.removedAuraInstanceIDs) do
            removeAuraState(auraInstanceId)
        end
    end

    local function applyAuraData(auraData)
        if not auraData or not auraData.auraInstanceID then
            return
        end
        local previous = auraState[auraData.auraInstanceID]
        local procLike = isProcCandidate(unitTarget, auraData)

        if previous and previous.spellId and previous.spellId ~= auraData.spellId then
            self:CloseAuraWindow(session, actor.guid, previous.spellId, timestampOffset)
            previous = nil
        end

        if auraData.spellId and not previous then
            self:OpenAuraWindow(session, actor.guid, auraData.spellId, timestampOffset, procLike, auraData.applications)
        elseif auraData.spellId and previous and (previous.applications or 0) ~= (auraData.applications or 0) then
            local aggregate = self:EnsureAuraAggregate(session, auraData.spellId)
            aggregate.refreshCount = aggregate.refreshCount + 1
        end

        auraState[auraData.auraInstanceID] = {
            auraInstanceId = auraData.auraInstanceID,
            spellId = auraData.spellId,
            applications = auraData.applications,
            isHelpful = auraData.isHelpful,
            sourceUnit = auraData.sourceUnit,
            isProc = procLike,
        }
        if auraData.spellId then
            local aggregate = self:EnsureAuraAggregate(session, auraData.spellId)
            aggregate.maxStacksObserved = math.max(aggregate.maxStacksObserved, auraData.applications or 0)
            aggregate.isProc = aggregate.isProc or procLike
        end
    end

    if updateInfo and updateInfo.addedAuras then
        for _, auraData in ipairs(updateInfo.addedAuras) do
            applyAuraData(auraData)
        end
    end

    if updateInfo and updateInfo.updatedAuraInstanceIDs then
        for _, auraInstanceId in ipairs(updateInfo.updatedAuraInstanceIDs) do
            applyAuraData(ApiCompat.GetUnitAuraDataByAuraInstanceID(unitTarget, auraInstanceId))
        end
    end

    if updateInfo and updateInfo.isFullUpdate then
        local seenAuraInstanceIds = {}
        local index = 1
        while true do
            local helpful = ApiCompat.GetUnitAuraDataByIndex(unitTarget, index, "HELPFUL")
            local harmful = ApiCompat.GetUnitAuraDataByIndex(unitTarget, index, "HARMFUL")
            if not helpful and not harmful then
                break
            end
            if helpful then
                if helpful.auraInstanceID then
                    seenAuraInstanceIds[helpful.auraInstanceID] = true
                end
                applyAuraData(helpful)
            end
            if harmful then
                if harmful.auraInstanceID then
                    seenAuraInstanceIds[harmful.auraInstanceID] = true
                end
                applyAuraData(harmful)
            end
            index = index + 1
        end

        local staleAuraInstanceIds = {}
        for auraInstanceId in pairs(auraState) do
            if not seenAuraInstanceIds[auraInstanceId] then
                staleAuraInstanceIds[#staleAuraInstanceIds + 1] = auraInstanceId
            end
        end
        for _, auraInstanceId in ipairs(staleAuraInstanceIds) do
            removeAuraState(auraInstanceId)
        end
    end
end

function CombatTracker:HandlePlayerRegenDisabled()
    self.playerInCombat = true
    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        local classifier = ns.Addon:GetModule("SessionClassifier")
        local context, subcontext, unitToken = nil, nil, nil
        if classifier and classifier.ResolveContextFromState then
            context, subcontext, unitToken = classifier:ResolveContextFromState()
        end
        if context then
            if context == Constants.CONTEXT.ARENA or context == Constants.CONTEXT.BATTLEGROUND then
                self:CreateOrRefreshMatch(context, subcontext)
            end

            local damageMeterService = ns.Addon:GetModule("DamageMeterService")
            if damageMeterService then
                damageMeterService:MarkSessionStart()
            end

            session = self:CreateSession(context, subcontext, "state")

            local snapshotService = ns.Addon:GetModule("SnapshotService")
            if snapshotService then
                if unitToken then
                    local actor = snapshotService:UpdateSessionActor(session, unitToken, "combat_start")
                    if actor then
                        session.primaryOpponent = actor
                    end
                end
                if ApiCompat.UnitExists("target") then
                    snapshotService:UpdateSessionActor(session, "target", "combat_start")
                end
                if ApiCompat.UnitExists("focus") then
                    snapshotService:UpdateSessionActor(session, "focus", "combat_start")
                end
            end

            self:RefreshSessionIdentity(session, unitToken, "combat_start")
        end
    end

    if session then
        self:InvalidatePendingFinalize(session)
    end
end

function CombatTracker:HandlePlayerRegenEnabled()
    self.playerInCombat = false
    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if snapshotService then
        snapshotService:TryRefreshDeferredSnapshot("post_combat")
    end

    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        return
    end

    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and damageMeterService.CaptureCurrentSessionSnapshot then
        damageMeterService:CaptureCurrentSessionSnapshot(session)
    end

    local delay = 1.5
    if session.context == Constants.CONTEXT.WORLD_PVP then
        delay = 5
    elseif session.context == Constants.CONTEXT.BATTLEGROUND or session.context == Constants.CONTEXT.ARENA then
        delay = 2
    end

    self:ScheduleFinalize(session, delay, "regen_end")
end

function CombatTracker:HandleDamageMeterCombatSessionUpdated(damageMeterType, sessionId)
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and damageMeterService.HandleCombatSessionUpdated then
        damageMeterService:HandleCombatSessionUpdated(damageMeterType, sessionId)
    end

    local session = self:GetCurrentSession()
    if session and session.state == "active" and not self.playerInCombat then
        if damageMeterType == Enum.DamageMeterType.DamageDone
            or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken
            or damageMeterType == Enum.DamageMeterType.HealingDone
        then
            self:ScheduleFinalize(session, 0.2, "damage_meter_event")
        end
    end
end

function CombatTracker:HandleDamageMeterCurrentSessionUpdated()
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and damageMeterService.HandleCurrentSessionUpdated then
        damageMeterService:HandleCurrentSessionUpdated()
    end

    local session = self:GetCurrentSession()
    if session and session.state == "active" and not self.playerInCombat then
        if damageMeterService and damageMeterService.CaptureCurrentSessionSnapshot then
            damageMeterService:CaptureCurrentSessionSnapshot(session)
        end
        self:ScheduleFinalize(session, 0.35, "damage_meter_current")
    end
end

function CombatTracker:HandleDamageMeterReset()
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and damageMeterService.HandleReset then
        damageMeterService:HandleReset()
    end
end

function CombatTracker:HandlePlayerSpecializationChanged(unit)
    if unit == "player" then
        ns.Addon:GetModule("SnapshotService"):TryRefreshDeferredSnapshot("spec_changed")
    end
end

function CombatTracker:HandlePlayerPvpTalentUpdate()
    ns.Addon:GetModule("SnapshotService"):TryRefreshDeferredSnapshot("pvp_talent_update")
end

function CombatTracker:HandlePlayerEnteringWorld()
    ns.Addon:TryRegisterSlashCommands()
    ns.Addon:GetModule("SessionClassifier"):RefreshZone()
end

function CombatTracker:HandleZoneChanged()
    ns.Addon:GetModule("SessionClassifier"):RefreshZone()
end

function CombatTracker:HandleTraitConfigListUpdated()
    ns.Addon:GetModule("SnapshotService"):HandleTraitConfigListUpdated()
end

function CombatTracker:HandlePlayerJoinedPvpMatch()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    local context = ApiCompat.IsMatchConsideredArena() and Constants.CONTEXT.ARENA or Constants.CONTEXT.BATTLEGROUND
    local subcontext = context == Constants.CONTEXT.ARENA and classifier:ResolveArenaSubcontext() or classifier:ResolveBattlegroundSubcontext()
    self:CreateOrRefreshMatch(context, subcontext)
end

function CombatTracker:HandlePvpMatchActive()
    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.state = "active"
        matchRecord.activatedAt = ApiCompat.GetServerTime()
    end
end

function CombatTracker:HandlePvpMatchComplete(winner, duration)
    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.state = "complete"
        matchRecord.completedAt = ApiCompat.GetServerTime()
        matchRecord.result = Constants.MATCH_RESULT.UNKNOWN
        matchRecord.metadata = matchRecord.metadata or {}
        matchRecord.metadata.winner = winner
        matchRecord.metadata.duration = duration
    end

    local session = self:GetCurrentSession()
    if session then
        session.result = Constants.SESSION_RESULT.UNKNOWN
    end
end

function CombatTracker:HandlePvpMatchInactive()
    local session = self:GetCurrentSession()
    if session then
        self:FinalizeSession(session.result ~= Constants.SESSION_RESULT.UNKNOWN and session.result or nil, "match_inactive")
    end
    self:SetCurrentMatch(nil)
end

function CombatTracker:HandlePvpMatchStateChanged()
    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.metadata = matchRecord.metadata or {}
        matchRecord.metadata.matchState = ApiCompat.GetActiveMatchState()
    end
end

function CombatTracker:HandleArenaPrepOpponentSpecializations()
    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        ns.Addon:GetModule("SnapshotService"):CaptureArenaPrep(matchRecord)
    end
end

function CombatTracker:HandleArenaOpponentUpdate(unitToken, updateReason)
    local session = self:GetCurrentSession()
    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if session then
        snapshotService:UpdateSessionActor(session, unitToken, "arena_opponent")
        self:AddTimelineMarker(session, "arena_opponent_update", { unitToken = unitToken, reason = updateReason })
    end
end

function CombatTracker:HandleDuelRequested(playerName)
    ns.Addon:GetModule("SessionClassifier"):SetPendingDuel(playerName, false)
    local session = self:GetCurrentSession()
    if session then
        self:RefreshSessionIdentity(session, nil, "duel_requested")
    end
end

function CombatTracker:HandleDuelToTheDeathRequested(playerName)
    ns.Addon:GetModule("SessionClassifier"):SetPendingDuel(playerName, true)
    local session = self:GetCurrentSession()
    if session then
        self:RefreshSessionIdentity(session, nil, "duel_requested")
    end
end

function CombatTracker:HandleDuelInbounds()
    local session = self:GetCurrentSession()
    if session then
        self:AddTimelineMarker(session, "duel_inbounds", {})
    end
end

function CombatTracker:HandleDuelOutOfBounds()
    local session = self:GetCurrentSession()
    if session then
        self:AddTimelineMarker(session, "duel_outofbounds", {})
    end
end

function CombatTracker:HandleDuelFinished()
    local session = self:GetCurrentSession()
    if session and session.context == Constants.CONTEXT.DUEL then
        self:FinalizeSession(nil, "duel_finished")
    end
    ns.Addon:GetModule("SessionClassifier"):ClearPendingDuel()
end

function CombatTracker:OnUpdate()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier and classifier.ExpirePendingDuel then
        classifier:ExpirePendingDuel()
    end

    local session = self:GetCurrentSession()
    if session and session.state == "active" then
        local now = Helpers.Now()
        local timeout = Constants.WORLD_PVP_IDLE_TIMEOUT
        if session.context == Constants.CONTEXT.DUEL then
            timeout = Constants.DUEL_IDLE_TIMEOUT
        elseif session.context == Constants.CONTEXT.TRAINING_DUMMY then
            timeout = Constants.TRAINING_DUMMY_IDLE_TIMEOUT
        elseif session.context == Constants.CONTEXT.GENERAL then
            timeout = Constants.GENERAL_IDLE_TIMEOUT
        end

        if session.pendingFinalizeAt and not self.playerInCombat and now >= session.pendingFinalizeAt then
            self:FinalizeSession(nil, "regen_end")
            return
        end

        -- Training dummy sessions often need the post-combat Damage Meter snapshot
        -- to resolve output on Midnight-safe mode, so do not finalize them while
        -- the player is still in combat.
        local canTimeoutWhileInCombat = false
        if session.lastRelevantAt and (not self.playerInCombat or canTimeoutWhileInCombat) and (now - session.lastRelevantAt) >= timeout then
            self:FinalizeSession(nil, "timeout")
        end
    end

    if ns.Addon.runtime.summaryOpenAt and Helpers.Now() >= ns.Addon.runtime.summaryOpenAt then
        ns.Addon.runtime.summaryOpenAt = nil
    end
end

ns.Addon:RegisterModule("CombatTracker", CombatTracker)
