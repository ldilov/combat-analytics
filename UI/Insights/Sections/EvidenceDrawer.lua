local _, ns = ...

-- UI/Insights/Sections/EvidenceDrawer.lua
--
-- "Evidence Drawer" section of the new Insights tab. Collapsed by default;
-- when expanded, shows every suggestion attached to the active session with
-- a filter-chip row (All / Offense / Defense / CC / Matchup / Consistency /
-- Meta) driven by ns.InsightsEvidenceFilter.
--
-- This is the "show me everything" surface — the rest of the Insights tab
-- summarises, this one enumerates.

local Theme         = ns.Widgets.THEME
local Filter        = ns.InsightsEvidenceFilter

local CARD_WIDTH       = 760
local TITLE_HEIGHT     = 18
local CAPTION_HEIGHT   = 18
local HEADER_HEIGHT    = 32
local CHIP_HEIGHT      = 22
local CHIP_GAP         = 6
local ROW_HEIGHT       = 44
local ROW_GAP          = 4
local LIST_PAD_Y       = 12
local MAX_ROWS         = 30  -- bounded pool; matches SuggestionEngine cap

local EvidenceDrawer = {}

-- Single suggestion row.
local function createRow(parent, width)
    local row = ns.Widgets.CreateSurface(parent, width, ROW_HEIGHT, Theme.panel, Theme.border)

    row.severityBadge = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.severityBadge:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -8)
    row.severityBadge:SetWidth(60)
    row.severityBadge:SetJustifyH("LEFT")

    row.code = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.code:SetPoint("TOPLEFT", row.severityBadge, "TOPRIGHT", 6, 0)
    row.code:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.code:SetJustifyH("LEFT")
    row.code:SetTextColor(unpack(Theme.text))

    row.message = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.message:SetPoint("TOPLEFT", row.code, "BOTTOMLEFT", 0, -3)
    row.message:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.message:SetJustifyH("LEFT")
    row.message:SetJustifyV("TOP")
    row.message:SetTextColor(unpack(Theme.textMuted))

    function row:Apply(suggestion)
        local sev = suggestion.severity or "info"
        self.severityBadge:SetText(string.upper(sev))
        if sev == "high" then
            self.severityBadge:SetTextColor(unpack(Theme.warning))
        elseif sev == "medium" then
            self.severityBadge:SetTextColor(unpack(Theme.accent))
        else
            self.severityBadge:SetTextColor(unpack(Theme.textMuted))
        end
        self.code:SetText(suggestion.reasonCode or "UNKNOWN")
        self.message:SetText(suggestion.message or suggestion.evidence and tostring(suggestion.evidence) or "")
    end

    return row
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function EvidenceDrawer:Build(canvas, anchor, width)
    self.canvas       = canvas
    self.width        = width or CARD_WIDTH
    self.expanded     = false
    self.activeChip   = Filter.CHIP.ALL
    self.chips        = {}
    self.rows         = {}
    self._suggestions = {}

    self.title = ns.Widgets.CreateSectionTitle(
        canvas, "Evidence Drawer",
        "TOPLEFT", anchor, "BOTTOMLEFT", 0, -18
    )
    self.caption = ns.Widgets.CreateCaption(
        canvas, "Every coaching note attached to this session.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    -- Toggle button doubles as the "header" so collapsed state has only
    -- the title + caption + button in the canvas.
    self.toggleButton = ns.Widgets.CreateButton(canvas, "▸ Show all notes", 160, HEADER_HEIGHT - 4)
    self.toggleButton:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)
    self.toggleButton:SetScript("OnClick", function()
        self:Toggle()
    end)

    -- Chip row (hidden until expanded)
    self.chipRow = CreateFrame("Frame", nil, canvas)
    self.chipRow:SetSize(self.width, CHIP_HEIGHT)
    self.chipRow:SetPoint("TOPLEFT", self.toggleButton, "BOTTOMLEFT", 0, -8)
    self.chipRow:Hide()

    -- List surface (hidden until expanded)
    self.list = ns.Widgets.CreateSurface(canvas, self.width, ROW_HEIGHT * 3, Theme.panelAlt, Theme.border)
    self.list:SetPoint("TOPLEFT", self.chipRow, "BOTTOMLEFT", 0, -8)
    self.list:Hide()

    self.emptyLabel = self.list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.emptyLabel:SetPoint("CENTER", self.list, "CENTER", 0, 0)
    self.emptyLabel:SetTextColor(unpack(Theme.textMuted))
end

local function ensureChips(self)
    if #self.chips > 0 then return end
    for i, chipKey in ipairs(Filter.CHIP_ORDER) do
        local chip = ns.Widgets.CreateButton(self.chipRow, Filter.CHIP_LABEL[chipKey] or chipKey, 92, CHIP_HEIGHT)
        if i == 1 then
            chip:SetPoint("LEFT", self.chipRow, "LEFT", 0, 0)
        else
            chip:SetPoint("LEFT", self.chips[i - 1], "RIGHT", CHIP_GAP, 0)
        end
        chip._chipKey = chipKey
        chip:SetScript("OnClick", function()
            self.activeChip = chipKey
            self:_RenderList()
            for _, c in ipairs(self.chips) do c:SetActive(c._chipKey == self.activeChip) end
            if self._onLayoutChange then self._onLayoutChange() end
        end)
        self.chips[i] = chip
    end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function EvidenceDrawer:Refresh(visible, session)
    if not self.toggleButton then return 0 end
    if visible == false then
        self.title:Hide(); self.caption:Hide(); self.toggleButton:Hide()
        self.chipRow:Hide(); self.list:Hide()
        return 0
    end

    self.title:Show(); self.caption:Show(); self.toggleButton:Show()

    self._suggestions = (session and (session.allSuggestions or session.suggestions)) or {}
    self.toggleButton:SetText(self.expanded
        and string.format("▾ Hide notes (%d)", #self._suggestions)
        or  string.format("▸ Show all notes (%d)", #self._suggestions))

    if not self.expanded then
        self.chipRow:Hide(); self.list:Hide()
        return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + HEADER_HEIGHT
    end

    ensureChips(self)
    self.chipRow:Show()
    self.list:Show()

    local counts = Filter.CountByChip(self._suggestions)
    for _, chip in ipairs(self.chips) do
        local n = counts[chip._chipKey] or 0
        chip:SetText(string.format("%s (%d)", Filter.CHIP_LABEL[chip._chipKey] or chip._chipKey, n))
        chip:SetActive(chip._chipKey == self.activeChip)
    end

    self:_RenderList()
    return self:_Height()
end

function EvidenceDrawer:_RenderList()
    local filtered = Filter.FilterByChip(self._suggestions, self.activeChip)

    for _, row in ipairs(self.rows) do row:Hide() end
    if self.overflowLabel then self.overflowLabel:Hide() end

    if #filtered == 0 then
        self.emptyLabel:SetText("No notes in this category.")
        self.emptyLabel:Show()
        self.list:SetHeight(ROW_HEIGHT * 2)
        return
    end
    self.emptyLabel:Hide()

    local visibleCount = math.min(#filtered, MAX_ROWS)
    for i = 1, visibleCount do
        local sug = filtered[i]
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
        row:Apply(sug)
        row:Show()
    end

    -- Overflow label when filtered list exceeds the pool cap.
    local hiddenCount = #filtered - visibleCount
    if hiddenCount > 0 then
        if not self.overflowLabel then
            self.overflowLabel = self.list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            self.overflowLabel:SetJustifyH("LEFT")
            self.overflowLabel:SetTextColor(unpack(Theme.textMuted))
        end
        self.overflowLabel:ClearAllPoints()
        local anchor = visibleCount > 0 and self.rows[visibleCount] or self.list
        if visibleCount > 0 then
            self.overflowLabel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -ROW_GAP)
        else
            self.overflowLabel:SetPoint("TOPLEFT", self.list, "TOPLEFT", 12, -10)
        end
        self.overflowLabel:SetText(string.format("... and %d more note%s not shown.",
            hiddenCount, hiddenCount == 1 and "" or "s"))
        self.overflowLabel:Show()
    end

    local listHeight = LIST_PAD_Y + visibleCount * (ROW_HEIGHT + ROW_GAP) + 8
    if hiddenCount > 0 then listHeight = listHeight + 16 end
    self.list:SetHeight(math.max(listHeight, ROW_HEIGHT * 2))
end

function EvidenceDrawer:Toggle()
    -- Guard against clicks before the first real Refresh has populated state.
    if not self.toggleButton or not self.title or not self.title:IsShown() then return end
    self.expanded = not self.expanded
    self:Refresh(true, { suggestions = self._suggestions, allSuggestions = self._suggestions })
    if self._onLayoutChange then self._onLayoutChange() end
end

function EvidenceDrawer:_Height()
    local base = TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + HEADER_HEIGHT
    if not self.expanded then return base end
    base = base + 8 + CHIP_HEIGHT + 8 + (self.list:GetHeight() or ROW_HEIGHT * 2)
    return base
end

function EvidenceDrawer:OnLayoutChange(callback)
    self._onLayoutChange = callback
end

ns.InsightsEvidenceDrawer = EvidenceDrawer
return EvidenceDrawer
