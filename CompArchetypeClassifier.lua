local _, ns = ...

-- CompArchetypeClassifier
-- Classifies the enemy team's comp archetype from a list of known spec IDs.
-- Called in FinalizeSession after ArenaRoundTracker:CopyStateIntoSession().
-- Writes to session.arena.compArchetype.
--
-- Role strings in SeedSpecArchetypes: "DAMAGER", "HEALER", "TANK" (uppercase).
-- rangeBucket values:                 "melee",   "ranged"          (lowercase).
-- Slot spec ID field:                 prepSpecId  (set by ArenaRoundTracker).

local Classifier = {}

-- Returns a simplified role key for the given spec ID.
-- "DAMAGER" is split into "melee_dps" or "ranged_dps" using rangeBucket.
local function getSpecRole(specId)
    local archetype = ns.StaticPvpData.GetSpecArchetype(specId)
    if not archetype then return "unknown" end
    local role        = archetype.role
    local rangeBucket = archetype.rangeBucket
    if role == "HEALER" then
        return "healer"
    elseif role == "TANK" then
        return "tank"
    elseif role == "DAMAGER" then
        if rangeBucket == "melee" then
            return "melee_dps"
        else
            -- "ranged" or anything else → treat as ranged/caster DPS
            return "ranged_dps"
        end
    end
    return "unknown"
end

-- Classify an enemy team from an array of specId integers (may contain nils/zeros).
-- Returns an archetype id string (e.g. "double_melee_healer") or "unknown".
function Classifier.ClassifyComp(specIds)
    if not specIds or #specIds == 0 then return "unknown" end

    local meleeDps   = 0
    local casterDps  = 0
    local anyDps     = 0
    local healers    = 0
    local totalKnown = 0

    for _, specId in ipairs(specIds) do
        if specId and specId > 0 then
            local role = getSpecRole(specId)
            totalKnown = totalKnown + 1
            if role == "melee_dps"  then meleeDps  = meleeDps  + 1; anyDps = anyDps + 1 end
            if role == "ranged_dps" then casterDps = casterDps + 1; anyDps = anyDps + 1 end
            if role == "healer"     then healers   = healers   + 1 end
            -- "tank" role counts toward totalKnown but no role bucket; falls through to "unknown".
            -- Tank specs do not appear in 2v2/3v3 rated arena in practice.
        end
    end

    if totalKnown == 0 then return "unknown" end

    local compData = ns.StaticPvpData.COMP_ARCHETYPES
    if not compData or not compData.archetypes then return "unknown" end

    for _, arch in ipairs(compData.archetypes) do
        local match = true
        if arch.minMelee  and meleeDps  < arch.minMelee  then match = false end
        if arch.minCaster and casterDps < arch.minCaster then match = false end
        if arch.minAnyDps and anyDps    < arch.minAnyDps then match = false end
        -- requiresHealer = false means "no healer constraint" (unconstrained), NOT "must have no healer".
        if arch.requiresHealer == true and healers < 1 then match = false end
        if match then return arch.id end
    end

    return "unknown"
end

ns.CompArchetypeClassifier = Classifier
