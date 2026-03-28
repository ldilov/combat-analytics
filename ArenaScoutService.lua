local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers   = ns.Helpers

-- ArenaScoutService
-- Produces pre-match scout cards and between-round adaptation cards for arena.
-- Consumes:
--   • ArenaRoundTracker.prepOpponents / slot data
--   • CombatStore aggregate spec buckets
--   • StaticPvpData (spec archetypes, spell intelligence, counter tips)
--   • CompArchetypeClassifier
-- Outputs:
--   • scoutCard  — per-enemy scouting + comp analysis   (T083)
--   • adaptationCard — round-over-round tactical advice  (T084)
--   • inspect enrichment                                 (T085)

local ArenaScoutService = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Constants
-- ──────────────────────────────────────────────────────────────────────────────

local MAX_WATCH_SPELLS  = 3
local DEATH_CAUSE_WINDOW_SECONDS = 6
local HEALER_PRESSURE_HIGH_THRESHOLD   = 0.25
local HEALER_PRESSURE_MEDIUM_THRESHOLD = 0.10

-- ──────────────────────────────────────────────────────────────────────────────
-- notesTag → classFile mapping for SPELL_INTELLIGENCE.
-- Used to associate offensive spells with a class when SPELL_INTELLIGENCE
-- entries lack an explicit specId field.
-- ──────────────────────────────────────────────────────────────────────────────

local NOTES_TAG_TO_CLASS = {
    -- Mage
    fire_burst         = "MAGE",
    mage_burst         = "MAGE",
    caster_haste_go    = "MAGE",
    -- Paladin
    paladin_burst      = "PALADIN",
    holy_paladin_burst = "PALADIN",
    -- Warrior
    warrior_burst      = "WARRIOR",
    warrior_avatar     = "WARRIOR",
    -- Hunter
    hunter_burst       = "HUNTER",
    mm_burst           = "HUNTER",
    sv_burst           = "HUNTER",
    -- Rogue
    outlaw_burst       = "ROGUE",
    assassination_burst = "ROGUE",
    sub_burst          = "ROGUE",
    sub_burst_blades   = "ROGUE",
    outlaw_adrenaline  = "ROGUE",
    -- Priest
    shadow_burst       = "PRIEST",
    power_infusion     = "PRIEST",
    -- Warlock
    affliction_burst   = "WARLOCK",
    demo_burst         = "WARLOCK",
    destro_burst       = "WARLOCK",
    -- Druid
    feral_burst        = "DRUID",
    feral_incarn       = "DRUID",
    balance_burst      = "DRUID",
    balance_incarn     = "DRUID",
    -- Shaman
    ele_burst          = "SHAMAN",
    ele_ascendance     = "SHAMAN",
    enh_ascendance     = "SHAMAN",
    bloodlust          = "SHAMAN",
    heroism            = "SHAMAN",
    -- Death Knight
    dk_rune_weapon     = "DEATHKNIGHT",
    unholy_army        = "DEATHKNIGHT",
    unholy_transform   = "DEATHKNIGHT",
    -- Demon Hunter
    havoc_meta         = "DEMONHUNTER",
    havoc_momentum     = "DEMONHUNTER",
    devourer_burst     = "DEMONHUNTER",
    -- Monk
    ww_sef             = "MONK",
    ww_serenity        = "MONK",
    ww_xuen            = "MONK",
    -- Evoker
    dev_dragonrage     = "EVOKER",
    aug_boe            = "EVOKER",
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Local helpers
-- ──────────────────────────────────────────────────────────────────────────────

--- Build a class → sorted offensive spells lookup from SPELL_INTELLIGENCE.
--- Cached after first call for the session lifetime.
local classOffensiveSpellsCache = nil

local function getClassOffensiveSpells()
    if classOffensiveSpellsCache then return classOffensiveSpellsCache end

    local spellIntel = ns.StaticPvpData and ns.StaticPvpData.SPELL_INTELLIGENCE or {}
    local byClass = {}

    for spellId, info in pairs(spellIntel) do
        if info.isMajorOffensive and info.notesTag then
            local classFile = NOTES_TAG_TO_CLASS[info.notesTag]
            if classFile then
                byClass[classFile] = byClass[classFile] or {}
                byClass[classFile][#byClass[classFile] + 1] = {
                    spellId   = spellId,
                    notesTag  = info.notesTag,
                    isBurst   = info.isBurstEnabler or false,
                }
            end
        end
    end

    -- Sort each class list: burst enablers first, then by spellId for stability.
    -- Lua 5.1 does not support comparison operators on booleans; convert to
    -- numeric rank (0 = burst, 1 = non-burst) for a stable sort.
    for classFile, list in pairs(byClass) do
        table.sort(list, function(a, b)
            local aBurst = a.isBurst and 0 or 1
            local bBurst = b.isBurst and 0 or 1
            if aBurst ~= bBurst then
                return aBurst < bBurst
            end
            return a.spellId < b.spellId
        end)
    end

    classOffensiveSpellsCache = byClass
    return byClass
end

--- Return up to MAX_WATCH_SPELLS offensive threat spells for a spec.
--- Uses classFile from the spec archetype to find relevant offensive spells.
local function getWatchForSpells(specId)
    local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(specId) or nil
    if not archetype then return {} end

    local classFile = archetype.classFile
    local classCatalog = getClassOffensiveSpells()
    local classSpells = classCatalog[classFile]
    if not classSpells then return {} end

    local result = {}
    for i = 1, math.min(MAX_WATCH_SPELLS, #classSpells) do
        local entry = classSpells[i]
        result[#result + 1] = {
            spellId  = entry.spellId,
            notesTag = entry.notesTag,
            isBurst  = entry.isBurst,
        }
    end
    return result
end

--- Resolve a simplified role string for comp summary display.
--- Returns "melee", "ranged", or "healer".
local function getDisplayRole(archetype)
    if not archetype then return "unknown" end
    if archetype.role == "HEALER" then return "healer" end
    if archetype.role == "TANK" then return "melee" end
    return archetype.rangeBucket or "unknown"
end

--- Build a human-readable comp summary from an array of display roles.
--- e.g. {"melee", "melee", "healer"} → "melee/melee/healer"
local function buildCompSummary(roles)
    if not roles or #roles == 0 then return "unknown" end
    -- Sort for consistency: healer last, melee before ranged.
    local order = { melee = 1, ranged = 2, healer = 3, unknown = 4 }
    local sorted = {}
    for i = 1, #roles do sorted[i] = roles[i] end
    table.sort(sorted, function(a, b)
        return (order[a] or 4) < (order[b] or 4)
    end)
    return table.concat(sorted, "/")
end

--- Classify comp archetype using CompArchetypeClassifier if available,
--- falling back to the comp summary string.
local function classifyCompArchetype(specIds)
    local classifier = ns.CompArchetypeClassifier
    if classifier and classifier.ClassifyComp then
        return classifier.ClassifyComp(specIds)
    end
    return "unknown"
end

--- Look up historical win rate and fight count from spec aggregate buckets.
--- Returns winRate (number or nil), fights (number).
local function getHistoricalStats(specId, aggregateSpecs)
    if not specId or not aggregateSpecs then return nil, 0 end

    local searchKey = tostring(specId)
    for _, bucket in ipairs(aggregateSpecs) do
        if bucket.key == searchKey then
            local fights = bucket.fights or 0
            if fights > 0 then
                local wins = bucket.wins or 0
                return wins / fights, fights
            end
            return nil, fights
        end
    end
    return nil, 0
end

--- Compute an aggregate win rate across all enemy specs combined.
--- Weighted by number of fights per spec.
local function computeOverallWR(enemies)
    local totalWins   = 0
    local totalFights = 0
    for _, enemy in ipairs(enemies) do
        if enemy.historicalWR and enemy.historicalFights and enemy.historicalFights > 0 then
            totalWins   = totalWins + (enemy.historicalWR * enemy.historicalFights)
            totalFights = totalFights + enemy.historicalFights
        end
    end
    if totalFights == 0 then return nil end
    return totalWins / totalFights
end

-- ──────────────────────────────────────────────────────────────────────────────
-- T083: BuildScoutCard
-- ──────────────────────────────────────────────────────────────────────────────

--- Build a pre-match scout card from prep opponent data and historical aggregates.
--- @param matchRecord table  Current match state from ArenaRoundTracker.
--- @param prepOpponents table  Array of opponent slot data from ArenaRoundTracker.
--- @param aggregates table  Player aggregate data from CombatStore.
--- @return table scoutCard
function ArenaScoutService.BuildScoutCard(matchRecord, prepOpponents, aggregates)
    if not prepOpponents then
        return {
            enemies       = {},
            compArchetype = "unknown",
            compSummary   = "unknown",
            overallWR     = nil,
            confidence    = "prep",
        }
    end

    local aggregateSpecs = aggregates and aggregates.specs or {}
    local enemies = {}
    local displayRoles = {}
    local specIds = {}

    for _, opp in ipairs(prepOpponents) do
        local specId   = opp.specId
        local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(specId) or nil

        local wr, fights = getHistoricalStats(specId, aggregateSpecs)
        local watchFor   = getWatchForSpells(specId)

        local entry = {
            specId          = specId,
            specName        = (archetype and archetype.specName) or opp.specName or nil,
            classFile       = (archetype and archetype.classFile) or opp.classFile or nil,
            role            = archetype and archetype.role or nil,
            archetype       = archetype and archetype.archetype or nil,
            rangeBucket     = archetype and archetype.rangeBucket or nil,
            historicalWR    = wr,
            historicalFights = fights,
            watchFor        = watchFor,
            guid            = opp.guid or nil,
            name            = opp.name or nil,
            fieldConfidence = opp.fieldConfidence or {},
            confidence      = "prep",
        }

        enemies[#enemies + 1] = entry

        local displayRole = getDisplayRole(archetype)
        displayRoles[#displayRoles + 1] = displayRole

        if specId and specId > 0 then
            specIds[#specIds + 1] = specId
        end
    end

    local compArchetype = classifyCompArchetype(specIds)
    local compSummary   = buildCompSummary(displayRoles)
    local overallWR     = computeOverallWR(enemies)

    -- Look up the comp archetype label from seed data if available.
    local compLabel = nil
    local compData = ns.StaticPvpData and ns.StaticPvpData.COMP_ARCHETYPES or {}
    if compData.archetypes then
        for _, arch in ipairs(compData.archetypes) do
            if arch.id == compArchetype then
                compLabel = arch.label
                break
            end
        end
    end

    return {
        enemies       = enemies,
        compArchetype = compLabel or compArchetype,
        compSummary   = compSummary,
        overallWR     = overallWR,
        confidence    = "prep",
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- T084: BuildAdaptationCard
-- ──────────────────────────────────────────────────────────────────────────────

--- Analyse the player's death in the previous round from timeline events.
--- Searches for the death lane event and nearby CC/enemy spell events.
--- @param timelineEvents table  The session.timelineEvents array.
--- @return table|nil  {deathTime, lastCC, lastEnemySpell, summary}
local function analyseDeathCause(timelineEvents)
    if not timelineEvents or #timelineEvents == 0 then return nil end

    -- Find the player's death event (last one if multiple).
    local deathEvent = nil
    for i = #timelineEvents, 1, -1 do
        local ev = timelineEvents[i]
        if ev.lane == Constants.TIMELINE_LANE.DEATH then
            deathEvent = ev
            break
        end
    end
    if not deathEvent then return nil end

    local deathTime = deathEvent.t or 0
    local windowStart = deathTime - DEATH_CAUSE_WINDOW_SECONDS

    -- Collect CC and enemy spell events in the death window.
    local lastCC         = nil
    local lastEnemySpell = nil
    local ccCount        = 0
    local enemyDamageSum = 0

    for _, ev in ipairs(timelineEvents) do
        local t = ev.t or 0
        if t >= windowStart and t <= deathTime then
            if ev.lane == Constants.TIMELINE_LANE.CC_RECEIVED then
                ccCount = ccCount + 1
                if not lastCC or t > (lastCC.t or 0) then
                    lastCC = ev
                end
            end
            if ev.lane == Constants.TIMELINE_LANE.DM_ENEMY_SPELL then
                enemyDamageSum = enemyDamageSum + ApiCompat.SanitizeNumber(ev.amount)
                if not lastEnemySpell or t > (lastEnemySpell.t or 0) then
                    lastEnemySpell = ev
                end
            end
        end
    end

    local summary
    if ccCount > 0 and lastEnemySpell then
        summary = string.format("Died in CC chain (%d CCs) under enemy burst", ccCount)
    elseif ccCount > 0 then
        summary = string.format("Died during CC (%d CCs in window)", ccCount)
    elseif lastEnemySpell then
        summary = string.format("Died to enemy pressure (%.0f damage in %ds window)",
            enemyDamageSum, DEATH_CAUSE_WINDOW_SECONDS)
    else
        summary = "Death cause unclear from available data"
    end

    return {
        deathTime      = deathTime,
        lastCC         = lastCC,
        lastEnemySpell = lastEnemySpell,
        ccCount        = ccCount,
        enemyDamageSum = enemyDamageSum,
        summary        = summary,
    }
end

--- Identify which arena slot dealt the most pressure to the player.
--- @param arenaSlots table  session.arena.slots from the finalized session.
--- @return number|nil slotIndex, table|nil slotData
local function findHighestPressureSlot(arenaSlots)
    if not arenaSlots then return nil, nil end
    local bestSlot  = nil
    local bestData  = nil
    local bestScore = -1

    for slot, data in pairs(arenaSlots) do
        local pressure = data.pressureScore or 0
        if pressure > bestScore then
            bestScore = pressure
            bestSlot  = slot
            bestData  = data
        end
    end
    return bestSlot, bestData
end

--- Assess healer pressure level from session data.
--- Looks for a healer-role enemy slot and compares their damageToPlayer
--- against total enemy damageToPlayer.
--- @param arenaSlots table  session.arena.slots
--- @return string  "high", "medium", or "low"
local function assessHealerPressure(arenaSlots)
    if not arenaSlots then return "low" end

    local healerDamage = 0
    local totalDamage  = 0

    for _, data in pairs(arenaSlots) do
        local dmg = data.damageToPlayer or 0
        totalDamage = totalDamage + dmg
        -- Identify healer by prepRole or by looking up archetype.
        local role = data.prepRole
        if not role and data.prepSpecId then
            local arch = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(data.prepSpecId) or nil
            role = arch and arch.role or nil
        end
        if role == "HEALER" then
            healerDamage = healerDamage + dmg
        end
    end

    if totalDamage == 0 then return "low" end
    local ratio = healerDamage / totalDamage

    if ratio >= HEALER_PRESSURE_HIGH_THRESHOLD then
        return "high"
    elseif ratio >= HEALER_PRESSURE_MEDIUM_THRESHOLD then
        return "medium"
    end
    return "low"
end

--- Generate a one-line tactical suggestion from the adaptation analysis.
local function generateTacticalSuggestion(deathCause, highestPressureData, healerPressure)
    -- Priority: death cause first, then pressure patterns.
    if deathCause and deathCause.ccCount and deathCause.ccCount > 1 then
        return "Consider saving trinket for the kill-setup CC chain instead of the opener."
    end

    if deathCause and deathCause.lastEnemySpell and not deathCause.lastCC then
        return "Died to sustained pressure without CC setup — pre-use a defensive earlier."
    end

    if healerPressure == "high" then
        return "Enemy healer is contributing significant pressure — consider swapping to them."
    end

    if highestPressureData then
        local specId = highestPressureData.prepSpecId
        local archetype = specId and ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(specId) or nil
        if archetype and archetype.rangeBucket == "melee" then
            return "Primary threat is melee — kite during their offensive cooldowns."
        end
        if archetype and archetype.rangeBucket == "ranged" then
            return "Primary threat is ranged — use LoS and gap-close to reduce their free casting."
        end
    end

    return "Focus on trading defensives efficiently and creating counter-pressure windows."
end

--- Build a between-round adaptation card from the finalized previous round session.
--- @param previousRoundSession table  Finalized session from the previous Solo Shuffle round.
--- @param currentPrepState table  Current prep opponent data (unused for now, reserved for future enrichment).
--- @return table adaptationCard
function ArenaScoutService.BuildAdaptationCard(previousRoundSession, currentPrepState)
    if not previousRoundSession then
        return {
            deathCause         = nil,
            highestPressureSlot = nil,
            healerPressure     = "low",
            matchupReminder    = nil,
            suggestion         = "No data from previous round — play to your standard gameplan.",
        }
    end

    -- Analyse death cause from timeline events.
    local deathCause = analyseDeathCause(previousRoundSession.timelineEvents)

    -- Find highest pressure slot.
    local arenaSlots = previousRoundSession.arena and previousRoundSession.arena.slots or nil
    local pressureSlotIdx, pressureSlotData = findHighestPressureSlot(arenaSlots)

    -- Assess healer pressure.
    local healerPressure = assessHealerPressure(arenaSlots)

    -- Matchup reminder: pull historical stat for the most dangerous spec.
    local matchupReminder = nil
    if pressureSlotData and pressureSlotData.prepSpecId then
        local store = ns.Addon:GetModule("CombatStore")
        if store and store.GetAggregateBucketByKey then
            local bucket = store:GetAggregateBucketByKey("specs", pressureSlotData.prepSpecId)
            if bucket and (bucket.fights or 0) > 0 then
                local wr = (bucket.wins or 0) / bucket.fights
                local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(pressureSlotData.prepSpecId) or nil
                local specLabel = (archetype and archetype.specName) or "Unknown"
                matchupReminder = string.format(
                    "vs %s: %.0f%% WR over %d fights",
                    specLabel,
                    wr * 100,
                    bucket.fights
                )
            end
        end
    end

    -- Generate tactical suggestion.
    local suggestion = generateTacticalSuggestion(deathCause, pressureSlotData, healerPressure)

    return {
        deathCause          = deathCause and deathCause.summary or nil,
        deathCauseDetail    = deathCause,
        highestPressureSlot = pressureSlotIdx,
        healerPressure      = healerPressure,
        matchupReminder     = matchupReminder,
        suggestion          = suggestion,
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- T085: EnrichWithInspect
-- ──────────────────────────────────────────────────────────────────────────────

--- Merge inspect data into a scout card enemy entry.
--- @param scoutCard table  The scout card produced by BuildScoutCard.
--- @param slotIndex number  1-based index into scoutCard.enemies.
--- @param inspectData table  {pvpTalents, talentImportString} from ArenaRoundTracker.
function ArenaScoutService.EnrichWithInspect(scoutCard, slotIndex, inspectData)
    if not scoutCard or not scoutCard.enemies then return end
    if not slotIndex or not inspectData then return end

    local enemy = scoutCard.enemies[slotIndex]
    if not enemy then return end

    -- Merge PvP talents with resolved spell names.
    if inspectData.pvpTalents and #inspectData.pvpTalents > 0 then
        local resolved = {}
        for _, talentId in ipairs(inspectData.pvpTalents) do
            local name = nil
            if C_Spell and C_Spell.GetSpellName then
                local ok, spellName = pcall(C_Spell.GetSpellName, talentId)
                if ok and spellName then
                    name = spellName
                end
            end
            resolved[#resolved + 1] = {
                talentId = talentId,
                name     = name,
            }
        end
        enemy.pvpTalents = resolved
    end

    -- Merge talent import string.
    if inspectData.talentImportString then
        enemy.talentImportString = inspectData.talentImportString
    end

    -- Upgrade confidence to "inspect".
    enemy.confidence = "inspect"

    -- Propagate to card-level confidence if all enemies are now at "inspect".
    local allInspect = true
    for _, e in ipairs(scoutCard.enemies) do
        if e.confidence ~= "inspect" then
            allInspect = false
            break
        end
    end
    if allInspect then
        scoutCard.confidence = "inspect"
    end

    ns.Addon:Trace("arena_scout.enrich_inspect", {
        slot       = slotIndex,
        specId     = enemy.specId or 0,
        pvpCount   = enemy.pvpTalents and #enemy.pvpTalents or 0,
        hasBuild   = enemy.talentImportString and "true" or "false",
    })
end

-- ──────────────────────────────────────────────────────────────────────────────
-- T090: No-data helpers
-- ──────────────────────────────────────────────────────────────────────────────

--- Check whether a scout card enemy entry has historical data.
--- Returns true if the enemy has at least one recorded fight.
function ArenaScoutService.HasHistoricalData(enemy)
    if not enemy then return false end
    return (enemy.historicalFights or 0) > 0
end

--- Produce a display-safe summary for an enemy entry.
--- Returns a formatted string suitable for UI display.
function ArenaScoutService.FormatEnemySummary(enemy)
    if not enemy then return "Unknown opponent" end

    local parts = {}
    parts[#parts + 1] = enemy.specName or "Unknown Spec"

    if enemy.historicalFights and enemy.historicalFights > 0 and enemy.historicalWR then
        parts[#parts + 1] = string.format("%.0f%% WR (%d fights)",
            enemy.historicalWR * 100, enemy.historicalFights)
    else
        parts[#parts + 1] = "no prior data"
    end

    if enemy.archetype then
        parts[#parts + 1] = enemy.archetype
    end

    return table.concat(parts, " | ")
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
ns.Addon:RegisterModule("ArenaScoutService", ArenaScoutService)
