local _, ns = ...

local Constants = ns.Constants

local CombatHistoryView = {
    viewId = "history",
    page = 1,
    rowCount = 6,
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

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 390)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -18)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.rows = {}
    for index = 1, self.rowCount do
        local row = ns.Widgets.CreateHistoryRow(self.canvas, 750, 58)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", self.rows[index - 1], "BOTTOMLEFT", 0, -6)
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

    ns.Widgets.SetCanvasHeight(self.canvas, (self.rowCount * 64) + 8)

    return self.frame
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
    local sessions, total = store:ListCombats(self.page, self.rowCount, nil, characterKey)
    local totalPages = math.max(1, math.ceil(total / self.rowCount))
    if self.page > totalPages then
        self.page = totalPages
        sessions, total = store:ListCombats(self.page, self.rowCount, nil, characterKey)
    end

    self.pageText:SetText(string.format("Page %d / %d", self.page, totalPages))
    self.prevButton:SetEnabled(self.page > 1)
    self.nextButton:SetEnabled(self.page < totalPages)
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    end

    for index = 1, self.rowCount do
        local row = self.rows[index]
        local session = sessions[index]
        if session then
            row:Show()
            row.sessionId = session.id
            local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown"
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
                    ns.Helpers.FormatNumber(session.totals.damageDone or 0),
                    ns.Helpers.FormatNumber(session.totals.damageTaken or 0),
                    session.metrics.pressureScore or 0,
                    session.metrics.burstScore or 0
                ),
                source = string.format("%s via %s", richLabel, readSource),
                result = string.lower(tostring(session.result or "unknown")),
                resultLabel = prettifyToken(session.result),
                analysisConfidence = session.analysisConfidence or "limited",
                confidenceLabel = richLabel,
            })
        else
            row:Hide()
            row.sessionId = nil
        end
    end
end

ns.Addon:RegisterModule("CombatHistoryView", CombatHistoryView)
