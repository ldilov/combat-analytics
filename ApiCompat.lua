local _, ns = ...

local ApiCompat = {}

local function callIfPresent(func, ...)
    if type(func) ~= "function" then
        return nil
    end
    return func(...)
end

function ApiCompat.GetCombatLogEventInfo()
    if C_CombatLog and C_CombatLog.GetCurrentEventInfo then
        return C_CombatLog.GetCurrentEventInfo()
    end
    if CombatLogGetCurrentEventInfo then
        return CombatLogGetCurrentEventInfo()
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
    if C_CombatLog and C_CombatLog.IsCurrentEventInfoRestricted then
        return C_CombatLog.IsCurrentEventInfoRestricted()
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

function ApiCompat.GetUnitGUID(unit)
    return UnitGUID and UnitGUID(unit) or nil
end

function ApiCompat.GetUnitName(unit)
    return GetUnitName and GetUnitName(unit, true) or (UnitName and UnitName(unit))
end

function ApiCompat.GetUnitClass(unit)
    if not UnitClass then
        return nil, nil, nil
    end
    local localized, english, classId = UnitClass(unit)
    return localized, english, classId
end

function ApiCompat.GetUnitRace(unit)
    if not UnitRace then
        return nil, nil, nil
    end
    local localized, english, raceId = UnitRace(unit)
    return localized, english, raceId
end

function ApiCompat.GetUnitLevel(unit)
    return UnitLevel and UnitLevel(unit) or nil
end

function ApiCompat.UnitIsPlayer(unit)
    return UnitIsPlayer and UnitIsPlayer(unit) or false
end

function ApiCompat.UnitCanAttack(attacker, target)
    return UnitCanAttack and UnitCanAttack(attacker, target) or false
end

function ApiCompat.UnitIsEnemy(unitA, unitB)
    return UnitIsEnemy and UnitIsEnemy(unitA, unitB) or false
end

function ApiCompat.UnitExists(unit)
    return UnitExists and UnitExists(unit) or false
end

function ApiCompat.UnitAffectingCombat(unit)
    return UnitAffectingCombat and UnitAffectingCombat(unit) or false
end

function ApiCompat.UnitHealth(unit)
    return UnitHealth and UnitHealth(unit) or 0
end

function ApiCompat.UnitHealthMax(unit)
    return UnitHealthMax and UnitHealthMax(unit) or 0
end

function ApiCompat.UnitPower(unit, powerType)
    return UnitPower and UnitPower(unit, powerType) or 0
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
    return C_PvP and C_PvP.GetScoreInfo and C_PvP.GetScoreInfo(index) or nil
end

function ApiCompat.GetScoreInfoByPlayerGUID(guid)
    return C_PvP and C_PvP.GetScoreInfoByPlayerGuid and C_PvP.GetScoreInfoByPlayerGuid(guid) or nil
end

function ApiCompat.GetArenaCrowdControlInfo(unitToken)
    return C_PvP and C_PvP.GetArenaCrowdControlInfo and C_PvP.GetArenaCrowdControlInfo(unitToken) or nil
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
        return C_Traits.GenerateInspectImportString(unit)
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
    return CanInspect and CanInspect(unit) or false
end

function ApiCompat.NotifyInspect(unit)
    if NotifyInspect then
        NotifyInspect(unit)
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

function ApiCompat.GetSpellInfo(spellId)
    if C_Spell and C_Spell.GetSpellInfo then
        return C_Spell.GetSpellInfo(spellId)
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

ns.ApiCompat = ApiCompat
