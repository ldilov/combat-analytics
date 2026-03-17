local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers

local SessionClassifier = {}

local IDENTITY_CONTEXT_PRIORITY = {
    [Constants.CONTEXT.GENERAL] = 10,
    [Constants.CONTEXT.WORLD_PVP] = 20,
    [Constants.CONTEXT.TRAINING_DUMMY] = 30,
    [Constants.CONTEXT.DUEL] = 40,
    [Constants.CONTEXT.BATTLEGROUND] = 90,
    [Constants.CONTEXT.ARENA] = 100,
}

local function isMineGuid(guid)
    if not guid then
        return false
    end
    local playerGuid = ApiCompat.GetPlayerGUID()
    if guid == playerGuid then
        return true
    end
    return ApiCompat.IsGuidPet(guid)
end

local function normalizeName(name)
    local value = string.lower(Helpers.Trim(tostring(name or "")) or "")
    value = string.gsub(value, "%s+", " ")
    return value
end

local function shortName(name)
    local normalized = normalizeName(name)
    return string.match(normalized, "^[^-]+") or normalized
end

local function namesEquivalent(left, right)
    local leftFull = normalizeName(left)
    local rightFull = normalizeName(right)
    if leftFull == "" or rightFull == "" then
        return false
    end
    return leftFull == rightFull or shortName(leftFull) == shortName(rightFull)
end

local function getContextPriority(context)
    return IDENTITY_CONTEXT_PRIORITY[context] or 0
end

local function createIdentity(kind, subkind, source)
    return {
        kind = kind or Constants.CONTEXT.GENERAL,
        subkind = subkind,
        provisional = true,
        confidence = 0,
        startedAtServer = ApiCompat.GetServerTime(),
        startedAtPrecise = Helpers.Now(),
        opponentGuid = nil,
        opponentName = nil,
        opponentCreatureId = nil,
        opponentFlags = nil,
        source = source or "state",
        reason = "initial",
        subjectKey = nil,
        evidence = {
            duelScore = 0,
            dummyScore = 0,
            worldPvpScore = 0,
            repeatedHostilePlayerEvents = 0,
            lastHostilePlayerGuid = nil,
            sawPendingDuel = false,
            sawConfirmedDuelGuid = false,
            sawHostilePlayerGuid = false,
            sawDummyCreatureId = false,
            sawDummyName = false,
            sawArenaState = false,
            sawBattlegroundState = false,
        },
    }
end

local function createUnitInfo(unitToken)
    if not unitToken or not ApiCompat.UnitExists(unitToken) then
        return nil
    end

    local guid = ApiCompat.GetUnitGUID(unitToken)
    if not guid then
        return nil
    end

    return {
        guid = guid,
        name = ApiCompat.GetUnitName(unitToken),
        unitToken = unitToken,
        isPlayer = ApiCompat.UnitIsPlayer(unitToken),
        isHostile = ApiCompat.UnitCanAttack("player", unitToken) or ApiCompat.UnitIsEnemy("player", unitToken),
        creatureId = ApiCompat.GetCreatureIdFromGUID(guid),
    }
end

local function createInfoFromEvent(classifier, eventRecord, guid, name, isPlayer, isHostile, flags)
    if not guid or isMineGuid(guid) then
        return nil
    end

    local creatureId = ApiCompat.GetCreatureIdFromGUID(guid)
    return {
        guid = guid,
        name = name,
        unitToken = nil,
        isPlayer = isPlayer and true or false,
        isHostile = isHostile and true or false,
        creatureId = creatureId,
        flags = flags,
        isTrainingDummyById = creatureId and Constants.TRAINING_DUMMY_CREATURE_IDS[creatureId] or false,
        isTrainingDummyByName = classifier:IsTrainingDummyName(name),
        subEvent = eventRecord and eventRecord.subEvent or nil,
    }
end

local function getIdentitySourceTag(source)
    return source or "state"
end

function SessionClassifier:Initialize()
    self.zoneName, self.mapId = ApiCompat.GetCurrentZoneName()
end

function SessionClassifier:RefreshZone()
    self.zoneName, self.mapId = ApiCompat.GetCurrentZoneName()
end

function SessionClassifier:ExpirePendingDuel()
    local pending = ns.Addon.runtime.pendingDuel
    if not pending or pending.state ~= "pending" then
        return
    end

    local ageSeconds = ApiCompat.GetServerTime() - (pending.requestedAt or 0)
    if ageSeconds > (Constants.DUEL_PENDING_TIMEOUT_SECONDS or 20) then
        ns.Addon:Trace("session.identity.duel_expired", {
            opponent = pending.opponentNameNormalized or "unknown",
        })
        ns.Addon.runtime.pendingDuel = nil
    end
end

function SessionClassifier:SetPendingDuel(opponentName, isToTheDeath)
    ns.Addon.runtime.pendingDuel = {
        opponentName = opponentName,
        opponentNameNormalized = normalizeName(opponentName),
        opponentGuid = nil,
        requestedAt = ApiCompat.GetServerTime(),
        confirmedAt = nil,
        isToTheDeath = isToTheDeath and true or false,
        state = "pending",
    }
end

function SessionClassifier:GetPendingDuel()
    self:ExpirePendingDuel()
    return ns.Addon.runtime.pendingDuel
end

function SessionClassifier:ClearPendingDuel()
    ns.Addon.runtime.pendingDuel = nil
end

function SessionClassifier:MarkPendingDuelActive(guid)
    local pending = self:GetPendingDuel()
    if not pending then
        return
    end
    if pending.opponentGuid and guid and pending.opponentGuid ~= guid then
        return
    end
    pending.state = "active"
end

function SessionClassifier:IsTrainingDummyName(name)
    if Helpers.IsBlank(name) then
        return false
    end
    for _, pattern in ipairs(Constants.TRAINING_DUMMY_PATTERNS) do
        if Helpers.ContainsIgnoreCase(name, pattern) then
            return true
        end
    end
    return false
end

function SessionClassifier:GetTrainingDummyScore(info)
    if not info or not info.guid or info.isPlayer then
        return 0
    end

    local creatureId = info.creatureId
    local isDummyById = creatureId and Constants.TRAINING_DUMMY_CREATURE_IDS[creatureId] or false
    local isDummyByName = info.isTrainingDummyByName
    if isDummyById then
        return 100
    end
    if creatureId and isDummyByName then
        return 85
    end
    if isDummyByName then
        return 70
    end
    return 0
end

function SessionClassifier:IsTrainingDummyEvent(eventRecord)
    if not eventRecord then
        return false
    end

    local sourceInfo = createInfoFromEvent(self, eventRecord, eventRecord.sourceGuid, eventRecord.sourceName, eventRecord.sourcePlayer, false, eventRecord.sourceFlags)
    local destInfo = createInfoFromEvent(self, eventRecord, eventRecord.destGuid, eventRecord.destName, eventRecord.destPlayer, false, eventRecord.destFlags)

    return (eventRecord.sourceMine and self:GetTrainingDummyScore(destInfo) >= Constants.TRAINING_DUMMY_PROMOTION_THRESHOLD)
        or (eventRecord.destMine and self:GetTrainingDummyScore(sourceInfo) >= Constants.TRAINING_DUMMY_PROMOTION_THRESHOLD)
end

function SessionClassifier:IsWorldPvpEvent(eventRecord)
    if not eventRecord then
        return false
    end
    local mineInvolved = eventRecord.sourceMine or eventRecord.destMine
    local hostilePlayerInvolved = eventRecord.sourceHostilePlayer or eventRecord.destHostilePlayer
    return mineInvolved and hostilePlayerInvolved and not ApiCompat.IsBattleground() and not ApiCompat.IsMatchConsideredArena()
end

function SessionClassifier:IsPlayerEngagement(eventRecord)
    if not eventRecord then
        return false
    end
    return eventRecord.sourceMine or eventRecord.destMine
end

function SessionClassifier:ResolveArenaSubcontext()
    if ApiCompat.IsSoloShuffle() then
        return Constants.SUBCONTEXT.SOLO_SHUFFLE
    end
    if ApiCompat.IsRatedArena() then
        return Constants.SUBCONTEXT.RATED_ARENA
    end
    if ApiCompat.IsArenaSkirmish() then
        return Constants.SUBCONTEXT.SKIRMISH
    end
    if ApiCompat.IsInBrawl() then
        return Constants.SUBCONTEXT.BRAWL
    end
    return Constants.SUBCONTEXT.RATED_ARENA
end

function SessionClassifier:ResolveBattlegroundSubcontext()
    if ApiCompat.IsRatedSoloRBG() or ApiCompat.IsSoloRBG() then
        return Constants.SUBCONTEXT.SOLO_RBG
    end
    if ApiCompat.IsRatedBattleground() then
        return Constants.SUBCONTEXT.RATED_BATTLEGROUND
    end
    return Constants.SUBCONTEXT.RANDOM_BATTLEGROUND
end

function SessionClassifier:BuildIdentity(kind, subkind, source)
    return createIdentity(kind, subkind, source)
end

function SessionClassifier:RefreshIdentitySubjectKey(session)
    if not session or not session.identity then
        return
    end

    local identity = session.identity
    identity.subjectKey = table.concat({
        identity.kind or "unknown",
        identity.opponentGuid or "none",
        tostring(identity.opponentCreatureId or 0),
        tostring(math.floor(identity.startedAtPrecise or 0)),
    }, ":")
end

function SessionClassifier:EnsureSessionIdentity(session, source)
    if not session then
        return nil
    end

    if not session.identity then
        session.identity = createIdentity(session.context or Constants.CONTEXT.GENERAL, session.subcontext, source)
    end

    if not session.identity.evidence then
        session.identity.evidence = createIdentity().evidence
    end
    self:RefreshIdentitySubjectKey(session)
    return session.identity
end

function SessionClassifier:InitializeSessionIdentity(session, context, subcontext, source)
    if not session then
        return nil
    end

    local identity = createIdentity(context or session.context or Constants.CONTEXT.GENERAL, subcontext or session.subcontext, source)
    session.identity = identity

    if identity.kind == Constants.CONTEXT.ARENA then
        identity.provisional = false
        identity.confidence = 100
        identity.evidence.sawArenaState = true
        identity.reason = "state_arena"
    elseif identity.kind == Constants.CONTEXT.BATTLEGROUND then
        identity.provisional = false
        identity.confidence = 100
        identity.evidence.sawBattlegroundState = true
        identity.reason = "state_battleground"
    elseif identity.kind == Constants.CONTEXT.DUEL then
        identity.provisional = true
        identity.confidence = 70
        identity.evidence.sawPendingDuel = self:GetPendingDuel() ~= nil
        identity.evidence.duelScore = 70
        identity.reason = "duel_requested"
    elseif identity.kind == Constants.CONTEXT.TRAINING_DUMMY then
        identity.provisional = true
        identity.confidence = 70
        identity.evidence.dummyScore = 70
        identity.reason = "dummy_candidate"
    elseif identity.kind == Constants.CONTEXT.WORLD_PVP then
        identity.provisional = true
        identity.confidence = 65
        identity.evidence.worldPvpScore = 65
        identity.reason = "hostile_player_candidate"
    else
        identity.provisional = true
        identity.confidence = 25
        identity.reason = "general_candidate"
    end

    self:RefreshIdentitySubjectKey(session)
    return identity
end

function SessionClassifier:UpdateOpponentIdentity(session, info)
    if not session or not info or not info.guid or isMineGuid(info.guid) then
        return
    end

    local identity = self:EnsureSessionIdentity(session)
    if not identity then
        return
    end

    identity.opponentGuid = info.guid or identity.opponentGuid
    identity.opponentName = info.name or identity.opponentName
    identity.opponentCreatureId = info.creatureId or identity.opponentCreatureId
    identity.opponentFlags = info.flags or identity.opponentFlags
    self:RefreshIdentitySubjectKey(session)
end

function SessionClassifier:PromoteSessionIdentity(session, context, subcontext, confidence, source, reason, info)
    if not session or not context then
        return false
    end

    local identity = self:EnsureSessionIdentity(session, source)
    local currentPriority = getContextPriority(identity.kind)
    local nextPriority = getContextPriority(context)
    local targetConfidence = math.max(0, math.min(100, tonumber(confidence) or 0))
    local isUpgrade = nextPriority > currentPriority
        or context == identity.kind
        or (identity.provisional and nextPriority == currentPriority)

    if not isUpgrade then
        return false
    end

    local previousKind = identity.kind
    local previousConfidence = identity.confidence or 0
    local previousProvisional = identity.provisional

    if nextPriority > currentPriority or context == identity.kind then
        session.context = context
        session.subcontext = subcontext
        identity.kind = context
        identity.subkind = subcontext
    end

    identity.confidence = math.max(previousConfidence, targetConfidence)
    identity.source = getIdentitySourceTag(source)
    identity.reason = reason or identity.reason
    identity.provisional = identity.confidence < 95 and context ~= Constants.CONTEXT.ARENA and context ~= Constants.CONTEXT.BATTLEGROUND
    self:UpdateOpponentIdentity(session, info)

    if context == Constants.CONTEXT.DUEL and info and info.guid then
        local pending = self:GetPendingDuel()
        if pending then
            pending.opponentGuid = info.guid
            pending.confirmedAt = pending.confirmedAt or ApiCompat.GetServerTime()
            pending.state = "active"
        end
    end

    self:RefreshIdentitySubjectKey(session)

    if previousKind ~= identity.kind or previousConfidence ~= identity.confidence or previousProvisional ~= identity.provisional then
        ns.Addon:Trace("session.identity.promote", {
            confidence = identity.confidence or 0,
            from = previousKind or "unknown",
            opponentGuid = identity.opponentGuid or "none",
            reason = identity.reason or "unknown",
            to = identity.kind or "unknown",
        })
    end

    return true
end

function SessionClassifier:TryConfirmPendingDuelInfo(info, source)
    local pending = self:GetPendingDuel()
    if not pending or (pending.state ~= "pending" and pending.state ~= "confirmed") then
        return false
    end
    if not info or not info.guid or not info.name or not info.isPlayer or not info.isHostile then
        return false
    end
    if not namesEquivalent(info.name, pending.opponentName) then
        return false
    end

    pending.opponentGuid = info.guid
    pending.confirmedAt = pending.confirmedAt or ApiCompat.GetServerTime()
    pending.state = "confirmed"
    ns.Addon:Trace("session.identity.duel_confirmed", {
        guid = info.guid,
        name = info.name or "unknown",
        source = getIdentitySourceTag(source),
    })
    return true
end

function SessionClassifier:TryConfirmPendingDuel(eventRecord)
    if not eventRecord then
        return false
    end

    if eventRecord.sourceMine and eventRecord.destGuid then
        return self:TryConfirmPendingDuelInfo(createInfoFromEvent(self, eventRecord, eventRecord.destGuid, eventRecord.destName, eventRecord.destPlayer, eventRecord.destHostilePlayer, eventRecord.destFlags), "cleu")
    end
    if eventRecord.destMine and eventRecord.sourceGuid then
        return self:TryConfirmPendingDuelInfo(createInfoFromEvent(self, eventRecord, eventRecord.sourceGuid, eventRecord.sourceName, eventRecord.sourcePlayer, eventRecord.sourceHostilePlayer, eventRecord.sourceFlags), "cleu")
    end
    return false
end

function SessionClassifier:GetWorldPvpScore(session, info, source)
    if not session or not info or not info.guid or not info.isPlayer or not info.isHostile then
        return 0
    end
    if ApiCompat.IsBattleground() or ApiCompat.IsMatchConsideredArena() then
        return 0
    end

    local pending = self:GetPendingDuel()
    if pending and pending.opponentGuid and pending.opponentGuid == info.guid then
        return 0
    end

    local identity = self:EnsureSessionIdentity(session, source)
    local evidence = identity.evidence
    if evidence.lastHostilePlayerGuid == info.guid then
        evidence.repeatedHostilePlayerEvents = (evidence.repeatedHostilePlayerEvents or 0) + 1
    else
        evidence.lastHostilePlayerGuid = info.guid
        evidence.repeatedHostilePlayerEvents = 1
    end

    local score = 70
    score = score + math.min(math.max((evidence.repeatedHostilePlayerEvents or 1) - 1, 0) * 10, 20)
    if source == "combat_start" then
        score = score + 10
    end
    if info.unitToken == "focus" or info.unitToken == "target" then
        score = score + 5
    end

    return math.min(score, 100)
end

function SessionClassifier:AccumulateUnitEvidence(session, unitToken, source)
    local info = createUnitInfo(unitToken)
    if not info or isMineGuid(info.guid) then
        return false
    end

    info.isTrainingDummyById = info.creatureId and Constants.TRAINING_DUMMY_CREATURE_IDS[info.creatureId] or false
    info.isTrainingDummyByName = self:IsTrainingDummyName(info.name)

    local identity = self:EnsureSessionIdentity(session, source)
    if not identity then
        return false
    end

    local evidence = identity.evidence
    if self:GetPendingDuel() then
        evidence.sawPendingDuel = true
    end

    self:UpdateOpponentIdentity(session, info)

    if self:TryConfirmPendingDuelInfo(info, source) then
        evidence.sawConfirmedDuelGuid = true
        evidence.duelScore = math.max(evidence.duelScore or 0, 95)
        self:PromoteSessionIdentity(
            session,
            Constants.CONTEXT.DUEL,
            self:GetPendingDuel() and self:GetPendingDuel().isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil,
            95,
            source,
            "pending_duel_guid_confirmed",
            info
        )
        self:MarkPendingDuelActive(info.guid)
        return true
    end

    local dummyScore = self:GetTrainingDummyScore(info)
    if dummyScore > 0 then
        evidence.dummyScore = math.max(evidence.dummyScore or 0, dummyScore)
        evidence.sawDummyCreatureId = evidence.sawDummyCreatureId or (info.isTrainingDummyById or (info.creatureId and info.isTrainingDummyByName) or false)
        evidence.sawDummyName = evidence.sawDummyName or info.isTrainingDummyByName or false
        if dummyScore >= (Constants.TRAINING_DUMMY_PROMOTION_THRESHOLD or 70) then
            self:PromoteSessionIdentity(
                session,
                Constants.CONTEXT.TRAINING_DUMMY,
                nil,
                dummyScore,
                source,
                info.isTrainingDummyById and "dummy_creature_id" or "dummy_name_and_guid",
                info
            )
            return true
        end
    end

    return false
end

function SessionClassifier:AccumulateEvidence(session, eventRecord)
    if not session or not eventRecord then
        return false
    end

    local promoted = false
    if eventRecord.sourceMine and eventRecord.destGuid then
        local destInfo = createInfoFromEvent(self, eventRecord, eventRecord.destGuid, eventRecord.destName, eventRecord.destPlayer, eventRecord.destHostilePlayer, eventRecord.destFlags)
        if destInfo then
            local identity = self:EnsureSessionIdentity(session, "cleu")
            if identity then
                if self:TryConfirmPendingDuelInfo(destInfo, "cleu") then
                    identity.evidence.sawConfirmedDuelGuid = true
                    identity.evidence.duelScore = math.max(identity.evidence.duelScore or 0, 95)
                    promoted = self:PromoteSessionIdentity(session, Constants.CONTEXT.DUEL, self:GetPendingDuel() and self:GetPendingDuel().isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil, 95, "cleu", "pending_duel_guid_confirmed", destInfo) or promoted
                end
                local dummyScore = self:GetTrainingDummyScore(destInfo)
                if dummyScore > 0 then
                    identity.evidence.dummyScore = math.max(identity.evidence.dummyScore or 0, dummyScore)
                    if dummyScore >= (Constants.TRAINING_DUMMY_PROMOTION_THRESHOLD or 70) then
                        promoted = self:PromoteSessionIdentity(session, Constants.CONTEXT.TRAINING_DUMMY, nil, dummyScore, "cleu", "dummy_guid_confirmed", destInfo) or promoted
                    end
                end
            end
        end
    elseif eventRecord.destMine and eventRecord.sourceGuid then
        local sourceInfo = createInfoFromEvent(self, eventRecord, eventRecord.sourceGuid, eventRecord.sourceName, eventRecord.sourcePlayer, eventRecord.sourceHostilePlayer, eventRecord.sourceFlags)
        if sourceInfo then
            local identity = self:EnsureSessionIdentity(session, "cleu")
            if identity then
                if self:TryConfirmPendingDuelInfo(sourceInfo, "cleu") then
                    identity.evidence.sawConfirmedDuelGuid = true
                    identity.evidence.duelScore = math.max(identity.evidence.duelScore or 0, 95)
                    promoted = self:PromoteSessionIdentity(session, Constants.CONTEXT.DUEL, self:GetPendingDuel() and self:GetPendingDuel().isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil, 95, "cleu", "pending_duel_guid_confirmed", sourceInfo) or promoted
                end
            end
        end
    end

    return promoted
end

function SessionClassifier:RefreshSessionIdentity(session, preferredUnitToken, source)
    if not session then
        return nil
    end

    local identity = self:EnsureSessionIdentity(session, source)
    if not identity then
        return nil
    end

    if identity.kind == Constants.CONTEXT.ARENA then
        identity.evidence.sawArenaState = true
        identity.provisional = false
        identity.confidence = 100
        identity.reason = identity.reason or "state_arena"
    elseif identity.kind == Constants.CONTEXT.BATTLEGROUND then
        identity.evidence.sawBattlegroundState = true
        identity.provisional = false
        identity.confidence = 100
        identity.reason = identity.reason or "state_battleground"
    end

    local orderedTokens = {}
    local seen = {}
    local function addToken(unitToken)
        if unitToken and not seen[unitToken] then
            seen[unitToken] = true
            orderedTokens[#orderedTokens + 1] = unitToken
        end
    end

    addToken(preferredUnitToken)
    addToken("target")
    addToken("focus")

    for _, unitToken in ipairs(orderedTokens) do
        self:AccumulateUnitEvidence(session, unitToken, source)
    end

    if session.primaryOpponent then
        self:SyncSessionIdentityFromOpponent(session, session.primaryOpponent, source)
    end

    self:RefreshIdentitySubjectKey(session)
    return identity
end

function SessionClassifier:SyncSessionIdentityFromOpponent(session, opponent, source)
    if not session or not opponent then
        return
    end

    local info = {
        guid = opponent.guid,
        name = opponent.name,
        unitToken = opponent.unitToken,
        isPlayer = opponent.isPlayer,
        isHostile = opponent.isHostile,
        creatureId = ApiCompat.GetCreatureIdFromGUID(opponent.guid),
        flags = opponent.flags,
        isTrainingDummyById = false,
        isTrainingDummyByName = self:IsTrainingDummyName(opponent.name),
    }
    info.isTrainingDummyById = info.creatureId and Constants.TRAINING_DUMMY_CREATURE_IDS[info.creatureId] or false

    local identity = self:EnsureSessionIdentity(session, source)
    if not identity then
        return
    end

    self:UpdateOpponentIdentity(session, info)

    local dummyScore = self:GetTrainingDummyScore(info)
    if dummyScore > 0 then
        identity.evidence.dummyScore = math.max(identity.evidence.dummyScore or 0, dummyScore)
        identity.evidence.sawDummyCreatureId = identity.evidence.sawDummyCreatureId or (info.isTrainingDummyById or (info.creatureId and info.isTrainingDummyByName) or false)
        identity.evidence.sawDummyName = identity.evidence.sawDummyName or info.isTrainingDummyByName or false
    end
end

function SessionClassifier:ResolveContext(eventRecord)
    local pendingDuel = self:GetPendingDuel()
    if pendingDuel and self:TryConfirmPendingDuel(eventRecord) then
        return Constants.CONTEXT.DUEL, pendingDuel.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil
    elseif pendingDuel then
        return Constants.CONTEXT.DUEL, pendingDuel.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil
    end

    if ApiCompat.IsMatchConsideredArena() or ApiCompat.IsSoloShuffle() then
        return Constants.CONTEXT.ARENA, self:ResolveArenaSubcontext()
    end

    if ApiCompat.IsBattleground() then
        return Constants.CONTEXT.BATTLEGROUND, self:ResolveBattlegroundSubcontext()
    end

    if self:IsTrainingDummyEvent(eventRecord) then
        return Constants.CONTEXT.TRAINING_DUMMY, nil
    end

    if self:IsWorldPvpEvent(eventRecord) then
        return nil, nil
    end

    if self:IsPlayerEngagement(eventRecord) and ns.Addon:GetSetting("includeGeneralCombat") then
        return Constants.CONTEXT.GENERAL, nil
    end

    return nil, nil
end

function SessionClassifier:ResolveContextFromState()
    local pendingDuel = self:GetPendingDuel()

    if ApiCompat.IsMatchConsideredArena() or ApiCompat.IsSoloShuffle() then
        return Constants.CONTEXT.ARENA, self:ResolveArenaSubcontext(), nil
    end

    if ApiCompat.IsBattleground() then
        return Constants.CONTEXT.BATTLEGROUND, self:ResolveBattlegroundSubcontext(), nil
    end

    for _, unitToken in ipairs({ "target", "focus" }) do
        local info = createUnitInfo(unitToken)
        if info then
            info.isTrainingDummyById = info.creatureId and Constants.TRAINING_DUMMY_CREATURE_IDS[info.creatureId] or false
            info.isTrainingDummyByName = self:IsTrainingDummyName(info.name)

            if pendingDuel and self:TryConfirmPendingDuelInfo(info, "state") then
                return Constants.CONTEXT.DUEL, pendingDuel.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil, unitToken
            end

            if self:GetTrainingDummyScore(info) >= (Constants.TRAINING_DUMMY_PROMOTION_THRESHOLD or 70) then
                return Constants.CONTEXT.TRAINING_DUMMY, nil, unitToken
            end

            if info.isPlayer and info.isHostile and ns.Addon:GetSetting("includeGeneralCombat") then
                return Constants.CONTEXT.GENERAL, nil, unitToken
            end
        end
    end

    if pendingDuel then
        return Constants.CONTEXT.DUEL, pendingDuel.isToTheDeath and Constants.SUBCONTEXT.TO_THE_DEATH or nil, nil
    end

    if ns.Addon:GetSetting("includeGeneralCombat") then
        return Constants.CONTEXT.GENERAL, nil, nil
    end

    return nil, nil, nil
end

function SessionClassifier:CanPromoteExistingSession(currentSession, context, subcontext)
    if not currentSession or not context then
        return false
    end

    if currentSession.context == context and currentSession.subcontext == subcontext then
        return false
    end

    if currentSession.context == Constants.CONTEXT.GENERAL and getContextPriority(context) > getContextPriority(currentSession.context) then
        return true
    end

    if currentSession.context == Constants.CONTEXT.WORLD_PVP and context == Constants.CONTEXT.DUEL then
        return true
    end

    if currentSession.identity and currentSession.identity.provisional and getContextPriority(context) >= getContextPriority(currentSession.context) then
        return true
    end

    return false
end

function SessionClassifier:ShouldStartNewSession(currentSession, eventRecord)
    local context, subcontext = self:ResolveContext(eventRecord)
    if not context then
        return false, nil, nil
    end
    if not currentSession then
        return true, context, subcontext
    end
    if currentSession.context == context and currentSession.subcontext == subcontext then
        return false, context, subcontext
    end
    if self:CanPromoteExistingSession(currentSession, context, subcontext) then
        return false, context, subcontext
    end
    return true, context, subcontext
end

function SessionClassifier:ShouldExpandTrackedActors(session, eventRecord)
    if not session or not eventRecord then
        return false
    end

    local tracked = session.trackedActorGuids or {}
    local sourceTracked = eventRecord.sourceGuid and tracked[eventRecord.sourceGuid]
    local destTracked = eventRecord.destGuid and tracked[eventRecord.destGuid]
    if not sourceTracked and not destTracked then
        return false
    end

    if eventRecord.sourceGuid and not tracked[eventRecord.sourceGuid] then
        return true
    end
    if eventRecord.destGuid and not tracked[eventRecord.destGuid] then
        return true
    end
    return false
end

function SessionClassifier:IsOpponentGuid(session, guid)
    if not session or not guid then
        return false
    end
    if isMineGuid(guid) then
        return false
    end
    return session.trackedActorGuids and session.trackedActorGuids[guid] or false
end

ns.Addon:RegisterModule("SessionClassifier", SessionClassifier)
