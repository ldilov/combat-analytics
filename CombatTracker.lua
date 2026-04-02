local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local CombatTracker = {
    playerInCombat = false,
}

local AFFILIATION_MINE = Constants.CLEU_FLAGS.AFFILIATION_MINE
local TYPE_PLAYER      = Constants.CLEU_FLAGS.TYPE_PLAYER
local REACTION_HOSTILE = Constants.CLEU_FLAGS.REACTION_HOSTILE

-- Default delay (seconds) after PLAYER_REGEN_ENABLED before finalizing a
-- session.  Gives the C_DamageMeter backend time to settle and push its final
-- totals so the import pipeline captures complete data.
local DM_STABILIZATION_DELAY = 1.5

-- Maximum age (seconds) for a session that survived a /reload in "active"
-- state.  Sessions older than this are considered stale and discarded.
local STALE_SESSION_MAX_AGE = 60

local function hasFlag(value, flag)
    return flag ~= 0 and value ~= nil and bit.band(value, flag) > 0
end

-- Midnight arena guard: auraData fields (spellId, auraInstanceID) for arena
-- opponent units are "secret" values that throw "table index is secret" when
-- used as table keys.  This helper attempts the index and returns the original
-- value on success, or nil if the value is secret/unusable as a key.
local function safeMakeKey(val)
    if val == nil then return nil end
    local tmp = {}
    local ok = pcall(function() tmp[val] = true end)
    return ok and val or nil
end

local function isMineGuid(guid)
    if not guid then
        return false
    end
    return guid == ApiCompat.GetPlayerGUID() or ApiCompat.IsGuidPet(guid)
end

local function shouldUseAsPrimaryOpponent(actor, currentOpponent)
    if not actor or not actor.guid or isMineGuid(actor.guid) or ApiCompat.IsGuidPet(actor.guid) then
        return false
    end
    if not currentOpponent or not currentOpponent.guid then
        return true
    end
    if ApiCompat.IsGuidPet(currentOpponent.guid) then
        return true
    end

    local actorToken = actor.unitToken or ""
    local currentToken = currentOpponent.unitToken or ""
    local actorIsArena = actorToken:match("^arena%d$") ~= nil
    local currentIsArena = currentToken:match("^arena%d$") ~= nil
    if actorIsArena ~= currentIsArena then
        return actorIsArena
    end

    if actorToken == "target" and currentToken ~= "target" then
        return true
    end

    return false
end

local function createSpellAggregate(spellId)
    return {
        spellId = spellId,
        name = nil,
        iconID = nil,
        schoolMask = nil,
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
        C_Timer.After(delaySeconds, function()
            -- Wrap in xpcall so timer callbacks never propagate errors to
            -- WoW's top-level handler.  Unhandled errors in C_Timer callbacks
            -- trigger the ADDON_ACTION_BLOCKED modal dialog even for ordinary
            -- Lua errors (e.g. indexing a secret value returned by a PvP API).
            local ok, err = xpcall(callback, debugstack)
            if not ok and ns and ns.Addon and ns.Addon.Warn then
                ns.Addon:Warn("timer callback error: " .. tostring(err or "?"))
            end
        end)
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

local function applySpellMetadata(aggregate, spellId, spellName, spellSchool)
    if not aggregate then
        return
    end

    if spellName and spellName ~= "" and not aggregate.name then
        aggregate.name = spellName
    end
    if spellSchool and not aggregate.schoolMask then
        aggregate.schoolMask = spellSchool
    end

    if spellId and spellId > 0 and (not aggregate.name or not aggregate.iconID) then
        local spellInfo = ns.ApiCompat.GetSpellInfo(spellId)
        if spellInfo then
            aggregate.name = aggregate.name or spellInfo.name
            aggregate.iconID = aggregate.iconID or spellInfo.iconID
        end
    end
end

local function isProcCandidate(unitToken, auraData)
    if not auraData or not auraData.spellId then
        return false
    end
    if unitToken ~= "player" and unitToken ~= "pet" then
        return false
    end
    local ok, category = pcall(function() return Constants.SPELL_CATEGORIES[auraData.spellId] end)
    if not ok then category = nil end
    -- auraData.duration can be a secret number in Midnight arena; comparison
    -- operators on secret values throw "attempt to compare", so pcall-guard.
    local okDur, durationProc = pcall(function()
        return auraData.duration and auraData.duration > 0 and auraData.duration <= 20
    end)
    if okDur and durationProc then
        return true
    end
    if category == Constants.SPELL_CATEGORY.OFFENSIVE or category == Constants.SPELL_CATEGORY.DEFENSIVE or category == Constants.SPELL_CATEGORY.MOBILITY then
        return true
    end
    return not category
end

function CombatTracker:Initialize()
    ns.Addon:GetModule("SessionClassifier"):Initialize()

    -- T037: Re-entrant safety — recover from /reload while a session was active.
    -- runtime.currentSession is wiped on reload (it is not in SavedVariables),
    -- but a module could theoretically restore one from persisted state.  Guard
    -- against a leftover "active" session that would otherwise never finalize.
    local session = self:GetCurrentSession()
    if session and session.state == "active" then
        local age = session.startedAt and (Helpers.Now() - session.startedAt) or math.huge
        if age > STALE_SESSION_MAX_AGE then
            ns.Addon:Trace("session.reload.discard", {
                id = session.id or "unknown",
                age = age,
                reason = "stale_after_reload",
            })
            session.state = "abandoned"
            session.result = Constants.SESSION_RESULT.UNKNOWN
            self:SetCurrentSession(nil)
        else
            ns.Addon:Trace("session.reload.finalize", {
                id = session.id or "unknown",
                age = age,
                reason = "reload",
            })
            self:FinalizeSession(Constants.SESSION_RESULT.UNKNOWN, "reload")
        end
    end
end

function CombatTracker:InvalidatePendingFinalize(session)
    if not session then
        return
    end
    session.pendingFinalizeAt = nil
    session.finalizeToken = (session.finalizeToken or 0) + 1
end

-- SetImportAuthority sets session.importedTotals.importStatus and derives
-- session.importedTotals.totalAuthority from Constants.IMPORT_AUTHORITY.
-- Safe to call with a nil importStatus (clears both fields to nil).
function CombatTracker:SetImportAuthority(session, importStatus)
    if not session then return end
    if importStatus == false then return end  -- v8 migration sentinel; preserve existing state
    session.importedTotals = session.importedTotals or {}
    session.importedTotals.importStatus = importStatus
    if importStatus == nil then
        session.importedTotals.totalAuthority = nil
        return
    end
    local auth = Constants.IMPORT_AUTHORITY
    if auth.authoritative[importStatus] then
        session.importedTotals.totalAuthority = "authoritative"
    elseif auth.estimated[importStatus] then
        session.importedTotals.totalAuthority = "estimated"
    elseif auth.failed[importStatus] then
        session.importedTotals.totalAuthority = "failed"
    else
        session.importedTotals.totalAuthority = nil
    end
end

function CombatTracker:ScheduleFinalize(session, delay, reason)
    if not session or session.state ~= "active" then
        return
    end

    -- T018: Enforce a context-aware minimum settle delay so C_DamageMeter has
    -- time to push its final totals before the import pipeline runs.
    local contextKey = session and session.context or "general"
    local minDelay = Constants.DAMAGE_SETTLE_DELAY[contextKey] or 0.5
    delay = math.max(delay, minDelay)

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
    -- T038: Duplicate session guard — if an active session already exists,
    -- finalize it before creating the replacement.
    local existing = self:GetCurrentSession()
    if existing and existing.state == "active" then
        ns.Addon:Trace("session.create.guard", {
            reason = "active_session_exists",
            existingId = existing.id or "unknown",
            existingContext = existing.context or "nil",
            newContext = context or "nil",
        })
        self:FinalizeSession(Constants.SESSION_RESULT.UNKNOWN, "superseded")
    end

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
        timelineEvents = {},
        provenance = {},
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
            -- v5: defensive economy
            greedDeaths = 0,           -- deaths where a major defensive was off cooldown
            defensiveOverlapCount = 0, -- times a second major defensive was activated while one was active
            burstWasteCount = 0,       -- major offensive used into an active enemy major defensive
        },
        killWindows = {},        -- array of { openedAt, closedAt, healerSlot, converted }
        killWindowConversions = 0,
        _runtime = {
            enemyActiveDefensives = {},  -- [destGuid] = { [spellId] = true }
            playerActiveDefensives = {}, -- [spellId] = timestampOffset
            killWindowOpen = false,
            killWindowStart = nil,
            killWindowHealerSlot = nil,
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
            -- v8: damage-import correctness fields
            importStatus    = nil,  -- Constants.IMPORT_STATUS value
            importDiagnostics = nil, -- ImportDiagnostics table (degraded/failed only)
            totalAuthority  = nil,  -- "authoritative" | "estimated" | "failed"
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
        -- captureQuality: legacy summary field kept for UI backward-compat.
        -- Sub-fields other than .confidence are write-only and have been removed (T024).
        -- .confidence is computed at FinalizeSession from coverage lane scores.
        captureQuality = {
            confidence = Constants.SESSION_CONFIDENCE.ESTIMATED,
        },
        -- arena is populated at FinalizeSession by ArenaRoundTracker.
        -- false = not an arena session; nil = arena session, not yet exported.
        arena = (context == Constants.CONTEXT.ARENA) and nil or false,
        -- attribution is populated by SpellAttributionPipeline (Phase 3).
        attribution = false,
        state = "active",
        idleTime = 0,
        lastPlayerActionOffset = nil,
        pendingFinalizeAt = nil,
    }

    if classifier and classifier.InitializeSessionIdentity then
        classifier:InitializeSessionIdentity(session, context or Constants.CONTEXT.GENERAL, subcontext, identitySource or "state")
    end

    -- T014: Inherit preMatchRatingSnapshot from matchRecord.metadata when the
    -- session is created after PVP_MATCH_ACTIVE fires. This handles the common
    -- Midnight case where session creation is deferred to the first damage event.
    local preSnap = matchRecord and matchRecord.metadata and matchRecord.metadata.preMatchRatingSnapshot
    if preSnap and not session.isRated then
        session.isRated = preSnap.isRated
        if preSnap.isRated then
            session.ratingSnapshot = {}
            if preSnap.before then
                session.ratingSnapshot.before = preSnap.before
            elseif preSnap.missingReason then
                session.ratingSnapshot.missingReason = preSnap.missingReason
            end
        else
            session.ratingSnapshot = { missingReason = preSnap.missingReason or "not_rated" }
        end
    end

    ns.Addon:Trace("session.snapshot.request", { reason = "session_start" })
    session.playerSnapshot = snapshotService:GetSessionPlayerSnapshot("session_start")
    -- Attach canonical build identity fields (feature 003-build-comparator-overhaul).
    -- buildId, loadoutId, and snapshotFreshness are computed by SnapshotService and
    -- already present on the snapshot object; this block surfaces them as a
    -- reminder and ensures they survive schema evolution.
    if session.playerSnapshot then
        session.playerSnapshot.buildId = session.playerSnapshot.buildId
            or ns.BuildHash.ComputeBuildId(session.playerSnapshot)
        session.playerSnapshot.loadoutId = session.playerSnapshot.loadoutId
            or ns.BuildHash.ComputeLoadoutId(session.playerSnapshot)
        session.playerSnapshot.snapshotFreshness = session.playerSnapshot.snapshotFreshness
            or ns.Constants.SNAPSHOT_FRESHNESS.DEGRADED
    end
    ns.Addon:Trace("session.snapshot.ready", {
        buildHash  = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown",
        buildId    = session.playerSnapshot and session.playerSnapshot.buildId or "unknown",
        freshness  = session.playerSnapshot and session.playerSnapshot.snapshotFreshness or "unknown",
        quality    = session.playerSnapshot and session.playerSnapshot.captureFlags and session.playerSnapshot.captureFlags.buildSnapshot or "ok",
        specId     = session.playerSnapshot and session.playerSnapshot.specId or 0,
    })
    snapshotService:UpdateSessionActor(session, "player", "session_start")
    snapshotService:UpdateSessionActor(session, "pet", "session_start")
    self:SetCurrentSession(session)

    -- T028: Initialize UnitGraphService for this new session. Archives any
    -- prior-session actor identity and resets the per-session working set.
    local ugsInit = ns.Addon:GetModule("UnitGraphService")
    if ugsInit and ugsInit.InitializeForSession then
        pcall(ugsInit.InitializeForSession, ugsInit)
    end

    ns.Addon:Trace("session.create.ready", {
        context = session.context or "nil",
        id = session.id or "unknown",
    })
    ns.Addon:Debug("Started session %s context=%s subcontext=%s", session.id, tostring(context), tostring(subcontext))
    return session
end

function CombatTracker:EnsureSessionFromState(preferredUnitToken, source)
    local session = self:GetCurrentSession()
    if session and session.state == "active" then
        return session
    end
    if not self.playerInCombat then
        return nil
    end

    local classifier = ns.Addon:GetModule("SessionClassifier")
    local context, subcontext, resolvedUnitToken = nil, nil, nil
    if classifier and classifier.ResolveContextFromState then
        context, subcontext, resolvedUnitToken = classifier:ResolveContextFromState(preferredUnitToken)
    end
    if not context then
        return nil
    end

    if context == Constants.CONTEXT.ARENA or context == Constants.CONTEXT.BATTLEGROUND then
        self:CreateOrRefreshMatch(context, subcontext)
    end

    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService then
        damageMeterService:MarkSessionStart()
    end

    session = self:CreateSession(context, subcontext, source or "state")

    local snapshotService = ns.Addon:GetModule("SnapshotService")
    local discoveryToken = resolvedUnitToken or preferredUnitToken
    if snapshotService then
        if discoveryToken then
            local actor = snapshotService:UpdateSessionActor(session, discoveryToken, source or "state")
            if shouldUseAsPrimaryOpponent(actor, session.primaryOpponent) then
                session.primaryOpponent = actor
            end
        end
        if ApiCompat.UnitExists("target") then
            local actor = snapshotService:UpdateSessionActor(session, "target", source or "state")
            if shouldUseAsPrimaryOpponent(actor, session.primaryOpponent) then
                session.primaryOpponent = actor
            end
        end
        if ApiCompat.UnitExists("focus") then
            local actor = snapshotService:UpdateSessionActor(session, "focus", source or "state")
            if shouldUseAsPrimaryOpponent(actor, session.primaryOpponent) then
                session.primaryOpponent = actor
            end
        end
    end

    self:RefreshSessionIdentity(session, discoveryToken, source or "state")
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

    local spellInfo = ns.StaticPvpData and ns.StaticPvpData.SPELL_INTELLIGENCE and ns.StaticPvpData.SPELL_INTELLIGENCE[spellId] or nil
    if spellInfo and spellInfo.category then
        return spellInfo.category
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

    local maxEvents = Constants.MAX_RAW_EVENTS_PER_SESSION
    if #session.rawEvents >= maxEvents then
        -- Ring buffer: overwrite oldest event
        session.rawEventWrap = true
        session.rawEventWriteHead = ((session.rawEventWriteHead or #session.rawEvents) % maxEvents) + 1
        session.rawEvents[session.rawEventWriteHead] = {
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

-- T013: NormalizeCombatLogEvent deleted — no production callers remain.
-- Was only called by HandleCombatLogEvent (also deleted, T014).
-- Session data now sourced from DamageMeter + visible-unit state APIs.

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

    local session = self:CreateSession(context, subcontext, "state")
    session.startLogTimestamp = eventRecord.timestamp
    session.lastLogTimestamp = eventRecord.timestamp
    self:UpdatePrimaryOpponent(session, eventRecord)
    self:TrackActorGuid(session, ApiCompat.GetPlayerGUID())
    self:TrackActorGuid(session, eventRecord.sourceGuid)
    self:TrackActorGuid(session, eventRecord.destGuid)
    -- T031: AccumulateEvidence removed — context detection uses ResolveContextFromState()
    return session
end

function CombatTracker:UpdateSpellStats(session, eventRecord)
    if not eventRecord.spellId then
        return
    end

    local aggregate = self:EnsureSpellAggregate(session, eventRecord.spellId)
    applySpellMetadata(aggregate, eventRecord.spellId, eventRecord.spellName, eventRecord.spellSchool)
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
    elseif eventRecord.sourceMine and eventRecord.eventType ~= "other"
        and eventRecord.eventType ~= "aura"
        and eventRecord.eventType ~= "interrupt"
        and eventRecord.eventType ~= "dispel"
        and eventRecord.eventType ~= "death"
    then
        -- Negative-space guard: a mine-side event with a spellId arrived with
        -- an eventType that no branch above handles.  This usually means a new
        -- event type was introduced that UpdateSpellStats doesn't know about
        -- yet.  Trace-only to avoid spam.
        ns.Addon:Trace("spell_stats.unhandled_event_type", {
            eventType = eventRecord.eventType or "nil",
            subEvent  = eventRecord.subEvent  or "nil",
            spellId   = eventRecord.spellId   or 0,
        })
    end
end

function CombatTracker:HandleSpellDataLoadResult(spellId, success)
    if not success or not spellId or spellId <= 0 then
        return
    end

    local mainFrame = ns.Addon:GetModule("MainFrame")
    if mainFrame and mainFrame.frame and mainFrame.frame:IsShown() and mainFrame.activeViewId then
        ns.Addon:Trace("spell_data.loaded", {
            spellId = spellId,
            view = mainFrame.activeViewId,
        })
        mainFrame:ShowView(mainFrame.activeViewId)
    end
end

function CombatTracker:OpenAuraWindow(session, guid, auraId, timestampOffset, isProc, stackCount)
    local safeAuraId = safeMakeKey(auraId)
    if not safeAuraId then return nil end
    session.activeAuraWindows[guid] = session.activeAuraWindows[guid] or {}
    local current = session.activeAuraWindows[guid][safeAuraId]
    if current then
        return current
    end

    local aggregate = self:EnsureAuraAggregate(session, safeAuraId)
    aggregate.applications = aggregate.applications + 1
    aggregate.procCount = aggregate.procCount + (isProc and 1 or 0)
    aggregate.isProc = aggregate.isProc or isProc
    -- stackCount may be a secret number (auraData.applications in Midnight arena);
    -- arithmetic is fine but math.max uses comparison, so pcall-guard both.
    pcall(function()
        aggregate.stacksObserved    = aggregate.stacksObserved    + (stackCount or 0)
        aggregate.maxStacksObserved = math.max(aggregate.maxStacksObserved, stackCount or 0)
    end)

    current = {
        startedAt = timestampOffset,
        stackCount = stackCount or 0,
    }
    session.activeAuraWindows[guid][safeAuraId] = current
    return current
end

function CombatTracker:CloseAuraWindow(session, guid, auraId, timestampOffset)
    local safeAuraId = safeMakeKey(auraId)
    if not safeAuraId then return end
    local guidWindows = session.activeAuraWindows[guid]
    if not guidWindows or not guidWindows[safeAuraId] then
        return
    end

    local activeWindow = guidWindows[safeAuraId]
    local aggregate = self:EnsureAuraAggregate(session, safeAuraId)
    aggregate.totalUptime = aggregate.totalUptime + math.max(0, timestampOffset - (activeWindow.startedAt or timestampOffset))
    guidWindows[safeAuraId] = nil
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

        -- Step 1: Track enemy active major defensives.
        -- Step 2: Track player defensive overlaps.
        local spellInfo = ns.StaticPvpData and ns.StaticPvpData.GetSpellInfo(eventRecord.auraId)
        if spellInfo and spellInfo.isMajorDefensive then
            local rt = session._runtime
            if rt then
                if not eventRecord.destMine then
                    -- Enemy gained a major defensive — record it so burst waste can be checked.
                    rt.enemyActiveDefensives[eventRecord.destGuid] =
                        rt.enemyActiveDefensives[eventRecord.destGuid] or {}
                    rt.enemyActiveDefensives[eventRecord.destGuid][eventRecord.auraId] = true
                else
                    -- Player gained a major defensive.
                    -- If another is already active, that is a defensive overlap.
                    if next(rt.playerActiveDefensives) ~= nil then
                        session.survival.defensiveOverlapCount =
                            (session.survival.defensiveOverlapCount or 0) + 1
                    end
                    rt.playerActiveDefensives[eventRecord.auraId] = eventRecord.timestampOffset
                end
            end
        end
    elseif eventRecord.subEvent == "SPELL_AURA_REFRESH" then
        aggregate.refreshCount = aggregate.refreshCount + 1
    elseif eventRecord.subEvent == "SPELL_AURA_REMOVED" or eventRecord.subEvent == "SPELL_AURA_REMOVED_DOSE" or eventRecord.subEvent == "SPELL_AURA_BROKEN" or eventRecord.subEvent == "SPELL_AURA_BROKEN_SPELL" then
        self:CloseAuraWindow(session, guid, eventRecord.auraId, eventRecord.timestampOffset)

        -- Step 1: Clear enemy active major defensive.
        -- Step 2: Clear player active major defensive.
        local spellInfo = ns.StaticPvpData and ns.StaticPvpData.GetSpellInfo(eventRecord.auraId)
        if spellInfo and spellInfo.isMajorDefensive then
            local rt = session._runtime
            if rt then
                if not eventRecord.destMine then
                    local enemyDefs = rt.enemyActiveDefensives[eventRecord.destGuid]
                    if enemyDefs then
                        enemyDefs[eventRecord.auraId] = nil
                    end
                else
                    rt.playerActiveDefensives[eventRecord.auraId] = nil
                end
            end
        end
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

            -- Step 3: Greed death — check if any major defensive was available (off cooldown).
            -- C_Spell.IsSpellUsable returns (isUsable, notEnoughPower) or nil for unknown spells.
            -- A non-nil truthy first return means the spell is in the spellbook and off cooldown.
            local taxonomy = ns.StaticPvpData and ns.StaticPvpData.SPELL_TAXONOMY
            if taxonomy and taxonomy.majorDefensive then
                for sid in pairs(taxonomy.majorDefensive) do
                    local isUsable = C_Spell.IsSpellUsable(sid)
                    if isUsable then
                        session.survival.greedDeaths =
                            (session.survival.greedDeaths or 0) + 1
                        break  -- one greed flag per death is sufficient
                    end
                end
            end
        elseif session.primaryOpponent and eventRecord.destGuid == session.primaryOpponent.guid then
            session.primaryOpponent.isDead = true
        end

        -- Kill window conversion: an enemy died while a kill window was open.
        if not eventRecord.destMine then
            local rt = session and session._runtime
            -- Kill window conversion: fires on ANY enemy death during an open window, not
            -- specifically the healer's death. Overstates conversions if a DPS dies while
            -- the healer is still CC'd. Accurate healer-specific detection requires a
            -- guid-to-slot lookup via ArenaRoundTracker:GetSlots() which is deferred.
            if rt and rt.killWindowOpen then
                session.killWindows[#session.killWindows + 1] = {
                    openedAt   = rt.killWindowStart,
                    closedAt   = eventRecord.timestampOffset,
                    healerSlot = rt.killWindowHealerSlot,
                    converted  = true,
                }
                session.killWindowConversions = (session.killWindowConversions or 0) + 1
                rt.killWindowOpen       = false
                rt.killWindowStart      = nil
                rt.killWindowHealerSlot = nil
            end
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
    -- T015/T031: Gated behind dev flag — AccumulateEvidence and
    -- ShouldStartNewSession have been removed from SessionClassifier.
    -- CA_DEV_LEGACY is never set in production; function body kept for later refactor.
    if not CA_DEV_LEGACY then return end

    local session = self:GetCurrentSession()
    if not session then
        return
    end

    if not self:ShouldTrackEvent(session, eventRecord) then
        ns.Addon:Trace("timeline.untracked", {
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
    -- T031: AccumulateEvidence removed — context detection uses ResolveContextFromState()
    self:RefreshSessionIdentity(session, nil, "state")

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

    -- Forward to ArenaRoundTracker for GUID resolution and pressure scoring.
    -- Only meaningful during arena sessions but safe to call unconditionally.
    if session.context == Constants.CONTEXT.ARENA then
        local art = ns.Addon:GetModule("ArenaRoundTracker")
        -- Legacy path removed: ArenaRoundTracker pressure now from DamageMeter
        -- if art then art:HandleCombatLogEvent(eventRecord) end
    end

    -- Forward to SpellAttributionPipeline for enemy-source attribution.
    -- Tracks incoming damage and summon ownership regardless of context.
    local sap = ns.Addon:GetModule("SpellAttributionPipeline")
    -- Legacy path removed: SpellAttribution now from DamageMeter only
    -- if sap then sap:HandleCombatLogEvent(session, eventRecord) end
end

function CombatTracker:CloseOpenAuras(session)
    for guid, auraMap in pairs(session.activeAuraWindows or {}) do
        for auraId in pairs(auraMap) do
            self:CloseAuraWindow(session, guid, auraId, session.duration or 0)
        end
    end
end

function CombatTracker:DeriveResult(session, explicitResult, reason)
    -- Only trust explicit results that are definitive.
    -- UNKNOWN explicit means event-based resolution failed; fall through to heuristics
    -- so death/kill signals can still produce a meaningful result.
    if explicitResult and explicitResult ~= Constants.SESSION_RESULT.UNKNOWN then
        return explicitResult
    end
    -- A previously-set session.result takes priority if definitive.
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

-- ResolveDataConfidence: returns one of the Constants.ANALYSIS_CONFIDENCE values
-- based on the richest available signal for this session.
-- Priority:
--   1. SpellAttributionPipeline reconciliation (state + DamageMeter data)
--   2. State-only (unrestricted session, no DamageMeter import needed)
--   3. Restricted session (DamageMeter only, limited state data)
--   4. Nothing useful captured → UNKNOWN
function CombatTracker:ResolveDataConfidence(session)
    local AC = Constants.ANALYSIS_CONFIDENCE

    -- If SAP ran and produced a reconciliation confidence, use it as the primary signal.
    -- For arenas, downgrade to PARTIAL_ROSTER if ArenaRoundTracker captured no slots —
    -- that means opponent identity is unknown regardless of damage reconciliation.
    if type(session.attribution) == "table" then
        local rec = session.attribution.reconciliation
        if rec and rec.confidence and rec.confidence ~= AC.UNKNOWN then
            if session.context == Constants.CONTEXT.ARENA then
                local arenaSlots = type(session.arena) == "table"
                    and session.arena.slots or nil
                local slotCount = 0
                if arenaSlots then
                    for _ in pairs(arenaSlots) do slotCount = slotCount + 1 end
                end
                -- Zero slots means no enemy identity data was captured at all.
                if slotCount == 0 then
                    return AC.PARTIAL_ROSTER
                end
            end
            return rec.confidence
        end
    end

    -- Fallback: derive from what data is available.
    local hasRawTimeline = #(session.rawEvents or {}) > 0
    if not hasRawTimeline then
        local importedTotals = session.importedTotals or {}
        local hasDamageMeterEvidence =
            (session.import and session.import.source and session.import.source ~= "none")
            or (session.damageBreakdownSource and session.damageBreakdownSource ~= "none")
            or (tonumber(importedTotals.damageDone) or 0) > 0
            or (tonumber(importedTotals.healingDone) or 0) > 0
            or (tonumber(importedTotals.damageTaken) or 0) > 0
            or (tonumber(importedTotals.absorbed) or 0) > 0
        if hasDamageMeterEvidence then
            if session.damageBreakdownSource and session.damageBreakdownSource ~= "none" then
                return AC.RESTRICTED_RAW
            end
            return AC.DEGRADED
        end
        return AC.UNKNOWN
    end

    -- Raw events present, no DamageMeter reconciliation ran (e.g. training dummy
    -- with unrestricted state would still have rawEvents from the local window).
    if ApiCompat.IsCombatLogRestricted() then
        return AC.RESTRICTED_RAW
    end

    return AC.FULL_RAW
end

-- ResolveAnalysisConfidence: maps the rich ANALYSIS_CONFIDENCE label to the
-- legacy 3-tier "high"/"medium"/"limited" strings consumed by all UI components.
-- Do not change these strings without updating all UI callers in Phase 5.
function CombatTracker:ResolveAnalysisConfidence(session)
    local AC = Constants.ANALYSIS_CONFIDENCE
    local dc = session.dataConfidence or AC.UNKNOWN
    if dc == AC.FULL_RAW or dc == AC.ENRICHED then
        return "high"
    end
    if dc == AC.RESTRICTED_RAW or dc == AC.PARTIAL_ROSTER then
        return "medium"
    end
    -- DEGRADED, UNKNOWN → "limited"
    return "limited"
end

-- Task 2.3 / T056: Death Cause Attribution
-- Scans timelineEvents for death-lane entries and looks backwards through the
-- timeline for the damage events leading up to each death.  Also checks the
-- CC_RECEIVED lane to determine if the player was crowd-controlled at death time.
local function analyzeDeath(session)
    if (session.survival and session.survival.deaths or 0) == 0 then return end

    local timeline = session.timelineEvents
    if not timeline or #timeline == 0 then return end

    -- Collect indices of death-lane events for the player.
    local deathIndices = {}
    for i, ev in ipairs(timeline) do
        if ev.lane == Constants.TIMELINE_LANE.DEATH and ev.destMine then
            deathIndices[#deathIndices + 1] = i
        end
    end
    if #deathIndices == 0 then return end

    session.deathCauses = session.deathCauses or {}

    for _, deathIdx in ipairs(deathIndices) do
        local deathEvt = timeline[deathIdx]
        local killingSpells = {}
        local totalBurstDamage = 0
        local sourceGuid, sourceName, sourceSpecId = nil, nil, nil

        -- Scan backwards from death event to find last 6 damage events targeting the player.
        -- T029: Skip chronology = "summary" rows — DM post-match aggregate rows must
        -- never be selected as the killing blow or last hostile cast.
        local count = 0
        for i = deathIdx - 1, 1, -1 do
            if count >= 6 then break end
            local ev = timeline[i]
            if ev and ev.amount and ev.amount > 0 and ev.destMine
                    and ev.chronology ~= "summary" then
                -- Resolve source name from session actors table
                local resolvedName = nil
                if ev.sourceGuid and session.actors and session.actors[ev.sourceGuid] then
                    resolvedName = session.actors[ev.sourceGuid].name
                end
                killingSpells[#killingSpells + 1] = {
                    spellId = ev.spellId,
                    amount = ev.amount or 0,
                    critical = ev.critical,
                    sourceGuid = ev.sourceGuid,
                    sourceName = resolvedName,
                    timestampOffset = ev.timestampOffset,
                }
                totalBurstDamage = totalBurstDamage + (ev.amount or 0)
                if not sourceGuid and ev.sourceGuid then
                    sourceGuid = ev.sourceGuid
                    sourceName = resolvedName
                end
                count = count + 1
            end
        end

        -- Check if player was under CC at time of death (reads CC_RECEIVED lane)
        local wasCCed = false
        local ccSpellId = nil
        local deathOffset = deathEvt.timestampOffset or 0
        for _, ev in ipairs(timeline) do
            if ev.lane == Constants.TIMELINE_LANE.CC_RECEIVED and ev.type == "start" then
                local meta = ev.meta or {}
                local ccStart = ev.t or 0
                local ccEnd = ccStart + (meta.duration or 0)
                if deathOffset >= ccStart and deathOffset <= ccEnd then
                    wasCCed = true
                    ccSpellId = meta.spellID or ev.spellId
                    break
                end
            end
        end

        -- Resolve source spec from primaryOpponent or arena roster
        if sourceGuid and session.primaryOpponent and session.primaryOpponent.guid == sourceGuid then
            sourceSpecId = session.primaryOpponent.specId
        end

        session.deathCauses[#session.deathCauses + 1] = {
            timestampOffset = deathEvt.timestampOffset,
            killingSpells = killingSpells,
            totalBurstDamage = totalBurstDamage,
            sourceGuid = sourceGuid,
            sourceName = sourceName,
            sourceSpecId = sourceSpecId,
            wasCCed = wasCCed,
            ccSpellId = ccSpellId,
        }
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Phase 3: Analytics Extraction
-- Runs during FinalizeSession to extract interrupt log, kill timings,
-- healer/DPS pressure split, and opponent comp key from raw events.
-- ──────────────────────────────────────────────────────────────────────────────

function CombatTracker:ExtractPhase3Analytics(session)
    if not session or not session.rawEvents then return end

    local events = session.rawEvents
    local playerGuid = ApiCompat.GetPlayerGUID()

    -- ── 3.1: Interrupt Log ──────────────────────────────────────────────────
    session.interruptLog = session.interruptLog or {}
    if session.interruptLog == false then session.interruptLog = {} end
    for _, evt in ipairs(events) do
        if evt.eventType == "interrupt" and evt.sourceMine then
            session.interruptLog[#session.interruptLog + 1] = {
                timestampOffset   = evt.timestampOffset,
                interruptSpellId  = evt.spellId,
                interruptedSpellId = evt.extraSpellId,
                targetGuid        = evt.destGuid,
                targetName        = evt.destName,
            }
        end
    end

    -- Compute interrupt rate for session.metrics
    local succ = session.utility and session.utility.successfulInterrupts or 0
    local fail = session.utility and session.utility.failedInterrupts or 0
    local total = succ + fail
    session.metrics = session.metrics or {}
    session.metrics.interruptRate = total > 0 and (succ / total) or nil

    -- ── 3.2: Healer vs DPS Pressure Split ───────────────────────────────────
    if session.context == Constants.CONTEXT.ARENA and session.arena and session.arena.slots then
        local roleByGuid = {}
        for _, slot in pairs(session.arena.slots) do
            if slot.guid and slot.prepRole then
                roleByGuid[slot.guid] = slot.prepRole
            end
        end

        local dmgToHealer, dmgToDps, dmgTotal, switchCount = 0, 0, 0, 0
        local lastTarget = nil
        for _, evt in ipairs(events) do
            if evt.eventType == "damage" and evt.sourceMine and evt.destGuid then
                local amount = evt.amount or 0
                local role = roleByGuid[evt.destGuid]
                if role == "HEALER" then
                    dmgToHealer = dmgToHealer + amount
                elseif role == "DAMAGER" or role == "TANK" then
                    dmgToDps = dmgToDps + amount
                end
                dmgTotal = dmgTotal + amount
                if evt.destGuid ~= lastTarget and lastTarget then
                    switchCount = switchCount + 1
                end
                lastTarget = evt.destGuid
            end
        end

        if dmgTotal > 0 then
            session.metrics.healerPressure = dmgToHealer / dmgTotal
            session.metrics.dpsPressure = dmgToDps / dmgTotal
        end
        session.metrics.targetSwitchCount = switchCount
    end

    -- ── 3.4: Opponent Comp Key ──────────────────────────────────────────────
    if session.context == Constants.CONTEXT.ARENA and session.arena and session.arena.slots then
        local specIds = {}
        for _, slot in pairs(session.arena.slots) do
            if slot.prepSpecId then
                specIds[#specIds + 1] = slot.prepSpecId
            end
        end
        if #specIds > 0 then
            table.sort(specIds)
            local parts = {}
            for _, id in ipairs(specIds) do parts[#parts + 1] = tostring(id) end
            session.opponentCompKey = table.concat(parts, "-")
        end
    end
    if session.opponentCompKey == false then session.opponentCompKey = nil end

    -- ── 3.5: Time-to-Kill (TTK) Analysis ───────────────────────────────────
    session.killTimings = session.killTimings or {}
    if session.killTimings == false then session.killTimings = {} end

    -- Track first damage timestamp and total damage per enemy target.
    local targetFirstDmg = {}  -- guid -> timestampOffset
    local targetTotalDmg = {}  -- guid -> total damage
    local targetNames    = {}  -- guid -> name
    local targetDeaths   = {}  -- guid -> timestampOffset of death

    for _, evt in ipairs(events) do
        if evt.eventType == "damage" and evt.sourceMine and evt.destGuid and evt.destGuid ~= playerGuid then
            if not targetFirstDmg[evt.destGuid] then
                targetFirstDmg[evt.destGuid] = evt.timestampOffset or 0
            end
            targetTotalDmg[evt.destGuid] = (targetTotalDmg[evt.destGuid] or 0) + (evt.amount or 0)
            targetNames[evt.destGuid] = evt.destName
        elseif evt.eventType == "death" and evt.destGuid and evt.destGuid ~= playerGuid then
            targetDeaths[evt.destGuid] = evt.timestampOffset or 0
        end
    end

    for guid, deathOffset in pairs(targetDeaths) do
        local firstDmgOffset = targetFirstDmg[guid]
        if firstDmgOffset then
            local ttk = deathOffset - firstDmgOffset
            if ttk >= 0 then
                session.killTimings[#session.killTimings + 1] = {
                    targetGuid         = guid,
                    targetName         = targetNames[guid],
                    firstDamageOffset  = firstDmgOffset,
                    deathOffset        = deathOffset,
                    ttk                = ttk,
                    totalDamageToTarget = targetTotalDmg[guid] or 0,
                }
            end
        end
    end

    -- Compute average TTK
    if #session.killTimings > 0 then
        local ttkSum = 0
        for _, kt in ipairs(session.killTimings) do
            ttkSum = ttkSum + kt.ttk
        end
        session.metrics.avgTTK = ttkSum / #session.killTimings
    end
end

function CombatTracker:FinalizeSession(explicitResult, reason)
    local session = self:GetCurrentSession()
    -- Idempotent: only finalizes sessions in "active" state.  Repeated calls
    -- (e.g. from overlapping timers, OnUpdate fallback, or manual flush) are
    -- safely ignored once the session has transitioned out of "active".
    if not session or session.state ~= "active" then
        return nil
    end

    self:CloseOpenAuras(session)
    analyzeDeath(session)

    -- T055/T030: Extract opener sequence from timelineEvents (VISIBLE_CAST lane;
    -- PLAYER_CAST is the legacy alias kept for sessions recorded before T013).
    -- T030: chronology guard — only realtime observed casts count; DM summary
    -- rows must not appear in the opener sequence.
    local openerSpells = {}
    for _, ev in ipairs(session.timelineEvents or {}) do
        if #openerSpells >= 5 then break end
        if (ev.lane == Constants.TIMELINE_LANE.VISIBLE_CAST
                or ev.lane == Constants.TIMELINE_LANE.PLAYER_CAST)
            and ev.chronology ~= "summary"
            and ev.spellId then
            openerSpells[#openerSpells + 1] = ev.spellId
        end
    end
    if #openerSpells > 0 then
        local hashInput = table.concat(openerSpells, ":")
        session.openerSequence = {
            spellIds = openerSpells,
            hash = string.format("%08x", ns.Math.HashString32(hashInput)),
        }
    end

    -- Phase 3 analytics extraction (runs before DamageMeter import and metrics).
    local okPhase3, errPhase3 = xpcall(function()
        self:ExtractPhase3Analytics(session)
    end, debugstack)
    if not okPhase3 then
        ns.Addon:Debug("Phase3 analytics extraction failed: %s", errPhase3)
    end

    session.endedAt = ApiCompat.GetServerTime()

    -- Sanitize totals: in restricted PvP sessions, localTotals may contain
    -- secret values that leaked through despite our sanitization.  Force them
    -- to safe numbers before any arithmetic in finalization/metrics.
    for _, bucket in ipairs({ session.localTotals, session.totals, session.importedTotals }) do
        if bucket then
            for key, val in pairs(bucket) do
                if type(val) ~= "number" or ApiCompat.IsSecretValue(val) then
                    bucket[key] = 0
                end
            end
        end
    end

    -- Safety: ensure the "after" rating snapshot is captured even if
    -- HandlePvpMatchComplete was not reached or errored.
    if session.isRated and session.ratingSnapshot and not session.ratingSnapshot.after then
        local ratedInfo = ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
        if ratedInfo then
            session.ratingSnapshot.after = {
                personalRating   = ratedInfo.personalRating,
                bestSeasonRating = ratedInfo.bestSeasonRating,
                seasonPlayed     = ratedInfo.seasonPlayed,
                seasonWon        = ratedInfo.seasonWon,
                weeklyPlayed     = ratedInfo.weeklyPlayed,
                weeklyWon        = ratedInfo.weeklyWon,
            }
        elseif not session.ratingSnapshot.missingReason then
            session.ratingSnapshot.missingReason = "api_unavailable"
        end
    end
    -- T052: Ensure non-rated sessions always have a missingReason.
    if not session.isRated and not session.ratingSnapshot then
        session.ratingSnapshot = { missingReason = "not_rated" }
    end

    -- Seed arena slot identity (GUIDs, names, specs) BEFORE DamageMeter import
    -- so collectExpectedOpponentGuids has populated data for candidate scoring.
    -- The full CopyStateIntoSession (with pressure scoring) runs after import.
    if session.context == Constants.CONTEXT.ARENA then
        local art = ns.Addon:GetModule("ArenaRoundTracker")
        if art and art.SeedSessionIdentity then
            art:SeedSessionIdentity(session)
        end
    end

    -- Diagnostic trace: state before DamageMeter import (helps debug arena failures).
    if session.context == Constants.CONTEXT.ARENA or session.context == Constants.CONTEXT.BATTLEGROUND then
        local slotCount = 0
        if session.arena and session.arena.slots then
            for _ in pairs(session.arena.slots) do slotCount = slotCount + 1 end
        end
        ns.Addon:Trace("session.pre_import", {
            context = session.context or "unknown",
            hasPrimaryOpponent = session.primaryOpponent ~= nil,
            opponentGuid = session.primaryOpponent and session.primaryOpponent.guid or "nil",
            opponentName = session.primaryOpponent and session.primaryOpponent.name or "nil",
            arenaSlotCount = slotCount,
            castCount = getRecordedCastCount(session),
            localDamage = session.localTotals and session.localTotals.damageDone or 0,
        })
    end

    session.damageMeterImportAttempts = session.damageMeterImportAttempts or 0
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    -- C_DamageMeter APIs are marked SecretWhenInCombat=true: they return
    -- opaque secret values during combat lockdown that IsSecretValue()
    -- sanitizes to zero. When finalizing during combat (training dummy idle
    -- timeout), queue a deferred import for after combat ends instead.
    if damageMeterService and not (InCombatLockdown and InCombatLockdown()) then
        local okImport, importedOrError = xpcall(function()
            return damageMeterService:ImportSession(session)
        end, debugstack)
        if not okImport then
            self:SetImportAuthority(session, Constants.IMPORT_STATUS.FAILED_DAMAGE_METER_UNAVAILABLE)
            ns.Addon:Warn("Damage Meter import failed; storing limited session data.")
            ns.Addon:Debug("%s", importedOrError)
        elseif not importedOrError then
            self:SetImportAuthority(session, Constants.IMPORT_STATUS.FAILED_NO_CANDIDATE)
        end
    elseif damageMeterService and (InCombatLockdown and InCombatLockdown()) then
        -- Queue deferred import: C_DamageMeter data is secret right now.
        -- HandlePlayerRegenEnabled will pick this up and re-import.
        -- Only one session can be finalized-in-combat at a time because
        -- training dummy timeouts are serialized through FinalizeSession.
        -- If a second session overwrites this slot, the first is still safe —
        -- the HandlePlayerRegenEnabled timer closure captures `deferredSession`
        -- by value, not by re-reading this field.
        self._deferredImportSession = session
        ns.Addon:Trace("damage_meter.import.deferred", {
            reason = "in_combat_lockdown",
            context = session.context or "unknown",
        })
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

    -- Health-delta fallback for training dummy sessions: when C_DamageMeter
    -- import produced zero damage but the OnUpdate health sampler observed
    -- actual health decreases on the target, use that as an estimated total.
    -- This handles the case where C_DamageMeter doesn't produce sessions for
    -- training dummy combat or where SecretWhenInCombat zeroed the data.
    if session.context == Constants.CONTEXT.TRAINING_DUMMY
        and (session.totals.damageDone or 0) <= 0
        and session._runtime
        and session._runtime.healthDelta
    then
        local hd = session._runtime.healthDelta
        if hd.totalDamageEstimate > 0 then
            session.totals.damageDone = hd.totalDamageEstimate
            session.importedTotals = session.importedTotals or {}
            session.importedTotals.damageDone = hd.totalDamageEstimate
            session.importedTotals.importStatus = Constants.IMPORT_STATUS.ESTIMATED_FROM_CASTS
            session.importedTotals.healthDeltaSamples = hd.samples
            self:SetImportAuthority(session, Constants.IMPORT_STATUS.ESTIMATED_FROM_CASTS)
            ns.Addon:Trace("damage_meter.health_delta_fallback", {
                estimatedDamage = hd.totalDamageEstimate,
                samples = hd.samples,
            })
        end
    end

    -- T019: Zero-damage real-combat override — if retries are exhausted and
    -- damage is still zero on a session with real combat signals, mark failed
    -- so the UI shows an honest reason rather than a silent zero.
    do
        local finalDamage = (session.totals and session.totals.damageDone) or 0
        local importedTotals = session.importedTotals or {}
        local currentAuthority = importedTotals.totalAuthority
        local hasRealCombatSignals = (
            finalDamage == 0
            and currentAuthority ~= "failed"
            and (
                getRecordedCastCount(session) > 0
                or session.primaryOpponent ~= nil
                or (session.duration or 0) >= 5
                or Helpers.IsPvpAnalyticsContext(session.context)
            )
        )
        if hasRealCombatSignals and (importedTotals.importStatus == nil or currentAuthority == nil) then
            self:SetImportAuthority(session, Constants.IMPORT_STATUS.FAILED_NO_MEANINGFUL_DATA)
        end
    end

    -- Post-import spell normalization: when session has total damage but
    -- individual spells have casts with 0 damage, distribute the unaccounted
    -- damage proportionally by cast weight.  Handles edge cases where the DM
    -- import set totals but returned no per-spell breakdown.
    do
        local totalDamage = (session.totals and session.totals.damageDone) or 0
        if totalDamage > 0 then
            local existingSpellDamage = 0
            local backfillCandidates = {}
            local totalWeight = 0
            for spellId, agg in pairs(session.spells or {}) do
                local dmg = tonumber(agg.totalDamage) or 0
                existingSpellDamage = existingSpellDamage + dmg
                if dmg <= 0 and (agg.castCount or 0) > 0 then
                    local cat = Constants.SPELL_CATEGORIES and Constants.SPELL_CATEGORIES[spellId]
                    local eligible = cat == nil or cat == Constants.SPELL_CATEGORY.OFFENSIVE
                    if eligible then
                        local w = math.max(agg.castCount or 0, 1)
                        backfillCandidates[#backfillCandidates + 1] = { aggregate = agg, weight = w }
                        totalWeight = totalWeight + w
                    end
                end
            end

            local remaining = math.max(0, totalDamage - existingSpellDamage)
            if remaining > 0 and totalWeight > 0 and #backfillCandidates > 0 then
                local allocated = 0
                for i, entry in ipairs(backfillCandidates) do
                    local estimate
                    if i == #backfillCandidates then
                        estimate = remaining - allocated
                    else
                        estimate = math.floor((remaining * entry.weight / totalWeight) + 0.5)
                    end
                    if estimate > 0 then
                        entry.aggregate.totalDamage = (entry.aggregate.totalDamage or 0) + estimate
                        entry.aggregate.hitCount = math.max(entry.aggregate.hitCount or 0, entry.aggregate.castCount or 0, 1)
                        entry.aggregate.executeCount = math.max(entry.aggregate.executeCount or 0, entry.aggregate.hitCount or 0, 1)
                        allocated = allocated + estimate
                    end
                end
                if allocated > 0 then
                    ns.Addon:Trace("finalize.spell_backfill", {
                        total = totalDamage,
                        existing = existingSpellDamage,
                        distributed = allocated,
                        spells = #backfillCandidates,
                    })
                end
            end
        end
    end

    -- Spell auto-classification: enrich spell aggregates with Midnight C_Spell
    -- classification APIs. These work on non-secret spellIDs (player's own casts)
    -- and provide authoritative CC/defensive/important flags that supplement
    -- the manual SeedSpellIntelligence catalog.
    do
        for spellId, agg in pairs(session.spells or {}) do
            if spellId and spellId > 0 and not agg.autoClassified then
                local isCC = ApiCompat.IsSpellCrowdControl(spellId)
                local isDef = ApiCompat.IsExternalDefensive(spellId)
                local isImportant = ApiCompat.IsSpellImportant(spellId)
                if isCC ~= nil or isDef ~= nil or isImportant ~= nil then
                    agg.autoClassified = true
                    if isCC then agg.isCC = true end
                    if isDef then agg.isDefensive = true end
                    if isImportant then agg.isImportant = true end
                end
            end
        end
    end

    -- T011: Export arena round state BEFORE classifier sync, metrics, and
    -- suggestions so all downstream analytics consume the hardened opponent
    -- identity rather than the first-hit placeholder.
    if session.context == Constants.CONTEXT.ARENA then
        local art = ns.Addon:GetModule("ArenaRoundTracker")
        if art then art:CopyStateIntoSession(session) end
    end

    -- T028: Enrich primaryOpponent identity fields using UnitGraphService's
    -- best-available resolution (which may have visible_unit priority data from
    -- VisibleCastProducer / ArenaRoundTracker that DM summary rows lack).
    do
        local ugsFinalize = ns.Addon:GetModule("UnitGraphService")
        local opp = session.primaryOpponent
        if ugsFinalize and opp and opp.guid then
            pcall(function()
                local identity = ugsFinalize:GetBestDisplayIdentity(opp.guid)
                if identity then
                    opp.name      = opp.name      or identity.name
                    opp.classFile = opp.classFile or identity.classFile
                    opp.specId    = opp.specId    or identity.specId
                    opp.arenaSlot = opp.arenaSlot or identity.arenaSlot
                    -- Record where the identity came from for diagnostics.
                    opp.identityProvenance = identity.provenance
                end
            end)
        end
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
        ns.Metrics.DeriveCoordination(session)
    end, debugstack)
    if not okWindows then
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

    -- Classify enemy comp archetype from arena slot spec IDs.
    -- session.arena.slots is keyed by slot integer; each entry has prepSpecId.
    -- Only runs for arena sessions where CopyStateIntoSession populated slots.
    if session.arena and session.arena.slots then
        local specIds = {}
        for _, slot in pairs(session.arena.slots) do
            local sid = slot.prepSpecId
            if sid and sid > 0 then
                specIds[#specIds + 1] = sid
            end
        end
        local compClassifier = ns.CompArchetypeClassifier
        if compClassifier then
            session.arena.compArchetype = compClassifier.ClassifyComp(specIds)
        end
    end

    session.finalDamageSource  = self:ResolveFinalDamageSource(session)
    -- dataConfidence must be set before ResolveAnalysisConfidence reads it.
    session.dataConfidence     = self:ResolveDataConfidence(session)
    session.analysisConfidence = self:ResolveAnalysisConfidence(session)

    -- T053: Populate provenance map — records which sanctioned API produced
    -- each persisted field group.  Adjust source based on actual data paths.
    local dmSuccess = session.import and session.import.source ~= "none"
    local PS = Constants.PROVENANCE_SOURCE
    session.provenance = {
        totals          = dmSuccess and PS.DAMAGE_METER or PS.STATE,
        spells          = PS.STATE,
        auras           = PS.VISIBLE_UNIT,
        attribution     = dmSuccess and PS.DAMAGE_METER or PS.ESTIMATED,
        arena           = PS.STATE,
        openerSequence  = PS.STATE,
        metrics         = PS.ESTIMATED,
        suggestions     = PS.ESTIMATED,
    }

    -- T054: Resolve session confidence using SESSION_CONFIDENCE enum.
    local SC = Constants.SESSION_CONFIDENCE
    local hasTimeline = session.timelineEvents and #session.timelineEvents > 0
    local hasCC = false
    for _, ev in ipairs(session.timelineEvents or {}) do
        if ev.lane == Constants.TIMELINE_LANE.CC_RECEIVED then hasCC = true; break end
    end
    local partialRoster = session.arena and session.arena.completionState == "partial_leaver"

    if dmSuccess and hasTimeline then
        session.captureQuality.confidence = SC.STATE_PLUS_DAMAGE_METER
    elseif dmSuccess then
        session.captureQuality.confidence = SC.DAMAGE_METER_ONLY
    elseif hasCC then
        session.captureQuality.confidence = SC.VISIBLE_CC_ONLY
    elseif partialRoster then
        session.captureQuality.confidence = SC.PARTIAL_ROSTER
    else
        session.captureQuality.confidence = SC.ESTIMATED
    end

    -- T023: Wire session.deathRecap from DM API into a DEATH lane timeline marker
    -- so the timeline and coverage services can account for death events.
    if session.deathRecap then
        local tp = ns.Addon:GetModule("TimelineProducer")
        if tp then
            local now = Helpers.Now()
            local t   = now - (session.startedAt or now)
            -- Use deathRecap.timeSeconds as the event offset when available.
            local deathOffset = session.deathRecap.timeSeconds
            if type(deathOffset) ~= "number" then deathOffset = t end
            tp:AppendTimelineEvent(session, {
                t          = deathOffset,
                lane       = Constants.TIMELINE_LANE.DEATH,
                type       = "death_recap",
                source     = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
                confidence = "confirmed",
                meta = {
                    recapEvents = session.deathRecap.events,
                    maxHealth   = session.deathRecap.maxHealth,
                    recapID     = session.deathRecap.recapID,
                },
            })
        end
    end

    -- Compute per-lane data coverage scores (T012).
    local covSvc = ns.Addon:GetModule("CoverageService")
    if covSvc then covSvc:Finalize(session) end

    session.state = "finalized"

    ns.Addon:Trace("session.finalized", {
        context = session.context or "unknown",
        identityConfidence = session.identity and session.identity.confidence or 0,
        importConfidence = session.import and session.import.confidence or 0,
        localDamage = session.localTotals and session.localTotals.damageDone or 0,
        importedDamage = session.importedTotals and session.importedTotals.damageDone or 0,
        finalDamage = session.totals and session.totals.damageDone or 0,
        finalDamageSource = session.finalDamageSource or "unknown",
        dataConfidence = session.dataConfidence or "unknown",
        analysisConfidence = session.analysisConfidence or "unknown",
    })

    -- Export enemy CC records from runtime to session
    if session._runtime and session._runtime.enemyCC then
        session.enemyCCEvents = {}
        for _, ccRecord in pairs(session._runtime.enemyCC) do
            session.enemyCCEvents[#session.enemyCCEvents + 1] = ccRecord
        end
    end

    -- Export DR snapshots from runtime
    if session._runtime and session._runtime.drSnapshots and #session._runtime.drSnapshots > 0 then
        session.drSnapshots = session._runtime.drSnapshots
    end

    -- Runtime-only tracking tables must not persist to SavedVariables.
    if session._runtime and session._runtime.killWindowOpen then
        -- Close any window still open at match end.
        session.killWindows[#session.killWindows + 1] = {
            openedAt   = session._runtime.killWindowStart,
            closedAt   = nil,   -- nil = window was still open at match end; never force-closed
            healerSlot = session._runtime.killWindowHealerSlot,
            converted  = false,
        }
    end
    session._runtime = nil

    local okPersist, errPersist = xpcall(function()
        ns.Addon:GetModule("CombatStore"):PersistSession(session)
    end, debugstack)
    if not okPersist then
        ns.Addon:Warn("Session persistence failed.")
        ns.Addon:Debug("%s", errPersist)
        return nil
    end

    -- Party sync broadcast (Task 6.3)
    local partySyncService = ns.Addon:GetModule("PartySyncService")
    if partySyncService and partySyncService.BroadcastSession then
        xpcall(function() partySyncService:BroadcastSession(session) end, debugstack)
    end

    ns.Addon:Debug(
        "Finalized session %s reason=%s raw=%d dmg=%d stored_sessions=%d",
        session.id,
        tostring(reason),
        #(session.rawEvents or {}),
        session.totals.damageDone or 0,
        ns.Addon:GetModule("CombatStore"):GetStorageStats().sessions or 0
    )

    -- T021: Post-finalization one-shot re-import listener.
    -- If the session was finalized without authoritative damage data, watch for
    -- a DAMAGE_METER_COMBAT_SESSION_UPDATED event within 10 seconds and schedule
    -- one additional import attempt. Capped at 1 re-attempt.
    do
        local importedTotals = session.importedTotals or {}
        if importedTotals.totalAuthority ~= "authoritative" then
            local dmService = ns.Addon:GetModule("DamageMeterService")
            if dmService then
                dmService._postFinalizeWatchSession = session
                dmService._postFinalizeWatchAt     = Helpers.Now()
                dmService._postFinalizeRetried     = false
                scheduleAfter(10, function()
                    if dmService._postFinalizeWatchSession == session then
                        dmService._postFinalizeWatchSession = nil
                        dmService._postFinalizeWatchAt      = nil
                        dmService._postFinalizeRetried      = nil
                    end
                end)
            end
        end
    end

    self:SetCurrentSession(nil)

    if ns.Addon:GetSetting("showSummaryAfterCombat") then
        ns.Addon:ShowSummary(session.id)
    end

    return session
end

-- T014: HandleCombatLogEvent deleted — no active event registration (dead code).
-- Was the only caller of NormalizeCombatLogEvent (also deleted, T013).
-- Session data now sourced from DamageMeter + visible-unit state APIs.

function CombatTracker:HandleUnitSpellcastSucceeded(unitTarget, castGUID, spellId, castBarId)
    if unitTarget ~= "player" and unitTarget ~= "pet" then
        return
    end

    local session = self:GetCurrentSession()
    if (not session or session.state ~= "active") and self.playerInCombat then
        local preferredUnitToken = nil
        if ApiCompat.UnitExists("target") then
            preferredUnitToken = "target"
        elseif ApiCompat.UnitExists("focus") then
            preferredUnitToken = "focus"
        end
        session = self:EnsureSessionFromState(preferredUnitToken, unitTarget == "pet" and "pet_cast" or "player_cast")
    end
    if not session or session.state ~= "active" or not spellId then
        return
    end

    local eventRecord = {
        eventType = "cast",
        subEvent = "UNIT_SPELLCAST_SUCCEEDED",
        spellId = spellId,
        castBarId = castBarId,  -- non-secret cast sequence counter (12.0.0+)
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

    -- Step 4: Burst waste — player cast a major offensive into an active enemy defensive.
    if unitTarget == "player" then
        local spellInfo = ns.StaticPvpData and ns.StaticPvpData.GetSpellInfo(spellId)
        if spellInfo and spellInfo.isMajorOffensive and session._runtime then
            local primary = session.primaryOpponent
            local rt = session._runtime
            if primary and primary.guid then
                local enemyDefs = rt.enemyActiveDefensives[primary.guid]
                if enemyDefs and next(enemyDefs) ~= nil then
                    session.survival.burstWasteCount =
                        (session.survival.burstWasteCount or 0) + 1
                end
            end
        end
    end
end

function CombatTracker:HandleUnitAura(unitTarget, updateInfo)
    local session = self:GetCurrentSession()
    if not session or not ApiCompat.UnitExists(unitTarget) then
        return
    end
    if not Constants.TRACKED_UNITS[unitTarget]
        and not string.find(unitTarget, "^arena")
        and not string.find(unitTarget, "^nameplate%d+$")
    then
        return
    end

    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if not snapshotService then return end
    local actor = snapshotService:UpdateSessionActor(session, unitTarget, "unit_aura")
    if not actor or not actor.guid then
        return
    end

    self:RefreshSessionIdentity(session, unitTarget, "unit_aura")

    session.visibleAuras[actor.guid] = session.visibleAuras[actor.guid] or {}
    local auraState = session.visibleAuras[actor.guid]
    local timestampOffset = getSessionRelativeOffset(session)

    local function removeAuraState(auraInstanceId)
        local safeId = safeMakeKey(auraInstanceId)
        if not safeId then return end
        local previous = auraState[safeId]
        if previous and previous.spellId then
            self:CloseAuraWindow(session, actor.guid, previous.spellId, timestampOffset)
        end
        auraState[safeId] = nil
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
        -- Midnight arena: auraData fields (auraInstanceID, spellId) for arena
        -- opponent units may be secret values that crash on table-index.
        -- safeMakeKey() probes the value; returns it if safe or nil if secret.
        local safeInstanceID = safeMakeKey(auraData.auraInstanceID)
        if not safeInstanceID then return end
        local safeSpellId = safeMakeKey(auraData.spellId)  -- nil when secret

        local previous = auraState[safeInstanceID]
        local procLike = isProcCandidate(unitTarget, auraData)

        -- previous.spellId is always a safe value (stored via safeSpellId below).
        if previous and previous.spellId and safeSpellId and previous.spellId ~= safeSpellId then
            self:CloseAuraWindow(session, actor.guid, previous.spellId, timestampOffset)
            previous = nil
        end

        if safeSpellId and not previous then
            self:OpenAuraWindow(session, actor.guid, safeSpellId, timestampOffset, procLike, auraData.applications)
        elseif safeSpellId and previous then
            local ok, appsChanged = pcall(function()
                return (previous.applications or 0) ~= (auraData.applications or 0)
            end)
            if ok and appsChanged then
                local aggregate = self:EnsureAuraAggregate(session, safeSpellId)
                aggregate.refreshCount = aggregate.refreshCount + 1
            end
        end

        auraState[safeInstanceID] = {
            auraInstanceId = safeInstanceID,
            spellId = safeSpellId,
            applications = auraData.applications,
            isHelpful = auraData.isHelpful,
            sourceUnit = auraData.sourceUnit,
            isProc = procLike,
        }
        if safeSpellId then
            local aggregate = self:EnsureAuraAggregate(session, safeSpellId)
            -- auraData.applications may be secret; math.max uses comparison and
            -- would throw, so pcall-guard the entire update.
            pcall(function()
                aggregate.maxStacksObserved = math.max(
                    aggregate.maxStacksObserved, auraData.applications or 0)
            end)
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
                local safeHelpfulId = helpful.auraInstanceID and safeMakeKey(helpful.auraInstanceID)
                if safeHelpfulId then
                    seenAuraInstanceIds[safeHelpfulId] = true
                end
                applyAuraData(helpful)
            end
            if harmful then
                local safeHarmfulId = harmful.auraInstanceID and safeMakeKey(harmful.auraInstanceID)
                if safeHarmfulId then
                    seenAuraInstanceIds[safeHarmfulId] = true
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

function CombatTracker:HandleRestrictionStateChanged()
    local session = self:GetCurrentSession()
    if not session then return end
    local isPvPRestricted = ApiCompat.IsPvPMatchRestricted()
    local isCombatRestricted = ApiCompat.IsCombatRestricted()
    session.restrictionState = {
        pvpMatch = isPvPRestricted,
        combat = isCombatRestricted,
        lastUpdatedAt = Helpers.Now(),
    }
    ns.Addon:Trace("restriction.state_changed", {
        pvpMatch = isPvPRestricted,
        combat = isCombatRestricted,
    })
end

function CombatTracker:HandlePlayerRegenDisabled()
    self.playerInCombat = true
    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService then
        damageMeterService:MarkSessionStart()
    end
    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        session = self:EnsureSessionFromState(nil, "combat_start")
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

    -- Deferred import: if a session was finalized during combat (training
    -- dummy idle timeout), C_DamageMeter returned secret values. Now that
    -- combat has ended, re-import with real data and persist the update.
    local deferredSession = self._deferredImportSession
    if deferredSession then
        self._deferredImportSession = nil
        local damageMeterService = ns.Addon:GetModule("DamageMeterService")
        if damageMeterService then
            -- Wait for DM Expired session to settle before re-importing.
            scheduleAfter(DM_STABILIZATION_DELAY, function()
                local okReimport = xpcall(function()
                    if damageMeterService.CaptureCurrentSessionSnapshot then
                        damageMeterService:CaptureCurrentSessionSnapshot(deferredSession)
                    end
                    damageMeterService:ImportSession(deferredSession)
                    -- Read status after ImportSession populates importedTotals;
                    -- the `and` guard returns false (not nil) when importedTotals
                    -- is nil, which SetImportAuthority treats as a no-op sentinel.
                    local newStatus = (deferredSession.importedTotals ~= nil)
                        and deferredSession.importedTotals.importStatus
                        or nil
                    self:SetImportAuthority(deferredSession, newStatus)
                    -- Recompute metrics with actual damage data.
                    local okMetrics, metricsErr = xpcall(function()
                        ns.Metrics.ComputeDerivedMetrics(deferredSession)
                    end, debugstack)
                    if not okMetrics then
                        ns.Addon:Debug("Deferred import: metrics recompute failed: %s", tostring(metricsErr or "?"))
                    end
                    ns.Addon:GetModule("CombatStore"):PersistSession(deferredSession)
                    ns.Addon:Trace("damage_meter.deferred_import.success", {
                        damage = deferredSession.totals and deferredSession.totals.damageDone or 0,
                        context = deferredSession.context or "unknown",
                    })
                end, debugstack)
                if not okReimport then
                    ns.Addon:Trace("damage_meter.deferred_import.failed", {})
                end
            end)
        end
    end

    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        return
    end

    local damageMeterService = ns.Addon:GetModule("DamageMeterService")
    if damageMeterService and damageMeterService.CaptureCurrentSessionSnapshot then
        damageMeterService:CaptureCurrentSessionSnapshot(session)
    end

    -- T035: Configurable DamageMeter stabilization delay.  After PLAYER_REGEN_ENABLED
    -- fires we wait before finalizing so that C_DamageMeter data has time to settle.
    -- Context-specific overrides extend the default for game modes where data arrives
    -- later (world PvP) or where arena/BG post-match events need extra time.
    local delay = DM_STABILIZATION_DELAY
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
        if Enum and Enum.DamageMeterType and (
            damageMeterType == Enum.DamageMeterType.DamageDone
            or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken
            or damageMeterType == Enum.DamageMeterType.HealingDone
        ) then
            self:ScheduleFinalize(session, 0.2, "damage_meter_event")
        end
    end

    -- T021: Post-finalization one-shot re-import — if a session was finalized
    -- without authoritative data and this DM event arrives within the 10-second
    -- watch window, schedule one additional import attempt.
    local damageMeterSvc = ns.Addon:GetModule("DamageMeterService")
    if damageMeterSvc
        and damageMeterSvc._postFinalizeWatchSession
        and not damageMeterSvc._postFinalizeRetried
    then
        local watchSession = damageMeterSvc._postFinalizeWatchSession
        local watchAge = damageMeterSvc._postFinalizeWatchAt
            and (Helpers.Now() - damageMeterSvc._postFinalizeWatchAt)
            or math.huge
        if watchAge <= 10 then
            -- Clear watch refs immediately so the 10-second cleanup timer never holds a stale
            -- session reference in the case where a new session overwrites the watch state
            -- before the timer fires.
            damageMeterSvc._postFinalizeRetried     = true
            damageMeterSvc._postFinalizeWatchSession = nil
            damageMeterSvc._postFinalizeWatchAt      = nil
            scheduleAfter(0.5, function()
                -- Guard: don't re-import if the session already has authoritative data
                -- (another path may have succeeded between clearing watch refs and this callback).
                local existingAuth = watchSession.importedTotals and watchSession.importedTotals.totalAuthority
                if existingAuth == "authoritative" then return end

                local store = ns.Addon:GetModule("CombatStore")
                if store and damageMeterSvc.ImportSession then
                    local ok = xpcall(function()
                        damageMeterSvc:ImportSession(watchSession)
                        self:SetImportAuthority(watchSession, watchSession.importedTotals and watchSession.importedTotals.importStatus)
                        store:PersistSession(watchSession)
                    end, debugstack)
                    if not ok then
                        ns.Addon:Trace("damage_meter.post_finalize_retry.error", {})
                    end
                end
            end)
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
        local snapshotService = ns.Addon:GetModule("SnapshotService")
        if snapshotService then
            snapshotService:TryRefreshDeferredSnapshot("spec_changed")
        end
    end
end

function CombatTracker:HandlePlayerPvpTalentUpdate()
    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if snapshotService then
        snapshotService:TryRefreshDeferredSnapshot("pvp_talent_update")
    end
end

function CombatTracker:HandlePlayerEnteringWorld()
    ns.Addon:TryRegisterSlashCommands()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier then
        classifier:RefreshZone()
    end
end

function CombatTracker:HandleZoneChanged()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier then
        classifier:RefreshZone()
    end
end

function CombatTracker:RefreshVisibleUnitState(unitToken, source)
    if not unitToken then
        return
    end

    local session = self:GetCurrentSession()
    if (not session or session.state ~= "active") and self.playerInCombat then
        session = self:EnsureSessionFromState(unitToken, source)
    end
    if not session or session.state ~= "active" or not ApiCompat.UnitExists(unitToken) then
        return
    end

    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if snapshotService then
        local actor = snapshotService:UpdateSessionActor(session, unitToken, source)
        if shouldUseAsPrimaryOpponent(actor, session.primaryOpponent) then
            session.primaryOpponent = actor
        end
    end

    self:RefreshSessionIdentity(session, unitToken, source)
    if self.playerInCombat then
        self:InvalidatePendingFinalize(session)
    end
end

function CombatTracker:HandlePlayerTargetChanged()
    self:RefreshVisibleUnitState("target", "target_changed")
end

function CombatTracker:HandlePlayerFocusChanged()
    self:RefreshVisibleUnitState("focus", "focus_changed")
end

function CombatTracker:HandleNamePlateUnitAdded(unitToken)
    self:RefreshVisibleUnitState(unitToken, "nameplate_added")
end

function CombatTracker:HandleUnitPet(unitId)
    if not unitId then
        return
    end
    local petToken = unitId .. "pet"
    if ApiCompat.UnitExists(petToken) then
        self:RefreshVisibleUnitState(petToken, "unit_pet")
    end
end

function CombatTracker:HandleTraitConfigListUpdated()
    local snapshotService = ns.Addon:GetModule("SnapshotService")
    if snapshotService then
        snapshotService:HandleTraitConfigListUpdated()
    end
end

function CombatTracker:HandlePlayerJoinedPvpMatch()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    local context = ApiCompat.IsMatchConsideredArena() and Constants.CONTEXT.ARENA or Constants.CONTEXT.BATTLEGROUND
    local subcontext = nil
    if classifier then
        subcontext = context == Constants.CONTEXT.ARENA and classifier:ResolveArenaSubcontext() or classifier:ResolveBattlegroundSubcontext()
    end
    self:CreateOrRefreshMatch(context, subcontext)

    -- Begin tracking arena round identity. ArenaRoundTracker owns match state
    -- independently of the combat session so prep and inter-round data is not lost.
    if context == Constants.CONTEXT.ARENA then
        local art = ns.Addon:GetModule("ArenaRoundTracker")
        if art then art:BeginMatch(context, subcontext) end
    end
end

function CombatTracker:HandlePvpMatchActive()
    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.state = "active"
        matchRecord.activatedAt = ApiCompat.GetServerTime()
    end
    -- Open a round in the ArenaRoundTracker. This is the authoritative signal
    -- that gates (round began) are now reliable.
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art then art:BeginRound("pvp_match_active") end

    -- T088: Hide scout overlay when match goes active
    local scoutView = ns.Addon:GetModule("ArenaScoutView")
    if scoutView then scoutView:Hide() end

    -- T013: Capture pre-match rating snapshot on matchRecord.metadata so it
    -- survives late session creation. PVP_MATCH_ACTIVE can fire before the
    -- combat session exists (common in Midnight where session creation is
    -- triggered by the first damage event). Storing on match metadata allows
    -- CreateSession (T014) to inherit the snapshot regardless of timing.
    local isRated = ApiCompat.DoesMatchOutcomeAffectRating()
    local preMatchSnapshot
    if isRated then
        local ratedInfo = ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
        if ratedInfo then
            preMatchSnapshot = {
                isRated = true,
                before = {
                    personalRating    = ratedInfo.personalRating,
                    bestSeasonRating  = ratedInfo.bestSeasonRating,
                    seasonPlayed      = ratedInfo.seasonPlayed,
                    seasonWon         = ratedInfo.seasonWon,
                    weeklyPlayed      = ratedInfo.weeklyPlayed,
                    weeklyWon         = ratedInfo.weeklyWon,
                },
            }
        else
            preMatchSnapshot = { isRated = true, missingReason = "api_unavailable" }
        end
    else
        preMatchSnapshot = { isRated = false, missingReason = "not_rated" }
    end

    if matchRecord then
        matchRecord.metadata = matchRecord.metadata or {}
        matchRecord.metadata.preMatchRatingSnapshot = preMatchSnapshot
    end

    -- T015: When the combat session already exists at PVP_MATCH_ACTIVE time,
    -- populate it directly from the snapshot (no regression from prior behavior).
    local session = self:GetCurrentSession()
    if session and preMatchSnapshot then
        session.isRated = preMatchSnapshot.isRated
        if preMatchSnapshot.isRated then
            session.ratingSnapshot = session.ratingSnapshot or {}
            if preMatchSnapshot.before then
                session.ratingSnapshot.before = preMatchSnapshot.before
            elseif preMatchSnapshot.missingReason then
                session.ratingSnapshot.missingReason = preMatchSnapshot.missingReason
            end
        else
            session.ratingSnapshot = { missingReason = preMatchSnapshot.missingReason or "not_rated" }
        end
    end
end

function CombatTracker:HandlePvpMatchComplete(winner, duration)
    -- Arena result from PvP match state APIs (no CLEU dependency).
    -- GetActiveMatchWinner() and GetBattlefieldArenaFaction() are the sole
    -- sources for win/loss/draw resolution.  The event args (winner, duration)
    -- are NOT used — Blizzard's own PVP UI likewise queries C_PvP directly.
    -- GetActiveMatchWinner() returns an integer faction index (0 = Horde,
    -- 1 = Alliance); GetBattlefieldArenaFaction() returns the local player's
    -- team index.  Compare to determine win/loss/draw.
    local winnerTeam   = ApiCompat.GetActiveMatchWinner()
    local playerTeam   = ApiCompat.GetBattlefieldArenaFaction()

    local matchResult, sessionResult
    if winnerTeam ~= nil and playerTeam ~= nil then
        local enemyTeam = (playerTeam + 1) % 2
        if winnerTeam == playerTeam then
            matchResult   = Constants.MATCH_RESULT.WIN
            sessionResult = Constants.SESSION_RESULT.WON
        elseif winnerTeam == enemyTeam then
            matchResult   = Constants.MATCH_RESULT.LOSS
            sessionResult = Constants.SESSION_RESULT.LOST
        else
            matchResult   = Constants.MATCH_RESULT.DRAW
            sessionResult = Constants.SESSION_RESULT.DRAW
        end
    else
        matchResult   = Constants.MATCH_RESULT.UNKNOWN
        sessionResult = Constants.SESSION_RESULT.UNKNOWN
    end

    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.state       = "complete"
        matchRecord.completedAt = ApiCompat.GetServerTime()
        matchRecord.result      = matchResult
        matchRecord.metadata    = matchRecord.metadata or {}
        -- Store raw event args as fallback reference; do not use for result.
        matchRecord.metadata.winnerArg  = winner
        matchRecord.metadata.winnerTeam = winnerTeam
        matchRecord.metadata.playerTeam = playerTeam
        matchRecord.metadata.duration   = duration
    end

    local session = self:GetCurrentSession()
    if session then
        session.result = sessionResult
    end

    -- Task 1.2: capture rating snapshot after match
    if session and session.isRated then
        local ratedInfo = ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
        session.ratingSnapshot = session.ratingSnapshot or {}
        if ratedInfo then
            session.ratingSnapshot.after = {
                personalRating    = ratedInfo.personalRating,
                bestSeasonRating  = ratedInfo.bestSeasonRating,
                seasonPlayed      = ratedInfo.seasonPlayed,
                seasonWon         = ratedInfo.seasonWon,
                weeklyPlayed      = ratedInfo.weeklyPlayed,
                weeklyWon         = ratedInfo.weeklyWon,
            }
        elseif not session.ratingSnapshot.missingReason then
            session.ratingSnapshot.missingReason = "api_unavailable"
        end
    end

    -- Defer score and rewards harvest to HandlePvpMatchInactive.
    -- C_PvP.GetScoreInfo is flagged SecretInActivePvPMatch = true in Midnight:
    -- calling it before the match is truly inactive returns secret values that
    -- trigger ADDON_ACTION_BLOCKED the moment any field is accessed.  Store a
    -- reference here; HarvestPostMatchData runs in the INACTIVE handler, which
    -- fires after the match leaves the active state and scores are accessible.
    if session then
        self._pendingPostMatchSession = session
    end

    -- Close the active round with the resolved winner.
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art then art:EndRound("pvp_match_complete", winnerTeam, duration) end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Post-match data harvest (scores, rewards, team rating).
-- Called from HandlePvpMatchInactive — AFTER the match leaves the active state
-- so that C_PvP.GetScoreInfo (SecretInActivePvPMatch) returns real values.
-- All fields are sanitized before use to defend against any residual secrets.
-- ──────────────────────────────────────────────────────────────────────────────
function CombatTracker:HarvestPostMatchData(session)
    if not session then return end

    -- Score harvest.
    local scores = {}
    local i = 1
    while true do
        local scoreInfo = ApiCompat.GetScoreInfo(i)
        if not scoreInfo then break end
        scores[#scores + 1] = {
            name         = ApiCompat.SanitizeString(scoreInfo.name),
            guid         = ApiCompat.SanitizeString(scoreInfo.guid),
            damageDone   = ApiCompat.SanitizeNumber(scoreInfo.damageDone),
            healingDone  = ApiCompat.SanitizeNumber(scoreInfo.healingDone),
            killingBlows = ApiCompat.SanitizeNumber(scoreInfo.killingBlows),
            deaths       = ApiCompat.SanitizeNumber(scoreInfo.deaths),
            rating       = ApiCompat.SanitizeNumber(scoreInfo.rating),
            ratingChange = ApiCompat.SanitizeNumber(scoreInfo.ratingChange),
            prematchMMR  = ApiCompat.SanitizeNumber(scoreInfo.prematchMMR),
            mmrChange    = ApiCompat.SanitizeNumber(scoreInfo.mmrChange),
            postmatchMMR = ApiCompat.SanitizeNumber(scoreInfo.postmatchMMR),
            talentSpec   = ApiCompat.SanitizeNumber(scoreInfo.talentSpec),
        }
        i = i + 1
        if i > 40 then break end
    end

    if #scores > 0 then
        session.postMatchScores = scores

        -- Backfill actor and opponent names from scoreboard.
        -- In restricted PvP sessions, srcName/dstName are secret and never
        -- stored.  The scoreboard is the authoritative non-secret name source.
        for _, entry in ipairs(scores) do
            if entry.guid and entry.name and session.actors then
                local actor = session.actors[entry.guid]
                if actor and not actor.name then
                    actor.name = entry.name
                end
            end
        end

        -- Backfill primaryOpponent name if still missing.
        local po = session.primaryOpponent
        if po and not po.name and po.guid then
            for _, entry in ipairs(scores) do
                if entry.guid == po.guid and entry.name then
                    po.name = entry.name
                    break
                end
            end
        end

        -- If primaryOpponent is still nil but we have arena slots with
        -- GUID → score mappings, pick the best opponent from scores.
        if not session.primaryOpponent and session.arena then
            for _, slot in pairs(session.arena.slots or {}) do
                if slot.guid then
                    for _, entry in ipairs(scores) do
                        if entry.guid == slot.guid and entry.name then
                            local myGuid = ApiCompat.GetPlayerGUID()
                            if entry.guid ~= myGuid then
                                session.primaryOpponent = session.actors and session.actors[slot.guid] or {
                                    guid      = slot.guid,
                                    name      = entry.name,
                                    isPlayer  = true,
                                    isHostile = true,
                                }
                                break
                            end
                        end
                    end
                    if session.primaryOpponent then break end
                end
            end
        end

        -- Backfill arena slot names from scoreboard.
        if session.arena then
            for _, slot in pairs(session.arena.slots or {}) do
                if slot.guid and not slot.name then
                    for _, entry in ipairs(scores) do
                        if entry.guid == slot.guid then
                            slot.name = entry.name
                            break
                        end
                    end
                end
            end
        end

        -- Team-level rating info.
        local teamInfo0 = ApiCompat.GetTeamInfo(0)
        local teamInfo1 = ApiCompat.GetTeamInfo(1)
        if teamInfo0 or teamInfo1 then
            session.teamRatingInfo = { team0 = teamInfo0, team1 = teamInfo1 }
        end

        -- BG objective stats.
        if session.context == Constants.CONTEXT.BATTLEGROUND then
            local myGuid = ApiCompat.GetPlayerGUID()
            for _, entry in ipairs(scores) do
                if entry.guid == myGuid then
                    local bgStats = {}
                    local idx = 1
                    while true do
                        local fullInfo = ApiCompat.GetScoreInfo(idx)
                        if not fullInfo then break end
                        local fullGuid = ApiCompat.SanitizeString(fullInfo.guid)
                        if fullGuid == myGuid and fullInfo.stats then
                            for _, stat in ipairs(fullInfo.stats) do
                                bgStats[#bgStats + 1] = {
                                    pvpStatID    = ApiCompat.SanitizeNumber(stat.pvpStatID),
                                    pvpStatValue = ApiCompat.SanitizeNumber(stat.pvpStatValue),
                                }
                            end
                        end
                        idx = idx + 1
                        if idx > 40 then break end
                    end
                    if #bgStats > 0 then session.bgStats = bgStats end
                    break
                end
            end
        end
    end

    -- Rating snapshot backfill from scoreInfo.
    -- GetPVPActiveMatchPersonalRatedInfo is NOT SecretInActivePvPMatch, so it
    -- may have returned nil at COMPLETE time if the match server hadn't settled.
    -- Now that we are INACTIVE, try it once more as a safety net.  Also derive
    -- rating before/after directly from scoreInfo.rating + ratingChange, which
    -- is authoritative and always present for rated matches.
    if session.isRated then
        -- Try refreshing ratingSnapshot.after via the personal-rated API.
        if not (session.ratingSnapshot and session.ratingSnapshot.after) then
            local ratedInfo = ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
            if ratedInfo and ratedInfo.personalRating and ratedInfo.personalRating > 0 then
                session.ratingSnapshot = session.ratingSnapshot or {}
                session.ratingSnapshot.after = {
                    personalRating   = ratedInfo.personalRating,
                    bestSeasonRating = ratedInfo.bestSeasonRating,
                    seasonPlayed     = ratedInfo.seasonPlayed,
                    seasonWon        = ratedInfo.seasonWon,
                    weeklyPlayed     = ratedInfo.weeklyPlayed,
                    weeklyWon        = ratedInfo.weeklyWon,
                }
            end
        end

        -- Fall back to scoreInfo.rating / ratingChange for this player when the
        -- personal-rated API is still unavailable (e.g. disconnected resync).
        local myGuid = ApiCompat.GetPlayerGUID()
        for _, entry in ipairs(scores) do
            if entry.guid == myGuid then
                local scoreRating = entry.rating
                if scoreRating and scoreRating > 0 then
                    session.ratingSnapshot = session.ratingSnapshot or {}
                    if not session.ratingSnapshot.after then
                        session.ratingSnapshot.after = { personalRating = scoreRating }
                    end
                    if not session.ratingSnapshot.before then
                        local change = entry.ratingChange or 0
                        session.ratingSnapshot.before = { personalRating = scoreRating - change }
                    end
                end
                break
            end
        end
    end

    -- Post-match rewards.
    local items      = ApiCompat.GetPostMatchItemRewards()
    local currencies = ApiCompat.GetPostMatchCurrencyRewards()
    local weeklyChest = ApiCompat.GetWeeklyChestInfo()
    if items or currencies or weeklyChest then
        session.postMatchRewards = {
            items       = items,
            currencies  = currencies,
            weeklyChest = weeklyChest,
        }
    end
end

function CombatTracker:HandlePvpMatchInactive()
    -- Harvest scores and rewards BEFORE finalizing.  GetScoreInfo is
    -- SecretInActivePvPMatch — safe to call only after this event fires.
    local pendingSession = self._pendingPostMatchSession
    self._pendingPostMatchSession = nil
    if pendingSession then
        local ok, err = xpcall(function()
            self:HarvestPostMatchData(pendingSession)
        end, debugstack)
        if not ok then
            ns.Addon:Warn("HarvestPostMatchData failed: " .. tostring(err or "?"))
        end
    end

    local session = self:GetCurrentSession()
    if session then
        self:FinalizeSession(session.result ~= Constants.SESSION_RESULT.UNKNOWN and session.result or nil, "match_inactive")
    end

    -- Close the match-level tracker state.
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art then art:EndMatch() end

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
    -- Capture spec data into ArenaRoundTracker so it is available for
    -- round key building even before any unit frames become visible.
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art then art:CapturePrepSpecs() end

    -- Task 4.4: Pre-match prep advisory — print compact matchup data for each enemy spec.
    local showAdvisory = ns.Addon.GetSetting and ns.Addon:GetSetting("showPreMatchAdvisory")
    if showAdvisory ~= false and art then
        local strategyEngine = ns.Addon:GetModule("StrategyEngine")
        if strategyEngine and strategyEngine.GetCounterGuide then
            local store = ns.Addon:GetModule("CombatStore")
            local characterKey = store and store:GetCurrentCharacterKey() or nil
            local snapshot = ns.Addon:GetLatestPlayerSnapshot()
            local buildHash = snapshot and snapshot.buildHash or nil
            local slots = art:GetSlots()
            local printed = false
            for _, slot in pairs(slots or {}) do
                local specId = slot.prepSpecId
                if specId then
                    local guide = strategyEngine.GetCounterGuide(specId, buildHash, characterKey)
                    if guide then
                        local specLabel = guide.specName or slot.prepSpecName or "Unknown"
                        local wrLabel = guide.historicalWinRate
                            and string.format("%.0f%% WR", guide.historicalWinRate * 100)
                            or "no history"
                        local archLabel = guide.archetypeLabel ~= "unknown" and guide.archetypeLabel or nil
                        local hint = guide.recommendedActions and guide.recommendedActions[1] or nil
                        local parts = { string.format("[CA] %s (%s)", specLabel, wrLabel) }
                        if archLabel then parts[#parts + 1] = archLabel end
                        if hint then parts[#parts + 1] = hint end
                        ns.Addon:Print(table.concat(parts, " — "))
                        printed = true
                    end
                end
            end
            if not printed then
                ns.Addon:Trace("advisory.skip", { reason = "no_resolved_specs" })
            end
        end
    end

    -- T088: Build scout card and show overlay
    local scoutService = ns.Addon:GetModule("ArenaScoutService")
    local scoutView = ns.Addon:GetModule("ArenaScoutView")
    if scoutService and scoutView and art then
        local store = ns.Addon:GetModule("CombatStore")
        local aggregates = store and store:GetAggregates() or {}
        local slots = art:GetSlots()
        local prepOpponents = {}
        for slotIndex, slot in pairs(slots) do
            prepOpponents[slotIndex] = slot
        end
        local ok, scoutCard = pcall(scoutService.BuildScoutCard, scoutService, matchRecord, prepOpponents, aggregates)
        if ok and scoutCard then
            scoutView:Show(scoutCard)
        end
    end
end

function CombatTracker:HandleArenaOpponentUpdate(unitToken, updateReason)
    -- IMPORTANT: ARENA_OPPONENT_UPDATE fires during prep phase, before any
    -- combat session exists. The previous guard (if session then) dropped all
    -- prep-phase roster data — the most reliable source of enemy spec/class.
    -- Always update match-level state; gate session-level work on session.
    local snapshotService = ns.Addon:GetModule("SnapshotService")

    local matchRecord = self:GetCurrentMatch()
    if matchRecord then
        matchRecord.metadata = matchRecord.metadata or {}
        matchRecord.metadata.opponentSlots = matchRecord.metadata.opponentSlots or {}
        -- Record slot visibility state so ArenaRoundTracker can reconcile GUIDs.
        matchRecord.metadata.opponentSlots[unitToken] = {
            unitToken   = unitToken,
            reason      = updateReason,
            updatedAt   = ApiCompat.GetServerTime(),
            guid        = ApiCompat.GetUnitGUID(unitToken),
            name        = ApiCompat.GetUnitName(unitToken),
        }
    end

    local session = self:GetCurrentSession()
    if session then
        if snapshotService then
            snapshotService:UpdateSessionActor(session, unitToken, "arena_opponent")
        end
    end

    -- Forward to ArenaRoundTracker unconditionally — it manages slot state even
    -- before and between sessions (prep phase, inter-round).
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    if art then art:HandleArenaOpponentUpdate(unitToken, updateReason) end
end

-- T034: DUEL_REQUESTED only sets pending flag — does NOT create a session.
-- Session creation waits for DUEL_INBOUNDS (confirms duel accepted).
function CombatTracker:HandleDuelRequested(playerName)
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier then
        classifier:SetPendingDuel(playerName, false)
    end
    ns.Addon:Trace("duel.requested", { opponent = playerName })
end

function CombatTracker:HandleDuelToTheDeathRequested(playerName)
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier then
        classifier:SetPendingDuel(playerName, true)
    end
    ns.Addon:Trace("duel.to_the_death_requested", { opponent = playerName })
end

-- T034: DUEL_INBOUNDS is the trigger for duel session creation. This fires
-- only after both players accept. Canceled duel requests (no DUEL_INBOUNDS)
-- produce zero stored sessions.
function CombatTracker:HandleDuelInbounds()
    local classifier = ns.Addon:GetModule("SessionClassifier")
    local pending = classifier and classifier:GetPendingDuel() or nil

    -- Mark pending duel as active so ResolveContextFromState returns DUEL context
    if classifier and pending then
        pending.state = "active"
    end

    local session = self:GetCurrentSession()
    if not session or session.state ~= "active" then
        local subcontext = pending and pending.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil

        local damageMeterService = ns.Addon:GetModule("DamageMeterService")
        if damageMeterService then
            damageMeterService:MarkSessionStart()
        end

        session = self:CreateSession(Constants.CONTEXT.DUEL, subcontext, "duel_inbounds")

        local snapshotService = ns.Addon:GetModule("SnapshotService")
        if snapshotService then
            if ApiCompat.UnitExists("target") then
                local actor = snapshotService:UpdateSessionActor(session, "target", "duel_start")
                if actor then
                    session.primaryOpponent = actor
                end
            end
            if ApiCompat.UnitExists("focus") then
                snapshotService:UpdateSessionActor(session, "focus", "duel_start")
            end
        end

        -- Persist the duel opponent name from the DUEL_REQUESTED event so
        -- ResolveOpponentName can use it as a last-resort fallback when no
        -- snapshot or DamageMeter data is available.
        if pending and pending.opponentName then
            session.duelOpponentName = pending.opponentName
            -- Also seed primaryOpponent if the snapshot path missed it
            if not session.primaryOpponent then
                session.primaryOpponent = {
                    name = pending.opponentName,
                    guid = pending.opponentGuid,
                    isPlayer = true,
                    isHostile = true,
                }
            elseif not session.primaryOpponent.name then
                session.primaryOpponent.name = pending.opponentName
            end
        end

        self:RefreshSessionIdentity(session, "target", "duel_inbounds")
        ns.Addon:Trace("duel.session_created", {
            sessionId = session.id,
            opponent = pending and pending.opponentName or "unknown",
        })
    else
        -- Session already exists (e.g. from PLAYER_REGEN_DISABLED) — promote to duel.
        if classifier then
            local subcontext = pending and pending.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil
            classifier:PromoteSessionIdentity(
                session,
                Constants.CONTEXT.DUEL,
                subcontext,
                95,
                "duel_inbounds",
                "duel_confirmed_inbounds",
                nil
            )
        end
        -- Backfill opponent name from pending duel data for promoted sessions.
        if pending and pending.opponentName then
            session.duelOpponentName = session.duelOpponentName or pending.opponentName
            if not session.primaryOpponent then
                session.primaryOpponent = {
                    name = pending.opponentName,
                    guid = pending.opponentGuid,
                    isPlayer = true,
                    isHostile = true,
                }
            elseif not session.primaryOpponent.name then
                session.primaryOpponent.name = pending.opponentName
            end
        end
    end

    if session then
        self:InvalidatePendingFinalize(session)
    end
end

function CombatTracker:HandleDuelOutOfBounds()
    local session = self:GetCurrentSession()
    if session then
    end
end

function CombatTracker:HandleDuelFinished()
    local session = self:GetCurrentSession()
    if session and session.context == Constants.CONTEXT.DUEL then
        self:FinalizeSession(nil, "duel_finished")
    end
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier then
        classifier:ClearPendingDuel()
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Task 1.3: Arena CC Tracking
-- ──────────────────────────────────────────────────────────────────────────────

function CombatTracker:HandleArenaCrowdControlUpdate(unitTarget, spellId)
    -- ── Branch A: CC applied to the player ───────────────────────────────────
    if unitTarget == "player" then
        local session = self:GetCurrentSession()
        if not session then return end

        local ccSpellId, startTime, duration = ApiCompat.GetArenaCrowdControlInfo("player")
        if not ccSpellId or ccSpellId == 0 then return end
        if not duration or duration <= 0 then return end

        local startOffset = getSessionRelativeOffset(session)

        session.ccReceived = session.ccReceived or {}
        local entry = {
            spellId     = ccSpellId,
            sourceToken = nil, -- API does not expose CC source
            startTime   = startTime,
            duration    = duration,
            startOffset = startOffset,
        }
        session.ccReceived[#session.ccReceived + 1] = entry

        ns.Addon:Trace("cc.received", {
            spellId     = ccSpellId,
            duration    = duration,
            startOffset = startOffset,
        })
        return
    end

    -- ── Branch B: Kill window tracking — enemy healer CCed (Task 5) ──────────
    -- Only process enemy arena slots (arena1..arena5).
    if not unitTarget or not unitTarget:match("^arena%d$") then return end

    local session = self:GetCurrentSession()
    if not session or not session._runtime then return end
    if session.context ~= Constants.CONTEXT.ARENA then return end

    -- Determine if this arena slot is a healer.
    local slotIndex = tonumber(unitTarget:match("%d"))
    local art = ns.Addon:GetModule("ArenaRoundTracker")
    local slots = art and art:GetSlots() or {}
    local slotData = slots[slotIndex]
    local specArchetype = slotData and slotData.prepSpecId
        and ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(slotData.prepSpecId)
    if not specArchetype or specArchetype.role ~= "HEALER" then return end

    -- Read current CC state for this enemy unit.
    local ccSpellId, _, duration = ApiCompat.GetArenaCrowdControlInfo(unitTarget)

    local rt  = session._runtime
    local now = getSessionRelativeOffset(session)

    local isInCC = ccSpellId and ccSpellId ~= 0 and duration and duration > 0

    if isInCC then
        -- Open a kill window if not already open.
        -- Only one kill window tracked at a time; second healer entering CC during
        -- an open window is intentionally ignored (2v2/3v3 brackets only have one healer).
        if not rt.killWindowOpen then
            rt.killWindowOpen       = true
            rt.killWindowStart      = now
            rt.killWindowHealerSlot = slotIndex
            ns.Addon:Trace("kill_window.opened", {
                healerSlot = slotIndex,
                openedAt   = now,
            })
        end
    else
        -- CC ended: close the kill window (not converted).
        if rt.killWindowOpen then
            session.killWindows[#session.killWindows + 1] = {
                openedAt   = rt.killWindowStart,
                closedAt   = now,
                healerSlot = rt.killWindowHealerSlot,
                converted  = false,
            }
            ns.Addon:Trace("kill_window.closed", {
                healerSlot = rt.killWindowHealerSlot,
                openedAt   = rt.killWindowStart,
                closedAt   = now,
                converted  = false,
            })
            rt.killWindowOpen       = false
            rt.killWindowStart      = nil
            rt.killWindowHealerSlot = nil
        end
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Task 2.2: Enhanced CC Tracking via C_LossOfControl
-- Works in ALL contexts (arena, BG, duel, world PvP) — not arena-only.
-- ──────────────────────────────────────────────────────────────────────────────

function CombatTracker:HandleLossOfControlAdded(unitTarget, effectIndex)
    -- Only track CC applied to the player.
    if unitTarget and unitTarget ~= "player" then return end

    local session = self:GetCurrentSession()
    if not session then return end

    -- Query the LoC data from the API.
    if not C_LossOfControl or not C_LossOfControl.GetActiveLossOfControlDataByUnit then return end

    local ok, locData = pcall(C_LossOfControl.GetActiveLossOfControlDataByUnit, "player", effectIndex)
    if not ok or not locData then return end

    local startOffset = getSessionRelativeOffset(session)

    session.lossOfControl = session.lossOfControl or {}
    if session.lossOfControl == false then session.lossOfControl = {} end

    local entry = {
        locType          = locData.locType or "UNKNOWN",
        spellId          = locData.spellID,
        displayText      = locData.displayText,
        iconTexture      = locData.iconTexture,
        startTime        = locData.startTime,
        timeRemaining    = locData.timeRemaining,
        duration         = locData.duration or 0,
        lockoutSchool    = locData.lockoutSchool,
        priority         = locData.priority,
        auraInstanceID   = locData.auraInstanceID,
        startOffset      = startOffset,
    }
    session.lossOfControl[#session.lossOfControl + 1] = entry

    ns.Addon:Trace("loc.added", {
        locType  = locData.locType or "?",
        spellId  = locData.spellID or 0,
        duration = locData.duration or 0,
    })

    -- Track CC on arena opponents (C_LossOfControl.GetActiveLossOfControlDataByUnit)
    if session and session.context == Constants.CONTEXT.ARENA and session._runtime then
        session._runtime.enemyCC = session._runtime.enemyCC or {}
        for i = 1, 5 do
            local unitToken = "arena" .. i
            if ApiCompat.UnitExists(unitToken) then
                local count = ApiCompat.GetActiveLossOfControlDataCount(unitToken)
                for idx = 1, (count or 0) do
                    local enemyLocData = ApiCompat.GetActiveLossOfControlData(unitToken, idx)
                    if enemyLocData and enemyLocData.spellID then
                        local key = unitToken .. ":" .. tostring(enemyLocData.spellID)
                        if not session._runtime.enemyCC[key] then
                            session._runtime.enemyCC[key] = {
                                unitToken = unitToken,
                                spellID = enemyLocData.spellID,
                                locType = enemyLocData.locType,
                                startTime = enemyLocData.startTime,
                                duration = enemyLocData.duration,
                                recordedAt = Helpers.Now(),
                            }
                        end
                    end
                end
            end
        end
    end
end

function CombatTracker:HandleLossOfControlUpdate(unitTarget)
    -- Informational; we capture state at ADDED time. No action needed.
end

function CombatTracker:HandlePlayerControlLost()
    local session = self:GetCurrentSession()
    if not session then return end
    session._playerControlLostAt = getSessionRelativeOffset(session)
end

function CombatTracker:HandlePlayerControlGained()
    local session = self:GetCurrentSession()
    if not session then return end
    session._playerControlLostAt = nil
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

        -- Health-delta sampling for training dummy damage estimation.
        -- C_DamageMeter may not produce usable data for dummy sessions
        -- (SecretWhenInCombat during in-combat finalization). Track the
        -- target's health changes as a last-resort damage approximation.
        if session.context == Constants.CONTEXT.TRAINING_DUMMY
            and self.playerInCombat
            and ApiCompat.UnitExists("target")
        then
            local rt = session._runtime
            if rt then
                local currentHealth = UnitHealth("target") or 0
                local maxHealth = UnitHealthMax("target") or 0
                if not rt.healthDelta then
                    rt.healthDelta = {
                        totalDamageEstimate = 0,
                        lastHealth = currentHealth,
                        maxHealth = maxHealth,
                        samples = 0,
                    }
                end
                local hd = rt.healthDelta
                if hd.lastHealth > 0 and currentHealth > 0 then
                    local delta = hd.lastHealth - currentHealth
                    -- Positive delta = damage dealt; ignore negative (dummy reset/heal).
                    -- Also handle dummy health resetting to max (wrap-around).
                    if delta > 0 and delta < (maxHealth * 0.5) then
                        hd.totalDamageEstimate = hd.totalDamageEstimate + delta
                        hd.samples = hd.samples + 1
                    end
                end
                hd.lastHealth = currentHealth
                hd.maxHealth = maxHealth
            end
        end

        -- Periodic DR state snapshot (every 5s for arena sessions)
        if session.context == Constants.CONTEXT.ARENA and session._runtime then
            local rt = session._runtime
            rt.lastDRSnapshotAt = rt.lastDRSnapshotAt or 0
            if (now - rt.lastDRSnapshotAt) >= 5 then
                rt.lastDRSnapshotAt = now
                rt.drSnapshots = rt.drSnapshots or {}
                local snapshot = { t = getSessionRelativeOffset(session), units = {} }
                local art = ns.Addon:GetModule("ArenaRoundTracker")
                if art and art.GetDiminishState then
                    for i = 1, 5 do
                        local unitToken = "arena" .. i
                        if ApiCompat.UnitExists(unitToken) then
                            local drState = art:GetDiminishState(unitToken)
                            if drState then
                                snapshot.units[unitToken] = drState
                            end
                        end
                    end
                end
                if next(snapshot.units) then
                    rt.drSnapshots[#rt.drSnapshots + 1] = snapshot
                end
            end
        end

        if session.pendingFinalizeAt and not self.playerInCombat and now >= session.pendingFinalizeAt then
            self:FinalizeSession(nil, "regen_end")
            return
        end

        -- Training dummy combat can linger after the pull ends, which would leave
        -- the session unpersisted forever. Allow idle dummy sessions to finalize
        -- in-combat, then queue a deferred DM import for after combat ends via
        -- HandlePlayerRegenEnabled (C_DamageMeter returns secret values in combat).
        local canTimeoutWhileInCombat = session.context == Constants.CONTEXT.TRAINING_DUMMY
        if session.lastRelevantAt and (not self.playerInCombat or canTimeoutWhileInCombat) and (now - session.lastRelevantAt) >= timeout then
            self:FinalizeSession(nil, "timeout")
        end
    end

    if ns.Addon.runtime.summaryOpenAt and Helpers.Now() >= ns.Addon.runtime.summaryOpenAt then
        ns.Addon.runtime.summaryOpenAt = nil
    end
end

ns.Addon:RegisterModule("CombatTracker", CombatTracker)
