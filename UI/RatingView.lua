local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

-- Human-readable labels for SESSION_CONFIDENCE values shown in chart tooltips.
local CONFIDENCE_LABELS = {
    state_plus_damage_meter = "State + Damage Meter",
    damage_meter_only       = "Damage Meter Only",
    visible_cc_only         = "Visible CC Only",
    partial_roster          = "Partial Roster",
    estimated               = "Estimated",
    legacy_cleu_import      = "Legacy Import",
}

local RatingView = {
    viewId = "rating",
    activeFilter = "all",
}

local FILTERS = {
    { key = "all",          label = "All",          context = nil,                   subcontext = nil },
    { key = "rated_arena",  label = "Rated Arena",  context = "arena",               subcontext = "rated_arena" },
    { key = "solo_shuffle", label = "Solo Shuffle", context = "arena",               subcontext = "solo_shuffle" },
    { key = "rated_bg",     label = "Rated BG",     context = "battleground",        subcontext = "rated_battleground" },
    { key = "solo_rbg",     label = "Solo RBG",     context = "battleground",        subcontext = "solo_rbg" },
}

local TIER_THRESHOLDS = { 1400, 1600, 1800, 2100 }

local DOT_SIZE = 6
local LINE_THICKNESS = 2
local Y_PADDING = 20
local STAT_ROW_HEIGHT = 72
local STAT_CARD_WIDTH = 170

local COLOR_WIN = { 0.44, 0.82, 0.60, 1.0 }
local COLOR_LOSS = { 0.90, 0.30, 0.25, 1.0 }
local COLOR_LINE = { 0.35, 0.78, 0.90, 0.6 }
local COLOR_TIER = { 0.60, 0.69, 0.78, 0.25 }

local function releaseChartObjects(self)
    if self.dots then
        for _, dot in ipairs(self.dots) do
            dot:Hide()
            dot:ClearAllPoints()
        end
    end
    self.dots = {}

    if self.lines then
        for _, line in ipairs(self.lines) do
            line:SetStartPoint("CENTER", self.chartCanvas)
            line:SetEndPoint("CENTER", self.chartCanvas)
            line:Hide()
        end
    end
    self.lines = {}

    if self.tierLines then
        for _, obj in ipairs(self.tierLines) do
            obj.line:Hide()
            obj.label:Hide()
        end
    end
    self.tierLines = {}

    if self.dotTooltipFrames then
        for _, frame in ipairs(self.dotTooltipFrames) do
            frame:Hide()
            frame:ClearAllPoints()
        end
    end
    self.dotTooltipFrames = {}
end

local function computeYRange(data)
    if #data == 0 then
        return 1200, 2200
    end

    local minRating = math.huge
    local maxRating = -math.huge

    for _, entry in ipairs(data) do
        local rating = entry.ratingAfter or 0
        if rating < minRating then minRating = rating end
        if rating > maxRating then maxRating = rating end
    end

    -- Include tier thresholds that are near the data range for visual reference
    for _, threshold in ipairs(TIER_THRESHOLDS) do
        if threshold >= minRating - 200 and threshold <= maxRating + 200 then
            if threshold < minRating then minRating = threshold end
            if threshold > maxRating then maxRating = threshold end
        end
    end

    -- Add padding
    minRating = minRating - Y_PADDING
    maxRating = maxRating + Y_PADDING

    -- Ensure a minimum range so the chart is not too compressed
    if maxRating - minRating < 100 then
        local mid = (minRating + maxRating) / 2
        minRating = mid - 50
        maxRating = mid + 50
    end

    return math.floor(minRating), math.ceil(maxRating)
end

local function ratingToY(rating, minR, maxR, canvasHeight)
    if maxR <= minR then return canvasHeight / 2 end
    local fraction = (rating - minR) / (maxR - minR)
    -- Y=0 is top in WoW frames, so invert: higher rating = higher on screen = smaller Y offset from top
    return canvasHeight - (fraction * canvasHeight)
end

local function indexToX(index, count, canvasWidth)
    if count <= 1 then return canvasWidth / 2 end
    local margin = 30
    local usable = canvasWidth - (margin * 2)
    return margin + ((index - 1) / (count - 1)) * usable
end

function RatingView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Rating Progression", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Track your rating changes over the last 50 rated sessions.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Filter bar
    self.filterBar = CreateFrame("Frame", nil, self.frame)
    self.filterBar:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.filterBar:SetPoint("RIGHT", self.frame, "RIGHT", -16, 0)
    self.filterBar:SetHeight(24)

    self.filterButtons = {}
    local prevButton = nil
    for _, filter in ipairs(FILTERS) do
        local width = math.max(72, 20 + (string.len(filter.label) * 8))
        local button = ns.Widgets.CreateButton(self.filterBar, filter.label, width, 22)
        if prevButton then
            button:SetPoint("TOPLEFT", prevButton, "TOPRIGHT", 6, 0)
        else
            button:SetPoint("TOPLEFT", self.filterBar, "TOPLEFT", 0, 0)
        end
        button:SetScript("OnClick", function()
            self.activeFilter = filter.key
            self:Refresh()
        end)
        self.filterButtons[filter.key] = button
        prevButton = button
    end

    -- Summary stats row — anchored to the BOTTOM so it never gets clipped
    self.summaryBar = CreateFrame("Frame", nil, self.frame)
    self.summaryBar:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 16, 8)
    self.summaryBar:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 8)
    self.summaryBar:SetHeight(STAT_ROW_HEIGHT)

    self.statCards = {}
    local cardLabels = { "Current Rating", "Peak Rating", "Win Streak", "Loss Streak" }
    for i = 1, 4 do
        local card = ns.Widgets.CreateMetricCard(self.summaryBar, STAT_CARD_WIDTH, STAT_ROW_HEIGHT - 4)
        if i == 1 then
            card:SetPoint("TOPLEFT", self.summaryBar, "TOPLEFT", 0, 0)
        else
            card:SetPoint("TOPLEFT", self.statCards[i - 1], "TOPRIGHT", 8, 0)
        end
        card:SetData("--", cardLabels[i], "")
        self.statCards[i] = card
    end

    -- Confidence pill — anchored after the last stat card; updated on refresh
    self.confidencePillAnchor = CreateFrame("Frame", nil, self.summaryBar)
    self.confidencePillAnchor:SetPoint("TOPLEFT", self.statCards[4], "TOPRIGHT", 12, 0)
    self.confidencePillAnchor:SetSize(100, STAT_ROW_HEIGHT - 4)
    self.confidencePill = nil

    -- Chart background surface — fills space between filter bar and summary bar
    self.chartShell = ns.Widgets.CreateSurface(self.frame, 1, 1, Theme.panel, Theme.border)
    self.chartShell:SetPoint("TOPLEFT", self.filterBar, "BOTTOMLEFT", 0, -10)
    self.chartShell:SetPoint("BOTTOMRIGHT", self.summaryBar, "TOPRIGHT", 0, -10)

    -- Chart canvas (inner area where dots and lines are drawn)
    self.chartCanvas = CreateFrame("Frame", nil, self.chartShell)
    self.chartCanvas:SetPoint("TOPLEFT", self.chartShell, "TOPLEFT", 40, -10)
    self.chartCanvas:SetPoint("BOTTOMRIGHT", self.chartShell, "BOTTOMRIGHT", -10, 20)

    -- Empty state
    self.emptyState = self.chartCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("CENTER", self.chartCanvas, "CENTER", 0, 0)
    self.emptyState:SetTextColor(unpack(Theme.textMuted))
    self.emptyState:SetText("No rated sessions found for this filter.")

    -- Y-axis labels pool
    self.yAxisLabels = {}

    self.dots = {}
    self.lines = {}
    self.tierLines = {}
    self.dotTooltipFrames = {}

    return self.frame
end

function RatingView:Refresh()
    if not self.frame then return end

    -- Update filter button states
    for key, button in pairs(self.filterButtons) do
        button:SetActive(key == self.activeFilter)
    end

    -- Fetch data
    local filter = nil
    for _, f in ipairs(FILTERS) do
        if f.key == self.activeFilter then
            filter = f
            break
        end
    end
    filter = filter or FILTERS[1]

    local store = ns.Addon:GetModule("CombatStore")
    local data = store:GetRatingTrend(nil, filter.context, filter.subcontext, 50)

    -- Clean up previous chart objects
    releaseChartObjects(self)

    if not data or #data == 0 then
        self.emptyState:Show()
        self:UpdateSummaryStats(data)
        return
    end

    self.emptyState:Hide()

    local canvasWidth = self.chartCanvas:GetWidth() or 700
    local canvasHeight = self.chartCanvas:GetHeight() or 200
    if canvasWidth < 10 then canvasWidth = 700 end
    if canvasHeight < 10 then canvasHeight = 200 end

    local minR, maxR = computeYRange(data)

    -- Draw tier threshold lines
    for _, threshold in ipairs(TIER_THRESHOLDS) do
        if threshold >= minR and threshold <= maxR then
            local y = ratingToY(threshold, minR, maxR, canvasHeight)

            local tierLine = self.chartCanvas:CreateLine(nil, "BACKGROUND")
            tierLine:SetThickness(1)
            tierLine:SetStartPoint("TOPLEFT", self.chartCanvas, 0, -y)
            tierLine:SetEndPoint("TOPLEFT", self.chartCanvas, canvasWidth, -y)
            tierLine:SetColorTexture(COLOR_TIER[1], COLOR_TIER[2], COLOR_TIER[3], COLOR_TIER[4])
            tierLine:Show()

            local tierLabel = self.chartCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            tierLabel:SetPoint("RIGHT", self.chartCanvas, "TOPLEFT", -4, -y)
            tierLabel:SetText(tostring(threshold))
            tierLabel:SetTextColor(unpack(Theme.textMuted))
            tierLabel:Show()

            self.tierLines[#self.tierLines + 1] = { line = tierLine, label = tierLabel }
        end
    end

    -- Draw Y-axis range labels (min and max)
    for _, lbl in ipairs(self.yAxisLabels) do
        lbl:Hide()
    end
    self.yAxisLabels = {}

    local minLabel = self.chartCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    minLabel:SetPoint("RIGHT", self.chartCanvas, "BOTTOMLEFT", -4, 0)
    minLabel:SetText(tostring(minR))
    minLabel:SetTextColor(unpack(Theme.textMuted))
    self.yAxisLabels[#self.yAxisLabels + 1] = minLabel

    local maxLabel = self.chartCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    maxLabel:SetPoint("RIGHT", self.chartCanvas, "TOPLEFT", -4, 0)
    maxLabel:SetText(tostring(maxR))
    maxLabel:SetTextColor(unpack(Theme.textMuted))
    self.yAxisLabels[#self.yAxisLabels + 1] = maxLabel

    -- Draw data points and connecting lines
    local count = #data
    local prevDot = nil

    for i, entry in ipairs(data) do
        local rating = entry.ratingAfter or 0
        local x = indexToX(i, count, canvasWidth)
        local y = ratingToY(rating, minR, maxR, canvasHeight)
        local isWin = entry.result == "won"
        local dotColor = isWin and COLOR_WIN or COLOR_LOSS

        -- Create dot
        local dot = CreateFrame("Frame", nil, self.chartCanvas)
        dot:SetSize(DOT_SIZE, DOT_SIZE)
        dot:SetPoint("CENTER", self.chartCanvas, "TOPLEFT", x, -y)
        dot:SetFrameLevel(self.chartCanvas:GetFrameLevel() + 2)

        local dotTexture = dot:CreateTexture(nil, "ARTWORK")
        dotTexture:SetTexture("Interface\\Buttons\\WHITE8x8")
        dotTexture:SetAllPoints()
        dotTexture:SetVertexColor(dotColor[1], dotColor[2], dotColor[3], dotColor[4])

        self.dots[#self.dots + 1] = dot

        -- Tooltip hover frame (slightly larger for easier mouse targeting)
        local tooltipFrame = CreateFrame("Frame", nil, self.chartCanvas)
        tooltipFrame:SetSize(DOT_SIZE + 8, DOT_SIZE + 8)
        tooltipFrame:SetPoint("CENTER", dot, "CENTER", 0, 0)
        tooltipFrame:SetFrameLevel(self.chartCanvas:GetFrameLevel() + 3)
        tooltipFrame:EnableMouse(true)

        local entryData = entry
        local entryIndex = i

        -- Pre-resolve confidence label for this data point so the tooltip
        -- closure does not need to call store:GetCombatById on every hover.
        local confidenceLabel = "Unknown"
        if entryData.sessionId then
            local session = store:GetCombatById(entryData.sessionId)
            if session and session.captureQuality and session.captureQuality.confidence then
                confidenceLabel = CONFIDENCE_LABELS[session.captureQuality.confidence] or session.captureQuality.confidence
            end
        end

        tooltipFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(string.format("Session %d", entryIndex), 1, 1, 1)
            GameTooltip:AddLine(string.format("Rating: %d", entryData.ratingAfter or 0), unpack(Theme.text))
            local changeStr = ""
            local change = entryData.change or 0
            if change > 0 then
                changeStr = string.format("|cff70d196+%d|r", change)
            elseif change < 0 then
                changeStr = string.format("|cffe64d40%d|r", change)
            else
                changeStr = "0"
            end
            GameTooltip:AddLine(string.format("Change: %s", changeStr), 1, 1, 1)
            if entryData.mmrAfter and entryData.mmrAfter > 0 then
                GameTooltip:AddLine(string.format("MMR: %d", entryData.mmrAfter), unpack(Theme.textMuted))
            end
            if entryData.timestamp then
                GameTooltip:AddLine(date("%Y-%m-%d %H:%M", entryData.timestamp), unpack(Theme.textMuted))
            end
            local resultText = entryData.result == "won" and "|cff70d196Won|r" or "|cffe64d40Lost|r"
            GameTooltip:AddLine(resultText, 1, 1, 1)
            GameTooltip:AddLine(string.format("Confidence: %s", confidenceLabel), unpack(Theme.textMuted))
            GameTooltip:Show()
        end)
        tooltipFrame:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        self.dotTooltipFrames[#self.dotTooltipFrames + 1] = tooltipFrame

        -- Connect to previous dot with a line
        if prevDot then
            local line = self.chartCanvas:CreateLine(nil, "ARTWORK")
            line:SetThickness(LINE_THICKNESS)
            line:SetStartPoint("CENTER", prevDot)
            line:SetEndPoint("CENTER", dot)
            line:SetColorTexture(COLOR_LINE[1], COLOR_LINE[2], COLOR_LINE[3], COLOR_LINE[4])
            line:Show()
            self.lines[#self.lines + 1] = line
        end

        prevDot = dot
    end

    self:UpdateSummaryStats(data)
end

function RatingView:UpdateConfidencePill(data)
    -- Hide any existing pill before potentially creating a new one.
    if self.confidencePill then
        self.confidencePill:Hide()
    end

    if not data or #data == 0 then
        return
    end

    local store = ns.Addon:GetModule("CombatStore")
    local latestEntry = data[#data]
    local confidence = nil

    if latestEntry.sessionId then
        local session = store:GetCombatById(latestEntry.sessionId)
        if session and session.captureQuality and session.captureQuality.confidence then
            confidence = session.captureQuality.confidence
        end
    end

    if not confidence then
        return
    end

    -- Create a fresh pill each refresh (cheap; one small frame + font string).
    self.confidencePill = ns.Widgets.CreateConfidencePill(self.confidencePillAnchor, confidence)
    self.confidencePill:SetPoint("TOPLEFT", self.confidencePillAnchor, "TOPLEFT", 0, -6)

    -- For degraded confidence levels, replace the default tooltip with a warning.
    local WARNING_LEVELS = { estimated = true, partial_roster = true }
    if WARNING_LEVELS[confidence] then
        local warningLabel = CONFIDENCE_LABELS[confidence] or confidence
        self.confidencePill:SetScript("OnEnter", function(pill)
            GameTooltip:SetOwner(pill, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Data Quality Warning", 0.96, 0.74, 0.38)
            GameTooltip:AddLine(
                string.format("Latest session confidence: %s. Rating and stat accuracy may be limited.", warningLabel),
                0.8, 0.8, 0.8, true
            )
            GameTooltip:Show()
        end)
        self.confidencePill:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
end

function RatingView:UpdateSummaryStats(data)
    if not data or #data == 0 then
        for i = 1, 4 do
            self.statCards[i]:SetData("--", ({ "Current Rating", "Peak Rating", "Win Streak", "Loss Streak" })[i], "No rated data")
        end
        self:UpdateConfidencePill(data)
        return
    end

    local currentRating = data[#data].ratingAfter or 0
    local peakRating = 0
    local bestWinStreak = 0
    local bestLossStreak = 0
    local currentWinStreak = 0
    local currentLossStreak = 0

    for _, entry in ipairs(data) do
        local rating = entry.ratingAfter or 0
        if rating > peakRating then peakRating = rating end

        if entry.result == "won" then
            currentWinStreak = currentWinStreak + 1
            currentLossStreak = 0
        else
            currentLossStreak = currentLossStreak + 1
            currentWinStreak = 0
        end

        if currentWinStreak > bestWinStreak then bestWinStreak = currentWinStreak end
        if currentLossStreak > bestLossStreak then bestLossStreak = currentLossStreak end
    end

    local lastChange = data[#data].change or 0
    local changeText
    if lastChange > 0 then
        changeText = string.format("Last: +%d", lastChange)
    elseif lastChange < 0 then
        changeText = string.format("Last: %d", lastChange)
    else
        changeText = "Last: 0"
    end

    self.statCards[1]:SetData(tostring(currentRating), "Current Rating", changeText, Theme.accent)
    self.statCards[2]:SetData(tostring(peakRating), "Peak Rating", string.format("Over last %d sessions", #data), Theme.warning)
    self.statCards[3]:SetData(tostring(bestWinStreak), "Best Win Streak", string.format("%d sessions tracked", #data), Theme.success)
    self.statCards[4]:SetData(tostring(bestLossStreak), "Worst Loss Streak", string.format("%d sessions tracked", #data), { 0.90, 0.30, 0.25, 1.0 })

    self:UpdateConfidencePill(data)
end

ns.Addon:RegisterModule("RatingView", RatingView)
