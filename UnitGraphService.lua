local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat

local UnitGraphService = {}

-- ---------------------------------------------------------------------------
-- Token priority for preferredToken selection: lower value = higher priority.
-- Arena slots are canonical identifiers in PvP.
-- ---------------------------------------------------------------------------

local TOKEN_PRIORITY = {}
for i = 1, 5 do
    TOKEN_PRIORITY["arena"  .. i]          = 1
    TOKEN_PRIORITY["arena"  .. i .. "pet"] = 1
end
TOKEN_PRIORITY["target"] = 2
TOKEN_PRIORITY["focus"]  = 2

local function getTokenPriority(token)
    if not token then return 99 end
    if TOKEN_PRIORITY[token] then return TOKEN_PRIORITY[token] end
    if token:sub(1, 9) == "nameplate" then return 3 end
    if token:sub(1, 5) == "party"     then return 4 end
    if token:sub(1, 4) == "raid"      then return 4 end
    return 5
end

local function isPetToken(token)
    if not token then return false end
    return token == "pet"
        or token:match("^arena%dpet$") ~= nil
        or token:match("^partypet%d$") ~= nil
end

local function isHostileToken(unitToken)
    if not unitToken or not ApiCompat.UnitExists(unitToken) then
        return false
    end
    return ApiCompat.UnitCanAttack("player", unitToken)
        or ApiCompat.UnitIsEnemy("player", unitToken)
end

-- ---------------------------------------------------------------------------
-- T015: Conflict resolution — source priority values.
-- Lower value = higher authority. When multiple sources provide the same
-- identity field, the source with the lowest priority value wins.
-- ---------------------------------------------------------------------------

local SOURCE_PRIORITY = {
    visible_unit        = 1,   -- Direct UnitGUID/UnitClass/UnitName observation
    arena               = 2,   -- ARENA_OPPONENT_UPDATE slot mapping
    arena_slot_mapping  = 2,   -- Alias for arena
    pet_owner_inference = 3,   -- Explicit pet-owner slot correspondence
    prior_session       = 4,   -- Stable identity from earlier in same session
    damage_meter        = 5,   -- Summary-derived from C_DamageMeter
    summary_derived     = 5,   -- Alias for damage_meter
    target              = 6,   -- Target/focus observation (lower than arena)
    focus               = 6,
    group               = 7,
    nameplate           = 8,
    unknown             = 99,
}

local function getSourcePriority(source)
    return SOURCE_PRIORITY[source] or 99
end

-- T015: Return the winning (value, source) pair between existing and incoming.
-- If incoming source has equal or lower priority number (= higher authority),
-- the incoming value wins. Otherwise existing wins.
local function resolveConflict(existingValue, existingSource, incomingValue, incomingSource)
    if existingValue == nil then
        return incomingValue, incomingSource
    end
    if incomingValue == nil then
        return existingValue, existingSource
    end
    local existPrio   = getSourcePriority(existingSource)
    local incomePrio  = getSourcePriority(incomingSource)
    if incomePrio <= existPrio then
        return incomingValue, incomingSource
    end
    return existingValue, existingSource
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

UnitGraphService.state = {
    nodes           = {},   -- [guid] = UnitGraphNode
    tokenToGuid     = {},   -- [unitToken] = guid
    petOwners       = {},   -- [petGuid] = ownerGuid (backward compat)
    petOwnerDetails = {},   -- [petGuid] = { ownerGuid, ownerName, ownerSlot, ownershipConfidence }
    priorSession    = {},   -- [guid] = shallow copy of node; preserved across rounds
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- T020: Initialize (alias kept for backward compat; callers should prefer
-- InitializeForSession and ResetForSessionEnd).
function UnitGraphService:Initialize()
    self:InitializeForSession()
end

-- T020: Initialize state for a new session/round. Preserves priorSession
-- identity so it can be used as a lower-priority fallback during the round.
function UnitGraphService:InitializeForSession()
    self.state = {
        nodes           = {},
        tokenToGuid     = {},
        petOwners       = {},
        petOwnerDetails = {},
        priorSession    = self.state and self.state.nodes or {},
    }
end

-- T020: Archive current node records as prior-session identity, then reset
-- operational state for the next session.
function UnitGraphService:ResetForSessionEnd()
    -- Shallow-copy current nodes into priorSession.
    local archived = {}
    for guid, node in pairs(self.state.nodes or {}) do
        archived[guid] = node
    end
    self.state = {
        nodes           = {},
        tokenToGuid     = {},
        petOwners       = {},
        petOwnerDetails = {},
        priorSession    = archived,
    }
end

-- ---------------------------------------------------------------------------
-- Core: RegisterUnit
-- Upserts a node for the given GUID, updates token mappings, refreshes
-- preferredToken when the new token has better priority.
-- ---------------------------------------------------------------------------

function UnitGraphService:RegisterUnit(guid, unitToken, source)
    if not guid or not unitToken then return end
    local now = (GetTime and GetTime()) or 0

    local node = self.state.nodes[guid]
    if not node then
        node = {
            guid              = guid,
            preferredToken    = nil,
            tokens            = {},
            name              = nil,
            className         = nil,
            classFile         = nil,
            classFileSrc      = nil,
            specId            = nil,
            specName          = nil,
            -- T014: arenaSlot — populated by UpdateFromArenaSlot.
            arenaSlot         = nil,
            isPet             = isPetToken(unitToken),
            ownerGUID         = nil,  -- backward compat field
            ownerGuid         = nil,  -- T014: normalized alias
            ownerName         = nil,
            ownerSlot         = nil,
            ownershipConfidence = nil,
            -- T014: Visibility state — tracked per node.
            isVisible         = true,
            visible           = true,  -- T014: alias
            firstSeenAt       = now,
            lastSeenAt        = now,
            -- T014: Attribution fields.
            confidence        = "unknown",
            provenance        = source or "unknown",
            metaSources       = {},
        }
        self.state.nodes[guid] = node
    end

    -- T016: Mark as visible and update timestamps.
    node.isVisible  = true
    node.visible    = true
    node.lastSeenAt = now
    node.firstSeenAt = node.firstSeenAt or now

    node.tokens[unitToken] = { source = source, seenAt = now }

    -- Evict stale token→guid binding for this slot so re-association is clean.
    local previousGuid = self.state.tokenToGuid[unitToken]
    if previousGuid and previousGuid ~= guid then
        local prevNode = self.state.nodes[previousGuid]
        if prevNode then
            prevNode.tokens[unitToken] = nil
            self:_recomputePreferredToken(prevNode)
        end
    end
    self.state.tokenToGuid[unitToken] = guid

    -- Promote preferredToken when this token has better (lower) priority value.
    local newPrio     = getTokenPriority(unitToken)
    local currentPrio = node.preferredToken
        and getTokenPriority(node.preferredToken)
        or 99
    if newPrio < currentPrio then
        node.preferredToken = unitToken
    end

    -- Opportunistically enrich metadata from live WoW API.
    self:_enrichNodeMetadata(node, unitToken, source, now)

    -- Update confidence based on source.
    local srcPrio = getSourcePriority(source or "unknown")
    if srcPrio <= 2 then
        node.confidence = "confirmed"
    elseif srcPrio <= 3 then
        node.confidence = "slot_confirmed"
    elseif srcPrio <= 5 then
        node.confidence = node.confidence == "confirmed" and "confirmed" or "inferred"
    end
    node.provenance = source or node.provenance
end

-- Recompute preferredToken for a node after a token is evicted.
function UnitGraphService:_recomputePreferredToken(node)
    local best, bestPrio = nil, 99
    for token in pairs(node.tokens) do
        local p = getTokenPriority(token)
        if p < bestPrio then
            best     = token
            bestPrio = p
        end
    end
    node.preferredToken = best
end

-- Pull name and class from the live WoW API for a known unit token.
function UnitGraphService:_enrichNodeMetadata(node, unitToken, source, now)
    if not ApiCompat.UnitExists(unitToken) then return end
    if not node.name then
        local name = ApiCompat.GetUnitName(unitToken)
        if name then
            node.name = name
            node.metaSources["name"] = { source = source, seenAt = now }
        end
    end
    if not node.classFile then
        local _, classFile = ApiCompat.GetUnitClass(unitToken)
        if classFile then
            node.classFile    = classFile
            node.classFileSrc = source
            node.metaSources["classFile"] = { source = source, seenAt = now }
        end
    end
    -- T021: Attempt to read arenaSlot from token name (arena1..arena5).
    if not node.arenaSlot then
        local slot = tonumber(unitToken:match("^arena(%d+)$"))
        if slot then
            node.arenaSlot = slot
        end
    end
end

-- ---------------------------------------------------------------------------
-- Core: pet ownership
-- ---------------------------------------------------------------------------

function UnitGraphService:RegisterPetOwner(petGuid, ownerGuid, ownershipConf)
    if not petGuid or not ownerGuid then return end
    self.state.petOwners[petGuid] = ownerGuid

    -- T024: Store full pet owner details for GetOwnerForPet.
    local conf = ownershipConf or "confirmed"
    local ownerNode = self.state.nodes[ownerGuid]
    self.state.petOwnerDetails[petGuid] = {
        ownerGuid           = ownerGuid,
        ownerName           = ownerNode and ownerNode.name or nil,
        ownerSlot           = ownerNode and ownerNode.arenaSlot or nil,
        ownershipConfidence = conf,
    }

    local node = self.state.nodes[petGuid]
    if node then
        node.ownerGUID  = ownerGuid
        node.ownerGuid  = ownerGuid
        if ownerNode then
            node.ownerName = ownerNode.name
            node.ownerSlot = ownerNode.arenaSlot
        end
        node.ownershipConfidence = conf
        node.isPet = true
    end
end

-- ---------------------------------------------------------------------------
-- Core: invalidation
-- ---------------------------------------------------------------------------

function UnitGraphService:InvalidateUnit(guid)
    if not guid then return end
    local node = self.state.nodes[guid]
    if not node then return end
    node.isVisible  = false
    node.visible    = false
    node.lastSeenAt = (GetTime and GetTime()) or 0
end

-- ---------------------------------------------------------------------------
-- T016: MarkSeen — explicit visibility state transition.
function UnitGraphService:MarkSeen(guid)
    if not guid then return end
    local now  = (GetTime and GetTime()) or 0
    local node = self.state.nodes[guid]
    if not node then return end
    local wasVisible = node.visible
    node.isVisible   = true
    node.visible     = true
    node.lastSeenAt  = now
    node.firstSeenAt = node.firstSeenAt or now
    return not wasVisible  -- returns true if state changed (hidden→visible)
end

-- T017: MarkUnseen — explicit visibility state transition.
-- T034/T036: Emits a VISIBILITY lane event when the state actually changes:
--   pets → "pet_disappeared", arena units → "arena_opponent_hidden".
function UnitGraphService:MarkUnseen(guid)
    if not guid then return end
    local now  = (GetTime and GetTime()) or 0
    local node = self.state.nodes[guid]
    if not node then return end
    local wasVisible = node.visible
    node.isVisible   = false
    node.visible     = false
    node.lastSeenAt  = now
    -- Emit only when state actually changed (coalesced).
    if wasVisible then
        local eventType = node.isPet and "pet_disappeared" or "arena_opponent_hidden"
        local unitToken = node.preferredToken
        pcall(self._EmitVisibilityEvent, self, guid, eventType, unitToken, "mark_unseen")
    end
    return wasVisible  -- returns true if state changed (visible→hidden)
end

-- ---------------------------------------------------------------------------
-- T033: _EmitVisibilityEvent
-- Appends a VISIBILITY lane event to the active session timeline.
-- Called internally by UpdateFromArenaSlot, MarkUnseen, and the
-- target/focus/pet handlers to record actor visibility transitions.
-- Silently returns when no active session exists.
-- ---------------------------------------------------------------------------

function UnitGraphService:_EmitVisibilityEvent(guid, eventType, unitToken, reason)
    local tp = ns.Addon:GetModule("TimelineProducer")
    if not tp then return end
    local session = tp:GetCurrentSession()
    if not session then return end

    local node = self.state.nodes[guid]
    local now  = (GetTime and GetTime()) or 0
    local t    = now - (session.startedAt or now)

    tp:AppendTimelineEvent(session, {
        t               = t,
        lane            = Constants.TIMELINE_LANE.VISIBILITY,
        type            = eventType,
        source          = Constants.PROVENANCE_SOURCE.VISIBLE_UNIT_CAST,
        confidence      = (node and node.confidence)
                          or Constants.ATTRIBUTION_CONFIDENCE.unknown,
        chronology      = "realtime",
        sourceGuid      = guid,
        sourceName      = node and node.name or nil,
        sourceClassFile = node and node.classFile or nil,
        sourceSlot      = node and node.arenaSlot or nil,
        sourceUnitToken = unitToken,
        meta            = { reason = reason },
    })
end

-- ---------------------------------------------------------------------------
-- T018: GetBestDisplayIdentity
-- Returns a flat record with the best known identity fields for a GUID.
-- Falls back to empty strings (not nil) to simplify consumer nil-checks.
-- ---------------------------------------------------------------------------

function UnitGraphService:GetBestDisplayIdentity(guid)
    if not guid then
        return { name="", classFile="", specId=nil, arenaSlot=nil, confidence="unknown", provenance="unknown" }
    end
    local node = self.state.nodes[guid]
    if node then
        return {
            name       = node.name       or "",
            classFile  = node.classFile  or "",
            specId     = node.specId,
            specName   = node.specName,
            arenaSlot  = node.arenaSlot,
            confidence = node.confidence or "unknown",
            provenance = node.provenance or "unknown",
        }
    end
    -- Fallback to prior-session identity.
    local prior = self.state.priorSession and self.state.priorSession[guid]
    if prior then
        return {
            name       = prior.name      or "",
            classFile  = prior.classFile or "",
            specId     = prior.specId,
            specName   = prior.specName,
            arenaSlot  = prior.arenaSlot,
            confidence = "inferred",
            provenance = "prior_session",
        }
    end
    return { name="", classFile="", specId=nil, arenaSlot=nil, confidence="unknown", provenance="unknown" }
end

-- ---------------------------------------------------------------------------
-- T019: GetOwnerForPet
-- Returns the full owner record for a pet GUID, or empty table if unknown.
-- ---------------------------------------------------------------------------

function UnitGraphService:GetOwnerForPet(petGuid)
    if not petGuid then return {} end
    local details = self.state.petOwnerDetails and self.state.petOwnerDetails[petGuid]
    if details then
        -- Refresh name/slot from owner node in case they were enriched since
        -- the ownership was initially recorded.
        local ownerNode = details.ownerGuid and self.state.nodes[details.ownerGuid]
        if ownerNode then
            details.ownerName = ownerNode.name or details.ownerName
            details.ownerSlot = ownerNode.arenaSlot or details.ownerSlot
        end
        return details
    end
    -- Legacy fallback: petOwners only has the ownerGuid.
    local ownerGuid = self.state.petOwners[petGuid]
    if not ownerGuid then return {} end
    local ownerNode = self.state.nodes[ownerGuid]
    return {
        ownerGuid           = ownerGuid,
        ownerName           = ownerNode and ownerNode.name or nil,
        ownerSlot           = ownerNode and ownerNode.arenaSlot or nil,
        ownershipConfidence = "confirmed",
    }
end

-- ---------------------------------------------------------------------------
-- T021: UpdateFromVisibleUnit
-- Pulls live WoW API state for the given unit token and merges into the node
-- using "visible_unit" source priority (highest authority).
-- ---------------------------------------------------------------------------

function UnitGraphService:UpdateFromVisibleUnit(unitToken)
    if not unitToken then return end
    local ok = pcall(function()
        if not ApiCompat.UnitExists(unitToken) then return end
        local guid = ApiCompat.GetUnitGUID(unitToken)
        if not guid then return end

        -- Ensure node exists.
        self:RegisterUnit(guid, unitToken, "visible_unit")
        local node = self.state.nodes[guid]
        if not node then return end

        local now = (GetTime and GetTime()) or 0

        -- Merge name with conflict resolution.
        local name = ApiCompat.GetUnitName(unitToken)
        if name then
            node.name, node.metaSources["name"] =
                resolveConflict(node.name, node.metaSources["name"] and node.metaSources["name"].source,
                                name, "visible_unit")
            node.metaSources["name"] = { source = "visible_unit", seenAt = now }
        end

        -- Merge classFile.
        local _, classFile = ApiCompat.GetUnitClass(unitToken)
        if classFile then
            local newCF, newSrc = resolveConflict(node.classFile, node.classFileSrc, classFile, "visible_unit")
            node.classFile    = newCF
            node.classFileSrc = newSrc
        end

        -- Derive arenaSlot from token name.
        local slot = tonumber(unitToken:match("^arena(%d+)$"))
        if slot and not node.arenaSlot then
            node.arenaSlot = slot
        end

        -- Mark observed and set high confidence.
        node.isVisible   = true
        node.visible     = true
        node.lastSeenAt  = now
        node.confidence  = "confirmed"
        node.provenance  = "visible_unit"
    end)
    if not ok then
        ns.Addon:Trace("unit_graph.update_visible_failed", { token = unitToken or "?" })
    end
end

-- ---------------------------------------------------------------------------
-- T022: UpdateFromArenaSlot
-- Called by ArenaRoundTracker when ARENA_OPPONENT_UPDATE or slot data arrives.
-- ---------------------------------------------------------------------------

function UnitGraphService:UpdateFromArenaSlot(slot, guid, name, classFile, specId)
    if not slot or not guid then return end
    local now = (GetTime and GetTime()) or 0

    local node = self.state.nodes[guid]
    -- T034: Capture previous visibility state before any mutation.
    local wasVisible = node and node.visible

    if not node then
        -- Ensure node exists (creates with arena source).
        self:RegisterUnit(guid, "arena" .. slot, "arena_slot_mapping")
        node = self.state.nodes[guid]
        if not node then return end
    end

    -- Merge fields using conflict resolution priority.
    if name then
        local newName, newSrc = resolveConflict(node.name, node.metaSources["name"] and node.metaSources["name"].source, name, "arena_slot_mapping")
        node.name = newName
        node.metaSources["name"] = { source = newSrc, seenAt = now }
    end
    if classFile then
        node.classFile, node.classFileSrc =
            resolveConflict(node.classFile, node.classFileSrc, classFile, "arena_slot_mapping")
    end
    if specId then
        node.specId = node.specId or specId
    end

    -- Arena slot assignment: authoritative from slot mapping.
    node.arenaSlot = slot

    node.confidence = node.confidence == "confirmed" and "confirmed" or "slot_confirmed"
    node.provenance = node.provenance ~= "visible_unit" and "arena_slot_mapping" or node.provenance

    -- Ensure tokenToGuid mapping for this slot token.
    local slotToken = "arena" .. slot
    if not self.state.tokenToGuid[slotToken] or self.state.tokenToGuid[slotToken] ~= guid then
        self.state.tokenToGuid[slotToken] = guid
        node.tokens[slotToken] = { source = "arena_slot_mapping", seenAt = now }
        if not node.preferredToken or getTokenPriority(slotToken) < getTokenPriority(node.preferredToken) then
            node.preferredToken = slotToken
        end
    end

    node.isVisible  = true
    node.visible    = true
    node.lastSeenAt = now
    node.firstSeenAt = node.firstSeenAt or now

    -- T034: Emit arena_opponent_visible when the node transitions from hidden
    -- to visible. Coalesced: only emits when visibility state actually changed.
    if not wasVisible then
        pcall(self._EmitVisibilityEvent, self,
            guid, "arena_opponent_visible", "arena" .. slot, "arena_opponent_update")
    end
end

-- ---------------------------------------------------------------------------
-- T023: UpdateFromDamageMeter
-- Lowest-authority update — only fills in nil fields.
-- ---------------------------------------------------------------------------

function UnitGraphService:UpdateFromDamageMeter(guid, name, classFile)
    if not guid then return end
    local now = (GetTime and GetTime()) or 0
    local node = self.state.nodes[guid]
    if not node then
        -- Create minimal node with lowest confidence.
        node = {
            guid              = guid,
            preferredToken    = nil,
            tokens            = {},
            name              = name,
            className         = nil,
            classFile         = classFile,
            classFileSrc      = "damage_meter",
            specId            = nil,
            specName          = nil,
            arenaSlot         = nil,
            isPet             = false,
            ownerGUID         = nil,
            ownerGuid         = nil,
            ownerName         = nil,
            ownerSlot         = nil,
            ownershipConfidence = nil,
            isVisible         = false,
            visible           = false,
            firstSeenAt       = now,
            lastSeenAt        = now,
            confidence        = "summary_derived",
            provenance        = "damage_meter",
            metaSources       = {
                name      = name      and { source = "damage_meter", seenAt = now } or nil,
                classFile = classFile and { source = "damage_meter", seenAt = now } or nil,
            },
        }
        self.state.nodes[guid] = node
        return
    end
    -- Only update nil fields — damage_meter is lowest priority.
    if name and not node.name then
        node.name = name
        node.metaSources["name"] = { source = "damage_meter", seenAt = now }
    end
    if classFile and not node.classFile then
        node.classFile    = classFile
        node.classFileSrc = "damage_meter"
    end
end

-- ---------------------------------------------------------------------------
-- T041: DumpState — returns a formatted diagnostic string of all known actors.
-- Used by the /ca debug actors slash command (Phase 6).
-- ---------------------------------------------------------------------------

function UnitGraphService:DumpState()
    local lines = {}
    lines[#lines + 1] = "=== UnitGraphService Actor Registry ==="
    local count = 0
    for guid, node in pairs(self.state.nodes or {}) do
        count = count + 1
        local shortGuid = guid:sub(-8)
        local petInfo = node.isPet and string.format(" [PET owner:%s conf:%s]",
            tostring(node.ownerGuid and node.ownerGuid:sub(-6) or "nil"),
            tostring(node.ownershipConfidence or "?")) or ""
        lines[#lines + 1] = string.format(
            "  [%s] %s cls:%s slot:%s vis:%s conf:%s prov:%s tok:%s%s",
            shortGuid,
            tostring(node.name or "?"),
            tostring(node.classFile or "?"),
            tostring(node.arenaSlot or "-"),
            node.visible and "Y" or "N",
            tostring(node.confidence or "?"),
            tostring(node.provenance or "?"),
            tostring(node.preferredToken or "-"),
            petInfo
        )
    end
    lines[#lines + 1] = string.format("Total: %d actors | %d token mappings | %d pet links",
        count,
        (function() local n=0; for _ in pairs(self.state.tokenToGuid or {}) do n=n+1 end; return n end)(),
        (function() local n=0; for _ in pairs(self.state.petOwners or {}) do n=n+1 end; return n end)()
    )
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Query API (backward compat + new)
-- ---------------------------------------------------------------------------

function UnitGraphService:GetTokenForGUID(guid)
    local node = self.state.nodes[guid]
    return node and node.preferredToken or nil
end

function UnitGraphService:GetGUIDForToken(unitToken)
    return self.state.tokenToGuid[unitToken]
end

function UnitGraphService:GetOwnerGUID(petGuid)
    return self.state.petOwners[petGuid]
end

function UnitGraphService:GetNode(guid)
    return self.state.nodes[guid]
end

function UnitGraphService:GetHostileCandidates(preferredToken)
    local candidates = {}
    local seenTokens = {}

    local function addCandidate(unitToken, guid)
        if not unitToken or seenTokens[unitToken] then
            return
        end
        if not isHostileToken(unitToken) then
            return
        end

        local resolvedGuid = guid or self:GetGUIDForToken(unitToken) or ApiCompat.GetUnitGUID(unitToken)
        if not resolvedGuid then
            return
        end

        local node = self.state.nodes[resolvedGuid]
        seenTokens[unitToken] = true
        candidates[#candidates + 1] = {
            guid        = resolvedGuid,
            name        = node and node.name or ApiCompat.GetUnitName(unitToken),
            unitToken   = unitToken,
            isHostile   = true,
            isPlayer    = ApiCompat.UnitIsPlayer(unitToken),
            isPet       = (node and node.isPet) or ApiCompat.IsGuidPet(resolvedGuid),
            creatureId  = ApiCompat.GetCreatureIdFromGUID(resolvedGuid),
            arenaSlot   = node and node.arenaSlot or nil,
            confidence  = node and node.confidence or Constants.ATTRIBUTION_CONFIDENCE.unknown,
            provenance  = node and node.provenance or "unknown",
            tokenPriority = getTokenPriority(unitToken),
        }
    end

    addCandidate(preferredToken)
    addCandidate("target")
    addCandidate("focus")

    for guid, node in pairs(self.state.nodes or {}) do
        if node and node.visible ~= false and node.preferredToken then
            addCandidate(node.preferredToken, guid)
        end
    end

    table.sort(candidates, function(left, right)
        local leftPet = left.isPet and 1 or 0
        local rightPet = right.isPet and 1 or 0
        if leftPet ~= rightPet then
            return leftPet < rightPet
        end
        if (left.tokenPriority or 99) ~= (right.tokenPriority or 99) then
            return (left.tokenPriority or 99) < (right.tokenPriority or 99)
        end
        local leftPlayer = left.isPlayer and 1 or 0
        local rightPlayer = right.isPlayer and 1 or 0
        if leftPlayer ~= rightPlayer then
            return leftPlayer > rightPlayer
        end
        return tostring(left.unitToken or "") < tostring(right.unitToken or "")
    end)

    return candidates
end

function UnitGraphService:GetBestHostileCandidate(preferredToken)
    local candidates = self:GetHostileCandidates(preferredToken)
    return candidates[1]
end

-- ---------------------------------------------------------------------------
-- Event handlers (called from Events.lua RegisterHandler wrappers)
-- ---------------------------------------------------------------------------

function UnitGraphService:HandleArenaOpponentUpdate(unitToken)
    if not unitToken then return end
    local guid = ApiCompat.GetUnitGUID(unitToken)
    if guid then
        -- T022: Use UpdateFromArenaSlot when we can parse the slot number.
        local slot = tonumber(unitToken:match("^arena(%d+)$"))
        if slot then
            local name      = ApiCompat.GetUnitName(unitToken)
            local _, clsFile = ApiCompat.GetUnitClass(unitToken)
            self:UpdateFromArenaSlot(slot, guid, name, clsFile, nil)
        else
            self:RegisterUnit(guid, unitToken, "arena")
        end
    end
end

function UnitGraphService:HandlePlayerTargetChanged()
    if ApiCompat.UnitExists("target") then
        local guid = ApiCompat.GetUnitGUID("target")
        if guid then
            self:RegisterUnit(guid, "target", "target")
            self:UpdateFromVisibleUnit("target")
            -- T035: Emit visibility event for the newly targeted unit.
            pcall(self._EmitVisibilityEvent, self,
                guid, "target_changed", "target", "player_target_changed")
        end
    end
end

function UnitGraphService:HandlePlayerFocusChanged()
    if ApiCompat.UnitExists("focus") then
        local guid = ApiCompat.GetUnitGUID("focus")
        if guid then
            self:RegisterUnit(guid, "focus", "focus")
            self:UpdateFromVisibleUnit("focus")
            -- T035: Emit visibility event for the newly focused unit.
            pcall(self._EmitVisibilityEvent, self,
                guid, "focus_changed", "focus", "player_focus_changed")
        end
    end
end

function UnitGraphService:HandleGroupRosterUpdate()
    for i = 1, 4 do
        local token = "party" .. i
        if ApiCompat.UnitExists(token) then
            local guid = ApiCompat.GetUnitGUID(token)
            if guid then self:RegisterUnit(guid, token, "group") end
        end
    end
    for i = 1, 40 do
        local token = "raid" .. i
        if ApiCompat.UnitExists(token) then
            local guid = ApiCompat.GetUnitGUID(token)
            if guid then self:RegisterUnit(guid, token, "group") end
        end
    end
end

function UnitGraphService:HandleUnitPet(unitId)
    if not unitId then return end
    local petToken = unitId .. "pet"
    if ApiCompat.UnitExists(petToken) then
        local petGuid   = ApiCompat.GetUnitGUID(petToken)
        local ownerGuid = ApiCompat.GetUnitGUID(unitId)
        if petGuid and ownerGuid then
            self:RegisterUnit(petGuid, petToken, "pet")
            -- T024: Register with confirmed confidence for direct unit-pet relationship.
            self:RegisterPetOwner(petGuid, ownerGuid, "confirmed")
            -- T036: Emit pet_appeared visibility event when the pet becomes visible.
            pcall(self._EmitVisibilityEvent, self,
                petGuid, "pet_appeared", petToken, "unit_pet")
        end
    end
end

function UnitGraphService:HandleNamePlateAdded(unitToken)
    if not unitToken then return end
    local guid = ApiCompat.GetUnitGUID(unitToken)
    if guid then
        self:RegisterUnit(guid, unitToken, "nameplate")
    end
end

function UnitGraphService:HandleNamePlateRemoved(unitToken)
    if not unitToken then return end
    local guid = self.state.tokenToGuid[unitToken]
    if guid then
        self:InvalidateUnit(guid)
        local node = self.state.nodes[guid]
        if node then
            node.tokens[unitToken] = nil
            self:_recomputePreferredToken(node)
        end
    end
    self.state.tokenToGuid[unitToken] = nil
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("UnitGraphService", UnitGraphService)
