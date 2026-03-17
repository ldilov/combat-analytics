local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local DamageMeterService = {}

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

local function sortSessionsById(sessions)
    table.sort(sessions, function(left, right)
        return (left.sessionID or 0) < (right.sessionID or 0)
    end)
    return sessions
end

local function sortSessionsByIdDesc(sessions)
    table.sort(sessions, function(left, right)
        return (left.sessionID or 0) > (right.sessionID or 0)
    end)
    return sessions
end

local function isDamageMeterEnabled()
    if GetCVarBool then
        return GetCVarBool("damageMeterEnabled")
    end
    if GetCVar then
        return GetCVar("damageMeterEnabled") == "1"
    end
    return true
end

local function getResolvedTotal(sessionSource, combatSource, combatSession)
    if sessionSource and sessionSource.totalAmount ~= nil then
        return sessionSource.totalAmount
    end
    if combatSource and combatSource.totalAmount ~= nil then
        return combatSource.totalAmount
    end
    if combatSession and #(combatSession.combatSources or {}) == 1 and combatSession.totalAmount ~= nil then
        return combatSession.totalAmount
    end
    return 0
end

local function countCombatSpells(combatSpells)
    return #(combatSpells or {})
end

local function sumCombatSpellAmounts(combatSpells)
    local total = 0
    for _, combatSpell in ipairs(combatSpells or {}) do
        total = total + (combatSpell.totalAmount or 0)
    end
    return total
end

local function mergeCombatSpell(spellsById, combatSpell)
    local spellId = combatSpell and combatSpell.spellID
    if not spellId then
        return
    end

    local mergedSpell = spellsById[spellId]
    if not mergedSpell then
        mergedSpell = {
            spellID = spellId,
            totalAmount = 0,
            amountPerSecond = 0,
            creatureName = combatSpell.creatureName,
            overkillAmount = 0,
            isAvoidable = combatSpell.isAvoidable,
            isDeadly = combatSpell.isDeadly,
            combatSpellDetails = combatSpell.combatSpellDetails,
        }
        spellsById[spellId] = mergedSpell
    end

    mergedSpell.totalAmount = mergedSpell.totalAmount + (combatSpell.totalAmount or 0)
    mergedSpell.amountPerSecond = mergedSpell.amountPerSecond + (combatSpell.amountPerSecond or 0)
    mergedSpell.overkillAmount = mergedSpell.overkillAmount + (combatSpell.overkillAmount or 0)
end

local function buildMergedCombatSpellList(spellsById)
    local result = {}
    for _, combatSpell in pairs(spellsById or {}) do
        result[#result + 1] = combatSpell
    end

    table.sort(result, function(left, right)
        if (left.totalAmount or 0) == (right.totalAmount or 0) then
            return (left.spellID or 0) < (right.spellID or 0)
        end
        return (left.totalAmount or 0) > (right.totalAmount or 0)
    end)

    return result
end

local function getExpectedDamageTotal(session, snapshot)
    local directDamage = tonumber(snapshot and snapshot.damageDone) or 0
    if directDamage > 0 then
        return directDamage
    end

    local enemyDamage = tonumber(snapshot and snapshot.enemyDamageTaken) or 0
    if enemyDamage <= 0 or not session then
        return 0
    end

    if session.context == Constants.CONTEXT.TRAINING_DUMMY or session.context == Constants.CONTEXT.DUEL then
        return enemyDamage
    end

    local identity = session.identity or {}
    local evidence = identity.evidence or {}
    local opponent = session.primaryOpponent or {}
    if (evidence.dummyScore or 0) >= 60 then
        return enemyDamage
    end
    if opponent.guid and not opponent.isPlayer then
        return enemyDamage
    end

    return 0
end

local function getDurationMatchScore(expectedDuration, candidateDuration)
    local left = tonumber(expectedDuration) or 0
    local right = tonumber(candidateDuration) or 0
    if left <= 0 or right <= 0 then
        return 0
    end

    local delta = math.abs(left - right)
    if delta <= 1 then
        return 24
    end
    if delta <= 3 then
        return 16
    end
    if delta <= 6 then
        return 10
    end
    if delta <= 10 then
        return 5
    end
    return 0
end

local function getDurationDelta(expectedDuration, candidateDuration)
    local left = tonumber(expectedDuration) or 0
    local right = tonumber(candidateDuration) or 0
    if left <= 0 or right <= 0 then
        return 0
    end
    return math.abs(left - right)
end

local function getImportConfidenceFromScore(score)
    local numeric = tonumber(score) or 0
    if numeric >= 150 then
        return 96
    end
    if numeric >= 130 then
        return 90
    end
    if numeric >= 110 then
        return 84
    end
    if numeric >= 90 then
        return 76
    end
    if numeric >= 70 then
        return 68
    end
    if numeric >= 50 then
        return 58
    end
    if numeric >= 30 then
        return 46
    end
    return 30
end

local function snapshotHasMeaningfulData(snapshot)
    if not snapshot then
        return false
    end
    return (snapshot.damageDone or 0) > 0
        or (snapshot.healingDone or 0) > 0
        or (snapshot.damageTaken or 0) > 0
        or countCombatSpells(snapshot.damageSpells) > 0
        or countCombatSpells(snapshot.enemyDamageSpells) > 0
        or (snapshot.enemyDamageTaken or 0) > 0
end

local function getLatestTrackedUnit(session)
    for _, actor in pairs(session.actors or {}) do
        if actor and actor.unitToken and actor.unitToken ~= "player" and actor.unitToken ~= "pet" then
            return actor
        end
    end
    return nil
end

function DamageMeterService:IsSupported()
    return type(C_DamageMeter) == "table" and type(Enum) == "table" and type(Enum.DamageMeterType) == "table"
end

function DamageMeterService:IsAvailable()
    if not self:IsSupported() then
        return false, "missing_api"
    end
    local isAvailable, failureReason = ApiCompat.IsDamageMeterAvailable()
    if not isAvailable then
        return false, failureReason
    end
    if not isDamageMeterEnabled() then
        return false, "damage_meter_disabled"
    end
    return true
end

function DamageMeterService:GetAvailableSessions()
    return sortSessionsById(ApiCompat.GetAvailableCombatSessions() or {})
end

function DamageMeterService:GetLatestSessionId()
    local latestSessionId = 0
    for _, sessionInfo in ipairs(self:GetAvailableSessions()) do
        latestSessionId = math.max(latestSessionId, sessionInfo.sessionID or 0)
    end
    return latestSessionId > 0 and latestSessionId or nil
end

function DamageMeterService:Initialize()
    local latestSessionId = self:GetLatestSessionId()
    self.lastSeenSessionId = latestSessionId or 0
    self.activeSessionBaselineId = nil
    self.warnedUnavailable = false
    self.latestUpdatedSessionIdByType = {}
    self.currentSessionSnapshot = nil
    self.sessionUpdateSignals = {}
end

function DamageMeterService:MarkSessionStart()
    self.activeSessionBaselineId = self:GetLatestSessionId() or self.lastSeenSessionId or 0
    self.currentSessionSnapshot = nil
    self.sessionUpdateSignals = {}
    ns.Addon:Trace("damage_meter.session_start", {
        baseline = self.activeSessionBaselineId or 0,
    })
end

function DamageMeterService:RecordSessionUpdateSignal(damageMeterType, sessionId)
    if not sessionId or sessionId <= 0 then
        return
    end

    self.sessionUpdateSignals = self.sessionUpdateSignals or {}
    local signal = self.sessionUpdateSignals[sessionId]
    if not signal then
        signal = {
            count = 0,
            types = {},
            lastUpdatedAt = 0,
        }
        self.sessionUpdateSignals[sessionId] = signal
    end

    signal.count = signal.count + 1
    signal.types[damageMeterType] = true
    signal.lastUpdatedAt = Helpers.Now()
end

function DamageMeterService:GetSessionUpdateSignal(sessionId)
    return self.sessionUpdateSignals and self.sessionUpdateSignals[sessionId] or nil
end

function DamageMeterService:GetSessionSignalScore(sessionId)
    local signal = self:GetSessionUpdateSignal(sessionId)
    if not signal then
        return 0, nil
    end

    local score = 0
    if signal.types[Enum.DamageMeterType.DamageDone] then
        score = score + 26
    end
    if signal.types[Enum.DamageMeterType.EnemyDamageTaken] then
        score = score + 22
    end
    if signal.types[Enum.DamageMeterType.HealingDone] then
        score = score + 6
    end

    score = score + math.min(signal.count or 0, 4) * 3

    local ageSeconds = math.max(0, Helpers.Now() - (signal.lastUpdatedAt or 0))
    if ageSeconds <= 0.5 then
        score = score + 8
    elseif ageSeconds <= 1.5 then
        score = score + 5
    elseif ageSeconds <= 3 then
        score = score + 2
    end

    return score, signal
end

function DamageMeterService:GetContextFitScore(session, snapshot)
    if not session or not snapshot then
        return 0
    end

    local identity = session.identity or {}
    local context = identity.kind or session.context
    if context == Constants.CONTEXT.TRAINING_DUMMY then
        local score = 0
        if (snapshot.enemyDamageTaken or 0) > 0 then
            score = score + 10
        end
        if (snapshot.enemyDamageSpellTotal or 0) > 0 then
            score = score + 8
        end
        if (snapshot.damageTaken or 0) <= 0 then
            score = score + 4
        end
        return score
    end

    if context == Constants.CONTEXT.DUEL or context == Constants.CONTEXT.WORLD_PVP then
        local score = 0
        if (snapshot.damageTaken or 0) > 0 then
            score = score + 8
        end
        if (snapshot.enemyDamageTaken or 0) > 0 then
            score = score + 6
        end
        if (snapshot.healingDone or 0) > 0 then
            score = score + 3
        end
        return score
    end

    return 0
end

function DamageMeterService:HandleCombatSessionUpdated(damageMeterType, sessionId)
    if not sessionId or sessionId <= 0 then
        return
    end
    self.latestUpdatedSessionIdByType = self.latestUpdatedSessionIdByType or {}
    self.latestUpdatedSessionIdByType[damageMeterType] = math.max(self.latestUpdatedSessionIdByType[damageMeterType] or 0, sessionId)
    self:RecordSessionUpdateSignal(damageMeterType, sessionId)
    ns.Addon:Trace("damage_meter.session_updated", {
        sessionId = sessionId,
        type = damageMeterType or 0,
    })
end

function DamageMeterService:HandleCurrentSessionUpdated()
    ns.Addon:Trace("damage_meter.current_updated", {})
end

function DamageMeterService:HandleReset()
    self.lastSeenSessionId = self:GetLatestSessionId() or 0
    self.latestUpdatedSessionIdByType = {}
    self.activeSessionBaselineId = nil
    self.currentSessionSnapshot = nil
    self.sessionUpdateSignals = {}
end

function DamageMeterService:FindSessionsForImport()
    local sessions = self:GetAvailableSessions()
    local baseline = self.activeSessionBaselineId or self.lastSeenSessionId or 0
    local candidates = {}
    local seen = {}
    local sessionInfoById = {}

    for _, sessionInfo in ipairs(sessions) do
        sessionInfoById[sessionInfo.sessionID or 0] = sessionInfo
    end

    local function addCandidate(sessionInfoOrId)
        local sessionInfo = sessionInfoOrId
        if type(sessionInfoOrId) == "number" then
            sessionInfo = sessionInfoById[sessionInfoOrId] or { sessionID = sessionInfoOrId }
        end
        local sessionId = sessionInfo and sessionInfo.sessionID or 0
        if sessionId <= baseline or seen[sessionId] then
            return
        end
        seen[sessionId] = true
        candidates[#candidates + 1] = sessionInfo
    end

    addCandidate(self.latestUpdatedSessionIdByType and self.latestUpdatedSessionIdByType[Enum.DamageMeterType.DamageDone] or nil)
    addCandidate(self.latestUpdatedSessionIdByType and self.latestUpdatedSessionIdByType[Enum.DamageMeterType.EnemyDamageTaken] or nil)
    if self.sessionUpdateSignals then
        for sessionId in pairs(self.sessionUpdateSignals) do
            addCandidate(sessionId)
        end
    end

    for _, sessionInfo in ipairs(sessions) do
        addCandidate(sessionInfo)
    end

    if #candidates == 0 and #sessions > 0 then
        local latest = sessions[#sessions]
        if (latest.sessionID or 0) > (self.lastSeenSessionId or 0) then
            candidates[#candidates + 1] = latest
        end
    end

    return sortSessionsByIdDesc(candidates)
end

function DamageMeterService:GetCurrentPlayerSource(damageMeterType)
    local combatSession = ApiCompat.GetCombatSessionFromType(Enum.DamageMeterSessionType.Current, damageMeterType)
    if not combatSession then
        return nil, nil, nil
    end

    local playerGuid = ApiCompat.GetPlayerGUID()
    local playerName = ApiCompat.GetPlayerName()
    local combatSource = nil

    for _, source in ipairs(combatSession.combatSources or {}) do
        if source and (source.isLocalPlayer or (playerGuid and source.sourceGUID == playerGuid) or (playerName and source.name == playerName)) then
            combatSource = source
            break
        end
    end

    local sessionSource = nil
    if combatSource then
        sessionSource = ApiCompat.GetCombatSessionSourceFromType(
            Enum.DamageMeterSessionType.Current,
            damageMeterType,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
    end

    if not sessionSource and combatSource and combatSource.isLocalPlayer then
        sessionSource = ApiCompat.GetCombatSessionSourceFromType(Enum.DamageMeterSessionType.Current, damageMeterType, nil, nil)
    end

    if not sessionSource and combatSource then
        sessionSource = {
            combatSpells = {},
            maxAmount = combatSource.totalAmount or 0,
            totalAmount = combatSource.totalAmount or 0,
        }
    end

    return sessionSource, combatSource, combatSession
end

function DamageMeterService:CollectEnemyDamageSnapshotForCurrent()
    local combatSession = ApiCompat.GetCombatSessionFromType(Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.EnemyDamageTaken)
    if not combatSession then
        return 0, {}
    end

    local spellsById = {}
    for _, combatSource in ipairs(combatSession.combatSources or {}) do
        local sessionSource = ApiCompat.GetCombatSessionSourceFromType(
            Enum.DamageMeterSessionType.Current,
            Enum.DamageMeterType.EnemyDamageTaken,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
        for _, combatSpell in ipairs(sessionSource and sessionSource.combatSpells or {}) do
            mergeCombatSpell(spellsById, combatSpell)
        end
    end

    return combatSession.totalAmount or 0, buildMergedCombatSpellList(spellsById)
end

function DamageMeterService:CollectEnemyDamageSnapshotForSession(sessionId)
    local combatSession = ApiCompat.GetCombatSessionFromID(sessionId, Enum.DamageMeterType.EnemyDamageTaken)
    if not combatSession then
        return 0, {}
    end

    local spellsById = {}
    for _, combatSource in ipairs(combatSession.combatSources or {}) do
        local sessionSource = ApiCompat.GetCombatSessionSourceFromID(
            sessionId,
            Enum.DamageMeterType.EnemyDamageTaken,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
        for _, combatSpell in ipairs(sessionSource and sessionSource.combatSpells or {}) do
            mergeCombatSpell(spellsById, combatSpell)
        end
    end

    return combatSession.totalAmount or 0, buildMergedCombatSpellList(spellsById)
end

function DamageMeterService:BuildSnapshotFromSources(session, payload)
    local enemyDamageTaken = tonumber(payload.enemyDamageTaken) or 0
    local snapshot = {
        duration = tonumber(payload.duration) or (session and session.duration) or 0,
        damageDone = tonumber(payload.damageDone) or 0,
        healingDone = tonumber(payload.healingDone) or 0,
        damageTaken = tonumber(payload.damageTaken) or 0,
        absorbed = tonumber(payload.absorbed) or 0,
        interrupts = tonumber(payload.interrupts) or 0,
        dispels = tonumber(payload.dispels) or 0,
        deaths = tonumber(payload.deaths) or 0,
        damageSpells = payload.damageSpells or {},
        healingSpells = payload.healingSpells or {},
        absorbSpells = payload.absorbSpells or {},
        enemyDamageTaken = enemyDamageTaken,
        enemyDamageSpells = payload.enemyDamageSpells or {},
    }

    snapshot.expectedDamageDone = getExpectedDamageTotal(session, snapshot)
    snapshot.localDamageSpellTotal = sumCombatSpellAmounts(snapshot.damageSpells)
    snapshot.enemyDamageSpellTotal = sumCombatSpellAmounts(snapshot.enemyDamageSpells)
    return snapshot
end

function DamageMeterService:BuildHistoricalSnapshot(session, sessionInfo, sessionId)
    local damageSource, damageCombatSource, damageSession = self:GetPlayerSource(sessionId, Enum.DamageMeterType.DamageDone)
    local healingSource, healingCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.HealingDone)
    local absorbSource, absorbCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.Absorbs)
    local interruptSource, interruptCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.Interrupts)
    local dispelSource, dispelCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.Dispels)
    local damageTakenSource, damageTakenCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.DamageTaken)
    local deathSource, deathCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.Deaths)
    local enemyDamageTaken, enemyDamageSpells = self:CollectEnemyDamageSnapshotForSession(sessionId)

    local snapshot = self:BuildSnapshotFromSources(session, {
        duration = tonumber(sessionInfo and sessionInfo.durationSeconds) or tonumber(damageSession and damageSession.durationSeconds) or (session and session.duration) or 0,
        damageDone = getResolvedTotal(damageSource, damageCombatSource, damageSession),
        healingDone = getResolvedTotal(healingSource, healingCombatSource),
        damageTaken = getResolvedTotal(damageTakenSource, damageTakenCombatSource),
        absorbed = getResolvedTotal(absorbSource, absorbCombatSource),
        interrupts = getResolvedTotal(interruptSource, interruptCombatSource),
        dispels = getResolvedTotal(dispelSource, dispelCombatSource),
        deaths = getResolvedTotal(deathSource, deathCombatSource),
        damageSpells = damageSource and damageSource.combatSpells or {},
        healingSpells = healingSource and healingSource.combatSpells or {},
        absorbSpells = absorbSource and absorbSource.combatSpells or {},
        enemyDamageTaken = enemyDamageTaken,
        enemyDamageSpells = enemyDamageSpells,
    })

    local score = 0
    if snapshot.expectedDamageDone > 0 then
        score = score + 100
    end
    if snapshot.damageDone > 0 then
        score = score + 25
    end
    if snapshot.enemyDamageTaken > 0 then
        score = score + 20
    end
    if countCombatSpells(snapshot.damageSpells) > 0 then
        score = score + 18
    end
    if countCombatSpells(snapshot.enemyDamageSpells) > 0 then
        score = score + 18
    end
    if snapshot.healingDone > 0 then
        score = score + 6
    end
    if snapshot.damageTaken > 0 then
        score = score + 6
    end
    score = score + getDurationMatchScore(session and session.duration, snapshot.duration)
    score = score + self:GetContextFitScore(session, snapshot)
    local signalScore, signal = self:GetSessionSignalScore(sessionId)
    score = score + signalScore

    return {
        snapshot = snapshot,
        score = score,
        sessionId = sessionId,
        sessionInfo = sessionInfo,
        damageSource = damageSource,
        damageCombatSource = damageCombatSource,
        signal = signal,
        durationDelta = getDurationDelta(session and session.duration, snapshot.duration),
        signalScore = signalScore,
    }
end

function DamageMeterService:ApplyImportMetadata(session, metadata)
    if not session then
        return
    end

    session.import = session.import or {}
    session.import.source = metadata and metadata.source or "none"
    session.import.damageMeterSessionId = metadata and metadata.damageMeterSessionId or nil
    session.import.confidence = metadata and metadata.confidence or 0
    session.import.durationDelta = metadata and metadata.durationDelta or nil
    session.import.signalScore = metadata and metadata.signalScore or 0
    session.import.score = metadata and metadata.score or 0
    session.import.finalDamageSourceHint = session.import.finalDamageSourceHint or nil
end

function DamageMeterService:ResolveDamageSpellBreakdown(session, snapshot)
    local localSpells = snapshot and snapshot.damageSpells or {}
    local enemySpells = snapshot and snapshot.enemyDamageSpells or {}
    local localTotal = tonumber(snapshot and snapshot.localDamageSpellTotal) or sumCombatSpellAmounts(localSpells)
    local enemyTotal = tonumber(snapshot and snapshot.enemyDamageSpellTotal) or sumCombatSpellAmounts(enemySpells)
    local expectedTotal = tonumber(snapshot and snapshot.expectedDamageDone) or getExpectedDamageTotal(session, snapshot)

    if localTotal <= 0 and enemyTotal <= 0 then
        return nil, {}, "none"
    end
    if localTotal <= 0 then
        return Enum.DamageMeterType.EnemyDamageTaken, enemySpells, "enemy_damage_taken"
    end
    if enemyTotal <= 0 then
        return Enum.DamageMeterType.DamageDone, localSpells, "damage_done"
    end

    if expectedTotal > 0 then
        local localCoverage = localTotal / expectedTotal
        local enemyCoverage = enemyTotal / expectedTotal
        if enemyCoverage > localCoverage + 0.15 and enemyTotal > localTotal then
            return Enum.DamageMeterType.EnemyDamageTaken, enemySpells, "enemy_damage_taken"
        end
    elseif enemyTotal > localTotal * 1.15 then
        return Enum.DamageMeterType.EnemyDamageTaken, enemySpells, "enemy_damage_taken"
    end

    return Enum.DamageMeterType.DamageDone, localSpells, "damage_done"
end

function DamageMeterService:BackfillDamageBreakdownFromCasts(session, expectedDamageTotal)
    local remainingDamage = math.max(0, (tonumber(expectedDamageTotal) or 0))
    if remainingDamage <= 0 then
        return false
    end

    local candidates = {}
    local totalWeight = 0
    for spellId, aggregate in pairs(session.spells or {}) do
        local currentDamage = tonumber(aggregate.totalDamage) or 0
        remainingDamage = remainingDamage - currentDamage

        local category = Constants.SPELL_CATEGORIES[spellId]
        local isEligibleCategory =
            category == nil
            or category == Constants.SPELL_CATEGORY.OFFENSIVE
        if isEligibleCategory and (aggregate.castCount or 0) > 0 and currentDamage <= 0 then
            local weight = math.max(aggregate.castCount or 0, 1)
            candidates[#candidates + 1] = {
                aggregate = aggregate,
                weight = weight,
            }
            totalWeight = totalWeight + weight
        end
    end

    remainingDamage = math.max(0, remainingDamage)
    if remainingDamage <= 0 or totalWeight <= 0 or #candidates == 0 then
        return false
    end

    local allocatedDamage = 0
    for index, entry in ipairs(candidates) do
        local estimate
        if index == #candidates then
            estimate = remainingDamage - allocatedDamage
        else
            estimate = math.floor((remainingDamage * entry.weight / totalWeight) + 0.5)
        end

        if estimate and estimate > 0 then
            local aggregate = entry.aggregate
            aggregate.totalDamage = (aggregate.totalDamage or 0) + estimate
            aggregate.hitCount = math.max(aggregate.hitCount or 0, aggregate.castCount or 0, 1)
            aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0, 1)
            allocatedDamage = allocatedDamage + estimate
        end
    end

    if allocatedDamage > 0 then
        session.captureQuality = session.captureQuality or {}
        session.captureQuality.spellBreakdown = Constants.CAPTURE_QUALITY.DEGRADED
        session.damageBreakdownSource = "estimated_from_casts"
        ns.Addon:Trace("damage_meter.spells.estimated", {
            damage = allocatedDamage,
            expected = expectedDamageTotal or 0,
            spells = #candidates,
        })
        return true
    end

    return false
end

function DamageMeterService:NormalizeImportedSpellStats(session, expectedDamageTotal)
    local hasDamage = false
    for _, aggregate in pairs(session.spells or {}) do
        if (aggregate.totalDamage or 0) > 0 then
            aggregate.hitCount = math.max(aggregate.hitCount or 0, aggregate.castCount or 0, 1)
            aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0, 1)
            hasDamage = true
        end
    end

    if hasDamage then
        local estimated = self:BackfillDamageBreakdownFromCasts(session, expectedDamageTotal)
        if estimated and not session.damageBreakdownSource then
            session.damageBreakdownSource = "estimated_from_casts"
        end
        return true
    end

    return self:BackfillDamageBreakdownFromCasts(session, expectedDamageTotal)
end

function DamageMeterService:CaptureCurrentSessionSnapshot(session)
    local damageSource, damageCombatSource, damageSession = self:GetCurrentPlayerSource(Enum.DamageMeterType.DamageDone)
    local healingSource, healingCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.HealingDone)
    local absorbSource, absorbCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Absorbs)
    local interruptSource, interruptCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Interrupts)
    local dispelSource, dispelCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Dispels)
    local damageTakenSource, damageTakenCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.DamageTaken)
    local deathSource, deathCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Deaths)
    local enemyDamageTaken, enemyDamageSpells = self:CollectEnemyDamageSnapshotForCurrent()

    local snapshot = self:BuildSnapshotFromSources(session, {
        duration = tonumber(damageSession and damageSession.durationSeconds) or (session and session.duration) or 0,
        damageDone = getResolvedTotal(damageSource, damageCombatSource, damageSession),
        healingDone = getResolvedTotal(healingSource, healingCombatSource),
        damageTaken = getResolvedTotal(damageTakenSource, damageTakenCombatSource),
        absorbed = getResolvedTotal(absorbSource, absorbCombatSource),
        interrupts = getResolvedTotal(interruptSource, interruptCombatSource),
        dispels = getResolvedTotal(dispelSource, dispelCombatSource),
        deaths = getResolvedTotal(deathSource, deathCombatSource),
        damageSpells = damageSource and damageSource.combatSpells or {},
        healingSpells = healingSource and healingSource.combatSpells or {},
        absorbSpells = absorbSource and absorbSource.combatSpells or {},
        enemyDamageTaken = enemyDamageTaken,
        enemyDamageSpells = enemyDamageSpells,
    })

    if snapshotHasMeaningfulData(snapshot) then
        self.currentSessionSnapshot = snapshot
        ns.Addon:Trace("damage_meter.current_snapshot", {
            damage = snapshot.damageDone or 0,
            enemyDamage = snapshot.enemyDamageTaken or 0,
            localSpells = countCombatSpells(snapshot.damageSpells),
            enemySpells = countCombatSpells(snapshot.enemyDamageSpells),
        })
        return true
    end

    return false
end

function DamageMeterService:ApplySnapshotToSession(session, snapshot)
    if not session or not snapshot then
        return false
    end

    session.duration = tonumber(snapshot.duration) or session.duration or 0
    session.captureQuality = session.captureQuality or {}
    session.captureQuality.damageMeter = Constants.CAPTURE_QUALITY.OK

    -- Only clear raw events and mark as DM-sourced when CLEU capture was already
    -- restricted (Midnight-safe mode). Good local data must not be wiped.
    local captureRestricted = session.captureQuality.rawEvents == Constants.CAPTURE_QUALITY.RESTRICTED
    if captureRestricted then
        session.rawEvents = {}
        session.captureSource = "damage_meter"
    end

    session.importedTotals = session.importedTotals or {}
    session.importedTotals.damageDone = tonumber(snapshot.damageDone) or 0
    session.importedTotals.healingDone = tonumber(snapshot.healingDone) or 0
    session.importedTotals.damageTaken = tonumber(snapshot.damageTaken) or 0
    session.importedTotals.absorbed = tonumber(snapshot.absorbed) or 0

    session.localTotals = session.localTotals or {}
    local localDamageDone = tonumber(session.localTotals.damageDone) or tonumber(session.totals.damageDone) or 0
    local localHealingDone = tonumber(session.localTotals.healingDone) or tonumber(session.totals.healingDone) or 0
    local localDamageTaken = tonumber(session.localTotals.damageTaken) or tonumber(session.totals.damageTaken) or 0
    local localAbsorbed = tonumber(session.localTotals.absorbed) or tonumber(session.totals.absorbed) or 0

    session.totals.damageDone = localDamageDone > 0 and localDamageDone or session.importedTotals.damageDone
    session.totals.healingDone = localHealingDone > 0 and localHealingDone or session.importedTotals.healingDone
    session.totals.damageTaken = localDamageTaken > 0 and localDamageTaken or session.importedTotals.damageTaken
    session.totals.absorbed = localAbsorbed > 0 and localAbsorbed or session.importedTotals.absorbed

    session.utility.interrupts = tonumber(snapshot.interrupts) or 0
    session.utility.successfulInterrupts = session.utility.interrupts
    session.utility.dispels = tonumber(snapshot.dispels) or 0
    session.survival.deaths = math.max(session.survival.deaths or 0, tonumber(snapshot.deaths) or 0)
    session.survival.totalAbsorbed = math.max(session.survival.totalAbsorbed or 0, localAbsorbed, session.importedTotals.absorbed or 0)

    local expectedDamageTotal = getExpectedDamageTotal(session, snapshot)
    if (session.totals.damageDone or 0) <= 0 and expectedDamageTotal > 0 then
        session.totals.damageDone = expectedDamageTotal
        session.importedTotals.damageDone = math.max(session.importedTotals.damageDone or 0, expectedDamageTotal)
        if session.import then
            session.import.finalDamageSourceHint = "enemy_damage_taken_fallback"
        end
    elseif localDamageDone <= 0 and (session.importedTotals.damageDone or 0) > 0 and session.import then
        session.import.finalDamageSourceHint = "damage_meter"
    end

    local damageMeterType, damageSpells, damageBreakdownSource = self:ResolveDamageSpellBreakdown(session, snapshot)
    if damageMeterType and countCombatSpells(damageSpells) > 0 then
        self:MergeSpellTotals(session, damageMeterType, damageSpells)
        session.damageBreakdownSource = damageBreakdownSource
    end
    self:MergeSpellTotals(session, Enum.DamageMeterType.HealingDone, snapshot.healingSpells)
    self:MergeSpellTotals(session, Enum.DamageMeterType.Absorbs, snapshot.absorbSpells)
    self:NormalizeImportedSpellStats(session, expectedDamageTotal)
    if session.import then
        session.import.damageBreakdown = session.damageBreakdownSource or "none"
    end
    return true
end

function DamageMeterService:GetPlayerSource(sessionId, damageMeterType)
    local combatSession = ApiCompat.GetCombatSessionFromID(sessionId, damageMeterType)
    if not combatSession then
        return nil, nil, nil
    end

    local playerGuid = ApiCompat.GetPlayerGUID()
    local playerName = ApiCompat.GetPlayerName()
    local combatSource = nil

    for _, source in ipairs(combatSession.combatSources or {}) do
        if source and (source.isLocalPlayer or (playerGuid and source.sourceGUID == playerGuid) or (playerName and source.name == playerName)) then
            combatSource = source
            break
        end
    end

    if not combatSource then
        return nil, nil, combatSession
    end

    local sessionSource = ApiCompat.GetCombatSessionSourceFromID(
        sessionId,
        damageMeterType,
        combatSource.sourceGUID,
        combatSource.sourceCreatureID
    )

    if not sessionSource and combatSource.isLocalPlayer then
        sessionSource = ApiCompat.GetCombatSessionSourceFromID(sessionId, damageMeterType, nil, nil)
    end

    if not sessionSource then
        sessionSource = {
            combatSpells = {},
            maxAmount = combatSource.totalAmount or 0,
            totalAmount = combatSource.totalAmount or 0,
        }
    end

    return sessionSource, combatSource, combatSession
end

function DamageMeterService:MergeSpellTotals(session, damageMeterType, combatSpells)
    session.spells = session.spells or {}

    for _, combatSpell in ipairs(combatSpells or {}) do
        local spellId = combatSpell.spellID
        if spellId then
            local category = Constants.SPELL_CATEGORIES[spellId]
            local shouldSkipDamageSpell =
                (damageMeterType == Enum.DamageMeterType.DamageDone or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken)
                and category
                and category ~= Constants.SPELL_CATEGORY.OFFENSIVE

            if not shouldSkipDamageSpell then
                session.spells[spellId] = session.spells[spellId] or createSpellAggregate(spellId)
                local aggregate = session.spells[spellId]

                if damageMeterType == Enum.DamageMeterType.DamageDone or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken then
                    aggregate.totalDamage = aggregate.totalDamage + (combatSpell.totalAmount or 0)
                    aggregate.overkill = aggregate.overkill + (combatSpell.overkillAmount or 0)
                    aggregate.hitCount = math.max(aggregate.hitCount or 0, 1)
                    aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0)
                elseif damageMeterType == Enum.DamageMeterType.HealingDone then
                    aggregate.totalHealing = aggregate.totalHealing + (combatSpell.totalAmount or 0)
                    aggregate.hitCount = math.max(aggregate.hitCount or 0, 1)
                    aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0)
                elseif damageMeterType == Enum.DamageMeterType.Absorbs then
                    aggregate.absorbed = aggregate.absorbed + (combatSpell.totalAmount or 0)
                end
            end
        end
    end
end

function DamageMeterService:ApplyPrimaryOpponent(session, sessionId)
    local enemySession = ApiCompat.GetCombatSessionFromID(sessionId, Enum.DamageMeterType.EnemyDamageTaken)
    local topSource = nil

    for _, source in ipairs(enemySession and enemySession.combatSources or {}) do
        if not topSource or (source.totalAmount or 0) > (topSource.totalAmount or 0) then
            topSource = source
        end
    end

    if topSource then
        session.primaryOpponent = session.primaryOpponent or {}
        session.primaryOpponent.guid = topSource.sourceGUID or session.primaryOpponent.guid
        session.primaryOpponent.name = topSource.name or session.primaryOpponent.name
        session.primaryOpponent.classFile = topSource.classFilename or session.primaryOpponent.classFile
        session.primaryOpponent.className = topSource.classFilename or session.primaryOpponent.className
        session.primaryOpponent.specIconId = topSource.specIconID or session.primaryOpponent.specIconId
        session.primaryOpponent.classification = topSource.classification or session.primaryOpponent.classification
        return
    end

    local trackedUnit = getLatestTrackedUnit(session)
    if trackedUnit then
        session.primaryOpponent = session.primaryOpponent or trackedUnit
    end
end

function DamageMeterService:ImportSession(session)
    if not session or not self:IsSupported() then
        return false
    end

    local isAvailable, failureReason = self:IsAvailable()
    if not isAvailable then
        if not self.warnedUnavailable then
            local reasonText = failureReason == "damage_meter_disabled"
                and "Blizzard Damage Meter tracking is disabled in the default UI."
                or tostring(failureReason or "unknown")
            ns.Addon:Warn(string.format("Built-in Damage Meter is unavailable: %s", reasonText))
            self.warnedUnavailable = true
        end
        return false
    end

    local candidateSessions = self:FindSessionsForImport()
    if #candidateSessions == 0 then
        ns.Addon:Trace("damage_meter.import.none", {
            baseline = self.activeSessionBaselineId or 0,
        })
        return false
    end

    local selectedCandidate = nil

    for _, candidate in ipairs(candidateSessions) do
        local candidateId = candidate and candidate.sessionID
        if candidateId then
            local builtCandidate = self:BuildHistoricalSnapshot(session, candidate, candidateId)
            local hasMeaningfulData = snapshotHasMeaningfulData(builtCandidate.snapshot)
            ns.Addon:Trace("damage_meter.import.candidate", {
                duration = builtCandidate.snapshot and builtCandidate.snapshot.duration or 0,
                durationDelta = builtCandidate.durationDelta or 0,
                enemyDamage = builtCandidate.snapshot and builtCandidate.snapshot.enemyDamageTaken or 0,
                enemySpellTotal = builtCandidate.snapshot and builtCandidate.snapshot.enemyDamageSpellTotal or 0,
                localDamage = builtCandidate.snapshot and builtCandidate.snapshot.damageDone or 0,
                localSpellTotal = builtCandidate.snapshot and builtCandidate.snapshot.localDamageSpellTotal or 0,
                meaningful = hasMeaningfulData and true or false,
                score = builtCandidate.score or 0,
                sessionId = candidateId,
                signalCount = builtCandidate.signal and builtCandidate.signal.count or 0,
                signalScore = builtCandidate.signalScore or 0,
            })
            if not selectedCandidate
                or builtCandidate.score > selectedCandidate.score
                or (builtCandidate.score == selectedCandidate.score and (builtCandidate.sessionId or 0) > (selectedCandidate.sessionId or 0))
            then
                selectedCandidate = builtCandidate
                selectedCandidate.hasMeaningfulData = hasMeaningfulData
            end
        end
    end

    if (not selectedCandidate or not selectedCandidate.hasMeaningfulData) and self.currentSessionSnapshot and snapshotHasMeaningfulData(self.currentSessionSnapshot) then
        self:ApplyImportMetadata(session, {
            source = "cached",
            confidence = 62,
            durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
            signalScore = 0,
            score = 0,
        })
        ns.Addon:Trace("damage_meter.import.cached_snapshot", {
            damage = self.currentSessionSnapshot.damageDone or 0,
            enemyDamage = self.currentSessionSnapshot.enemyDamageTaken or 0,
        })
        return self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
    end

    if not selectedCandidate or not selectedCandidate.sessionId then
        local currentDamageSource, currentDamageCombatSource, currentDamageSession = self:GetCurrentPlayerSource(Enum.DamageMeterType.DamageDone)
        local currentHealingSource, currentHealingCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.HealingDone)
        local currentAbsorbSource, currentAbsorbCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Absorbs)
        local currentInterruptSource, currentInterruptCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Interrupts)
        local currentDispelSource, currentDispelCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Dispels)
        local currentDamageTakenSource, currentDamageTakenCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.DamageTaken)
        local currentDeathSource, currentDeathCombatSource = self:GetCurrentPlayerSource(Enum.DamageMeterType.Deaths)
        local currentEnemyDamageTaken, currentEnemyDamageSpells = self:CollectEnemyDamageSnapshotForCurrent()
        local currentHasMeaningfulData =
            getResolvedTotal(currentDamageSource, currentDamageCombatSource, currentDamageSession) > 0
            or getResolvedTotal(currentHealingSource, currentHealingCombatSource) > 0
            or getResolvedTotal(currentDamageTakenSource, currentDamageTakenCombatSource) > 0
            or countCombatSpells(currentDamageSource and currentDamageSource.combatSpells or {}) > 0
            or currentEnemyDamageTaken > 0
            or countCombatSpells(currentEnemyDamageSpells) > 0

        if currentHasMeaningfulData then
            self:CaptureCurrentSessionSnapshot(session)
            self:ApplyImportMetadata(session, {
                source = "current",
                confidence = 74,
                durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
                signalScore = 0,
                score = 0,
            })
            ns.Addon:Trace("damage_meter.import.current_fallback", {
                damage = self.currentSessionSnapshot and self.currentSessionSnapshot.damageDone or 0,
                sessionId = 0,
            })
            return self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
        elseif self.currentSessionSnapshot then
            self:ApplyImportMetadata(session, {
                source = "cached",
                confidence = 55,
                durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
                signalScore = 0,
                score = 0,
            })
            return self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
        else
            return false
        end
    end

    local sessionId = selectedCandidate.sessionId
    local sessionInfo = selectedCandidate.sessionInfo
    session.damageMeterSessionId = sessionId
    self:ApplyImportMetadata(session, {
        source = "historical",
        damageMeterSessionId = sessionId,
        confidence = getImportConfidenceFromScore(selectedCandidate.score),
        durationDelta = selectedCandidate.durationDelta,
        signalScore = selectedCandidate.signalScore or 0,
        score = selectedCandidate.score or 0,
    })
    ns.Addon:Trace("damage_meter.import.selected", {
        duration = selectedCandidate.snapshot and selectedCandidate.snapshot.duration or 0,
        durationDelta = selectedCandidate.durationDelta or 0,
        enemyDamage = selectedCandidate.snapshot and selectedCandidate.snapshot.enemyDamageTaken or 0,
        expected = selectedCandidate.snapshot and selectedCandidate.snapshot.expectedDamageDone or 0,
        localDamage = selectedCandidate.snapshot and selectedCandidate.snapshot.damageDone or 0,
        score = selectedCandidate.score or 0,
        sessionId = sessionId,
        signalCount = selectedCandidate.signal and selectedCandidate.signal.count or 0,
        signalScore = selectedCandidate.signalScore or 0,
    })
    self:ApplySnapshotToSession(session, selectedCandidate.snapshot)

    if (session.context == Constants.CONTEXT.TRAINING_DUMMY or session.context == Constants.CONTEXT.DUEL) and (session.totals.damageDone or 0) <= 0 then
        if (selectedCandidate.snapshot.enemyDamageTaken or 0) > 0 then
            session.totals.damageDone = selectedCandidate.snapshot.enemyDamageTaken or 0
            ns.Addon:Trace("damage_meter.import.enemy_fallback", {
                damage = session.totals.damageDone or 0,
                sessionId = sessionId,
            })
        elseif self.currentSessionSnapshot and (self.currentSessionSnapshot.enemyDamageTaken or 0) > 0 then
            session.totals.damageDone = self.currentSessionSnapshot.enemyDamageTaken or 0
            ns.Addon:Trace("damage_meter.import.cached_enemy_fallback", {
                damage = session.totals.damageDone or 0,
                sessionId = sessionId,
            })
        end
    end
    self:ApplyPrimaryOpponent(session, sessionId)
    local classifier = ns.Addon:GetModule("SessionClassifier")
    if classifier and classifier.SyncSessionIdentityFromOpponent then
        classifier:SyncSessionIdentityFromOpponent(session, session.primaryOpponent, "damage_meter")
    end

    self.lastSeenSessionId = math.max(self.lastSeenSessionId or 0, sessionId)
    self.activeSessionBaselineId = nil

    ns.Addon:Trace("damage_meter.import.ready", {
        damage = session.totals.damageDone or 0,
        damageBreakdown = session.damageBreakdownSource or "none",
        damageSpells = Helpers.CountMapEntries(session.spells or {}),
        healing = session.totals.healingDone or 0,
        importConfidence = session.import and session.import.confidence or 0,
        sessionId = sessionId,
        selectedScore = selectedCandidate.score or 0,
        taken = session.totals.damageTaken or 0,
    })
    return true
end

ns.Addon:RegisterModule("DamageMeterService", DamageMeterService)
