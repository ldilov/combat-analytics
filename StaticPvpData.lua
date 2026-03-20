local _, ns = ...

local Helpers = ns.Helpers
local Constants = ns.Constants
local generated = ns.GeneratedSeedData or {}
local seedMaps             = ns.SeedMaps             or {}
local seedCompArchetypes   = ns.SeedCompArchetypes   or {}
local seedMetricThresholds = ns.SeedMetricThresholds or {}

local function normalizeName(name)
    local value = string.lower(Helpers.Trim(tostring(name or "")) or "")
    value = string.gsub(value, "%s+", " ")
    return value
end

local function mergeInto(target, source)
    for key, value in pairs(source or {}) do
        if type(value) == "table" and type(target[key]) == "table" then
            mergeInto(target[key], value)
        elseif type(value) == "table" then
            target[key] = Helpers.CopyTable(value, true)
        else
            target[key] = value
        end
    end
end

local themePresets = {
    modern_steel_ember = {
        background = { 0.05, 0.06, 0.08, 0.97 },
        panel = { 0.09, 0.10, 0.13, 0.97 },
        panelAlt = { 0.12, 0.13, 0.17, 0.97 },
        border = { 0.22, 0.24, 0.29, 1.0 },
        borderStrong = { 0.58, 0.42, 0.27, 1.0 },
        accent = { 0.92, 0.47, 0.22, 1.0 },
        accentSoft = { 0.30, 0.20, 0.15, 1.0 },
        text = { 0.93, 0.94, 0.96, 1.0 },
        textMuted = { 0.67, 0.70, 0.75, 1.0 },
        success = { 0.45, 0.74, 0.56, 1.0 },
        warning = { 0.95, 0.67, 0.26, 1.0 },
        panelHover = { 0.17, 0.14, 0.14, 0.98 },
        panelDisabled = { 0.07, 0.08, 0.10, 0.95 },
        barShell = { 0.08, 0.09, 0.11, 1.0 },
        header = { 0.08, 0.09, 0.12, 0.98 },
        contentShell = { 0.08, 0.09, 0.12, 0.97 },
        severityHigh = { 0.33, 0.16, 0.14, 1.0 },
        severityMedium = { 0.30, 0.21, 0.13, 1.0 },
        severityLow = { 0.15, 0.19, 0.24, 1.0 },
    },
}

local spellIntelligence = Helpers.CopyTable(generated.spellIntelligence or {}, true)
local dummyCatalog = Helpers.CopyTable(generated.dummyCatalog or {}, true)
local specArchetypes = Helpers.CopyTable(generated.specArchetypes or {}, true)
local arenaControl = Helpers.CopyTable(generated.arenaControl or {}, true)

local spellTaxonomy = {
    majorOffensive = {},
    majorDefensive = {},
}

for spellId, info in pairs(spellIntelligence) do
    if info.isMajorOffensive then
        spellTaxonomy.majorOffensive[spellId] = true
    end
    if info.isMajorDefensive then
        spellTaxonomy.majorDefensive[spellId] = true
    end
end

ns.StaticPvpData = {
    THEME_PRESETS = themePresets,
    SPELL_TAXONOMY = spellTaxonomy,
    SPELL_INTELLIGENCE = spellIntelligence,
    INSIGHT_RULES = {
        minimumMatchupSamples = 3,
        minimumBuildSamples = 5,
        openerWarningRatio = 0.85,
        strongPressureRatio = 1.10,
    },
    DUMMY_CATALOG = dummyCatalog,
    SPEC_ARCHETYPES = specArchetypes,
    ARENA_CONTROL = arenaControl,
    MAPS               = seedMaps,
    COMP_ARCHETYPES    = seedCompArchetypes,
    METRIC_THRESHOLDS  = seedMetricThresholds,
}

function ns.StaticPvpData.GetDummyInfo(creatureId)
    return creatureId and ns.StaticPvpData.DUMMY_CATALOG[creatureId] or nil
end

function ns.StaticPvpData.GetSpecArchetype(specId)
    return specId and ns.StaticPvpData.SPEC_ARCHETYPES[specId] or nil
end

function ns.StaticPvpData.GetCCFamiliesForSpec(specId)
    if not specId then return {} end
    return ns.StaticPvpData.ARENA_CONTROL.specCCLists and
           ns.StaticPvpData.ARENA_CONTROL.specCCLists[specId] or {}
end

function ns.StaticPvpData.GetImmunities()
    -- Returns the immunityTags table (shared, not per-spec)
    return ns.StaticPvpData.ARENA_CONTROL.immunityTags or {}
end

function ns.StaticPvpData.GetCCFamily(spellId)
    if not spellId then return nil end
    local families = ns.StaticPvpData.ARENA_CONTROL.ccFamilies
    if not families then return nil end
    for family, spells in pairs(families) do
        for _, entry in ipairs(spells) do
            if entry.spellId == spellId then
                return family
            end
        end
    end
    return nil
end

function ns.StaticPvpData.GetSpellInfo(spellId)
    return spellId and spellIntelligence[spellId] or nil
end

function ns.StaticPvpData.GetMapInfo(mapId)
    if not mapId then return nil end
    local m = ns.StaticPvpData.MAPS
    return (m.arenas       and m.arenas[mapId])
        or (m.battlegrounds and m.battlegrounds[mapId])
        or nil
end

function ns.StaticPvpData.IsTrainingDummyName(name)
    local normalized = normalizeName(name)
    if normalized == "" then
        return false
    end
    for _, record in pairs(ns.StaticPvpData.DUMMY_CATALOG) do
        if normalizeName(record.displayName) == normalized or normalizeName(record.normalizedName) == normalized then
            return true
        end
    end
    return false
end

mergeInto(ns.StaticPvpData.INSIGHT_RULES, generated.insightRules or {})

for spellId, info in pairs(ns.StaticPvpData.SPELL_INTELLIGENCE) do
    if info.category and Constants.SPELL_CATEGORIES[spellId] == nil then
        Constants.SPELL_CATEGORIES[spellId] = info.category
    end
end

ns.StaticPvpData.BG_STAT_NAMES = {
    [156] = "Flag Captures",
    [157] = "Flag Returns",
    [679] = "Bases Assaulted",
    [682] = "Bases Defended",
    [114] = "Honorable Kills",
    [115] = "Deaths",
    [692] = "Demolishers Destroyed",
    [693] = "Gates Destroyed",
    [218] = "Orb Possessions",
    [219] = "Victory Points",
}

for creatureId in pairs(ns.StaticPvpData.DUMMY_CATALOG) do
    Constants.TRAINING_DUMMY_CREATURE_IDS[creatureId] = true
end

for _, record in pairs(ns.StaticPvpData.DUMMY_CATALOG) do
    local normalized = record.normalizedName or record.displayName
    if normalized and not Helpers.ArrayFind(Constants.TRAINING_DUMMY_PATTERNS, function(value)
        return normalizeName(value) == normalizeName(normalized)
    end) then
        Constants.TRAINING_DUMMY_PATTERNS[#Constants.TRAINING_DUMMY_PATTERNS + 1] = normalized
    end
end
