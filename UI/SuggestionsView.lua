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
}

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
        return string.format("First major go at %.1fs versus %.1fs over %d similar sessions.", evidence.current or 0, evidence.baseline or 0, evidence.samples or 0)
    end
    if suggestion.reasonCode == "DEFENSIVE_DRIFT" then
        return string.format("First defensive at %.1fs versus %.1fs norm. Damage taken %s.", evidence.current or 0, evidence.baseline or 0, ns.Helpers.FormatNumber(evidence.damageTaken or 0))
    end
    if suggestion.reasonCode == "MIDNIGHT_SAFE_LIMITS" then
        return "Built from Blizzard's post-combat Damage Meter totals because raw CLEU timing is restricted."
    end
    if suggestion.reasonCode == "RAW_EVENT_OVERFLOW" then
        return string.format("Stored %d events against cap %d.", evidence.rawEvents or 0, evidence.max or 0)
    end

    return "Derived from current session output and your stored PvP history."
end

local function buildSessionTag(session)
    if not session then
        return "Unknown session context."
    end

    local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown opponent"
    return string.format("%s | %s | %s | %s", date("%Y-%m-%d %H:%M", session.timestamp or time()), session.context or "unknown", opponent, session.result or "unknown")
end

function SuggestionsView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Actionable Insights", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "History-backed notes translated into readable coaching cues instead of internal codes.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 96)
    self.emptyCard:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)

    self.cards = {}
    for index = 1, 8 do
        local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 108)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        else
            card:SetPoint("TOPLEFT", self.cards[index - 1], "BOTTOMLEFT", 0, -10)
        end
        self.cards[index] = card
    end

    ns.Widgets.SetCanvasHeight(self.canvas, 980)
    return self.frame
end

function SuggestionsView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local suggestions = store:GetRecentSuggestions(100)
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end
    if #suggestions == 0 then
        self.emptyCard:SetData(
            "low",
            "No insights yet",
            "Once you collect a few fights, this tab will surface benchmark misses, matchup trends, and rotation issues.",
            "Dummy sessions help seed the baseline faster."
        )
        self.emptyCard:Show()
        for _, card in ipairs(self.cards) do
            card:Hide()
        end
        return
    end

    self.emptyCard:Hide()

    for index, card in ipairs(self.cards) do
        local suggestion = suggestions[index]
        if suggestion then
            local session = store:GetCombatById(suggestion.sessionId)
            card:SetData(
                suggestion.severity,
                SUGGESTION_TITLES[suggestion.reasonCode] or (suggestion.message or "Insight"),
                string.format("%s\n%s", suggestion.message or "", buildSessionTag(session)),
                buildEvidenceText(suggestion)
            )
        else
            card:Hide()
        end
    end
end

ns.Addon:RegisterModule("SuggestionsView", SuggestionsView)
