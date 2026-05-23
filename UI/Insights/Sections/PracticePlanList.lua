local _, ns = ...

-- UI/Insights/Sections/PracticePlanList.lua
--
-- "Practice Plan" section of the new Insights tab. Shows recurring drills
-- — reason codes that triggered >= 2 times in the last 7 days — so the
-- player can spend a few minutes between queues drilling the actual repeat
-- failure pattern.
--
-- Data source: PracticePlannerService:GetRecurringDrills(characterKey,
-- weekDays), which delegates to the pure-logic ns.InsightsRecurringDrills.

local Theme = ns.Widgets.THEME

local CARD_WIDTH       = 760
local TITLE_HEIGHT     = 18
local CAPTION_HEIGHT   = 18
local ROW_HEIGHT       = 56
local ROW_GAP          = 6
local LIST_PADDING_Y   = 12
local MIN_LIST_HEIGHT  = 90
local DEFAULT_WINDOW   = 7

local SEVERITY_COLOR = {
    high   = Theme.warning,
    medium = Theme.accent,
    low    = Theme.textMuted,
}

local PracticePlanList = {}

local function createRow(parent, width)
    local row = ns.Widgets.CreateSurface(parent, width, ROW_HEIGHT, Theme.panel, Theme.border)

    row.severityChip = ns.Widgets.CreateSurface(row, 14, ROW_HEIGHT - 16, Theme.accentSoft, Theme.borderStrong)
    row.severityChip:SetPoint("LEFT", row, "LEFT", 10, 0)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", row.severityChip, "TOPRIGHT", 10, 0)
    row.title:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetTextColor(unpack(Theme.text))

    row.action = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.action:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
    row.action:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row.action:SetJustifyH("LEFT")
    row.action:SetJustifyV("TOP")
    row.action:SetTextColor(unpack(Theme.textMuted))

    row.countBadge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.countBadge:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.countBadge:SetJustifyH("RIGHT")
    row.countBadge:SetTextColor(unpack(Theme.text))

    function row:Apply(drill, windowDays)
        local color = SEVERITY_COLOR[drill.severity] or Theme.textMuted
        ns.Widgets.SetBackdropColors(self.severityChip, color, Theme.borderStrong)
        self.title:SetText(drill.title or drill.reasonCode or "Drill")
        self.action:SetText(drill.action or "")
        self.countBadge:SetText(string.format("x%d / %dd", drill.count or 0, windowDays or DEFAULT_WINDOW))
    end

    return row
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function PracticePlanList:Build(canvas, anchor, width)
    self.canvas = canvas
    self.width  = width or CARD_WIDTH
    self.rows   = {}

    self.title = ns.Widgets.CreateSectionTitle(
        canvas, "Practice Plan",
        "TOPLEFT", anchor, "BOTTOMLEFT", 0, -18
    )
    self.caption = ns.Widgets.CreateCaption(
        canvas, "Patterns that recurred this week. Drill the highest-severity item first.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    self.list = ns.Widgets.CreateSurface(canvas, self.width, MIN_LIST_HEIGHT, Theme.panelAlt, Theme.border)
    self.list:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)

    self.emptyLabel = self.list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.emptyLabel:SetPoint("CENTER", self.list, "CENTER", 0, 0)
    self.emptyLabel:SetTextColor(unpack(Theme.textMuted))
    self.emptyLabel:Hide()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function PracticePlanList:Refresh(visible, session)
    if not self.list then return 0 end
    if visible == false then
        self.title:Hide(); self.caption:Hide(); self.list:Hide()
        return 0
    end
    self.title:Show(); self.caption:Show(); self.list:Show()

    local planner = ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("PracticePlannerService", true) or nil
    local drills = {}
    if planner and planner.GetRecurringDrills then
        local characterKey = session and (session.characterKey or session.character) or nil
        local ok, list = pcall(planner.GetRecurringDrills, planner, characterKey, DEFAULT_WINDOW)
        if ok and type(list) == "table" then drills = list end
    end

    -- Reset existing rows
    for _, row in ipairs(self.rows) do row:Hide() end

    if #drills == 0 then
        self.emptyLabel:SetText("No recurring coaching patterns this week — keep queueing.")
        self.emptyLabel:Show()
        self.list:SetHeight(MIN_LIST_HEIGHT)
        return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + MIN_LIST_HEIGHT
    end

    self.emptyLabel:Hide()

    for i, drill in ipairs(drills) do
        local row = self.rows[i]
        if not row then
            row = createRow(self.list, self.width - 24)
            self.rows[i] = row
        end
        row:ClearAllPoints()
        if i == 1 then
            row:SetPoint("TOPLEFT", self.list, "TOPLEFT", 12, -10)
        else
            row:SetPoint("TOPLEFT", self.rows[i - 1], "BOTTOMLEFT", 0, -ROW_GAP)
        end
        row:Apply(drill, DEFAULT_WINDOW)
        row:Show()
    end

    local listHeight = math.max(MIN_LIST_HEIGHT, LIST_PADDING_Y + #drills * (ROW_HEIGHT + ROW_GAP) + 8)
    self.list:SetHeight(listHeight)
    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + listHeight
end

function PracticePlanList:_Height()
    if not self.list or not self.list:IsShown() then return 0 end
    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + (self.list:GetHeight() or MIN_LIST_HEIGHT)
end

ns.InsightsPracticePlanList = PracticePlanList
return PracticePlanList
