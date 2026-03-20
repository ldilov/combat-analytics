local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat

local SeedEnricher = {}

-- DR category enum values from C_SpellDiminish (PvP ruleset).
-- Stored at runtime for reference by other modules.
ns.RuntimeDRCategories = nil

-- Maps the numeric SpellDiminishCategory enum to our seed family names.
local DIMINISH_TO_FAMILY = {
    [0]  = "root",
    [1]  = "taunt",
    [2]  = "stun",
    [3]  = "knockback",
    [4]  = "incapacitate",
    [5]  = "disorientation",
    [6]  = "silence",
    [7]  = "disarm",
}

--- Attempt to load authoritative DR category metadata from the Midnight
--- C_SpellDiminish API.  Called once during addon initialisation.
--- Populates ns.RuntimeDRCategories with an array of {id, name, icon, family}.
function SeedEnricher:EnrichDRCategories()
    -- Guard: C_SpellDiminish may not exist on older clients.
    if not C_SpellDiminish or not C_SpellDiminish.IsSystemSupported then
        ns.Addon:Trace("SeedEnricher: C_SpellDiminish not available.")
        return
    end

    local ok, supported = pcall(C_SpellDiminish.IsSystemSupported)
    if not ok or not supported then
        ns.Addon:Trace("SeedEnricher: C_SpellDiminish not supported on this client.")
        return
    end

    -- Enum.SpellDiminishRuleset.PvP == 1
    local ruleset = Enum and Enum.SpellDiminishRuleset and Enum.SpellDiminishRuleset.PvP or 1
    local okCall, categories = pcall(C_SpellDiminish.GetAllSpellDiminishCategories, ruleset)
    if not okCall or not categories then
        ns.Addon:Trace("SeedEnricher: GetAllSpellDiminishCategories returned nil or errored.")
        return
    end

    local result = {}
    for _, catInfo in ipairs(categories) do
        -- catInfo should have: category (enum int), name (string), icon (textureID)
        local entry = {
            id = catInfo.category,
            name = catInfo.name or "Unknown",
            icon = catInfo.icon or 0,
            family = DIMINISH_TO_FAMILY[catInfo.category] or "unknown",
        }
        result[#result + 1] = entry
    end

    ns.RuntimeDRCategories = result
    ns.Addon:Trace(string.format("SeedEnricher: Loaded %d DR categories from C_SpellDiminish.", #result))

    -- Diagnostic: check seed data against runtime categories.
    self:ValidateSeedDRFamilies()
end

--- Cross-reference our seed arenaControl.ccFamilies against the runtime
--- DR categories.  Log warnings for any seed families that don't map to
--- a known runtime category (stale seed data).
function SeedEnricher:ValidateSeedDRFamilies()
    if not ns.RuntimeDRCategories then return end

    local runtimeFamilySet = {}
    for _, cat in ipairs(ns.RuntimeDRCategories) do
        runtimeFamilySet[cat.family] = true
    end

    local seedControl = ns.StaticPvpData and ns.StaticPvpData.ARENA_CONTROL
    if not seedControl or not seedControl.ccFamilies then return end

    for family in pairs(seedControl.ccFamilies) do
        -- Some seed families are custom groupings (polymorph, horror, sleep)
        -- that don't directly map to a single diminish category — skip those.
        if not runtimeFamilySet[family] and family ~= "polymorph" and family ~= "horror" and family ~= "sleep" then
            ns.Addon:Trace(string.format("SeedEnricher: Seed CC family '%s' has no matching runtime DR category.", family))
        end
    end
end

function SeedEnricher:Init()
    self:EnrichDRCategories()
end

ns.Addon:RegisterModule("SeedEnricher", SeedEnricher)
