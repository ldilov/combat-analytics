local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers

local SuggestionEngine = {}

local function addSuggestion(results, suggestion)
    results[#results + 1] = suggestion
end

local function buildSuggestion(session, reasonCode, severity, confidence, evidence, comparisonKey, message)
    return {
        sessionId = session.id,
        reasonCode = reasonCode,
        severity = severity,
        confidence = Helpers.Round(confidence, 2),
        evidence = evidence,
        comparisonKey = comparisonKey,
        message = message,
    }
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
    local contextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
    local opponent = session.primaryOpponent or {}
    local hasRawTimeline = #(session.rawEvents or {}) > 0
    local successfulCastCount = getSuccessfulCastCount(session)
    local matchupBaseline = nil
    if opponent.guid or opponent.name then
        matchupBaseline = store:GetSessionBaseline(buildHash, contextKey, opponent.guid or opponent.name)
    end

    local buildBaseline = store:GetBuildBaseline(buildHash, contextKey)
    if buildBaseline and buildBaseline.fights >= 5 and session.metrics.pressureScore < (buildBaseline.averagePressureScore * 0.8) then
        addSuggestion(results, buildSuggestion(
            session,
            "LOW_PRESSURE_VS_BUILD_BASELINE",
            "medium",
            0.78,
            { samples = buildBaseline.fights, current = session.metrics.pressureScore, baseline = buildBaseline.averagePressureScore },
            buildHash,
            "Pressure score landed below your normal build baseline."
        ))
    end

    if successfulCastCount >= 6 and (session.metrics.rotationalConsistencyScore or 0) > 0 and session.metrics.rotationalConsistencyScore < 45 then
        addSuggestion(results, buildSuggestion(
            session,
            "ROTATION_GAPS_OBSERVED",
            "medium",
            0.73,
            {
                casts = successfulCastCount,
                idleSeconds = session.metrics.idleSeconds or 0,
                rotationScore = session.metrics.rotationalConsistencyScore or 0,
            },
            "rotation",
            "Successful casts showed noticeable gaps, which points to lost uptime in the rotation."
        ))
    end

    if matchupBaseline and matchupBaseline.fights >= 5 then
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
            and (session.totals.damageTaken or 0) > (matchupBaseline.averageDamageTaken or 0)
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
                    damageTaken = session.totals.damageTaken or 0,
                },
                contextKey,
                "Defensive timing drifted later than your stronger historical pacing for this matchup."
            ))
        end
    end

    if (session.metrics.procWindowsObserved or 0) >= 3 and (session.metrics.procWindowCastCount or 0) < math.max(2, session.metrics.procWindowsObserved) then
        addSuggestion(results, buildSuggestion(
            session,
            "PROC_WINDOWS_UNDERUSED",
            "medium",
            0.67,
            {
                procWindows = session.metrics.procWindowsObserved or 0,
                castsDuringWindows = session.metrics.procWindowCastCount or 0,
            },
            "proc_windows",
            "Several proc-like buff windows were observed, but follow-up casts during those windows were low."
        ))
    end

    local contextBaseline = store:GetContextBaseline(contextKey)
    if hasRawTimeline and contextBaseline and contextBaseline.fights >= 5 and session.metrics.burstScore < (contextBaseline.averageBurstScore * 0.8) then
        addSuggestion(results, buildSuggestion(
            session,
            "WEAK_BURST_FOR_CONTEXT",
            "medium",
            0.72,
            { samples = contextBaseline.fights, current = session.metrics.burstScore, baseline = contextBaseline.averageBurstScore },
            contextKey,
            "Burst windows underperformed relative to this context."
        ))
    end

    if session.result == Constants.SESSION_RESULT.LOST and (session.survival.unusedDefensives or 0) > 0 then
        addSuggestion(results, buildSuggestion(
            session,
            "DEFENSIVE_UNUSED_ON_LOSS",
            "high",
            0.86,
            { unusedDefensives = session.survival.unusedDefensives, deaths = session.survival.deaths or 0 },
            "defensives",
            "You died or lost the fight with major defensives still unused."
        ))
    end

    if opponent.guid or opponent.name then
        local opponentKey = opponent.guid or opponent.name
        local opponentBaseline = store:GetOpponentBaseline(opponentKey)
        if opponentBaseline and opponentBaseline.fights >= 10 and (session.totals.damageTaken or 0) > (opponentBaseline.averageDamageTaken * 1.25) then
            addSuggestion(results, buildSuggestion(
                session,
                "HIGH_DAMAGE_TAKEN_VS_OPPONENT",
                "medium",
                0.69,
                { samples = opponentBaseline.fights, current = session.totals.damageTaken, baseline = opponentBaseline.averageDamageTaken },
                opponentKey,
                "Incoming pressure from this opponent exceeded your historical average."
            ))
        end
    end

    if hasRawTimeline and session.context == Constants.CONTEXT.TRAINING_DUMMY then
        local dummyBenchmarks = store:GetDummyBenchmarks()
        for _, benchmark in ipairs(dummyBenchmarks) do
            if benchmark.buildHash == buildHash and benchmark.sessions >= 5 and benchmark.dummyName == (opponent.name or "") then
                local averageOpenerDamage = benchmark.totalOpenerDamage / math.max(benchmark.sessions, 1)
                if (session.metrics.openerDamage or 0) < (averageOpenerDamage * 0.85) then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "DUMMY_OPENER_VARIANCE",
                        "low",
                        0.75,
                        { samples = benchmark.sessions, current = session.metrics.openerDamage, baseline = averageOpenerDamage },
                        benchmark.key,
                        "Opener damage drifted below your benchmark for this dummy and build."
                    ))
                end
                break
            end
        end
    end

    if not hasRawTimeline and session.context == Constants.CONTEXT.TRAINING_DUMMY then
        local dummyBenchmarks = store:GetDummyBenchmarks()
        for _, benchmark in ipairs(dummyBenchmarks) do
            if benchmark.buildHash == buildHash and benchmark.sessions >= 5 and benchmark.dummyName == (opponent.name or "") then
                local averageSustainedDps = benchmark.totalSustainedDps / math.max(benchmark.sessions, 1)
                if (session.metrics.sustainedDps or 0) < (averageSustainedDps * 0.9) then
                    addSuggestion(results, buildSuggestion(
                        session,
                        "DUMMY_SUSTAINED_VARIANCE",
                        "low",
                        0.77,
                        { samples = benchmark.sessions, current = session.metrics.sustainedDps, baseline = averageSustainedDps },
                        benchmark.key,
                        "Sustained dummy damage landed below your stored benchmark for this build."
                    ))
                end
                break
            end
        end
    end

    if session.captureQuality and session.captureQuality.rawEvents == Constants.CAPTURE_QUALITY.OVERFLOW then
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

    return results
end

ns.Addon:RegisterModule("SuggestionEngine", SuggestionEngine)
