local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local BuildHash = ns.BuildHash

local SnapshotService = {}

local function buildFallbackSnapshot(reason)
    local localizedClass, englishClass, classId = ApiCompat.GetPlayerClassInfo()
    local localizedRace, englishRace, raceId = ApiCompat.GetPlayerRaceInfo()
    local specIndex = ApiCompat.GetSpecialization()
    local specId, specName, _, specIcon, role = ApiCompat.GetSpecializationInfo(specIndex)

    local snapshot = {
        reason = reason,
        capturedAt = ApiCompat.GetServerTime(),
        guid = ApiCompat.GetPlayerGUID(),
        name = ApiCompat.GetPlayerName(),
        realm = ApiCompat.GetNormalizedRealmName(),
        className = localizedClass,
        classFile = englishClass,
        classId = classId,
        raceName = localizedRace,
        raceFile = englishRace,
        raceId = raceId,
        specIndex = specIndex,
        specId = specId,
        specName = specName,
        specIcon = specIcon,
        role = role,
        activeConfigId = nil,
        heroTalentSpecId = nil,
        importString = nil,
        talentNodes = {},
        pvpTalents = {},
        averageItemLevel = nil,
        equippedItemLevel = nil,
        pvpItemLevel = nil,
        masteryEffect = nil,
        versatilityDamageDone = nil,
        versatilityDamageTaken = nil,
        gear = {},
        weapons = {},
        trinkets = {},
        captureFlags = {
            buildSnapshot = Constants.CAPTURE_QUALITY.DEGRADED,
        },
    }

    snapshot.buildHash = BuildHash.FromSnapshot(snapshot)
    return snapshot
end

local function hasTalentConfigData(configId)
    if not configId then
        return false
    end

    local configInfo = ApiCompat.GetConfigInfo(configId)
    return configInfo and configInfo.treeIDs and #configInfo.treeIDs > 0 or false
end

local function captureTalentNodes(configId)
    local nodes = {}
    if not configId then
        return nodes
    end

    local configInfo = ApiCompat.GetConfigInfo(configId)
    if not configInfo or not configInfo.treeIDs then
        return nodes
    end

    for _, treeId in ipairs(configInfo.treeIDs) do
        local treeNodes = ApiCompat.GetTreeNodes(treeId) or {}
        for _, nodeId in ipairs(treeNodes) do
            local nodeInfo = ApiCompat.GetNodeInfo(configId, nodeId)
            if nodeInfo and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID then
                local entryInfo = ApiCompat.GetEntryInfo(configId, nodeInfo.activeEntry.entryID)
                local definitionInfo = entryInfo and entryInfo.definitionID and ApiCompat.GetDefinitionInfo(entryInfo.definitionID) or nil
                nodes[#nodes + 1] = {
                    nodeId = nodeId,
                    entryId = nodeInfo.activeEntry.entryID,
                    activeRank = nodeInfo.currentRank or 0,
                    definitionId = entryInfo and entryInfo.definitionID or nil,
                    definitionSpellId = definitionInfo and definitionInfo.spellID or nil,
                }
            end
        end
    end

    table.sort(nodes, function(left, right)
        return (left.nodeId or 0) < (right.nodeId or 0)
    end)
    return nodes
end

local function captureEquipment()
    local gear = {}
    local weapons = {}
    local trinkets = {}

    for _, slot in ipairs(Constants.INVENTORY_SLOTS) do
        local itemLink = ApiCompat.GetInventoryItemLink("player", slot)
        local itemId = ApiCompat.GetInventoryItemID("player", slot)
        if itemId then
            local _, _, _, _, _, itemClassId, itemSubclassId = ApiCompat.GetItemInfoInstant(itemLink or itemId)
            local record = {
                slot = slot,
                itemId = itemId,
                itemLink = itemLink,
                classId = itemClassId,
                subclassId = itemSubclassId,
            }
            gear[#gear + 1] = record
            if slot == 13 or slot == 14 then
                trinkets[#trinkets + 1] = record
            elseif slot == 16 or slot == 17 then
                weapons[#weapons + 1] = record
            end
        end
    end

    return gear, weapons, trinkets
end

local function capturePvpTalents()
    local selected = ApiCompat.GetAllSelectedPvpTalentIDs() or {}
    local talents = {}
    for _, talentId in ipairs(selected) do
        talents[#talents + 1] = talentId
    end
    table.sort(talents)
    return talents
end

local function buildSpecSnapshot(specIndex)
    if not specIndex then
        return {
            specIndex = nil,
            specId = nil,
            specName = nil,
            specIcon = nil,
            role = nil,
        }
    end

    local specId, specName, _, icon, role = ApiCompat.GetSpecializationInfo(specIndex)
    return {
        specIndex = specIndex,
        specId = specId,
        specName = specName,
        specIcon = icon,
        role = role,
    }
end

function SnapshotService:Initialize()
    self.initialized = true
    self.pendingFullRefresh = true
    self:RefreshPlayerSnapshot("initialize")
end

function SnapshotService:IsFullSnapshotReady()
    local specIndex = ApiCompat.GetSpecialization()
    local activeConfigId = ApiCompat.GetActiveConfigID()
    return specIndex ~= nil and hasTalentConfigData(activeConfigId)
end

function SnapshotService:CapturePlayerSnapshot(reason)
    ns.Addon:Trace("snapshot.capture.begin", { reason = reason or "refresh" })

    local localizedClass, englishClass, classId = ApiCompat.GetPlayerClassInfo()
    local localizedRace, englishRace, raceId = ApiCompat.GetPlayerRaceInfo()
    local specIndex = ApiCompat.GetSpecialization()
    local specSnapshot = buildSpecSnapshot(specIndex)
    local averageItemLevel, equippedItemLevel, pvpItemLevel = ApiCompat.GetAverageItemLevel()
    local masteryEffect = ApiCompat.GetMasteryEffect()
    local versatilityDamageDone, versatilityDamageTaken = ApiCompat.GetVersatilityBonuses()
    local activeConfigId = ApiCompat.GetActiveConfigID()
    local heroTalentSpecId = ApiCompat.GetActiveHeroTalentSpec()
    ns.Addon:Trace("snapshot.capture.state", {
        activeConfigId = activeConfigId or 0,
        heroTalentSpecId = heroTalentSpecId or 0,
        specIndex = specIndex or 0,
    })

    local importString = activeConfigId and ApiCompat.GenerateImportString(activeConfigId) or nil
    ns.Addon:Trace("snapshot.capture.import", {
        activeConfigId = activeConfigId or 0,
        hasImport = importString and true or false,
    })

    local talentNodes = captureTalentNodes(activeConfigId)
    ns.Addon:Trace("snapshot.capture.talents", {
        activeConfigId = activeConfigId or 0,
        nodeCount = #talentNodes,
    })

    local gear, weapons, trinkets = captureEquipment()
    local pvpTalents = capturePvpTalents()
    ns.Addon:Trace("snapshot.capture.pvp", {
        pvpTalentCount = #pvpTalents,
        trinketCount = #trinkets,
        weaponCount = #weapons,
    })

    local snapshot = {
        reason = reason,
        capturedAt = ApiCompat.GetServerTime(),
        guid = ApiCompat.GetPlayerGUID(),
        name = ApiCompat.GetPlayerName(),
        realm = ApiCompat.GetNormalizedRealmName(),
        className = localizedClass,
        classFile = englishClass,
        classId = classId,
        raceName = localizedRace,
        raceFile = englishRace,
        raceId = raceId,
        specIndex = specSnapshot.specIndex,
        specId = specSnapshot.specId,
        specName = specSnapshot.specName,
        specIcon = specSnapshot.specIcon,
        role = specSnapshot.role,
        activeConfigId = activeConfigId,
        heroTalentSpecId = heroTalentSpecId,
        importString = importString,
        talentNodes = talentNodes,
        pvpTalents = pvpTalents,
        averageItemLevel = averageItemLevel,
        equippedItemLevel = equippedItemLevel,
        pvpItemLevel = pvpItemLevel,
        masteryEffect = masteryEffect,
        versatilityDamageDone = versatilityDamageDone,
        versatilityDamageTaken = versatilityDamageTaken,
        gear = gear,
        weapons = weapons,
        trinkets = trinkets,
        captureFlags = {},
    }

    snapshot.buildHash = BuildHash.FromSnapshot(snapshot)
    return snapshot
end

function SnapshotService:RefreshPlayerSnapshot(reason)
    ns.Addon:Trace("snapshot.refresh.begin", { reason = reason or "refresh" })
    if not self:IsFullSnapshotReady() then
        local snapshot = buildFallbackSnapshot(reason or "refresh")
        snapshot.captureFlags.buildSnapshot = Constants.CAPTURE_QUALITY.DEGRADED
        snapshot.captureFlags.awaitingTraitData = true
        ns.Addon:SetLatestPlayerSnapshot(snapshot)
        self.pendingFullRefresh = true
        ns.Addon:Trace("snapshot.refresh.fallback", {
            reason = reason or "refresh",
            specId = snapshot.specId or 0,
        })
        return snapshot
    end

    local ok, snapshotOrError = xpcall(function()
        return self:CapturePlayerSnapshot(reason or "refresh")
    end, debugstack)

    local snapshot = snapshotOrError
    if not ok then
        ns.Addon:Warn("Player snapshot capture degraded; continuing with a minimal snapshot.")
        ns.Addon:Debug("%s", snapshotOrError)
        snapshot = buildFallbackSnapshot(reason or "refresh")
        snapshot.captureFlags.buildSnapshot = Constants.CAPTURE_QUALITY.DEGRADED
        ns.Addon:Trace("snapshot.refresh.error", { reason = reason or "refresh" })
    end

    ns.Addon:SetLatestPlayerSnapshot(snapshot)
    self.pendingFullRefresh = snapshot.captureFlags and snapshot.captureFlags.buildSnapshot == Constants.CAPTURE_QUALITY.DEGRADED or false
    ns.Addon:Trace("snapshot.refresh.ready", {
        buildHash = snapshot.buildHash or "unknown",
        pending = self.pendingFullRefresh and true or false,
        specId = snapshot.specId or 0,
    })
    return snapshot
end

function SnapshotService:TryRefreshDeferredSnapshot(reason)
    if not self.pendingFullRefresh and ns.Addon:GetLatestPlayerSnapshot() then
        return ns.Addon:GetLatestPlayerSnapshot()
    end
    return self:RefreshPlayerSnapshot(reason or "deferred_refresh")
end

function SnapshotService:GetLatestPlayerSnapshot()
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
    if snapshot and not self.pendingFullRefresh then
        return snapshot
    end
    return self:TryRefreshDeferredSnapshot("lazy")
end

function SnapshotService:GetSessionPlayerSnapshot(reason)
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
    if snapshot then
        ns.Addon:Trace("snapshot.session.cached", {
            pending = self.pendingFullRefresh and true or false,
            reason = reason or "session_start",
            specId = snapshot.specId or 0,
        })
        return snapshot
    end

    if InCombatLockdown and InCombatLockdown() then
        snapshot = buildFallbackSnapshot(reason or "session_start")
        snapshot.captureFlags.buildSnapshot = Constants.CAPTURE_QUALITY.DEGRADED
        snapshot.captureFlags.awaitingTraitData = true
        ns.Addon:SetLatestPlayerSnapshot(snapshot)
        self.pendingFullRefresh = true
        ns.Addon:Trace("snapshot.session.combat_fallback", {
            reason = reason or "session_start",
            specId = snapshot.specId or 0,
        })
        return snapshot
    end

    ns.Addon:Trace("snapshot.session.refresh", { reason = reason or "session_start" })
    return self:TryRefreshDeferredSnapshot(reason or "session_start")
end

function SnapshotService:HandleTraitConfigListUpdated()
    self:TryRefreshDeferredSnapshot("trait_config_ready")
end

function SnapshotService:CreateActorSnapshotFromUnit(unitToken, sourceType)
    if not ApiCompat.UnitExists(unitToken) then
        return nil
    end

    -- Wrap in pcall: Midnight returns secret values for arena enemy units
    -- during PvP combat.  The ApiCompat Safe wrappers handle most cases, but
    -- pcall provides a final safety net against any remaining taint leaks.
    local ok, snapshot = pcall(function()
        local guid = ApiCompat.GetUnitGUID(unitToken)
        if not guid then return nil end

        local localizedClass, englishClass, classId = ApiCompat.GetUnitClass(unitToken)
        local localizedRace, englishRace, raceId = ApiCompat.GetUnitRace(unitToken)
        return {
            guid = guid,
            name = ApiCompat.GetUnitName(unitToken),
            unitToken = unitToken,
            sourceType = sourceType or "unit",
            capturedAt = ApiCompat.GetServerTime(),
            isPlayer = ApiCompat.UnitIsPlayer(unitToken),
            className = localizedClass,
            classFile = englishClass,
            classId = classId,
            raceName = localizedRace,
            raceFile = englishRace,
            raceId = raceId,
            level = ApiCompat.GetUnitLevel(unitToken),
            healthMax = ApiCompat.UnitHealthMax(unitToken),
        }
    end)

    if not ok then return nil end
    return snapshot
end

function SnapshotService:UpdateSessionActor(session, unitToken, sourceType)
    if not session then
        return nil
    end

    local snapshot = self:CreateActorSnapshotFromUnit(unitToken, sourceType)
    if not snapshot or not snapshot.guid then
        return nil
    end

    -- Guard: if guid is somehow still secret (should not happen after
    -- CreateActorSnapshotFromUnit pcall, but belt-and-suspenders).
    if ApiCompat.IsSecretValue(snapshot.guid) then
        return nil
    end

    session.actors = session.actors or {}
    session.actors[snapshot.guid] = session.actors[snapshot.guid] or snapshot
    local current = session.actors[snapshot.guid]
    for key, value in pairs(snapshot) do
        if value ~= nil and not ApiCompat.IsSecretValue(value) then
            current[key] = value
        end
    end
    session.trackedActorGuids = session.trackedActorGuids or {}
    session.trackedActorGuids[snapshot.guid] = true
    return current
end

function SnapshotService:CaptureArenaPrep(matchRecord)
    if not matchRecord then
        return
    end

    matchRecord.prepOpponents = matchRecord.prepOpponents or {}
    local opponentCount = ApiCompat.GetNumArenaOpponentSpecs()
    for index = 1, opponentCount do
        local specId = ApiCompat.GetArenaOpponentSpec(index)
        if specId and specId > 0 then
            local _, specName = ApiCompat.GetSpecializationInfoByID(specId)
            matchRecord.prepOpponents[index] = {
                slot = index,
                observedAt = ApiCompat.GetServerTime(),
                specId = specId,
                specName = specName,
                observationType = "arena_prep",
            }
        end
    end
end

ns.Addon:RegisterModule("SnapshotService", SnapshotService)
