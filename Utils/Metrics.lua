local _, ns = ...

local Constants = ns.Constants
local ApiCompat = ns.ApiCompat
local Helpers = ns.Helpers
local MathUtil = ns.Math

local Metrics = {}

local function gatherDamageEvents(session, predicate)
    local events = {}
    for _, eventRecord in ipairs(session.rawEvents or {}) do
        if (eventRecord.amount or 0) > 0 and predicate(eventRecord) then
            events[#events + 1] = eventRecord
        end
    end
    return events
end

local function hasRawTimeline(session)
    return #(session.rawEvents or {}) > 0
end

local function summarizeWindow(session, windowType, startOffset, endOffset)
    local summary = {
        windowType = windowType,
        startTimeOffset = Helpers.Round(startOffset, 3),
        endTimeOffset = Helpers.Round(endOffset, 3),
        duration = Helpers.Round(math.max(0, endOffset - startOffset), 3),
        damageDone = 0,
        healingDone = 0,
        damageTaken = 0,
        spellIds = {},
        auraIds = {},
        cooldownSpellIds = {},
        eventCount = 0,
    }

    for _, eventRecord in ipairs(session.rawEvents or {}) do
        local offset = eventRecord.timestampOffset or 0
        if offset >= startOffset and offset <= endOffset then
            summary.eventCount = summary.eventCount + 1
            if eventRecord.spellId then
                summary.spellIds[eventRecord.spellId] = true
            end
            if eventRecord.auraId then
                summary.auraIds[eventRecord.auraId] = true
            end
            if eventRecord.isCooldownCast and eventRecord.spellId then
                summary.cooldownSpellIds[eventRecord.spellId] = true
            end
            if eventRecord.eventType == "damage" then
                if eventRecord.sourceMine then
                    summary.damageDone = summary.damageDone + (eventRecord.amount or 0)
                elseif eventRecord.destMine then
                    summary.damageTaken = summary.damageTaken + (eventRecord.amount or 0)
                end
            elseif eventRecord.eventType == "healing" and eventRecord.sourceMine then
                summary.healingDone = summary.healingDone + (eventRecord.amount or 0)
            end
        end
    end

    return summary
end

local function findBurstWindow(session)
    local damageEvents = gatherDamageEvents(session, function(eventRecord)
        return eventRecord.eventType == "damage" and eventRecord.sourceMine
    end)
    if #damageEvents == 0 then
        return nil
    end

    local bestStart = damageEvents[1].timestampOffset or 0
    local bestEnd = bestStart
    local bestDamage = damageEvents[1].amount or 0

    local left = 1
    local windowDamage = 0
    for right = 1, #damageEvents do
        local current = damageEvents[right]
        windowDamage = windowDamage + (current.amount or 0)
        local currentStart = damageEvents[left].timestampOffset or 0
        local currentEnd = current.timestampOffset or 0

        while (currentEnd - currentStart) > Constants.WINDOW_BURST_MAX_SECONDS and left < right do
            windowDamage = windowDamage - (damageEvents[left].amount or 0)
            left = left + 1
            currentStart = damageEvents[left].timestampOffset or 0
        end

        if (currentEnd - currentStart) >= Constants.WINDOW_BURST_MIN_SECONDS and windowDamage > bestDamage then
            bestDamage = windowDamage
            bestStart = currentStart
            bestEnd = currentEnd
        end
    end

    if session.totals.damageDone <= 0 then
        return nil
    end
    if (bestDamage / session.totals.damageDone) < Constants.WINDOW_BURST_MIN_DAMAGE_SHARE then
        return nil
    end

    return summarizeWindow(session, Constants.WINDOW_TYPE.BURST, bestStart, bestEnd)
end

local function findDefensiveWindow(session)
    local firstDefensive = nil
    for _, cooldown in pairs(session.cooldowns or {}) do
        if cooldown.category == Constants.SPELL_CATEGORY.DEFENSIVE and cooldown.firstUsedAt then
            if not firstDefensive or cooldown.firstUsedAt < firstDefensive then
                firstDefensive = cooldown.firstUsedAt
            end
        end
    end
    if not firstDefensive then
        return nil
    end
    return summarizeWindow(session, Constants.WINDOW_TYPE.DEFENSIVE, math.max(0, firstDefensive - 1.5), firstDefensive + 4)
end

local function findKillAttemptWindow(session)
    local burstWindow = nil
    for _, windowRecord in ipairs(session.windows or {}) do
        if windowRecord.windowType == Constants.WINDOW_TYPE.BURST then
            burstWindow = windowRecord
            break
        end
    end

    local endOffset = burstWindow and burstWindow.endTimeOffset or math.min(session.duration or 0, Constants.WINDOW_OPENERS_SECONDS)
    return summarizeWindow(session, Constants.WINDOW_TYPE.KILL_ATTEMPT, math.max(0, endOffset - 4), math.min(session.duration or 0, endOffset + 2))
end

local function findRecoveryWindow(session)
    local biggestSpikeAt = nil
    local biggestSpike = 0
    for _, eventRecord in ipairs(session.rawEvents or {}) do
        if eventRecord.eventType == "damage" and eventRecord.destMine and (eventRecord.amount or 0) > biggestSpike then
            biggestSpike = eventRecord.amount or 0
            biggestSpikeAt = eventRecord.timestampOffset or 0
        end
    end
    if not biggestSpikeAt then
        return nil
    end
    return summarizeWindow(session, Constants.WINDOW_TYPE.RECOVERY, biggestSpikeAt, math.min(session.duration or 0, biggestSpikeAt + Constants.WINDOW_RECOVERY_SECONDS))
end

local function computeRotationalConsistency(session)
    local intervals = {}
    for _, aggregate in pairs(session.spells or {}) do
        if aggregate.averageInterval and aggregate.averageInterval > 0 and aggregate.castCount and aggregate.castCount > 1 then
            intervals[#intervals + 1] = aggregate.averageInterval
        end
    end

    if #intervals <= 1 then
        return 0
    end

    local average = MathUtil.Average(intervals)
    local deviation = MathUtil.StandardDeviation(intervals)
    if average <= 0 then
        return 0
    end
    return Helpers.Clamp(100 - ((deviation / average) * 100), 0, 100)
end

local function computeProcConversion(session)
    local procCount = 0
    local procValue = 0
    local procCasts = 0
    for _, aura in pairs(session.auras or {}) do
        if aura.isProc then
            procCount = procCount + (aura.procCount or 0)
            procValue = procValue + (aura.damageDuringWindows or 0) + (aura.healingDuringWindows or 0)
            procCasts = procCasts + (aura.castsDuringWindows or 0)
        end
    end
    if procCount <= 0 then
        return 0, 0, 0
    end
    if procValue > 0 then
        return procValue / procCount, procCount, procCasts
    end
    return Helpers.Clamp((procCasts / procCount) * 25, 0, 100), procCount, procCasts
end

local function computeTopOutputShare(session)
    local topAmount = 0
    local totalAmount = math.max((session.totals.damageDone or 0) + (session.totals.healingDone or 0), 1)

    for _, aggregate in pairs(session.spells or {}) do
        local amount = (aggregate.totalDamage or 0) + (aggregate.totalHealing or 0)
        if amount > topAmount then
            topAmount = amount
        end
    end

    return topAmount / totalAmount
end

local function isMajorOffensiveSpell(spellId)
    local taxonomy = ns.StaticPvpData and ns.StaticPvpData.SPELL_TAXONOMY or nil
    return taxonomy and taxonomy.majorOffensive and taxonomy.majorOffensive[spellId] or false
end

local function isMajorDefensiveSpell(spellId)
    local taxonomy = ns.StaticPvpData and ns.StaticPvpData.SPELL_TAXONOMY or nil
    if taxonomy and taxonomy.majorDefensive and taxonomy.majorDefensive[spellId] then
        return true
    end
    return ApiCompat.AuraIsBigDefensive and ApiCompat.AuraIsBigDefensive(spellId) or false
end

local function findFirstCooldownAt(session, predicate)
    local earliest = nil
    for spellId, cooldown in pairs(session.cooldowns or {}) do
        if cooldown.firstUsedAt and predicate(spellId, cooldown) then
            earliest = earliest and math.min(earliest, cooldown.firstUsedAt) or cooldown.firstUsedAt
        end
    end
    return earliest
end

local function countCooldownUses(session, predicate)
    local total = 0
    for spellId, cooldown in pairs(session.cooldowns or {}) do
        if predicate(spellId, cooldown) then
            total = total + (cooldown.useCount or 0)
        end
    end
    return total
end

-- findCombatEngagementOffset: returns the timestampOffset of the first hostile
-- PvP combat event in the session.
--
-- WHY THIS EXISTS: In arenas the CLEU starts recording during the prep phase
-- (self-buffs, racials, food) before the gate opens. The gate can open 60-90s
-- after session start. Anchoring the opener window at timestampOffset=0 would
-- capture exclusively prep-phase activity and miss the actual opener entirely.
-- Non-PvP sessions (training dummy, BG) have no prep phase, so this returns 0
-- and the window behaves identically to the old code.
local function findCombatEngagementOffset(session)
    for _, ev in ipairs(session.rawEvents or {}) do
        local t = ev.eventType
        if t == "cast" or t == "damage" or t == "miss" then
            -- Player initiates on a hostile player (opener cast or first hit).
            if ev.sourceMine and ev.destHostilePlayer then
                return ev.timestampOffset or 0
            end
            -- Hostile player hits the player (reactive engagement anchor).
            if ev.destMine and ev.sourceHostilePlayer then
                return ev.timestampOffset or 0
            end
        end
    end
    return 0
end

-- countOpenerCasts: count SPELL_CAST_SUCCESS events by the player inside the
-- opener window [openerStart, openerEnd]. Intentionally excludes SPELL_CAST_START
-- (cast begin, not completion) and SPELL_CAST_FAILED to avoid double-counting
-- cast-time spells and inflating the count with misses.
local function countOpenerCasts(session, openerStart, openerEnd)
    local count = 0
    for _, eventRecord in ipairs(session.rawEvents or {}) do
        local offset = eventRecord.timestampOffset or 0
        if eventRecord.sourceMine
            and eventRecord.subEvent == "SPELL_CAST_SUCCESS"
            and offset >= openerStart
            and offset <= openerEnd
        then
            count = count + 1
        end
    end
    return count
end

-- collectOpenerSpellIds: returns opener spells in chronological cast order
-- (first SPELL_CAST_SUCCESS per spellId, sorted by cast time).
--
-- WHY CHRONOLOGICAL: The opener sequence matters for PvP coaching. "Cheap Shot
-- → Garrote → Kidney Shot" is meaningfully different from the reverse. The old
-- damage-score ranking destroyed sequence information and biased toward damage
-- dealers, missing setup/CC spells that define the opener pattern.
local function collectOpenerSpellIds(session, openerStart, openerEnd, limit)
    local firstSeenAt = {}
    for _, eventRecord in ipairs(session.rawEvents or {}) do
        local offset = eventRecord.timestampOffset or 0
        if eventRecord.sourceMine
            and eventRecord.subEvent == "SPELL_CAST_SUCCESS"
            and offset >= openerStart
            and offset <= openerEnd
            and eventRecord.spellId
            and not firstSeenAt[eventRecord.spellId]
        then
            firstSeenAt[eventRecord.spellId] = offset
        end
    end

    local ordered = {}
    for spellId, offset in pairs(firstSeenAt) do
        ordered[#ordered + 1] = { spellId = spellId, offset = offset }
    end
    table.sort(ordered, function(a, b)
        if a.offset == b.offset then return a.spellId < b.spellId end
        return a.offset < b.offset
    end)

    local result = {}
    for i = 1, math.min(limit or 5, #ordered) do
        result[i] = ordered[i].spellId
    end
    return result
end

-- collectOpenerCooldownSpellIds: cooldowns first used within [openerStart, openerEnd].
-- openerStart filter prevents prep-phase cooldown uses (racials, trinkets popped
-- before the gate opens) from being reported as opener cooldowns.
local function collectOpenerCooldownSpellIds(session, openerStart, openerEnd, limit)
    local ranked = {}
    for spellId, cooldown in pairs(session.cooldowns or {}) do
        local firstUse = cooldown.firstUsedAt
        if firstUse and firstUse >= openerStart and firstUse <= openerEnd then
            ranked[#ranked + 1] = { spellId = spellId, firstUsedAt = firstUse }
        end
    end
    table.sort(ranked, function(left, right)
        if (left.firstUsedAt or 0) == (right.firstUsedAt or 0) then
            return (left.spellId or 0) < (right.spellId or 0)
        end
        return (left.firstUsedAt or 0) < (right.firstUsedAt or 0)
    end)

    local result = {}
    for index = 1, math.min(limit or 3, #ranked) do
        result[#result + 1] = ranked[index].spellId
    end
    return result
end

function Metrics.DeriveWindows(session)
    if not hasRawTimeline(session) then
        session.windows = {}
        return session.windows
    end

    local windows = {}
    local engagementAt = findCombatEngagementOffset(session)
    local openerEnd = math.min(session.duration or 0, engagementAt + Constants.WINDOW_OPENERS_SECONDS)
    windows[#windows + 1] = summarizeWindow(session, Constants.WINDOW_TYPE.OPENER, engagementAt, openerEnd)

    local burstWindow = findBurstWindow(session)
    if burstWindow then
        windows[#windows + 1] = burstWindow
    end

    local defensiveWindow = findDefensiveWindow(session)
    if defensiveWindow then
        windows[#windows + 1] = defensiveWindow
    end

    windows[#windows + 1] = findKillAttemptWindow(session)

    local recoveryWindow = findRecoveryWindow(session)
    if recoveryWindow then
        windows[#windows + 1] = recoveryWindow
    end

    session.windows = windows
    return windows
end

function Metrics.ComputeDerivedMetrics(session)
    local duration = math.max(session.duration or 0, 1)
    local outgoing = session.totals.damageDone or 0
    local incoming = session.totals.damageTaken or 0
    local healing = session.totals.healingDone or 0
    local burstDamage = 0
    local openerDamage = 0

    for _, windowRecord in ipairs(session.windows or {}) do
        if windowRecord.windowType == Constants.WINDOW_TYPE.BURST then
            burstDamage = math.max(burstDamage, windowRecord.damageDone or 0)
        elseif windowRecord.windowType == Constants.WINDOW_TYPE.OPENER then
            openerDamage = windowRecord.damageDone or 0
        end
    end

    local sustainedDps = outgoing / duration
    local sustainedHps = healing / duration
    local burstDps = burstDamage > 0 and (burstDamage / math.max(Constants.WINDOW_BURST_MIN_SECONDS, 1)) or 0
    local limitedTimeline = not hasRawTimeline(session)
    local procConversionScore, procWindowsObserved, procWindowCastCount = computeProcConversion(session)
    local topOutputShare = computeTopOutputShare(session)
    -- Anchor all opener calculations to the first hostile combat event.
    -- For arenas this skips the prep phase; for duels/dummy sessions it is 0.
    local engagementAt = findCombatEngagementOffset(session)
    local openerEnd = math.min(session.duration or 0, engagementAt + Constants.WINDOW_OPENERS_SECONDS)
    local openerCastCount = countOpenerCasts(session, engagementAt, openerEnd)
    local openerSpellIds = collectOpenerSpellIds(session, engagementAt, openerEnd, 5)
    local openerCooldownSpellIds = collectOpenerCooldownSpellIds(session, engagementAt, openerEnd, 3)
    local firstMajorOffensiveAt = findFirstCooldownAt(session, function(spellId)
        return isMajorOffensiveSpell(spellId)
    end)
    local firstMajorDefensiveAt = findFirstCooldownAt(session, function(spellId)
        return isMajorDefensiveSpell(spellId)
    end)
    -- Engagement-relative versions: "seconds after gate open / first hit".
    -- These are what the user sees in the UI. The absolute values are preserved
    -- for backward-compatible baseline comparisons in CombatStore aggregates.
    local firstMajorOffensiveRelative = firstMajorOffensiveAt
        and Helpers.Round(math.max(0, firstMajorOffensiveAt - engagementAt), 2) or nil
    local firstMajorDefensiveRelative = firstMajorDefensiveAt
        and Helpers.Round(math.max(0, firstMajorDefensiveAt - engagementAt), 2) or nil
    local majorOffensiveCount = countCooldownUses(session, function(spellId)
        return isMajorOffensiveSpell(spellId)
    end)
    local majorDefensiveCount = countCooldownUses(session, function(spellId)
        return isMajorDefensiveSpell(spellId)
    end)
    local sustainedBurstProxy = Helpers.Clamp((sustainedDps / 1500) * 20, 0, 20)
    local concentrationProxy = Helpers.Clamp(topOutputShare * 60, 0, 60)
    local procBurstProxy = Helpers.Clamp((procWindowsObserved or 0) * 8 + (procWindowCastCount or 0) * 4, 0, 20)

    local pressureScore = limitedTimeline and Helpers.Clamp((sustainedDps / 100), 0, 100) or Helpers.Clamp(((sustainedDps * 0.6) + (burstDps * 0.4)) / 100, 0, 100)
    local burstScore = limitedTimeline and Helpers.Clamp(concentrationProxy + sustainedBurstProxy + procBurstProxy, 0, 100) or Helpers.Clamp((burstDamage / math.max(outgoing, 1)) * 100, 0, 100)
    local survivabilityScore = Helpers.Clamp(((healing + 1) / math.max(incoming, 1)) * 65 + ((session.survival.defensivesUsed or 0) * 5), 0, 100)
    local utilityEfficiency = Helpers.Clamp(((session.utility.successfulInterrupts or 0) * 12) + ((session.utility.dispels or 0) * 4) + ((session.utility.ccApplied or 0) * 2), 0, 100)

    session.metrics = {
        sustainedDps = Helpers.Round(sustainedDps, 2),
        sustainedHps = Helpers.Round(sustainedHps, 2),
        burstDps = Helpers.Round(limitedTimeline and math.max(sustainedDps, outgoing * topOutputShare) or burstDps, 2),
        openerDamage = openerDamage,
        idleSeconds = Helpers.Round(session.idleTime or 0, 2),
        pressureScore = Helpers.Round(pressureScore, 2),
        sustainedPressureScore = Helpers.Round(Helpers.Clamp((sustainedDps / 100), 0, 100), 2),
        burstScore = Helpers.Round(burstScore, 2),
        survivabilityScore = Helpers.Round(survivabilityScore, 2),
        rotationalConsistencyScore = Helpers.Round(computeRotationalConsistency(session), 2),
        utilityEfficiencyScore = Helpers.Round(utilityEfficiency, 2),
        procConversionScore = Helpers.Round(procConversionScore, 2),
        procWindowsObserved = procWindowsObserved or 0,
        procWindowCastCount = procWindowCastCount or 0,
        openerCastCount = openerCastCount,
        firstMajorOffensiveAt = firstMajorOffensiveAt and Helpers.Round(firstMajorOffensiveAt, 2) or nil,
        firstMajorDefensiveAt = firstMajorDefensiveAt and Helpers.Round(firstMajorDefensiveAt, 2) or nil,
        majorOffensiveCount = majorOffensiveCount,
        majorDefensiveCount = majorDefensiveCount,
        limitedBySource = limitedTimeline,
    }

    session.openerFingerprint = {
        -- engagementAt: timestampOffset of the first hostile combat event.
        -- 0 for non-arena sessions (training dummy, duels with no prep).
        engagementAt = Helpers.Round(engagementAt, 3),
        openerCastCount = openerCastCount,
        openerSpellIds = openerSpellIds,
        openerCooldownSpellIds = openerCooldownSpellIds,
        -- Absolute timestampOffset values — kept for CombatStore baseline compat.
        firstMajorOffensiveAt = firstMajorOffensiveAt and Helpers.Round(firstMajorOffensiveAt, 2) or nil,
        firstMajorDefensiveAt = firstMajorDefensiveAt and Helpers.Round(firstMajorDefensiveAt, 2) or nil,
        -- Engagement-relative values — used for display ("Xseconds after gate open").
        firstMajorOffensiveRelative = firstMajorOffensiveRelative,
        firstMajorDefensiveRelative = firstMajorDefensiveRelative,
    }

    return session.metrics
end

ns.Metrics = Metrics
