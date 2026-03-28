local _, ns = ...

local CleanupView = {
    viewId = "cleanup",
    rawOnly = false,
}

local Constants = ns.Constants
local Helpers = ns.Helpers

-- Context colors for the segmented bar — distinct hues per combat context.
local CONTEXT_COLORS = {
    [Constants.CONTEXT.ARENA]           = { 0.90, 0.35, 0.35, 1.0 },
    [Constants.CONTEXT.DUEL]            = { 0.35, 0.78, 0.90, 1.0 },
    [Constants.CONTEXT.BATTLEGROUND]    = { 0.44, 0.82, 0.60, 1.0 },
    [Constants.CONTEXT.WORLD_PVP]       = { 0.96, 0.74, 0.38, 1.0 },
    [Constants.CONTEXT.TRAINING_DUMMY]  = { 0.68, 0.55, 0.88, 1.0 },
    [Constants.CONTEXT.GENERAL]         = { 0.55, 0.58, 0.62, 1.0 },
}

-- Ordered list of contexts for deterministic bar/legend rendering.
local CONTEXT_ORDER = {
    Constants.CONTEXT.ARENA,
    Constants.CONTEXT.BATTLEGROUND,
    Constants.CONTEXT.DUEL,
    Constants.CONTEXT.WORLD_PVP,
    Constants.CONTEXT.TRAINING_DUMMY,
    Constants.CONTEXT.GENERAL,
}

local function dateKeyToTimestamp(dateKey, endOfDay)
    if Helpers.IsBlank(dateKey) then
        return nil
    end
    local parsed = Helpers.ParseDateKey(dateKey)
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

--- Build the current filter table from the edit boxes.
--- @return table filters
local function buildFilters(self)
    local filters = {
        dateFrom = dateKeyToTimestamp(self.dateFrom:GetText(), false),
        dateTo = dateKeyToTimestamp(self.dateTo:GetText(), true),
        context = Helpers.Trim(self.contextBox:GetText()),
        opponent = Helpers.Trim(self.opponentBox:GetText()),
        rawLogOnly = self.rawOnly,
    }
    if filters.context == "" then
        filters.context = nil
    end
    if filters.opponent == "" then
        filters.opponent = nil
    end
    return filters
end

--- Return true when any user-facing filter field is non-empty.
--- @return boolean
local function hasActiveFilters(self)
    local filters = buildFilters(self)
    return filters.dateFrom ~= nil
        or filters.dateTo ~= nil
        or filters.context ~= nil
        or filters.opponent ~= nil
end

--- Count sessions matching the supplied filters by iterating the store.
--- Mirrors the same matching logic used in CombatStore:DeleteSessions.
--- @return number matchCount
local function countMatchingSessions(filters)
    local store = ns.Addon:GetModule("CombatStore")
    local db = store:GetDB()
    local count = 0

    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session then
            local matches = true

            if filters.dateFrom and session.timestamp < filters.dateFrom then
                matches = false
            end
            if matches and filters.dateTo and session.timestamp > filters.dateTo then
                matches = false
            end
            if matches and filters.context and session.context ~= filters.context then
                matches = false
            end
            if matches and filters.opponent then
                local opponent = session.primaryOpponent
                if not opponent or (opponent.guid ~= filters.opponent and opponent.name ~= filters.opponent) then
                    matches = false
                end
            end
            if matches and filters.rawLogOnly and #(session.rawEvents or {}) == 0 then
                matches = false
            end

            if matches then
                count = count + 1
            end
        end
    end

    return count
end

--- Count sessions per context and count legacy (pre-v6) sessions.
--- @return table contextCounts  e.g. { arena = 12, duel = 5, ... }
--- @return number legacyCount   sessions with LEGACY_CLEU_IMPORT confidence
local function countByContextAndLegacy()
    local store = ns.Addon:GetModule("CombatStore")
    local db = store:GetDB()
    local contextCounts = {}
    local legacyCount = 0

    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session then
            local ctx = session.context or Constants.CONTEXT.GENERAL
            contextCounts[ctx] = (contextCounts[ctx] or 0) + 1

            local confidence = session.captureQuality and session.captureQuality.confidence
            if confidence == Constants.SESSION_CONFIDENCE.LEGACY_CLEU_IMPORT then
                legacyCount = legacyCount + 1
            end
        end
    end

    return contextCounts, legacyCount
end

--- Pick the storage-pressure color based on fill fraction.
--- @param fraction number  0..1+
--- @return table color  {r, g, b, a}
local function pressureColor(fraction)
    if fraction >= 0.80 then
        return { 0.90, 0.30, 0.25, 1.0 }
    elseif fraction >= 0.50 then
        return ns.Widgets.THEME.warning
    end
    return ns.Widgets.THEME.success
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────────────────────────────────────

function CleanupView:Build(parent)
    local Widgets = ns.Widgets
    local THEME = Widgets.THEME

    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    -- Title / caption --------------------------------------------------------

    self.title = Widgets.CreateSectionTitle(self.frame, "Cleanup / Maintenance", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = Widgets.CreateCaption(self.frame, "Prune stored history manually and rebuild long-term aggregates when needed.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Filter row -------------------------------------------------------------

    self.dateFrom = Widgets.CreateEditBox(self.frame, 100, 20)
    self.dateFrom:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -16)
    self.dateFrom:SetText("")

    self.dateTo = Widgets.CreateEditBox(self.frame, 100, 20)
    self.dateTo:SetPoint("LEFT", self.dateFrom, "RIGHT", 8, 0)
    self.dateTo:SetText("")

    self.contextBox = Widgets.CreateEditBox(self.frame, 120, 20)
    self.contextBox:SetPoint("LEFT", self.dateTo, "RIGHT", 8, 0)
    self.contextBox:SetText("")

    self.opponentBox = Widgets.CreateEditBox(self.frame, 120, 20)
    self.opponentBox:SetPoint("LEFT", self.contextBox, "RIGHT", 8, 0)
    self.opponentBox:SetText("")

    self.rawToggle = Widgets.CreateButton(self.frame, "Raw Only: Off", 110, 22)
    self.rawToggle:SetPoint("LEFT", self.opponentBox, "RIGHT", 8, 0)
    self.rawToggle:SetScript("OnClick", function()
        self.rawOnly = not self.rawOnly
        self.rawToggle:SetText(self.rawOnly and "Raw Only: On" or "Raw Only: Off")
        self:Refresh()
    end)

    self.deleteButton = Widgets.CreateButton(self.frame, "Delete", 80, 22)
    self.deleteButton:SetPoint("LEFT", self.rawToggle, "RIGHT", 8, 0)
    self.deleteButton:SetScript("OnClick", function()
        local filters = buildFilters(self)
        local deleted = ns.Addon:GetModule("CombatStore"):DeleteSessions(filters)
        ns.Addon:PrintSuccess(string.format("Cleanup removed %d sessions.", deleted))
        ns.Addon:GetModule("MainFrame"):RefreshAll()
        self:Refresh()
    end)

    self.rebuildButton = Widgets.CreateButton(self.frame, "Rebuild", 80, 22)
    self.rebuildButton:SetPoint("LEFT", self.deleteButton, "RIGHT", 8, 0)
    self.rebuildButton:SetScript("OnClick", function()
        ns.Addon:GetModule("CombatStore"):RebuildAggregates()
        ns.Addon:PrintSuccess("Aggregates rebuilt.")
        ns.Addon:GetModule("MainFrame"):RefreshAll()
        self:Refresh()
    end)

    -- Visual indicators area (below filter row) ------------------------------

    local indicatorAnchor = self.dateFrom
    local indicatorY = -18

    -- 1. Sessions-by-context segmented bar -----------------------------------

    self.contextBarTitle = Widgets.CreateSectionTitle(self.frame, "Sessions by Context", "TOPLEFT", indicatorAnchor, "BOTTOMLEFT", 0, indicatorY)
    self.contextBarTitle:SetFontObject("GameFontHighlight")
    self.contextBarTitle:SetTextColor(unpack(THEME.text))

    -- Placeholder bar — rebuilt on every Refresh with current data.
    self.contextBarHolder = CreateFrame("Frame", nil, self.frame)
    self.contextBarHolder:SetPoint("TOPLEFT", self.contextBarTitle, "BOTTOMLEFT", 0, -6)
    self.contextBarHolder:SetSize(600, 16)

    -- Legend holder
    self.contextLegendHolder = CreateFrame("Frame", nil, self.frame)
    self.contextLegendHolder:SetPoint("TOPLEFT", self.contextBarHolder, "BOTTOMLEFT", 0, -4)
    self.contextLegendHolder:SetSize(600, 14)

    -- 2. Storage-pressure metric bar -----------------------------------------

    self.storagePressureBar = Widgets.CreateMetricBar(self.frame, 600, 58)
    self.storagePressureBar:SetPoint("TOPLEFT", self.contextLegendHolder, "BOTTOMLEFT", 0, -14)

    -- 3. Legacy data pill ----------------------------------------------------

    self.legacyHolder = CreateFrame("Frame", nil, self.frame)
    self.legacyHolder:SetPoint("TOPLEFT", self.storagePressureBar, "BOTTOMLEFT", 0, -10)
    self.legacyHolder:SetSize(600, 22)

    self.legacyLabel = self.legacyHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.legacyLabel:SetPoint("LEFT", self.legacyHolder, "LEFT", 0, 0)
    self.legacyLabel:SetText("Legacy Sessions:")
    self.legacyLabel:SetTextColor(unpack(THEME.textMuted))

    self.legacyPill = Widgets.CreatePill(self.legacyHolder, 84, 18)
    self.legacyPill:SetPoint("LEFT", self.legacyLabel, "RIGHT", 8, 0)

    -- 4. Delete-preview card -------------------------------------------------

    self.deletePreviewCard = Widgets.CreateMetricCard(self.frame, 280, 80)
    self.deletePreviewCard:SetPoint("TOPLEFT", self.legacyHolder, "BOTTOMLEFT", 0, -14)
    self.deletePreviewCard:Hide()

    -- 5. Body text (storage stats + warnings) --------------------------------

    self.scrollFrame, self.content, self.text = Widgets.CreateBodyText(self.frame, 808, 200)
    self.scrollFrame:SetPoint("TOPLEFT", self.deletePreviewCard, "BOTTOMLEFT", 0, -14)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    -- Wire up filter change listeners to auto-refresh the preview.
    local onFilterChange = function()
        self:RefreshDeletePreview()
    end
    self.dateFrom:HookScript("OnTextChanged", onFilterChange)
    self.dateTo:HookScript("OnTextChanged", onFilterChange)
    self.contextBox:HookScript("OnTextChanged", onFilterChange)
    self.opponentBox:HookScript("OnTextChanged", onFilterChange)

    return self.frame
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Refresh
-- ─────────────────────────────────────────────────────────────────────────────

function CleanupView:Refresh()
    local Widgets = ns.Widgets
    local THEME = Widgets.THEME
    local stats = ns.Addon:GetModule("CombatStore"):GetStorageStats()
    local contextCounts, legacyCount = countByContextAndLegacy()
    local totalSessions = stats.sessions or 0

    -- 1. Rebuild sessions-by-context segmented bar ---------------------------

    -- Clear old bar/legend children
    if self._contextBar then
        self._contextBar:Hide()
        self._contextBar:SetParent(nil)
        self._contextBar = nil
    end
    if self._contextLegend then
        self._contextLegend:Hide()
        self._contextLegend:SetParent(nil)
        self._contextLegend = nil
    end

    local segments = {}
    local legendEntries = {}
    for _, ctx in ipairs(CONTEXT_ORDER) do
        local count = contextCounts[ctx] or 0
        if count > 0 then
            segments[#segments + 1] = {
                value = count,
                color = CONTEXT_COLORS[ctx] or THEME.textMuted,
                label = string.format("%s (%d)", ctx, count),
            }
        end
        -- Always include in legend so the user knows what colors map to what.
        legendEntries[#legendEntries + 1] = {
            color = CONTEXT_COLORS[ctx] or THEME.textMuted,
            label = ctx,
        }
    end

    if #segments > 0 then
        self._contextBar = Widgets.CreateSegmentedBar(self.contextBarHolder, segments, 600, 16)
        self._contextBar:SetPoint("TOPLEFT", self.contextBarHolder, "TOPLEFT", 0, 0)
        self.contextBarHolder:Show()
    else
        self.contextBarHolder:Hide()
    end

    self._contextLegend = Widgets.CreateMiniLegend(self.contextLegendHolder, legendEntries, 10)
    self._contextLegend:SetPoint("TOPLEFT", self.contextLegendHolder, "TOPLEFT", 0, 0)

    -- 2. Storage-pressure metric bar -----------------------------------------

    local totalRaw = stats.totalRawEvents or 0
    local threshold = Constants.RAW_EVENT_WARNING_THRESHOLD
    local fraction = threshold > 0 and (totalRaw / threshold) or 0
    local color = pressureColor(fraction)

    self.storagePressureBar:SetData(
        "Raw Event Storage",
        Helpers.FormatNumber(totalRaw) .. " / " .. Helpers.FormatNumber(threshold),
        string.format(
            "%s raw events stored. %s",
            Helpers.FormatNumber(totalRaw),
            fraction >= 0.80 and "Consider pruning old sessions." or
            fraction >= 0.50 and "Approaching warning threshold." or
            "Storage usage is healthy."
        ),
        math.min(fraction, 1),
        color,
        0.80 -- marker at the 80% warning line
    )

    -- 3. Legacy data pill ----------------------------------------------------

    if legacyCount > 0 then
        local pillBg = { 0.22, 0.24, 0.26, 1.0 }
        local pillBorder = { 0.50, 0.54, 0.58, 1.0 }
        self.legacyPill:SetData(
            string.format("%d legacy", legacyCount),
            THEME.text,
            pillBg,
            pillBorder
        )
        self.legacyHolder:Show()
    else
        self.legacyPill:SetData("0 legacy", THEME.textMuted)
        self.legacyHolder:Show()
    end

    -- 4. Delete preview (refreshed separately) --------------------------------

    self:RefreshDeletePreview()

    -- 5. Body text (storage stats + warnings) --------------------------------

    local lines = {
        "Filters",
        "dateFrom/dateTo use YYYY-MM-DD.",
        "context values: duel, arena, battleground, world_pvp, training_dummy, general.",
        "",
        "Storage",
        string.format("Sessions: %d", totalSessions),
        string.format("Matches: %d", stats.matches or 0),
        string.format("Raw Events: %d", totalRaw),
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Delete Preview
-- ─────────────────────────────────────────────────────────────────────────────

function CleanupView:RefreshDeletePreview()
    local Widgets = ns.Widgets
    local THEME = Widgets.THEME

    if not hasActiveFilters(self) then
        self.deletePreviewCard:Hide()
        return
    end

    local filters = buildFilters(self)
    local matchCount = countMatchingSessions(filters)

    local color
    if matchCount == 0 then
        color = THEME.textMuted
    elseif matchCount <= 10 then
        color = THEME.warning
    else
        color = { 0.90, 0.30, 0.25, 1.0 }
    end

    self.deletePreviewCard:SetData(
        tostring(matchCount),
        "Sessions matching filters",
        matchCount == 0
            and "No sessions match the current filters."
            or string.format("%d session(s) will be removed on Delete.", matchCount),
        color
    )
    self.deletePreviewCard:Show()
end

ns.Addon:RegisterModule("CleanupView", CleanupView)
