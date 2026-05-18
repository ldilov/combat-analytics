local _, ns = ...

local DeathAnalyzer = {}

-- Major defensive cooldowns to check (from SeedSpellIntelligence or hardcoded)
local MAJOR_DEFENSIVES = {
    -- Death Knight
    [48707] = { name = "Anti-Magic Shell", cd = 60 },
    [48792] = { name = "Icebound Fortitude", cd = 120 },
    -- Demon Hunter
    [198589] = { name = "Blur", cd = 60 },
    [196555] = { name = "Netherwalk", cd = 180 },
    -- Druid
    [22812] = { name = "Barkskin", cd = 60 },
    [61336] = { name = "Survival Instincts", cd = 180 },
    -- Hunter
    [186265] = { name = "Aspect of the Turtle", cd = 180 },
    [109304] = { name = "Exhilaration", cd = 120 },
    -- Mage
    [45438] = { name = "Ice Block", cd = 240 },
    [55342] = { name = "Mirror Image", cd = 120 },
    -- Monk
    [122278] = { name = "Dampen Harm", cd = 120 },
    [122783] = { name = "Diffuse Magic", cd = 90 },
    [243435] = { name = "Fortifying Brew", cd = 180 },
    -- Paladin
    [642] = { name = "Divine Shield", cd = 300 },
    [498] = { name = "Divine Protection", cd = 60 },
    -- Priest
    [47585] = { name = "Dispersion", cd = 120 },
    [19236] = { name = "Desperate Prayer", cd = 90 },
    -- Rogue
    [31224] = { name = "Cloak of Shadows", cd = 120 },
    [1856] = { name = "Vanish", cd = 120 },
    [5277] = { name = "Evasion", cd = 120 },
    -- Shaman
    [108271] = { name = "Astral Shift", cd = 90 },
    -- Warlock
    [104773] = { name = "Unending Resolve", cd = 180 },
    -- Warrior
    [184364] = { name = "Enraged Regeneration", cd = 120 },
    [118038] = { name = "Die by the Sword", cd = 120 },
    [12975] = { name = "Last Stand", cd = 180 },
    -- Evoker
    [363916] = { name = "Obsidian Scales", cd = 150 },
}

-- Check if a spell is a major defensive, using new API with hardcoded fallback.
local function isMajorDefensive(spellId)
    -- Try new API first
    if ns.ApiCompat and ns.ApiCompat.AuraIsBigDefensive then
        local result = ns.ApiCompat.AuraIsBigDefensive(spellId)
        if result then return true end
    end
    -- Fallback to hardcoded table
    return MAJOR_DEFENSIVES[spellId] ~= nil
end

-- Filter MAJOR_DEFENSIVES to only those matching the player's class
local CLASS_DEFENSIVES = {
    DEATHKNIGHT = { [48707] = true, [48792] = true },
    DEMONHUNTER = { [198589] = true, [196555] = true },
    DRUID = { [22812] = true, [61336] = true },
    HUNTER = { [186265] = true, [109304] = true },
    MAGE = { [45438] = true, [55342] = true },
    MONK = { [122278] = true, [122783] = true, [243435] = true },
    PALADIN = { [642] = true, [498] = true },
    PRIEST = { [47585] = true, [19236] = true },
    ROGUE = { [31224] = true, [1856] = true, [5277] = true },
    SHAMAN = { [108271] = true },
    WARLOCK = { [104773] = true },
    WARRIOR = { [184364] = true, [118038] = true, [12975] = true },
    EVOKER = { [363916] = true },
}

function DeathAnalyzer:FilterByClass(defNames, classFile)
    local classSpells = CLASS_DEFENSIVES[classFile]
    if not classSpells then return defNames end
    local filtered = {}
    for _, name in ipairs(defNames) do
        for spellId, info in pairs(MAJOR_DEFENSIVES) do
            if info.name == name and classSpells[spellId] then
                filtered[#filtered + 1] = name
                break
            end
        end
    end
    return filtered
end

function DeathAnalyzer:AnalyzeDeaths(session)
    local suggestions = {}
    if not session or not session.rawEvents then return suggestions end

    -- Player events are identified by sourceMine/destMine (the codebase-wide
    -- convention). Raw GUIDs are secret in instanced PvP, so a UnitGUID("player")
    -- comparison would never match on the primary arena/BG path.
    local cooldownUsages = {}  -- spellId -> sorted list of use offsets

    -- First pass: build per-spell cooldown usage timeline. rawEvents are
    -- chronological, so appended offsets are already sorted ascending.
    -- Casts arrive as subEvent "UNIT_SPELLCAST_SUCCEEDED" (instanced PvP,
    -- primary) or "SPELL_CAST_SUCCESS" (CLEU path, when available).
    for _, event in ipairs(session.rawEvents) do
        if event.eventType == "cast"
            and event.sourceMine
            and (event.subEvent == "UNIT_SPELLCAST_SUCCEEDED"
                 or event.subEvent == "SPELL_CAST_SUCCESS")
        then
            local spellId = event.spellId
            if spellId and isMajorDefensive(spellId) then
                local uses = cooldownUsages[spellId]
                if not uses then
                    uses = {}
                    cooldownUsages[spellId] = uses
                end
                uses[#uses + 1] = event.timestampOffset or 0
            end
        end
    end

    -- Second pass: find player death events and check available defensives.
    for _, event in ipairs(session.rawEvents) do
        if event.eventType == "death"
            and event.subEvent == "UNIT_DIED"
            and event.destMine
        then
            local deathTime = event.timestampOffset or 0
            local availableDefensives = {}

            for spellId, info in pairs(MAJOR_DEFENSIVES) do
                -- Find the most recent use at or before this death; earlier
                -- uses are irrelevant once a later one resets the cooldown.
                local lastUsedBeforeDeath
                local uses = cooldownUsages[spellId]
                if uses then
                    for i = 1, #uses do
                        local u = uses[i]
                        if u <= deathTime then
                            lastUsedBeforeDeath = u
                        else
                            break
                        end
                    end
                end
                if not lastUsedBeforeDeath then
                    -- Never used before this death = was available
                    availableDefensives[#availableDefensives + 1] = info.name
                elseif (deathTime - lastUsedBeforeDeath) >= info.cd then
                    -- Used but was off cooldown by death time
                    availableDefensives[#availableDefensives + 1] = info.name
                end
            end

            -- Filter to only defensives the player's class actually has.
            -- When the class is unknown we cannot tell which of the 19
            -- cross-class defensives the player actually had, so suppress the
            -- suggestion entirely rather than emit nonsense (e.g. telling a
            -- Warrior they should have used Ice Block).
            local classFile = session.playerSnapshot and session.playerSnapshot.classFile
            if classFile then
                availableDefensives = self:FilterByClass(availableDefensives, classFile)
            else
                availableDefensives = {}
            end

            if #availableDefensives > 0 then
                local defList = table.concat(availableDefensives, ", ")
                suggestions[#suggestions + 1] = {
                    reasonCode = "DIED_WITH_DEFENSIVES",
                    severity = "high",
                    confidence = 0.9,
                    controllability = "resource_available",
                    effort = 1,
                    message = string.format("Died with defensive(s) available: %s", defList),
                    evidence = {
                        deathTime = deathTime,
                        availableDefensives = availableDefensives,
                    },
                }
            end
        end
    end

    return suggestions
end

ns.Addon:RegisterModule("DeathAnalyzer", DeathAnalyzer)
