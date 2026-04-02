local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local DamageMeterService = {}

local UNATTRIBUTED_DAMAGE_SPELL_ID = -1
local DEFAULT_SPELL_ICON_ID = 134400

-- T048: Detect whether DeathRecap category exists in Enum.DamageMeterType.
local HAS_DEATH_RECAP = pcall(function() return Enum.DamageMeterType.DeathRecap end)

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
        source = nil,
        syntheticKind = nil,
        estimated = false,
    }
end

local function ensureSyntheticSpellAggregate(session, spellId, name, iconID, syntheticKind)
    session.spells = session.spells or {}
    session.spells[spellId] = session.spells[spellId] or createSpellAggregate(spellId)
    local aggregate = session.spells[spellId]
    aggregate.name = name or aggregate.name
    aggregate.iconID = iconID or aggregate.iconID or DEFAULT_SPELL_ICON_ID
    aggregate.syntheticKind = syntheticKind or aggregate.syntheticKind
    aggregate.source = Constants.PROVENANCE_SOURCE.ESTIMATED
    return aggregate
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
    if spellId == nil then
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

    -- Arena/BG: enemyDamageTaken is a valid proxy for the player's damage output
    -- when the DamageDone source returned zero (restricted CLEU environment).
    if session.context == Constants.CONTEXT.ARENA or session.context == Constants.CONTEXT.BATTLEGROUND then
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

    -- Last resort: use session.totals.damageDone (may have been set by a
    -- partial DM import or prior retry) when the snapshot itself had no total.
    local sessionTotal = session and session.totals and tonumber(session.totals.damageDone) or 0
    if sessionTotal > 0 then
        return sessionTotal
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

-- Attempts to import a death recap from C_DeathRecap given a DM combatSource.
-- Returns a deathRecap table on success, nil if no data or API unavailable.
local function tryImportDeathRecap(deathCombatSource)
    if not deathCombatSource then return nil end
    local recapId  = deathCombatSource.deathRecapID or 0
    local deathTime = deathCombatSource.deathTimeSeconds or 0
    if not recapId or recapId == 0 then return nil end

    local recap = { timeSeconds = deathTime, recapID = recapId }

    local okHp, maxHp = pcall(function()
        return C_DeathRecap and C_DeathRecap.GetRecapMaxHealth and C_DeathRecap.GetRecapMaxHealth(recapId)
    end)
    recap.maxHealth = okHp and maxHp or nil

    local okHas, hasEvents = pcall(function()
        return C_DeathRecap and C_DeathRecap.HasRecapEvents and C_DeathRecap.HasRecapEvents(recapId)
    end)
    if okHas and hasEvents then
        local okE, events = pcall(function()
            return C_DeathRecap.GetRecapEvents(recapId)
        end)
        recap.events = okE and events or nil
    end

    return recap
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

local function setAggregateDamageAmount(aggregate, amount)
    local numeric = tonumber(amount) or 0
    aggregate.totalDamage = numeric
    aggregate.hitCount = numeric > 0 and math.max(aggregate.hitCount or 0, 1) or 0
    aggregate.executeCount = numeric > 0 and math.max(aggregate.executeCount or 0, aggregate.hitCount or 0, 1) or 0
end

local function snapshotHasMeaningfulDamage(snapshot)
    if not snapshot then
        return false
    end
    return (snapshot.damageDone or 0) > 0
        or (snapshot.enemyDamageTaken or 0) > 0
        or (tonumber(snapshot.localDamageSpellTotal) or 0) > 0
        or (tonumber(snapshot.enemyDamageSpellTotal) or 0) > 0
        or countCombatSpells(snapshot.damageSpells) > 0
        or countCombatSpells(snapshot.enemyDamageSpells) > 0
end

local function getDamageEvidenceScore(snapshot)
    if not snapshot then
        return 0
    end

    local localTotal = tonumber(snapshot.localDamageSpellTotal) or sumCombatSpellAmounts(snapshot.damageSpells)
    local enemyTotal = tonumber(snapshot.enemyDamageSpellTotal) or sumCombatSpellAmounts(snapshot.enemyDamageSpells)
    local score = 0

    if (snapshot.damageDone or 0) > 0 then
        score = score + 70
    end
    if (snapshot.enemyDamageTaken or 0) > 0 then
        score = score + 55
    end
    if localTotal > 0 then
        score = score + 40
    end
    if enemyTotal > 0 then
        score = score + 40
    end

    score = score + math.min(countCombatSpells(snapshot.damageSpells), 6) * 4
    score = score + math.min(countCombatSpells(snapshot.enemyDamageSpells), 6) * 4

    return score
end

local function getLatestTrackedUnit(session)
    for _, actor in pairs(session.actors or {}) do
        if actor and actor.unitToken and actor.unitToken ~= "player" and actor.unitToken ~= "pet" then
            return actor
        end
    end
    return nil
end

-- collectExpectedOpponentGuids returns a keyed table of all known enemy GUIDs
-- for the given session. GUIDs are gathered from four sources:
--   1. session.primaryOpponent.guid
--   2. session.identity.opponentGuid
--   3. session.arena.slots[*].guid (all persisted arena slots)
--   4. ArenaRoundTracker:GetSlots() live state (current round slots)
local function collectExpectedOpponentGuids(session)
    local guids = {}

    local po = session and session.primaryOpponent
    if po and po.guid then guids[po.guid] = true end

    local identity = session and session.identity
    if identity and identity.opponentGuid then guids[identity.opponentGuid] = true end

    local arena = session and session.arena
    if arena and arena.slots then
        for _, slot in pairs(arena.slots) do
            if slot.guid then guids[slot.guid] = true end
        end
    end

    -- Pull live slots from ArenaRoundTracker for the current round.
    local art = ns and ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("ArenaRoundTracker")
    if art then
        for _, slot in pairs(art:GetSlots()) do
            if slot.guid then guids[slot.guid] = true end
        end
    end

    return guids
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

    -- Startup diagnostics: log C_DamageMeter availability and CVar state.
    local isAvailable, failReason = self:IsAvailable()
    local cvarEnabled = isDamageMeterEnabled()
    local sessionCount = latestSessionId and 1 or 0
    ns.Addon:Trace("damage_meter.init", {
        isSupported = self:IsSupported(),
        isAvailable = isAvailable,
        failReason = failReason or "none",
        cvarEnabled = cvarEnabled,
        initialSessions = sessionCount,
        baselineId = self.lastSeenSessionId,
    })

    -- Warn user if CVar is disabled — this is the #1 cause of zero damage.
    if self:IsSupported() and not cvarEnabled then
        C_Timer.After(5, function()
            ns.Addon:Warn(
                "Blizzard Damage Meter is DISABLED. CombatAnalytics cannot track damage without it. "
                .. "Enable it: ESC > Options > Gameplay > Combat > Enable Damage Meter"
            )
        end)
    end
end

function DamageMeterService:MarkSessionStart()
    -- Preserve the earliest baseline for the current combat window. Late
    -- session autodiscovery may call MarkSessionStart again after C_DamageMeter
    -- has already advanced to the active fight session; resetting the baseline
    -- then can make import selection skip the fight we are trying to import.
    if self.activeSessionBaselineId ~= nil then
        ns.Addon:Trace("damage_meter.session_start.reuse", {
            baseline = self.activeSessionBaselineId or 0,
        })
        return self.activeSessionBaselineId
    end

    self.activeSessionBaselineId = self:GetLatestSessionId() or self.lastSeenSessionId or 0
    self.currentSessionSnapshot = nil
    self.sessionUpdateSignals = {}
    ns.Addon:Trace("damage_meter.session_start", {
        baseline = self.activeSessionBaselineId or 0,
    })
    return self.activeSessionBaselineId
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

    if context == Constants.CONTEXT.ARENA or context == Constants.CONTEXT.BATTLEGROUND then
        local score = 0
        if (snapshot.damageDone or 0) > 0 then
            score = score + 10
        end
        if (snapshot.damageTaken or 0) > 0 then
            score = score + 8
        end
        if (snapshot.enemyDamageTaken or 0) > 0 then
            score = score + 6
        end
        if countCombatSpells(snapshot.damageSpells) > 0 then
            score = score + 4
        end
        if (snapshot.healingDone or 0) > 0 then
            score = score + 3
        end
        return score
    end

    return 0
end

-- GetOpponentFitScore scores how well a Damage Meter candidate's enemy source
-- list matches the known opponent roster for the given session.
--
-- Scoring:
--   +28  Primary opponent GUID found in candidate's enemy sources
--   +10  Per additional overlapping GUID (capped at +30 total overlap credit)
--   -18  Candidate has enemy sources but zero GUID overlap (wrong session penalty)
--   +10  Arena: candidate source count exactly matches expected bracket size
--    +6  Arena: candidate source count is off by one from expected bracket size
--   +14  Duel: candidate has exactly one enemy source
--    -8  Duel: candidate has more than one enemy source
--
-- Returns 0 safely when both the GUID set and enemy sources are empty.
function DamageMeterService:GetOpponentFitScore(session, enemySources)
    if not session then return 0 end
    local sources = enemySources or {}
    if #sources == 0 then return 0 end

    local expectedGuids = collectExpectedOpponentGuids(session)
    local primaryGuid   = session.primaryOpponent and session.primaryOpponent.guid

    -- Count how many expected GUIDs we actually have.
    local expectedCount = 0
    for _ in pairs(expectedGuids) do expectedCount = expectedCount + 1 end

    -- When no expected GUIDs are available (e.g. arena secret values that were
    -- sanitized to nil), skip the overlap penalty — the candidate can still be
    -- ranked by duration, signal score, and source count.
    if expectedCount == 0 and not primaryGuid then
        if session.context == Constants.CONTEXT.ARENA or session.context == Constants.CONTEXT.BATTLEGROUND then
            -- Give a small positive score for having enemy sources at all.
            return #sources > 0 and 8 or 0
        end
        return 0
    end

    local score = 0
    local overlapCount = 0
    local primaryFound = false

    for _, entry in ipairs(sources) do
        local sourceGuid = entry.combatSource and entry.combatSource.sourceGUID
        if sourceGuid then
            if primaryGuid and sourceGuid == primaryGuid then
                if not primaryFound then
                    score = score + 28
                    primaryFound = true
                end
            elseif expectedGuids[sourceGuid] then
                overlapCount = overlapCount + 1
            end
        end
    end

    -- Per-overlap credit, capped at +30.
    score = score + math.min(overlapCount * 10, 30)

    -- Zero-overlap penalty: penalize candidates with sources but no GUID match.
    local totalOverlap = (primaryFound and 1 or 0) + overlapCount
    if totalOverlap == 0 then
        score = score - 18
    end

    -- Context source-count fit.
    local identity  = session.identity or {}
    local context   = identity.kind or session.context
    local sourceCount = #sources

    if context == Constants.CONTEXT.ARENA then
        local bracket = session.bracket or (session.arena and session.arena.bracket)
        if bracket and bracket > 0 then
            local delta = math.abs(sourceCount - bracket)
            if delta == 0 then
                score = score + 10
            elseif delta == 1 then
                score = score + 6
            end
        end
    elseif context == Constants.CONTEXT.DUEL then
        if sourceCount == 1 then
            score = score + 14
        elseif sourceCount > 1 then
            score = score - 8
        end
    elseif context == Constants.CONTEXT.TRAINING_DUMMY then
        if sourceCount == 1 then
            score = score + 14
        elseif sourceCount > 1 then
            score = score - 8
        end
    end

    ns.Addon:Trace("damage_meter.opponent_fit", {
        expectedGuidCount = expectedCount,
        candidateSourceCount = #sources,
        overlapCount = (primaryFound and 1 or 0) + overlapCount,
        score = score,
        context = session.context or "unknown",
    })

    return score
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

    -- Fallback: if no candidates found above baseline, include the session AT
    -- the baseline. Training dummy and short PvE encounters may update an
    -- existing C_DamageMeter session in-place rather than creating a new one.
    if #candidates == 0 and baseline > 0 then
        for _, sessionInfo in ipairs(sessions) do
            local sessionId = sessionInfo and sessionInfo.sessionID or 0
            if sessionId == baseline and not seen[sessionId] then
                seen[sessionId] = true
                candidates[#candidates + 1] = sessionInfo
            end
        end
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

-- CollectEnemyDamageSnapshotForCurrent returns three values:
--   1. totalAmount (number)
--   2. flatSpellList  — merged across all sources (backward-compatible for callers
--                       that only need a global spell breakdown)
--   3. sources        — per-source list for SpellAttributionPipeline; each entry
--                       is { combatSource = ..., sessionSource = ... }
-- The flat spell list is kept to avoid breaking existing UI consumers.
function DamageMeterService:CollectEnemyDamageSnapshotForCurrent()
    local combatSession = ApiCompat.GetCombatSessionFromType(Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.EnemyDamageTaken)
    if not combatSession then
        return 0, {}, {}
    end

    local spellsById = {}
    local sources    = {}
    for _, combatSource in ipairs(combatSession.combatSources or {}) do
        local sessionSource = ApiCompat.GetCombatSessionSourceFromType(
            Enum.DamageMeterSessionType.Current,
            Enum.DamageMeterType.EnemyDamageTaken,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
        -- Build the flat merged list (legacy path — merges within source scope
        -- only, so each source's spells do not collide across sources).
        local sourceSpellsById = {}
        for _, combatSpell in ipairs(sessionSource and sessionSource.combatSpells or {}) do
            mergeCombatSpell(sourceSpellsById, combatSpell)
            mergeCombatSpell(spellsById,       combatSpell)
        end
        sources[#sources + 1] = { combatSource = combatSource, sessionSource = sessionSource }
    end

    return combatSession.totalAmount or 0, buildMergedCombatSpellList(spellsById), sources
end

-- Same as above but for a historical session id.
function DamageMeterService:CollectEnemyDamageSnapshotForSession(sessionId)
    local combatSession = ApiCompat.GetCombatSessionFromID(sessionId, Enum.DamageMeterType.EnemyDamageTaken)
    if not combatSession then
        return 0, {}, {}
    end

    local spellsById = {}
    local sources    = {}
    for _, combatSource in ipairs(combatSession.combatSources or {}) do
        local sessionSource = ApiCompat.GetCombatSessionSourceFromID(
            sessionId,
            Enum.DamageMeterType.EnemyDamageTaken,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
        local sourceSpellsById = {}
        for _, combatSpell in ipairs(sessionSource and sessionSource.combatSpells or {}) do
            mergeCombatSpell(sourceSpellsById, combatSpell)
            mergeCombatSpell(spellsById,       combatSpell)
        end
        sources[#sources + 1] = { combatSource = combatSource, sessionSource = sessionSource }
    end

    return combatSession.totalAmount or 0, buildMergedCombatSpellList(spellsById), sources
end

-- T049: Collect Death Recap rows from C_DamageMeter for a given session.
function DamageMeterService:CollectDeathRecapSnapshot(sessionId)
    if not HAS_DEATH_RECAP then
        return nil
    end

    local ok, combatSession = pcall(ApiCompat.GetCombatSessionFromID, sessionId, Enum.DamageMeterType.DeathRecap)
    if not ok or not combatSession then
        return { available = false }
    end

    local rows = {}
    for _, combatSource in ipairs(combatSession.combatSources or {}) do
        local sourceOk, sessionSource = pcall(
            ApiCompat.GetCombatSessionSourceFromID,
            sessionId,
            Enum.DamageMeterType.DeathRecap,
            combatSource.sourceGUID,
            combatSource.sourceCreatureID
        )
        for _, combatSpell in ipairs(sourceOk and sessionSource and sessionSource.combatSpells or {}) do
            rows[#rows + 1] = {
                spellId = combatSpell.spellID,
                amount = combatSpell.totalAmount or 0,
                sourceGuid = combatSource.sourceGUID,
                sourceName = combatSource.name,
                sourceClassFile = combatSource.classFilename,
            }
        end
    end

    if #rows == 0 then
        return { available = false }
    end

    return { available = true, rows = rows }
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
        avoidableDamageTaken = tonumber(payload.avoidableDamageTaken) or 0,
        avoidableSpells = payload.avoidableSpells or {},
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
    local avoidDamageTakenSource, avoidDamageTakenCombatSource = self:GetPlayerSource(sessionId, Enum.DamageMeterType.AvoidableDamageTaken)
    -- T008: Capture the 3rd return value (enemySources) for GUID-overlap scoring.
    local enemyDamageTaken, enemyDamageSpells, enemySources = self:CollectEnemyDamageSnapshotForSession(sessionId)

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
        avoidableDamageTaken = getResolvedTotal(avoidDamageTakenSource, avoidDamageTakenCombatSource),
        avoidableSpells = avoidDamageTakenSource and avoidDamageTakenSource.combatSpells or {},
    })

    snapshot.deathRecap = tryImportDeathRecap(deathCombatSource)
    if snapshot.deathRecap then
        ns.Addon:Trace("death_recap.imported", {
            recapId     = snapshot.deathRecap.recapID,
            timeSeconds = snapshot.deathRecap.timeSeconds,
            hasEvents   = snapshot.deathRecap.events ~= nil,
        })
    end

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

    -- T009: Add GUID-overlap opponent fit score.
    local opponentFitScore = self:GetOpponentFitScore(session, enemySources)
    score = score + opponentFitScore

    -- T009: Apply duration mismatch penalty (>15s delta on non-zero-duration sessions).
    local sessionDuration = tonumber(session and session.duration) or 0
    local candidateDuration = tonumber(snapshot.duration) or 0
    if sessionDuration > 0 and math.abs(candidateDuration - sessionDuration) > 15 then
        score = score - 20
    end

    return {
        snapshot = snapshot,
        score = score,
        damageEvidenceScore = getDamageEvidenceScore(snapshot),
        sessionId = sessionId,
        sessionInfo = sessionInfo,
        damageSource = damageSource,
        damageCombatSource = damageCombatSource,
        signal = signal,
        durationDelta = getDurationDelta(session and session.duration, snapshot.duration),
        signalScore = signalScore,
        opponentFitScore = opponentFitScore,
        enemySources = enemySources or {},
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
    -- T010: Persist opponent fit score and enemy source count for diagnostics.
    session.import.opponentFitScore = metadata and metadata.opponentFitScore or 0
    session.import.enemySourceCount = metadata and metadata.enemySourceCount or 0
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
    else
        -- No expected total — compare raw totals and spell detail richness.
        local localCount = countCombatSpells(localSpells)
        local enemyCount = countCombatSpells(enemySpells)
        if enemyTotal > localTotal * 1.15 then
            return Enum.DamageMeterType.EnemyDamageTaken, enemySpells, "enemy_damage_taken"
        end
        -- Prefer the source with significantly more spell entries when totals
        -- are close — a richer breakdown produces better per-spell analytics.
        if enemyCount > localCount * 2 and enemyCount >= 3 and enemyTotal >= localTotal * 0.85 then
            return Enum.DamageMeterType.EnemyDamageTaken, enemySpells, "enemy_damage_taken"
        end
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
            aggregate.estimated = true
            aggregate.source = Constants.PROVENANCE_SOURCE.ESTIMATED
            allocatedDamage = allocatedDamage + estimate
        end
    end

    if allocatedDamage > 0 then
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

function DamageMeterService:UpdateUnattributedDamageBucket(session, expectedDamageTotal)
    if not session then
        return false
    end

    local accountedDamage = 0
    for spellId, aggregate in pairs(session.spells or {}) do
        if spellId ~= UNATTRIBUTED_DAMAGE_SPELL_ID then
            accountedDamage = accountedDamage + (tonumber(aggregate.totalDamage) or 0)
        end
    end

    local missingDamage = math.max(0, (tonumber(expectedDamageTotal) or 0) - accountedDamage)
    local existing = session.spells and session.spells[UNATTRIBUTED_DAMAGE_SPELL_ID] or nil
    if missingDamage <= 0 then
        if existing then
            session.spells[UNATTRIBUTED_DAMAGE_SPELL_ID] = nil
        end
        return false
    end

    local aggregate = ensureSyntheticSpellAggregate(
        session,
        UNATTRIBUTED_DAMAGE_SPELL_ID,
        "Unattributed Damage",
        DEFAULT_SPELL_ICON_ID,
        "unattributed_damage"
    )
    setAggregateDamageAmount(aggregate, missingDamage)
    aggregate.castCount = 0
    aggregate.overkill = 0
    aggregate.absorbed = 0
    aggregate.estimated = true
    aggregate.source = Constants.PROVENANCE_SOURCE.ESTIMATED
    return true
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
        local unattributed = self:UpdateUnattributedDamageBucket(session, expectedDamageTotal)
        if unattributed and not session.damageBreakdownSource then
            session.damageBreakdownSource = "unattributed_damage_meter"
        end
        return true
    end

    local estimated = self:BackfillDamageBreakdownFromCasts(session, expectedDamageTotal)
    local unattributed = self:UpdateUnattributedDamageBucket(session, expectedDamageTotal)
    if estimated and not session.damageBreakdownSource then
        session.damageBreakdownSource = "estimated_from_casts"
    elseif unattributed and not session.damageBreakdownSource then
        session.damageBreakdownSource = "unattributed_damage_meter"
    end
    return estimated
end

function DamageMeterService:_buildSnapshotFromSessionType(session, sessionType)
    local function getSource(dmType)
        local combatSession = ApiCompat.GetCombatSessionFromType(sessionType, dmType)
        if not combatSession then return nil, nil, nil end
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
            sessionSource = ApiCompat.GetCombatSessionSourceFromType(sessionType, dmType, combatSource.sourceGUID, combatSource.sourceCreatureID)
        end
        if not sessionSource and combatSource and combatSource.isLocalPlayer then
            sessionSource = ApiCompat.GetCombatSessionSourceFromType(sessionType, dmType, nil, nil)
        end
        if not sessionSource and combatSource then
            sessionSource = { combatSpells = {}, maxAmount = combatSource.totalAmount or 0, totalAmount = combatSource.totalAmount or 0 }
        end
        return sessionSource, combatSource, combatSession
    end

    local damageSource, damageCombatSource, damageSession = getSource(Enum.DamageMeterType.DamageDone)
    local healingSource                                   = getSource(Enum.DamageMeterType.HealingDone)
    local absorbSource                                    = getSource(Enum.DamageMeterType.Absorbs)
    local interruptSource, interruptCombatSource          = getSource(Enum.DamageMeterType.Interrupts)
    local dispelSource, dispelCombatSource                = getSource(Enum.DamageMeterType.Dispels)
    local damageTakenSource, damageTakenCombatSource      = getSource(Enum.DamageMeterType.DamageTaken)
    local deathSource, deathCombatSource                  = getSource(Enum.DamageMeterType.Deaths)
    local avoidDamageTakenSource, avoidDamageTakenCombatSource = getSource(Enum.DamageMeterType.AvoidableDamageTaken)

    local dmDuration = (damageSession and tonumber(damageSession.durationSeconds) or 0)
    if dmDuration <= 0 then
        dmDuration = tonumber(ApiCompat.GetSessionDurationSeconds(sessionType)) or 0
    end

    local enemyDamageTaken, enemyDamageSpells = self:CollectEnemyDamageSnapshotForCurrent()

    local snapshot = self:BuildSnapshotFromSources(session, {
        duration = dmDuration > 0 and dmDuration or (session and session.duration) or 0,
        damageDone = getResolvedTotal(damageSource, damageCombatSource, damageSession),
        healingDone = getResolvedTotal(healingSource),
        damageTaken = getResolvedTotal(damageTakenSource, damageTakenCombatSource),
        absorbed = getResolvedTotal(absorbSource),
        interrupts = getResolvedTotal(interruptSource, interruptCombatSource),
        dispels = getResolvedTotal(dispelSource, dispelCombatSource),
        deaths = getResolvedTotal(deathSource, deathCombatSource),
        damageSpells = damageSource and damageSource.combatSpells or {},
        healingSpells = healingSource and healingSource.combatSpells or {},
        absorbSpells = absorbSource and absorbSource.combatSpells or {},
        enemyDamageTaken = enemyDamageTaken,
        enemyDamageSpells = enemyDamageSpells,
        avoidableDamageTaken = getResolvedTotal(avoidDamageTakenSource, avoidDamageTakenCombatSource),
        avoidableSpells = avoidDamageTakenSource and avoidDamageTakenSource.combatSpells or {},
    })
    snapshot.dmDurationSeconds = dmDuration > 0 and dmDuration or nil
    snapshot.deathRecap = tryImportDeathRecap(deathCombatSource)
    if snapshot.deathRecap then
        ns.Addon:Trace("death_recap.imported", {
            recapId    = snapshot.deathRecap.recapID,
            timeSeconds = snapshot.deathRecap.timeSeconds,
            hasEvents  = snapshot.deathRecap.events ~= nil,
        })
    end
    return snapshot
end

function DamageMeterService:CaptureCurrentSessionSnapshot(session)
    -- Fast-path: try the Expired session type first — it represents the just-finalized
    -- session with a locked duration, available immediately after combat ends.
    local expiredSnapshot = self:_buildSnapshotFromSessionType(session, Enum.DamageMeterSessionType.Expired)
    if expiredSnapshot and snapshotHasMeaningfulData(expiredSnapshot) then
        expiredSnapshot.capturedViaExpired = true
        self.currentSessionSnapshot = expiredSnapshot
        ns.Addon:Trace("damage_meter.current_snapshot", {
            damage = expiredSnapshot.damageDone or 0,
            enemyDamage = expiredSnapshot.enemyDamageTaken or 0,
            capturedViaExpired = true,
        })
        return true
    end

    -- Fall through to the Current session type path.
    local snapshot = self:_buildSnapshotFromSessionType(session, Enum.DamageMeterSessionType.Current)

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

    -- T015: Never overwrite an authoritative import with a lesser one.
    if session.importedTotals
        and session.importedTotals.importStatus == Constants.IMPORT_STATUS.IMPORTED_AUTHORITATIVE
    then
        return false
    end

    session.duration = tonumber(snapshot.duration) or session.duration or 0

    session.importedTotals = session.importedTotals or {}
    session.importedTotals.damageDone = tonumber(snapshot.damageDone) or 0
    session.importedTotals.healingDone = tonumber(snapshot.healingDone) or 0
    session.importedTotals.damageTaken = tonumber(snapshot.damageTaken) or 0
    session.importedTotals.absorbed = tonumber(snapshot.absorbed) or 0
    session.importedTotals.avoidableDamageTaken = tonumber(snapshot.avoidableDamageTaken) or 0
    session.importedTotals.avoidableSpells = snapshot.avoidableSpells or {}
    session.importedTotals.dmDurationSeconds = snapshot.dmDurationSeconds or nil

    session.localTotals = session.localTotals or {}
    local localDamageDone = tonumber(session.localTotals.damageDone) or tonumber(session.totals.damageDone) or 0
    local localHealingDone = tonumber(session.localTotals.healingDone) or tonumber(session.totals.healingDone) or 0
    local localDamageTaken = tonumber(session.localTotals.damageTaken) or tonumber(session.totals.damageTaken) or 0
    local localAbsorbed = tonumber(session.localTotals.absorbed) or tonumber(session.totals.absorbed) or 0

    session.totals.damageDone = localDamageDone > 0 and localDamageDone or session.importedTotals.damageDone
    session.totals.healingDone = localHealingDone > 0 and localHealingDone or session.importedTotals.healingDone
    session.totals.damageTaken = localDamageTaken > 0 and localDamageTaken or session.importedTotals.damageTaken
    session.totals.absorbed = localAbsorbed > 0 and localAbsorbed or session.importedTotals.absorbed
    session.totals.avoidableDamageTaken = session.importedTotals.avoidableDamageTaken or 0

    session.utility.interrupts = tonumber(snapshot.interrupts) or 0
    session.utility.successfulInterrupts = session.utility.interrupts
    session.utility.dispels = tonumber(snapshot.dispels) or 0
    session.survival.deaths = math.max(session.survival.deaths or 0, tonumber(snapshot.deaths) or 0)
    session.survival.totalAbsorbed = math.max(session.survival.totalAbsorbed or 0, localAbsorbed, session.importedTotals.absorbed or 0)
    if snapshot.deathRecap and not session.deathRecap then
        session.deathRecap = snapshot.deathRecap
    end

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

    -- T014: Set importStatus based on the resolved import path.
    session.importedTotals = session.importedTotals or {}
    if not session.importedTotals.importStatus then
        local hint   = session.import and session.import.finalDamageSourceHint
        local source = session.import and session.import.source
        if hint == "enemy_damage_taken_fallback" then
            session.importedTotals.importStatus = Constants.IMPORT_STATUS.IMPORTED_ENEMY_DAMAGE_TAKEN_FALLBACK
        elseif session.damageBreakdownSource == "estimated_from_casts" then
            session.importedTotals.importStatus = Constants.IMPORT_STATUS.ESTIMATED_FROM_CASTS
        elseif source == "historical" then
            session.importedTotals.importStatus = Constants.IMPORT_STATUS.IMPORTED_AUTHORITATIVE
        elseif source == "current" or source == "cached" then
            session.importedTotals.importStatus = Constants.IMPORT_STATUS.IMPORTED_CURRENT_SNAPSHOT
        end
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
        -- Synthetic fallback: API returned no spell-level data but we have a combat total.
        -- FAILED_NO_PLAYER_SOURCE is not applicable here — combatSource is always non-nil at
        -- this point (the nil case returns early above). Emit a synthetic so callers always
        -- receive a usable source with at least total-level damage data.
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
        if spellId ~= nil then
            local category = Constants.SPELL_CATEGORIES[spellId]
            local shouldSkipDamageSpell =
                (damageMeterType == Enum.DamageMeterType.DamageDone or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken)
                and category
                and category ~= Constants.SPELL_CATEGORY.OFFENSIVE

            if not shouldSkipDamageSpell then
                session.spells[spellId] = session.spells[spellId] or createSpellAggregate(spellId)
                local aggregate = session.spells[spellId]
                local spellInfo = spellId > 0 and ns.ApiCompat.GetSpellInfo(spellId) or nil
                if spellInfo then
                    aggregate.name = aggregate.name or spellInfo.name
                    aggregate.iconID = aggregate.iconID or spellInfo.iconID
                elseif spellId == 0 then
                    aggregate.name = aggregate.name or "Environmental"
                    aggregate.iconID = aggregate.iconID or DEFAULT_SPELL_ICON_ID
                    aggregate.syntheticKind = aggregate.syntheticKind or "environmental"
                end

                if damageMeterType == Enum.DamageMeterType.DamageDone or damageMeterType == Enum.DamageMeterType.EnemyDamageTaken then
                    aggregate.totalDamage = aggregate.totalDamage + (combatSpell.totalAmount or 0)
                    aggregate.overkill = aggregate.overkill + (combatSpell.overkillAmount or 0)
                    aggregate.hitCount = math.max(aggregate.hitCount or 0, 1)
                    aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0)
                    aggregate.source = Constants.PROVENANCE_SOURCE.DAMAGE_METER
                    aggregate.estimated = false
                    -- Floor castCount from hitCount when CLEU tracking didn't provide cast data.
                    if (aggregate.castCount or 0) == 0 and (aggregate.hitCount or 0) > 0 then
                        aggregate.castCount = aggregate.hitCount
                    end
                elseif damageMeterType == Enum.DamageMeterType.HealingDone then
                    aggregate.totalHealing = aggregate.totalHealing + (combatSpell.totalAmount or 0)
                    aggregate.hitCount = math.max(aggregate.hitCount or 0, 1)
                    aggregate.executeCount = math.max(aggregate.executeCount or 0, aggregate.hitCount or 0)
                    if (aggregate.castCount or 0) == 0 and (aggregate.hitCount or 0) > 0 then
                        aggregate.castCount = aggregate.hitCount
                    end
                elseif damageMeterType == Enum.DamageMeterType.Absorbs then
                    aggregate.absorbed = aggregate.absorbed + (combatSpell.totalAmount or 0)
                end
            end
        end
    end
end

-- T010: buildImportDiagnostics creates a new diagnostics record for tracking
-- the import decision path. Fields are populated by ImportSession and callers.
local function buildImportDiagnostics()
    return {
        baselineSessionId    = nil,
        candidateIds         = {},
        selectedCandidateId  = nil,
        selectedDmType       = nil,
        sourceResolutionPath = nil,
        durationDelta        = nil,
        opponentFitScore     = nil,
        signalScore          = nil,
        fallbackUsed         = nil,
        failureReason        = nil,
    }
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
        local opp = session.primaryOpponent
        opp.guid           = topSource.sourceGUID    or opp.guid
        opp.name           = topSource.name          or opp.name
        opp.classFile      = topSource.classFilename or opp.classFile
        opp.className      = topSource.classFilename or opp.className
        opp.specIconId     = topSource.specIconID    or opp.specIconId
        opp.classification = topSource.classification or opp.classification
    else
        local trackedUnit = getLatestTrackedUnit(session)
        if trackedUnit then
            session.primaryOpponent = session.primaryOpponent or trackedUnit
        end
    end

    -- Cross-reference arena slot data for spec resolution.
    -- DamageMeter sources provide GUID/name/class but not specId/specName.
    -- Prefer session.arena.slots (populated by SeedSessionIdentity) over
    -- art:GetSlots() which returns empty after EndMatch clears the match.
    if session.primaryOpponent then
        local opp = session.primaryOpponent
        if not opp.specId or not opp.specName then
            local slots = (session.arena and session.arena.slots) or {}
            -- Fallback to live ArenaRoundTracker if session slots are empty.
            if not next(slots) then
                local art = ns and ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("ArenaRoundTracker")
                if art then slots = art:GetSlots() end
            end
            for _, slot in pairs(slots) do
                if (slot.guid and slot.guid == opp.guid) or (slot.name and slot.name == opp.name) then
                    opp.specId     = opp.specId     or slot.prepSpecId
                    opp.specName   = opp.specName   or slot.prepSpecName
                    opp.specIconId = opp.specIconId or slot.prepSpecIconId
                    opp.classFile  = opp.classFile  or slot.prepClassFile or slot.classFile
                    break
                end
            end
        end
    end
end

function DamageMeterService:ImportSession(session)
    if not session or not self:IsSupported() then
        return false
    end

    -- T011: Create diagnostics record and thread it through the function.
    local diag = buildImportDiagnostics()
    diag.baselineSessionId = self.activeSessionBaselineId or self.lastSeenSessionId or 0

    local isAvailable, failureReason = self:IsAvailable()
    if not isAvailable then
        if not self.warnedUnavailable then
            local reasonText = failureReason == "damage_meter_disabled"
                and "Blizzard Damage Meter tracking is disabled in the default UI. "
                .. "Enable it: ESC > Options > Gameplay > Combat > Enable Damage Meter"
                or tostring(failureReason or "unknown")
            ns.Addon:Warn(string.format("Built-in Damage Meter is unavailable: %s", reasonText))
            self.warnedUnavailable = true
        end
        ns.Addon:Trace("damage_meter.import.unavailable", {
            reason = failureReason or "unknown",
            cvarEnabled = isDamageMeterEnabled(),
            isSupported = self:IsSupported(),
        })
        return false
    end

    -- Detailed pre-import diagnostics: log all available DM sessions and
    -- the current snapshot state so failures can be traced post-hoc.
    local allSessions = self:GetAvailableSessions()
    ns.Addon:Trace("damage_meter.import.begin", {
        context = session and session.context or "unknown",
        baseline = self.activeSessionBaselineId or 0,
        lastSeen = self.lastSeenSessionId or 0,
        availableSessions = #allSessions,
        hasCurrentSnapshot = self.currentSessionSnapshot ~= nil,
        currentSnapshotDamage = self.currentSessionSnapshot and self.currentSessionSnapshot.damageDone or 0,
        currentSnapshotEnemyDamage = self.currentSessionSnapshot and self.currentSessionSnapshot.enemyDamageTaken or 0,
        sessionDuration = session and session.duration or 0,
        inCombatLockdown = InCombatLockdown and InCombatLockdown() or false,
        isPvPRestricted = ApiCompat.IsPvPMatchRestricted and ApiCompat.IsPvPMatchRestricted() or false,
    })

    -- Re-capture the "current" DM snapshot now (import runs after stabilization
    -- delay, so DM data should be settled). The regen_end capture often fires
    -- before C_DamageMeter finalizes short-lived sessions (training dummies,
    -- quick duels).
    if not self.currentSessionSnapshot or not snapshotHasMeaningfulData(self.currentSessionSnapshot) then
        self:CaptureCurrentSessionSnapshot(session)
    end

    local candidateSessions = self:FindSessionsForImport()

    -- T017: Handle FAILED_DAMAGE_METER_UNAVAILABLE — no sessions available.
    if #candidateSessions == 0 then
        ns.Addon:Trace("damage_meter.import.none", {
            baseline = self.activeSessionBaselineId or 0,
        })
        session.importedTotals = session.importedTotals or {}
        session.importedTotals.importStatus = Constants.IMPORT_STATUS.FAILED_DAMAGE_METER_UNAVAILABLE
        diag.failureReason = "C_DamageMeter returned no sessions"
        session.importedTotals.importDiagnostics = diag
        return false
    end

    local selectedCandidate = nil

    for _, candidate in ipairs(candidateSessions) do
        local candidateId = candidate and candidate.sessionID
        if candidateId then
            -- T011: Track every candidate evaluated.
            diag.candidateIds[#diag.candidateIds + 1] = candidateId
            local builtCandidate = self:BuildHistoricalSnapshot(session, candidate, candidateId)
            local hasMeaningfulData = snapshotHasMeaningfulData(builtCandidate.snapshot)
            ns.Addon:Trace("damage_meter.import.candidate", {
                duration = builtCandidate.snapshot and builtCandidate.snapshot.duration or 0,
                durationDelta = builtCandidate.durationDelta or 0,
                damageEvidence = builtCandidate.damageEvidenceScore or 0,
                enemyDamage = builtCandidate.snapshot and builtCandidate.snapshot.enemyDamageTaken or 0,
                enemySpellTotal = builtCandidate.snapshot and builtCandidate.snapshot.enemyDamageSpellTotal or 0,
                localDamage = builtCandidate.snapshot and builtCandidate.snapshot.damageDone or 0,
                localSpellTotal = builtCandidate.snapshot and builtCandidate.snapshot.localDamageSpellTotal or 0,
                meaningful = hasMeaningfulData and true or false,
                opponentFitScore = builtCandidate.opponentFitScore or 0,
                score = builtCandidate.score or 0,
                sessionId = candidateId,
                signalCount = builtCandidate.signal and builtCandidate.signal.count or 0,
                signalScore = builtCandidate.signalScore or 0,
                sourceCount = builtCandidate.enemySources and #builtCandidate.enemySources or 0,
            })
            local selectedDamageScore = selectedCandidate and (selectedCandidate.damageEvidenceScore or 0) or 0
            local builtDamageScore = builtCandidate.damageEvidenceScore or 0
            local builtHasDamage = snapshotHasMeaningfulDamage(builtCandidate.snapshot)
            local selectedHasDamage = selectedCandidate and snapshotHasMeaningfulDamage(selectedCandidate.snapshot) or false

            if not selectedCandidate
                or builtCandidate.score > selectedCandidate.score
                or (
                    builtHasDamage
                    and not selectedHasDamage
                    and builtCandidate.score >= (selectedCandidate.score or 0) - 20
                )
                or (
                    builtCandidate.score == selectedCandidate.score
                    and (
                        builtDamageScore > selectedDamageScore
                        or (
                            builtDamageScore == selectedDamageScore
                            and (builtCandidate.sessionId or 0) > (selectedCandidate.sessionId or 0)
                        )
                    )
                )
            then
                selectedCandidate = builtCandidate
                selectedCandidate.hasMeaningfulData = hasMeaningfulData
            end
        end
    end

    -- T012: Populate diagnostics after selecting the winning candidate.
    if selectedCandidate then
        diag.selectedCandidateId = selectedCandidate.sessionId
        diag.durationDelta       = selectedCandidate.durationDelta
        diag.opponentFitScore    = selectedCandidate.opponentFitScore
        diag.signalScore         = selectedCandidate.signalScore
    else
        diag.failureReason = "no_candidate_matched"
    end

    local currentDamageScore = getDamageEvidenceScore(self.currentSessionSnapshot)
    local selectedDamageScore = selectedCandidate and (selectedCandidate.damageEvidenceScore or 0) or 0
    local shouldPreferCurrentSnapshot =
        self.currentSessionSnapshot
        and snapshotHasMeaningfulData(self.currentSessionSnapshot)
        and (
            not selectedCandidate
            or not snapshotHasMeaningfulDamage(selectedCandidate.snapshot)
            or (
                currentDamageScore > selectedDamageScore
                and selectedDamageScore <= 0
            )
            or (
                currentDamageScore >= selectedDamageScore + 25
                and (selectedCandidate.snapshot and (selectedCandidate.snapshot.damageDone or 0) or 0) <= 0
            )
        )

    if shouldPreferCurrentSnapshot then
        self:ApplyImportMetadata(session, {
            source = "current",
            confidence = 78,
            durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
            signalScore = 0,
            score = currentDamageScore,
            opponentFitScore = 0,
            enemySourceCount = 0,
        })
        ns.Addon:Trace("damage_meter.import.prefer_current_damage", {
            currentDamage = self.currentSessionSnapshot and self.currentSessionSnapshot.damageDone or 0,
            currentEnemyDamage = self.currentSessionSnapshot and self.currentSessionSnapshot.enemyDamageTaken or 0,
            currentDamageScore = currentDamageScore,
            selectedCandidateId = selectedCandidate and selectedCandidate.sessionId or 0,
            selectedDamageScore = selectedDamageScore,
        })
        local ok = self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
        if ok then
            local latestId = self:GetLatestSessionId()
            if latestId then
                self:ApplyPrimaryOpponent(session, latestId)
            end
        end
        if diag.failureReason ~= nil or #(diag.candidateIds or {}) > 0 then
            session.importedTotals = session.importedTotals or {}
            session.importedTotals.importDiagnostics = diag
        end
        return ok
    end

    if (not selectedCandidate or not selectedCandidate.hasMeaningfulData) and self.currentSessionSnapshot and snapshotHasMeaningfulData(self.currentSessionSnapshot) then
        self:ApplyImportMetadata(session, {
            source = "cached",
            confidence = 62,
            durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
            signalScore = 0,
            score = 0,
            opponentFitScore = 0,   -- T017: diagnostics on fallback path
            enemySourceCount = 0,
        })
        ns.Addon:Trace("damage_meter.import.cached_snapshot", {
            damage = self.currentSessionSnapshot.damageDone or 0,
            enemyDamage = self.currentSessionSnapshot.enemyDamageTaken or 0,
        })
        local ok = self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
        -- Apply opponent identity from DM enemy sources (all paths, not just historical).
        if ok then
            local oppSessionId = self.lastSeenSessionId or self:GetLatestSessionId()
            if oppSessionId then
                self:ApplyPrimaryOpponent(session, oppSessionId)
            end
        end
        -- IMPORTANT fix: persist partial diagnostics on early fallback returns
        if diag.failureReason ~= nil or #(diag.candidateIds or {}) > 0 then
            session.importedTotals = session.importedTotals or {}
            session.importedTotals.importDiagnostics = diag
        end
        return ok
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
                opponentFitScore = 0,   -- T017: diagnostics on fallback path
                enemySourceCount = 0,
            })
            ns.Addon:Trace("damage_meter.import.current_fallback", {
                damage = self.currentSessionSnapshot and self.currentSessionSnapshot.damageDone or 0,
                sessionId = 0,
            })
            local ok = self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
            -- Apply opponent identity from current DM session.
            if ok then
                local latestId = self:GetLatestSessionId()
                if latestId then
                    self:ApplyPrimaryOpponent(session, latestId)
                end
            end
            if diag.failureReason ~= nil or #(diag.candidateIds or {}) > 0 then
                session.importedTotals = session.importedTotals or {}
                session.importedTotals.importDiagnostics = diag
            end
            return ok
        elseif self.currentSessionSnapshot then
            self:ApplyImportMetadata(session, {
                source = "cached",
                confidence = 55,
                durationDelta = getDurationDelta(session and session.duration, self.currentSessionSnapshot and self.currentSessionSnapshot.duration),
                signalScore = 0,
                score = 0,
                opponentFitScore = 0,   -- T017: diagnostics on fallback path
                enemySourceCount = 0,
            })
            local ok = self:ApplySnapshotToSession(session, self.currentSessionSnapshot)
            -- Apply opponent identity from DM enemy sources.
            if ok then
                local oppSessionId = self.lastSeenSessionId or self:GetLatestSessionId()
                if oppSessionId then
                    self:ApplyPrimaryOpponent(session, oppSessionId)
                end
            end
            if diag.failureReason ~= nil or #(diag.candidateIds or {}) > 0 then
                session.importedTotals = session.importedTotals or {}
                session.importedTotals.importDiagnostics = diag
            end
            return ok
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
        -- T010: persist opponent fit score and enemy source count for diagnostics.
        opponentFitScore = selectedCandidate.opponentFitScore or 0,
        enemySourceCount = selectedCandidate.enemySources and #selectedCandidate.enemySources or 0,
    })
    ns.Addon:Trace("damage_meter.import.selected", {
        duration = selectedCandidate.snapshot and selectedCandidate.snapshot.duration or 0,
        durationDelta = selectedCandidate.durationDelta or 0,
        enemyDamage = selectedCandidate.snapshot and selectedCandidate.snapshot.enemyDamageTaken or 0,
        expected = selectedCandidate.snapshot and selectedCandidate.snapshot.expectedDamageDone or 0,
        localDamage = selectedCandidate.snapshot and selectedCandidate.snapshot.damageDone or 0,
        opponentFitScore = selectedCandidate.opponentFitScore or 0,
        score = selectedCandidate.score or 0,
        sessionId = sessionId,
        signalCount = selectedCandidate.signal and selectedCandidate.signal.count or 0,
        signalScore = selectedCandidate.signalScore or 0,
        sourceCount = selectedCandidate.enemySources and #selectedCandidate.enemySources or 0,
    })
    self:ApplySnapshotToSession(session, selectedCandidate.snapshot)

    local needsEnemyFallback = (session.totals.damageDone or 0) <= 0
        and (session.context == Constants.CONTEXT.TRAINING_DUMMY
            or session.context == Constants.CONTEXT.DUEL
            or session.context == Constants.CONTEXT.ARENA
            or session.context == Constants.CONTEXT.BATTLEGROUND)
    if needsEnemyFallback then
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

    -- Merge per-source enemy damage rows into SpellAttributionPipeline.
    -- This must run after ApplyPrimaryOpponent so session.primaryOpponent is set,
    -- and after the historical sessionId is resolved so we query the right session.
    local _, _, enemySources = self:CollectEnemyDamageSnapshotForSession(sessionId)
    local sap = ns.Addon:GetModule("SpellAttributionPipeline")
    if sap then
        for _, entry in ipairs(enemySources or {}) do
            sap:MergeDamageMeterSource(session, entry.combatSource, entry.sessionSource)
        end
        local importedTotal = selectedCandidate.snapshot
            and selectedCandidate.snapshot.enemyDamageTaken or 0
        sap:FinalizeReconciliation(session, importedTotal, "historical")
    end

    -- T057: Emit dm_spell timeline events for each merged player damage spell row.
    local tp = ns.Addon:GetModule("TimelineProducer")
    if tp then
        local _, resolvedDamageSpells = self:ResolveDamageSpellBreakdown(session, selectedCandidate.snapshot)
        for _, row in ipairs(resolvedDamageSpells or {}) do
            if row.spellID then
                local spellInfo = ns.ApiCompat.GetSpellInfo(row.spellID)
                tp:AppendTimelineEvent(session, {
                    t          = session.duration,
                    lane       = Constants.TIMELINE_LANE.DM_SPELL,
                    type       = "player_spell",
                    spellId    = row.spellID,
                    spellName  = spellInfo and spellInfo.name or nil,
                    amount     = row.totalAmount or 0,
                    source     = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
                    -- T011: summary_derived confidence; chronology="summary" so
                    -- chronological analysis (death attribution) skips this row.
                    confidence = Constants.ATTRIBUTION_CONFIDENCE.summary_derived,
                    chronology = "summary",
                })
            end
        end

        -- T058: Emit dm_enemy_spell timeline events for each enemy damage source row.
        -- T012: sourceGuid/sourceName/sourceClassFile promoted to top-level (canonical
        -- read path). Meta copy preserved for backward compat with existing UI consumers.
        for _, entry in ipairs(enemySources or {}) do
            local combatSource = entry.combatSource
            local sessionSource = entry.sessionSource
            local srcGuid      = combatSource and combatSource.sourceGUID or nil
            local srcName      = combatSource and combatSource.name or nil
            local srcClassFile = combatSource and combatSource.classFilename or nil
            for _, combatSpell in ipairs(sessionSource and sessionSource.combatSpells or {}) do
                if combatSpell.spellID then
                    tp:AppendTimelineEvent(session, {
                        t               = session.duration,
                        lane            = Constants.TIMELINE_LANE.DM_ENEMY_SPELL,
                        type            = "enemy_spell",
                        spellId         = combatSpell.spellID,
                        amount          = combatSpell.totalAmount or 0,
                        source          = Constants.PROVENANCE_SOURCE.DAMAGE_METER,
                        -- T011: summary chronology and confidence.
                        confidence      = Constants.ATTRIBUTION_CONFIDENCE.summary_derived,
                        chronology      = "summary",
                        -- T012: Top-level normalized source identity.
                        sourceGuid      = srcGuid,
                        sourceName      = srcName,
                        sourceClassFile = srcClassFile,
                        -- Backward-compat meta copy.
                        meta = {
                            sourceGuid      = srcGuid,
                            sourceName      = srcName,
                            sourceClassFile = srcClassFile,
                        },
                    })
                end
            end
        end

        -- T050: Merge Death Recap rows into timeline as dm_enemy_spell lane events.
        -- T011/T012: chronology="summary"; source identity promoted to top level.
        local deathRecap = self:CollectDeathRecapSnapshot(sessionId)
        if deathRecap and deathRecap.available and deathRecap.rows then
            for _, row in ipairs(deathRecap.rows) do
                tp:AppendTimelineEvent(session, {
                    t               = session.duration,
                    lane            = Constants.TIMELINE_LANE.DM_ENEMY_SPELL,
                    type            = "death_recap",
                    spellId         = row.spellId,
                    amount          = row.amount,
                    source          = Constants.PROVENANCE_SOURCE.DEATH_RECAP_SUMMARY,
                    confidence      = Constants.ATTRIBUTION_CONFIDENCE.summary_derived,
                    -- T011: Post-match summary; excluded from chronological analysis.
                    chronology      = "summary",
                    -- T012: Top-level normalized source identity.
                    sourceGuid      = row.sourceGuid,
                    sourceName      = row.sourceName,
                    sourceClassFile = row.sourceClassFile,
                    -- Backward-compat meta copy.
                    meta = {
                        sourceGuid      = row.sourceGuid,
                        sourceName      = row.sourceName,
                        sourceClassFile = row.sourceClassFile,
                    },
                })
            end
        end
    end

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

    -- T016: Finalize import authority and persist diagnostics when not authoritative.
    local ct = ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("CombatTracker")
    local currentImportStatus = session.importedTotals and session.importedTotals.importStatus
    if ct and ct.SetImportAuthority then
        ct:SetImportAuthority(session, currentImportStatus)
    else
        -- Fallback: derive authority directly without CombatTracker.
        session.importedTotals = session.importedTotals or {}
        if currentImportStatus then
            local authorityTable = Constants.IMPORT_AUTHORITY
            if authorityTable.authoritative[currentImportStatus] then
                session.importedTotals.totalAuthority = "authoritative"
            elseif authorityTable.estimated[currentImportStatus] then
                session.importedTotals.totalAuthority = "estimated"
            elseif authorityTable.failed[currentImportStatus] then
                session.importedTotals.totalAuthority = "failed"
            end
        end
    end
    local finalAuthority = session.importedTotals and session.importedTotals.totalAuthority
    if finalAuthority ~= "authoritative" then
        -- Only persist diagnostics for non-authoritative imports (saves SavedVariables space).
        local hasDiagData = (diag.failureReason ~= nil)
            or (diag.selectedCandidateId ~= nil)
            or (#(diag.candidateIds or {}) > 0)
        if hasDiagData then
            session.importedTotals.importDiagnostics = diag
        end
    end

    return true
end

ns.Addon:RegisterModule("DamageMeterService", DamageMeterService)
