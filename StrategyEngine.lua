local _, ns = ...

local Constants = ns.Constants

local StrategyEngine = {}

-- Static per-archetype recommended actions.
local ARCHETYPE_ACTIONS = {
    setup_burst = {
        "Survive the setup window — pre-position defensives before the CC chain lands.",
        "Trinket only the critical CC in the chain, not the opener.",
        "Counter-pressure during their downtime between goes.",
    },
    sustained_caster = {
        "Interrupt or kick key casts on cooldown to disrupt sustained pressure.",
        "Maintain melee uptime or LoS to reduce free casting time.",
        "Save burst for windows when their defenses are on cooldown.",
    },
    melee_pressure = {
        "Kite during their offensive cooldowns — they rely on uptime.",
        "Peel or CC them off your healer during their go windows.",
        "Trade cooldowns efficiently — their pressure is constant, not bursty.",
    },
    skirmisher = {
        "Track their mobility cooldowns — they re-engage aggressively.",
        "Don't overcommit defensives to chip damage; wait for committed goes.",
        "Control the pace — force them to play reactive instead of proactive.",
    },
    control_healer = {
        "Coordinate CC chains on the healer during your go windows.",
        "Purge or dispel key healing buffs before attempting a kill.",
        "Pressure the DPS to force early healer cooldowns.",
    },
    reactive_healer = {
        "Land kill attempts in CC windows when the healer can't react.",
        "Apply sustained pressure to force throughput cooldowns early.",
        "Swap to the healer if DPS is too defensively loaded.",
    },
    bruiser = {
        "Avoid trading into them in prolonged 1v1 — they outlast most specs.",
        "Focus on their teammates — bruisers struggle to peel at range.",
        "Save burst for execute range where their tankiness matters less.",
    },
    sustained_ranged = {
        "Close distance quickly — their damage drops in melee range.",
        "Interrupt key shots and use LoS to reduce free damage.",
        "Pressure hard during pet downtime if applicable.",
    },
}

-- Fallback actions for unknown archetypes.
local DEFAULT_ACTIONS = {
    "Track their major offensive cooldowns and respond with defensives.",
    "Look for CC windows to set up your own kill attempts.",
    "Play to your spec's strengths rather than reacting to theirs.",
}

function StrategyEngine.GetCounterGuide(specId, playerBuildHash, characterKey)
    if not specId then return nil end

    local store = ns.Addon:GetModule("CombatStore")
    local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(specId) or nil
    local ccFamilies = ns.StaticPvpData and ns.StaticPvpData.GetCCFamiliesForSpec(specId) or {}
    local specSignature = store and store.GetSpecDamageSignature and store:GetSpecDamageSignature(specId) or {}
    local buildEffectiveness = playerBuildHash and store and store.GetBuildEffectivenessVsSpec
        and store:GetBuildEffectivenessVsSpec(playerBuildHash, specId) or nil
    local bestBuild = store and store.GetBestBuildVsSpec and store:GetBestBuildVsSpec(specId) or nil
    local winRateByMMR = store and store.GetSpecWinRateByMMRBand
        and store:GetSpecWinRateByMMRBand(specId, characterKey) or {}

    -- Historical win rate from spec aggregate.
    local specWinRate = nil
    local specFights = 0
    if store and store.GetAggregateBuckets then
        local specBuckets = store:GetAggregateBuckets("specs")
        local specKey = tostring(specId)
        if specBuckets and specBuckets[specKey] then
            local bucket = specBuckets[specKey]
            specFights = bucket.fights or 0
            if specFights > 0 then
                specWinRate = (bucket.wins or 0) / specFights
            end
        end
    end

    -- Top opponent spells (from specDamageSignatures).
    local topSpellsFromOpponent = {}
    for i, entry in ipairs(specSignature) do
        if i > 5 then break end
        topSpellsFromOpponent[i] = entry
    end

    -- Archetype-based recommended actions.
    local archetypeKey = archetype and archetype.archetype or nil
    local recommendedActions = ARCHETYPE_ACTIONS[archetypeKey] or DEFAULT_ACTIONS

    return {
        specId = specId,
        archetypeLabel = archetype and archetype.archetype or "unknown",
        specName = archetype and archetype.specName or nil,
        classFile = archetype and archetype.classFile or nil,
        rangeBucket = archetype and archetype.rangeBucket or "unknown",
        threatTags = archetype and archetype.threatTags or {},
        ccFamilies = ccFamilies,
        topSpellsFromOpponent = topSpellsFromOpponent,
        historicalWinRate = specWinRate,
        historicalFights = specFights,
        winRateByMMRBand = winRateByMMR,
        bestBuildVsSpec = bestBuild,
        currentBuildEffectiveness = buildEffectiveness,
        recommendedActions = recommendedActions,
    }
end

-- Convenience: check if enough data exists for a meaningful guide.
function StrategyEngine.HasSufficientData(specId, characterKey)
    local store = ns.Addon:GetModule("CombatStore")
    if not store or not store.GetAggregateBuckets then return false end
    local specBuckets = store:GetAggregateBuckets("specs")
    local specKey = tostring(specId)
    return specBuckets and specBuckets[specKey] and (specBuckets[specKey].fights or 0) >= 5
end

ns.Addon:RegisterModule("StrategyEngine", StrategyEngine)
