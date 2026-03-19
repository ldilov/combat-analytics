local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers   = ns.Helpers

-- ArenaRoundTracker
-- Owns match and round identity independently of the combat session lifecycle.
-- Blizzard fires ARENA_OPPONENT_UPDATE and ARENA_PREP_OPPONENT_SPECIALIZATIONS
-- before combat begins and between rounds — CombatTracker's session does not
-- exist at those points. This module bridges that gap.
--
-- Responsibilities:
--   • Maintain stable matchKey and roundKey across multi-round arenas
--   • Preserve enemy slot state through "unseen" transitions
--   • Stage unresolved GUIDs from CLEU before unit frames become visible
--   • Compute weighted pressure scores for primaryOpponent selection
--   • Copy final round metadata into session.arena at FinalizeSession time
local ArenaRoundTracker = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Local helpers
-- ──────────────────────────────────────────────────────────────────────────────

local function nowServer()
    return ApiCompat.GetServerTime() or 0
end

local function nowPrecise()
    return Helpers and Helpers.Now and Helpers.Now() or GetTime()
end

local function safeGetMapId()
    if C_Map and C_Map.GetBestMapForUnit then
        return C_Map.GetBestMapForUnit("player")
    end
    return nil
end

-- Parse "arena1".."arena5" → slot integer, nil otherwise.
local function parseArenaSlot(unitToken)
    if type(unitToken) ~= "string" then return nil end
    local n = unitToken:match("^arena(%d+)$")
    return n and tonumber(n) or nil
end

local function shallowCopy(src)
    local dst = {}
    for k, v in pairs(src or {}) do dst[k] = v end
    return dst
end

-- Build a snapshot from a live unit frame. Returns nil if unit not visible.
local function buildUnitSnapshot(unitToken)
    if not ApiCompat.UnitExists(unitToken) then return nil end
    local guid = ApiCompat.GetUnitGUID(unitToken)
    if not guid then return nil end
    local localClass, engClass, classId = ApiCompat.GetUnitClass(unitToken)
    local localRace, engRace, raceId    = ApiCompat.GetUnitRace(unitToken)
    return {
        guid        = guid,
        name        = ApiCompat.GetUnitName(unitToken),
        unitToken   = unitToken,
        className   = localClass,
        classFile   = engClass,
        classId     = classId,
        raceName    = localRace,
        raceFile    = engRace,
        raceId      = raceId,
        level       = ApiCompat.GetUnitLevel(unitToken),
        healthMax   = ApiCompat.UnitHealthMax(unitToken),
        capturedAt  = nowPrecise(),
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Key builders
-- ──────────────────────────────────────────────────────────────────────────────

local function buildMatchKey(matchRecord)
    return table.concat({
        "player=" .. tostring(ApiCompat.GetPlayerGUID() or "unknown"),
        "map="    .. tostring(matchRecord.mapId  or 0),
        "ctx="    .. tostring(matchRecord.context    or Constants.CONTEXT.ARENA),
        "sub="    .. tostring(matchRecord.subcontext or "unknown"),
        "joined=" .. tostring(matchRecord.joinedAt   or 0),
    }, "|")
end

-- Roster signature: sorted per-slot entries so the key is stable regardless
-- of slot query order. Incorporates GUID when visible, falls back to prep data.
local function buildRosterSignature(slots)
    local rows = {}
    for slot = 1, 5 do
        local s = slots[slot]
        if s then
            rows[#rows + 1] = string.format("%d:%s:%s:%s",
                slot,
                s.guid         or "?",
                tostring(s.prepSpecId or 0),
                s.classFile    or "?"
            )
        end
    end
    table.sort(rows)
    return table.concat(rows, "|")
end

local function buildRoundKey(matchKey, roundIndex, slots)
    return string.format("%s|round=%d|roster=%s",
        matchKey, roundIndex, buildRosterSignature(slots))
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Slot management
-- ──────────────────────────────────────────────────────────────────────────────

local function ensureSlot(round, slot)
    if not round.slots[slot] then
        round.slots[slot] = {
            slot            = slot,
            unitToken       = "arena" .. tostring(slot),
            visible         = false,
            guid            = nil,
            name            = nil,
            className       = nil,
            classFile       = nil,
            classId         = nil,
            prepSpecId      = nil,
            prepSpecName    = nil,
            prepSpecIconId  = nil,
            prepRole        = nil,
            prepClassFile   = nil,
            damageToPlayer          = 0,
            damageTakenFromPlayer   = 0,
            ccOnPlayer              = 0,
            killParticipation       = 0,
            pressureScore           = 0,
            isDead                  = false,
            updateHistory           = {},
        }
    end
    return round.slots[slot]
end

local function refreshPressure(slot)
    slot.pressureScore =
        (slot.damageToPlayer        or 0) * 0.45 +
        (slot.damageTakenFromPlayer or 0) * 0.30 +
        (slot.ccOnPlayer            or 0) * 0.15 +
        (slot.killParticipation     or 0) * 0.10
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Module lifecycle
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:Initialize()
    self.currentMatch = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Match management
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:BeginMatch(context, subcontext)
    local matchRecord = {
        context      = context    or Constants.CONTEXT.ARENA,
        subcontext   = subcontext,
        joinedAt     = nowServer(),
        mapId        = safeGetMapId(),
        playerGuid   = ApiCompat.GetPlayerGUID(),
        prepOpponents = {},
        rounds       = {},
        currentRound = nil,
    }
    matchRecord.matchKey = buildMatchKey(matchRecord)
    self.currentMatch = matchRecord
    ns.Addon:Trace("arena_round.match.begin", {
        context    = matchRecord.context    or "nil",
        subcontext = matchRecord.subcontext or "nil",
        matchKey   = matchRecord.matchKey,
    })
    return matchRecord
end

function ArenaRoundTracker:GetCurrentMatch()
    return self.currentMatch
end

function ArenaRoundTracker:GetCurrentRound()
    return self.currentMatch and self.currentMatch.currentRound or nil
end

function ArenaRoundTracker:EndMatch()
    local matchRecord = self.currentMatch
    if not matchRecord then return end
    -- Close any still-active round (e.g. match went inactive without complete).
    if matchRecord.currentRound then
        self:EndRound("match_inactive", nil, nil)
    end
    ns.Addon:Trace("arena_round.match.end", {
        rounds = #(matchRecord.rounds),
    })
    self.currentMatch = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Round management
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:BeginRound(reason)
    -- Lazily create match record if we somehow missed PLAYER_JOINED_PVP_MATCH.
    local matchRecord = self.currentMatch
    if not matchRecord then
        matchRecord = self:BeginMatch(Constants.CONTEXT.ARENA, nil)
    end

    -- Guard: do not double-open a round.
    local existing = matchRecord.currentRound
    if existing and existing.state == "active" then
        return existing
    end

    local roundIndex = #matchRecord.rounds + 1
    local round = {
        roundIndex          = roundIndex,
        state               = "active",
        startReason         = reason or "unknown",
        startedAt           = nowServer(),
        slots               = {},
        guidToSlot          = {},
        unresolvedEnemyGuids = {},
        markers             = {},
    }

    -- Seed slot prep data from any previously captured ARENA_PREP specs.
    for slot, prep in pairs(matchRecord.prepOpponents) do
        local s = ensureSlot(round, slot)
        s.prepSpecId     = prep.specId
        s.prepSpecName   = prep.specName
        s.prepSpecIconId = prep.specIconId
        s.prepRole       = prep.role
        s.prepClassFile  = prep.classFile
    end

    round.rosterSignature = buildRosterSignature(round.slots)
    round.roundKey        = buildRoundKey(matchRecord.matchKey, roundIndex, round.slots)

    matchRecord.rounds[#matchRecord.rounds + 1] = round
    matchRecord.currentRound = round

    ns.Addon:Trace("arena_round.round.begin", {
        reason     = reason or "unknown",
        roundIndex = roundIndex,
        roundKey   = round.roundKey,
    })
    return round
end

function ArenaRoundTracker:EndRound(reason, winner, duration)
    local matchRecord = self.currentMatch
    local round = matchRecord and matchRecord.currentRound or nil
    if not round then return nil end

    round.state           = "complete"
    round.endReason       = reason   or "unknown"
    round.endedAt         = nowServer()
    round.winner          = winner
    round.duration        = duration
    -- Recompute stable keys with full roster data now available.
    round.rosterSignature = buildRosterSignature(round.slots)
    round.roundKey        = buildRoundKey(matchRecord.matchKey, round.roundIndex, round.slots)

    matchRecord.currentRound = nil

    ns.Addon:Trace("arena_round.round.end", {
        duration   = duration or 0,
        reason     = reason   or "unknown",
        roundIndex = round.roundIndex,
        roundKey   = round.roundKey,
        winner     = winner   or "unknown",
    })
    return round
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Prep specialization capture
-- Called from CombatTracker:HandleArenaPrepOpponentSpecializations()
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:CapturePrepSpecs()
    -- Lazily create match record; ARENA_PREP fires before PLAYER_JOINED_PVP_MATCH
    -- in some queue flows.
    local matchRecord = self.currentMatch
    if not matchRecord then
        matchRecord = self:BeginMatch(Constants.CONTEXT.ARENA, nil)
    end

    local count = ApiCompat.GetNumArenaOpponentSpecs()
    for slot = 1, count do
        local specId = ApiCompat.GetArenaOpponentSpec(slot)
        if specId and specId > 0 then
            local _, specName, _, specIcon, role, classFile =
                ApiCompat.GetSpecializationInfoByID(specId)
            matchRecord.prepOpponents[slot] = {
                slot          = slot,
                observedAt    = nowServer(),
                specId        = specId,
                specName      = specName,
                specIconId    = specIcon,
                role          = role,
                classFile     = classFile,
            }
        end
    end

    -- Also propagate into active round if one exists.
    local round = matchRecord.currentRound
    if round then
        for slot, prep in pairs(matchRecord.prepOpponents) do
            local s = ensureSlot(round, slot)
            s.prepSpecId     = s.prepSpecId     or prep.specId
            s.prepSpecName   = s.prepSpecName   or prep.specName
            s.prepSpecIconId = s.prepSpecIconId or prep.specIconId
            s.prepRole       = s.prepRole       or prep.role
            s.prepClassFile  = s.prepClassFile  or prep.classFile
        end
        round.rosterSignature = buildRosterSignature(round.slots)
        round.roundKey        = buildRoundKey(matchRecord.matchKey, round.roundIndex, round.slots)
    end

    ns.Addon:Trace("arena_round.prep.captured", {
        count = count,
    })
    return matchRecord.prepOpponents
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Opponent unit update
-- Called from CombatTracker:HandleArenaOpponentUpdate()
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:HandleArenaOpponentUpdate(unitToken, updateReason)
    local slot = parseArenaSlot(unitToken)
    if not slot then return nil end

    -- Ensure a round exists. ARENA_OPPONENT_UPDATE fires during prep before
    -- PVP_MATCH_ACTIVE, so BeginRound is called lazily here if needed.
    local round = self:GetCurrentRound()
    if not round then
        round = self:BeginRound("arena_opponent_update")
    end

    local s = ensureSlot(round, slot)
    s.lastUpdateReason = updateReason
    s.lastUpdateAt     = nowServer()
    s.updateHistory[#s.updateHistory + 1] = {
        reason = updateReason,
        at     = s.lastUpdateAt,
    }

    if updateReason == "unseen" then
        s.visible  = false
        s.hiddenAt = s.lastUpdateAt
    else
        local snapshot = buildUnitSnapshot(unitToken)
        if snapshot then
            s.visible    = true
            s.guid       = snapshot.guid
            s.name       = snapshot.name
            s.className  = snapshot.className
            s.classFile  = snapshot.classFile
            s.classId    = snapshot.classId
            s.raceName   = snapshot.raceName
            s.raceFile   = snapshot.raceFile
            s.raceId     = snapshot.raceId
            s.healthMax  = snapshot.healthMax
            s.lastSeenAt = snapshot.capturedAt
            round.guidToSlot[snapshot.guid] = slot

            -- If we had this GUID staged as unresolved, clear it.
            round.unresolvedEnemyGuids[snapshot.guid] = nil
        end

        -- Merge prep data (non-destructive; only fill if not already set).
        local prep = self.currentMatch and self.currentMatch.prepOpponents[slot]
        if prep then
            s.prepSpecId     = s.prepSpecId     or prep.specId
            s.prepSpecName   = s.prepSpecName   or prep.specName
            s.prepSpecIconId = s.prepSpecIconId or prep.specIconId
            s.prepRole       = s.prepRole       or prep.role
            s.prepClassFile  = s.prepClassFile  or prep.classFile
        end
    end

    -- Recompute round keys after any slot change.
    round.rosterSignature = buildRosterSignature(round.slots)
    round.roundKey        = buildRoundKey(self.currentMatch.matchKey, round.roundIndex, round.slots)
    return s
end

-- ──────────────────────────────────────────────────────────────────────────────
-- CLEU routing
-- Called from CombatTracker:HandleNormalizedEvent()
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:HandleCombatLogEvent(eventRecord)
    if not eventRecord then return end
    local round = self:GetCurrentRound()
    if not round then return end

    local playerGuid = ApiCompat.GetPlayerGUID()

    -- Identify the enemy in this event relative to the local player.
    local enemyGuid, enemyName
    if eventRecord.sourceMine and eventRecord.destGuid and eventRecord.destGuid ~= playerGuid then
        enemyGuid = eventRecord.destGuid
        enemyName = eventRecord.destName
    elseif eventRecord.destMine and eventRecord.sourceGuid and eventRecord.sourceGuid ~= playerGuid then
        enemyGuid = eventRecord.sourceGuid
        enemyName = eventRecord.sourceName
    end

    if not enemyGuid then return end

    -- Resolve enemy to a slot, or stage as unresolved for later reconciliation.
    local slotIndex = round.guidToSlot[enemyGuid]
    local s = slotIndex and round.slots[slotIndex] or nil

    if not s then
        -- Stage GUID — will be linked when ARENA_OPPONENT_UPDATE fires.
        if not round.unresolvedEnemyGuids[enemyGuid] then
            round.unresolvedEnemyGuids[enemyGuid] = {
                guid      = enemyGuid,
                name      = enemyName,
                firstSeen = nowServer(),
                lastSeen  = nowServer(),
                actions   = 0,
            }
        else
            round.unresolvedEnemyGuids[enemyGuid].lastSeen = nowServer()
            round.unresolvedEnemyGuids[enemyGuid].name =
                round.unresolvedEnemyGuids[enemyGuid].name or enemyName
        end
        round.unresolvedEnemyGuids[enemyGuid].actions =
            round.unresolvedEnemyGuids[enemyGuid].actions + 1
        return
    end

    -- Accumulate pressure metrics per slot.
    local evType = eventRecord.eventType
    if evType == "damage" then
        if eventRecord.destMine and eventRecord.sourceGuid == enemyGuid then
            s.damageToPlayer = (s.damageToPlayer or 0) + (eventRecord.amount or 0)
        elseif eventRecord.sourceMine and eventRecord.destGuid == enemyGuid then
            s.damageTakenFromPlayer = (s.damageTakenFromPlayer or 0) + (eventRecord.amount or 0)
        end
        refreshPressure(s)
    elseif evType == "aura" and eventRecord.destMine and eventRecord.sourceGuid == enemyGuid then
        -- Count CC applications onto the player (AURA_APPLIED on self).
        if eventRecord.subEvent == "SPELL_AURA_APPLIED" then
            s.ccOnPlayer = (s.ccOnPlayer or 0) + 1
            refreshPressure(s)
        end
    elseif evType == "death" and eventRecord.destGuid == enemyGuid then
        s.isDead          = true
        s.killParticipation = (s.killParticipation or 0) + 1
        refreshPressure(s)
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Primary enemy selection (weighted pressure score)
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:GetPrimaryEnemy()
    local round = self:GetCurrentRound()
    if not round then return nil end
    local best = nil
    for slot = 1, 5 do
        local s = round.slots[slot]
        if s and s.guid then
            if not best or (s.pressureScore or 0) > (best.pressureScore or 0) then
                best = s
            end
        end
    end
    return best
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Session export
-- Called from CombatTracker:FinalizeSession() to persist round state
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:CopyStateIntoSession(session)
    if not session then return end
    local matchRecord = self.currentMatch
    -- Allow finalization with either match or round data, not both required.
    if not matchRecord then return end

    local round = matchRecord.currentRound
        -- If match is already ended, pick the last completed round.
        or (matchRecord.rounds[#matchRecord.rounds])

    session.arena = {
        matchKey         = matchRecord.matchKey,
        mapId            = matchRecord.mapId,
        joinedAt         = matchRecord.joinedAt,
        roundIndex       = round and round.roundIndex       or nil,
        roundKey         = round and round.roundKey         or nil,
        rosterSignature  = round and round.rosterSignature  or nil,
        state            = round and round.state            or "unknown",
        slots            = {},
        guidToSlot       = {},
        unresolvedGuids  = {},
    }

    if round then
        for slot, s in pairs(round.slots) do
            session.arena.slots[slot] = shallowCopy(s)
            -- Strip the updateHistory list from the persisted record — it is
            -- diagnostically useful at runtime but wastes SavedVariables space.
            session.arena.slots[slot].updateHistory = nil
        end
        for guid, slotIdx in pairs(round.guidToSlot) do
            session.arena.guidToSlot[guid] = slotIdx
        end
        for guid, unresolved in pairs(round.unresolvedEnemyGuids) do
            session.arena.unresolvedGuids[guid] = shallowCopy(unresolved)
        end
    end

    -- Overlay primaryOpponent from weighted pressure data.
    local primary = self:GetPrimaryEnemy()
    if primary and primary.guid then
        local opp = session.primaryOpponent or {}
        opp.guid        = opp.guid        or primary.guid
        opp.name        = opp.name        or primary.name
        opp.classFile   = opp.classFile   or primary.classFile or primary.prepClassFile
        opp.specId      = opp.specId      or primary.prepSpecId
        opp.specIconId  = opp.specIconId  or primary.prepSpecIconId
        opp.pressureScore = primary.pressureScore
        session.primaryOpponent = opp
    end

    ns.Addon:Trace("arena_round.session.export", {
        matchKey   = session.arena.matchKey or "nil",
        roundIndex = session.arena.roundIndex or 0,
        roundKey   = session.arena.roundKey or "nil",
        slots      = session.arena.slots and (function()
            local n = 0
            for _ in pairs(session.arena.slots) do n = n + 1 end
            return n
        end)() or 0,
    })
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
ns.Addon:RegisterModule("ArenaRoundTracker", ArenaRoundTracker)
