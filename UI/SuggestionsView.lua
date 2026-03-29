local _, ns = ...

local SuggestionsView = {
    viewId = "insights",
}

local SUGGESTION_TITLES = {
    LOW_PRESSURE_VS_BUILD_BASELINE = "Output below your normal build baseline",
    WEAK_BURST_FOR_CONTEXT = "Burst pressure underperformed for this context",
    DEFENSIVE_UNUSED_ON_LOSS = "A major defensive trade was missed",
    HIGH_DAMAGE_TAKEN_VS_OPPONENT = "This opponent dealt more pressure than usual",
    DUMMY_OPENER_VARIANCE = "Opener lagged behind your dummy benchmark",
    DUMMY_SUSTAINED_VARIANCE = "Sustained dummy damage fell below benchmark",
    ROTATION_GAPS_OBSERVED = "Rotation had visible dead space",
    PROC_WINDOWS_UNDERUSED = "Proc-like buff windows were not converted",
    LATE_FIRST_GO = "First major go started later than usual",
    DEFENSIVE_DRIFT = "Defensive timing drifted later than usual",
    MIDNIGHT_SAFE_LIMITS = "Timeline detail is limited in Midnight-safe mode",
    RAW_EVENT_OVERFLOW = "Raw event cap was reached",
    DIED_IN_CC = "Died while crowd-controlled",
    TRINKET_TIMING_POOR = "Trinket was late or unused during CC",
    HIGH_CC_UPTIME = "Excessive time spent under crowd control",
    SPEC_WINRATE_DEFICIT = "Struggling against this spec historically",
    SPEC_WINRATE_STRENGTH = "Strong historical performance against this spec",
    SPEC_SCALING_NOTABLE = "PvP Scaling Note",
    REACTIVE_DEFENSIVE_LATE = "Defensive cooldown used late into CC",
    SUBOPTIMAL_OPENER_SEQUENCE = "Opener sequence has low win rate vs this spec",
    POOR_INTERRUPT_RATE = "Low interrupt success rate",
    LOW_HEALER_PRESSURE = "Healer received little damage",
    TILT_WARNING = "Performance dip detected (possible tilt)",
    COMP_DEFICIT = "Low win rate vs this opponent composition",
    CC_DR_WASTE = "CC applied at diminished returns",
    CC_LATE_TRINKET = "Trinket used too late in CC chain",
    CC_MISSED_KILL_WINDOW = "CC on healer but no burst follow-up",
    CC_GOOD_TRINKET = "Good trinket timing (well done!)",
    CC_CHAIN_BREAK = "CC chain broken prematurely",
    CC_HIGH_UPTIME = "Excessive time spent crowd-controlled",
}

-- ---------------------------------------------------------------------------
-- Category filter definitions for coaching notes
-- ---------------------------------------------------------------------------
local CATEGORY_FILTERS = {
    { key = "all",         label = "All"         },
    { key = "offense",     label = "Offense"     },
    { key = "defense",     label = "Defense"     },
    { key = "cc",          label = "CC"          },
    { key = "matchup",     label = "Matchup"     },
    { key = "consistency", label = "Consistency" },
}

local REASON_TO_CATEGORY = {
    -- offense
    LOW_PRESSURE_VS_BUILD_BASELINE = "offense",
    WEAK_BURST_FOR_CONTEXT         = "offense",
    LATE_FIRST_GO                  = "offense",
    SUBOPTIMAL_OPENER_SEQUENCE     = "offense",
    LOW_HEALER_PRESSURE            = "offense",
    -- defense
    DEFENSIVE_UNUSED_ON_LOSS       = "defense",
    DEFENSIVE_DRIFT                = "defense",
    REACTIVE_DEFENSIVE_LATE        = "defense",
    -- CC
    DIED_IN_CC                     = "cc",
    TRINKET_TIMING_POOR            = "cc",
    HIGH_CC_UPTIME                 = "cc",
    POOR_INTERRUPT_RATE            = "cc",
    CC_DR_WASTE                    = "cc",
    CC_LATE_TRINKET                = "cc",
    CC_MISSED_KILL_WINDOW          = "cc",
    CC_GOOD_TRINKET                = "cc",
    CC_CHAIN_BREAK                 = "cc",
    CC_HIGH_UPTIME                 = "cc",
    -- matchup
    HIGH_DAMAGE_TAKEN_VS_OPPONENT  = "matchup",
    SPEC_WINRATE_DEFICIT           = "matchup",
    SPEC_WINRATE_STRENGTH          = "matchup",
    COMP_DEFICIT                   = "matchup",
    -- consistency
    DUMMY_OPENER_VARIANCE          = "consistency",
    DUMMY_SUSTAINED_VARIANCE       = "consistency",
    ROTATION_GAPS_OBSERVED         = "consistency",
    PROC_WINDOWS_UNDERUSED         = "consistency",
    TILT_WARNING                   = "consistency",
}

-- Severity to fill fraction for MetricBar severity indicators
local SEVERITY_FILL = {
    high   = 1.0,
    medium = 0.55,
    low    = 0.2,
}

-- Severity to MetricBar fill color
local SEVERITY_BAR_COLORS = {
    high   = { 0.90, 0.30, 0.25, 1.0 },
    medium = { 0.96, 0.74, 0.38, 1.0 },
    low    = { 0.44, 0.82, 0.60, 1.0 },
}

local function formatDisplayLabel(value)
    return ns.Widgets.FormatDisplayLabel(value)
end

local function getInsightRule(key, fallback)
    local rules = ns.StaticPvpData and ns.StaticPvpData.INSIGHT_RULES or nil
    if rules and rules[key] ~= nil then
        return rules[key]
    end
    return fallback
end

local function buildEvidenceText(suggestion)
    local evidence = suggestion.evidence or {}

    if suggestion.reasonCode == "LOW_PRESSURE_VS_BUILD_BASELINE" then
        return string.format("Pressure %.1f versus %.1f across %d build sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "WEAK_BURST_FOR_CONTEXT" then
        return string.format("Burst %.1f versus %.1f context average across %d sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "DEFENSIVE_UNUSED_ON_LOSS" then
        return string.format("Unused defensives: %d. Deaths: %d.", evidence.unusedDefensives or 0, evidence.deaths or 0)
    end
    if suggestion.reasonCode == "HIGH_DAMAGE_TAKEN_VS_OPPONENT" then
        return string.format("Incoming %s versus %s normal taken over %d fights.", ns.Helpers.FormatNumber(evidence.current or 0), ns.Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "DUMMY_OPENER_VARIANCE" then
        return string.format("Opener %s versus %s benchmark over %d pulls.", ns.Helpers.FormatNumber(evidence.current or 0), ns.Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "DUMMY_SUSTAINED_VARIANCE" then
        return string.format("Sustained %s versus %s benchmark over %d pulls.", ns.Helpers.FormatNumber(evidence.current or 0), ns.Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "ROTATION_GAPS_OBSERVED" then
        return string.format("Casts: %d. Idle time: %.1fs. Rotation score: %.1f.", evidence.casts or 0, evidence.idleSeconds or 0, evidence.rotationScore or 0)
    end
    if suggestion.reasonCode == "PROC_WINDOWS_UNDERUSED" then
        return string.format("Proc windows: %d. Casts inside windows: %d.", evidence.procWindows or 0, evidence.castsDuringWindows or 0)
    end
    if suggestion.reasonCode == "LATE_FIRST_GO" then
        -- Show the delta rather than absolute offsets — absolute values are
        -- arena-relative and unintuitive (e.g. "78s vs 77s" for an arena session
        -- with a 75s prep phase). The delta is always meaningful.
        local delta = (evidence.current or 0) - (evidence.baseline or 0)
        return string.format("First major go was %.1fs later than your usual timing for this matchup (%d session average).", delta, evidence.samples or 0)
    end
    if suggestion.reasonCode == "DEFENSIVE_DRIFT" then
        local delta = (evidence.current or 0) - (evidence.baseline or 0)
        return string.format("First defensive was %.1fs later than your usual pacing. Damage taken %s.", delta, ns.Helpers.FormatNumber(evidence.damageTaken or 0))
    end
    if suggestion.reasonCode == "MIDNIGHT_SAFE_LIMITS" then
        return "Built from Blizzard's post-combat Damage Meter totals because raw CLEU timing is restricted."
    end
    if suggestion.reasonCode == "RAW_EVENT_OVERFLOW" then
        return string.format("Stored %d events against cap %d.", evidence.rawEvents or 0, evidence.max or 0)
    end
    if suggestion.reasonCode == "DIED_IN_CC" then
        return string.format("CC spell ID %d. Burst taken: %s across %d damage events.", evidence.ccSpellId or 0, ns.Helpers.FormatNumber(evidence.totalBurstDamage or 0), evidence.killingSpellCount or 0)
    end
    if suggestion.reasonCode == "TRINKET_TIMING_POOR" then
        return string.format("CC spell ID %d lasted %.1fs. Trinket lag: %.1fs.", evidence.ccSpellId or 0, evidence.ccDuration or 0, evidence.lagSeconds or 0)
    end
    if suggestion.reasonCode == "HIGH_CC_UPTIME" then
        return string.format("CC uptime %.1f%%. Time under CC: %.1fs.", (evidence.ccUptimePct or 0) * 100, evidence.timeUnderCC or 0)
    end
    if suggestion.reasonCode == "SPEC_WINRATE_DEFICIT" then
        return string.format("Win rate %.0f%% against %s over %d sessions.", (evidence.winRate or 0) * 100, evidence.specName or "this spec", evidence.fights or 0)
    end
    if suggestion.reasonCode == "SPEC_WINRATE_STRENGTH" then
        return string.format("Win rate %.0f%% against %s over %d sessions.", (evidence.winRate or 0) * 100, evidence.specName or "this spec", evidence.fights or 0)
    end
    if suggestion.reasonCode == "SPEC_SCALING_NOTABLE" then
        local scalingInfo = evidence.scalingInfo or {}
        local dmgMod = scalingInfo.damageModifier and string.format("Damage modifier: %.2f", scalingInfo.damageModifier) or ""
        local healMod = scalingInfo.healingModifier and string.format("Healing modifier: %.2f", scalingInfo.healingModifier) or ""
        local sep = (dmgMod ~= "" and healMod ~= "") and ". " or ""
        return string.format("Spec %s has notable PvP scaling. %s%s%s", tostring(evidence.specId or ""), dmgMod, sep, healMod)
    end
    if suggestion.reasonCode == "REACTIVE_DEFENSIVE_LATE" then
        return string.format("Defensive (spell %d) used %.1fs into CC (spell %d). Earlier use reduces burst taken.",
            evidence.cooldownSpellId or 0, evidence.latencySeconds or 0, evidence.ccSpellId or 0)
    end
    if suggestion.reasonCode == "SUBOPTIMAL_OPENER_SEQUENCE" then
        return string.format("Current opener win rate %.0f%% over %d attempts vs %s. A better opener has %.0f%% over %d attempts.",
            (evidence.currentWinRate or 0) * 100, evidence.currentAttempts or 0, evidence.specName or "this spec",
            (evidence.betterWinRate or 0) * 100, evidence.betterAttempts or 0)
    end
    if suggestion.reasonCode == "POOR_INTERRUPT_RATE" then
        return string.format("Interrupt rate: %.0f%% (%d successful, %d failed).",
            evidence.interruptRate or 0, evidence.successful or 0, evidence.failed or 0)
    end
    if suggestion.reasonCode == "LOW_HEALER_PRESSURE" then
        return string.format("Healer took %.0f%% of your damage. DPS/Tank took %.0f%%.",
            evidence.healerPressurePct or 0, evidence.dpsPressurePct or 0)
    end
    if suggestion.reasonCode == "TILT_WARNING" then
        return string.format("Last %d matches lost. Recent pressure: %.0f (baseline: %.0f).",
            evidence.consecutiveLosses or 0, evidence.recentPressure or 0, evidence.baselinePressure or 0)
    end
    if suggestion.reasonCode == "COMP_DEFICIT" then
        return string.format("Record vs this comp: %d-%d (%.0f%% win rate over %d games).",
            evidence.wins or 0, evidence.losses or 0, evidence.winRate or 0, evidence.fights or 0)
    end
    if suggestion.reasonCode == "CC_DR_WASTE" then
        return string.format("DR category: %s. Chain length: %d. Applied at diminished level.", evidence.drCategory or "?", evidence.chainLength or 0)
    end
    if suggestion.reasonCode == "CC_LATE_TRINKET" then
        return string.format("Trinket delay: %.1fs after CC start. CC duration: %.1fs.", evidence.trinketDelay or 0, evidence.ccDuration or 0)
    end
    if suggestion.reasonCode == "CC_MISSED_KILL_WINDOW" then
        return string.format("Healer CC duration: %.1fs. No burst within %.1fs of CC.", evidence.ccDuration or 0, evidence.followUpWindow or 5)
    end
    if suggestion.reasonCode == "CC_GOOD_TRINKET" then
        return string.format("Trinketed %.1fs into CC. Avoided %.1fs of remaining CC.", evidence.trinketDelay or 0, evidence.avoidedDuration or 0)
    end
    if suggestion.reasonCode == "CC_CHAIN_BREAK" then
        return string.format("Chain on %s broke after %d CCs. Gap: %.1fs.", evidence.drCategory or "?", evidence.chainLength or 0, evidence.gapSeconds or 0)
    end
    if suggestion.reasonCode == "CC_HIGH_UPTIME" then
        return string.format("CC uptime: %.1f%%. Total time under CC: %.1fs.", (evidence.uptimePct or 0) * 100, evidence.totalCCTime or 0)
    end

    return "Derived from current session output and your stored PvP history."
end

local function buildSessionTag(session)
    if not session then
        return "Unknown session context."
    end

    local opponent = ns.Helpers.ResolveOpponentName(session, "Unknown opponent")
    return string.format("%s | %s | %s | %s", date("%Y-%m-%d %H:%M", session.timestamp or time()), session.context or "unknown", opponent, session.result or "unknown")
end

local function buildTrustCard(store, session)
    local rawAvailable = #(session.rawEvents or {}) > 0
    local importInfo = session.import or {}
    local identityConfidence = session.identity and session.identity.confidence or 0
    local readQuality = session.analysisConfidence or "limited"
    local severity = readQuality == "high" and "low" or (readQuality == "medium" and "medium" or "high")
    local characterLabel = store:GetSessionCharacterLabel(session)
    -- Rich label from the data confidence pipeline (e.g. "Full Raw", "Partial Roster").
    local dataConf = session.dataConfidence or readQuality
    local richLabel = formatDisplayLabel(dataConf)

    local body = string.format(
        "%s trust on %s. %s data is driving the read, and opponent identity confidence is %d.",
        richLabel,
        characterLabel,
        formatDisplayLabel(session.finalDamageSource),
        identityConfidence
    )

    -- T120: Support both legacy ANALYSIS_CONFIDENCE and new SESSION_CONFIDENCE labels
    if readQuality == "high" then
        if dataConf == "enriched" or dataConf == "state_plus_damage_meter" then
            body = string.format(
                "%s trust on %s. State events and DamageMeter reconciled within tolerance — full attribution available.",
                richLabel,
                characterLabel
            )
        else
            body = string.format(
                "%s trust on %s. Timeline exists and fight identity resolved cleanly enough for stronger coaching.",
                richLabel,
                characterLabel
            )
        end
    elseif dataConf == "partial_roster" then
        body = string.format(
            "%s trust on %s. Damage data is solid but not all arena opponents were identified — roster-specific advice is limited.",
            richLabel,
            characterLabel
        )
    elseif dataConf == "restricted_raw" or dataConf == "damage_meter_only" then
        body = string.format(
            "%s trust on %s. CLEU is restricted for this session; coaching relies on DamageMeter totals only.",
            richLabel,
            characterLabel
        )
    elseif dataConf == "degraded" or dataConf == "visible_cc_only" then
        body = string.format(
            "%s trust on %s. Limited to CC/control data — damage totals may be unreliable. Timing advice suppressed.",
            richLabel,
            characterLabel
        )
    elseif dataConf == "legacy_cleu_import" then
        body = string.format(
            "%s trust on %s. Migrated from pre-Midnight session — CLEU data is legacy, timeline detail limited.",
            richLabel,
            characterLabel
        )
    elseif readQuality == "limited" or dataConf == "estimated" then
        body = string.format(
            "%s trust on %s. This read leans on post-combat totals, so timing-heavy advice is intentionally conservative.",
            richLabel,
            characterLabel
        )
    end

    local evidence = string.format(
        "Source %s | data %s | capture %s | raw timeline %s | identity %d | import %d",
        formatDisplayLabel(session.finalDamageSource),
        richLabel,
        session.captureSource or "unknown",
        rawAvailable and "yes" or "no",
        identityConfidence,
        importInfo.confidence or 0
    )

    return severity, "Session Trust", body, evidence
end

local function buildFightStory(store, session, characterKey)
    local opponentKey = session.primaryOpponent and (session.primaryOpponent.guid or session.primaryOpponent.name) or nil
    local contextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"
    local buildBaseline = store:GetBuildBaseline(buildHash, contextKey, session.id, characterKey)
    local matchupBaseline = opponentKey and store:GetSessionBaseline(buildHash, contextKey, opponentKey, session.id, characterKey) or nil
    local openerFingerprint = session.openerFingerprint or {}
    local openerWarningRatio = getInsightRule("openerWarningRatio", 0.85)
    local strongPressureRatio = getInsightRule("strongPressureRatio", 1.1)

    if session.result == ns.Constants.SESSION_RESULT.LOST and (session.survival.unusedDefensives or 0) > 0 then
        return
            "high",
            "Fight Story",
            "The loss happened with a true defensive still available, which makes this look more like a trade issue than an output issue.",
            string.format("Unused defensives %d | largest spike %s | self-heal %s", session.survival.unusedDefensives or 0, ns.Helpers.FormatNumber(session.survival.largestIncomingSpike or 0), ns.Helpers.FormatNumber(session.survival.selfHealing or 0))
    end

    if session.result == ns.Constants.SESSION_RESULT.LOST and not openerFingerprint.firstMajorDefensiveAt and (session.survival.largestIncomingSpike or 0) > 0 then
        return
            "high",
            "Fight Story",
            "You lost the first important trade before a major defensive was committed, so the session reads as survival-limited.",
            string.format("Largest spike %s | damage taken %s | absorbed %s", ns.Helpers.FormatNumber(session.survival.largestIncomingSpike or 0), ns.Helpers.FormatNumber(session.totals.damageTaken or 0), ns.Helpers.FormatNumber(session.survival.totalAbsorbed or 0))
    end

    if matchupBaseline
        and matchupBaseline.fights >= getInsightRule("minimumMatchupSamples", 3)
        and (session.metrics.openerDamage or 0) > 0
        and (session.metrics.openerDamage or 0) < ((matchupBaseline.averageOpenerDamage or 0) * openerWarningRatio)
    then
        return
            "medium",
            "Fight Story",
            "The opener landed below your usual pace for this build and matchup, so the fight started behind your own norm.",
            string.format("Opener %s vs %s over %d similar sessions", ns.Helpers.FormatNumber(session.metrics.openerDamage or 0), ns.Helpers.FormatNumber(matchupBaseline.averageOpenerDamage or 0), matchupBaseline.fights or 0)
    end

    if buildBaseline
        and buildBaseline.fights >= getInsightRule("minimumBuildSamples", 5)
        and (session.metrics.pressureScore or 0) >= ((buildBaseline.averagePressureScore or 0) * strongPressureRatio)
        and session.result == ns.Constants.SESSION_RESULT.WON
    then
        return
            "low",
            "Fight Story",
            "You won by sustaining more pressure than this build usually produces in the same context, even if the fight was not a perfect burst conversion.",
            string.format("Pressure %.1f vs %.1f build norm over %d sessions", session.metrics.pressureScore or 0, buildBaseline.averagePressureScore or 0, buildBaseline.fights or 0)
    end

    if (session.metrics.procWindowsObserved or 0) >= 3 and (session.metrics.procWindowCastCount or 0) < math.max(2, session.metrics.procWindowsObserved or 0) then
        return
            "medium",
            "Fight Story",
            "Momentum windows showed up, but the follow-through inside those windows was lighter than the fight needed.",
            string.format("Proc windows %d | casts inside %d | first go %s", session.metrics.procWindowsObserved or 0, session.metrics.procWindowCastCount or 0, (openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt) and string.format("%.1fs", openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt) or "--")
    end

    if session.result == ns.Constants.SESSION_RESULT.WON then
        return
            "low",
            "Fight Story",
            "This session looks stable rather than flashy: you kept output flowing well enough to win the exchange without a major collapse.",
            string.format("Damage %s | taken %s | survivability %.1f", ns.Helpers.FormatNumber(session.totals.damageDone or 0), ns.Helpers.FormatNumber(session.totals.damageTaken or 0), session.metrics.survivabilityScore or 0)
    end

    return
        "medium",
        "Fight Story",
        "This session ended without one single obvious failure point, so the cleaner read is to review opener pacing and first trade timing together.",
        string.format("Opener %s | first offensive %s | first defensive %s", ns.Helpers.FormatNumber(session.metrics.openerDamage or 0), (openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt) and string.format("%.1fs", openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt) or "--", (openerFingerprint.firstMajorDefensiveRelative or openerFingerprint.firstMajorDefensiveAt) and string.format("%.1fs", openerFingerprint.firstMajorDefensiveRelative or openerFingerprint.firstMajorDefensiveAt) or "--")
end

local function buildMatchupCard(store, session, characterKey)
    local opponentKey = session.primaryOpponent and (session.primaryOpponent.guid or session.primaryOpponent.name) or nil
    local contextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
    local buildHash = session.playerSnapshot and session.playerSnapshot.buildHash or "unknown"

    if not opponentKey then
        return
            "low",
            "Matchup Memory",
            "This session does not have a stable opponent identity yet, so matchup memory is intentionally held back.",
            "Need a recognizable opponent or spec bucket before history can say something useful."
    end

    local matchupBaseline = store:GetSessionBaseline(buildHash, contextKey, opponentKey, session.id, characterKey)
    local opponentBaseline = store:GetOpponentBaseline(opponentKey, session.id, characterKey)
    local minimumSamples = getInsightRule("minimumMatchupSamples", 3)

    if matchupBaseline and matchupBaseline.fights >= minimumSamples then
        local body = "This matchup trend on this character looks fairly stable."
        if (matchupBaseline.losses or 0) > (matchupBaseline.wins or 0) then
            body = "This matchup trend on this character is leaning defensive, so survivability and first-trade timing look like the bigger review target."
        elseif (matchupBaseline.averageOpenerDamage or 0) > 0 and (session.metrics.openerDamage or 0) < (matchupBaseline.averageOpenerDamage or 0) then
            body = "You have enough same-build history here to judge the opener cleanly, and this pull started below your usual pace."
        end

        return
            "low",
            "Matchup Memory",
            body,
            string.format("Fights %d | W-L %d-%d | avg opener %s | avg first go %s | avg duration %s", matchupBaseline.fights or 0, matchupBaseline.wins or 0, matchupBaseline.losses or 0, ns.Helpers.FormatNumber(matchupBaseline.averageOpenerDamage or 0), matchupBaseline.averageFirstMajorOffensiveAt and string.format("%.1fs", matchupBaseline.averageFirstMajorOffensiveAt) or "--", ns.Helpers.FormatDuration(matchupBaseline.averageDuration or 0))
    end

    if opponentBaseline and opponentBaseline.fights >= minimumSamples then
        return
            "low",
            "Matchup Memory",
            "You have opponent history on this character, but not enough same-build samples yet for a sharper matchup read.",
            string.format("Opponent fights %d | avg taken %s | avg duration %s", opponentBaseline.fights or 0, ns.Helpers.FormatNumber(opponentBaseline.averageDamageTaken or 0), ns.Helpers.FormatDuration(opponentBaseline.averageDuration or 0))
    end

    return
        "low",
        "Matchup Memory",
        "Need a few more same-character sessions before this section can tell whether the matchup is output-limited or survival-limited.",
        "Three similar sessions is the minimum before matchup memory becomes meaningful."
end

-- ---------------------------------------------------------------------------
-- T077: Extract compact one-line key-data points from the fight story evidence
-- ---------------------------------------------------------------------------
local function extractStoryPills(storyEvidence)
    if not storyEvidence or storyEvidence == "" then
        return {}
    end
    local pills = {}
    -- Pull key=value pairs separated by "|"
    for segment in storyEvidence:gmatch("[^|]+") do
        local trimmed = segment:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            pills[#pills + 1] = trimmed
        end
    end
    return pills
end

-- ---------------------------------------------------------------------------
-- T077: Check whether a suggestion's reasonCode passes the active filter
-- ---------------------------------------------------------------------------
local function passesFilter(activeFilter, reasonCode)
    if activeFilter == "all" then
        return true
    end
    local category = REASON_TO_CATEGORY[reasonCode]
    return category == activeFilter
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
function SuggestionsView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.activeFilter = "all"

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Actionable Insights", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Post-fight review for the current character: trust first, then fight story, matchup memory, and coaching notes.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 96)
    self.emptyCard:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)

    -- -----------------------------------------------------------------------
    -- Trust card + severity bar + confidence pill
    -- -----------------------------------------------------------------------
    self.trustCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)
    self.trustCard:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)

    self.trustSeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)
    self.trustSeverityBar:SetPoint("TOPLEFT", self.trustCard, "BOTTOMLEFT", 0, -4)

    self.trustConfidencePill = ns.Widgets.CreateConfidencePill(self.canvas, "estimated")
    self.trustConfidencePill:SetPoint("TOPLEFT", self.trustSeverityBar, "BOTTOMLEFT", 0, -4)

    -- -----------------------------------------------------------------------
    -- Story card + severity bar + compact pill strip
    -- -----------------------------------------------------------------------
    self.storyCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)
    self.storyCard:SetPoint("TOPLEFT", self.trustConfidencePill, "BOTTOMLEFT", 0, -10)

    self.storySeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)
    self.storySeverityBar:SetPoint("TOPLEFT", self.storyCard, "BOTTOMLEFT", 0, -4)

    -- T065: Degraded import banner — shown when session.metrics.degradedImport is set
    self.degradedImportBanner = ns.Widgets.CreateInsightCard(self.canvas, 750, 68)
    self.degradedImportBanner:SetPoint("TOPLEFT", self.storySeverityBar, "BOTTOMLEFT", 0, -4)
    self.degradedImportBanner:Hide()

    -- Compact fight-story pill strip (populated in Refresh)
    self.storyPillFrame = CreateFrame("Frame", nil, self.canvas)
    self.storyPillFrame:SetSize(750, 22)
    self.storyPillFrame:SetPoint("TOPLEFT", self.storySeverityBar, "BOTTOMLEFT", 0, -4)
    self.storyPills = {}

    -- -----------------------------------------------------------------------
    -- Matchup card + severity bar
    -- -----------------------------------------------------------------------
    self.matchupCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)
    self.matchupCard:SetPoint("TOPLEFT", self.storyPillFrame, "BOTTOMLEFT", 0, -10)

    self.matchupSeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)
    self.matchupSeverityBar:SetPoint("TOPLEFT", self.matchupCard, "BOTTOMLEFT", 0, -4)

    -- -----------------------------------------------------------------------
    -- Category filter bar for coaching notes
    -- -----------------------------------------------------------------------
    self.filterFrame = CreateFrame("Frame", nil, self.canvas)
    self.filterFrame:SetSize(750, 28)
    self.filterFrame:SetPoint("TOPLEFT", self.matchupSeverityBar, "BOTTOMLEFT", 0, -22)

    self.filterButtons = {}
    local filterXOffset = 0
    for i, def in ipairs(CATEGORY_FILTERS) do
        local btnWidth = #def.label * 8 + 20
        local btn = ns.Widgets.CreateButton(self.filterFrame, def.label, btnWidth, 24)
        btn:SetPoint("TOPLEFT", self.filterFrame, "TOPLEFT", filterXOffset, 0)
        btn.filterKey = def.key
        btn:SetActive(def.key == "all")
        btn:SetScript("OnClick", function()
            self.activeFilter = def.key
            for _, other in ipairs(self.filterButtons) do
                other:SetActive(other.filterKey == self.activeFilter)
            end
            self:Refresh()
        end)
        self.filterButtons[i] = btn
        filterXOffset = filterXOffset + btnWidth + 6
    end

    -- -----------------------------------------------------------------------
    -- Recent coaching notes section title + caption
    -- -----------------------------------------------------------------------
    self.recentTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Recent Coaching Notes", "TOPLEFT", self.filterFrame, "BOTTOMLEFT", 0, -14)
    self.recentCaption = ns.Widgets.CreateCaption(self.canvas, "Rules-backed notes from recent sessions on this character, newest first.", "TOPLEFT", self.recentTitle, "BOTTOMLEFT", 0, -4)

    -- -----------------------------------------------------------------------
    -- Coaching note cards with per-card severity bars
    -- -----------------------------------------------------------------------
    self.cards = {}
    self.cardSeverityBars = {}
    for index = 1, 8 do
        local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 108)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.recentCaption, "BOTTOMLEFT", 0, -12)
        else
            card:SetPoint("TOPLEFT", self.cardSeverityBars[index - 1], "BOTTOMLEFT", 0, -10)
        end
        self.cards[index] = card

        local severityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 28)
        severityBar:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -2)
        self.cardSeverityBars[index] = severityBar
    end

    -- Strategy Spotlight section
    self.strategyTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Strategy Spotlight", "TOPLEFT", self.cardSeverityBars[#self.cardSeverityBars], "BOTTOMLEFT", 0, -22)
    self.strategyCaption = ns.Widgets.CreateCaption(self.canvas, "Counter guide for the spec you faced most recently.", "TOPLEFT", self.strategyTitle, "BOTTOMLEFT", 0, -4)

    self.strategyCard = CreateFrame("Frame", nil, self.canvas, "BackdropTemplate")
    self.strategyCard:SetSize(750, 180)
    self.strategyCard:SetPoint("TOPLEFT", self.strategyCaption, "BOTTOMLEFT", 0, -12)
    ns.Widgets.ApplyBackdrop(self.strategyCard, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)

    self.strategyCard.specLabel = self.strategyCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.strategyCard.specLabel:SetPoint("TOPLEFT", self.strategyCard, "TOPLEFT", 12, -12)
    self.strategyCard.specLabel:SetJustifyH("LEFT")
    self.strategyCard.specLabel:SetTextColor(unpack(ns.Widgets.THEME.accent))

    self.strategyCard.ccLabel = self.strategyCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.strategyCard.ccLabel:SetPoint("TOPLEFT", self.strategyCard.specLabel, "BOTTOMLEFT", 0, -6)
    self.strategyCard.ccLabel:SetPoint("RIGHT", self.strategyCard, "RIGHT", -12, 0)
    self.strategyCard.ccLabel:SetJustifyH("LEFT")
    self.strategyCard.ccLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))

    self.strategyCard.threatLabel = self.strategyCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.strategyCard.threatLabel:SetPoint("TOPLEFT", self.strategyCard.ccLabel, "BOTTOMLEFT", 0, -6)
    self.strategyCard.threatLabel:SetPoint("RIGHT", self.strategyCard, "RIGHT", -12, 0)
    self.strategyCard.threatLabel:SetJustifyH("LEFT")
    self.strategyCard.threatLabel:SetTextColor(unpack(ns.Widgets.THEME.warning))

    self.strategyCard.actions = self.strategyCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.strategyCard.actions:SetPoint("TOPLEFT", self.strategyCard.threatLabel, "BOTTOMLEFT", 0, -8)
    self.strategyCard.actions:SetPoint("RIGHT", self.strategyCard, "RIGHT", -12, 0)
    self.strategyCard.actions:SetJustifyH("LEFT")
    self.strategyCard.actions:SetJustifyV("TOP")
    self.strategyCard.actions:SetTextColor(unpack(ns.Widgets.THEME.text))

    self.strategyCard.winRate = self.strategyCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.strategyCard.winRate:SetPoint("BOTTOMLEFT", self.strategyCard, "BOTTOMLEFT", 12, 10)
    self.strategyCard.winRate:SetPoint("RIGHT", self.strategyCard, "RIGHT", -12, 0)
    self.strategyCard.winRate:SetJustifyH("LEFT")
    self.strategyCard.winRate:SetTextColor(unpack(ns.Widgets.THEME.textMuted))

    self.strategyEmpty = ns.Widgets.CreateInsightCard(self.canvas, 750, 72)
    self.strategyEmpty:SetPoint("TOPLEFT", self.strategyCaption, "BOTTOMLEFT", 0, -12)

    -- -----------------------------------------------------------------------
    -- T105: Opener Lab section
    -- -----------------------------------------------------------------------
    self.openerLabSection = CreateFrame("Frame", nil, self.canvas, "BackdropTemplate")
    ns.Widgets.ApplyBackdrop(self.openerLabSection, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)
    self.openerLabSection:SetSize(750, 200)

    self.openerLabTitle = self.openerLabSection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.openerLabTitle:SetPoint("TOPLEFT", self.openerLabSection, "TOPLEFT", 12, -10)
    self.openerLabTitle:SetTextColor(unpack(ns.Widgets.THEME.text))
    self.openerLabTitle:SetText("Opener Lab")

    self.openerLabSequence = self.openerLabSection:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.openerLabSequence:SetPoint("TOPLEFT", self.openerLabTitle, "BOTTOMLEFT", 0, -8)
    self.openerLabSequence:SetPoint("RIGHT", self.openerLabSection, "RIGHT", -12, 0)
    self.openerLabSequence:SetJustifyH("LEFT")
    self.openerLabSequence:SetTextColor(unpack(ns.Widgets.THEME.text))

    self.openerLabRankTitle = self.openerLabSection:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.openerLabRankTitle:SetPoint("TOPLEFT", self.openerLabSequence, "BOTTOMLEFT", 0, -10)
    self.openerLabRankTitle:SetJustifyH("LEFT")
    self.openerLabRankTitle:SetTextColor(unpack(ns.Widgets.THEME.accent))

    self.openerLabRows = {}
    for rowIdx = 1, 3 do
        local row = {}
        row.bar = ns.Widgets.CreateMetricBar(self.openerLabSection, 710, 22)
        if rowIdx == 1 then
            row.bar:SetPoint("TOPLEFT", self.openerLabRankTitle, "BOTTOMLEFT", 0, -6)
        else
            row.bar:SetPoint("TOPLEFT", self.openerLabRows[rowIdx - 1].bar, "BOTTOMLEFT", 0, -4)
        end
        self.openerLabRows[rowIdx] = row
    end

    self.openerLabSection:Hide()

    -- -----------------------------------------------------------------------
    -- T112: Practice Plan section
    -- -----------------------------------------------------------------------
    self.practicePlanTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Practice Plan", "TOPLEFT", self.openerLabSection, "BOTTOMLEFT", 0, -22)
    self.practicePlanCaption = ns.Widgets.CreateCaption(self.canvas, "Actionable practice drills derived from your recent performance patterns.", "TOPLEFT", self.practicePlanTitle, "BOTTOMLEFT", 0, -4)

    self.practicePlanCards = {}
    self.practicePlanBars = {}
    for ppIdx = 1, 10 do
        local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 108)
        if ppIdx == 1 then
            card:SetPoint("TOPLEFT", self.practicePlanCaption, "BOTTOMLEFT", 0, -12)
        else
            card:SetPoint("TOPLEFT", self.practicePlanBars[ppIdx - 1], "BOTTOMLEFT", 0, -10)
        end
        self.practicePlanCards[ppIdx] = card

        local bar = ns.Widgets.CreateMetricBar(self.canvas, 750, 28)
        bar:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -2)
        self.practicePlanBars[ppIdx] = bar
    end

    self.practicePlanTitle:Hide()
    self.practicePlanCaption:Hide()

    ns.Widgets.SetCanvasHeight(self.canvas, 1900)
    return self.frame
end

-- ---------------------------------------------------------------------------
-- Helper: configure a severity MetricBar for a given severity level
-- ---------------------------------------------------------------------------
local function setSeverityBar(bar, severity, label)
    local fill = SEVERITY_FILL[severity] or 0.2
    local color = SEVERITY_BAR_COLORS[severity] or SEVERITY_BAR_COLORS.low
    local severityLabel = (severity == "high" and "HIGH") or (severity == "medium" and "MED") or "LOW"
    bar:SetData(
        label or "Severity",
        severityLabel,
        "",
        fill,
        color
    )
end

-- ---------------------------------------------------------------------------
-- Helper: rebuild the fight-story pill strip
-- ---------------------------------------------------------------------------
local function refreshStoryPills(self, storyEvidence)
    -- Hide existing pills
    for _, pill in ipairs(self.storyPills) do
        pill:Hide()
    end

    local segments = extractStoryPills(storyEvidence)
    if #segments == 0 then
        self.storyPillFrame:SetSize(750, 1)
        return
    end

    local xOffset = 0
    for i, text in ipairs(segments) do
        local pill = self.storyPills[i]
        if not pill then
            pill = ns.Widgets.CreatePill(self.storyPillFrame, 10, 18, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)
            self.storyPills[i] = pill
        end
        -- Size pill to text width (estimate: ~6px per character + 16 padding)
        local pillWidth = math.max(50, #text * 6 + 16)
        pill:SetSize(pillWidth, 18)
        pill:ClearAllPoints()
        pill:SetPoint("TOPLEFT", self.storyPillFrame, "TOPLEFT", xOffset, 0)
        pill:SetData(text)
        pill:Show()
        xOffset = xOffset + pillWidth + 6
    end

    self.storyPillFrame:SetSize(750, 22)
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function SuggestionsView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store:GetCurrentCharacterKey()
    local latestSession = store:GetLatestSession(characterKey)
    local suggestions = store:GetRecentSuggestions(100, characterKey)
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end

    -- Default-hide practice plan; the end of Refresh will show it if applicable
    self.practicePlanTitle:Hide()
    self.practicePlanCaption:Hide()
    for _, ppCard in ipairs(self.practicePlanCards) do ppCard:Hide() end
    for _, ppBar in ipairs(self.practicePlanBars) do ppBar:Hide() end

    if not latestSession and #suggestions == 0 then
        self.emptyCard:SetData(
            "low",
            "No insights yet",
            "Once this character has a few fights stored, this tab will surface trust, fight story, matchup memory, and coaching notes.",
            "Dummy sessions help seed opener baselines; duels and arena rounds make the story cards stronger."
        )
        self.emptyCard:Show()
        self.trustCard:Hide()
        self.trustSeverityBar:Hide()
        self.trustConfidencePill:Hide()
        self.storyCard:Hide()
        self.storySeverityBar:Hide()
        self.degradedImportBanner:Hide()
        self.storyPillFrame:Hide()
        self.matchupCard:Hide()
        self.matchupSeverityBar:Hide()
        self.filterFrame:Hide()
        self.recentTitle:Hide()
        self.recentCaption:Hide()
        for _, card in ipairs(self.cards) do
            card:Hide()
        end
        for _, bar in ipairs(self.cardSeverityBars) do
            bar:Hide()
        end
        self.strategyTitle:Hide()
        self.strategyCaption:Hide()
        self.strategyCard:Hide()
        self.strategyEmpty:Hide()
        return
    end

    self.emptyCard:Hide()
    self.filterFrame:Show()
    self.recentTitle:Show()
    self.recentCaption:Show()

    if latestSession then
        self.caption:SetText(string.format("Post-fight review for %s. Trust first, then fight story, matchup memory, and coaching notes.", store:GetSessionCharacterLabel(latestSession)))

        -- Trust card + severity bar + confidence pill
        local trustSeverity, trustTitle, trustBody, trustEvidence = buildTrustCard(store, latestSession)
        self.trustCard:SetData(trustSeverity, trustTitle, trustBody, trustEvidence)
        setSeverityBar(self.trustSeverityBar, trustSeverity, "Trust Level")
        self.trustSeverityBar:Show()

        -- Confidence pill — session-level confidence from the session itself.
        -- Reuse the existing pill frame via SetConfidence to avoid frame leaks.
        local sessionConfidence = latestSession.sessionConfidence or latestSession.dataConfidence or "estimated"
        self.trustConfidencePill:SetConfidence(sessionConfidence)
        self.trustConfidencePill:Show()

        -- T065: Show degraded import banner when damage data is incomplete.
        -- Metric scores preceded by "~" in evidence text when banner is visible.
        local metrics = latestSession.metrics or {}
        local degradedImport = metrics.degradedImport
        if degradedImport then
            local bannerBody = degradedImport == "partial"
                and "Damage import used an estimated fallback — pressure and burst scores may under-report by 5–20%."
                or  "Damage import failed for this session — pressure, burst, and survivability scores are based on cast estimates only."
            self.degradedImportBanner:SetData(
                "medium",
                degradedImport == "partial" and "~Scores approximate" or "~Scores unreliable",
                bannerBody,
                "Score is approximate — damage import was incomplete."
            )
            self.degradedImportBanner:SetPoint("TOPLEFT", self.storySeverityBar, "BOTTOMLEFT", 0, -4)
            self.degradedImportBanner:Show()
        else
            self.degradedImportBanner:Hide()
        end
        local storyAnchor = degradedImport and self.degradedImportBanner or self.storySeverityBar

        -- Story card + severity bar + pill strip
        local storySeverity, storyTitle, storyBody, storyEvidence = buildFightStory(store, latestSession, characterKey)
        self.storyCard:SetData(storySeverity, storyTitle, storyBody, storyEvidence)
        -- Re-anchor story card below the confidence pill (or degraded banner)
        self.storyCard:ClearAllPoints()
        self.storyCard:SetPoint("TOPLEFT", self.trustConfidencePill, "BOTTOMLEFT", 0, -10)
        setSeverityBar(self.storySeverityBar, storySeverity, "Story Severity")
        self.storySeverityBar:Show()
        -- Re-anchor pill strip and degraded banner relative to story severity bar
        self.storyPillFrame:ClearAllPoints()
        self.storyPillFrame:SetPoint("TOPLEFT", storyAnchor, "BOTTOMLEFT", 0, -4)
        refreshStoryPills(self, storyEvidence)
        self.storyPillFrame:Show()

        -- Matchup card + severity bar
        local matchupSeverity, matchupTitle, matchupBody, matchupEvidence = buildMatchupCard(store, latestSession, characterKey)
        self.matchupCard:SetData(matchupSeverity, matchupTitle, matchupBody, matchupEvidence)
        setSeverityBar(self.matchupSeverityBar, matchupSeverity, "Matchup Signal")
        self.matchupSeverityBar:Show()

        self.trustCard:Show()
        self.storyCard:Show()
        self.matchupCard:Show()
    else
        self.caption:SetText("Post-fight review for the current character: trust first, then fight story, matchup memory, and coaching notes.")
        self.trustCard:Hide()
        self.trustSeverityBar:Hide()
        self.trustConfidencePill:Hide()
        self.storyCard:Hide()
        self.storySeverityBar:Hide()
        self.degradedImportBanner:Hide()
        self.storyPillFrame:Hide()
        self.matchupCard:Hide()
        self.matchupSeverityBar:Hide()
    end

    -- -----------------------------------------------------------------------
    -- Coaching notes — apply category filter
    -- -----------------------------------------------------------------------
    local filtered = {}
    for _, suggestion in ipairs(suggestions) do
        if passesFilter(self.activeFilter, suggestion.reasonCode) then
            filtered[#filtered + 1] = suggestion
        end
    end

    local visibleCount = 0
    for index, card in ipairs(self.cards) do
        local severityBar = self.cardSeverityBars[index]
        local suggestion = filtered[index]
        if suggestion then
            local session = store:GetCombatById(suggestion.sessionId)
            card:SetData(
                suggestion.severity,
                SUGGESTION_TITLES[suggestion.reasonCode] or (suggestion.message or "Insight"),
                string.format("%s\n%s", suggestion.message or "", buildSessionTag(session)),
                buildEvidenceText(suggestion)
            )
            setSeverityBar(severityBar, suggestion.severity, REASON_TO_CATEGORY[suggestion.reasonCode] or "note")
            card:Show()
            severityBar:Show()
            visibleCount = visibleCount + 1
        elseif index == 1 and #filtered == 0 then
            -- Show a placeholder when no coaching notes match the active filter
            local noMatchMsg = self.activeFilter == "all"
                and "The latest sessions on this character did not trip any recent rule-based warnings, which usually means the trust/story cards are the better place to review."
                or string.format("No coaching notes match the '%s' filter. Try 'All' to see every note.", self.activeFilter)
            card:SetData(
                "low",
                "No fresh coaching notes",
                noMatchMsg,
                latestSession and buildSessionTag(latestSession) or "Collect another duel, arena round, or dummy pull for more notes."
            )
            setSeverityBar(severityBar, "low", "note")
            card:Show()
            severityBar:Show()
            visibleCount = 1
        else
            card:Hide()
            severityBar:Hide()
        end
    end

    -- -----------------------------------------------------------------------
    -- Re-anchor strategy section below the last visible coaching card
    -- -----------------------------------------------------------------------
    local lastVisibleBar = self.cardSeverityBars[math.max(1, visibleCount)]
    self.strategyTitle:ClearAllPoints()
    self.strategyTitle:SetPoint("TOPLEFT", lastVisibleBar, "BOTTOMLEFT", 0, -22)

    -- Strategy Spotlight
    self.strategyTitle:Show()
    self.strategyCaption:Show()

    local specBuckets = store:GetAggregateBuckets("specs")
    local totalFights = 0
    for _, bucket in ipairs(specBuckets) do
        totalFights = totalFights + (bucket.fights or 0)
    end

    if totalFights < 3 then
        self.strategyCard:Hide()
        self.strategyEmpty:SetData(
            "low",
            "Not enough data yet",
            "Complete more sessions to unlock strategy insights.",
            string.format("%d sessions recorded so far — need at least 3.", totalFights)
        )
        self.strategyEmpty:Show()
        self:RecalculateCanvasHeight()
        return
    end

    self.strategyEmpty:Hide()

    local topBucket = specBuckets[1]
    if not topBucket then
        self.strategyCard:Hide()
        self:RecalculateCanvasHeight()
        return
    end

    local topSpecId = tonumber(topBucket.key)
    local strategyEngine = ns.Addon:GetModule("StrategyEngine")
    local guide = strategyEngine and strategyEngine.GetCounterGuide and strategyEngine.GetCounterGuide(topSpecId, nil, characterKey) or nil

    if not guide then
        self.strategyCard:Hide()
        self:RecalculateCanvasHeight()
        return
    end

    -- Spec name + archetype
    local specDisplay = guide.specName or topBucket.label or tostring(topSpecId)
    local archetypeDisplay = guide.archetypeLabel or "unknown"
    self.strategyCard.specLabel:SetText(string.format("%s  (%s)", specDisplay, archetypeDisplay))

    -- CC families (each entry is { spellId, family }; deduplicate family names)
    local ccText = ""
    if guide.ccFamilies and #guide.ccFamilies > 0 then
        local seen = {}
        local familyNames = {}
        for _, entry in ipairs(guide.ccFamilies) do
            local name = type(entry) == "table" and entry.family or tostring(entry)
            if name and not seen[name] then
                seen[name] = true
                familyNames[#familyNames + 1] = name
            end
        end
        if #familyNames > 0 then
            ccText = "CC: " .. table.concat(familyNames, ", ")
        end
    end
    self.strategyCard.ccLabel:SetText(ccText)

    -- Threat tags
    local threatText = ""
    if guide.threatTags and #guide.threatTags > 0 then
        threatText = "Threats: " .. table.concat(guide.threatTags, ", ")
    end
    self.strategyCard.threatLabel:SetText(threatText)

    -- Recommended actions (up to 3 bullets)
    local actionLines = {}
    for i, action in ipairs(guide.recommendedActions or {}) do
        if i > 3 then break end
        actionLines[#actionLines + 1] = string.format("- %s", action)
    end
    self.strategyCard.actions:SetText(table.concat(actionLines, "\n"))

    -- Historical win rate
    if guide.historicalWinRate and guide.historicalFights and guide.historicalFights > 0 then
        self.strategyCard.winRate:SetText(string.format("Win rate: %.0f%% across %d fights", guide.historicalWinRate * 100, guide.historicalFights))
    else
        self.strategyCard.winRate:SetText("")
    end

    self.strategyCard:Show()

    -- -----------------------------------------------------------------------
    -- T112: Practice Plan section
    -- -----------------------------------------------------------------------
    local ppOk, ppSuggestions = pcall(function()
        local planner = ns.Addon:GetModule("PracticePlannerService")
        if not planner or not planner.GeneratePracticePlan then return {} end
        local aggregates = store:GetAggregateBuckets("specs")
        local recent = store.GetRecentSessions and store:GetRecentSessions(20, characterKey) or {}
        return planner:GeneratePracticePlan(aggregates, recent) or {}
    end)
    if not ppOk then ppSuggestions = {} end

    -- Anchor the practice plan section below the visible strategy element
    local ppAnchor = self.strategyCard:IsShown() and self.strategyCard
        or (self.strategyEmpty:IsShown() and self.strategyEmpty or self.strategyCaption)

    if ppSuggestions and #ppSuggestions > 0 then
        self.practicePlanTitle:ClearAllPoints()
        self.practicePlanTitle:SetPoint("TOPLEFT", ppAnchor, "BOTTOMLEFT", 0, -22)
        self.practicePlanTitle:Show()
        self.practicePlanCaption:Show()

        local ppVisible = math.min(#ppSuggestions, 10)
        for ppIdx = 1, 10 do
            local ppCard = self.practicePlanCards[ppIdx]
            local ppBar = self.practicePlanBars[ppIdx]
            local item = ppSuggestions[ppIdx]
            if item and ppIdx <= ppVisible then
                local categoryLabel = item.category or "general"
                local sev = item.severity or "low"
                ppCard:SetData(
                    sev,
                    item.title or "Practice Drill",
                    string.format("%s\n%s", item.action or "", item.evidence or ""),
                    string.format("Category: %s | %s", categoryLabel, item.linkedMatchup or "")
                )
                setSeverityBar(ppBar, sev, categoryLabel)
                ppCard:Show()
                ppBar:Show()
            else
                ppCard:Hide()
                ppBar:Hide()
            end
        end
    else
        self.practicePlanTitle:Hide()
        self.practicePlanCaption:Hide()
        for _, ppCard in ipairs(self.practicePlanCards) do ppCard:Hide() end
        for _, ppBar in ipairs(self.practicePlanBars) do ppBar:Hide() end
    end

    self:RecalculateCanvasHeight()
end

-- ---------------------------------------------------------------------------
-- Recalculate canvas height based on visible content
-- ---------------------------------------------------------------------------
function SuggestionsView:RecalculateCanvasHeight()
    -- Sum up the approximate heights of all visible sections.
    -- This keeps the scroll canvas tight rather than using a fixed oversize.
    local height = 0

    -- Top section cards (trust + severity + confidence + story + severity + pills + matchup + severity)
    if self.trustCard:IsShown() then
        height = height + 104 + 32 + 22 + 10 + 4 + 4  -- trustCard + bar + pill + spacing
    end
    if self.storyCard:IsShown() then
        height = height + 104 + 32 + 4 + 10  -- storyCard + bar + spacing
        if self.degradedImportBanner:IsShown() then
            height = height + 68 + 4  -- banner height + gap
        end
        if self.storyPillFrame:IsShown() then
            height = height + 22 + 4
        end
    end
    if self.matchupCard:IsShown() then
        height = height + 104 + 32 + 4 + 10  -- matchupCard + bar + spacing
    end

    -- Filter bar
    if self.filterFrame:IsShown() then
        height = height + 28 + 22  -- filterFrame + gap to section title
    end

    -- Recent section header
    if self.recentTitle:IsShown() then
        height = height + 20 + 4 + 12  -- title + caption gap + card gap
    end

    -- Coaching cards
    for i, card in ipairs(self.cards) do
        if card:IsShown() then
            height = height + 108 + 28 + 2 + 10  -- card + severityBar + gaps
        end
    end

    -- Strategy section
    if self.strategyTitle:IsShown() then
        height = height + 22 + 20 + 4 + 12  -- gap + title + caption gap + card gap
        if self.strategyCard:IsShown() then
            height = height + 180
        elseif self.strategyEmpty:IsShown() then
            height = height + 72
        end
    end

    -- Opener Lab section
    if self.openerLabSection and self.openerLabSection:IsShown() then
        height = height + 200 + 22 + 20 + 4 + 12  -- section + gap + title + caption + card gap
    end

    -- Practice Plan section
    if self.practicePlanTitle:IsShown() then
        height = height + 22 + 20 + 4 + 12  -- gap + title + caption gap + card gap
        for _, ppCard in ipairs(self.practicePlanCards) do
            if ppCard:IsShown() then
                height = height + 108 + 28 + 2 + 10  -- card + bar + gaps
            end
        end
    end

    -- Add some bottom padding
    height = height + 40

    ns.Widgets.SetCanvasHeight(self.canvas, math.max(height, 400))
end

ns.Addon:RegisterModule("SuggestionsView", SuggestionsView)
