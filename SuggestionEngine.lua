local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local SuggestionEngine = {}

local function addSuggestion(results, suggestion)
    results[#results + 1] = suggestion
end

-- T038: suggestionConf is an optional attribution confidence string indicating
-- how trustworthy the source events for this suggestion are.
--   "confirmed"      — based on realtime observed events
--   "inferred"       — partially inferred / mixed sources
--   "summary_derived"— derived solely from DM post-match aggregates
--   "unknown"        — source confidence could not be determined
-- Suggestions with "summary_derived" or "unknown" should be displayed with a
-- lower weight or a visual caveat in the UI.
local function buildSuggestion(session, reasonCode, severity, confidence, evidence, comparisonKey, message, suggestionConf)
    return {
        sessionId          = session.id,
        reasonCode         = reasonCode,
        severity           = severity,
        confidence         = Helpers.Round(confidence, 2),
        evidence           = evidence,
        comparisonKey      = comparisonKey,
        message            = message,
        -- T038: Attribution-tier confidence for the source data behind this suggestion.
        suggestionConfidence = suggestionConf or "observed",
    }
end

-- T038: Derive minimum event confidence across a list of timeline events.
-- Returns "confirmed" > "inferred" > "summary_derived" > "unknown" in descending order.
local CONFIDENCE_TIER = {
    confirmed      = 1,
    owner_confirmed = 2,
    slot_confirmed = 3,
    inferred       = 4,
    summary_derived = 5,
    unknown        = 6,
    observed_active = 4,  -- treat as inferred
}
local CONFIDENCE_TIER_NAME = { [1]="confirmed", [2]="owner_confirmed", [3]="slot_confirmed", [4]="inferred", [5]="summary_derived", [6]="unknown" }

local function minEventConfidence(events)
    local worst = 1  -- start at "confirmed", worsen as we scan
    for _, ev in ipairs(events) do
        local tier = CONFIDENCE_TIER[ev.confidence] or 6
        if tier > worst then worst = tier end
    end
    return CONFIDENCE_TIER_NAME[worst] or "unknown"
end

local function getSuccessfulCastCount(session)
    local total = 0
    for _, spell in pairs(session.spells or {}) do
        total = total + (spell.castCount or 0)
    end
    return total
end

function SuggestionEngine:BuildSessionSuggestions(session)
    local store = ns.Addon:GetModule("CombatStore")
    local results = {}
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    local characterKey = store:GetSessionCharacterKey(session)
    local contextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
    local opponent = session.primaryOpponent or {}
    -- T022: Enrich opponent identity from UnitGraphService canonical node.
    -- Falls back to session.primaryOpponent when node is absent (historical sessions).
    do
        local ugs = ns.Addon:GetModule("UnitGraphService")
        if ugs and opponent.guid then
            local node = ugs:GetNode(opponent.guid)
            if node then
                opponent = {
                    guid           = opponent.guid,
                    name           = node.name           or opponent.name,
                    className      = node.className      or opponent.className,
                    classFile      = node.classFile      or opponent.classFile,
                    classId        = node.classId        or opponent.classId,
                    specId         = node.specId         or opponent.specId,
                    specName       = node.specName       or opponent.specName,
                    preferredToken = node.preferredToken,
                }
            end
        end
    end
    local hasRawTimeline = #(session.rawEvents or {}) > 0
    local successfulCastCount = getSuccessfulCastCount(session)
    local matchupBaseline = nil
    if opponent.guid or opponent.name then
        matchupBaseline = store:GetSessionBaseline(buildHash, contextKey, opponent.guid or opponent.name, nil, characterKey)
    end

    -- Defensive aliases: session.metrics / session.survival may be nil on old
    -- saved sessions (pre-v4) or if metrics computation was skipped due to an
    -- error.  Using local tables means every field access below is nil-safe
    -- without cluttering every individual comparison with guard chains.
    local m        = session.metrics  or {}
    local survival = session.survival or {}

    -- T020: Coverage-gated suggestion suppression.
    -- Lane scores computed by CoverageService.Finalize(); absent before schema v6.
    -- Suggestions requiring reliable cast / aura / identity data are suppressed
    -- when the corresponding lane score is below threshold to avoid misleading
    -- coaching based on incomplete observation.
    local cov = session.coverage or {}
    local CAST_COV_THRESHOLD     = 0.4
    local AURA_COV_THRESHOLD     = 0.4
    local IDENTITY_COV_THRESHOLD = 0.6

    local hasCastCoverage     = (cov.visibleCasts and cov.visibleCasts.score     or 0) >= CAST_COV_THRESHOLD
    local hasCCCoverage       = (cov.ccReceived   and cov.ccReceived.score       or 0) >= AURA_COV_THRESHOLD
    local hasIdentityCoverage = (cov.identity     and cov.identity.score         or 0) >= IDENTITY_COV_THRESHOLD

    local buildBaseline = store:GetBuildBaseline(buildHash, contextKey, nil, characterKey)
    if buildBaseline and buildBaseline.fights >= 5 and m.pressureScore and m.pressureScore < (buildBaseline.averagePressureScore * 0.8) then
        addSuggestion(results, buildSuggestion(
            session,
            "LOW_PRESSURE_VS_BUILD_BASELINE",
            "medium",
            0.78,
            { samples = buildBaseline.fights, current = m.pressureScore, baseline = buildBaseline.averagePressureScore },
            buildHash,
            "Pressure score landed below your normal build baseline."
        ))
    end

    if hasCastCoverage and successfulCastCount >= 6 and (m.rotationalConsistencyScore or 0) > 0 and m.rotationalConsistencyScore < 45 then
        addSuggestion(results, buildSuggestion(
            session,
            "ROTATION_GAPS_OBSERVED",
            "medium",
            0.73,
            {
                casts = successfulCastCount,
                idleSeconds = m.idleSeconds or 0,
                rotationScore = m.rotationalConsistencyScore or 0,
            },
            "rotation",
            "Successful casts showed noticeable gaps, which points to lost uptime in the rotation."
        ))
    end

    if hasCastCoverage and matchupBaseline and matchupBaseline.fights >= 5 then
        local openerFingerprint = session.openerFingerprint or {}
        if openerFingerprint.firstMajorOffensiveAt
            and matchupBaseline.averageFirstMajorOffensiveAt
            and openerFingerprint.firstMajorOffensiveAt > (matchupBaseline.averageFirstMajorOffensiveAt + 1.0)
        then
            addSuggestion(results, buildSuggestion(
                session,
                "LATE_FIRST_GO",
                "medium",
                0.74,
                {
                    samples = matchupBaseline.fights,
                    current = openerFingerprint.firstMajorOffensiveAt,
                    baseline = matchupBaseline.averageFirstMajorOffensiveAt,
                },
                contextKey,
                "Major offensive cooldowns came online later than your usual timing for this build and matchup."
            ))
        end

        if openerFingerprint.firstMajorDefensiveAt
            and matchupBaseline.averageFirstMajorDefensiveAt
            and openerFingerprint.firstMajorDefensiveAt > (matchupBaseline.averageFirstMajorDefensiveAt + 1.0)
            and ((session.totals and session.totals.damageTaken) or 0) > (matchupBaseline.averageDamageTaken or 0)
        then
            addSuggestion(results, buildSuggestion(
                session,
                "DEFENSIVE_DRIFT",
                "medium",
                0.71,
                {
                    samples = matchupBaseline.fights,
                    current = openerFingerprint.firstMajorDefensiveAt,
                    baseline = matchupBaseline.averageFirstMajorDefensiveAt,
                    damageTaken = (session.totals and session.totals.damageTaken) or 0,
                },
                contextKey,
                "Defensive timing drifted later than your stronger historical pacing for this matchup."
            ))
        end
    end

    if hasCastCoverage and (m.procWindowsObserved or 0) >= 3 and (m.procWindowCastCount or 0) < math.max(2, m.procWindowsObserved) then
        addSuggestion(results, buildSuggestion(
            session,
            "PROC_WINDOWS_UNDERUSED",
            "medium",
            0.67,
            {
                procWindows = m.procWindowsObserved or 0,
                castsDuringWindows = m.procWindowCastCount or 0,
            },
            "proc_windows",
            "Several proc-like buff windows were observed, but follow-up casts during those windows were low."
        ))
    end

    -- Task 2.2: High CC uptime suggestion
    if hasCCCoverage and (m.ccUptimePct or 0) > 0.35 then
        local damageTakenDuringCC = session.totals and session.totals.damageTakenDuringCC
        local totalDamageTaken = (session.totals and session.totals.damageTaken) or 0
        local fireSuggestion = false
        if damageTakenDuringCC then
            fireSuggestion = damageTakenDuringCC > 0.5 * totalDamageTaken
        else
            -- Graceful degradation: fire without damage-during-CC data
            fireSuggestion = true
        end
        if fireSuggestion then
            local evidence = {
                ccUptimePct = m.ccUptimePct,
                timeUnderCC = m.timeUnderCC,
            }
            if damageTakenDuringCC then
                evidence.damageTakenDuringCC = damageTakenDuringCC
            end
            addSuggestion(results, buildSuggestion(
                session,
                "HIGH_CC_UPTIME",
                "medium",
                0.72,
                evidence,
                "cc_uptime",
                "You spent a significant portion of the fight under crowd control. Consider positioning to avoid CC chains."
            ))
        end
    end

    local contextBaseline = store:GetContextBaseline(contextKey, nil, characterKey)
    if hasRawTimeline and contextBaseline and contextBaseline.fights >= 5 and m.burstScore and m.burstScore < (contextBaseline.averageBurstScore * 0.8) then
        addSuggestion(results, buildSuggestion(
            session,
            "WEAK_BURST_FOR_CONTEXT",
            "medium",
            0.72,
            { samples = contextBaseline.fights, current = m.burstScore, baseline = contextBaseline.averageBurstScore },
            contextKey,
            "Burst windows underperformed relative to this context."
        ))
    end

    if session.result == Constants.SESSION_RESULT.LOST and (survival.unusedDefensives or 0) > 0 then
        addSuggestion(results, buildSuggestion(
            session,
            "DEFENSIVE_UNUSED_ON_LOSS",
            "high",
            0.86,
            { unusedDefensives = survival.unusedDefensives, deaths = survival.deaths or 0 },
            "defensives",
            "You died or lost the fight with major defensives still unused."
        ))
    end

    -- Task 2.3: Death cause attribution — DIED_IN_CC
    if hasCCCoverage and session.deathCauses then
        for _, cause in ipairs(session.deathCauses) do
            if cause.wasCCed and cause.ccSpellId then
                addSuggestion(results, buildSuggestion(
                    session,
                    "DIED_IN_CC",
                    "high",
                    0.85,
                    {
                        ccSpellId = cause.ccSpellId,
                        totalBurstDamage = cause.totalBurstDamage,
                        killingSpellCount = #(cause.killingSpells or {}),
                        timestampOffset = cause.timestampOffset,
                    },
                    "death_cc",
                    "You died while crowd-controlled. Consider saving trinket or defensive for CC chains."
                ))
                break -- One suggestion per session is enough
            end
        end
    end

    if hasIdentityCoverage and (opponent.guid or opponent.name) then
        local opponentKey = opponent.guid or opponent.name
        local opponentBaseline = store:GetOpponentBaseline(opponentKey, nil, characterKey)
        if opponentBaseline and opponentBaseline.fights >= 10 and ((session.totals and session.totals.damageTaken) or 0) > (opponentBaseline.averageDamageTaken * 1.25) then
            addSuggestion(results, buildSuggestion(
                session,
                "HIGH_DAMAGE_TAKEN_VS_OPPONENT",
                "medium",
                0.69,
                { samples = opponentBaseline.fights, current = session.totals and session.totals.damageTaken, baseline = opponentBaseline.averageDamageTaken },
                opponentKey,
                "Incoming pressure from this opponent exceeded your historical average."
            ))
        end
    end

    -- Avoidable damage taken: flag when it exceeds 25% of total damage received.
    local totalTaken = (session.totals and session.totals.damageTaken) or 0
    local avoidable  = (session.totals and session.totals.avoidableDamageTaken) or 0
    if avoidable > 0 and totalTaken > 0 then
        local ratio = avoidable / totalTaken
        if ratio >= 0.25 then
            local topSpellName   = nil
            local topSpellAmount = 0
            local avoidableSpells = session.importedTotals and session.importedTotals.avoidableSpells or {}
            for _, spell in ipairs(avoidableSpells) do
                if (spell.totalAmount or 0) > topSpellAmount then
                    topSpellAmount = spell.totalAmount
                    local spellName = spell.spellID and ns.ApiCompat.GetSpellName(spell.spellID) or nil
                    topSpellName = spellName or ("Spell " .. tostring(spell.spellID or "?"))
                end
            end
            local msg = string.format(
                "%.0f%% of damage you received was avoidable (%s). Work on positioning and defensive reaction.",
                ratio * 100,
                topSpellName and ("highest source: " .. topSpellName) or "multiple sources"
            )
            addSuggestion(results, buildSuggestion(
                session,
                "HIGH_AVOIDABLE_DAMAGE_TAKEN",
                ratio >= 0.50 and "high" or "medium",
                math.min(1.0, ratio * 2),
                { avoidable = avoidable, total = totalTaken, ratio = ratio, topSpell = topSpellName },
                "avoidable_damage",
                msg
            ))
        end
    end

    -- Task 4.3: Spec win rate threshold suggestions
    if hasIdentityCoverage and opponent.specId then
        local specBucket = store.GetAggregateBucketByKey and store:GetAggregateBucketByKey("specs", opponent.specId) or nil
        if specBucket and (specBucket.fights or 0) >= 10 then
            local winRate = (specBucket.wins or 0) / specBucket.fights
            if winRate < 0.40 then
                addSuggestion(results, buildSuggestion(
                    session,
                    "SPEC_WINRATE_DEFICIT",
                    "medium",
                    0.70,
                    { specId = opponent.specId, specName = opponent.specName, fights = specBucket.fights, winRate = winRate },
                    "spec_wr:" .. specKey,
                    "Your win rate against this spec is notably low. Consider reviewing the counter guide for matchup-specific advice."
                ))
            elseif winRate > 0.70 then
                addSuggestion(results, buildSuggestion(
                    session,
                    "SPEC_WINRATE_STRENGTH",
                    "low",
                    0.65,
                    { specId = opponent.specId, specName = opponent.specName, fights = specBucket.fights, winRate = winRate },
                    "spec_wr:" .. specKey,
                    "You have a strong historical win rate against this spec — keep pressing your advantage."
                ))
            end
        end
    end

    -- Task 7.7: Spec Scaling Context Suggestions
    local specScalingFired = false
    do
        local specId = session.playerSnapshot and session.playerSnapshot.specId
        if specId and not specScalingFired then
            local scalingResult = ns.ApiCompat.GetGlobalPvpScalingInfoForSpecID(specId)
            if scalingResult then
                local notable = false
                if scalingResult.damageModifier and (scalingResult.damageModifier > 1.05 or scalingResult.damageModifier < 0.95) then
                    notable = true
                end
                if scalingResult.healingModifier and (scalingResult.healingModifier > 1.05 or scalingResult.healingModifier < 0.95) then
                    notable = true
                end
                if notable then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "SPEC_SCALING_NOTABLE",
                        "low",
                        0.5,
                        { specId = specId, scalingInfo = scalingResult },
                        "spec_scaling",
                        "Your spec has notable PvP scaling modifiers active that may affect damage or healing output."
                    ))
                    specScalingFired = true
                end
            end
        end
    end

    -- Task 2.5: Reactive defensive late suggestion
    if hasCCCoverage and session.cdSequence then
        for _, entry in ipairs(session.cdSequence) do
            if entry.classification == "reactive_late" and entry.lagSeconds and entry.lagSeconds > 2.0 then
                addSuggestion(results, buildSuggestion(
                    session,
                    "REACTIVE_DEFENSIVE_LATE",
                    "medium",
                    0.7,
                    { cooldownSpellId = entry.spellId, latencySeconds = entry.lagSeconds, ccSpellId = entry.ccSpellId },
                    "defensive_timing",
                    "A defensive cooldown was used more than 2 seconds into a CC window. Earlier usage can prevent burst damage."
                ))
                break -- One suggestion per session
            end
        end
    end

    if hasRawTimeline and session.context == Constants.CONTEXT.TRAINING_DUMMY then
        local dummyBenchmarks = store:GetDummyBenchmarks(characterKey)
        for _, benchmark in ipairs(dummyBenchmarks or {}) do
            if benchmark.buildHash == buildHash and benchmark.sessions >= 5 and benchmark.dummyName == (opponent.name or "") then
                local averageOpenerDamage = benchmark.totalOpenerDamage / math.max(benchmark.sessions, 1)
                if (m.openerDamage or 0) < (averageOpenerDamage * 0.85) then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "DUMMY_OPENER_VARIANCE",
                        "low",
                        0.75,
                        { samples = benchmark.sessions, current = m.openerDamage, baseline = averageOpenerDamage },
                        benchmark.key,
                        "Opener damage drifted below your benchmark for this dummy and build."
                    ))
                end
                break
            end
        end
    end

    if not hasRawTimeline and session.context == Constants.CONTEXT.TRAINING_DUMMY then
        local dummyBenchmarks = store:GetDummyBenchmarks(characterKey)
        for _, benchmark in ipairs(dummyBenchmarks or {}) do
            if benchmark.buildHash == buildHash and benchmark.sessions >= 5 and benchmark.dummyName == (opponent.name or "") then
                local averageSustainedDps = benchmark.totalSustainedDps / math.max(benchmark.sessions, 1)
                if (m.sustainedDps or 0) < (averageSustainedDps * 0.9) then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "DUMMY_SUSTAINED_VARIANCE",
                        "low",
                        0.77,
                        { samples = benchmark.sessions, current = m.sustainedDps, baseline = averageSustainedDps },
                        benchmark.key,
                        "Sustained dummy damage landed below your stored benchmark for this build."
                    ))
                end
                break
            end
        end
    end

    if #(session.rawEvents or {}) >= Constants.MAX_RAW_EVENTS_PER_SESSION then
        addSuggestion(results, buildSuggestion(
            session,
            "RAW_EVENT_OVERFLOW",
            "low",
            1.0,
            { rawEvents = #(session.rawEvents or {}), max = Constants.MAX_RAW_EVENTS_PER_SESSION },
            "raw_events",
            "Raw event storage hit the emergency cap, so some detail was dropped."
        ))
    end

    if not hasRawTimeline then
        addSuggestion(results, buildSuggestion(
            session,
            "MIDNIGHT_SAFE_LIMITS",
            "low",
            1.0,
            { source = session.captureSource or "damage_meter" },
            "capture_mode",
            "This session was imported from the built-in Damage Meter, so raw event windows and burst timing are unavailable on Midnight-safe mode."
        ))
    end

    -- Task 2.7: Suboptimal opener sequence suggestion
    if hasCastCoverage and hasIdentityCoverage and session.openerSequence and session.openerSequence.hash and opponent.specId then
        local openerBuckets = store:GetOpenerSequenceEffectiveness(opponent.specId)
        local currentHash = session.openerSequence.hash
        local currentEntry = openerBuckets[currentHash]
        if currentEntry and currentEntry.attempts >= 5 then
            local currentWinRate = currentEntry.wins / math.max(currentEntry.attempts, 1)
            if currentWinRate < 0.40 then
                -- Check if a better opener exists
                local bestHash, bestWinRate, bestAttempts = nil, currentWinRate, 0
                for hash, entry in pairs(openerBuckets) do
                    if hash ~= currentHash and entry.attempts >= 5 then
                        local wr = entry.wins / math.max(entry.attempts, 1)
                        if wr > bestWinRate then
                            bestHash = hash
                            bestWinRate = wr
                            bestAttempts = entry.attempts
                        end
                    end
                end
                if bestHash then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "SUBOPTIMAL_OPENER_SEQUENCE",
                        "medium",
                        0.65,
                        {
                            currentHash = currentHash,
                            currentWinRate = currentWinRate,
                            currentAttempts = currentEntry.attempts,
                            betterHash = bestHash,
                            betterWinRate = bestWinRate,
                            betterAttempts = bestAttempts,
                            specName = opponent.specName,
                        },
                        "opener_sequence",
                        "Your current opener sequence has a low win rate against this spec. A different opener pattern performs better."
                    ))
                end
            end
        end
    end

    -- Task 4.2: Trinket Timing Suggestion
    -- T038: Also capture source event objects for suggestionConfidence derivation.
    local ccWindowSourceEvents = {}
    local ccWindows = (function()
        local events = session.timelineEvents
        if not events then return {} end
        local w = {}
        for _, ev in ipairs(events) do
            -- T031: Only include realtime-observed CC events in timing analysis;
            -- summary-derived rows (DM post-match) must not inflate CC windows.
            if ev.lane == Constants.TIMELINE_LANE.CC_RECEIVED and ev.type == "start"
                    and ev.chronology ~= "summary" then
                local meta = ev.meta or {}
                w[#w + 1] = {
                    spellId     = meta.spellID or ev.spellId,
                    duration    = meta.duration or 0,
                    startOffset = ev.t or 0,
                }
                -- T038: Keep reference for confidence derivation.
                ccWindowSourceEvents[#ccWindowSourceEvents + 1] = ev
            end
        end
        return w
    end)()
    if #ccWindows > 0 and hasRawTimeline then
        -- Collect trinket use timestamps from raw events (spell 42292 + break CC tags)
        local trinketUseOffsets = {}
        local breakCcTags = ns.StaticPvpData and ns.StaticPvpData.ARENA_CONTROL
            and ns.StaticPvpData.ARENA_CONTROL.breakCcTags or { [42292] = true }
        for _, evt in ipairs(session.rawEvents) do
            if evt.sourceMine and evt.spellId and breakCcTags[evt.spellId] then
                trinketUseOffsets[#trinketUseOffsets + 1] = evt.timestampOffset or 0
            end
        end

        for _, cc in ipairs(ccWindows) do
            if cc.duration and cc.duration > 3 then
                local ccStart = cc.startOffset or 0
                local threshold = ccStart + cc.duration * 0.75
                local trinketUsedAt = nil
                for _, offset in ipairs(trinketUseOffsets) do
                    if offset >= ccStart and offset <= ccStart + cc.duration then
                        trinketUsedAt = offset
                        break
                    end
                end
                if not trinketUsedAt or trinketUsedAt > threshold then
                    -- T038: Derive suggestionConfidence from the source CC events.
                    local ccSuggestConf = minEventConfidence(ccWindowSourceEvents)
                    addSuggestion(results, buildSuggestion(
                        session,
                        "TRINKET_TIMING_POOR",
                        "high",
                        0.80,
                        {
                            ccSpellId = cc.spellId,
                            ccDuration = cc.duration,
                            trinketUsedAt = trinketUsedAt,
                            lagSeconds = trinketUsedAt and (trinketUsedAt - ccStart) or cc.duration,
                            sourceSpecName = opponent.specName,
                        },
                        "trinket_timing",
                        "Trinket was used late or not at all during a significant CC window.",
                        ccSuggestConf
                    ))
                    break -- One trinket timing suggestion per session
                end
            end
        end
    end

    -- ── Phase 3.1: Poor Interrupt Rate ─────────────────────────────────────
    local u = session.utility or {}
    local interruptRate = m.interruptRate
    local totalInterruptAttempts = (u.successfulInterrupts or 0) + (u.failedInterrupts or 0)
    if interruptRate and interruptRate < 0.4 and totalInterruptAttempts >= 3 then
        addSuggestion(results, buildSuggestion(
            session,
            "POOR_INTERRUPT_RATE",
            "medium",
            0.75,
            {
                interruptRate = Helpers.Round(interruptRate * 100, 1),
                successful = u.successfulInterrupts or 0,
                failed = u.failedInterrupts or 0,
            },
            "interrupt_rate",
            string.format("Interrupt success rate was only %.0f%% (%d/%d). Focus on timing kicks on key casts.",
                interruptRate * 100,
                u.successfulInterrupts or 0,
                totalInterruptAttempts
            )
        ))
    end

    -- ── Phase 3.2: Low Healer Pressure ──────────────────────────────────────
    local healerPressure = m.healerPressure
    if healerPressure and healerPressure < 0.15 and session.result == Constants.SESSION_RESULT.LOST
        and session.context == Constants.CONTEXT.ARENA then
        addSuggestion(results, buildSuggestion(
            session,
            "LOW_HEALER_PRESSURE",
            "medium",
            0.70,
            {
                healerPressurePct = Helpers.Round(healerPressure * 100, 1),
                dpsPressurePct = Helpers.Round((m.dpsPressure or 0) * 100, 1),
            },
            "healer_pressure",
            string.format("Only %.0f%% of your damage hit the healer. Consider cross-CCing or swapping to pressure them.",
                healerPressure * 100
            )
        ))
    end

    -- ── Phase 3.3: Tilt Warning ─────────────────────────────────────────────
    if store then
        local streak = store:GetRecentSessionStreak(5)
        local consecutiveLosses = 0
        for _, s in ipairs(streak) do
            if s.result == Constants.SESSION_RESULT.LOST then
                consecutiveLosses = consecutiveLosses + 1
            else
                break
            end
        end
        if consecutiveLosses >= 3 then
            local baseline = store:GetPressureBaseline(session.context, 20)
            local recentAvg = 0
            for i = 1, math.min(consecutiveLosses, #streak) do
                recentAvg = recentAvg + (streak[i].pressureScore or 0)
            end
            recentAvg = consecutiveLosses > 0 and (recentAvg / consecutiveLosses) or 0

            if baseline > 0 and recentAvg < baseline * 0.85 then
                addSuggestion(results, buildSuggestion(
                    session,
                    "TILT_WARNING",
                    "high",
                    0.80,
                    {
                        consecutiveLosses = consecutiveLosses,
                        recentPressure = Helpers.Round(recentAvg, 1),
                        baselinePressure = Helpers.Round(baseline, 1),
                    },
                    "tilt_warning",
                    string.format("Your last %d matches were losses with avg pressure %.0f (baseline %.0f). Consider taking a break.",
                        consecutiveLosses, recentAvg, baseline
                    )
                ))
            end
        end
    end

    -- ── Phase 3.4: Comp Deficit ─────────────────────────────────────────────
    if hasIdentityCoverage and store and session.opponentCompKey then
        local comps = store:GetCompWinRates()
        local comp = comps[session.opponentCompKey]
        if comp and comp.fights >= 5 then
            local winRate = comp.fights > 0 and (comp.wins / comp.fights) or 0
            if winRate < 0.35 then
                addSuggestion(results, buildSuggestion(
                    session,
                    "COMP_DEFICIT",
                    "medium",
                    0.75,
                    {
                        compKey = session.opponentCompKey,
                        fights = comp.fights,
                        wins = comp.wins,
                        losses = comp.losses,
                        winRate = Helpers.Round(winRate * 100, 1),
                    },
                    "comp_deficit",
                    string.format("You are %d-%d (%.0f%%) vs this comp. Review the counter guide for each spec.",
                        comp.wins, comp.losses, winRate * 100
                    )
                ))
            end
        end
    end

    -- ── CC Coach Integration (T100) ─────────────────────────────────────────
    local ccCoach = ns.Addon:GetModule("CCCoachService")
    if ccCoach and ccCoach.GenerateCCInsights then
        local ccOk, ccInsights = pcall(ccCoach.GenerateCCInsights, ccCoach, session)
        if ccOk and ccInsights then
            local CC_INSIGHT_TO_REASON = {
                dr_waste        = "CC_DR_WASTE",
                late_trinket    = "CC_LATE_TRINKET",
                missed_cc_kill  = "CC_MISSED_KILL_WINDOW",
                good_trinket    = "CC_GOOD_TRINKET",
                cc_chain_break  = "CC_CHAIN_BREAK",
                high_cc_uptime  = "CC_HIGH_UPTIME",
            }
            for _, insight in ipairs(ccInsights) do
                local reasonCode = CC_INSIGHT_TO_REASON[insight.insightType]
                if reasonCode then
                    addSuggestion(results, buildSuggestion(
                        session,
                        reasonCode,
                        insight.severity or "medium",
                        insight.confidence or 0.70,
                        insight.evidence or {},
                        "cc_coaching",
                        insight.message or "CC coaching insight"
                    ))
                end
            end
        end
    end

    return results
end

ns.Addon:RegisterModule("SuggestionEngine", SuggestionEngine)
