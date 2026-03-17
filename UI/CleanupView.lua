local _, ns = ...

local CleanupView = {
    viewId = "cleanup",
    rawOnly = false,
}

local function dateKeyToTimestamp(dateKey, endOfDay)
    if ns.Helpers.IsBlank(dateKey) then
        return nil
    end
    local parsed = ns.Helpers.ParseDateKey(dateKey)
    if not parsed then
        return nil
    end
    return time({
        year = parsed.year,
        month = parsed.month,
        day = parsed.day,
        hour = endOfDay and 23 or 0,
        min = endOfDay and 59 or 0,
        sec = endOfDay and 59 or 0,
    })
end

function CleanupView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Cleanup / Maintenance", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Prune stored history manually and rebuild long-term aggregates when needed.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.dateFrom = ns.Widgets.CreateEditBox(self.frame, 100, 20)
    self.dateFrom:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -16)
    self.dateFrom:SetText("")

    self.dateTo = ns.Widgets.CreateEditBox(self.frame, 100, 20)
    self.dateTo:SetPoint("LEFT", self.dateFrom, "RIGHT", 8, 0)
    self.dateTo:SetText("")

    self.contextBox = ns.Widgets.CreateEditBox(self.frame, 120, 20)
    self.contextBox:SetPoint("LEFT", self.dateTo, "RIGHT", 8, 0)
    self.contextBox:SetText("")

    self.opponentBox = ns.Widgets.CreateEditBox(self.frame, 120, 20)
    self.opponentBox:SetPoint("LEFT", self.contextBox, "RIGHT", 8, 0)
    self.opponentBox:SetText("")

    self.rawToggle = ns.Widgets.CreateButton(self.frame, "Raw Only: Off", 110, 22)
    self.rawToggle:SetPoint("LEFT", self.opponentBox, "RIGHT", 8, 0)
    self.rawToggle:SetScript("OnClick", function()
        self.rawOnly = not self.rawOnly
        self.rawToggle:SetText(self.rawOnly and "Raw Only: On" or "Raw Only: Off")
    end)

    self.deleteButton = ns.Widgets.CreateButton(self.frame, "Delete", 80, 22)
    self.deleteButton:SetPoint("LEFT", self.rawToggle, "RIGHT", 8, 0)
    self.deleteButton:SetScript("OnClick", function()
        local filters = {
            dateFrom = dateKeyToTimestamp(self.dateFrom:GetText(), false),
            dateTo = dateKeyToTimestamp(self.dateTo:GetText(), true),
            context = ns.Helpers.Trim(self.contextBox:GetText()),
            opponent = ns.Helpers.Trim(self.opponentBox:GetText()),
            rawLogOnly = self.rawOnly,
        }
        if filters.context == "" then
            filters.context = nil
        end
        if filters.opponent == "" then
            filters.opponent = nil
        end
        local deleted = ns.Addon:GetModule("CombatStore"):DeleteSessions(filters)
        ns.Addon:PrintSuccess(string.format("Cleanup removed %d sessions.", deleted))
        ns.Addon:GetModule("MainFrame"):RefreshAll()
        self:Refresh()
    end)

    self.rebuildButton = ns.Widgets.CreateButton(self.frame, "Rebuild", 80, 22)
    self.rebuildButton:SetPoint("LEFT", self.deleteButton, "RIGHT", 8, 0)
    self.rebuildButton:SetScript("OnClick", function()
        ns.Addon:GetModule("CombatStore"):RebuildAggregates()
        ns.Addon:PrintSuccess("Aggregates rebuilt.")
        ns.Addon:GetModule("MainFrame"):RefreshAll()
        self:Refresh()
    end)

    self.scrollFrame, self.content, self.text = ns.Widgets.CreateBodyText(self.frame, 808, 368)
    self.scrollFrame:SetPoint("TOPLEFT", self.dateFrom, "BOTTOMLEFT", 0, -14)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    return self.frame
end

function CleanupView:Refresh()
    local stats = ns.Addon:GetModule("CombatStore"):GetStorageStats()
    local lines = {
        "Filters",
        "dateFrom/dateTo use YYYY-MM-DD.",
        "context values: duel, arena, battleground, world_pvp, training_dummy, general.",
        "",
        "Storage",
        string.format("Sessions: %d", stats.sessions or 0),
        string.format("Matches: %d", stats.matches or 0),
        string.format("Raw Events: %d", stats.totalRawEvents or 0),
        "",
        "Warnings",
    }

    if #(stats.warnings or {}) == 0 then
        lines[#lines + 1] = "No storage warnings."
    else
        for _, warning in ipairs(stats.warnings or {}) do
            lines[#lines + 1] = string.format("%s  %s", date("%Y-%m-%d %H:%M", warning.timestamp or time()), warning.message or "")
        end
    end

    ns.Widgets.SetBodyText(self.content, self.text, table.concat(lines, "\n"))
end

ns.Addon:RegisterModule("CleanupView", CleanupView)
