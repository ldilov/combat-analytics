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

-- Maps a GUID to its arena slot via indexed lookup (round.guidToSlot), falling
-- back to a linear scan over all slots. Returns nil when no slot matches.
local function findSlotByGuid(round, guid)
    if not round or not guid then return nil end
    local indexed = round.guidToSlot and round.guidToSlot[guid]
    if indexed and round.slots[indexed] and round.slots[indexed].guid == guid then
        return round.slots[indexed]
    end
    for _, s in pairs(round.slots) do
        if s.guid == guid then return s end
    end
    return nil
end

-- Initializes selection evidence on a slot if not already present. Idempotent.
local function ensureSelectionEvidence(slot)
    if not slot.selectionEvidence then
        slot.selectionEvidence = {
            damageToPlayer = 0,
            deathRecap     = 0,
            identityBias   = 0,
            visibilityBias = 0,
        }
    end
    return slot.selectionEvidence
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

-- Known non-"unseen" reasons for ARENA_OPPONENT_UPDATE. Any value outside
-- this set is still treated as "visible" (safe fallback), but an unknown
-- reason is recorded in the trace log so it can be investigated.
local KNOWN_VISIBLE_UPDATE_REASONS = {
    seen = true,
}

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
            fieldConfidence         = {},
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
    self.inspectQueue = {}
    self.inspectBusy = false
    self.inspectElapsed = 0
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

function ArenaRoundTracker:GetSlots()
    local round = self:GetCurrentRound()
    return round and round.slots or {}
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
        completionState     = "complete",  -- T044: default; upgraded by EndRound
        startReason         = reason or "unknown",
        startedAt           = nowServer(),
        slots               = {},
        guidToSlot          = {},
        unresolvedEnemyGuids = {},
        markers             = {},
    }

    -- Seed slot prep data from any previously captured ARENA_PREP specs.
    local seedTs = nowServer()
    for slot, prep in pairs(matchRecord.prepOpponents) do
        local s = ensureSlot(round, slot)
        s.prepSpecId     = prep.specId
        s.prepSpecName   = prep.specName
        s.prepSpecIconId = prep.specIconId
        s.prepRole       = prep.role
        s.prepClassFile  = prep.classFile
        -- T040/T043: Set field confidence for prep-sourced fields.
        s.fieldConfidence.spec           = "prep"
        s.fieldConfidence.specLearnedAt  = seedTs
        s.fieldConfidence.class          = "prep"
        s.fieldConfidence.classLearnedAt = seedTs
    end

    round.rosterSignature = buildRosterSignature(round.slots)
    round.roundKey        = buildRoundKey(matchRecord.matchKey, roundIndex, round.slots)

    matchRecord.rounds[#matchRecord.rounds + 1] = round
    matchRecord.currentRound = round

    -- T027: Initialize UnitGraphService for this new round so prior-round actor
    -- data is archived and the working set starts clean for this session.
    local ugs = ns.Addon:GetModule("UnitGraphService")
    if ugs and ugs.InitializeForSession then
        pcall(ugs.InitializeForSession, ugs)
    end

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

    -- T044: Determine completionState based on roster and disconnect signals.
    local hasUnresolved  = false
    local hasDisconnect  = false
    for slot = 1, 5 do
        local s = round.slots[slot]
        if s then
            -- A slot that was created but never became visible is unresolved.
            if not s.visible and not s.guid then
                hasUnresolved = true
            end
            -- Check update history for disconnect-related reasons.
            for _, entry in ipairs(s.updateHistory or {}) do
                if entry.reason == "disconnect" or entry.reason == "destroyed" then
                    hasDisconnect = true
                end
            end
        end
    end
    -- Also treat unresolved enemy GUIDs as evidence of a leaver.
    for _ in pairs(round.unresolvedEnemyGuids or {}) do
        hasUnresolved = true
        break
    end
    if hasDisconnect then
        round.completionState = "partial_disconnect"
    elseif hasUnresolved then
        round.completionState = "partial_leaver"
    else
        round.completionState = "complete"
    end

    -- Recompute stable keys with full roster data now available.
    round.rosterSignature = buildRosterSignature(round.slots)
    round.roundKey        = buildRoundKey(matchRecord.matchKey, round.roundIndex, round.slots)

    -- T089: Show adaptation card between rounds in Solo Shuffle
    if matchRecord.subcontext == Constants.SUBCONTEXT.SOLO_SHUFFLE then
        local scoutService = ns.Addon:GetModule("ArenaScoutService")
        local scoutView = ns.Addon:GetModule("ArenaScoutView")
        if scoutService and scoutView then
            local previousRoundSession = nil
            -- Find the most recent finalized session from CombatStore
            local store = ns.Addon:GetModule("CombatStore")
            if store then
                local sessions = store:GetRecentSessions(1)
                previousRoundSession = sessions and sessions[1] or nil
            end
            local currentPrepState = { slots = round.slots, roundNumber = matchRecord.roundCount or 1 }
            local ok, adaptCard = pcall(scoutService.BuildAdaptationCard, scoutService, previousRoundSession, currentPrepState)
            if ok and adaptCard then
                scoutView:ShowAdaptation(adaptCard)
            end
        end
    end

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
        local ts = nowServer()
        for slot, prep in pairs(matchRecord.prepOpponents) do
            local s = ensureSlot(round, slot)
            s.prepSpecId     = s.prepSpecId     or prep.specId
            s.prepSpecName   = s.prepSpecName   or prep.specName
            s.prepSpecIconId = s.prepSpecIconId or prep.specIconId
            s.prepRole       = s.prepRole       or prep.role
            s.prepClassFile  = s.prepClassFile  or prep.classFile
            -- T040/T043: Set field confidence for prep-sourced fields.
            s.fieldConfidence.spec           = "prep"
            s.fieldConfidence.specLearnedAt  = ts
            s.fieldConfidence.class          = "prep"
            s.fieldConfidence.classLearnedAt = ts
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
        -- T034: Propagate visibility-lost into UnitGraphService so it emits
        -- the arena_opponent_hidden VISIBILITY lane event.
        if s.guid then
            local ugsUnseen = ns.Addon:GetModule("UnitGraphService")
            if ugsUnseen and ugsUnseen.MarkUnseen then
                pcall(ugsUnseen.MarkUnseen, ugsUnseen, s.guid)
            end
        end
    else
        -- Negative-space: trace any updateReason that is not in the known-visible
        -- set. The existing logic is still correct (treat as visible), but the
        -- unknown value is surfaced in the trace log for investigation.
        if not KNOWN_VISIBLE_UPDATE_REASONS[updateReason] then
            ns.Addon:Trace("arena_round.opponent.unknown_reason", {
                unit   = unitToken,
                reason = tostring(updateReason),
            })
        end
        local snapshot = buildUnitSnapshot(unitToken)
        -- Reject snapshots whose GUID is the local player.  After a match ends
        -- arena unit tokens can briefly become invalid or transition through
        -- states where UnitGUID returns the player's own GUID; storing that
        -- would cause the player to appear as their own opponent in history.
        local myGuid = ApiCompat.GetPlayerGUID()
        if snapshot and snapshot.guid ~= myGuid then
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

            -- T041/T043: Set field confidence for visible-sourced fields.
            local visTs = nowServer()
            s.fieldConfidence.guid           = "visible"
            s.fieldConfidence.guidLearnedAt  = visTs
            s.fieldConfidence.name           = "visible"
            s.fieldConfidence.nameLearnedAt  = visTs
            s.fieldConfidence.class          = "visible"
            s.fieldConfidence.classLearnedAt = visTs

            -- T027: Push this slot assignment into UnitGraphService so it can
            -- use arena_slot_mapping priority for identity resolution.
            local ugs = ns.Addon:GetModule("UnitGraphService")
            if ugs and ugs.UpdateFromArenaSlot then
                pcall(ugs.UpdateFromArenaSlot, ugs,
                    slot,
                    snapshot.guid,
                    snapshot.name,
                    snapshot.classFile,
                    s.prepSpecId)
            end
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

    -- Queue inspect for PvP talent capture (Task 1.4)
    if s.visible and updateReason ~= "unseen" then
        self:QueueInspect(unitToken)
    end

    return s
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Opponent PvP Talent Inspect (Task 1.4)
-- FIFO queue, one inspect per 0.5s via OnUpdate polling.
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:QueueInspect(unitToken)
    if not unitToken or not ApiCompat.UnitExists(unitToken) then return end
    -- Avoid duplicates
    for _, queued in ipairs(self.inspectQueue) do
        if queued == unitToken then return end
    end
    self.inspectQueue[#self.inspectQueue + 1] = unitToken
end

function ArenaRoundTracker:ProcessInspectQueue(elapsed)
    self.inspectElapsed = (self.inspectElapsed or 0) + elapsed
    if self.inspectElapsed < 0.5 then return end
    self.inspectElapsed = 0

    if self.inspectBusy then return end
    if #self.inspectQueue == 0 then return end

    -- Never call NotifyInspect while in combat lockdown.  On Midnight the
    -- inspect action is restricted during active combat and calling it from
    -- addon code triggers ADDON_ACTION_BLOCKED.  We keep the queue intact
    -- and retry on the next OnUpdate tick once combat ends.
    if InCombatLockdown and InCombatLockdown() then return end

    local unitToken = table.remove(self.inspectQueue, 1)
    if not ApiCompat.UnitExists(unitToken) then return end

    self.inspectBusy = true
    self.inspectTarget = unitToken
    ApiCompat.NotifyInspect(unitToken)
end

function ArenaRoundTracker:HandleInspectReady()
    self.inspectBusy = false
    local unitToken = self.inspectTarget
    self.inspectTarget = nil
    if not unitToken then return end

    local round = self:GetCurrentRound()
    if not round then return end

    local slot = parseArenaSlot(unitToken)
    if not slot or not round.slots[slot] then return end

    -- Capture PvP talents via inspect API.  Wrap in pcall: arena unit
    -- tokens may return secret values from inspect APIs during combat.
    local pvpTalents = {}
    if C_SpecializationInfo and C_SpecializationInfo.GetInspectSelectedPvpTalent then
        for talentIndex = 1, 4 do
            local ok, talentId = pcall(C_SpecializationInfo.GetInspectSelectedPvpTalent, unitToken, talentIndex)
            if ok and talentId and not ApiCompat.IsSecretValue(talentId) and talentId > 0 then
                pvpTalents[#pvpTalents + 1] = talentId
            end
        end
    end

    -- T042/T043: Timestamp for inspect-sourced field confidence.
    local inspTs = nowServer()

    if #pvpTalents > 0 then
        round.slots[slot].pvpTalents = pvpTalents
        -- T042/T043: Field confidence for pvpTalents.
        round.slots[slot].fieldConfidence.pvpTalents          = "inspect"
        round.slots[slot].fieldConfidence.pvpTalentsLearnedAt = inspTs
        ns.Addon:Trace("arena_round.inspect.pvp_talents", {
            slot = slot,
            unit = unitToken,
            talents = table.concat(pvpTalents, ","),
        })
    end

    -- Task 2.3: Capture opponent talent build import string via C_Traits (12.0.0+).
    -- HasValidInspectData() ensures the inspect cache is populated before reading.
    if ApiCompat.HasValidInspectData() then
        local importString = ApiCompat.GenerateInspectImportString(unitToken)
        if importString and type(importString) == "string" and importString ~= "" then
            round.slots[slot].talentImportString = importString
            -- T042/T043: Field confidence for talentImportString.
            round.slots[slot].fieldConfidence.talentImportString          = "inspect"
            round.slots[slot].fieldConfidence.talentImportStringLearnedAt = inspTs
            ns.Addon:Trace("arena_round.inspect.talent_import", {
                slot = slot,
                unit = unitToken,
                length = #importString,
            })
        end
    end

    -- T042/T043: Upgrade spec confidence to "inspect" (from "prep" or "visible").
    round.slots[slot].fieldConfidence.spec          = "inspect"
    round.slots[slot].fieldConfidence.specLearnedAt = inspTs
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Native DR tracking (Task 2.1 — C_SpellDiminish)
-- ──────────────────────────────────────────────────────────────────────────────

--- Handle UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED.
--- Stores native DR state per arena unit per category into the current round.
--- @param unitTarget string — e.g. "arena1"
--- @param trackerInfo table — {category, startTime, duration, showCountdown, isImmune}
function ArenaRoundTracker:HandleDiminishStateUpdated(unitTarget, trackerInfo)
    if not unitTarget or not trackerInfo then return end
    local slot = parseArenaSlot(unitTarget)
    if not slot then return end

    local round = self:GetCurrentRound()
    if not round or not round.slots[slot] then return end

    round.slots[slot].drState = round.slots[slot].drState or {}

    -- trackerInfo is a raw WoW API payload and may carry secret/restricted fields
    -- under the Midnight taint model. Access each field through pcall to prevent
    -- taint propagation from unreadable fields to the addon frame.
    local category, startTime, duration, isImmune, showCountdown

    local ok, err = pcall(function()
        category      = trackerInfo.category
        startTime     = trackerInfo.startTime
        duration      = trackerInfo.duration
        isImmune      = trackerInfo.isImmune
        showCountdown = trackerInfo.showCountdown
    end)
    if not ok then
        ns.Addon:Trace("arena_round.dr_taint_guard", { unit = unitTarget, err = tostring(err) })
        return
    end

    if category == nil then return end

    round.slots[slot].drState[category] = {
        startTime     = startTime,
        duration      = duration,
        isImmune      = isImmune or false,
        showCountdown = showCountdown or false,
    }

    ns.Addon:Trace("arena_round.dr_updated", {
        slot     = slot,
        unit     = unitTarget,
        category = category,
        immune   = isImmune and "true" or "false",
    })
end

--- Returns the current DR state table for a given unit token (e.g. "arena1").
--- Returns nil when no round or no DR data exists for the given unit.
function ArenaRoundTracker:GetDiminishState(unitToken)
    local round = self:GetCurrentRound()
    if not round then return nil end
    local slot = parseArenaSlot(unitToken)
    if not slot or not round.slots[slot] then return nil end
    return round.slots[slot].drState
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Session-pressure hydration
-- Called from CopyStateIntoSession before exporting to the session record.
-- Reads post-session evidence (attribution + death recap timeline) and writes
-- per-slot primarySelectionScore and selectionEvidence for GetPrimaryEnemy.
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:ApplySessionPressure(round, session)
    if not round then return end
    local myGuid = ApiCompat.GetPlayerGUID()

    -- Step 1: Reset all derived selection fields to zero for a clean slate.
    for _, s in pairs(round.slots) do
        s.primarySelectionScore = 0
        ensureSelectionEvidence(s)
        s.selectionEvidence.damageToPlayer = 0
        s.selectionEvidence.deathRecap     = 0
        s.selectionEvidence.identityBias   = 0
        s.selectionEvidence.visibilityBias = 0
    end

    -- Step 2: Hydrate damageToPlayer from session.attribution.bySource.
    -- Each bySource entry is keyed by enemy GUID; totalAmount is the aggregate.
    local bySource = session and type(session.attribution) == "table" and session.attribution.bySource
    if bySource then
        for sourceGuid, sourceData in pairs(bySource) do
            if sourceGuid ~= myGuid then
                local slot = findSlotByGuid(round, sourceGuid)
                if slot then
                    local ev = ensureSelectionEvidence(slot)
                    ev.damageToPlayer = ev.damageToPlayer + (sourceData.totalAmount or 0)
                end
            end
        end
    end

    -- Step 3: Hydrate deathRecap from DM_ENEMY_SPELL timeline events of type "death_recap".
    for _, ev in ipairs(session and session.timelineEvents or {}) do
        if ev.lane == Constants.TIMELINE_LANE.DM_ENEMY_SPELL and ev.type == "death_recap" then
            local sourceGuid = ev.meta and ev.meta.sourceGuid
            if sourceGuid and sourceGuid ~= myGuid then
                local slot = findSlotByGuid(round, sourceGuid)
                if slot then
                    local sev = ensureSelectionEvidence(slot)
                    sev.deathRecap = sev.deathRecap + (ev.amount or 0)
                end
            end
        end
    end

    -- Step 4: Apply identity and visibility biases; compute composite score.
    -- preferredOpponentGuid is the slot GUID from the last successful export.
    local preferredGuid = round.preferredOpponentGuid
    for _, s in pairs(round.slots) do
        if s.guid and s.guid ~= myGuid then
            local sev = ensureSelectionEvidence(s)

            -- Identity bias: +12 when this slot is the previously preferred enemy.
            if preferredGuid and s.guid == preferredGuid then
                sev.identityBias = 12
            end

            -- Visibility bias: +1 for currently visible slots.
            if s.visible then
                sev.visibilityBias = 1
            end

            -- Composite score: damageToPlayer has highest weight, followed by kill
            -- participation, with identity and visibility as tie-breaker adjustments.
            s.primarySelectionScore =
                sev.damageToPlayer   * 0.45 +
                (s.killParticipation or 0) * 0.10 +
                sev.identityBias +
                sev.visibilityBias
        end
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Primary enemy selection (evidence-based stable ranking)
-- ──────────────────────────────────────────────────────────────────────────────

-- GetPrimaryEnemy(preferredGuid) — returns (slot, strategy).
--
-- Ranking policy (stable, deterministic):
--   1. Highest primarySelectionScore (set by ApplySessionPressure)
--   2. Visible slots over hidden
--   3. Most recently seen (lastSeenAt)
--   4. Lowest slot index (deterministic tie-breaker)
--
-- 85% sticky GUID rule: when meaningful pressure data exists (bestScore > 0),
-- the previously preferred opponent is retained if its score is >= 85% of the
-- best slot's score, preventing identity flapping between nearly-tied enemies.
--
-- Strategy labels:
--   "preferred_guid_sticky" — retained by sticky rule
--   "highest_score"         — normal score-based selection
--   "latest_visible"        — fallback: no pressure data, picked by visibility
--   "no_visible_slot"       — all eligible slots are invisible or tied at zero
--   "no_round"              — no active or recent round exists
--
-- The player's own GUID is always excluded from consideration.
function ArenaRoundTracker:GetPrimaryEnemy(preferredGuid)
    local round = self:GetCurrentRound()
    if not round then return nil, "no_round" end

    local myGuid = ApiCompat.GetPlayerGUID()

    -- Collect eligible slots: non-nil GUID, not the local player.
    local eligible = {}
    for slot = 1, 5 do
        local s = round.slots[slot]
        if s and s.guid and s.guid ~= myGuid then
            eligible[#eligible + 1] = s
        end
    end

    if #eligible == 0 then return nil, "no_visible_slot" end

    -- Find the best score across all eligible slots.
    local bestScore = 0
    for _, s in ipairs(eligible) do
        local score = s.primarySelectionScore or 0
        if score > bestScore then bestScore = score end
    end

    -- 85% sticky preferred GUID rule (only when pressure data is meaningful).
    if preferredGuid and bestScore > 0 then
        for _, s in ipairs(eligible) do
            if s.guid == preferredGuid then
                local prefScore = s.primarySelectionScore or 0
                if prefScore >= bestScore * 0.85 then
                    return s, "preferred_guid_sticky"
                end
                break
            end
        end
    end

    -- Stable sort: score → visible → recently seen → lowest slot index.
    table.sort(eligible, function(a, b)
        local aScore = a.primarySelectionScore or 0
        local bScore = b.primarySelectionScore or 0
        if aScore ~= bScore then return aScore > bScore end

        local aVis = a.visible and 1 or 0
        local bVis = b.visible and 1 or 0
        if aVis ~= bVis then return aVis > bVis end

        local aSeen = a.lastSeenAt or 0
        local bSeen = b.lastSeenAt or 0
        if aSeen ~= bSeen then return aSeen > bSeen end

        return (a.slot or 99) < (b.slot or 99)
    end)

    local best = eligible[1]
    if not best then return nil, "no_visible_slot" end

    -- Determine strategy label.
    local strategy
    if (best.primarySelectionScore or 0) > 0 then
        strategy = "highest_score"
    elseif best.visible then
        strategy = "latest_visible"
    else
        strategy = "no_visible_slot"
    end

    return best, strategy
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Lightweight identity seed — copies slot GUIDs, names, and specs into the
-- session WITHOUT the pressure scoring (which depends on attribution data that
-- is populated later by the DamageMeter import).  Called BEFORE the import so
-- collectExpectedOpponentGuids has populated slot data for candidate scoring.
-- ──────────────────────────────────────────────────────────────────────────────

function ArenaRoundTracker:SeedSessionIdentity(session)
    if not session then return end
    local matchRecord = self.currentMatch
    if not matchRecord then return end
    local round = matchRecord.currentRound or (matchRecord.rounds[#matchRecord.rounds])
    if not round then return end

    session.arena = session.arena or {}
    session.arena.matchKey    = session.arena.matchKey or matchRecord.matchKey
    session.arena.slots       = session.arena.slots or {}
    session.arena.guidToSlot  = session.arena.guidToSlot or {}

    for slot, s in pairs(round.slots) do
        session.arena.slots[slot] = session.arena.slots[slot] or {}
        local dst = session.arena.slots[slot]
        dst.guid          = dst.guid          or s.guid
        dst.name          = dst.name          or s.name
        dst.classFile     = dst.classFile     or s.classFile
        dst.className     = dst.className     or s.className
        dst.classId       = dst.classId       or s.classId
        dst.prepSpecId    = dst.prepSpecId    or s.prepSpecId
        dst.prepSpecName  = dst.prepSpecName  or s.prepSpecName
        dst.prepClassFile = dst.prepClassFile or s.prepClassFile
        if s.guid then
            session.arena.guidToSlot[s.guid] = slot
        end
    end

    -- Seed primaryOpponent from best available slot if not already set.
    if not session.primaryOpponent or not session.primaryOpponent.guid then
        local primary = self:GetPrimaryEnemy(nil)
        if primary and primary.guid then
            session.primaryOpponent = session.primaryOpponent or {}
            session.primaryOpponent.guid      = primary.guid
            session.primaryOpponent.name      = primary.name
            session.primaryOpponent.classFile = primary.classFile or primary.prepClassFile
            session.primaryOpponent.specId    = primary.prepSpecId
            session.primaryOpponent.specName  = primary.prepSpecName
        end
    end
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

    -- Step 1: Hydrate slot pressure scores from post-session evidence before
    -- exporting. This must run while session.attribution and session.timelineEvents
    -- are fully populated (i.e. after DamageMeter import completes).
    if round then
        self:ApplySessionPressure(round, session)
    end

    session.arena = {
        matchKey         = matchRecord.matchKey,
        mapId            = matchRecord.mapId,
        joinedAt         = matchRecord.joinedAt,
        roundIndex       = round and round.roundIndex        or nil,
        roundKey         = round and round.roundKey          or nil,
        rosterSignature  = round and round.rosterSignature   or nil,
        state            = round and round.state             or "unknown",
        completionState  = round and round.completionState   or "complete",  -- T044
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

    -- Task 1.3: accumulate total CC duration received by the player
    local totalCcDuration = 0
    for _, cc in ipairs(session.ccReceived or {}) do
        totalCcDuration = totalCcDuration + (cc.duration or 0)
    end
    session.arena.ccDurationReceived = totalCcDuration

    -- Step 2: Select primary opponent using evidence-based stable ranking.
    -- Pass the existing primaryOpponent.guid as the preferred GUID for the
    -- 85% sticky rule so identity is stable across back-to-back rounds.
    local preferredGuid = session.primaryOpponent and session.primaryOpponent.guid or nil
    local primary, strategy = self:GetPrimaryEnemy(preferredGuid)

    if primary and primary.guid then
        -- Remember this selection as the preferred GUID for the next round.
        if round then round.preferredOpponentGuid = primary.guid end

        local opp = session.primaryOpponent or {}
        opp.guid       = opp.guid       or primary.guid
        opp.name       = opp.name       or primary.name
        opp.classFile  = opp.classFile  or primary.classFile  or primary.prepClassFile
        -- className and specName backfill from arena prep data.
        opp.className  = opp.className  or primary.className  or primary.prepClassFile
        opp.specName   = opp.specName   or primary.prepSpecName
        opp.specId     = opp.specId     or primary.prepSpecId
        opp.specIconId = opp.specIconId or primary.prepSpecIconId
        opp.pressureScore = primary.primarySelectionScore or 0

        -- Persist selection diagnostics for post-hoc inspection.
        local sev = primary.selectionEvidence or {}
        opp.selection = {
            strategy          = strategy or "highest_score",
            slot              = primary.slot,
            score             = primary.primarySelectionScore or 0,
            damageToPlayer    = sev.damageToPlayer or 0,
            killParticipation = primary.killParticipation or 0,
            preferredGuid     = preferredGuid,
            evidence = {
                damageToPlayer = sev.damageToPlayer or 0,
                deathRecap     = sev.deathRecap     or 0,
                identityBias   = sev.identityBias   or 0,
                visibilityBias = sev.visibilityBias or 0,
            },
        }
        session.primaryOpponent = opp
    else
        -- No eligible enemy slot found. Record the fallback strategy so the
        -- session is never missing selection metadata (SC-005).
        local opp = session.primaryOpponent or {}
        opp.selection = opp.selection or {
            strategy          = strategy or "no_visible_slot",
            slot              = nil,
            score             = 0,
            damageToPlayer    = 0,
            killParticipation = 0,
            preferredGuid     = preferredGuid,
            evidence = {
                damageToPlayer = 0,
                deathRecap     = 0,
                identityBias   = 0,
                visibilityBias = 0,
            },
        }
        if next(opp) then
            session.primaryOpponent = opp
        end
    end

    ns.Addon:Trace("arena_round.session.export", {
        matchKey      = session.arena.matchKey or "nil",
        roundIndex    = session.arena.roundIndex or 0,
        roundKey      = session.arena.roundKey or "nil",
        strategy      = session.primaryOpponent and session.primaryOpponent.selection and session.primaryOpponent.selection.strategy or "none",
        score         = session.primaryOpponent and session.primaryOpponent.selection and session.primaryOpponent.selection.score or 0,
        slots         = session.arena.slots and (function()
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
