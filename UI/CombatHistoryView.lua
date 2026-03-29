local _, ns = ...

local Constants = ns.Constants

-- T060: LAYOUT-derived row constants — history row spans 3 single-line rows
-- Evaluated lazily on first use because ns.Widgets may not be available at parse time.
local HIST_ROW_H, HIST_ROW_GAP
local function getHistRowDims()
    if not HIST_ROW_H then
        local L    = ns.Widgets.LAYOUT
        HIST_ROW_H   = L.ROW_HEIGHT * 3 - 2   -- 58
        HIST_ROW_GAP = L.ROW_GAP + 2           -- 6
    end
    return HIST_ROW_H, HIST_ROW_GAP
end

local CombatHistoryView = {
    viewId = "history",
    page = 1,
    rowCount = 6,
    filterResult = nil, -- nil = all, "won", "lost"
    filterContext = nil, -- nil = all, or a Constants.CONTEXT value
}

local function prettifyToken(value)
    local text = tostring(value or "unknown")
    text = string.gsub(text, "_", " ")
    text = string.lower(text)
    return string.gsub(text, "(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. rest
    end)
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
    return map[value] or prettifyToken(value)
end

function CombatHistoryView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Combat History", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Chronological record of finalized sessions. Click a row to inspect the full detail view.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Result filter buttons: All / Won / Lost
    self.filterAllButton = ns.Widgets.CreateButton(self.frame, "All", 60, 22)
    self.filterAllButton:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -10)
    self.filterAllButton:SetActive(true)
    self.filterAllButton:SetScript("OnClick", function()
        self.filterResult = nil
        self.page = 1
        self:UpdateFilterButtons()
        self:Refresh()
    end)

    self.filterWonButton = ns.Widgets.CreateButton(self.frame, "Won", 60, 22)
    self.filterWonButton:SetPoint("LEFT", self.filterAllButton, "RIGHT", 6, 0)
    self.filterWonButton:SetScript("OnClick", function()
        self.filterResult = "won"
        self.page = 1
        self:UpdateFilterButtons()
        self:Refresh()
    end)

    self.filterLostButton = ns.Widgets.CreateButton(self.frame, "Lost", 60, 22)
    self.filterLostButton:SetPoint("LEFT", self.filterWonButton, "RIGHT", 6, 0)
    self.filterLostButton:SetScript("OnClick", function()
        self.filterResult = "lost"
        self.page = 1
        self:UpdateFilterButtons()
        self:Refresh()
    end)

    self.prevButton = ns.Widgets.CreateButton(self.frame, "Prev", 80, 22)
    self.prevButton:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -112, -12)
    self.prevButton:SetScript("OnClick", function()
        self.page = math.max(1, self.page - 1)
        self:Refresh()
    end)

    self.nextButton = ns.Widgets.CreateButton(self.frame, "Next", 80, 22)
    self.nextButton:SetPoint("LEFT", self.prevButton, "RIGHT", 8, 0)
    self.nextButton:SetScript("OnClick", function()
        self.page = self.page + 1
        self:Refresh()
    end)

    self.pageText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.pageText:SetPoint("TOPRIGHT", self.prevButton, "BOTTOMRIGHT", 0, -6)
    self.pageText:SetTextColor(unpack(ns.Widgets.THEME.textMuted))

    -- 20-session results sparkline at top
    self.sparklineLabel = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.sparklineLabel:SetPoint("TOPLEFT", self.filterAllButton, "BOTTOMLEFT", 0, -10)
    self.sparklineLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.sparklineLabel:SetText("Last 20 sessions:")

    self.sparkline = ns.Widgets.CreateSparkline(self.frame, {}, ns.Widgets.THEME.accent, 200, 14)
    self.sparkline:SetPoint("LEFT", self.sparklineLabel, "RIGHT", 8, 0)
    self.sparkline:Hide()

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 370)
    self.shell:SetPoint("TOPLEFT", self.sparklineLabel, "BOTTOMLEFT", 0, -8)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 48)

    local histH, histGap = getHistRowDims()

    self.rows = {}
    for index = 1, self.rowCount do
        local row = ns.Widgets.CreateHistoryRow(self.canvas, 750, histH)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", self.rows[index - 1], "BOTTOMLEFT", 0, -histGap)
        end
        row:SetScript("OnClick", function(button)
            if button.sessionId then
                if ns.Addon.SetReviewedSession then
                    ns.Addon:SetReviewedSession(button.sessionId, "history")
                end
                ns.Addon:OpenView("detail", { sessionId = button.sessionId })
            end
        end)
        self.rows[index] = row
    end

    self.replayButtons = {}
    for index = 1, self.rowCount do
        local row = self.rows[index]
        local btn = ns.Widgets.CreateButton(self.canvas, "Replay", 60, 20)
        btn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)
        btn:Hide()
        btn:SetScript("OnClick", function()
            if btn.sessionId then
                local store = ns.Addon:GetModule("CombatStore")
                local session = store and store:GetCombatById(btn.sessionId)
                if session and ns.ReplayView then
                    ns.ReplayView:Show(session)
                end
            end
        end)
        self.replayButtons[index] = btn
    end

    -- Context filter toggle buttons at the bottom
    self.ctxFilterFrame = CreateFrame("Frame", nil, self.frame)
    self.ctxFilterFrame:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 16, 12)
    self.ctxFilterFrame:SetSize(400, 26)

    self.ctxBtnAll = ns.Widgets.CreateButton(self.ctxFilterFrame, "All", 60, 22)
    self.ctxBtnAll:SetPoint("LEFT", self.ctxFilterFrame, "LEFT", 0, 0)
    self.ctxBtnAll:SetActive(true)
    self.ctxBtnAll:SetScript("OnClick", function()
        self.filterContext = nil
        self.page = 1
        self:UpdateContextFilterButtons()
        self:Refresh()
    end)

    self.ctxBtnArena = ns.Widgets.CreateButton(self.ctxFilterFrame, "Arena", 64, 22)
    self.ctxBtnArena:SetPoint("LEFT", self.ctxBtnAll, "RIGHT", 6, 0)
    self.ctxBtnArena:SetScript("OnClick", function()
        self.filterContext = Constants.CONTEXT and Constants.CONTEXT.ARENA or "ARENA"
        self.page = 1
        self:UpdateContextFilterButtons()
        self:Refresh()
    end)

    self.ctxBtnDuel = ns.Widgets.CreateButton(self.ctxFilterFrame, "Duel", 60, 22)
    self.ctxBtnDuel:SetPoint("LEFT", self.ctxBtnArena, "RIGHT", 6, 0)
    self.ctxBtnDuel:SetScript("OnClick", function()
        self.filterContext = Constants.CONTEXT and Constants.CONTEXT.DUEL or "DUEL"
        self.page = 1
        self:UpdateContextFilterButtons()
        self:Refresh()
    end)

    self.ctxBtnDummy = ns.Widgets.CreateButton(self.ctxFilterFrame, "Dummy", 66, 22)
    self.ctxBtnDummy:SetPoint("LEFT", self.ctxBtnDuel, "RIGHT", 6, 0)
    self.ctxBtnDummy:SetScript("OnClick", function()
        self.filterContext = Constants.CONTEXT and Constants.CONTEXT.TRAINING_DUMMY or "TRAINING_DUMMY"
        self.page = 1
        self:UpdateContextFilterButtons()
        self:Refresh()
    end)

    -- Duel Lab opponent card pool (object pool, created once)
    self.duelLabHeader = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.duelLabHeader:SetTextColor(unpack(ns.Widgets.THEME.text))
    self.duelLabHeader:SetText("Duel Lab \226\128\148 Opponent Series")
    self.duelLabHeader:Hide()

    local DUEL_LAB_MAX = 10
    local CARD_HEIGHT = 62
    self.duelLabCards = {}
    for i = 1, DUEL_LAB_MAX do
        local card = ns.Widgets.CreateSurface(self.canvas, 750, CARD_HEIGHT, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)
        card.nameText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        card.nameText:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
        card.scoreText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        card.scoreText:SetPoint("LEFT", card.nameText, "RIGHT", 12, 0)
        card.scoreText:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
        card.openerBar = ns.Widgets.CreateMetricBar(card, 200, 28)
        card.openerBar:SetPoint("TOPLEFT", card.nameText, "BOTTOMLEFT", 0, -4)
        card.trendPill = ns.Widgets.CreatePill(card, 70, 16, ns.Widgets.THEME.accentSoft, ns.Widgets.THEME.border)
        card.trendPill:SetPoint("LEFT", card.openerBar, "RIGHT", 8, 0)
        card.infoText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.infoText:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -8)
        card.infoText:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
        card:Hide()
        self.duelLabCards[i] = card
    end

    local hH, hGap = getHistRowDims()
    ns.Widgets.SetCanvasHeight(self.canvas, (self.rowCount * (hH + hGap)) + ns.Widgets.LAYOUT.ROW_GAP * 2)

    return self.frame
end

function CombatHistoryView:UpdateFilterButtons()
    self.filterAllButton:SetActive(self.filterResult == nil)
    self.filterWonButton:SetActive(self.filterResult == "won")
    self.filterLostButton:SetActive(self.filterResult == "lost")
end

function CombatHistoryView:UpdateContextFilterButtons()
    local ctx = self.filterContext
    if self.ctxBtnAll then self.ctxBtnAll:SetActive(ctx == nil) end
    if self.ctxBtnArena then self.ctxBtnArena:SetActive(ctx == (Constants.CONTEXT and Constants.CONTEXT.ARENA or "ARENA")) end
    if self.ctxBtnDuel then self.ctxBtnDuel:SetActive(ctx == (Constants.CONTEXT and Constants.CONTEXT.DUEL or "DUEL")) end
    if self.ctxBtnDummy then self.ctxBtnDummy:SetActive(ctx == (Constants.CONTEXT and Constants.CONTEXT.TRAINING_DUMMY or "TRAINING_DUMMY")) end
end

function CombatHistoryView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store:GetCurrentCharacterKey()
    local latestSession = store:GetLatestSession(characterKey)
    if latestSession then
        self.caption:SetText(string.format("Chronological record of finalized sessions for %s. Click a row to inspect the full detail view.", store:GetSessionCharacterLabel(latestSession)))
    else
        self.caption:SetText("Chronological record of finalized sessions for the current character. Click a row to inspect the full detail view.")
    end
    local filters = {}
    if self.filterResult then
        filters.result = self.filterResult
    end
    if self.filterContext then
        filters.context = self.filterContext
    end
    local sessions, total = store:ListCombats(self.page, self.rowCount, filters, characterKey)
    local totalPages = math.max(1, math.ceil(total / self.rowCount))
    if self.page > totalPages then
        self.page = totalPages
        sessions, total = store:ListCombats(self.page, self.rowCount, filters, characterKey)
    end

    self.pageText:SetText(string.format("Page %d / %d", self.page, totalPages))
    self.prevButton:SetEnabled(self.page > 1)
    self.nextButton:SetEnabled(self.page < totalPages)
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    end

    -- 20-session results sparkline
    if self.sparkline then
        local allSessions, allTotal = store:ListCombats(1, 20, {}, characterKey)
        local sparkData = {}
        for i = 1, math.min(allTotal, 20) do
            local s = allSessions[i]
            if s then
                sparkData[#sparkData + 1] = (s.result == "won") and 1 or 0
            end
        end
        if #sparkData > 0 then
            self.sparkline:Hide()
            local anchor = { self.sparkline:GetPoint(1) }
            self.sparkline = ns.Widgets.CreateSparkline(
                self.frame, sparkData, ns.Widgets.THEME.success, 200, 14
            )
            if anchor[1] then
                self.sparkline:SetPoint(anchor[1], anchor[2], anchor[3], anchor[4], anchor[5])
            else
                self.sparkline:SetPoint("LEFT", self.sparklineLabel, "RIGHT", 8, 0)
            end
            self.sparkline:Show()
        else
            self.sparkline:Hide()
        end
    end

    for index = 1, self.rowCount do
        local row = self.rows[index]
        local session = sessions[index]
        if session then
            row:Show()
            row.sessionId = session.id
            local rBtn = self.replayButtons and self.replayButtons[index]
            if rBtn then
                rBtn.sessionId = session.id
                rBtn:Show()
            end
            local opponent = ns.Helpers.ResolveOpponentName(session, "Unknown")
            local subcontext = session.subcontext and prettifyToken(session.subcontext) or nil
            local contextLabel = prettifyToken(session.context)
            if subcontext then
                contextLabel = string.format("%s • %s", contextLabel, subcontext)
            end
            local readQuality = formatDisplayLabel(session.analysisConfidence or "limited")
            local readSource = formatDisplayLabel(session.finalDamageSource or "damage_meter")
            -- Use the richer dataConfidence label (e.g. "Full Raw", "Enriched",
            -- "Partial Roster") when available; fall back to the 3-tier label.
            local richLabel = session.dataConfidence
                and formatDisplayLabel(session.dataConfidence)
                or readQuality

            -- T025: Determine damage display for history row based on totalAuthority.
            local importedTotals = session.importedTotals or {}
            local totalAuthority = importedTotals.totalAuthority
            local damageDisplay
            if totalAuthority == "failed" then
                damageDisplay = "|cffff8800\226\156\151 —|r"
            elseif totalAuthority == "estimated" then
                damageDisplay = "|cffa0a0a0~" .. ns.Helpers.FormatNumber(session.totals.damageDone or 0) .. "|r"
            else
                damageDisplay = ns.Helpers.FormatNumber(session.totals.damageDone or 0)
            end

            row:SetData({
                title = opponent,
                timestamp = date("%Y-%m-%d %H:%M", session.timestamp),
                meta = string.format(
                    "%s  |  %s  |  %s",
                    contextLabel,
                    prettifyToken(session.result),
                    store:GetSessionCharacterLabel(session)
                ),
                stats = string.format(
                    "Duration %s  |  Damage %s  |  Taken %s  |  Pressure %.1f  |  Burst %.1f",
                    ns.Helpers.FormatDuration(session.duration or 0),
                    damageDisplay,
                    ns.Helpers.FormatNumber(session.totals.damageTaken or 0),
                    session.metrics.pressureScore or 0,
                    session.metrics.burstScore or 0
                ),
                source = string.format("%s via %s", richLabel, readSource),
                result = string.lower(tostring(session.result or "unknown")),
                resultLabel = prettifyToken(session.result),
                analysisConfidence = session.analysisConfidence or "limited",
                confidenceLabel = richLabel,
                dataConfidence = session.dataConfidence or nil,
            })

        else
            row:Hide()
            row.sessionId = nil
            local rBtn = self.replayButtons and self.replayButtons[index]
            if rBtn then
                rBtn:Hide()
                rBtn.sessionId = nil
            end
        end
    end

    -- Duel Lab section: show when duel context filter active or duel data available
    local duelCtx = Constants.CONTEXT and Constants.CONTEXT.DUEL or "DUEL"
    local showDuelLab = (self.filterContext == duelCtx)
    local duelGroups = {}
    if showDuelLab and self.duelLabCards then
        local okSvc, duelLabSvc = pcall(function() return ns.Addon:GetModule("DuelLabService") end)
        if okSvc and duelLabSvc then
            local allDuels = store:ListCombats(1, 500, { context = duelCtx }, characterKey)
            local okGroup, grouped = pcall(function() return duelLabSvc:GroupDuelsByOpponent(allDuels) end)
            if okGroup and grouped then
                for _, entry in pairs(grouped) do
                    duelGroups[#duelGroups + 1] = entry
                end
                table.sort(duelGroups, function(a, b) return (a.totalDuels or 0) > (b.totalDuels or 0) end)
            end
        end
    end

    local DUEL_LAB_MAX = 10
    local CARD_HEIGHT = 62
    local GAP = 8
    local visibleCards = math.min(#duelGroups, DUEL_LAB_MAX)

    if visibleCards > 0 and self.duelLabHeader then
        -- Find last visible row for anchor
        local lastRow = self.rows[self.rowCount]
        self.duelLabHeader:ClearAllPoints()
        self.duelLabHeader:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, -16)
        self.duelLabHeader:Show()
    elseif self.duelLabHeader then
        self.duelLabHeader:Hide()
    end

    local TREND_COLORS = {
        improving = ns.Widgets.THEME.success,
        declining = ns.Widgets.THEME.warning,
        stable    = ns.Widgets.THEME.textMuted,
    }

    for i = 1, DUEL_LAB_MAX do
        local card = self.duelLabCards[i]
        if not card then break end
        local entry = duelGroups[i]
        if entry then
            card:ClearAllPoints()
            if i == 1 then
                card:SetPoint("TOPLEFT", self.duelLabHeader, "BOTTOMLEFT", 0, -GAP)
            else
                card:SetPoint("TOPLEFT", self.duelLabCards[i - 1], "BOTTOMLEFT", 0, -GAP)
            end
            -- Class-colored name
            local nameColor = ns.Widgets.THEME.text
            if entry.opponentClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.opponentClass] then
                local cc = RAID_CLASS_COLORS[entry.opponentClass]
                nameColor = { cc.r, cc.g, cc.b, 1.0 }
            end
            card.nameText:SetText(entry.opponentName or "Unknown")
            card.nameText:SetTextColor(unpack(nameColor))
            -- Set score W-L (D)
            local sc = entry.setScore or {}
            card.scoreText:SetText(string.format("%d-%d (%d)", sc.wins or 0, sc.losses or 0, sc.draws or 0))
            -- Opener success bar
            local opRate = entry.openerSuccessRate or 0
            card.openerBar:SetData("Opener", string.format("%.0f%%", opRate * 100), "", opRate, ns.Widgets.THEME.accent)
            -- Trend pill
            local trend = entry.adaptationTrend or "stable"
            local tColor = TREND_COLORS[trend] or ns.Widgets.THEME.textMuted
            card.trendPill:SetData(trend, tColor, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)
            -- Info text
            local avgDur = entry.averageDuration or 0
            card.infoText:SetText(string.format("%d duels | avg %s", entry.totalDuels or 0, ns.Helpers.FormatDuration(avgDur)))
            card:Show()
        else
            card:Hide()
        end
    end

    -- Adjust canvas height to accommodate duel lab cards
    local extraHeight = 0
    if visibleCards > 0 then
        extraHeight = 16 + 20 + GAP + (visibleCards * (CARD_HEIGHT + GAP))
    end
    local rH, rGap = getHistRowDims()
    ns.Widgets.SetCanvasHeight(self.canvas, (self.rowCount * (rH + rGap)) + ns.Widgets.LAYOUT.ROW_GAP * 2 + extraHeight)
end

ns.Addon:RegisterModule("CombatHistoryView", CombatHistoryView)
