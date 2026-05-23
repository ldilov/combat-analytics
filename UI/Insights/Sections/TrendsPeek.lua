local _, ns = ...

-- UI/Insights/Sections/TrendsPeek.lua
--
-- "Trends Peek" section of the new Insights tab. Compact card showing a tiny
-- sparkline of pressureScore + rating delta over the last 14 days, with a
-- button that jumps to the dedicated Rating view for full detail.
--
-- All series math is in ns.InsightsTrendsPeek (pure logic). This file is a
-- thin renderer that:
--   1. Pulls session list + rating history from CombatStore on refresh
--   2. Asks InsightsTrendsPeek.Build for a descriptor
--   3. Paints a minimal sparkline made of vertical textures + a headline

local Theme       = ns.Widgets.THEME
local TrendsLogic = ns.InsightsTrendsPeek

local CARD_WIDTH       = 760
local TITLE_HEIGHT     = 18
local CAPTION_HEIGHT   = 18
local CARD_HEIGHT      = 96
local SPARK_HEIGHT     = 48
local SPARK_BAR_GAP    = 1
local SPARK_MAX_BARS   = 28
local DEFAULT_WINDOW   = 14

local TrendsPeek = {}

local function clampLen(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ---------------------------------------------------------------------------
-- Sparkline rendering helpers
-- ---------------------------------------------------------------------------
local function buildSparklineFrame(parent, width, height)
    local frame = ns.Widgets.CreateSurface(parent, width, height, Theme.barShell, Theme.border)
    frame.bars = {}

    function frame:Apply(values, minV, maxV)
        -- Hide all existing bars first.
        for _, bar in ipairs(self.bars) do bar:Hide() end

        local count = math.min(#(values or {}), SPARK_MAX_BARS)
        if count < 1 then return end

        local usableW = (self:GetWidth() or width) - 12
        local barW    = math.max(1, math.floor((usableW - (count - 1) * SPARK_BAR_GAP) / count))
        local span    = (maxV or 0) - (minV or 0)
        if span <= 0 then span = 1 end

        local startIdx = #values - count + 1
        for i = startIdx, #values do
            local localIdx = i - startIdx + 1
            local bar = self.bars[localIdx]
            if not bar then
                bar = self:CreateTexture(nil, "ARTWORK")
                bar:SetTexture("Interface\\Buttons\\WHITE8x8")
                self.bars[localIdx] = bar
            end
            local normalized = (values[i] - (minV or 0)) / span
            local barH = math.max(2, math.floor((self:GetHeight() - 8) * normalized))
            bar:SetSize(barW, barH)
            bar:ClearAllPoints()
            local x = 6 + (localIdx - 1) * (barW + SPARK_BAR_GAP)
            bar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, 4)
            bar:SetVertexColor(unpack(Theme.accent))
            bar:Show()
        end
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function TrendsPeek:Build(canvas, anchor, width)
    self.canvas = canvas
    self.width  = width or CARD_WIDTH

    self.title = ns.Widgets.CreateSectionTitle(
        canvas, "Trends Peek",
        "TOPLEFT", anchor, "BOTTOMLEFT", 0, -18
    )
    self.caption = ns.Widgets.CreateCaption(
        canvas, "Last 14 days at a glance. Open the Rating tab for full charts.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    self.card = ns.Widgets.CreateSurface(canvas, self.width, CARD_HEIGHT, Theme.panelAlt, Theme.border)
    self.card:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)

    self.card.headline = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.card.headline:SetPoint("TOPLEFT", self.card, "TOPLEFT", 12, -12)
    self.card.headline:SetPoint("RIGHT", self.card, "RIGHT", -120, -12)
    self.card.headline:SetJustifyH("LEFT")
    self.card.headline:SetTextColor(unpack(Theme.text))

    self.card.subLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.card.subLabel:SetPoint("TOPLEFT", self.card.headline, "BOTTOMLEFT", 0, -4)
    self.card.subLabel:SetTextColor(unpack(Theme.textMuted))

    self.sparkline = buildSparklineFrame(self.card, math.floor(self.width * 0.55), SPARK_HEIGHT)
    self.sparkline:SetPoint("BOTTOMLEFT", self.card, "BOTTOMLEFT", 12, 12)

    self.openRatingButton = ns.Widgets.CreateButton(self.card, "Open Rating tab", 108, 22)
    self.openRatingButton:SetPoint("TOPRIGHT", self.card, "TOPRIGHT", -12, -10)
    self.openRatingButton:SetScript("OnClick", function()
        local mainFrame = ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("MainFrame", true) or nil
        if mainFrame and mainFrame.SelectTab then
            pcall(mainFrame.SelectTab, mainFrame, "rating")
        end
    end)

    self.emptyLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.emptyLabel:SetPoint("CENTER", self.card, "CENTER", 0, 0)
    self.emptyLabel:SetTextColor(unpack(Theme.textMuted))
    self.emptyLabel:Hide()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function TrendsPeek:Refresh(visible)
    if not self.card then return 0 end
    if visible == false then
        self.title:Hide(); self.caption:Hide(); self.card:Hide()
        return 0
    end
    self.title:Show(); self.caption:Show(); self.card:Show()

    local store = ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("CombatStore", true) or nil
    local sessions = {}
    local rating   = {}
    if store then
        if store.GetRecentSessionStreak then
            local ok, list = pcall(store.GetRecentSessionStreak, store, 50)
            if ok and type(list) == "table" then sessions = list end
        end
        if store.GetRatingTrend then
            local ok, list = pcall(store.GetRatingTrend, store, nil, nil, nil, 50)
            if ok and type(list) == "table" then rating = list end
        end
    end

    local descriptor = TrendsLogic.Build(sessions, rating, { windowDays = DEFAULT_WINDOW })
    local windowDays = descriptor.windowDays or DEFAULT_WINDOW

    self.card.headline:SetText(descriptor.headline or "")

    if descriptor.hasSparkline then
        self.sparkline:Show()
        self.sparkline:Apply(descriptor.sparkline.values, descriptor.sparkline.min, descriptor.sparkline.max)
        local subBits = {}
        subBits[#subBits + 1] = string.format("pressure (%d samples)", descriptor.sparkline.sampleCount)
        if descriptor.sparkline.min and descriptor.sparkline.max then
            subBits[#subBits + 1] = string.format("range %d..%d",
                math.floor(descriptor.sparkline.min + 0.5),
                math.floor(descriptor.sparkline.max + 0.5))
        end
        self.card.subLabel:SetText(table.concat(subBits, "  |  "))
    else
        self.sparkline:Hide()
        self.card.subLabel:SetText(string.format("Need at least 2 sessions in the last %d days for a sparkline.", windowDays))
    end

    if not descriptor.hasData then
        self.emptyLabel:SetText(string.format("No data captured in the last %d days yet.", windowDays))
        self.emptyLabel:Show()
        self.card.headline:SetText("")
        self.card.subLabel:SetText("")
    else
        self.emptyLabel:Hide()
    end

    self.card:SetHeight(CARD_HEIGHT)
    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + CARD_HEIGHT
end

function TrendsPeek:_Height()
    if not self.card or not self.card:IsShown() then return 0 end
    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + (self.card:GetHeight() or CARD_HEIGHT)
end

ns.InsightsTrendsPeekView = TrendsPeek
return TrendsPeek
