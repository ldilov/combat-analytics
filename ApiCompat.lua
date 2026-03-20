local _, ns = ...

local ApiCompat = {}

local function callIfPresent(func, ...)
    if type(func) ~= "function" then
        return nil
    end
    return func(...)
end

function ApiCompat.GetCombatLogEventInfo()
    -- Priority 1: C_CombatLog namespace — undocumented but referenced in
    -- Blizzard_DeprecatedCombatLog as the canonical CLEU data source.
    -- Works during COMBAT_LOG_EVENT_UNFILTERED.
    if C_CombatLog and C_CombatLog.GetCurrentEventInfo then
        return C_CombatLog.GetCurrentEventInfo()
    end
    -- Priority 2: Deprecated global (only when loadDeprecationFallbacks CVar is true).
    if CombatLogGetCurrentEventInfo then
        return CombatLogGetCurrentEventInfo()
    end
    -- Priority 3: Internal API — only as last resort. Documented with its own
    -- event (COMBAT_LOG_EVENT_INTERNAL_UNFILTERED) and may not return data
    -- during COMBAT_LOG_EVENT_UNFILTERED. Not used by any Blizzard addon.
    if C_CombatLogInternal and C_CombatLogInternal.GetCurrentEventInfo then
        return C_CombatLogInternal.GetCurrentEventInfo()
    end
    return nil
end

function ApiCompat.GetCombatLogEntryInfo()
    if C_CombatLog and C_CombatLog.GetCurrentEntryInfo then
        return C_CombatLog.GetCurrentEntryInfo()
    end
    return nil
end

function ApiCompat.IsCombatLogRestricted()
    -- C_CombatLog.IsCombatLogRestricted() is the session-level gate introduced in Midnight.
    -- IsCurrentEventInfoRestricted() is a per-event predicate and must NOT be used here —
    -- it fires for restricted events even in unrestricted sessions.
    if C_CombatLog and C_CombatLog.IsCombatLogRestricted then
        return C_CombatLog.IsCombatLogRestricted()
    end
    return false
end

function ApiCompat.IsDamageMeterAvailable()
    if C_DamageMeter and C_DamageMeter.IsDamageMeterAvailable then
        return C_DamageMeter.IsDamageMeterAvailable()
    end
    return false, "missing_api"
end

function ApiCompat.GetAvailableCombatSessions()
    if C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions then
        return C_DamageMeter.GetAvailableCombatSessions()
    end
    return {}
end

function ApiCompat.GetCombatSessionFromID(sessionId, damageMeterType)
    if C_DamageMeter and C_DamageMeter.GetCombatSessionFromID then
        return C_DamageMeter.GetCombatSessionFromID(sessionId, damageMeterType)
    end
    return nil
end

function ApiCompat.GetCombatSessionFromType(sessionType, damageMeterType)
    if C_DamageMeter and C_DamageMeter.GetCombatSessionFromType then
        return C_DamageMeter.GetCombatSessionFromType(sessionType, damageMeterType)
    end
    return nil
end

function ApiCompat.GetCombatSessionSourceFromID(sessionId, damageMeterType, sourceGuid, sourceCreatureId)
    if C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromID then
        return C_DamageMeter.GetCombatSessionSourceFromID(sessionId, damageMeterType, sourceGuid, sourceCreatureId)
    end
    return nil
end

function ApiCompat.GetCombatSessionSourceFromType(sessionType, damageMeterType, sourceGuid, sourceCreatureId)
    if C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromType then
        return C_DamageMeter.GetCombatSessionSourceFromType(sessionType, damageMeterType, sourceGuid, sourceCreatureId)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Secret value protection (Midnight taint model)
-- ---------------------------------------------------------------------------
-- In Midnight (11.2+), Unit* APIs return **secret** values for arena enemy
-- units during PvP combat.  Secret strings/numbers cannot be used as table
-- keys, compared, concatenated, or stored without propagating taint that
-- eventually crashes Blizzard UI code.
--
-- IsSecretValue(v) returns true when `v` is a tainted secret.
-- The Safe* wrappers return nil/false instead of secret values so that all
-- downstream code can rely on normal Lua values.
-- ---------------------------------------------------------------------------

local function isSecretValue(val)
    if val == nil then return false end
    -- Attempt a trivial operation.  If the value is secret the operation
    -- raises an error that pcall catches.
    local ok = pcall(function()
        -- tostring on a secret string errors with "secret value" in Midnight.
        local _ = tostring(val) .. ""
    end)
    return not ok
end

ApiCompat.IsSecretValue = isSecretValue

-- Safely extract a number from a potentially secret value.
-- Returns 0 if the value is secret, nil, or non-numeric.
function ApiCompat.SanitizeNumber(val)
    if val == nil then return 0 end
    if isSecretValue(val) then return 0 end
    return tonumber(val) or 0
end

-- Safely extract a string from a potentially secret value.
-- Returns nil if the value is secret.
function ApiCompat.SanitizeString(val)
    if val == nil then return nil end
    if isSecretValue(val) then return nil end
    if type(val) ~= "string" then return tostring(val) end
    return val
end

-- Safely extract a boolean-ish value from a potentially secret value.
function ApiCompat.SanitizeBool(val)
    if val == nil then return false end
    if isSecretValue(val) then return false end
    return val and true or false
end

-- Returns true when the unit token refers to an arena enemy slot.
local function isArenaUnit(unit)
    return unit and type(unit) == "string" and unit:find("^arena") ~= nil
end

ApiCompat.IsArenaUnit = isArenaUnit

function ApiCompat.GetUnitGUID(unit)
    if not UnitGUID then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or isSecretValue(guid) then return nil end
    return guid
end

function ApiCompat.GetUnitName(unit)
    local fn = GetUnitName or UnitName
    if not fn then return nil end
    local ok, name = pcall(fn, unit, true)
    if not ok or isSecretValue(name) then return nil end
    return name
end

function ApiCompat.GetUnitClass(unit)
    if not UnitClass then
        return nil, nil, nil
    end
    local ok, localized, english, classId = pcall(UnitClass, unit)
    if not ok or isSecretValue(localized) then
        return nil, nil, nil
    end
    return localized, english, classId
end

function ApiCompat.GetUnitRace(unit)
    if not UnitRace then
        return nil, nil, nil
    end
    local ok, localized, english, raceId = pcall(UnitRace, unit)
    if not ok or isSecretValue(localized) then
        return nil, nil, nil
    end
    return localized, english, raceId
end

function ApiCompat.GetUnitLevel(unit)
    if not UnitLevel then return nil end
    local ok, level = pcall(UnitLevel, unit)
    if not ok or isSecretValue(level) then return nil end
    return level
end

function ApiCompat.UnitIsPlayer(unit)
    if not UnitIsPlayer then return false end
    local ok, result = pcall(UnitIsPlayer, unit)
    if not ok then return false end
    return result or false
end

function ApiCompat.UnitCanAttack(attacker, target)
    if not UnitCanAttack then return false end
    local ok, result = pcall(UnitCanAttack, attacker, target)
    if not ok then return false end
    return result or false
end

function ApiCompat.UnitIsEnemy(unitA, unitB)
    if not UnitIsEnemy then return false end
    local ok, result = pcall(UnitIsEnemy, unitA, unitB)
    if not ok then return false end
    return result or false
end

function ApiCompat.UnitExists(unit)
    if not UnitExists then return false end
    local ok, result = pcall(UnitExists, unit)
    if not ok then return false end
    return result or false
end

function ApiCompat.UnitAffectingCombat(unit)
    if not UnitAffectingCombat then return false end
    local ok, result = pcall(UnitAffectingCombat, unit)
    if not ok then return false end
    return result or false
end

function ApiCompat.UnitHealth(unit)
    if not UnitHealth then return 0 end
    local ok, result = pcall(UnitHealth, unit)
    if not ok or isSecretValue(result) then return 0 end
    return result or 0
end

function ApiCompat.UnitHealthMax(unit)
    if not UnitHealthMax then return 0 end
    local ok, result = pcall(UnitHealthMax, unit)
    if not ok or isSecretValue(result) then return 0 end
    return result or 0
end

function ApiCompat.UnitPower(unit, powerType)
    if not UnitPower then return 0 end
    local ok, result = pcall(UnitPower, unit, powerType)
    if not ok or isSecretValue(result) then return 0 end
    return result or 0
end

function ApiCompat.GetBestMapForUnit(unit)
    if C_Map and C_Map.GetBestMapForUnit then
        return C_Map.GetBestMapForUnit(unit)
    end
    return nil
end

function ApiCompat.GetMapInfo(mapId)
    if C_Map and C_Map.GetMapInfo then
        return C_Map.GetMapInfo(mapId)
    end
    return nil
end

function ApiCompat.GetCurrentZoneName()
    local mapId = ApiCompat.GetBestMapForUnit("player")
    local mapInfo = mapId and ApiCompat.GetMapInfo(mapId) or nil
    if mapInfo and mapInfo.name then
        return mapInfo.name, mapId
    end
    return GetZoneText and GetZoneText() or "", mapId
end

function ApiCompat.IsBattleground()
    return C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() or false
end

function ApiCompat.IsInBrawl()
    return C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() or false
end

function ApiCompat.IsWargame()
    return C_PvP and C_PvP.IsWargame and C_PvP.IsWargame() or false
end

function ApiCompat.IsBrawlSoloShuffle()
    return C_PvP and C_PvP.IsBrawlSoloShuffle and C_PvP.IsBrawlSoloShuffle() or false
end

function ApiCompat.IsBrawlSoloRBG()
    return C_PvP and C_PvP.IsBrawlSoloRBG and C_PvP.IsBrawlSoloRBG() or false
end

function ApiCompat.IsRatedArena()
    if C_PvP and C_PvP.IsRatedArena then
        return C_PvP.IsRatedArena()
    end
    return false
end

function ApiCompat.IsArenaSkirmish()
    if C_PvP and C_PvP.IsArenaSkirmish then
        return C_PvP.IsArenaSkirmish()
    end
    return false
end

function ApiCompat.IsRatedBattleground()
    return C_PvP and C_PvP.IsRatedBattleground and C_PvP.IsRatedBattleground() or false
end

function ApiCompat.IsRatedSoloShuffle()
    return C_PvP and C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle() or false
end

function ApiCompat.IsRatedSoloRBG()
    return C_PvP and C_PvP.IsRatedSoloRBG and C_PvP.IsRatedSoloRBG() or false
end

function ApiCompat.IsSoloShuffle()
    if C_PvP and C_PvP.IsSoloShuffle then
        return C_PvP.IsSoloShuffle()
    end
    return ApiCompat.IsRatedSoloShuffle() or ApiCompat.IsBrawlSoloShuffle()
end

function ApiCompat.IsSoloRBG()
    if C_PvP and C_PvP.IsSoloRBG then
        return C_PvP.IsSoloRBG()
    end
    return ApiCompat.IsRatedSoloRBG() or ApiCompat.IsBrawlSoloRBG()
end

function ApiCompat.IsMatchConsideredArena()
    return C_PvP and C_PvP.IsMatchConsideredArena and C_PvP.IsMatchConsideredArena() or false
end

function ApiCompat.GetActiveMatchState()
    return C_PvP and C_PvP.GetActiveMatchState and C_PvP.GetActiveMatchState() or nil
end

function ApiCompat.GetActiveMatchWinner()
    return C_PvP and C_PvP.GetActiveMatchWinner and C_PvP.GetActiveMatchWinner() or nil
end

function ApiCompat.GetTeamInfo(team)
    return C_PvP and C_PvP.GetTeamInfo and C_PvP.GetTeamInfo(team) or nil
end

function ApiCompat.GetScoreInfo(index)
    -- SecretInActivePvPMatch = true: call only after PVP_MATCH_INACTIVE.
    -- pcall as a last-resort guard; callers must sanitize all returned fields.
    if not (C_PvP and C_PvP.GetScoreInfo) then return nil end
    local ok, result = pcall(C_PvP.GetScoreInfo, index)
    if not ok then return nil end
    return result
end

function ApiCompat.GetScoreInfoByPlayerGUID(guid)
    if not (C_PvP and C_PvP.GetScoreInfoByPlayerGuid) then return nil end
    local ok, result = pcall(C_PvP.GetScoreInfoByPlayerGuid, guid)
    if not ok then return nil end
    return result
end

function ApiCompat.GetArenaCrowdControlInfo(unitToken)
    -- SecretWhenLossOfControlInfoRestricted / SecretArguments in Midnight.
    if not (C_PvP and C_PvP.GetArenaCrowdControlInfo) then return nil, nil, nil end
    local ok, a, b, c = pcall(C_PvP.GetArenaCrowdControlInfo, unitToken)
    if not ok then return nil, nil, nil end
    return a, b, c
end

function ApiCompat.RequestCrowdControlSpell(unitToken)
    if C_PvP and C_PvP.RequestCrowdControlSpell then
        C_PvP.RequestCrowdControlSpell(unitToken)
    end
end

function ApiCompat.GetBattlefieldArenaFaction()
    return GetBattlefieldArenaFaction and GetBattlefieldArenaFaction() or nil
end

function ApiCompat.GetArenaOpponentSpec(index)
    if GetArenaOpponentSpec then
        return GetArenaOpponentSpec(index)
    end
    return nil
end

function ApiCompat.GetNumArenaOpponentSpecs()
    if GetNumArenaOpponentSpecs then
        return GetNumArenaOpponentSpecs()
    end
    return 0
end

function ApiCompat.GetSpecialization(inspect, pet)
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        return C_SpecializationInfo.GetSpecialization(inspect, pet)
    end
    return GetSpecialization and GetSpecialization(inspect, pet) or nil
end

function ApiCompat.GetSpecializationInfo(specIndex, inspect, pet, sex)
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        return C_SpecializationInfo.GetSpecializationInfo(specIndex, inspect, pet, sex)
    end
    if GetSpecializationInfo then
        return GetSpecializationInfo(specIndex, inspect, pet, sex)
    end
    return nil
end

function ApiCompat.GetSpecializationInfoByID(specId)
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoByID then
        return C_SpecializationInfo.GetSpecializationInfoByID(specId)
    end
    if GetSpecializationInfoByID then
        return GetSpecializationInfoByID(specId)
    end
    return nil
end

function ApiCompat.GetAllSelectedPvpTalentIDs()
    if C_SpecializationInfo and C_SpecializationInfo.GetAllSelectedPvpTalentIDs then
        return C_SpecializationInfo.GetAllSelectedPvpTalentIDs()
    end
    return {}
end

function ApiCompat.GetInspectSelectedPvpTalent(slot)
    if C_SpecializationInfo and C_SpecializationInfo.GetInspectSelectedPvpTalent then
        return C_SpecializationInfo.GetInspectSelectedPvpTalent(slot)
    end
    return nil
end

function ApiCompat.GetPvpTalentInfo(talentId)
    return GetPvpTalentInfoByID and GetPvpTalentInfoByID(talentId) or nil
end

function ApiCompat.GetAverageItemLevel()
    if GetAverageItemLevel then
        return GetAverageItemLevel()
    end
    return nil, nil
end

function ApiCompat.GetMasteryEffect()
    if GetMasteryEffect then
        return GetMasteryEffect()
    end
    return nil, nil
end

function ApiCompat.GetVersatilityBonuses()
    local damageDoneBonus = 0
    local damageTakenReduction = 0

    if GetCombatRatingBonus and CR_VERSATILITY_DAMAGE_DONE then
        damageDoneBonus = damageDoneBonus + (GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE) or 0)
    end
    if GetCombatRatingBonus and CR_VERSATILITY_DAMAGE_TAKEN then
        damageTakenReduction = damageTakenReduction + (GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_TAKEN) or 0)
    end
    if GetVersatilityBonus and CR_VERSATILITY_DAMAGE_DONE then
        damageDoneBonus = damageDoneBonus + (GetVersatilityBonus(CR_VERSATILITY_DAMAGE_DONE) or 0)
    end
    if GetVersatilityBonus and CR_VERSATILITY_DAMAGE_TAKEN then
        damageTakenReduction = damageTakenReduction + (GetVersatilityBonus(CR_VERSATILITY_DAMAGE_TAKEN) or 0)
    end

    return damageDoneBonus, damageTakenReduction
end

function ApiCompat.GetActiveConfigID()
    return C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() or nil
end

function ApiCompat.GetActiveHeroTalentSpec()
    return C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec and C_ClassTalents.GetActiveHeroTalentSpec() or nil
end

function ApiCompat.GenerateImportString(configId)
    if C_Traits and C_Traits.GenerateImportString then
        return C_Traits.GenerateImportString(configId)
    end
    return nil
end

function ApiCompat.GenerateInspectImportString(unit)
    if C_Traits and C_Traits.GenerateInspectImportString then
        local ok, result = pcall(C_Traits.GenerateInspectImportString, unit)
        if ok and result and not isSecretValue(result) then
            return result
        end
    end
    return nil
end

function ApiCompat.GetConfigInfo(configId)
    return C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configId) or nil
end

function ApiCompat.GetTreeNodes(treeId)
    return C_Traits and C_Traits.GetTreeNodes and C_Traits.GetTreeNodes(treeId) or nil
end

function ApiCompat.GetNodeInfo(configId, nodeId)
    return C_Traits and C_Traits.GetNodeInfo and C_Traits.GetNodeInfo(configId, nodeId) or nil
end

function ApiCompat.GetEntryInfo(configId, entryId)
    return C_Traits and C_Traits.GetEntryInfo and C_Traits.GetEntryInfo(configId, entryId) or nil
end

function ApiCompat.GetDefinitionInfo(definitionId)
    return C_Traits and C_Traits.GetDefinitionInfo and C_Traits.GetDefinitionInfo(definitionId) or nil
end

function ApiCompat.GetUnitAuraDataByAuraInstanceID(unit, auraInstanceId)
    return C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID and C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceId) or nil
end

function ApiCompat.GetUnitAuraDataByIndex(unit, index, filter)
    return C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and C_UnitAuras.GetAuraDataByIndex(unit, index, filter) or nil
end

function ApiCompat.GetInventoryItemID(unit, slot)
    return GetInventoryItemID and GetInventoryItemID(unit, slot) or nil
end

function ApiCompat.GetInventoryItemLink(unit, slot)
    return GetInventoryItemLink and GetInventoryItemLink(unit, slot) or nil
end

function ApiCompat.GetItemInfoInstant(item)
    if GetItemInfoInstant then
        return GetItemInfoInstant(item)
    end
    return nil
end

function ApiCompat.CanInspect(unit)
    if not CanInspect then return false end
    local ok, result = pcall(CanInspect, unit)
    if not ok then return false end
    return result or false
end

function ApiCompat.NotifyInspect(unit)
    if NotifyInspect then
        pcall(NotifyInspect, unit)
    end
end

function ApiCompat.ClearInspectPlayer()
    if ClearInspectPlayer then
        ClearInspectPlayer()
    end
end

function ApiCompat.IsInInstance()
    if IsInInstance then
        return IsInInstance()
    end
    return false, "none"
end

function ApiCompat.GetNormalizedRealmName()
    return GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName() or ""
end

function ApiCompat.GetPlayerGUID()
    return UnitGUID and UnitGUID("player") or nil
end

function ApiCompat.GetPlayerName()
    return UnitName and UnitName("player") or UNKNOWNOBJECT
end

function ApiCompat.GetPlayerClassInfo()
    return ApiCompat.GetUnitClass("player")
end

function ApiCompat.GetPlayerRaceInfo()
    return ApiCompat.GetUnitRace("player")
end

function ApiCompat.GetServerTime()
    return GetServerTime and GetServerTime() or time()
end

function ApiCompat.GetSpellName(spellId)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellId)
    end
    if GetSpellInfo then
        local name = GetSpellInfo(spellId)
        return name
    end
    return nil
end

function ApiCompat.GetSpellTexture(spellId)
    if C_Spell and C_Spell.GetSpellTexture then
        local iconID = C_Spell.GetSpellTexture(spellId)
        return iconID
    end
    if GetSpellInfo then
        local _, _, icon = GetSpellInfo(spellId)
        return icon
    end
    return nil
end

function ApiCompat.IsSpellDataCached(spellId)
    if C_Spell and C_Spell.IsSpellDataCached then
        return C_Spell.IsSpellDataCached(spellId)
    end
    return true
end

function ApiCompat.RequestLoadSpellData(spellId)
    if C_Spell and C_Spell.RequestLoadSpellData and spellId and spellId > 0 then
        C_Spell.RequestLoadSpellData(spellId)
        return true
    end
    return false
end

function ApiCompat.GetSpellInfo(spellId)
    if C_Spell and C_Spell.GetSpellInfo then
        local spellInfo = C_Spell.GetSpellInfo(spellId)
        if spellInfo then
            return spellInfo
        end
    end

    local name = ApiCompat.GetSpellName(spellId)
    local iconID = ApiCompat.GetSpellTexture(spellId)
    if name or iconID then
        return {
            name = name,
            iconID = iconID,
            spellID = spellId,
        }
    end

    if spellId and spellId > 0 and not ApiCompat.IsSpellDataCached(spellId) then
        ApiCompat.RequestLoadSpellData(spellId)
    end

    if GetSpellInfo then
        local name, _, icon, castTime, minRange, maxRange, spellID = GetSpellInfo(spellId)
        return {
            name = name,
            iconID = icon,
            castTime = castTime,
            minRange = minRange,
            maxRange = maxRange,
            spellID = spellID or spellId,
        }
    end
    return nil
end

function ApiCompat.GetSpellCooldown(spellId)
    if C_Spell and C_Spell.GetSpellCooldown then
        return C_Spell.GetSpellCooldown(spellId)
    end
    if GetSpellCooldown then
        local startTime, duration, enabled, modRate = GetSpellCooldown(spellId)
        return {
            startTime = startTime,
            duration = duration,
            isEnabled = enabled == 1,
            modRate = modRate or 1,
        }
    end
    return nil
end

function ApiCompat.AuraIsBigDefensive(spellId)
    if C_UnitAuras and C_UnitAuras.AuraIsBigDefensive then
        return C_UnitAuras.AuraIsBigDefensive(spellId)
    end
    return false
end

function ApiCompat.IsGuidPlayer(guid)
    return type(guid) == "string" and string.sub(guid, 1, 8) == "Player-"
end

function ApiCompat.IsGuidPet(guid)
    return type(guid) == "string" and string.sub(guid, 1, 4) == "Pet-"
end

function ApiCompat.GetCreatureIdFromGUID(guid)
    if not guid then
        return nil
    end
    if C_CreatureInfo and C_CreatureInfo.GetCreatureID then
        return C_CreatureInfo.GetCreatureID(guid)
    end
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" then
        return tonumber(npcId)
    end
    return nil
end

function ApiCompat.CallIfPresent(func, ...)
    return callIfPresent(func, ...)
end

function ApiCompat.GetPVPActiveMatchPersonalRatedInfo()
    if C_PvP and C_PvP.GetPVPActiveMatchPersonalRatedInfo then
        return C_PvP.GetPVPActiveMatchPersonalRatedInfo()
    end
    return nil
end

function ApiCompat.DoesMatchOutcomeAffectRating()
    if C_PvP and C_PvP.DoesMatchOutcomeAffectRating then
        return C_PvP.DoesMatchOutcomeAffectRating()
    end
    return false
end

function ApiCompat.GetGlobalPvpScalingInfoForSpecID(specId)
    if C_PvP and C_PvP.GetGlobalPvpScalingInfoForSpecID then
        return C_PvP.GetGlobalPvpScalingInfoForSpecID(specId)
    end
    return nil
end

function ApiCompat.GetPersonalRatedSoloShuffleSpecStats()
    if C_PvP and C_PvP.GetPersonalRatedSoloShuffleSpecStats then
        return C_PvP.GetPersonalRatedSoloShuffleSpecStats()
    end
    return nil
end

function ApiCompat.GetPersonalRatedBGBlitzSpecStats()
    if C_PvP and C_PvP.GetPersonalRatedBGBlitzSpecStats then
        return C_PvP.GetPersonalRatedBGBlitzSpecStats()
    end
    return nil
end

function ApiCompat.GetPostMatchItemRewards()
    if C_PvP and C_PvP.GetPostMatchItemRewards then
        return C_PvP.GetPostMatchItemRewards()
    end
    return nil
end

function ApiCompat.GetPostMatchCurrencyRewards()
    if C_PvP and C_PvP.GetPostMatchCurrencyRewards then
        return C_PvP.GetPostMatchCurrencyRewards()
    end
    return nil
end

function ApiCompat.GetWeeklyChestInfo()
    if C_PvP and C_PvP.GetWeeklyChestInfo then
        return C_PvP.GetWeeklyChestInfo()
    end
    return nil
end

function ApiCompat.AreTrainingGroundsEnabled()
    if C_PvP and C_PvP.AreTrainingGroundsEnabled then
        return C_PvP.AreTrainingGroundsEnabled()
    end
    return false
end

function ApiCompat.GetTrainingGrounds()
    if C_PvP and C_PvP.GetTrainingGrounds then
        return C_PvP.GetTrainingGrounds()
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- C_SpellDiminish wrappers (Task 2.1)
-- ──────────────────────────────────────────────────────────────────────────────

function ApiCompat.IsSpellDiminishSupported()
    if not C_SpellDiminish or not C_SpellDiminish.IsSystemSupported then return false end
    local ok, result = pcall(C_SpellDiminish.IsSystemSupported)
    return ok and result or false
end

function ApiCompat.GetAllDiminishCategories(ruleset)
    if not C_SpellDiminish or not C_SpellDiminish.GetAllSpellDiminishCategories then return nil end
    local ok, result = pcall(C_SpellDiminish.GetAllSpellDiminishCategories, ruleset)
    return ok and result or nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- C_LossOfControl wrappers (Task 2.2)
-- ──────────────────────────────────────────────────────────────────────────────

function ApiCompat.GetActiveLossOfControlData(unit, index)
    if not C_LossOfControl or not C_LossOfControl.GetActiveLossOfControlDataByUnit then return nil end
    local ok, result = pcall(C_LossOfControl.GetActiveLossOfControlDataByUnit, unit, index)
    return ok and result or nil
end

function ApiCompat.GetActiveLossOfControlDataCount(unit)
    if not C_LossOfControl or not C_LossOfControl.GetActiveLossOfControlDataCountByUnit then return 0 end
    local ok, result = pcall(C_LossOfControl.GetActiveLossOfControlDataCountByUnit, unit)
    return ok and result or 0
end

ns.ApiCompat = ApiCompat
