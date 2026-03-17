local _, ns = ...

local SettingsPanel = {}

local function createText(parent, fontObject, text, anchor, relativeTo, relativePoint, x, y, color)
    local label = parent:CreateFontString(nil, "ARTWORK", fontObject)
    label:SetPoint(anchor, relativeTo, relativePoint, x or 0, y or 0)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    if color then
        label:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    end
    label:SetText(text or "")
    return label
end

function SettingsPanel:RefreshStatus()
    if not self.statusText then
        return
    end

    local store = ns.Addon:GetModule("CombatStore")
    local tracker = ns.Addon:GetModule("CombatTracker")
    local stats = store and store:GetStorageStats() or {}
    local active = tracker and tracker:GetCurrentSession() or nil

    local lines = {
        "Status",
        string.format("Stored sessions: %d", stats.sessions or 0),
        string.format("Stored matches: %d", stats.matches or 0),
        string.format("Stored raw events: %d", stats.totalRawEvents or 0),
        string.format("Active session: %s", active and active.id or "none"),
        string.format("Active context: %s", active and active.context or "none"),
        "Combat analytics source: built-in Damage Meter (Midnight-safe mode)",
        "",
        "Settings",
        string.format("Debug logging: %s", ns.Addon:IsDebugEnabled() and "enabled" or "disabled"),
        "Raw event timeline: unavailable on Midnight-safe mode",
        string.format("Include general combat: %s", ns.Addon:GetSetting("includeGeneralCombat") and "enabled" or "disabled"),
        "Minimap button: disabled during stabilization",
        "",
        "Use /caa or /combatanalytics to open the addon directly.",
    }

    self.statusText:SetText(table.concat(lines, "\n"))
end

function SettingsPanel:Open()
    if InCombatLockdown and InCombatLockdown() then
        ns.Addon:PrintWarning("CombatAnalytics settings cannot open during combat.")
        return
    end

    if not self.initialized then
        self:Initialize()
    end

    if self.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(self.category:GetID())
        return
    end

    if InterfaceOptionsFrame_OpenToCategory and self.panel then
        InterfaceOptionsFrame_OpenToCategory(self.panel)
        InterfaceOptionsFrame_OpenToCategory(self.panel)
    end
end

function SettingsPanel:BuildPanel()
    if self.panel then
        return
    end

    local panel = CreateFrame("Frame")
    panel.name = "CombatAnalytics"
    panel:Hide()

    self.title = createText(panel, "GameFontNormalLarge", "CombatAnalytics", "TOPLEFT", panel, "TOPLEFT", 16, -16, ns.Widgets.THEME.text)
    self.subtitle = createText(panel, "GameFontHighlightSmall", "Post-combat analytics for arenas, duels, battlegrounds, and training dummies.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -6, ns.Widgets.THEME.textMuted)

    self.openButton = ns.Widgets.CreateButton(panel, "Open Summary", 120, 24)
    self.openButton:SetPoint("TOPLEFT", self.subtitle, "BOTTOMLEFT", 0, -18)
    self.openButton:SetScript("OnClick", function()
        ns.Addon:OpenView("summary")
    end)

    self.historyButton = ns.Widgets.CreateButton(panel, "Open History", 120, 24)
    self.historyButton:SetPoint("LEFT", self.openButton, "RIGHT", 8, 0)
    self.historyButton:SetScript("OnClick", function()
        ns.Addon:OpenView("history")
    end)

    self.insightsButton = ns.Widgets.CreateButton(panel, "Open Insights", 120, 24)
    self.insightsButton:SetPoint("LEFT", self.historyButton, "RIGHT", 8, 0)
    self.insightsButton:SetScript("OnClick", function()
        ns.Addon:OpenView("insights")
    end)

    self.cleanupButton = ns.Widgets.CreateButton(panel, "Open Cleanup", 120, 24)
    self.cleanupButton:SetPoint("LEFT", self.insightsButton, "RIGHT", 8, 0)
    self.cleanupButton:SetScript("OnClick", function()
        ns.Addon:OpenView("cleanup")
    end)

    self.debugButton = ns.Widgets.CreateButton(panel, "Toggle Debug", 120, 24)
    self.debugButton:SetPoint("TOPLEFT", self.openButton, "BOTTOMLEFT", 0, -16)
    self.debugButton:SetScript("OnClick", function()
        ns.Addon:SetSetting("enableDebugLogging", not ns.Addon:IsDebugEnabled())
        self:RefreshStatus()
    end)

    self.rawButton = ns.Widgets.CreateButton(panel, "Toggle Raw Events", 140, 24)
    self.rawButton:SetPoint("LEFT", self.debugButton, "RIGHT", 8, 0)
    self.rawButton:SetScript("OnClick", function()
        ns.Addon:SetSetting("keepRawEvents", not ns.Addon:GetSetting("keepRawEvents"))
        self:RefreshStatus()
    end)
    self.rawButton:SetText("Raw Events N/A")
    self.rawButton:SetEnabled(false)

    self.generalButton = ns.Widgets.CreateButton(panel, "Toggle General Combat", 160, 24)
    self.generalButton:SetPoint("LEFT", self.rawButton, "RIGHT", 8, 0)
    self.generalButton:SetScript("OnClick", function()
        ns.Addon:SetSetting("includeGeneralCombat", not ns.Addon:GetSetting("includeGeneralCombat"))
        self:RefreshStatus()
    end)

    self.statusText = createText(panel, "GameFontHighlight", "", "TOPLEFT", self.debugButton, "BOTTOMLEFT", 0, -18, ns.Widgets.THEME.text)
    self.statusText:SetWidth(680)

    panel:SetScript("OnShow", function()
        self:RefreshStatus()
    end)

    self.panel = panel
end

function SettingsPanel:Initialize()
    if self.initialized then
        return
    end

    self:BuildPanel()

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        self.category = Settings.RegisterCanvasLayoutCategory(self.panel, self.panel.name)
        Settings.RegisterAddOnCategory(self.category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(self.panel)
    end

    self.initialized = true
end

ns.Addon:RegisterModule("SettingsPanel", SettingsPanel)
