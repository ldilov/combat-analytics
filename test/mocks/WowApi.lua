-- test/mocks/WowApi.lua
-- Mock implementations of WoW global API functions used by attribution modules.
--
-- Each mock is backed by a configurable lookup table so individual test
-- suites can set up only the data they need.
--
-- Usage:
--   dofile("test/mocks/WowApi.lua")
--   WowMock.units["target"] = { guid = "Player-123", name = "Frostbolt", class = "MAGE", classFile = "MAGE" }
--   WowMock.time = 1000.5
--   -- now UnitGUID("target") returns "Player-123"

WowMock = {
    -- { [unitToken] = { guid, name, class, classFile, ... } }
    units = {},
    -- { [guid] = { owner = { guid, name, class, classFile } } } — pet→owner
    petOwners = {},
    -- { [spellId] = { name, rank, icon, castTime, minRange, maxRange } }
    spells = {},
    -- { [unitToken] = { [index] = auraData } }
    auras = {},
    -- Simulated GetTime() return value
    time = 0,
    -- Simulated IsUnit results: { [tokenA.."|"..tokenB] = bool }
    unitEquality = {},
}

-- ---------------------------------------------------------------------------
-- UnitGUID
-- ---------------------------------------------------------------------------
function UnitGUID(unitToken)
    local entry = WowMock.units[unitToken]
    return entry and entry.guid or nil
end

-- ---------------------------------------------------------------------------
-- UnitName
-- ---------------------------------------------------------------------------
function UnitName(unitToken)
    local entry = WowMock.units[unitToken]
    if not entry then return nil, nil end
    return entry.name or nil, entry.realm or nil
end

-- ---------------------------------------------------------------------------
-- UnitClass
-- ---------------------------------------------------------------------------
--- Returns className (display), classFilename, classId
function UnitClass(unitToken)
    local entry = WowMock.units[unitToken]
    if not entry then return nil, nil, nil end
    return entry.class or nil, entry.classFile or nil, entry.classId or nil
end

-- ---------------------------------------------------------------------------
-- UnitExists
-- ---------------------------------------------------------------------------
function UnitExists(unitToken)
    return WowMock.units[unitToken] ~= nil
end

-- ---------------------------------------------------------------------------
-- UnitIsPlayer
-- ---------------------------------------------------------------------------
function UnitIsPlayer(unitToken)
    local entry = WowMock.units[unitToken]
    return entry and (entry.isPlayer ~= false) or false
end

function UnitCanAttack(attacker, target)
    local entry = WowMock.units[target]
    return entry and entry.isHostile or false
end

function UnitIsEnemy(unitA, unitB)
    local entry = WowMock.units[unitB]
    return entry and entry.isHostile or false
end

-- ---------------------------------------------------------------------------
-- IsUnit
-- ---------------------------------------------------------------------------
--- Returns true when tokenA and tokenB refer to the same unit.
function IsUnit(tokenA, tokenB)
    -- First check explicit overrides.
    local key1 = tokenA .. "|" .. tokenB
    local key2 = tokenB .. "|" .. tokenA
    if WowMock.unitEquality[key1] ~= nil then
        return WowMock.unitEquality[key1]
    end
    if WowMock.unitEquality[key2] ~= nil then
        return WowMock.unitEquality[key2]
    end
    -- Fall back to comparing GUIDs.
    local gA = UnitGUID(tokenA)
    local gB = UnitGUID(tokenB)
    if gA and gB then
        return gA == gB
    end
    -- Same token is trivially equal.
    return tokenA == tokenB
end

-- ---------------------------------------------------------------------------
-- GetSpellInfo
-- ---------------------------------------------------------------------------
--- Returns name, rank, icon, castTime, minRange, maxRange, spellId
function GetSpellInfo(spellId)
    local entry = WowMock.spells[spellId]
    if not entry then return nil end
    return entry.name, entry.rank or "", entry.icon or 0,
           entry.castTime or 0, entry.minRange or 0, entry.maxRange or 0,
           spellId
end

-- ---------------------------------------------------------------------------
-- GetTime
-- ---------------------------------------------------------------------------
function GetTime()
    return WowMock.time
end

-- ---------------------------------------------------------------------------
-- C_UnitAuras.GetAuraDataByIndex
-- ---------------------------------------------------------------------------
C_UnitAuras = C_UnitAuras or {}

function C_UnitAuras.GetAuraDataByIndex(unitToken, index, filter)
    local unitAuras = WowMock.auras[unitToken]
    if not unitAuras then return nil end
    local aura = unitAuras[index]
    if not aura then return nil end
    -- Optionally filter by HELPFUL/HARMFUL if the mock entry has a filter field.
    if filter and aura.filter and aura.filter ~= filter then
        return nil
    end
    return aura
end

-- Also expose the full aura list as ForEachAura convenience:
function C_UnitAuras.GetAuraDataBySpellID(unitToken, spellId, filter)
    local unitAuras = WowMock.auras[unitToken]
    if not unitAuras then return nil end
    for _, aura in pairs(unitAuras) do
        if aura.spellId == spellId then
            if not filter or not aura.filter or aura.filter == filter then
                return aura
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- C_PvP stubs (no-op by default, override per test)
-- ---------------------------------------------------------------------------
C_PvP = C_PvP or {}

function C_PvP.GetScoreInfo(index)          return nil end
function C_PvP.GetPVPActiveMatchPersonalRatedInfo() return nil end
function C_PvP.GetArenaCrowdControlInfo(playerToken) return nil end

-- ---------------------------------------------------------------------------
-- WowMock helpers
-- ---------------------------------------------------------------------------

--- Convenience: register a unit with all fields at once.
---@param token string        Unit token (e.g. "arena1", "target")
---@param data  table         { guid, name, class, classFile, classId, isPlayer, realm }
function WowMock.SetUnit(token, data)
    WowMock.units[token] = data
end

--- Convenience: register a spell.
---@param spellId number
---@param data    table  { name, icon, castTime, minRange, maxRange }
function WowMock.SetSpell(spellId, data)
    WowMock.spells[spellId] = data
end

--- Convenience: add an aura to a unit's aura list (appends to list).
---@param token   string  Unit token
---@param aura    table   AuraData-style table { spellId, name, sourceUnit, duration, expirationTime, ... }
function WowMock.AddAura(token, aura)
    WowMock.auras[token] = WowMock.auras[token] or {}
    local list = WowMock.auras[token]
    list[#list + 1] = aura
end

--- Reset all mock state to empty.
function WowMock.Reset()
    WowMock.units        = {}
    WowMock.petOwners    = {}
    WowMock.spells       = {}
    WowMock.auras        = {}
    WowMock.time         = 0
    WowMock.unitEquality = {}
end

-- ---------------------------------------------------------------------------
-- WoW global stubs (no-op unless overridden)
-- ---------------------------------------------------------------------------

-- Common globals that modules may call at module load time.
GetLocale       = GetLocale       or function() return "enUS" end
date            = date            or os.date
math.huge       = math.huge
string.format   = string.format

-- Texture / frame globals (no-op stubs so modules that call them don't crash).
CreateFrame = CreateFrame or function(frameType, name, parent, template)
    local f = { frameType = frameType, name = name }
    local mt = {}
    mt.__index = function(t, k)
        -- Return a no-op function for any unknown method.
        return function(...) return nil end
    end
    return setmetatable(f, mt)
end
