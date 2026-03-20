local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local SummaryView = {
    viewId = "summary",
}

local SUGGESTION_TITLES = {
    LOW_PRESSURE_VS_BUILD_BASELINE = "Output landed below your usual build baseline",
    WEAK_BURST_FOR_CONTEXT = "Burst pressure was lighter than normal for this matchup",
    DEFENSIVE_UNUSED_ON_LOSS = "Major defensive trade was left unused",
    HIGH_DAMAGE_TAKEN_VS_OPPONENT = "This opponent pressured you harder than usual",
    DUMMY_OPENER_VARIANCE = "Opener landed below your dummy benchmark",
    DUMMY_SUSTAINED_VARIANCE = "Sustained dummy damage is below your benchmark",
    ROTATION_GAPS_OBSERVED = "Successful casts had dead air between them",
    PROC_WINDOWS_UNDERUSED = "Proc-like buff windows were not converted cleanly",
    LATE_FIRST_GO = "First major go started later than usual",
    DEFENSIVE_DRIFT = "Defensive timing drifted later than your norm",
    MIDNIGHT_SAFE_LIMITS = "Timing detail is limited on Midnight-safe mode",
    RAW_EVENT_OVERFLOW = "Raw event storage hit its emergency cap",
    DIED_IN_CC = "You died while crowd-controlled",
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
}

local function formatPercent(value)
    return string.format("%.1f%%", tonumber(value) or 0)
end

local function formatItemLevel(value)
    local numeric = tonumber(value)
    if not numeric or numeric <= 0 then
        return "--"
    end
    return string.format("%.1f", numeric)
end

local function buildSpellRows(session, limit)
    local rows = {}
    local totalOutput = math.max((session.totals.damageDone or 0) + (session.totals.healingDone or 0), 1)

    for spellId, aggregate in pairs(session.spells or {}) do
        local amount = (aggregate.totalDamage or 0) + (aggregate.totalHealing or 0)
        if amount > 0 or (aggregate.castCount or 0) > 0 then
            local spellInfo = ns.ApiCompat.GetSpellInfo(spellId) or {}
            rows[#rows + 1] = {
                spellId = spellId,
                name = aggregate.name or spellInfo.name or (spellId == 0 and "Environmental") or string.format("Unknown Spell (%s)", tostring(spellId)),
                icon = aggregate.iconID or spellInfo.iconID,
                amount = amount,
                damage = aggregate.totalDamage or 0,
                healing = aggregate.totalHealing or 0,
                casts = aggregate.castCount or 0,
                hits = aggregate.hitCount or 0,
                share = amount / totalOutput,
            }
        end
    end

    table.sort(rows, function(left, right)
        return left.amount > right.amount
    end)

    while #rows > (limit or 6) do
        table.remove(rows)
    end

    return rows
end

local function buildSuggestionEvidence(suggestion)
    local evidence = suggestion.evidence or {}

    if suggestion.reasonCode == "LOW_PRESSURE_VS_BUILD_BASELINE" then
        return string.format("Pressure %.1f vs %.1f baseline across %d build sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "WEAK_BURST_FOR_CONTEXT" then
        return string.format("Burst %.1f vs %.1f context average across %d sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "DEFENSIVE_UNUSED_ON_LOSS" then
        return string.format("Unused defensives: %d. Deaths: %d.", evidence.unusedDefensives or 0, evidence.deaths or 0)
    end
    if suggestion.reasonCode == "HIGH_DAMAGE_TAKEN_VS_OPPONENT" then
        return string.format("Taken %s vs %s usual incoming damage across %d fights.", Helpers.FormatNumber(evidence.current or 0), Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "DUMMY_OPENER_VARIANCE" then
        return string.format("Opener %s vs %s dummy average across %d samples.", Helpers.FormatNumber(evidence.current or 0), Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "DUMMY_SUSTAINED_VARIANCE" then
        return string.format("Sustained %s vs %s dummy benchmark across %d samples.", Helpers.FormatNumber(evidence.current or 0), Helpers.FormatNumber(evidence.baseline or 0), evidence.samples or 0)
    end
    if suggestion.reasonCode == "ROTATION_GAPS_OBSERVED" then
        return string.format("Casts observed: %d. Idle time: %.1fs. Rotation score: %.1f.", evidence.casts or 0, evidence.idleSeconds or 0, evidence.rotationScore or 0)
    end
    if suggestion.reasonCode == "PROC_WINDOWS_UNDERUSED" then
        return string.format("Proc-like windows: %d. Casts inside windows: %d.", evidence.procWindows or 0, evidence.castsDuringWindows or 0)
    end
    if suggestion.reasonCode == "LATE_FIRST_GO" then
        return string.format("First major go at %.1fs vs %.1fs usual timing across %d sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "DEFENSIVE_DRIFT" then
        return string.format("First defensive at %.1fs vs %.1fs norm. Damage taken: %s.", evidence.current or 0, evidence.baseline or 0, Helpers.FormatNumber(evidence.damageTaken or 0))
    end
    if suggestion.reasonCode == "MIDNIGHT_SAFE_LIMITS" then
        return "Built from Blizzard's post-combat Damage Meter totals, not raw combat log events."
    end
    if suggestion.reasonCode == "RAW_EVENT_OVERFLOW" then
        return string.format("Stored %d raw events against a cap of %d.", evidence.rawEvents or 0, evidence.max or 0)
    end
    if suggestion.reasonCode == "DIED_IN_CC" then
        return string.format("CC spell ID %d. Burst damage taken: %s from %d sources.", evidence.ccSpellId or 0, Helpers.FormatNumber(evidence.totalBurstDamage or 0), evidence.killingSpellCount or 0)
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

    if evidence.samples then
        return string.format("Backed by %d stored sessions.", evidence.samples)
    end

    return "Based on your stored session history and current fight snapshot."
end

local function setComparisonRow(row, title, description, current, expected, formatter, goodWhenLower)
    if not expected or expected <= 0 then
        row:Hide()
        return false
    end

    local scaleMax = math.max(current or 0, expected, expected * 1.25, 1)
    local percent = (current or 0) / scaleMax
    local marker = expected / scaleMax
    local delta = expected > 0 and (((current or 0) - expected) / expected) * 100 or 0
    local favorable = goodWhenLower and (current or 0) <= expected or (not goodWhenLower and (current or 0) >= expected)
    local color = favorable and Theme.success or Theme.warning
    local deltaText = string.format("%s current  |  %s expected", formatter(current or 0), formatter(expected))
    local deltaLabel = string.format("%s %.0f%% versus expectation.", goodWhenLower and "Lower is better." or "Higher is better.", delta)

    row:SetData(title, deltaText, string.format("%s %s", description or "", deltaLabel), percent, color, marker)
    row:Show()
    return true
end

local function formatDisplayLabel(value)
    local map = {
        high = "High",
        medium = "Medium",
        limited = "Limited",
        ["local"] = "Local",
        damage_meter = "Damage Meter",
        enemy_damage_taken_fallback = "Enemy Fallback",
        estimated = "Estimated",
    }
    return map[value] or tostring(value or "unknown")
end

function SummaryView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "PvP Performance Dashboard", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.confidenceBadge = ns.Widgets.CreateConfidenceBadge(self.frame, 10)
    self.confidenceBadge:SetPoint("LEFT", self.title, "RIGHT", 8, 0)
    self.confidenceBadge:Hide()
    self.caption = ns.Widgets.CreateCaption(self.frame, "Latest fight translated into explained scores, benchmark bars, and recognizable spell output.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.dummyNotice = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.dummyNotice:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -6)
    self.dummyNotice:SetTextColor(unpack(Theme.warning))
    self.dummyNotice:SetText("Note: Training dummy sessions may not appear reliably on Summary. See the Dummy tab for the most complete dummy-specific analysis.")
    self.dummyNotice:Hide()

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(Theme.textMuted))
    self.emptyState:SetText("No finalized combat sessions yet.")

    self.metricCards = {}
    local cardWidth = 370
    local cardHeight = 92
    for index = 1, 4 do
        local card = ns.Widgets.CreateMetricCard(self.canvas, cardWidth, cardHeight)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        elseif index == 2 then
            card:SetPoint("TOPLEFT", self.metricCards[1], "TOPRIGHT", 10, 0)
        elseif index == 3 then
            card:SetPoint("TOPLEFT", self.metricCards[1], "BOTTOMLEFT", 0, -10)
        else
            card:SetPoint("TOPLEFT", self.metricCards[2], "BOTTOMLEFT", 0, -10)
        end
        self.metricCards[index] = card
    end

    self.scoresTitle = ns.Widgets.CreateSectionTitle(self.canvas, "How To Read The Fight", "TOPLEFT", self.metricCards[3], "BOTTOMLEFT", 0, -22)
    self.scoresCaption = ns.Widgets.CreateCaption(self.canvas, "Each bar explains what the score means for PvP decisions instead of just giving you a number.", "TOPLEFT", self.scoresTitle, "BOTTOMLEFT", 0, -4)

    self.metricBars = {}
    for index = 1, 5 do
        local row = ns.Widgets.CreateMetricBar(self.canvas, 750, 60)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.scoresCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.metricBars[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.metricBars[index] = row
    end

    self.benchmarkTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Benchmark Lens", "TOPLEFT", self.metricBars[#self.metricBars], "BOTTOMLEFT", 0, -22)
    self.benchmarkCaption = ns.Widgets.CreateCaption(self.canvas, "Current fight versus your own historical expectation. The vertical marker is the expected value.", "TOPLEFT", self.benchmarkTitle, "BOTTOMLEFT", 0, -4)

    self.comparisonRows = {}
    for index = 1, 3 do
        local row = ns.Widgets.CreateMetricBar(self.canvas, 750, 60)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.benchmarkCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.comparisonRows[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.comparisonRows[index] = row
    end

    self.spellsTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Top Spells", "TOPLEFT", self.comparisonRows[#self.comparisonRows], "BOTTOMLEFT", 0, -22)
    self.spellsCaption = ns.Widgets.CreateCaption(self.canvas, "Spell icons and contribution bars make it easier to recognize where output really came from.", "TOPLEFT", self.spellsTitle, "BOTTOMLEFT", 0, -4)

    self.spellRows = {}
    for index = 1, 6 do
        local row = ns.Widgets.CreateSpellRow(self.canvas, 750, 46)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.spellsCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.spellRows[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.spellRows[index] = row
    end

    -- Opponent composition panel (arena sessions only).
    self.compTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Enemy Composition", "TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    self.compCaption = ns.Widgets.CreateCaption(self.canvas, "Arena opponent slots with class, spec, and archetype threat profile.", "TOPLEFT", self.compTitle, "BOTTOMLEFT", 0, -4)
    self.compTitle:Hide()
    self.compCaption:Hide()

    self.compSlotRows = {}
    for index = 1, 5 do
        local slotRow = ns.Widgets.CreateSlotRow(self.canvas, 750, 24)
        if index == 1 then
            slotRow:SetPoint("TOPLEFT", self.compCaption, "BOTTOMLEFT", 0, -8)
        else
            slotRow:SetPoint("TOPLEFT", self.compSlotRows[index - 1], "BOTTOMLEFT", 0, -4)
        end
        slotRow:Hide()
        self.compSlotRows[index] = slotRow
    end

    -- BG Objectives section (battleground sessions only).
    self.bgStatsTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Objectives", "TOPLEFT", self.compSlotRows[#self.compSlotRows], "BOTTOMLEFT", 0, -22)
    self.bgStatsCaption = ns.Widgets.CreateCaption(self.canvas, "Battleground objective stats from the post-match scoreboard.", "TOPLEFT", self.bgStatsTitle, "BOTTOMLEFT", 0, -4)
    self.bgStatsTitle:Hide()
    self.bgStatsCaption:Hide()

    self.bgStatRows = {}
    for index = 1, 6 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.bgStatsCaption, "BOTTOMLEFT", 0, -8)
        else
            row:SetPoint("TOPLEFT", self.bgStatRows[index - 1], "BOTTOMLEFT", 0, -4)
        end
        row:SetTextColor(unpack(Theme.text))
        row:Hide()
        self.bgStatRows[index] = row
    end

    -- Post-match scoreboard section (arena/BG rated sessions).
    self.scoreboardTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Match Scoreboard", "TOPLEFT", self.bgStatRows[#self.bgStatRows], "BOTTOMLEFT", 0, -22)
    self.scoreboardCaption = ns.Widgets.CreateCaption(self.canvas, "Per-player stats from the post-match scoreboard.", "TOPLEFT", self.scoreboardTitle, "BOTTOMLEFT", 0, -4)
    self.scoreboardTitle:Hide()
    self.scoreboardCaption:Hide()

    self.scoreboardRows = {}
    for index = 1, 10 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.scoreboardCaption, "BOTTOMLEFT", 0, -8)
        else
            row:SetPoint("TOPLEFT", self.scoreboardRows[index - 1], "BOTTOMLEFT", 0, -3)
        end
        row:SetTextColor(unpack(Theme.text))
        row:Hide()
        self.scoreboardRows[index] = row
    end

    -- Anchor insights below the comp panel (or spells if comp is hidden).
    -- Adjusted dynamically in Refresh.
    self.insightsTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Actionable Insights", "TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    self.insightsCaption = ns.Widgets.CreateCaption(self.canvas, "History-backed takeaways, translated into plain language instead of raw reason codes.", "TOPLEFT", self.insightsTitle, "BOTTOMLEFT", 0, -4)

    self.insightCards = {}
    for index = 1, 4 do
        local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 96)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.insightsCaption, "BOTTOMLEFT", 0, -12)
        else
            card:SetPoint("TOPLEFT", self.insightCards[index - 1], "BOTTOMLEFT", 0, -10)
        end
        self.insightCards[index] = card
    end

    -- Party Sync peer sessions section.
    self.partyTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Party Session Data", "TOPLEFT", self.insightCards[#self.insightCards], "BOTTOMLEFT", 0, -22)
    self.partyCaption = ns.Widgets.CreateCaption(self.canvas, "Summaries received from party members via addon messaging.", "TOPLEFT", self.partyTitle, "BOTTOMLEFT", 0, -4)
    self.partyTitle:Hide()
    self.partyCaption:Hide()

    self.partyPeerRows = {}
    for index = 1, 5 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.partyCaption, "BOTTOMLEFT", 0, -8)
        else
            row:SetPoint("TOPLEFT", self.partyPeerRows[index - 1], "BOTTOMLEFT", 0, -4)
        end
        row:SetTextColor(unpack(Theme.text))
        row:Hide()
        self.partyPeerRows[index] = row
    end

    ns.Widgets.SetCanvasHeight(self.canvas, 1300)
    return self.frame
end

function SummaryView:Refresh(payload)
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store:GetCurrentCharacterKey()
    local requestedSessionId = payload and payload.sessionId or ns.Addon:GetReviewedSession() or ns.Addon.runtime.latestSummarySessionId
    local session = requestedSessionId and store:GetCombatById(requestedSessionId) or nil
    if not session then
        session = store:GetLatestSession(characterKey)
    end
    local isPinnedReview = requestedSessionId ~= nil and session ~= nil and session.id == requestedSessionId
    if payload and payload.sessionId and ns.Addon.SetReviewedSession then
        ns.Addon:SetReviewedSession(payload.sessionId, "summary")
    end
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end
    if not session then
        self.caption:SetText("Latest fight translated into explained scores, benchmark bars, and recognizable spell output.")
        self.emptyState:Show()
        for _, collection in ipairs({ self.metricCards, self.metricBars, self.comparisonRows, self.spellRows, self.insightCards }) do
            for _, widget in ipairs(collection) do
                widget:Hide()
            end
        end
        if self.dummyNotice then
            self.dummyNotice:Hide()
        end
        self.scoresTitle:Hide()
        self.scoresCaption:Hide()
        self.benchmarkTitle:Hide()
        self.benchmarkCaption:Hide()
        self.spellsTitle:Hide()
        self.spellsCaption:Hide()
        self.insightsTitle:Hide()
        self.insightsCaption:Hide()
        if self.compTitle then self.compTitle:Hide() end
        if self.compCaption then self.compCaption:Hide() end
        for _, slotRow in ipairs(self.compSlotRows or {}) do slotRow:Hide() end
        if self.confidenceBadge then self.confidenceBadge:Hide() end
        if self.bgStatsTitle then self.bgStatsTitle:Hide() end
        if self.bgStatsCaption then self.bgStatsCaption:Hide() end
        for _, row in ipairs(self.bgStatRows or {}) do row:Hide() end
        if self.scoreboardTitle then self.scoreboardTitle:Hide() end
        if self.scoreboardCaption then self.scoreboardCaption:Hide() end
        for _, row in ipairs(self.scoreboardRows or {}) do row:Hide() end
        if self.partyTitle then self.partyTitle:Hide() end
        if self.partyCaption then self.partyCaption:Hide() end
        for _, peerRow in ipairs(self.partyPeerRows or {}) do peerRow:Hide() end
        return
    end

    self.emptyState:Hide()

    -- Confidence badge next to title (gated by setting).
    if self.confidenceBadge then
        local showBadge = ns.Addon and ns.Addon.GetSetting and ns.Addon:GetSetting("showConfidenceBadges")
        if showBadge ~= false then
            self.confidenceBadge:SetConfidence(session.dataConfidence or "unknown")
            self.confidenceBadge:Show()
        else
            self.confidenceBadge:Hide()
        end
    end

    self.caption:SetText(isPinnedReview
        and "Selected fight translated into explained scores, benchmark bars, and recognizable spell output."
        or "Latest fight translated into explained scores, benchmark bars, and recognizable spell output.")

    local isDummy = session.context == ns.Constants.CONTEXT.TRAINING_DUMMY
    if self.dummyNotice then
        if isDummy then
            self.dummyNotice:Show()
            self.shell:ClearAllPoints()
            self.shell:SetPoint("TOPLEFT", self.dummyNotice, "BOTTOMLEFT", 0, -8)
            self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)
        else
            self.dummyNotice:Hide()
            self.shell:ClearAllPoints()
            self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
            self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)
        end
    end

    self.scoresTitle:Show()
    self.scoresCaption:Show()
    self.benchmarkTitle:Show()
    self.benchmarkCaption:Show()
    self.spellsTitle:Show()
    self.spellsCaption:Show()
    self.insightsTitle:Show()
    self.insightsCaption:Show()

    local snapshot = session.playerSnapshot or {}
    characterKey = store:GetSessionCharacterKey(session)
    local opponent = ns.Helpers.ResolveOpponentName(session, "Unknown Opponent")
    local itemLevel = snapshot.equippedItemLevel or snapshot.averageItemLevel or snapshot.pvpItemLevel or 0
    local buildHash = snapshot.buildHash or "unknown"
    local contextKey = session.subcontext and string.format("%s:%s", session.context, session.subcontext) or session.context
    local buildBaseline = store:GetBuildBaseline(buildHash, contextKey, session.id, characterKey)
    local opponentBaseline = session.primaryOpponent and store:GetOpponentBaseline(session.primaryOpponent.guid or session.primaryOpponent.name, session.id, characterKey) or nil
    local matchupBaseline = session.primaryOpponent and store:GetSessionBaseline(buildHash, contextKey, session.primaryOpponent.guid or session.primaryOpponent.name, session.id, characterKey) or nil
    local dummyBenchmark = nil
    local openerFingerprint = session.openerFingerprint or {}
    local readQuality = formatDisplayLabel(session.analysisConfidence)
    local readSource = formatDisplayLabel(session.finalDamageSource)
    -- Prefer the richer dataConfidence label in user-visible strings
    -- (e.g. "Full Raw" instead of "High", "Partial Roster" instead of "Medium").
    local richQuality = session.dataConfidence
        and formatDisplayLabel(session.dataConfidence)
        or readQuality

    self.caption:SetText(string.format(
        "%s Read quality: %s via %s.",
        isPinnedReview
            and "Selected fight translated into explained scores, benchmark bars, and recognizable spell output."
            or "Latest fight translated into explained scores, benchmark bars, and recognizable spell output.",
        richQuality,
        readSource
    ))

    if session.context == ns.Constants.CONTEXT.TRAINING_DUMMY then
        for _, benchmark in ipairs(store:GetDummyBenchmarks(characterKey)) do
            if benchmark.buildHash == buildHash and benchmark.dummyName == (session.primaryOpponent and session.primaryOpponent.name or "") then
                dummyBenchmark = benchmark
                break
            end
        end
    end

    self.metricCards[1]:SetData(
        string.format("%s", Helpers.FormatNumber(session.totals.damageDone or 0)),
        "Damage Done",
        string.format("%s DPS over %s versus %s. Source: %s.", Helpers.FormatNumber(session.metrics.sustainedDps or 0), Helpers.FormatDuration(session.duration or 0), opponent, readSource),
        Theme.accent
    )
    self.metricCards[1]:Show()

    self.metricCards[2]:SetData(
        string.format("%.1f", session.metrics.pressureScore or 0),
        "Offensive Pressure",
        string.format("Blend of sustained output and kill threat. Burst score: %.1f.", session.metrics.burstScore or 0),
        Theme.warning
    )
    self.metricCards[2]:Show()

    self.metricCards[3]:SetData(
        string.format("%.1f", session.metrics.survivabilityScore or 0),
        "Survivability",
        string.format("%s taken, %s healing, %d deaths.", Helpers.FormatNumber(session.totals.damageTaken or 0), Helpers.FormatNumber(session.totals.healingDone or 0), session.survival and session.survival.deaths or 0),
        Theme.success
    )
    self.metricCards[3]:Show()

    self.metricCards[4]:SetData(
        string.format("%s ilvl", formatItemLevel(itemLevel)),
        "Fight Snapshot",
        string.format("Mastery %s  |  Vers %s dmg / %s DR  |  Read %s", formatPercent(snapshot.masteryEffect), formatPercent(snapshot.versatilityDamageDone), formatPercent(snapshot.versatilityDamageTaken), richQuality),
        Theme.text
    )
    self.metricCards[4]:Show()

    self.metricBars[1]:SetData(
        "Pressure",
        string.format("%.1f / 100", session.metrics.pressureScore or 0),
        "How much healing or defensive respect your damage pattern should force. Reference: 35 low, 55 solid, 75 oppressive.",
        (session.metrics.pressureScore or 0) / 100,
        Theme.warning
    )
    self.metricBars[2]:SetData(
        "Burst Threat",
        string.format("%.1f / 100", session.metrics.burstScore or 0),
        session.metrics.limitedBySource and "Limited on Midnight-safe mode because precise kill-window timing is unavailable. Reference: 30 low, 50 threatening, 70 kill-ready." or "How concentrated your damage was into short kill windows. Reference: 30 low, 50 threatening, 70 kill-ready.",
        (session.metrics.burstScore or 0) / 100,
        Theme.accent
    )
    self.metricBars[3]:SetData(
        "Survivability",
        string.format("%.1f / 100", session.metrics.survivabilityScore or 0),
        "Healing-to-incoming-damage ratio plus defensive usage bonus. Reference: 45 fragile, 65 stable, 80 excellent recovery.",
        (session.metrics.survivabilityScore or 0) / 100,
        Theme.success
    )
    self.metricBars[4]:SetData(
        "Rotation Uptime",
        string.format("%.1f / 100", session.metrics.rotationalConsistencyScore or 0),
        "Built from successful cast spacing. Reference: below 40 means gaps, 60 is clean, 80 is tournament-clean.",
        (session.metrics.rotationalConsistencyScore or 0) / 100,
        Theme.accentSoft
    )
    self.metricBars[5]:SetData(
        "Buff Window Follow-through",
        string.format("%.1f / 100", session.metrics.procConversionScore or 0),
        string.format("Proc-like windows observed: %d. Casts landed inside them: %d. First go %s.", session.metrics.procWindowsObserved or 0, session.metrics.procWindowCastCount or 0, openerFingerprint.firstMajorOffensiveAt and string.format("%.1fs", openerFingerprint.firstMajorOffensiveAt) or "--"),
        (session.metrics.procConversionScore or 0) / 100,
        Theme.borderStrong
    )
    for _, row in ipairs(self.metricBars) do
        row:Show()
    end

    local comparisonCount = 0
    local function nextComparisonRow()
        comparisonCount = comparisonCount + 1
        return self.comparisonRows[comparisonCount]
    end

    if buildBaseline and buildBaseline.fights >= 5 then
        local row = nextComparisonRow()
        setComparisonRow(
            row,
            "Damage vs Build Baseline",
            string.format("Compared against your last %d sessions on the same build.", buildBaseline.fights or 0),
            session.totals.damageDone or 0,
            buildBaseline.averageDamageDone or 0,
            Helpers.FormatNumber,
            false
        )
    end

    if buildBaseline and buildBaseline.fights >= 5 and comparisonCount < #self.comparisonRows then
        local row = nextComparisonRow()
        setComparisonRow(
            row,
            "Pressure vs Build Baseline",
            string.format("Pressure expectation from %d stored sessions on this build.", buildBaseline.fights or 0),
            session.metrics.pressureScore or 0,
            buildBaseline.averagePressureScore or 0,
            function(value)
                return string.format("%.1f", value or 0)
            end,
            false
        )
    end

    if matchupBaseline and matchupBaseline.fights >= 5 and (session.metrics.openerDamage or 0) > 0 and comparisonCount < #self.comparisonRows then
        local row = nextComparisonRow()
        setComparisonRow(
            row,
            "Opener vs Matchup Baseline",
            string.format("Compared against %d sessions on this build versus this opponent/context.", matchupBaseline.fights or 0),
            session.metrics.openerDamage or 0,
            matchupBaseline.averageOpenerDamage or 0,
            Helpers.FormatNumber,
            false
        )
    elseif dummyBenchmark and dummyBenchmark.sessions >= 5 and comparisonCount < #self.comparisonRows then
        local row = nextComparisonRow()
        local expectedSustained = (dummyBenchmark.totalSustainedDps or 0) / math.max(dummyBenchmark.sessions or 1, 1)
        setComparisonRow(
            row,
            "Sustained DPS vs Dummy Benchmark",
            string.format("Dummy-specific expectation from %d benchmark pulls.", dummyBenchmark.sessions or 0),
            session.metrics.sustainedDps or 0,
            expectedSustained,
            Helpers.FormatNumber,
            false
        )
    elseif opponentBaseline and opponentBaseline.fights >= 5 and comparisonCount < #self.comparisonRows then
        local row = nextComparisonRow()
        setComparisonRow(
            row,
            "Damage Taken vs Opponent History",
            string.format("Incoming damage expectation from %d prior fights against this opponent.", opponentBaseline.fights or 0),
            session.totals.damageTaken or 0,
            opponentBaseline.averageDamageTaken or 0,
            Helpers.FormatNumber,
            true
        )
    end

    for index = comparisonCount + 1, #self.comparisonRows do
        local row = self.comparisonRows[index]
        if index == 1 then
            row:SetData(
                "Build Baseline Pending",
                string.format("%s current damage", Helpers.FormatNumber(session.totals.damageDone or 0)),
                "Need at least 5 similar sessions on the same build before the dashboard can draw an expected damage line.",
                (session.metrics.pressureScore or 0) / 100,
                Theme.accentSoft
            )
        elseif index == 2 then
            row:SetData(
                "Pressure Reference Pending",
                string.format("%.1f current pressure", session.metrics.pressureScore or 0),
                "Need more history in this context before personal pressure expectations become reliable.",
                (session.metrics.pressureScore or 0) / 100,
                Theme.accentSoft
            )
        else
            row:SetData(
                "Personal Benchmark Pending",
                string.format("%s opener", Helpers.FormatNumber(session.metrics.openerDamage or 0)),
                "Reference markers appear here once you have enough build-matched duels, dummy pulls, or matchup history for this session type.",
                (session.metrics.pressureScore or 0) / 100,
                Theme.accentSoft
            )
        end
        row:Show()
    end

    local spells = buildSpellRows(session, #self.spellRows)
    for index, row in ipairs(self.spellRows) do
        local spell = spells[index]
        if spell then
            row:SetData(
                spell.icon,
                spell.name,
                string.format("Damage %s  |  Healing %s  |  Casts %d  |  Hits %d", Helpers.FormatNumber(spell.damage), Helpers.FormatNumber(spell.healing), spell.casts or 0, spell.hits or 0),
                string.format("%s  (%s of output)", Helpers.FormatNumber(spell.amount), formatPercent((spell.share or 0) * 100)),
                spell.share,
                Theme.accent
            )
        else
            row:Hide()
        end
    end

    -- Opponent composition panel (arena sessions only).
    local arenaSlots = session.arena and session.arena.slots or {}
    local compSlotCount = 0
    if next(arenaSlots) then
        self.compTitle:Show()
        self.compCaption:Show()
        for _, slotData in pairs(arenaSlots) do
            compSlotCount = compSlotCount + 1
            if compSlotCount <= #self.compSlotRows then
                local specId = slotData.prepSpecId
                local archetype = specId and ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype(specId) or nil
                local archetypeLabel = archetype and archetype.label or ""
                local threatTag = archetype and archetype.threatTags and archetype.threatTags[1] or ""
                self.compSlotRows[compSlotCount]:SetSlotData({
                    classFile = slotData.classFile or slotData.prepClassFile,
                    specName = slotData.prepSpecName or slotData.name or "Unknown",
                    name = slotData.name,
                    archetypeLabel = archetypeLabel,
                    threatTag = threatTag,
                })
            end
        end
    else
        self.compTitle:Hide()
        self.compCaption:Hide()
    end
    for index = compSlotCount + 1, #self.compSlotRows do
        self.compSlotRows[index]:Hide()
    end

    -- BG Objectives panel (battleground sessions only).
    local bgStatCount = 0
    local bgStats = session.bgStats
    if session.context == ns.Constants.CONTEXT.BATTLEGROUND and bgStats and type(bgStats) == "table" and #bgStats > 0 then
        self.bgStatsTitle:Show()
        self.bgStatsCaption:Show()
        for _, stat in ipairs(bgStats) do
            if stat.pvpStatValue and stat.pvpStatValue > 0 then
                bgStatCount = bgStatCount + 1
                if bgStatCount <= #self.bgStatRows then
                    local statName = ns.StaticPvpData and ns.StaticPvpData.BG_STAT_NAMES and ns.StaticPvpData.BG_STAT_NAMES[stat.pvpStatID]
                        or string.format("Stat %d", stat.pvpStatID or 0)
                    self.bgStatRows[bgStatCount]:SetText(string.format("%s: %d", statName, stat.pvpStatValue))
                    self.bgStatRows[bgStatCount]:Show()
                end
            end
        end
    end
    if bgStatCount == 0 then
        self.bgStatsTitle:Hide()
        self.bgStatsCaption:Hide()
    end
    -- Re-anchor BG stats section below comp panel (or spells if no comp).
    self.bgStatsTitle:ClearAllPoints()
    if compSlotCount > 0 then
        self.bgStatsTitle:SetPoint("TOPLEFT", self.compSlotRows[compSlotCount], "BOTTOMLEFT", 0, -22)
    else
        self.bgStatsTitle:SetPoint("TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    end
    for index = bgStatCount + 1, #self.bgStatRows do
        self.bgStatRows[index]:Hide()
    end

    -- Post-match scoreboard (arena/BG rated sessions).
    local scoreboardCount = 0
    local postScores = session.postMatchScores
    local playerGuid = ns.ApiCompat.GetPlayerGUID()
    if postScores and type(postScores) == "table" and #postScores > 0 then
        self.scoreboardTitle:Show()
        self.scoreboardCaption:Show()
        for _, entry in ipairs(postScores) do
            scoreboardCount = scoreboardCount + 1
            if scoreboardCount <= #self.scoreboardRows then
                local ratingStr = ""
                if entry.ratingChange and entry.ratingChange ~= 0 then
                    ratingStr = entry.ratingChange > 0
                        and string.format("  |cff70d196+%d|r", entry.ratingChange)
                        or string.format("  |cffe64d40%d|r", entry.ratingChange)
                end
                local isMe = entry.guid == playerGuid
                local nameColor = isMe and "|cff59a5f5" or "|cffffffff"
                self.scoreboardRows[scoreboardCount]:SetText(string.format(
                    "%s%s|r  —  %s dmg  |  %s heal  |  %d KB  |  %d D%s",
                    nameColor, entry.name or "Unknown",
                    Helpers.FormatNumber(entry.damageDone or 0),
                    Helpers.FormatNumber(entry.healingDone or 0),
                    entry.killingBlows or 0,
                    entry.deaths or 0,
                    ratingStr
                ))
                self.scoreboardRows[scoreboardCount]:Show()
            end
        end
    end
    if scoreboardCount == 0 then
        self.scoreboardTitle:Hide()
        self.scoreboardCaption:Hide()
    end
    -- Re-anchor scoreboard below BG stats (or comp, or spells).
    self.scoreboardTitle:ClearAllPoints()
    if bgStatCount > 0 then
        self.scoreboardTitle:SetPoint("TOPLEFT", self.bgStatRows[bgStatCount], "BOTTOMLEFT", 0, -22)
    elseif compSlotCount > 0 then
        self.scoreboardTitle:SetPoint("TOPLEFT", self.compSlotRows[compSlotCount], "BOTTOMLEFT", 0, -22)
    else
        self.scoreboardTitle:SetPoint("TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    end
    for index = scoreboardCount + 1, #self.scoreboardRows do
        self.scoreboardRows[index]:Hide()
    end

    -- Re-anchor insights section below scoreboard (or comp, or spells).
    self.insightsTitle:ClearAllPoints()
    local insightsAnchor = self.spellRows[#self.spellRows]
    if scoreboardCount > 0 then
        insightsAnchor = self.scoreboardRows[scoreboardCount]
    elseif bgStatCount > 0 then
        insightsAnchor = self.bgStatRows[bgStatCount]
    elseif compSlotCount > 0 then
        insightsAnchor = self.compSlotRows[compSlotCount]
    end
    self.insightsTitle:SetPoint("TOPLEFT", insightsAnchor, "BOTTOMLEFT", 0, -22)

    local suggestions = session.suggestions or {}
    for index, card in ipairs(self.insightCards) do
        local suggestion = suggestions[index]
        if suggestion then
            card:SetData(
                suggestion.severity,
                SUGGESTION_TITLES[suggestion.reasonCode] or (suggestion.message or "Insight"),
                suggestion.message or "No detail available.",
                buildSuggestionEvidence(suggestion)
            )
        elseif index == 1 then
            card:SetData(
                "low",
                "No standout issues in this fight",
                "This session did not trip any benchmark or rules-based warnings.",
                "As you build more history, this area will become more matchup-specific."
            )
        else
            card:Hide()
        end
    end

    -- Party Sync peer session panel.
    local sync = ns.Addon:GetModule("PartySyncService")
    local peers = sync and sync:GetPeerSessions() or {}
    local peerCount = 0
    local now = Helpers.Now()
    for sender, peer in pairs(peers) do
        -- Only show peers received within the last 5 minutes.
        if (now - (peer.receivedAt or 0)) < 300 then
            peerCount = peerCount + 1
            if peerCount <= #self.partyPeerRows then
                local specInfo = peer.specId and peer.specId > 0 and ns.ApiCompat.GetSpecializationInfoByID(peer.specId) or nil
                local specLabel = specInfo and specInfo.name or string.format("Spec %d", peer.specId or 0)
                self.partyPeerRows[peerCount]:SetText(string.format(
                    "%s  |  %s  |  %s  |  %s dmg  |  P:%.1f  B:%.1f  |  %s",
                    tostring(sender),
                    specLabel,
                    Helpers.FormatDuration(peer.duration or 0),
                    Helpers.FormatNumber(peer.damageDone or 0),
                    peer.pressureScore or 0,
                    peer.burstScore or 0,
                    peer.result or "unknown"
                ))
                self.partyPeerRows[peerCount]:Show()
            end
        end
    end

    if peerCount > 0 then
        self.partyTitle:Show()
        self.partyCaption:Show()
        self.partyTitle:ClearAllPoints()
        self.partyTitle:SetPoint("TOPLEFT", self.insightCards[#self.insightCards], "BOTTOMLEFT", 0, -22)
    else
        self.partyTitle:Hide()
        self.partyCaption:Hide()
    end
    for index = peerCount + 1, #self.partyPeerRows do
        self.partyPeerRows[index]:Hide()
    end

    local extraHeight = 0
    extraHeight = extraHeight + (peerCount > 0 and (60 + peerCount * 18) or 0)
    extraHeight = extraHeight + (bgStatCount > 0 and (60 + bgStatCount * 20) or 0)
    extraHeight = extraHeight + (scoreboardCount > 0 and (60 + scoreboardCount * 16) or 0)
    local baseHeight = compSlotCount > 0 and 1440 or 1280
    ns.Widgets.SetCanvasHeight(self.canvas, baseHeight + extraHeight)
end

ns.Addon:RegisterModule("SummaryView", SummaryView)
