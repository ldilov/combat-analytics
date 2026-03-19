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
        local contentWidth = math.max(1, (scrollFrame:GetWidth() or (width - 52)) - 10)
        content:SetWidth(contentWidth)
        local contentHeight = math.max(content:GetHeight() or 0, 1)
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
            Widgets.ApplyBackdrop(self, Widgets.THEME.accentSoft, Widgets.THEME.borderStrong)
            self.text:SetTextColor(unpack(Widgets.THEME.text))
        elseif not self:IsEnabled() then
            Widgets.ApplyBackdrop(self, Widgets.THEME.panelDisabled, Widgets.THEME.border)
            self.text:SetTextColor(0.42, 0.48, 0.55, 1)
        else
            Widgets.ApplyBackdrop(self, Widgets.THEME.panelAlt, Widgets.THEME.border)
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
        Widgets.ApplyBackdrop(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
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
        Widgets.ApplyBackdrop(self, Widgets.THEME.panelAlt, Widgets.THEME.borderStrong)
    end)
    editBox:HookScript("OnEditFocusLost", function(self)
        Widgets.ApplyBackdrop(self, Widgets.THEME.panelAlt, Widgets.THEME.border)
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
        Widgets.ApplyBackdrop(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
    end)
    button:SetScript("OnLeave", function(self)
        Widgets.ApplyBackdrop(self, Widgets.THEME.panel, Widgets.THEME.border)
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

        Widgets.ApplyBackdrop(self.badge, palette, border)
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
        Widgets.ApplyBackdrop(self, nextBackgroundColor or backgroundColor or Widgets.THEME.accentSoft, nextBorderColor or borderColor or Widgets.THEME.borderStrong)
        self.text:SetText(labelText or "")
        self.text:SetTextColor(unpack(textColor or Widgets.THEME.text))
        self:Show()
    end

    return pill
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

    button.title = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.title:SetPoint("TOPLEFT", button, "TOPLEFT", 14, -10)
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
        Widgets.ApplyBackdrop(self, Widgets.THEME.panelHover, Widgets.THEME.borderStrong)
    end)
    button:SetScript("OnLeave", function(self)
        Widgets.ApplyBackdrop(self, Widgets.THEME.panel, Widgets.THEME.border)
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
        self:Show()
    end

    return button
end

ns.Widgets = Widgets
