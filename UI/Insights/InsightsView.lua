local _, ns = ...

-- UI/Insights/InsightsView.lua
--
-- New Insights dashboard. Replaces the dense "trust + story + 8 generic
-- cards + drawer" stack from the old UI/SuggestionsView.lua with a
-- coaching-focused layout driven by the pure-logic Insights modules:
--
--   ns.InsightsPriority    — ranks suggestions for the Next Queue Focus card
--   ns.InsightsOnboarding  — Cold / Sparse / Full state classification
--   ns.InsightsPillarMapper — maps reason codes to the 4 scoreboard pillars
--
-- Current sections (top to bottom):
--   1. FidelityBar    — session metadata + character history depth
--   2. Onboarding     — only when state is Cold / Sparse
--   3. NextQueueFocus — single highest-impact callout
--   4. PillarScoreboard — 4 columns (Pressure/Survival/Control/Consistency),
--                         each click toggles inline drilldown to reason codes
--
-- Remaining sections from PLAN.md (FightTimelineRead, MatchupPlan, TrendsPeek,
-- PracticePlan, EvidenceDrawer) hook in below the scoreboard in future
-- iterations. They all anchor to PillarDrilldown.bottom so adding them does
-- not require rewriting existing layout.

local Helpers = ns.Helpers
local Theme   = ns.Widgets.THEME

local InsightsView = {
    viewId = "insights",
}

-- ---------------------------------------------------------------------------
-- Title overrides for the new layout.
-- ---------------------------------------------------------------------------
local SUGGESTION_TITLES = {
    LOW_PRESSURE_VS_BUILD_BASELINE = "Output below your build baseline",
    WEAK_BURST_FOR_CONTEXT         = "Burst pressure underperformed",
    DEFENSIVE_UNUSED_ON_LOSS       = "A major defensive trade was missed",
    HIGH_DAMAGE_TAKEN_VS_OPPONENT  = "This opponent pressured you harder than usual",
    DUMMY_OPENER_VARIANCE          = "Opener lagged your dummy benchmark",
    DUMMY_SUSTAINED_VARIANCE       = "Sustained dummy damage fell below benchmark",
    ROTATION_GAPS_OBSERVED         = "Rotation had visible dead space",
    PROC_WINDOWS_UNDERUSED         = "Proc-like buff windows were not converted",
    LATE_FIRST_GO                  = "First major go started late",
    DEFENSIVE_DRIFT                = "Defensive timing drifted late",
    DIED_IN_CC                     = "Died while crowd-controlled",
    TRINKET_TIMING_POOR            = "Trinket was late or unused during CC",
    HIGH_CC_UPTIME                 = "Excessive time spent under crowd control",
    SPEC_WINRATE_DEFICIT           = "Struggling against this spec historically",
    SPEC_WINRATE_STRENGTH          = "Strong historical performance against this spec",
    REACTIVE_DEFENSIVE_LATE        = "Defensive cooldown used late into CC",
    SUBOPTIMAL_OPENER_SEQUENCE     = "Opener has low win rate vs this spec",
    POOR_INTERRUPT_RATE            = "Low interrupt success rate",
    LOW_HEALER_PRESSURE            = "Healer received little damage",
    TILT_WARNING                   = "Recent performance dip detected",
    COMP_DEFICIT                   = "Low win rate vs this comp",
    DIED_WITH_DEFENSIVES           = "Died with defensives still available",
    CC_DR_WASTE                    = "CC applied at diminished returns",
    CC_LATE_TRINKET                = "Trinket used too late in CC chain",
    CC_MISSED_KILL_WINDOW          = "CC on healer but no burst follow-up",
    CC_GOOD_TRINKET                = "Good trinket timing — keep doing this",
    CC_CHAIN_BREAK                 = "CC chain broken prematurely",
    CC_HIGH_UPTIME                 = "Excessive time spent crowd-controlled",
    MIDNIGHT_SAFE_LIMITS           = "Timeline detail limited in Midnight-safe mode",
    RAW_EVENT_OVERFLOW             = "Raw event cap reached",
}

local function titleFor(reasonCode)
    return SUGGESTION_TITLES[reasonCode] or reasonCode or "Next session focus"
end

local function evidenceLine(suggestion)
    if not suggestion then return "" end
    local pieces = {}
    if suggestion.severity then
        pieces[#pieces + 1] = string.format("severity %s", suggestion.severity)
    end
    if suggestion.recurrenceCount and suggestion.recurrenceCount > 0 then
        pieces[#pieces + 1] = string.format("recurrence %d/7d", suggestion.recurrenceCount)
    end
    if suggestion.confidenceTier then
        pieces[#pieces + 1] = (suggestion.confidenceTier:gsub("_", " "))
    end
    return table.concat(pieces, "  |  ")
end

local function priorityBreakdownLine(scoring)
    if not scoring then return "" end
    return string.format(
        "Priority %.2f = sev %.2f x conf %.2f x recur %.2f x ctrl %.2f",
        scoring.priority         or 0,
        scoring.severity         or 0,
        scoring.confidence       or 0,
        scoring.recurrenceWeight or 1,
        scoring.controllability  or 0
    )
end

local function resolveSession(store, payload)
    if payload and payload.id and payload.timestamp then
        return payload
    end
    if store and store.GetLastSession then
        local ok, last = pcall(store.GetLastSession, store)
        if ok then return last end
    end
    return nil
end

local function characterSessionCount(store, session)
    if not store or not session then return 0 end
    if store.GetSessionCountForCharacter then
        local ok, n = pcall(store.GetSessionCountForCharacter, store, session)
        if ok and tonumber(n) then return n end
    end
    if store.GetRecentSessionStreak then
        local ok, list = pcall(store.GetRecentSessionStreak, store, 50)
        if ok and type(list) == "table" then
            local key = session.characterKey or session.character
            local n = 0
            for _, s in ipairs(list) do
                if (s.characterKey or s.character) == key then n = n + 1 end
            end
            return n
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Pillar Scoreboard helpers
-- ---------------------------------------------------------------------------

-- Pick a color for the value text based on whether the metric is healthy.
-- A simple band system since we may not have personal baselines yet.
local function pillarValueColor(value)
    if not value then return Theme.textMuted end
    if value >= 70 then return Theme.success end
    if value >= 50 then return Theme.text end
    if value >= 35 then return Theme.warning end
    return Theme.warning  -- always-visible; no red palette token
end

local function buildPillarColumn(parent, width, height)
    local col = ns.Widgets.CreateSurface(parent, width, height, Theme.panel, Theme.border)
    col:EnableMouse(true)
    col:SetScript("OnEnter", function(self)
        ns.Widgets.SetBackdropColors(self, Theme.panelHover, Theme.accent)
    end)
    col:SetScript("OnLeave", function(self)
        ns.Widgets.SetBackdropColors(self, self._active and Theme.panelHover or Theme.panel, self._active and Theme.accent or Theme.border)
    end)

    col.label = col:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    col.label:SetPoint("TOPLEFT", col, "TOPLEFT", 10, -8)
    col.label:SetTextColor(unpack(Theme.text))

    col.value = col:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    col.value:SetPoint("TOPLEFT", col.label, "BOTTOMLEFT", 0, -4)
    col.value:SetTextColor(unpack(Theme.text))

    col.delta = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    col.delta:SetPoint("TOPLEFT", col.value, "BOTTOMLEFT", 0, -2)
    col.delta:SetTextColor(unpack(Theme.textMuted))

    col.codeCount = col:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    col.codeCount:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 10, 6)
    col.codeCount:SetTextColor(unpack(Theme.textMuted))

    function col:SetData(labelText, value, deltaText, codeCount)
        self.label:SetText(labelText or "")
        if value then
            self.value:SetText(string.format("%.0f", value))
            self.value:SetTextColor(unpack(pillarValueColor(value)))
        else
            self.value:SetText("--")
            self.value:SetTextColor(unpack(Theme.textMuted))
        end
        self.delta:SetText(deltaText or "")
        self.codeCount:SetText(codeCount and (codeCount .. " notes") or "")
    end

    function col:SetActive(active)
        self._active = active and true or false
        ns.Widgets.SetBackdropColors(self, self._active and Theme.panelHover or Theme.panel, self._active and Theme.accent or Theme.border)
    end

    return col
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function InsightsView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.activePillar = nil

    self.title = ns.Widgets.CreateSectionTitle(
        self.frame, "Actionable Insights",
        "TOPLEFT", self.frame, "TOPLEFT", 16, -16
    )
    self.caption = ns.Widgets.CreateCaption(
        self.frame, "One coaching focus before your next queue, plus a pillar breakdown.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    -- ── Fidelity bar ────────────────────────────────────────────────────
    self.fidelityCard = ns.Widgets.CreateInsightCard(self.canvas, 760, 64)
    self.fidelityCard:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    if ns.Widgets.AddHoverEffect then
        ns.Widgets.AddHoverEffect(self.fidelityCard, 0.06)
    end

    -- ── Onboarding banner ───────────────────────────────────────────────
    self.onboardCard = ns.Widgets.CreateInsightCard(self.canvas, 760, 72)
    self.onboardCard:SetPoint("TOPLEFT", self.fidelityCard, "BOTTOMLEFT", 0, -8)
    self.onboardCard:Hide()

    -- ── Next Queue Focus ────────────────────────────────────────────────
    self.focusCard = ns.Widgets.CreateInsightCard(self.canvas, 760, 160)
    self.focusCard:SetPoint("TOPLEFT", self.onboardCard, "BOTTOMLEFT", 0, -8)
    if ns.Widgets.AddHoverEffect then
        ns.Widgets.AddHoverEffect(self.focusCard, 0.08)
    end

    -- ── Empty placeholder when no focus is available ────────────────────
    self.emptyCard = ns.Widgets.CreateInsightCard(self.canvas, 760, 84)
    self.emptyCard:SetPoint("TOPLEFT", self.fidelityCard, "BOTTOMLEFT", 0, -8)
    self.emptyCard:Hide()

    -- ── Pillar Scoreboard ───────────────────────────────────────────────
    self.scoreboardTitle = ns.Widgets.CreateSectionTitle(
        self.canvas, "Pillar Scoreboard",
        "TOPLEFT", self.focusCard, "BOTTOMLEFT", 0, -18
    )
    self.scoreboardCaption = ns.Widgets.CreateCaption(
        self.canvas, "Click any pillar to expand the contributing reason codes for this session.",
        "TOPLEFT", self.scoreboardTitle, "BOTTOMLEFT", 0, -4
    )

    self.scoreboardRow = CreateFrame("Frame", nil, self.canvas)
    self.scoreboardRow:SetSize(760, 96)
    self.scoreboardRow:SetPoint("TOPLEFT", self.scoreboardCaption, "BOTTOMLEFT", 0, -8)

    local Mapper = ns.InsightsPillarMapper
    self.pillarColumns = {}
    if Mapper and Mapper.PILLARS then
        local colCount = #Mapper.PILLARS
        local gap = 8
        local colWidth = math.floor((760 - (colCount - 1) * gap) / colCount)
        for i, pillarKey in ipairs(Mapper.PILLARS) do
            local col = buildPillarColumn(self.scoreboardRow, colWidth, 96)
            if i == 1 then
                col:SetPoint("TOPLEFT", self.scoreboardRow, "TOPLEFT", 0, 0)
            else
                col:SetPoint("TOPLEFT", self.pillarColumns[i - 1], "TOPRIGHT", gap, 0)
            end
            col._pillarKey = pillarKey
            col:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" then
                    InsightsView:OnPillarClick(pillarKey)
                end
            end)
            self.pillarColumns[i] = col
        end
    end

    -- ── Pillar drilldown panel (collapsed by default) ───────────────────
    self.drilldown = ns.Widgets.CreateSurface(self.canvas, 760, 24, Theme.panelAlt, Theme.border)
    self.drilldown:SetPoint("TOPLEFT", self.scoreboardRow, "BOTTOMLEFT", 0, -8)
    self.drilldown:Hide()

    self.drilldown.title = self.drilldown:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.drilldown.title:SetPoint("TOPLEFT", self.drilldown, "TOPLEFT", 10, -8)
    self.drilldown.title:SetTextColor(unpack(Theme.text))

    self.drilldown.body = self.drilldown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.drilldown.body:SetPoint("TOPLEFT", self.drilldown.title, "BOTTOMLEFT", 0, -6)
    self.drilldown.body:SetPoint("RIGHT", self.drilldown, "RIGHT", -10, 0)
    self.drilldown.body:SetJustifyH("LEFT")
    self.drilldown.body:SetJustifyV("TOP")
    self.drilldown.body:SetTextColor(unpack(Theme.textMuted))

    -- ── Fight Timeline Read (anchors below pillar drilldown) ────────────
    if ns.InsightsFightTimelineRead then
        ns.InsightsFightTimelineRead:Build(self.canvas, self.drilldown, 760)
        ns.InsightsFightTimelineRead:OnLayoutChange(function()
            self:_RecalculateCanvas()
        end)
        self.timelineSection = ns.InsightsFightTimelineRead
    end

    -- ── Matchup Plan (anchors below timeline drawer) ────────────────────
    if ns.InsightsMatchupPlanCard then
        local anchor = (self.timelineSection and self.timelineSection.drawer) or self.drilldown
        ns.InsightsMatchupPlanCard:Build(self.canvas, anchor, 760)
        self.matchupSection = ns.InsightsMatchupPlanCard
    end

    -- ── Trends Peek (anchors below matchup card) ────────────────────────
    if ns.InsightsTrendsPeekView then
        local anchor = (self.matchupSection and self.matchupSection.card)
            or (self.timelineSection and self.timelineSection.drawer)
            or self.drilldown
        ns.InsightsTrendsPeekView:Build(self.canvas, anchor, 760)
        self.trendsSection = ns.InsightsTrendsPeekView
    end

    -- ── Practice Plan (anchors below trends card) ───────────────────────
    if ns.InsightsPracticePlanList then
        local anchor = (self.trendsSection and self.trendsSection.card)
            or (self.matchupSection and self.matchupSection.card)
            or self.drilldown
        ns.InsightsPracticePlanList:Build(self.canvas, anchor, 760)
        self.practiceSection = ns.InsightsPracticePlanList
    end

    -- ── Evidence Drawer (anchors at the bottom, collapsed by default) ───
    if ns.InsightsEvidenceDrawer then
        local anchor = (self.practiceSection and self.practiceSection.list)
            or (self.trendsSection and self.trendsSection.card)
            or self.drilldown
        ns.InsightsEvidenceDrawer:Build(self.canvas, anchor, 760)
        ns.InsightsEvidenceDrawer:OnLayoutChange(function()
            self:_RecalculateCanvas()
        end)
        self.evidenceSection = ns.InsightsEvidenceDrawer
    end

    ns.Widgets.SetCanvasHeight(self.canvas, 600)
end

-- ---------------------------------------------------------------------------
-- Pillar drilldown — toggle a single pillar's contributing reason codes
-- ---------------------------------------------------------------------------
function InsightsView:OnPillarClick(pillarKey)
    if self.activePillar == pillarKey then
        self.activePillar = nil
        for _, col in ipairs(self.pillarColumns) do
            col:SetActive(false)
        end
        self.drilldown:Hide()
        self:_RecalculateCanvas()
        return
    end

    self.activePillar = pillarKey
    for _, col in ipairs(self.pillarColumns) do
        col:SetActive(col._pillarKey == pillarKey)
    end

    local lines = self._pillarLines and self._pillarLines[pillarKey] or {}
    local Mapper = ns.InsightsPillarMapper
    local label  = (Mapper and Mapper.GetLabel(pillarKey)) or pillarKey

    self.drilldown.title:SetText(label .. " — contributing notes")
    if #lines == 0 then
        self.drilldown.body:SetText("No reason codes triggered in this pillar for this session.")
    else
        self.drilldown.body:SetText(table.concat(lines, "\n"))
    end

    local bodyHeight = math.max(20, math.min(220, 16 * math.max(#lines, 1)))
    self.drilldown:SetHeight(40 + bodyHeight)
    self.drilldown:Show()
    self:_RecalculateCanvas()
end

function InsightsView:_RecalculateCanvas()
    local base = 16 + 64 + 8
    if self.onboardCard:IsShown() then base = base + 72 + 8 end
    base = base + (self.focusCard:IsShown() and 160 or 84) + 8
    base = base + 18 + 4 + 18  -- scoreboard title + caption
    base = base + 96 + 8       -- scoreboard row
    if self.drilldown:IsShown() then
        base = base + self.drilldown:GetHeight() + 16
    end
    if self.timelineSection and self.timelineSection.title and self.timelineSection.title:IsShown() then
        base = base + (self.timelineSection:_Height() or 0) + 8
    end
    if self.matchupSection and self.matchupSection.title and self.matchupSection.title:IsShown() then
        base = base + (self.matchupSection:_Height() or 0) + 8
    end
    if self.trendsSection and self.trendsSection.title and self.trendsSection.title:IsShown() then
        base = base + (self.trendsSection:_Height() or 0) + 8
    end
    if self.practiceSection and self.practiceSection.title and self.practiceSection.title:IsShown() then
        base = base + (self.practiceSection:_Height() or 0) + 8
    end
    if self.evidenceSection and self.evidenceSection.title and self.evidenceSection.title:IsShown() then
        base = base + (self.evidenceSection:_Height() or 0) + 8
    end
    ns.Widgets.SetCanvasHeight(self.canvas, math.max(base, 400))
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function InsightsView:Refresh(payload)
    if not self.frame then return end

    local store = ns.Addon:GetModule("CombatStore", true)
    local session = resolveSession(store, payload)
    local sessionCount = characterSessionCount(store, session)

    local Onboarding = ns.InsightsOnboarding
    local Priority   = ns.InsightsPriority
    local Mapper     = ns.InsightsPillarMapper

    local state = Onboarding and Onboarding.Classify(sessionCount) or "full"

    -- ----- Fidelity bar -------------------------------------------------
    if session then
        local opponent = (Helpers and Helpers.ResolveOpponentName and Helpers.ResolveOpponentName(session, "Unknown opponent")) or "Unknown opponent"
        local dateStr  = date("%Y-%m-%d %H:%M", session.timestamp or time())
        local body     = string.format("%s · %s · %s · %s", dateStr, session.context or "unknown", opponent, session.result or "unknown")
        local evidence = string.format(
            "Character history: %d session%s. Data source: %s.",
            sessionCount,
            sessionCount == 1 and "" or "s",
            session.finalDamageSource or session.captureSource or "unknown"
        )
        self.fidelityCard:SetData("info", "Fidelity", body, evidence)
    else
        self.fidelityCard:SetData("info", "Fidelity", "No session selected", "Open a session to see insights.")
    end

    -- ----- Onboarding banner --------------------------------------------
    local onboardMsg = Onboarding and Onboarding.OnboardingMessage(state) or nil
    if onboardMsg then
        self.onboardCard:SetData("medium", "Onboarding", onboardMsg, "")
        self.focusCard:ClearAllPoints()
        self.focusCard:SetPoint("TOPLEFT", self.onboardCard, "BOTTOMLEFT", 0, -8)
        self.emptyCard:ClearAllPoints()
        self.emptyCard:SetPoint("TOPLEFT", self.onboardCard, "BOTTOMLEFT", 0, -8)
    else
        self.onboardCard:Hide()
        self.focusCard:ClearAllPoints()
        self.focusCard:SetPoint("TOPLEFT", self.fidelityCard, "BOTTOMLEFT", 0, -8)
        self.emptyCard:ClearAllPoints()
        self.emptyCard:SetPoint("TOPLEFT", self.fidelityCard, "BOTTOMLEFT", 0, -8)
    end

    -- ----- Next Queue Focus ---------------------------------------------
    local sectionVis = Onboarding and Onboarding.SectionVisibility(state) or { nextQueueFocus = true, pillarScoreboard = true }
    local suggestions = (session and (session.allSuggestions or session.suggestions)) or {}
    local top = (Priority and sectionVis.nextQueueFocus) and Priority.Top(suggestions) or nil

    if top then
        local s = top.suggestion
        local body = s.message
            or (s.evidence and tostring(s.evidence))
            or "Review this moment before your next queue."
        local evidence = evidenceLine(s)
        local breakdown = priorityBreakdownLine(top.scoring)
        local trailing = evidence
        if breakdown ~= "" then
            trailing = trailing ~= "" and (evidence .. "\n" .. breakdown) or breakdown
        end
        self.focusCard:SetData(s.severity or "medium", titleFor(s.reasonCode), body, trailing)
        self.emptyCard:Hide()
    else
        self.focusCard:Hide()
        local emptyMsg
        if state == "cold" then
            emptyMsg = "Play any PvP match or run a dummy benchmark to unlock coaching focus."
        elseif not session then
            emptyMsg = "Select a session from the History tab to surface coaching focus."
        elseif #suggestions == 0 then
            emptyMsg = "No coaching notes for this session yet — clean run, or data was not detailed enough."
        else
            emptyMsg = "Coaching focus unavailable for this session."
        end
        self.emptyCard:SetData("info", "Next Queue Focus", emptyMsg, "")
    end

    -- ----- Pillar Scoreboard --------------------------------------------
    local scoreboardVisible = sectionVis.pillarScoreboard and Mapper and #self.pillarColumns > 0
    if scoreboardVisible then
        self.scoreboardTitle:Show()
        self.scoreboardCaption:Show()
        self.scoreboardRow:Show()

        local buckets = Mapper.Bucket(suggestions)
        self._pillarLines = {}
        for _, pillarKey in ipairs(Mapper.PILLARS) do
            self._pillarLines[pillarKey] = {}
            for _, sug in ipairs(buckets[pillarKey] or {}) do
                local line = string.format("- %s   [%s]", titleFor(sug.reasonCode), sug.severity or "info")
                self._pillarLines[pillarKey][#self._pillarLines[pillarKey] + 1] = line
            end
        end

        local anchorTo = self.focusCard:IsShown() and self.focusCard or self.emptyCard
        self.scoreboardTitle:ClearAllPoints()
        self.scoreboardTitle:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -18)

        for _, col in ipairs(self.pillarColumns) do
            local pillarKey = col._pillarKey
            local value = Mapper.PillarValue(session, pillarKey)
            local count = #(self._pillarLines[pillarKey] or {})
            col:SetData(Mapper.GetLabel(pillarKey), value, "", count)
            col:SetActive(self.activePillar == pillarKey)
        end

        -- Reset drilldown when the session changes — it would otherwise show
        -- stale reason codes for the previous session.
        if self._lastSessionId ~= (session and session.id or nil) then
            self.activePillar = nil
            self.drilldown:Hide()
            for _, col in ipairs(self.pillarColumns) do col:SetActive(false) end
            self._lastSessionId = session and session.id or nil
        end
    else
        self.scoreboardTitle:Hide()
        self.scoreboardCaption:Hide()
        self.scoreboardRow:Hide()
        self.drilldown:Hide()
    end

    -- ----- Fight Timeline Read ------------------------------------------
    if self.timelineSection then
        local timelineVisible = sectionVis.fightTimelineRead and session ~= nil
        self.timelineSection:Refresh(session, suggestions, timelineVisible)
    end

    -- ----- Matchup Plan -------------------------------------------------
    if self.matchupSection then
        local matchupVisible = sectionVis.matchupPlan and session ~= nil
        self.matchupSection:Refresh(session, matchupVisible)
    end

    -- ----- Trends Peek --------------------------------------------------
    if self.trendsSection then
        self.trendsSection:Refresh(sectionVis.trendsPeek)
    end

    -- ----- Practice Plan ------------------------------------------------
    if self.practiceSection then
        self.practiceSection:Refresh(sectionVis.practicePlan, session)
    end

    -- ----- Evidence Drawer ----------------------------------------------
    if self.evidenceSection then
        local evidenceVisible = sectionVis.evidenceDrawer and session ~= nil
        self.evidenceSection:Refresh(evidenceVisible, session)
    end

    self:_RecalculateCanvas()
end

ns.Addon:RegisterModule("InsightsView", InsightsView)
