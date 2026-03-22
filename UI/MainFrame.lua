local _, ns = ...

local MainFrame = {
    tabs = {
        { id = "summary", label = "Summary", module = "SummaryView" },
        { id = "history", label = "History", module = "CombatHistoryView" },
        { id = "detail", label = "Detail", module = "CombatDetailView" },
        { id = "opponents", label = "Opponent", module = "OpponentStatsView" },
        { id = "classspec", label = "Specs", module = "ClassSpecView" },
        { id = "matchup", label = "Matchup", module = "MatchupDetailView", hidden = true },
        { id = "dummy", label = "Dummy", module = "DummyBenchmarkView" },
        { id = "rating", label = "Rating", module = "RatingView" },
        { id = "insights", label = "Insights", module = "SuggestionsView" },
        { id = "counterguide", label = "Counters", module = "CounterGuideView" },
        { id = "builds",      label = "Builds",  module = "BuildComparatorView" },
        { id = "cleanup",     label = "Cleanup", module = "CleanupView" },
    },
}

local function runViewMethod(viewModule, methodName, ...)
    if not viewModule or type(viewModule[methodName]) ~= "function" then
        return true
    end

    local args = { ... }
    local ok, err = xpcall(function()
        viewModule[methodName](viewModule, unpack(args))
    end, debugstack)
    if not ok then
        ns.Addon:Warn(string.format("CombatAnalytics %s view failed.", tostring(viewModule.viewId or methodName)))
        ns.Addon:Debug("%s", err)
        return false
    end
    return true
end

function MainFrame:Initialize()
    if self.frame then
        return
    end

    self.frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    self.frame:SetSize(860, 600)
    self.frame:SetPoint("CENTER")
    self.frame:SetMovable(true)
    self.frame:SetResizable(true)
    if self.frame.SetResizeBounds then
        self.frame:SetResizeBounds(860, 600, 1320, 920)
    elseif self.frame.SetMinResize then
        self.frame:SetMinResize(860, 600)
    end
    self.frame:EnableMouse(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", self.frame.StartMoving)
    self.frame:SetScript("OnDragStop", self.frame.StopMovingOrSizing)
    self.frame:Hide()
    ns.Widgets.ApplyBackdrop(self.frame, ns.Widgets.THEME.background, ns.Widgets.THEME.borderStrong, { left = 1, right = 1, top = 1, bottom = 1 })

    self.header = ns.Widgets.CreateSurface(self.frame, 1, 78, ns.Widgets.THEME.header, ns.Widgets.THEME.borderStrong)
    self.header:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 2, -2)
    self.header:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -2, -2)

    self.accentBar = CreateFrame("Frame", nil, self.header, "BackdropTemplate")
    self.accentBar:SetPoint("BOTTOMLEFT", self.header, "BOTTOMLEFT", 0, 0)
    self.accentBar:SetPoint("BOTTOMRIGHT", self.header, "BOTTOMRIGHT", 0, 0)
    self.accentBar:SetHeight(2)
    ns.Widgets.ApplyBackdrop(self.accentBar, ns.Widgets.THEME.accent, ns.Widgets.THEME.accent, { left = 0, right = 0, top = 0, bottom = 0 })

    self.title = self.header:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    self.title:SetPoint("TOPLEFT", self.header, "TOPLEFT", 18, -14)
    self.title:SetText("CombatAnalytics")
    self.title:SetTextColor(unpack(ns.Widgets.THEME.text))

    self.subtitle = self.header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.subtitle:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)
    self.subtitle:SetText("Post-combat analytics for arenas, duels, battlegrounds, world PvP, and benchmark sessions")
    self.subtitle:SetTextColor(unpack(ns.Widgets.THEME.textMuted))

    self.closeButton = ns.Widgets.CreateButton(self.header, "Close", 64, 22)
    self.closeButton:SetPoint("TOPRIGHT", self.header, "TOPRIGHT", -10, -12)
    self.closeButton:SetScript("OnClick", function()
        self.frame:Hide()
    end)

    self.resizeHandle = CreateFrame("Button", nil, self.frame)
    self.resizeHandle:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -6, 6)
    self.resizeHandle:SetSize(18, 18)
    self.resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    self.resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    self.resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    self.resizeHandle:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            self.frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    self.resizeHandle:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            self.frame:StopMovingOrSizing()
        end
    end)

    -- Two-row tab strip: up to TABS_PER_ROW buttons on row 1, rest on row 2.
    local TABS_PER_ROW = 6
    local ROW_H        = 28
    local ROW_GAP      = 6

    self.tabStrip = CreateFrame("Frame", nil, self.frame)
    self.tabStrip:SetPoint("TOPLEFT", self.header, "BOTTOMLEFT", 16, -10)
    self.tabStrip:SetPoint("TOPRIGHT", self.header, "BOTTOMRIGHT", -16, -10)
    self.tabStrip:SetHeight(ROW_H * 2 + ROW_GAP)

    self.contentShell = ns.Widgets.CreateSurface(self.frame, 1, 1, ns.Widgets.THEME.contentShell, ns.Widgets.THEME.border)
    self.contentShell:SetPoint("TOPLEFT", self.tabStrip, "BOTTOMLEFT", 0, -10)
    self.contentShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.content = CreateFrame("Frame", nil, self.contentShell)
    self.content:SetPoint("TOPLEFT", self.contentShell, "TOPLEFT", 12, -12)
    self.content:SetPoint("BOTTOMRIGHT", self.contentShell, "BOTTOMRIGHT", -12, 12)

    self.buttons = {}
    self.views = {}

    -- Collect visible tabs first so row splitting is index-based.
    local visibleTabs = {}
    for _, tab in ipairs(self.tabs) do
        if not tab.hidden then
            visibleTabs[#visibleTabs + 1] = tab
        end
    end

    local prevRow1 = nil
    local prevRow2 = nil

    for _, tab in ipairs(self.tabs) do
        -- Build the view regardless of whether the tab button is visible.
        local viewModule = ns.Addon:GetModule(tab.module)
        local viewAvailable = false
        if viewModule then
            if runViewMethod(viewModule, "Build", self.content) and viewModule.frame then
                viewAvailable = true
                self.views[tab.id] = viewModule
                viewModule.frame:Hide()
            end
        end

        if not tab.hidden then
            local width  = math.max(72, 24 + (string.len(tab.label) * 7))
            local button = ns.Widgets.CreateButton(self.tabStrip, tab.label, width, 24)

            -- Determine which row this tab falls on by its position in visibleTabs.
            local visibleIndex = 0
            for vi, vt in ipairs(visibleTabs) do
                if vt.id == tab.id then visibleIndex = vi break end
            end

            if visibleIndex <= TABS_PER_ROW then
                -- Row 1 (top)
                if prevRow1 then
                    button:SetPoint("TOPLEFT", prevRow1, "TOPRIGHT", 4, 0)
                else
                    button:SetPoint("TOPLEFT", self.tabStrip, "TOPLEFT", 0, 0)
                end
                prevRow1 = button
            else
                -- Row 2 (bottom)
                if prevRow2 then
                    button:SetPoint("TOPLEFT", prevRow2, "TOPRIGHT", 4, 0)
                else
                    button:SetPoint("TOPLEFT", self.tabStrip, "TOPLEFT", 0, -(ROW_H + ROW_GAP))
                end
                prevRow2 = button
            end

            button:SetScript("OnClick", function()
                self:ShowView(tab.id)
            end)
            button.isViewAvailable = viewAvailable
            if not viewAvailable then
                button:SetEnabled(false)
            end
            self.buttons[tab.id] = button
        end
    end
end

function MainFrame:RefreshAll()
    for _, tab in ipairs(self.tabs) do
        local view = self.views[tab.id]
        if view and view.Refresh then
            runViewMethod(view, "Refresh")
        end
    end
end

function MainFrame:ShowView(viewId, payload)
    if not self.frame then
        self:Initialize()
    end

    if InCombatLockdown and InCombatLockdown() then
        ns.Addon:PrintWarning("CombatAnalytics UI cannot open during combat. Use /ca after combat ends.")
        return
    end

    self.frame:Show()
    self.activeViewId = viewId or self.activeViewId or "summary"
    if not self.views[self.activeViewId] then
        for _, tab in ipairs(self.tabs) do
            if self.views[tab.id] then
                self.activeViewId = tab.id
                break
            end
        end
    end
    if not self.activeViewId then
        ns.Addon:PrintWarning("CombatAnalytics has no available views to display.")
        self.frame:Hide()
        return
    end

    for _, tab in ipairs(self.tabs) do
        local isActive = tab.id == self.activeViewId
        local button = self.buttons[tab.id]
        if button then
            local isAvailable = button.isViewAvailable ~= false
            button:SetActive(isActive and isAvailable)
            button:SetEnabled(isAvailable)
        end
        local view = self.views[tab.id]
        if view and view.frame then
            if isActive then
                view.frame:Show()
                if view.Refresh then
                    runViewMethod(view, "Refresh", payload)
                end
            else
                view.frame:Hide()
            end
        end
    end

    -- When navigating to a hidden tab (e.g. matchup drill-down),
    -- deactivate all visible tab buttons since none of them match.
    local activeHasButton = self.buttons[self.activeViewId] ~= nil
    if not activeHasButton then
        for tabId, button in pairs(self.buttons) do
            button:SetActive(false)
        end
    end
end

ns.Addon:RegisterModule("MainFrame", MainFrame)
