local _, ns = ...

local Widgets = {}

local DEFAULT_THEME = {
    background = { 0.04, 0.05, 0.07, 0.96 },
    panel = { 0.08, 0.10, 0.14, 0.96 },
    panelAlt = { 0.11, 0.13, 0.18, 0.96 },
    border = { 0.20, 0.24, 0.32, 1.0 },
    borderStrong = { 0.32, 0.52, 0.64, 1.0 },
    accent = { 0.35, 0.78, 0.90, 1.0 },
    accentSoft = { 0.18, 0.42, 0.52, 1.0 },
    text = { 0.90, 0.94, 0.98, 1.0 },
    textMuted = { 0.60, 0.69, 0.78, 1.0 },
    success = { 0.44, 0.82, 0.60, 1.0 },
    warning = { 0.96, 0.74, 0.38, 1.0 },
    panelHover = { 0.15, 0.18, 0.24, 0.98 },
    panelDisabled = { 0.06, 0.07, 0.09, 0.95 },
    barShell = { 0.06, 0.08, 0.12, 1.0 },
    header = { 0.06, 0.08, 0.11, 0.98 },
    contentShell = { 0.07, 0.09, 0.13, 0.97 },
    severityHigh = { 0.42, 0.19, 0.16, 1.0 },
    severityMedium = { 0.34, 0.25, 0.12, 1.0 },
    severityLow = { 0.12, 0.24, 0.30, 1.0 },
}

local function deepCopy(source)
    if type(source) ~= "table" then
        return source
    end

    local copy = {}
    for key, value in pairs(source) do
        if type(value) == "table" then
            copy[key] = deepCopy(value)
        else
            copy[key] = value
        end
    end
    return copy
end

local presetName = ns.Addon and ns.Addon.GetSetting and ns.Addon:GetSetting("themePreset") or nil
local preset = ns.StaticPvpData
    and ns.StaticPvpData.THEME_PRESETS
    and ns.StaticPvpData.THEME_PRESETS[presetName or "modern_steel_ember"]

Widgets.THEME = preset and deepCopy(preset) or deepCopy(DEFAULT_THEME)

-- ---------------------------------------------------------------------------
-- T052: Shared layout tokens — reference these instead of hard-coding pixels
-- ---------------------------------------------------------------------------
Widgets.LAYOUT = {
    ROW_HEIGHT          = 20,
    ICON_SIZE           = 18,
    ICON_RESERVED_WIDTH = 22,
    SECTION_TOP_PAD     = 8,
    ROW_GAP             = 4,
    CARD_PAD            = 10,
    LABEL_FONT          = "GameFontNormalSmall",
    VALUE_FONT          = "GameFontHighlightSmall",
    CAPTION_FONT        = "GameFontDisableSmall",
    BADGE_HEIGHT        = 14,
}

function Widgets.ApplyBackdrop(frame, backgroundColor, borderColor, insets)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = true,
        tileSize = 8,
        edgeSize = 1,
        insets = insets or { left = 1, right = 1, top = 1, bottom = 1 },
    })
    local bg = backgroundColor or Widgets.THEME.panel
    local border = borderColor or Widgets.THEME.border
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
end

-- Safe color-only backdrop update — does NOT call SetBackdrop, so it is safe
-- to call from script hooks (OnEnter, OnLeave, SetActive, etc.) during tainted
-- gameplay execution.  Never triggers SetupTextureCoordinates / secret-number crash.
function Widgets.SetBackdropColors(frame, backgroundColor, borderColor)
    local bg = backgroundColor or Widgets.THEME.panel
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local bc = borderColor or Widgets.THEME.border
    frame:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4] or 1)
end

function Widgets.CreateSurface(parent, width, height, backgroundColor, borderColor)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, height)
    Widgets.ApplyBackdrop(frame, backgroundColor, borderColor)
    return frame
end

function Widgets.CreateSectionTitle(parent, text, anchor, relativeTo, relativePoint, xOffset, yOffset)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint(anchor or "TOPLEFT", relativeTo or parent, relativePoint or "TOPLEFT", xOffset or 0, yOffset or 0)
    label:SetText(text or "")
    label:SetTextColor(unpack(Widgets.THEME.text))
    return label
end

function Widgets.CreateCaption(parent, text, anchor, relativeTo, relativePoint, xOffset, yOffset)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint(anchor or "TOPLEFT", relativeTo or parent, relativePoint or "TOPLEFT", xOffset or 0, yOffset or 0)
    label:SetText(text or "")
    label:SetTextColor(unpack(Widgets.THEME.textMuted))
    return label
end

function Widgets.CreateBodyText(parent, width, height)
    local shell = Widgets.CreateSurface(parent, width, height, Widgets.THEME.panel, Widgets.THEME.border)

    local scrollFrame = CreateFrame("ScrollFrame", nil, shell)
    scrollFrame:SetPoint("TOPLEFT", shell, "TOPLEFT", 10, -10)
    scrollFrame:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -28, 10)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetClipsChildren(true)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(width - 52, 1)
    scrollFrame:SetScrollChild(content)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    text:SetWidth(width - 62)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(4)
    text:SetTextColor(unpack(Widgets.THEME.text))

    local scrollBar = CreateFrame("Slider", nil, shell, "BackdropTemplate")
    scrollBar:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -8, -10)
    scrollBar:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -8, 10)
    scrollBar:SetWidth(12)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    if scrollBar.SetObeyStepOnDrag then
        scrollBar:SetObeyStepOnDrag(true)
    end
    Widgets.ApplyBackdrop(scrollBar, Widgets.THEME.panelAlt, Widgets.THEME.border)

    local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
    thumb:SetVertexColor(unpack(Widgets.THEME.accent))
    thumb:SetSize(8, 48)
    scrollBar:SetThumbTexture(thumb)

    local function updateScrollRange()
        local contentWidth = math.max(1, (scrollFrame:GetWidth() or (width - 52)) - 10)
        content:SetWidth(contentWidth)
        text:SetWidth(math.max(1, contentWidth - 10))
        local contentHeight = math.max(content:GetHeight() or 0, (text:GetStringHeight() or 0) + 8)
        local viewHeight = scrollFrame:GetHeight() or 0
        local maxScroll = math.max(0, contentHeight - viewHeight)

        scrollBar:SetMinMaxValues(0, maxScroll)
        if maxScroll <= 0 then
            scrollBar:SetValue(0)
            scrollFrame:SetVerticalScroll(0)
            scrollBar:Hide()
            return
        end

        scrollBar:Show()
        if scrollBar:GetValue() > maxScroll then
            scrollBar:SetValue(maxScroll)
        end
    end

    scrollBar:SetScript("OnValueChanged", function(_, value)
        scrollFrame:SetVerticalScroll(value or 0)
    end)

    scrollFrame:SetScript("OnMouseWheel", function(_, delta)
        local minValue, maxValue = scrollBar:GetMinMaxValues()
        if maxValue <= minValue then
            return
        end

        local step = math.max(24, math.floor((scrollFrame:GetHeight() or 0) * 0.15))
        local nextValue = (scrollBar:GetValue() or 0) - (delta * step)
        if nextValue < minValue then
            nextValue = minValue
        elseif nextValue > maxValue then
            nextValue = maxValue
        end
        scrollBar:SetValue(nextValue)
    end)

    content:SetScript("OnSizeChanged", updateScrollRange)
    scrollFrame:SetScript("OnSizeChanged", updateScrollRange)
    scrollFrame.UpdateScrollRange = updateScrollRange
    scrollFrame.scrollBar = scrollBar
    scrollBar:Hide()
    updateScrollRange()

    if shell.EnableMouseWheel then
        shell:EnableMouseWheel(true)
        shell:SetScript("OnMouseWheel", function(_, delta)
            scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta)
        end)
    end

    return shell, content, text
end

function Widgets.CreateScrollCanvas(parent, width, height)
    local shell = Widgets.CreateSurface(parent, width, height, Widgets.THEME.panel, Widgets.THEME.border)

    local scrollFrame = CreateFrame("ScrollFrame", nil, shell)
    scrollFrame:SetPoint("TOPLEFT", shell, "TOPLEFT", 10, -10)
    scrollFrame:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -28, 10)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetClipsChildren(true)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(width - 52, 1)
    scrollFrame:SetScrollChild(content)

    local scrollBar = CreateFrame("Slider", nil, shell, "BackdropTemplate")
    scrollBar:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -8, -10)
    scrollBar:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -8, 10)
    scrollBar:SetWidth(12)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    if scrollBar.SetObeyStepOnDrag then
        scrollBar:SetObeyStepOnDrag(true)
    end
    Widgets.ApplyBackdrop(scrollBar, Widgets.THEME.panelAlt, Widgets.THEME.border)

    local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
    thumb:SetVertexColor(unpack(Widgets.THEME.accent))
    thumb:SetSize(8, 48)
    scrollBar:SetThumbTexture(thumb)

    local function updateScrollRange()
        local viewHeight = scrollFrame:GetHeight() or 0
        -- Skip update when frame geometry is not yet resolved (avoids spurious
        -- scrollbar flash on first layout pass).
        if viewHeight <= 0 then return end
        local contentWidth = math.max(1, (scrollFrame:GetWidth() or (width - 52)) - 10)
        content:SetWidth(contentWidth)
        local contentHeight = math.max(content:GetHeight() or 0, 1)
        local maxScroll = math.max(0, contentHeight - viewHeight)

        scrollBar:SetMinMaxValues(0, maxScroll)
        if maxScroll <= 0 then
            scrollBar:SetValue(0)
            scrollFrame:SetVerticalScroll(0)
            scrollBar:Hide()
            return
        end

        scrollBar:Show()
        if scrollBar:GetValue() > maxScroll then
            scrollBar:SetValue(maxScroll)
        end
    end

    scrollBar:SetScript("OnValueChanged", function(_, value)
        scrollFrame:SetVerticalScroll(value or 0)
    end)

    scrollFrame:SetScript("OnMouseWheel", function(_, delta)
        local minValue, maxValue = scrollBar:GetMinMaxValues()
        if maxValue <= minValue then
            return
        end

        local step = math.max(24, math.floor((scrollFrame:GetHeight() or 0) * 0.15))
        local nextValue = (scrollBar:GetValue() or 0) - (delta * step)
        if nextValue < minValue then
            nextValue = minValue
        elseif nextValue > maxValue then
            nextValue = maxValue
        end
        scrollBar:SetValue(nextValue)
    end)

    content:SetScript("OnSizeChanged", updateScrollRange)
    scrollFrame:SetScript("OnSizeChanged", updateScrollRange)
    scrollFrame.UpdateScrollRange = updateScrollRange
    scrollFrame.scrollBar = scrollBar
    scrollBar:Hide()
    updateScrollRange()

    if shell.EnableMouseWheel then
        shell:EnableMouseWheel(true)
        shell:SetScript("OnMouseWheel", function(_, delta)
            scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta)
        end)
    end

    return shell, scrollFrame, content
end

function Widgets.AnchorBodyText(shell, width, height)
    shell:SetSize(width, height)
end

function Widgets.SetBodyText(content, textRegion, value)
    textRegion:SetText(value or "")
    local height = math.max((textRegion:GetStringHeight() or 0) + 16, 1)
    content:SetHeight(height)
    local scrollFrame = content:GetParent()
    if scrollFrame and scrollFrame.UpdateScrollRange then
        scrollFrame:UpdateScrollRange()
    end
end

function Widgets.SetCanvasHeight(content, height)
    content:SetHeight(math.max(height or 1, 1))
    local scrollFrame = content:GetParent()
    if scrollFrame and scrollFrame.UpdateScrollRange then
        scrollFrame:UpdateScrollRange()
    end
end

function Widgets.CreateButton(parent, label, width, height)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width or 120, height or 22)
    Widgets.ApplyBackdrop(button, Widgets.THEME.panelAlt, Widgets.THEME.border)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.text:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.text:SetTextColor(unpack(Widgets.THEME.text))

    function button:SetText(value)
        self.text:SetText(value or "")
    end

    function button:SetActive(isActive)
        self.isActive = isActive and true or false
        if self.isActive then
            Widgets.SetBackdropColors(self, Widgets.THEME.accentSoft, Widgets.THEME.borderStrong)
            self.text:SetTextColor(unpack(Widgets.THEME.text))
        elseif not self:IsEnabled() then
            Widgets.SetBackdropColors(self, Widgets.THEME.panelDisabled, Widgets.THEME.border)
            self.text:SetTextColor(0.42, 0.48, 0.55, 1)
        else
            Widgets.SetBackdropColors(self, Widgets.THEME.panelAlt, Widgets.THEME.border)
            self.text:SetTextColor(unpack(Widgets.THEME.text))
        end
    end

    button:HookScript("OnEnable", function(self)
        self:SetActive(self.isActive)
    end)
    button:HookScript("OnDisable", function(self)
        self:SetActive(self.isActive)
    end)
    button:HookScript("OnEnter", function(self)
        if self.isActive or not self:IsEnabled() then
            return
        end
        Widgets.SetBackdropColors(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
    end)
    button:HookScript("OnLeave", function(self)
        self:SetActive(self.isActive)
    end)

    button:SetText(label or "")
    button:SetActive(false)
    return button
end

function Widgets.CreateEditBox(parent, width, height)
    local editBox = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    editBox:SetSize(width or 120, height or 20)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("GameFontHighlight")
    editBox:SetTextColor(unpack(Widgets.THEME.text))
    editBox:SetTextInsets(8, 8, 4, 4)
    Widgets.ApplyBackdrop(editBox, Widgets.THEME.panelAlt, Widgets.THEME.border)
    editBox:HookScript("OnEditFocusGained", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panelAlt, Widgets.THEME.borderStrong)
    end)
    editBox:HookScript("OnEditFocusLost", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panelAlt, Widgets.THEME.border)
    end)
    return editBox
end

function Widgets.CreateLabeledEditBox(parent, labelText, width, height)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width or 120, (height or 20) + 18)

    holder.label = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    holder.label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    holder.label:SetText(labelText or "")
    holder.label:SetTextColor(unpack(Widgets.THEME.textMuted))

    holder.editBox = Widgets.CreateEditBox(holder, width, height)
    holder.editBox:SetPoint("TOPLEFT", holder.label, "BOTTOMLEFT", 0, -4)

    return holder, holder.editBox
end

function Widgets.CreateRowButton(parent, width, height)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width, height or 22)
    Widgets.ApplyBackdrop(button, Widgets.THEME.panel, Widgets.THEME.border)

    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.text:SetPoint("LEFT", button, "LEFT", 8, 0)
    button.text:SetPoint("RIGHT", button, "RIGHT", -8, 0)
    button.text:SetJustifyH("LEFT")
    button.text:SetTextColor(unpack(Widgets.THEME.text))

    button:SetScript("OnEnter", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
    end)
    button:SetScript("OnLeave", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panel, Widgets.THEME.border)
    end)

    return button
end

function Widgets.CreateMetricCard(parent, width, height)
    local card = Widgets.CreateSurface(parent, width, height, Widgets.THEME.panelAlt, Widgets.THEME.border)

    card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    card.value:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
    card.value:SetJustifyH("LEFT")

    card.label = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.label:SetPoint("TOPLEFT", card.value, "BOTTOMLEFT", 0, -6)
    card.label:SetTextColor(unpack(Widgets.THEME.text))
    card.label:SetJustifyH("LEFT")

    card.detail = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.detail:SetPoint("TOPLEFT", card.label, "BOTTOMLEFT", 0, -4)
    card.detail:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.detail:SetJustifyH("LEFT")
    card.detail:SetJustifyV("TOP")
    card.detail:SetTextColor(unpack(Widgets.THEME.textMuted))

    function card:SetData(valueText, labelText, detailText, accentColor)
        local color = accentColor or Widgets.THEME.accent
        self.value:SetText(valueText or "--")
        self.value:SetTextColor(unpack(color))
        self.label:SetText(labelText or "")
        self.detail:SetText(detailText or "")
    end

    return card
end

function Widgets.CreateMetricBar(parent, width, height)
    local row = Widgets.CreateSurface(parent, width, height or 58, Widgets.THEME.panelAlt, Widgets.THEME.border)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -10)
    row.title:SetTextColor(unpack(Widgets.THEME.text))
    row.title:SetJustifyH("LEFT")

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.value:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -10)
    row.value:SetTextColor(unpack(Widgets.THEME.text))
    row.value:SetJustifyH("RIGHT")

    row.barShell = CreateFrame("Frame", nil, row, "BackdropTemplate")
    row.barShell:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -8)
    row.barShell:SetPoint("TOPRIGHT", row.value, "BOTTOMRIGHT", 0, -8)
    row.barShell:SetHeight(10)
    Widgets.ApplyBackdrop(row.barShell, Widgets.THEME.barShell, Widgets.THEME.border, { left = 0, right = 0, top = 0, bottom = 0 })

    row.fill = row.barShell:CreateTexture(nil, "ARTWORK")
    row.fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.fill:SetPoint("TOPLEFT", row.barShell, "TOPLEFT", 0, 0)
    row.fill:SetPoint("BOTTOMLEFT", row.barShell, "BOTTOMLEFT", 0, 0)
    row.fill:SetWidth(1)
    row.fill:SetVertexColor(unpack(Widgets.THEME.accent))

    row.marker = row.barShell:CreateTexture(nil, "OVERLAY")
    row.marker:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.marker:SetWidth(2)
    row.marker:SetPoint("TOP", row.barShell, "TOPLEFT", 0, 0)
    row.marker:SetPoint("BOTTOM", row.barShell, "BOTTOMLEFT", 0, 0)
    row.marker:SetVertexColor(unpack(Widgets.THEME.warning))
    row.marker:Hide()

    row.caption = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.caption:SetPoint("TOPLEFT", row.barShell, "BOTTOMLEFT", 0, -6)
    row.caption:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.caption:SetJustifyH("LEFT")
    row.caption:SetJustifyV("TOP")
    row.caption:SetTextColor(unpack(Widgets.THEME.textMuted))

    function row:SetData(titleText, valueText, captionText, percent, fillColor, markerPercent)
        local clampedPercent = ns.Helpers.Clamp(percent or 0, 0, 1)
        local barWidth = math.max(1, self.barShell:GetWidth() or 1)
        local color = fillColor or Widgets.THEME.accent

        self.title:SetText(titleText or "")
        self.value:SetText(valueText or "")
        self.caption:SetText(captionText or "")
        self.fill:SetVertexColor(unpack(color))
        self.fill:SetWidth(barWidth * clampedPercent)

        if markerPercent and markerPercent > 0 and markerPercent < 1.5 then
            local clampedMarker = ns.Helpers.Clamp(markerPercent, 0, 1)
            self.marker:ClearAllPoints()
            self.marker:SetPoint("TOP", self.barShell, "TOPLEFT", barWidth * clampedMarker, 0)
            self.marker:SetPoint("BOTTOM", self.barShell, "BOTTOMLEFT", barWidth * clampedMarker, 0)
            self.marker:Show()
        else
            self.marker:Hide()
        end
    end

    return row
end

function Widgets.CreateSpellRow(parent, width, height)
    local row = Widgets.CreateSurface(parent, width, height or 56, Widgets.THEME.panelAlt, Widgets.THEME.border)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.icon:SetSize(32, 32)
    row.icon:SetTexture(134400)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -8)
    row.name:SetTextColor(unpack(Widgets.THEME.text))
    row.name:SetJustifyH("LEFT")

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -6)
    row.detail:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.detail:SetTextColor(unpack(Widgets.THEME.textMuted))
    row.detail:SetJustifyH("LEFT")
    row.detail:SetJustifyV("TOP")

    row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.amount:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -8)
    row.amount:SetTextColor(unpack(Widgets.THEME.text))
    row.amount:SetJustifyH("RIGHT")

    row.barShell = CreateFrame("Frame", nil, row, "BackdropTemplate")
    row.barShell:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 10, 8)
    row.barShell:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -12, 8)
    row.barShell:SetHeight(6)
    Widgets.ApplyBackdrop(row.barShell, Widgets.THEME.barShell, Widgets.THEME.border, { left = 0, right = 0, top = 0, bottom = 0 })

    row.fill = row.barShell:CreateTexture(nil, "ARTWORK")
    row.fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.fill:SetPoint("TOPLEFT", row.barShell, "TOPLEFT", 0, 0)
    row.fill:SetPoint("BOTTOMLEFT", row.barShell, "BOTTOMLEFT", 0, 0)
    row.fill:SetWidth(1)
    row.fill:SetVertexColor(unpack(Widgets.THEME.accent))

    function row:SetData(iconID, nameText, detailText, amountText, share, fillColor)
        local clampedShare = ns.Helpers.Clamp(share or 0, 0, 1)
        self.icon:SetTexture(iconID or 134400)
        self.name:SetText(nameText or "Unknown Spell")
        self.detail:SetText(detailText or "")
        self.amount:SetText(amountText or "")
        self.fill:SetVertexColor(unpack(fillColor or Widgets.THEME.accent))
        self.fill:SetWidth(math.max(1, (self.barShell:GetWidth() or 1) * clampedShare))
        self:Show()
    end

    return row
end

function Widgets.CreateInsightCard(parent, width, height)
    local card = Widgets.CreateSurface(parent, width, height or 92, Widgets.THEME.panelAlt, Widgets.THEME.border)

    card.badge = Widgets.CreateSurface(card, 56, 18, Widgets.THEME.accentSoft, Widgets.THEME.borderStrong)
    card.badge:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
    card.badge.text = card.badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.badge.text:SetPoint("CENTER")
    card.badge.text:SetTextColor(unpack(Widgets.THEME.text))

    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.title:SetPoint("LEFT", card.badge, "RIGHT", 10, 0)
    card.title:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.title:SetJustifyH("LEFT")
    card.title:SetTextColor(unpack(Widgets.THEME.text))

    card.body = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.body:SetPoint("TOPLEFT", card.badge, "BOTTOMLEFT", 0, -10)
    card.body:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.body:SetJustifyH("LEFT")
    card.body:SetJustifyV("TOP")
    card.body:SetTextColor(unpack(Widgets.THEME.text))

    card.evidence = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.evidence:SetPoint("TOPLEFT", card.body, "BOTTOMLEFT", 0, -6)
    card.evidence:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.evidence:SetJustifyH("LEFT")
    card.evidence:SetJustifyV("TOP")
    card.evidence:SetTextColor(unpack(Widgets.THEME.textMuted))

    function card:SetData(severity, titleText, bodyText, evidenceText)
        local palette = Widgets.THEME.accentSoft
        local border = Widgets.THEME.borderStrong
        if severity == "high" then
            palette = Widgets.THEME.severityHigh
            border = Widgets.THEME.warning
        elseif severity == "medium" then
            palette = Widgets.THEME.severityMedium
            border = Widgets.THEME.warning
        elseif severity == "low" then
            palette = Widgets.THEME.severityLow
            border = Widgets.THEME.borderStrong
        end

        Widgets.SetBackdropColors(self.badge, palette, border)
        self.badge.text:SetText(string.upper(severity or "info"))
        self.title:SetText(titleText or "")
        self.body:SetText(bodyText or "")
        self.evidence:SetText(evidenceText or "")
        self:Show()
    end

    return card
end

function Widgets.CreatePill(parent, width, height, backgroundColor, borderColor)
    local pill = Widgets.CreateSurface(parent, width or 84, height or 18, backgroundColor or Widgets.THEME.accentSoft, borderColor or Widgets.THEME.borderStrong)

    pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pill.text:SetPoint("CENTER", pill, "CENTER", 0, 0)
    pill.text:SetTextColor(unpack(Widgets.THEME.text))

    function pill:SetData(labelText, textColor, nextBackgroundColor, nextBorderColor)
        Widgets.SetBackdropColors(self, nextBackgroundColor or backgroundColor or Widgets.THEME.accentSoft, nextBorderColor or borderColor or Widgets.THEME.borderStrong)
        self.text:SetText(labelText or "")
        self.text:SetTextColor(unpack(textColor or Widgets.THEME.text))
        self:Show()
    end

    return pill
end

-- Confidence badge: 10x10 colored circle indicator based on dataConfidence level.
-- Supports both legacy ANALYSIS_CONFIDENCE and new SESSION_CONFIDENCE labels (T120).
local CONFIDENCE_BADGE_COLORS = {
    -- Legacy ANALYSIS_CONFIDENCE labels (pre-v6)
    full_raw       = { 0.44, 0.82, 0.60, 1.0 },  -- green
    enriched       = { 0.44, 0.82, 0.60, 1.0 },  -- green
    restricted_raw = { 0.96, 0.86, 0.38, 1.0 },  -- yellow
    partial_roster = { 0.96, 0.62, 0.30, 1.0 },  -- orange
    degraded       = { 0.90, 0.30, 0.25, 1.0 },  -- red
    unknown        = { 0.50, 0.54, 0.58, 1.0 },  -- grey
    -- New SESSION_CONFIDENCE labels (v6+)
    state_plus_damage_meter = { 0.44, 0.82, 0.60, 1.0 },  -- green
    damage_meter_only       = { 0.35, 0.78, 0.90, 1.0 },  -- blue-green
    visible_cc_only         = { 0.96, 0.86, 0.38, 1.0 },  -- yellow
    estimated               = { 0.96, 0.62, 0.30, 1.0 },  -- orange
    legacy_cleu_import      = { 0.60, 0.69, 0.78, 1.0 },  -- muted blue
}
local CONFIDENCE_BADGE_TOOLTIPS = {
    -- Legacy ANALYSIS_CONFIDENCE labels (pre-v6)
    full_raw       = "Full Raw — unrestricted CLEU data with high fidelity.",
    enriched       = "Enriched — CLEU + DamageMeter data merged.",
    restricted_raw = "Restricted Raw — DamageMeter primary, limited event detail.",
    partial_roster = "Partial Roster — incomplete arena slot coverage.",
    degraded       = "Degraded — significant data gaps detected.",
    unknown        = "Unknown — confidence level could not be determined.",
    -- New SESSION_CONFIDENCE labels (v6+)
    state_plus_damage_meter = "State + Damage Meter — full state events and DM import.",
    damage_meter_only       = "Damage Meter Only — DM data captured, limited state events.",
    visible_cc_only         = "Visible CC Only — only crowd control and loss-of-control data.",
    estimated               = "Estimated — insufficient direct observation.",
    legacy_cleu_import      = "Legacy Import — migrated from pre-Midnight CLEU session.",
}

function Widgets.CreateConfidenceBadge(parent, size)
    size = size or 10
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(size, size)

    badge.dot = badge:CreateTexture(nil, "ARTWORK")
    badge.dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    badge.dot:SetAllPoints()
    badge.dot:SetVertexColor(unpack(CONFIDENCE_BADGE_COLORS.unknown))

    badge._confidence = "unknown"

    function badge:SetConfidence(confidence)
        confidence = confidence or "unknown"
        self._confidence = confidence
        local color = CONFIDENCE_BADGE_COLORS[confidence] or CONFIDENCE_BADGE_COLORS.unknown
        self.dot:SetVertexColor(unpack(color))
    end

    badge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Data Confidence", 1, 1, 1)
        local tip = CONFIDENCE_BADGE_TOOLTIPS[self._confidence] or CONFIDENCE_BADGE_TOOLTIPS.unknown
        GameTooltip:AddLine(tip, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return badge
end

function Widgets.CreateHistoryRow(parent, width, height)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width or 808, height or 64)
    Widgets.ApplyBackdrop(button, Widgets.THEME.panel, Widgets.THEME.border)

    button.accent = button:CreateTexture(nil, "ARTWORK")
    button.accent:SetTexture("Interface\\Buttons\\WHITE8x8")
    button.accent:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.accent:SetWidth(3)
    button.accent:SetVertexColor(unpack(Widgets.THEME.accent))

    button.confidenceBadge = Widgets.CreateConfidenceBadge(button, 10)
    button.confidenceBadge:SetPoint("TOPLEFT", button, "TOPLEFT", 14, -13)

    button.title = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.title:SetPoint("LEFT", button.confidenceBadge, "RIGHT", 6, 0)
    button.title:SetTextColor(unpack(Widgets.THEME.text))
    button.title:SetJustifyH("LEFT")

    button.timestamp = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.timestamp:SetPoint("TOPRIGHT", button, "TOPRIGHT", -14, -10)
    button.timestamp:SetTextColor(unpack(Widgets.THEME.textMuted))
    button.timestamp:SetJustifyH("RIGHT")

    button.meta = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.meta:SetPoint("TOPLEFT", button.title, "BOTTOMLEFT", 0, -5)
    button.meta:SetPoint("RIGHT", button, "RIGHT", -180, 0)
    button.meta:SetTextColor(unpack(Widgets.THEME.textMuted))
    button.meta:SetJustifyH("LEFT")

    button.stats = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.stats:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 14, 11)
    button.stats:SetPoint("RIGHT", button, "RIGHT", -160, 0)
    button.stats:SetTextColor(unpack(Widgets.THEME.text))
    button.stats:SetJustifyH("LEFT")

    button.resultPill = Widgets.CreatePill(button, 78, 18, Widgets.THEME.panelAlt, Widgets.THEME.border)
    button.resultPill:SetPoint("TOPRIGHT", button, "TOPRIGHT", -14, -34)

    button.confidencePill = Widgets.CreatePill(button, 78, 18, Widgets.THEME.accentSoft, Widgets.THEME.borderStrong)
    button.confidencePill:SetPoint("RIGHT", button.resultPill, "LEFT", -6, 0)

    button.source = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.source:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -14, 11)
    button.source:SetTextColor(unpack(Widgets.THEME.textMuted))
    button.source:SetJustifyH("RIGHT")

    local function getResultColors(result)
        if result == "won" then
            return Widgets.THEME.success, Widgets.THEME.success
        end
        if result == "lost" then
            return Widgets.THEME.severityHigh, Widgets.THEME.warning
        end
        return Widgets.THEME.panelAlt, Widgets.THEME.border
    end

    local function getConfidenceColors(confidence)
        if confidence == "high" then
            return Widgets.THEME.severityLow, Widgets.THEME.borderStrong
        end
        if confidence == "medium" then
            return Widgets.THEME.severityMedium, Widgets.THEME.warning
        end
        return Widgets.THEME.accentSoft, Widgets.THEME.borderStrong
    end

    button:SetScript("OnEnter", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
    end)
    button:SetScript("OnLeave", function(self)
        Widgets.SetBackdropColors(self, Widgets.THEME.panel, Widgets.THEME.border)
    end)

    function button:SetData(data)
        data = data or {}
        local resultBackground, resultBorder = getResultColors(data.result)
        local confidenceBackground, confidenceBorder = getConfidenceColors(data.analysisConfidence)
        local accentColor = Widgets.THEME.accent
        if data.result == "won" then
            accentColor = Widgets.THEME.success
        elseif data.result == "lost" then
            accentColor = Widgets.THEME.warning
        elseif data.analysisConfidence == "limited" then
            accentColor = Widgets.THEME.textMuted
        end

        self.accent:SetVertexColor(unpack(accentColor))
        self.title:SetText(data.title or "Unknown Fight")
        self.timestamp:SetText(data.timestamp or "")
        self.meta:SetText(data.meta or "")
        self.stats:SetText(data.stats or "")
        self.source:SetText(data.source or "")
        self.resultPill:SetData(string.upper(data.resultLabel or "log"), Widgets.THEME.text, resultBackground, resultBorder)
        self.confidencePill:SetData(string.upper(data.confidenceLabel or "limited"), Widgets.THEME.text, confidenceBackground, confidenceBorder)

        -- Confidence badge (colored dot) gated by showConfidenceBadges setting.
        local showBadge = ns.Addon and ns.Addon.GetSetting and ns.Addon:GetSetting("showConfidenceBadges")
        if showBadge ~= false and self.confidenceBadge then
            self.confidenceBadge:SetConfidence(data.dataConfidence or "unknown")
            self.confidenceBadge:Show()
        elseif self.confidenceBadge then
            self.confidenceBadge:Hide()
        end

        self:Show()
    end

    return button
end

-- Slot row for opponent composition panel.
-- Shows: class-color dot, spec name, archetype label, threat tags.
function Widgets.CreateSlotRow(parent, width, height)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(width or 750, height or 24)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.dot:SetVertexColor(unpack(Widgets.THEME.textMuted))

    row.specLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.specLabel:SetPoint("LEFT", row.dot, "RIGHT", 8, 0)
    row.specLabel:SetTextColor(unpack(Widgets.THEME.text))
    row.specLabel:SetJustifyH("LEFT")

    row.archetype = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.archetype:SetPoint("LEFT", row.specLabel, "RIGHT", 12, 0)
    row.archetype:SetTextColor(unpack(Widgets.THEME.textMuted))
    row.archetype:SetJustifyH("LEFT")

    row.threat = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.threat:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.threat:SetTextColor(unpack(Widgets.THEME.warning))
    row.threat:SetJustifyH("RIGHT")

    function row:SetSlotData(data)
        data = data or {}
        -- Class-color dot via RAID_CLASS_COLORS global.
        local classFile = data.classFile
        if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
            local cc = RAID_CLASS_COLORS[classFile]
            self.dot:SetVertexColor(cc.r, cc.g, cc.b, 1)
        else
            self.dot:SetVertexColor(unpack(Widgets.THEME.textMuted))
        end
        self.specLabel:SetText(data.specName or data.name or "Unknown")
        self.archetype:SetText(data.archetypeLabel or "")
        self.threat:SetText(data.threatTag or "")
        self:Show()
    end

    return row
end

-- ---------------------------------------------------------------------------
-- T061: Sparkline — compact line trend with dots at each data point
-- ---------------------------------------------------------------------------
function Widgets.CreateSparkline(parent, data, color, width, height)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 120, height or 24)

    data = data or {}
    if #data < 2 then
        return frame
    end

    local r, g, b, a = color[1], color[2], color[3], color[4] or 1
    local count = #data

    local dataMin, dataMax = data[1], data[1]
    for i = 2, count do
        if data[i] < dataMin then dataMin = data[i] end
        if data[i] > dataMax then dataMax = data[i] end
    end
    local range = dataMax - dataMin
    if range == 0 then range = 1 end

    local dotSize = 3
    local w = width or 120
    local h = height or 24
    local xStep = (w - dotSize) / math.max(count - 1, 1)

    local dots = {}
    for i = 1, count do
        local xPos = (i - 1) * xStep
        local yPos = ((data[i] - dataMin) / range) * (h - dotSize)

        local dot = frame:CreateTexture(nil, "ARTWORK")
        dot:SetTexture("Interface\\Buttons\\WHITE8x8")
        dot:SetSize(dotSize, dotSize)
        dot:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", xPos, yPos)
        dot:SetVertexColor(r, g, b, a)
        dots[i] = { x = xPos + dotSize / 2, y = yPos + dotSize / 2 }
    end

    -- Connect adjacent dots with thin line textures
    for i = 1, count - 1 do
        local dx = dots[i + 1].x - dots[i].x
        local dy = dots[i + 1].y - dots[i].y
        local dist = math.sqrt(dx * dx + dy * dy)
        local angle = math.atan2(dy, dx)

        local line = frame:CreateTexture(nil, "BACKGROUND")
        line:SetTexture("Interface\\Buttons\\WHITE8x8")
        line:SetSize(dist, 1)
        line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", dots[i].x, dots[i].y)
        line:SetVertexColor(r, g, b, a * 0.7)
        line:SetRotation(-angle)
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- T062: SegmentedBar — multi-segment colored horizontal bar
-- ---------------------------------------------------------------------------
function Widgets.CreateSegmentedBar(parent, segments, width, height)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local w = width or 200
    local h = height or 16
    frame:SetSize(w, h)
    Widgets.ApplyBackdrop(frame, Widgets.THEME.barShell, Widgets.THEME.border)

    segments = segments or {}
    if #segments == 0 then
        return frame
    end

    local total = 0
    for i = 1, #segments do
        total = total + (segments[i].value or 0)
    end
    if total == 0 then total = 1 end

    local xOffset = 1
    local barWidth = w - 2
    for i = 1, #segments do
        local seg = segments[i]
        local segWidth = math.max(1, (seg.value / total) * barWidth)
        local tex = frame:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetSize(segWidth, h - 2)
        tex:SetPoint("TOPLEFT", frame, "TOPLEFT", xOffset, -1)
        local c = seg.color or Widgets.THEME.accent
        tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)

        -- Optional centered label if the segment is wide enough
        if seg.label and segWidth > 40 then
            local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("CENTER", tex, "CENTER", 0, 0)
            lbl:SetText(seg.label)
            lbl:SetTextColor(unpack(Widgets.THEME.text))
        end

        xOffset = xOffset + segWidth
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- T063: MirroredDeltaBar — two-sided bar growing from center
-- ---------------------------------------------------------------------------
function Widgets.CreateMirroredDeltaBar(parent, leftValue, rightValue, leftColor, rightColor, label, width, height)
    local w = width or 200
    local h = height or 16
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(w, h)

    local halfWidth = w / 2
    local maxVal = math.max(leftValue or 0, rightValue or 0)
    if maxVal == 0 then maxVal = 1 end

    -- Left bar (grows leftward from center)
    local leftBarWidth = math.max(1, ((leftValue or 0) / maxVal) * halfWidth)
    local leftTex = frame:CreateTexture(nil, "ARTWORK")
    leftTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    leftTex:SetSize(leftBarWidth, h)
    leftTex:SetPoint("RIGHT", frame, "CENTER", 0, 0)
    local lc = leftColor or Widgets.THEME.accent
    leftTex:SetVertexColor(lc[1], lc[2], lc[3], lc[4] or 1)

    -- Right bar (grows rightward from center)
    local rightBarWidth = math.max(1, ((rightValue or 0) / maxVal) * halfWidth)
    local rightTex = frame:CreateTexture(nil, "ARTWORK")
    rightTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    rightTex:SetSize(rightBarWidth, h)
    rightTex:SetPoint("LEFT", frame, "CENTER", 0, 0)
    local rc = rightColor or Widgets.THEME.warning
    rightTex:SetVertexColor(rc[1], rc[2], rc[3], rc[4] or 1)

    -- Center label
    local labelFs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelFs:SetPoint("CENTER", frame, "CENTER", 0, 0)
    labelFs:SetText(label or "")
    labelFs:SetTextColor(unpack(Widgets.THEME.text))

    frame.leftTex = leftTex
    frame.rightTex = rightTex
    frame.label = labelFs

    return frame
end

-- ---------------------------------------------------------------------------
-- T064: HeatGrid — N x M grid of colored cells
-- ---------------------------------------------------------------------------
function Widgets.CreateHeatGrid(parent, rows, cols, data, colorRampFn, labels, cellSize)
    cellSize = cellSize or 16
    labels = labels or {}

    local labelOffset = labels.rowLabels and 60 or 0
    local colLabelOffset = labels.colLabels and 14 or 0

    local totalWidth = labelOffset + cols * cellSize
    local totalHeight = colLabelOffset + rows * cellSize

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(totalWidth, totalHeight)

    -- Column labels
    if labels.colLabels then
        for c = 1, cols do
            local colLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            colLabel:SetPoint("BOTTOM", frame, "TOPLEFT",
                labelOffset + (c - 1) * cellSize + cellSize / 2, -colLabelOffset)
            colLabel:SetText(labels.colLabels[c] or "")
            colLabel:SetTextColor(unpack(Widgets.THEME.textMuted))
        end
    end

    -- Row labels and cells
    for r = 1, rows do
        if labels.rowLabels then
            local rowLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rowLabel:SetPoint("RIGHT", frame, "TOPLEFT",
                labelOffset - 4, -colLabelOffset - (r - 1) * cellSize - cellSize / 2)
            rowLabel:SetText(labels.rowLabels[r] or "")
            rowLabel:SetTextColor(unpack(Widgets.THEME.textMuted))
            rowLabel:SetJustifyH("RIGHT")
        end

        for c = 1, cols do
            local val = data[r] and data[r][c] or 0
            local cr, cg, cb = 0.2, 0.2, 0.2
            if colorRampFn then
                cr, cg, cb = colorRampFn(val)
            end

            local cell = frame:CreateTexture(nil, "ARTWORK")
            cell:SetTexture("Interface\\Buttons\\WHITE8x8")
            cell:SetSize(cellSize - 1, cellSize - 1)
            cell:SetPoint("TOPLEFT", frame, "TOPLEFT",
                labelOffset + (c - 1) * cellSize,
                -colLabelOffset - (r - 1) * cellSize)
            cell:SetVertexColor(cr, cg, cb, 1)
        end
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- T065: TimelineLane — single horizontal lane with positioned event markers/bars
-- ---------------------------------------------------------------------------
function Widgets.CreateTimelineLane(parent, events, totalDuration, width, height)
    local w = width or 750
    local h = height or 20
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(w, h)

    -- Background track
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetAllPoints()
    bg:SetVertexColor(unpack(Widgets.THEME.barShell))

    events = events or {}
    totalDuration = totalDuration or 1
    if totalDuration <= 0 then totalDuration = 1 end

    for i = 1, #events do
        local ev = events[i]
        local xPos = ((ev.t or 0) / totalDuration) * w
        local c = ev.color or Widgets.THEME.accent

        if ev.duration and ev.duration > 0 then
            -- Draw as a bar spanning the duration
            local barWidth = math.max(1, (ev.duration / totalDuration) * w)
            local bar = frame:CreateTexture(nil, "ARTWORK")
            bar:SetTexture("Interface\\Buttons\\WHITE8x8")
            bar:SetSize(barWidth, h)
            bar:SetPoint("LEFT", frame, "LEFT", xPos, 0)
            bar:SetVertexColor(c[1], c[2], c[3], (c[4] or 1) * 0.8)
        else
            -- Draw as a 3px vertical marker
            local marker = frame:CreateTexture(nil, "ARTWORK")
            marker:SetTexture("Interface\\Buttons\\WHITE8x8")
            marker:SetSize(3, h)
            marker:SetPoint("LEFT", frame, "LEFT", xPos, 0)
            marker:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
        end

        -- Tooltip hit area
        if ev.tooltip then
            local hitFrame = CreateFrame("Frame", nil, frame)
            local hitWidth = (ev.duration and ev.duration > 0)
                and math.max(6, (ev.duration / totalDuration) * w) or 6
            hitFrame:SetSize(hitWidth, h)
            hitFrame:SetPoint("LEFT", frame, "LEFT", xPos, 0)
            hitFrame:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(ev.tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            hitFrame:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- T066: Gauge — linear horizontal gauge with optional threshold markers
-- ---------------------------------------------------------------------------
function Widgets.CreateGauge(parent, value, min, max, thresholds, color, width, height)
    local w = width or 200
    local h = height or 16
    local minVal = min or 0
    local maxVal = max or 1

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(w, h)

    -- Background track
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetAllPoints()
    bg:SetVertexColor(unpack(Widgets.THEME.barShell))

    -- Fill bar
    local range = maxVal - minVal
    if range <= 0 then range = 1 end
    local clamped = math.max(minVal, math.min(value or 0, maxVal))
    local fillWidth = math.max(1, ((clamped - minVal) / range) * w)

    local fill = frame:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetSize(fillWidth, h)
    fill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    local c = color or Widgets.THEME.accent
    fill:SetVertexColor(c[1], c[2], c[3], c[4] or 1)

    -- Threshold markers
    if thresholds then
        for i = 1, #thresholds do
            local th = thresholds[i]
            local thPos = ((th.value - minVal) / range) * w
            local thMarker = frame:CreateTexture(nil, "OVERLAY")
            thMarker:SetTexture("Interface\\Buttons\\WHITE8x8")
            thMarker:SetSize(2, h)
            thMarker:SetPoint("LEFT", frame, "LEFT", thPos, 0)
            local tc = th.color or Widgets.THEME.warning
            thMarker:SetVertexColor(tc[1], tc[2], tc[3], tc[4] or 1)
        end
    end

    frame.fill = fill
    return frame
end

-- ---------------------------------------------------------------------------
-- T067: ConfidencePill — maps SESSION_CONFIDENCE enum to colored pill
-- ---------------------------------------------------------------------------
local CONFIDENCE_PILL_MAP = {
    state_plus_damage_meter = {
        color   = { 0.18, 0.38, 0.24, 1.0 },
        border  = { 0.44, 0.82, 0.60, 1.0 },
        label   = "Full Data",
        tooltip = "Full state + DamageMeter data available.",
    },
    damage_meter_only = {
        color   = { 0.14, 0.28, 0.44, 1.0 },
        border  = { 0.35, 0.60, 0.90, 1.0 },
        label   = "Post-Combat Data",
        tooltip = "DamageMeter data only; limited live event detail.",
    },
    visible_cc_only = {
        color   = { 0.40, 0.38, 0.14, 1.0 },
        border  = { 0.96, 0.86, 0.38, 1.0 },
        label   = "Limited Data",
        tooltip = "Only CC/visibility data; no DamageMeter integration.",
    },
    partial_roster = {
        color   = { 0.40, 0.28, 0.12, 1.0 },
        border  = { 0.96, 0.62, 0.30, 1.0 },
        label   = "Incomplete Roster",
        tooltip = "Arena session with incomplete slot coverage.",
    },
    estimated = {
        color   = { 0.22, 0.24, 0.26, 1.0 },
        border  = { 0.50, 0.54, 0.58, 1.0 },
        label   = "Estimated",
        tooltip = "Insufficient direct observation; values are estimated.",
    },
    legacy_cleu_import = {
        color   = { 0.22, 0.24, 0.26, 1.0 },
        border  = { 0.50, 0.54, 0.58, 1.0 },
        label   = "Legacy Session",
        tooltip = "Imported from a pre-v6 session schema.",
    },
}

function Widgets.CreateConfidencePill(parent, confidence)
    local mapping = CONFIDENCE_PILL_MAP[confidence] or CONFIDENCE_PILL_MAP.estimated
    local pill = Widgets.CreatePill(parent, nil, nil, mapping.color, mapping.border)
    pill:SetData(mapping.label)
    pill._confidence = confidence

    local function applyTooltip(p, m)
        if m.tooltip then
            p:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Session Confidence", 1, 1, 1)
                GameTooltip:AddLine(m.tooltip, 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end
    applyTooltip(pill, mapping)

    function pill:SetConfidence(newConfidence)
        if newConfidence == self._confidence then return end
        self._confidence = newConfidence
        local m = CONFIDENCE_PILL_MAP[newConfidence] or CONFIDENCE_PILL_MAP.estimated
        self:SetData(m.label)
        applyTooltip(self, m)
    end

    return pill
end

-- ---------------------------------------------------------------------------
-- T068: MiniLegend — compact horizontal color legend strip
-- ---------------------------------------------------------------------------
function Widgets.CreateMiniLegend(parent, entries, spacing)
    spacing = spacing or 8
    local swatchSize = 8
    local frame = CreateFrame("Frame", nil, parent)

    entries = entries or {}
    if #entries == 0 then
        frame:SetSize(1, 12)
        return frame
    end

    local xOffset = 0
    for i = 1, #entries do
        local entry = entries[i]

        -- Color swatch
        local swatch = frame:CreateTexture(nil, "ARTWORK")
        swatch:SetTexture("Interface\\Buttons\\WHITE8x8")
        swatch:SetSize(swatchSize, swatchSize)
        swatch:SetPoint("LEFT", frame, "LEFT", xOffset, 0)
        local c = entry.color or Widgets.THEME.accent
        swatch:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
        xOffset = xOffset + swatchSize + 4

        -- Label text
        local labelFs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        labelFs:SetPoint("LEFT", frame, "LEFT", xOffset, 0)
        labelFs:SetText(entry.label or "")
        labelFs:SetTextColor(unpack(Widgets.THEME.textMuted))
        xOffset = xOffset + (labelFs:GetStringWidth() or 40) + spacing
    end

    frame:SetSize(xOffset, math.max(swatchSize, 12))
    return frame
end

-- ---------------------------------------------------------------------------
-- T069: DeltaBadge — +/- delta indicator with green/red coloring
-- ---------------------------------------------------------------------------
function Widgets.CreateDeltaBadge(parent, delta, formatStr)
    local fmt = formatStr or "%.1f"
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")

    local isPositive = (delta or 0) >= 0
    local prefix = isPositive and "+" or ""
    local displayText = prefix .. string.format(fmt, delta or 0)

    local bgColor, borderColor, textColor
    if isPositive then
        bgColor = {
            Widgets.THEME.success[1] * 0.3,
            Widgets.THEME.success[2] * 0.3,
            Widgets.THEME.success[3] * 0.3,
            0.9,
        }
        borderColor = Widgets.THEME.success
        textColor = Widgets.THEME.success
    else
        bgColor = {
            Widgets.THEME.severityHigh[1] * 0.5,
            Widgets.THEME.severityHigh[2] * 0.5,
            Widgets.THEME.severityHigh[3] * 0.5,
            0.9,
        }
        borderColor = Widgets.THEME.severityHigh
        textColor = { 0.90, 0.30, 0.25, 1.0 }
    end

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", frame, "CENTER", 0, 0)
    label:SetText(displayText)
    label:SetTextColor(textColor[1], textColor[2], textColor[3], textColor[4] or 1)

    local textWidth = label:GetStringWidth() or 24
    frame:SetSize(textWidth + 12, 18)
    Widgets.ApplyBackdrop(frame, bgColor, borderColor)

    frame.label = label
    return frame
end

-- ---------------------------------------------------------------------------
-- T053: CreateIconRow — fixed-height row with icon placeholder, label, value, badge
-- ---------------------------------------------------------------------------
function Widgets.CreateIconRow(parent, options)
    options = options or {}
    local L = Widgets.LAYOUT
    local iconSize           = options.iconSize           or L.ICON_SIZE
    local maxLabelWidth      = options.maxLabelWidth      or 120
    local maxValueWidth      = options.maxValueWidth      or 80
    local showPlaceholder    = options.showPlaceholder
    if showPlaceholder == nil then showPlaceholder = true end

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(L.ROW_HEIGHT)

    -- Icon region — always L.ICON_RESERVED_WIDTH wide so text anchors never shift
    local iconRegion = row:CreateTexture(nil, "ARTWORK")
    iconRegion:SetSize(iconSize, iconSize)
    iconRegion:SetPoint("LEFT", row, "LEFT", 0, 0)
    if showPlaceholder then
        iconRegion:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        iconRegion:SetVertexColor(0.35, 0.38, 0.42, 1)
    end
    row.iconRegion = iconRegion

    -- Invisible spacer keeps the label anchored to ICON_RESERVED_WIDTH, not iconSize
    local iconSpacer = row:CreateTexture(nil, "BACKGROUND")
    iconSpacer:SetSize(L.ICON_RESERVED_WIDTH, 1)
    iconSpacer:SetPoint("LEFT", row, "LEFT", 0, 0)
    iconSpacer:SetAlpha(0)

    -- Label — truncates with ellipsis, never wraps
    local labelFs = row:CreateFontString(nil, "OVERLAY", L.LABEL_FONT)
    labelFs:SetPoint("LEFT", iconSpacer, "RIGHT", 2, 0)
    labelFs:SetWidth(maxLabelWidth)
    labelFs:SetJustifyH("LEFT")
    labelFs:SetJustifyV("MIDDLE")
    labelFs:SetWordWrap(false)
    labelFs:SetTextColor(unpack(Widgets.THEME.text))
    labelFs:SetText(options.labelText or "")
    row.labelFs = labelFs

    -- Value — right-aligned within its reserved column
    local valueFs = row:CreateFontString(nil, "OVERLAY", L.VALUE_FONT)
    valueFs:SetWidth(maxValueWidth)
    valueFs:SetJustifyH("RIGHT")
    valueFs:SetJustifyV("MIDDLE")
    valueFs:SetTextColor(unpack(Widgets.THEME.textMuted))
    valueFs:SetText(options.valueText or "")
    row.valueFs = valueFs

    -- Badge — right edge of row
    local badgeFs = row:CreateFontString(nil, "OVERLAY", L.CAPTION_FONT)
    badgeFs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    badgeFs:SetJustifyH("RIGHT")
    badgeFs:SetJustifyV("MIDDLE")
    badgeFs:SetTextColor(unpack(Widgets.THEME.textMuted))
    badgeFs:SetText(options.badgeText or "")
    row.badgeFs = badgeFs

    -- Anchor value to the left of badge (or row right if badge is empty)
    valueFs:SetPoint("RIGHT", badgeFs, "LEFT", -4, 0)

    function row:SetData(iconFileID, labelText, valueText, badgeText)
        Widgets.SetRowIcon(self, iconFileID)
        if labelText ~= nil then self.labelFs:SetText(labelText) end
        if valueText ~= nil then self.valueFs:SetText(valueText) end
        if badgeText ~= nil then self.badgeFs:SetText(badgeText) end
    end

    return row
end

-- ---------------------------------------------------------------------------
-- T054: SetRowIcon — safe icon update that always preserves icon region width
-- ---------------------------------------------------------------------------
function Widgets.SetRowIcon(row, fileID)
    if not row or not row.iconRegion then return end
    local L = Widgets.LAYOUT
    if fileID then
        row.iconRegion:SetTexture(fileID)
        row.iconRegion:SetVertexColor(1, 1, 1, 1)
    else
        -- Placeholder: question-mark icon dimmed — never hides, always ICON_RESERVED_WIDTH wide
        row.iconRegion:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        row.iconRegion:SetVertexColor(0.35, 0.38, 0.42, 1)
    end
    row.iconRegion:SetSize(L.ICON_SIZE, L.ICON_SIZE)
end

ns.Widgets = Widgets
