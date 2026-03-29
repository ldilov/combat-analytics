local _, ns = ...

local Constants = ns.Constants
local Theme = ns.Widgets.THEME

local CombatDetailView = {
    viewId = "detail",
    rawPage = 1,
    sessionId = nil,
}

-- Timeline replay constants
local TIMELINE_HEIGHT = 120
local TIMELINE_BAR_WIDTH = 2
local TIMELINE_CC_ALPHA = 0.3
local TIMELINE_DEATH_WIDTH = 3
local TIMELINE_MAX_EVENTS = 500
local TIMELINE_MARGIN_LEFT = 8
local TIMELINE_MARGIN_RIGHT = 8

local TIMELINE_COLORS = {
    damageDealt = { 0.35, 0.55, 0.90, 0.8 },
    damageTaken = { 0.90, 0.30, 0.25, 0.8 },
    ccWindow    = { 0.95, 0.65, 0.15, TIMELINE_CC_ALPHA },
    healing     = { 0.44, 0.82, 0.60, 0.8 },
    death       = { 1.0, 0.0, 0.0, 1.0 },
    centerLine  = { 0.5, 0.5, 0.5, 0.3 },
}

-- Texture pool: acquire a hidden texture from the pool or create a new one.
local function acquireTexture(pool, parent)
    for index = 1, #pool do
        local tex = pool[index]
        if not tex._inUse then
            tex._inUse = true
            tex:SetParent(parent)
            tex:ClearAllPoints()
            tex:Show()
            return tex
        end
    end
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture("Interface\\Buttons\\WHITE8x8")
    tex._inUse = true
    pool[#pool + 1] = tex
    return tex
end

-- Release all textures in the pool (hide and mark free).
local function releaseAllTextures(pool)
    for index = 1, #pool do
        pool[index]._inUse = false
        pool[index]:Hide()
    end
end

-- Tooltip hitbox pool: acquire a hidden button from the pool or create a new one.
local function acquireHitbox(pool, parent)
    for index = 1, #pool do
        local btn = pool[index]
        if not btn._inUse then
            btn._inUse = true
            btn:SetParent(parent)
            btn:ClearAllPoints()
            btn:Show()
            return btn
        end
    end
    local btn = CreateFrame("Button", nil, parent)
    btn:EnableMouse(true)
    btn:RegisterForClicks("AnyUp")
    btn:SetScript("OnEnter", function(self)
        if self._tooltipLines and #self._tooltipLines > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine("Timeline Events", 1, 1, 1)
            for _, line in ipairs(self._tooltipLines) do
                GameTooltip:AddLine(line.text, line.r, line.g, line.b, true)
            end
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    btn._inUse = true
    pool[#pool + 1] = btn
    return btn
end

local function releaseAllHitboxes(pool)
    for index = 1, #pool do
        pool[index]._inUse = false
        pool[index]._tooltipLines = nil
        pool[index]:Hide()
    end
end

-- Downsample an event list to at most maxCount entries using uniform stride.
local function downsampleEvents(events, maxCount)
    if #events <= maxCount then
        return events
    end
    local sampled = {}
    local stride = #events / maxCount
    for i = 1, maxCount do
        local idx = math.floor((i - 1) * stride) + 1
        sampled[#sampled + 1] = events[idx]
    end
    return sampled
end

-- T022: Returns display state for the damage total of a session.
-- Returns { value = string, style = "normal"|"estimated"|"failed", reason = string|nil }
local function GetDamageDisplayState(session)
    local importedTotals = session and session.importedTotals or {}
    local totalAuthority = importedTotals.totalAuthority
    local damageDone     = session and session.totals and session.totals.damageDone or 0
    local formattedDamage = ns.Helpers.FormatNumber(damageDone)

    if totalAuthority == "authoritative" then
        return { value = formattedDamage, style = "normal", reason = nil }
    end

    if totalAuthority == "estimated" then
        return { value = "~" .. formattedDamage, style = "estimated", reason = nil }
    end

    if totalAuthority == "failed" then
        local diag = importedTotals.importDiagnostics or {}
        return { value = "—", style = "failed", reason = diag.failureReason or "Damage import failed" }
    end

    -- nil authority with zero damage and real combat signals → failed display
    if (totalAuthority == nil or totalAuthority == false) and damageDone == 0 then
        local ctx = session and session.context
        local hasRealSignals = session and (
            (session.primaryOpponent ~= nil)
            or (session.duration or 0) >= 5
            or ctx == "arena"
            or ctx == "battleground"
            or ctx == "duel"
        )
        if hasRealSignals then
            local diag = importedTotals.importDiagnostics or {}
            return { value = "—", style = "failed", reason = diag.failureReason or "Damage import failed" }
        end
    end

    return { value = formattedDamage, style = "normal", reason = nil }
end

local function findWindowByType(session, windowType)
    for _, windowRecord in ipairs(session.windows or {}) do
        if windowRecord.windowType == windowType then
            return windowRecord
        end
    end
    return nil
end

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

local function formatSpellList(spellIds)
    local names = {}
    for _, spellId in ipairs(spellIds or {}) do
        local spellInfo = ns.ApiCompat.GetSpellInfo(spellId) or {}
        names[#names + 1] = spellInfo.name or tostring(spellId)
    end
    if #names == 0 then
        return "--"
    end
    return table.concat(names, ", ")
end

local function buildSpellRows(session, limit)
    local rows = {}
    local totalOutput = math.max((session.totals.damageDone or 0) + (session.totals.healingDone or 0), 1)

    for spellId, aggregate in pairs(session.spells or {}) do
        local amount = (aggregate.totalDamage or 0) + (aggregate.totalHealing or 0)
        if amount > 0 or (aggregate.castCount or 0) > 0 then
            local spellInfo = ns.ApiCompat.GetSpellInfo(spellId) or {}
            rows[#rows + 1] = {
                spellId = spellId,
                name = aggregate.name or spellInfo.name or (spellId == 0 and "Environmental") or string.format("Unknown Spell (%s)", tostring(spellId)),
                icon = aggregate.iconID or spellInfo.iconID,
                amount = amount,
                damage = aggregate.totalDamage or 0,
                healing = aggregate.totalHealing or 0,
                casts = aggregate.castCount or 0,
                hits = aggregate.hitCount or 0,
                share = amount / totalOutput,
            }
        end
    end

    table.sort(rows, function(left, right)
        return left.amount > right.amount
    end)

    while #rows > (limit or 8) do
        table.remove(rows)
    end

    return rows
end

local function buildOverviewText(session)
    local identity = session.identity or {}
    local importInfo = session.import or {}
    local openerFingerprint = session.openerFingerprint or {}
    local snapshot = session.playerSnapshot or {}
    local opponent = ns.Helpers.ResolveOpponentName(session, "Unknown Opponent")
    local contextLabel = prettifyToken(session.context)
    if session.subcontext then
        contextLabel = string.format("%s • %s", contextLabel, prettifyToken(session.subcontext))
    end

    return table.concat({
        string.format(
            "Opponent: %s  |  Context: %s  |  Result: %s",
            opponent,
            contextLabel,
            prettifyToken(session.result)
        ),
        string.format(
            "Damage Read: %s via %s  |  Data: %s  |  Identity Confidence: %s%%  |  Import Confidence: %s%%",
            formatDisplayLabel(session.analysisConfidence),
            formatDisplayLabel(session.finalDamageSource),
            session.dataConfidence and formatDisplayLabel(session.dataConfidence) or formatDisplayLabel(session.analysisConfidence),
            tostring(identity.confidence or 0),
            tostring(importInfo.confidence or 0)
        ),
        string.format(
            "Snapshot: ilvl %s  |  Mastery %s  |  Vers %s dealt / %s DR  |  Build %s",
            snapshot.equippedItemLevel and string.format("%.1f", snapshot.equippedItemLevel) or "--",
            snapshot.masteryEffect and string.format("%.1f%%", snapshot.masteryEffect) or "--",
            snapshot.versatilityDamageDone and string.format("%.1f%%", snapshot.versatilityDamageDone) or "--",
            snapshot.versatilityDamageTaken and string.format("%.1f%%", snapshot.versatilityDamageTaken) or "--",
            tostring(snapshot.buildHash or "unknown")
        ),
        string.format(
            "Opener: %d casts  |  First offensive %s  |  First defensive %s%s",
            openerFingerprint.openerCastCount or 0,
            -- Prefer engagement-relative ("3.2s after gate open"); fall back to
            -- absolute offset for sessions recorded before this fix.
            (openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt)
                and string.format("%.1fs", openerFingerprint.firstMajorOffensiveRelative or openerFingerprint.firstMajorOffensiveAt)
                or "--",
            (openerFingerprint.firstMajorDefensiveRelative or openerFingerprint.firstMajorDefensiveAt)
                and string.format("%.1fs", openerFingerprint.firstMajorDefensiveRelative or openerFingerprint.firstMajorDefensiveAt)
                or "--",
            (openerFingerprint.engagementAt and openerFingerprint.engagementAt > 0.5)
                and string.format("  |  Gate +%.1fs", openerFingerprint.engagementAt) or ""
        ),
        string.format(
            "Opener Spells: %s",
            formatSpellList(openerFingerprint.openerSpellIds)
        ),
        string.format(
            "Cooldowns Committed: %s",
            formatSpellList(openerFingerprint.openerCooldownSpellIds)
        ),
    }, "\n")
end

local function buildRawEventSection(session, filteredRawEvents, rawPage, actorFilter, spellFilter, eventTypeFilter, windowFilter)
    local totalPages = math.max(1, math.ceil(#filteredRawEvents / Constants.DETAIL_RAW_PAGE_SIZE))
    local startIndex = (rawPage - 1) * Constants.DETAIL_RAW_PAGE_SIZE + 1
    local endIndex = math.min(startIndex + Constants.DETAIL_RAW_PAGE_SIZE - 1, #filteredRawEvents)
    local rawLines = {}

    for index = startIndex, endIndex do
        local eventRecord = filteredRawEvents[index]
        local spellName = "--"
        if eventRecord.spellId and eventRecord.spellId > 0 then
            local spellInfo = ns.ApiCompat.GetSpellInfo(eventRecord.spellId) or {}
            spellName = spellInfo.name or tostring(eventRecord.spellId)
        end

        rawLines[#rawLines + 1] = string.format(
            "%6.2f  %-10s  %-18s  amount=%-10s  source=%s  dest=%s",
            eventRecord.timestampOffset or 0,
            tostring(eventRecord.eventType or "other"),
            spellName,
            tostring(eventRecord.amount or "-"),
            tostring(eventRecord.sourceName or eventRecord.sourceGuid or "-"),
            tostring(eventRecord.destName or eventRecord.destGuid or "-")
        )
    end

    local rawEventSection = (#rawLines > 0 and table.concat(rawLines, "\n")) or "No raw events match the current filters."
    if #(session.rawEvents or {}) == 0 and session.metrics and session.metrics.limitedBySource then
        rawEventSection = "Raw event timeline is unavailable in Midnight-safe mode. Spell totals above were imported from Blizzard's post-combat Damage Meter."
    end

    local filterLine = string.format(
        "Page %d / %d  |  Filters: actor=%s  spell=%s  event=%s  window=%s",
        rawPage,
        totalPages,
        actorFilter ~= "" and actorFilter or "--",
        spellFilter ~= "" and spellFilter or "--",
        eventTypeFilter ~= "" and eventTypeFilter or "--",
        windowFilter ~= "" and windowFilter or "--"
    )

    return filterLine, rawEventSection, totalPages
end

function CombatDetailView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Combat Detail", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Structured fight review with clean spell and timing sections. Raw combat lines remain available below for inspection.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.filterBar = CreateFrame("Frame", nil, self.frame)
    self.filterBar:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -14)
    self.filterBar:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -16, 0)
    self.filterBar:SetHeight(48)

    self.actorHolder, self.actorFilter = ns.Widgets.CreateLabeledEditBox(self.filterBar, "Actor", 104, 20)
    self.actorHolder:SetPoint("TOPLEFT", self.filterBar, "TOPLEFT", 0, 0)
    self.actorFilter:SetText("")

    self.spellHolder, self.spellFilter = ns.Widgets.CreateLabeledEditBox(self.filterBar, "Spell ID", 88, 20)
    self.spellHolder:SetPoint("LEFT", self.actorHolder, "RIGHT", 8, 0)
    self.spellFilter:SetText("")

    self.eventHolder, self.eventTypeFilter = ns.Widgets.CreateLabeledEditBox(self.filterBar, "Event", 88, 20)
    self.eventHolder:SetPoint("LEFT", self.spellHolder, "RIGHT", 8, 0)
    self.eventTypeFilter:SetText("")

    self.windowHolder, self.windowFilter = ns.Widgets.CreateLabeledEditBox(self.filterBar, "Window", 100, 20)
    self.windowHolder:SetPoint("LEFT", self.eventHolder, "RIGHT", 8, 0)
    self.windowFilter:SetText("")

    self.applyFiltersButton = ns.Widgets.CreateButton(self.filterBar, "Apply", 74, 22)
    self.applyFiltersButton:SetPoint("BOTTOMLEFT", self.windowHolder, "BOTTOMRIGHT", 16, -2)
    self.applyFiltersButton:SetScript("OnClick", function()
        self.rawPage = 1
        self:Refresh({ sessionId = self.sessionId })
    end)

    self.prevButton = ns.Widgets.CreateButton(self.filterBar, "Prev Raw", 96, 22)
    self.prevButton:SetPoint("LEFT", self.applyFiltersButton, "RIGHT", 8, 0)
    self.prevButton:SetScript("OnClick", function()
        self.rawPage = math.max(1, self.rawPage - 1)
        self:Refresh({ sessionId = self.sessionId })
    end)

    self.nextButton = ns.Widgets.CreateButton(self.filterBar, "Next Raw", 96, 22)
    self.nextButton:SetPoint("LEFT", self.prevButton, "RIGHT", 8, 0)
    self.nextButton:SetScript("OnClick", function()
        self.rawPage = self.rawPage + 1
        self:Refresh({ sessionId = self.sessionId })
    end)

    -- T067: Export Diagnostics button — conditionally visible based on import authority
    self.exportDiagButton = ns.Widgets.CreateButton(self.filterBar, "Export Diag", 100, 22)
    self.exportDiagButton:SetPoint("LEFT", self.nextButton, "RIGHT", 8, 0)
    self.exportDiagButton:Hide()
    self.exportDiagButton:SetScript("OnClick", function()
        if not self.exportDiagModal then return end
        local serializer = ns.Addon:GetModule("ExportSerializer")
        local session = self.exportDiagModal.currentSession
        if serializer and session then
            local text = serializer.ExportDiagnosticSession(session)
            self.exportDiagModal.editBox:SetText(text or "")
            self.exportDiagModal.editBox:SetCursorPosition(0)
            self.exportDiagModal:Show()
        end
    end)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 368)
    self.shell:SetPoint("TOPLEFT", self.filterBar, "BOTTOMLEFT", 0, -10)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(Theme.textMuted))
    self.emptyState:SetText("No combat session selected.")

    -- T024: Degraded-session banner — shown when totalAuthority == "failed".
    self.degradedBanner = CreateFrame("Frame", nil, self.canvas)
    self.degradedBanner:SetHeight(22)
    self.degradedBanner:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.degradedBanner:SetPoint("TOPRIGHT", self.canvas, "TOPRIGHT", 0, 0)
    self.degradedBannerBg = self.degradedBanner:CreateTexture(nil, "BACKGROUND")
    self.degradedBannerBg:SetAllPoints()
    self.degradedBannerBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.degradedBannerBg:SetVertexColor(0.8, 0.5, 0.0, 0.25)
    self.degradedBannerText = self.degradedBanner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.degradedBannerText:SetPoint("CENTER", self.degradedBanner, "CENTER", 0, 0)
    self.degradedBannerText:SetTextColor(1.0, 0.75, 0.0, 1.0)
    self.degradedBannerText:SetText("\226\154\160 Damage import failed \226\128\148 some analytics may be inaccurate.")
    self.degradedBanner:Hide()

    self.metricCards = {}
    for index = 1, 4 do
        local card = ns.Widgets.CreateMetricCard(self.canvas, 370, 92)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        elseif index == 2 then
            card:SetPoint("TOPLEFT", self.metricCards[1], "TOPRIGHT", 10, 0)
        elseif index == 3 then
            card:SetPoint("TOPLEFT", self.metricCards[1], "BOTTOMLEFT", 0, -10)
        else
            card:SetPoint("TOPLEFT", self.metricCards[2], "BOTTOMLEFT", 0, -10)
        end
        self.metricCards[index] = card
    end

    self.overviewTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Fight Story", "TOPLEFT", self.metricCards[3], "BOTTOMLEFT", 0, -22)
    self.overviewCaption = ns.Widgets.CreateCaption(self.canvas, "The important metadata, opener timings, and capture quality in one readable block.", "TOPLEFT", self.overviewTitle, "BOTTOMLEFT", 0, -4)
    self.overviewPanel = ns.Widgets.CreateSurface(self.canvas, 750, 136, Theme.panelAlt, Theme.border)
    self.overviewPanel:SetPoint("TOPLEFT", self.overviewCaption, "BOTTOMLEFT", 0, -12)
    self.overviewPanel.header = self.overviewPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.overviewPanel.header:SetPoint("TOPLEFT", self.overviewPanel, "TOPLEFT", 12, -10)
    self.overviewPanel.header:SetTextColor(unpack(Theme.text))
    self.overviewPanel.header:SetText("Session Snapshot")
    self.overviewPanel.body = self.overviewPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.overviewPanel.body:SetPoint("TOPLEFT", self.overviewPanel.header, "BOTTOMLEFT", 0, -8)
    self.overviewPanel.body:SetPoint("RIGHT", self.overviewPanel, "RIGHT", -12, 0)
    self.overviewPanel.body:SetJustifyH("LEFT")
    self.overviewPanel.body:SetJustifyV("TOP")
    self.overviewPanel.body:SetSpacing(4)
    self.overviewPanel.body:SetTextColor(unpack(Theme.textMuted))

    self.scoreTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Score Profile", "TOPLEFT", self.overviewPanel, "BOTTOMLEFT", 0, -22)
    self.scoreCaption = ns.Widgets.CreateCaption(self.canvas, "These bars keep the combat review visual instead of making you parse a paragraph of numbers.", "TOPLEFT", self.scoreTitle, "BOTTOMLEFT", 0, -4)

    self.metricBars = {}
    for index = 1, 5 do
        local row = ns.Widgets.CreateMetricBar(self.canvas, 750, 60)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.scoreCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.metricBars[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.metricBars[index] = row
    end

    self.spellsTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Spell Breakdown", "TOPLEFT", self.metricBars[#self.metricBars], "BOTTOMLEFT", 0, -22)
    self.spellsCaption = ns.Widgets.CreateCaption(self.canvas, "Top contributors are rendered as proper spell rows so you can read them quickly.", "TOPLEFT", self.spellsTitle, "BOTTOMLEFT", 0, -4)

    self.spellRows = {}
    for index = 1, 8 do
        local row = ns.Widgets.CreateSpellRow(self.canvas, 750, 48)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.spellsCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.spellRows[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.spellRows[index] = row
    end

    -- Timeline Replay section
    self.timelineTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Timeline Replay", "TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    self.timelineCaption = ns.Widgets.CreateCaption(self.canvas, "Graphical event timeline. Damage dealt rises above center, damage taken drops below. CC windows and death markers are overlaid.", "TOPLEFT", self.timelineTitle, "BOTTOMLEFT", 0, -4)

    self.timelineContainer = ns.Widgets.CreateSurface(self.canvas, 750, TIMELINE_HEIGHT, Theme.panel, Theme.border)
    self.timelineContainer:SetPoint("TOPLEFT", self.timelineCaption, "BOTTOMLEFT", 0, -12)

    -- Center line divider
    self.timelineCenterLine = self.timelineContainer:CreateTexture(nil, "BACKGROUND", nil, 1)
    self.timelineCenterLine:SetTexture("Interface\\Buttons\\WHITE8x8")
    self.timelineCenterLine:SetPoint("LEFT", self.timelineContainer, "LEFT", TIMELINE_MARGIN_LEFT, 0)
    self.timelineCenterLine:SetPoint("RIGHT", self.timelineContainer, "RIGHT", -TIMELINE_MARGIN_RIGHT, 0)
    self.timelineCenterLine:SetHeight(1)
    self.timelineCenterLine:SetVertexColor(unpack(TIMELINE_COLORS.centerLine))

    -- Time axis labels
    self.timelineStartLabel = self.timelineContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.timelineStartLabel:SetPoint("BOTTOMLEFT", self.timelineContainer, "BOTTOMLEFT", TIMELINE_MARGIN_LEFT, 2)
    self.timelineStartLabel:SetTextColor(unpack(Theme.textMuted))
    self.timelineStartLabel:SetText("0s")

    self.timelineEndLabel = self.timelineContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.timelineEndLabel:SetPoint("BOTTOMRIGHT", self.timelineContainer, "BOTTOMRIGHT", -TIMELINE_MARGIN_RIGHT, 2)
    self.timelineEndLabel:SetTextColor(unpack(Theme.textMuted))
    self.timelineEndLabel:SetText("0s")

    self.timelineEmptyLabel = self.timelineContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.timelineEmptyLabel:SetPoint("CENTER", self.timelineContainer, "CENTER", 0, 0)
    self.timelineEmptyLabel:SetTextColor(unpack(Theme.textMuted))
    self.timelineEmptyLabel:SetText("No raw events recorded for this session.")
    self.timelineEmptyLabel:Hide()

    -- Legend row beneath the timeline
    self.timelineLegend = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.timelineLegend:SetPoint("TOPLEFT", self.timelineContainer, "BOTTOMLEFT", 0, -6)
    self.timelineLegend:SetTextColor(unpack(Theme.textMuted))
    self.timelineLegend:SetText("Blue = Damage Dealt  |  Red = Damage Taken  |  Green = Healing  |  Amber = CC Window  |  Red Line = Death")

    -- Texture and hitbox pools for timeline
    self.timelineTexturePool = self.timelineTexturePool or {}
    self.timelineHitboxPool = self.timelineHitboxPool or {}

    -- Multi-lane timeline section (from session.timelineEvents).
    self.multiLaneTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Multi-Lane Timeline", "TOPLEFT", self.timelineLegend, "BOTTOMLEFT", 0, -22)
    self.multiLaneCaption = ns.Widgets.CreateCaption(self.canvas, "Each lane shows a different event type positioned along the fight duration.", "TOPLEFT", self.multiLaneTitle, "BOTTOMLEFT", 0, -4)
    -- Stable anchor for dynamically created lane widgets. Lanes are recreated in Refresh.
    self.multiLaneContainer = CreateFrame("Frame", nil, self.canvas)
    self.multiLaneContainer:SetPoint("TOPLEFT", self.multiLaneCaption, "BOTTOMLEFT", 0, -8)
    self.multiLaneContainer:SetSize(750, 10) -- height adjusted dynamically
    self.multiLaneTitle:Hide()
    self.multiLaneCaption:Hide()
    self.multiLaneContainer:Hide()
    self.multiLaneWidgets = {}

    self.multiLaneFallback = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.multiLaneFallback:SetPoint("TOPLEFT", self.multiLaneCaption, "BOTTOMLEFT", 0, -8)
    self.multiLaneFallback:SetTextColor(unpack(Theme.textMuted))
    self.multiLaneFallback:SetText("Limited timeline data available for this session (legacy or restricted capture).")
    self.multiLaneFallback:Hide()

    -- T096: Trade Ledger panel
    local TradeLedgerView = ns.Addon:GetModule("TradeLedgerView")
    if TradeLedgerView then
        TradeLedgerView:Build(self.canvas)
        self.tradeLedgerView = TradeLedgerView
    end

    -- CC Received section
    self.ccTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Crowd Control Received", "TOPLEFT", self.multiLaneContainer, "BOTTOMLEFT", 0, -22)
    self.ccCaption = ns.Widgets.CreateCaption(self.canvas, "CC events that landed on you during this session, with total uptime.", "TOPLEFT", self.ccTitle, "BOTTOMLEFT", 0, -4)
    self.ccSummary = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.ccSummary:SetPoint("TOPLEFT", self.ccCaption, "BOTTOMLEFT", 0, -10)
    self.ccSummary:SetTextColor(unpack(Theme.textMuted))
    self.ccRows = {}
    for index = 1, 8 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.ccSummary, "BOTTOMLEFT", 0, -8)
        else
            row:SetPoint("TOPLEFT", self.ccRows[index - 1], "BOTTOMLEFT", 0, -4)
        end
        row:SetJustifyH("LEFT")
        row:SetTextColor(unpack(Theme.text))
        self.ccRows[index] = row
    end

    -- Defensive Timing section
    local ccLastAnchor = self.ccRows[#self.ccRows]
    self.defTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Defensive Timing", "TOPLEFT", ccLastAnchor, "BOTTOMLEFT", 0, -22)
    self.defCaption = ns.Widgets.CreateCaption(self.canvas, "How quickly defensive cooldowns were used relative to incoming crowd control.", "TOPLEFT", self.defTitle, "BOTTOMLEFT", 0, -4)
    self.defRows = {}
    for index = 1, 6 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.defCaption, "BOTTOMLEFT", 0, -10)
        else
            row:SetPoint("TOPLEFT", self.defRows[index - 1], "BOTTOMLEFT", 0, -4)
        end
        row:SetJustifyH("LEFT")
        row:SetTextColor(unpack(Theme.text))
        self.defRows[index] = row
    end

    -- Death Analysis section
    local defLastAnchor = self.defRows[#self.defRows]
    self.deathTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Death Analysis", "TOPLEFT", defLastAnchor, "BOTTOMLEFT", 0, -22)
    self.deathCaption = ns.Widgets.CreateCaption(self.canvas, "Breakdown of each death: who killed you, the burst window, and the kill chain.", "TOPLEFT", self.deathTitle, "BOTTOMLEFT", 0, -4)
    self.deathFrames = {}
    for index = 1, 4 do
        local row = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if index == 1 then
            row:SetPoint("TOPLEFT", self.deathCaption, "BOTTOMLEFT", 0, -10)
        else
            row:SetPoint("TOPLEFT", self.deathFrames[index - 1], "BOTTOMLEFT", 0, -6)
        end
        row:SetJustifyH("LEFT")
        row:SetWidth(740)
        row:SetWordWrap(true)
        row:SetTextColor(unpack(Theme.text))
        self.deathFrames[index] = row
    end

    -- Raw Timeline section (text dump), now anchored below the death analysis section
    local deathLastAnchor = self.deathFrames[#self.deathFrames]
    self.rawTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Raw Timeline", "TOPLEFT", deathLastAnchor, "BOTTOMLEFT", 0, -22)
    self.rawCaption = ns.Widgets.CreateCaption(self.canvas, "Filtered raw events stay available here, but they are now the support layer instead of the whole screen.", "TOPLEFT", self.rawTitle, "BOTTOMLEFT", 0, -4)
    self.rawMeta = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.rawMeta:SetPoint("TOPLEFT", self.rawCaption, "BOTTOMLEFT", 0, -10)
    self.rawMeta:SetTextColor(unpack(Theme.textMuted))

    self.rawShell, self.rawContent, self.rawText = ns.Widgets.CreateBodyText(self.canvas, 750, 210)
    self.rawShell:SetPoint("TOPLEFT", self.rawMeta, "BOTTOMLEFT", 0, -8)

    ns.Widgets.SetCanvasHeight(self.canvas, 2240)

    -- T068: Export Diagnostics modal — read-only EditBox with Select All / Close
    local diagModal = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    diagModal:SetSize(640, 480)
    diagModal:SetPoint("CENTER", UIParent, "CENTER")
    diagModal:SetFrameStrata("DIALOG")
    diagModal:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    diagModal:SetBackdropColor(0, 0, 0, 0.9)
    diagModal:Hide()
    diagModal:EnableMouse(true)
    diagModal:SetMovable(true)
    diagModal:RegisterForDrag("LeftButton")
    diagModal:SetScript("OnDragStart", function(f) f:StartMoving() end)
    diagModal:SetScript("OnDragStop",  function(f) f:StopMovingOrSizing() end)
    diagModal.currentSession = nil

    local diagTitleFs = diagModal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    diagTitleFs:SetPoint("TOPLEFT", diagModal, "TOPLEFT", 16, -16)
    diagTitleFs:SetText("Export Diagnostics")
    diagTitleFs:SetTextColor(1, 0.82, 0)

    local diagScrollFrame = CreateFrame("ScrollFrame", nil, diagModal, "UIPanelScrollFrameTemplate")
    diagScrollFrame:SetPoint("TOPLEFT",     diagModal, "TOPLEFT",     16,  -44)
    diagScrollFrame:SetPoint("BOTTOMRIGHT", diagModal, "BOTTOMRIGHT", -36,  48)

    local diagEditBox = CreateFrame("EditBox", nil, diagScrollFrame)
    diagEditBox:SetMultiLine(true)
    diagEditBox:SetFontObject("GameFontHighlightSmall")
    diagEditBox:SetWidth(576)
    diagEditBox:SetAutoFocus(false)
    diagEditBox:SetMaxLetters(0)
    diagEditBox:EnableMouse(true)
    diagEditBox:SetScript("OnEscapePressed", function() diagModal:Hide() end)
    diagScrollFrame:SetScrollChild(diagEditBox)

    diagModal.editBox = diagEditBox

    local diagSelectAllBtn = ns.Widgets.CreateButton(diagModal, "Select All", 100, 22)
    diagSelectAllBtn:SetPoint("BOTTOMLEFT", diagModal, "BOTTOMLEFT", 16, 16)
    diagSelectAllBtn:SetScript("OnClick", function()
        diagEditBox:SetFocus()
        diagEditBox:HighlightText()
    end)

    local diagCloseBtn = ns.Widgets.CreateButton(diagModal, "Close", 80, 22)
    diagCloseBtn:SetPoint("BOTTOMRIGHT", diagModal, "BOTTOMRIGHT", -16, 16)
    diagCloseBtn:SetScript("OnClick", function() diagModal:Hide() end)

    self.exportDiagModal = diagModal

    return self.frame
end

-- Render the graphical timeline for a given session.
function CombatDetailView:BuildTimeline(session)
    -- Release all pooled resources
    releaseAllTextures(self.timelineTexturePool)
    releaseAllHitboxes(self.timelineHitboxPool)

    local rawEvents = session.rawEvents or {}
    local duration = math.max(session.duration or 0, 0.1)

    -- If no raw events, show empty label and bail
    if #rawEvents == 0 then
        self.timelineEmptyLabel:Show()
        self.timelineCenterLine:Hide()
        self.timelineStartLabel:Hide()
        self.timelineEndLabel:Hide()
        self.timelineLegend:Hide()
        return
    end

    self.timelineEmptyLabel:Hide()
    self.timelineCenterLine:Show()
    self.timelineStartLabel:Show()
    self.timelineEndLabel:Show()
    self.timelineLegend:Show()

    self.timelineStartLabel:SetText("0s")
    self.timelineEndLabel:SetText(string.format("%.0fs", duration))

    local containerWidth = self.timelineContainer:GetWidth() or 750
    local drawWidth = containerWidth - TIMELINE_MARGIN_LEFT - TIMELINE_MARGIN_RIGHT
    if drawWidth < 10 then
        drawWidth = 750 - TIMELINE_MARGIN_LEFT - TIMELINE_MARGIN_RIGHT
    end
    local halfHeight = (TIMELINE_HEIGHT - 14) / 2  -- leave room for axis labels at bottom

    -- Classify raw events and find maximum amounts for scaling
    local damageDealtEvents = {}
    local damageTakenEvents = {}
    local healingEvents = {}
    local maxDamageDealt = 1
    local maxDamageTaken = 1
    local maxHealing = 1

    for _, evt in ipairs(rawEvents) do
        local evtType = evt.eventType
        local amount = evt.amount or 0
        if amount > 0 then
            if evtType == "damage" and evt.sourceMine then
                damageDealtEvents[#damageDealtEvents + 1] = evt
                if amount > maxDamageDealt then
                    maxDamageDealt = amount
                end
            elseif evtType == "damage" and evt.destMine then
                damageTakenEvents[#damageTakenEvents + 1] = evt
                if amount > maxDamageTaken then
                    maxDamageTaken = amount
                end
            elseif evtType == "healing" and evt.sourceMine then
                healingEvents[#healingEvents + 1] = evt
                if amount > maxHealing then
                    maxHealing = amount
                end
            end
        end
    end

    -- Downsample if too many events across all categories combined
    local totalEvents = #damageDealtEvents + #damageTakenEvents + #healingEvents
    if totalEvents > TIMELINE_MAX_EVENTS then
        local ratio = TIMELINE_MAX_EVENTS / totalEvents
        local dealtCap = math.max(1, math.floor(#damageDealtEvents * ratio))
        local takenCap = math.max(1, math.floor(#damageTakenEvents * ratio))
        local healCap = math.max(1, math.floor(#healingEvents * ratio))
        damageDealtEvents = downsampleEvents(damageDealtEvents, dealtCap)
        damageTakenEvents = downsampleEvents(damageTakenEvents, takenCap)
        healingEvents = downsampleEvents(healingEvents, healCap)
    end

    local container = self.timelineContainer

    -- Helper to map timestamp offset to x pixel
    local function timeToX(offset)
        return TIMELINE_MARGIN_LEFT + (offset / duration) * drawWidth
    end

    -- Helper to build tooltip clusters.
    -- We divide the timeline into horizontal buckets and group events per bucket.
    local BUCKET_WIDTH = 12
    local bucketCount = math.max(1, math.floor(drawWidth / BUCKET_WIDTH))
    local buckets = {}
    for i = 1, bucketCount do
        buckets[i] = {}
    end

    local function addToBucket(evt, label, color)
        local offset = evt.timestampOffset or 0
        local bucketIdx = math.floor((offset / duration) * (bucketCount - 1)) + 1
        bucketIdx = math.max(1, math.min(bucketIdx, bucketCount))
        buckets[bucketIdx][#buckets[bucketIdx] + 1] = {
            text = label,
            r = color[1],
            g = color[2],
            b = color[3],
        }
    end

    -- 1) Render CC windows (below everything, BACKGROUND layer)
    local ccTimeline = session.ccTimeline or {}
    for _, cc in ipairs(ccTimeline) do
        local startOffset = cc.startOffset or 0
        local ccDuration = cc.duration or 0
        if ccDuration > 0 then
            local x1 = timeToX(startOffset)
            local x2 = timeToX(math.min(startOffset + ccDuration, duration))
            local ccWidth = math.max(2, x2 - x1)

            local tex = acquireTexture(self.timelineTexturePool, container)
            tex:SetDrawLayer("BACKGROUND", 2)
            tex:SetPoint("TOPLEFT", container, "TOPLEFT", x1, -2)
            tex:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", x1, 14)
            tex:SetWidth(ccWidth)
            tex:SetVertexColor(unpack(TIMELINE_COLORS.ccWindow))

            local spellInfo = cc.spellId and ns.ApiCompat.GetSpellInfo(cc.spellId) or {}
            local spellName = spellInfo.name or tostring(cc.spellId or "CC")
            -- Add to multiple buckets spanning the CC window
            local bucketStart = math.floor((startOffset / duration) * (bucketCount - 1)) + 1
            local bucketEnd = math.floor((math.min(startOffset + ccDuration, duration) / duration) * (bucketCount - 1)) + 1
            bucketStart = math.max(1, math.min(bucketStart, bucketCount))
            bucketEnd = math.max(1, math.min(bucketEnd, bucketCount))
            for bi = bucketStart, bucketEnd do
                local existing = false
                for _, line in ipairs(buckets[bi]) do
                    if line.text == string.format("CC: %s (%.1fs)", spellName, ccDuration) then
                        existing = true
                        break
                    end
                end
                if not existing then
                    buckets[bi][#buckets[bi] + 1] = {
                        text = string.format("CC: %s (%.1fs)", spellName, ccDuration),
                        r = TIMELINE_COLORS.ccWindow[1],
                        g = TIMELINE_COLORS.ccWindow[2],
                        b = TIMELINE_COLORS.ccWindow[3],
                    }
                end
            end
        end
    end

    -- 2) Render damage dealt bars (upward from center line)
    for _, evt in ipairs(damageDealtEvents) do
        local offset = evt.timestampOffset or 0
        local amount = evt.amount or 0
        local barHeight = math.max(1, (amount / maxDamageDealt) * halfHeight)
        local x = timeToX(offset)

        local tex = acquireTexture(self.timelineTexturePool, container)
        tex:SetDrawLayer("ARTWORK", 1)
        tex:SetWidth(TIMELINE_BAR_WIDTH)
        tex:SetHeight(barHeight)
        tex:SetPoint("BOTTOMLEFT", container, "LEFT", x, 0)
        tex:SetVertexColor(unpack(TIMELINE_COLORS.damageDealt))

        local spellInfo = evt.spellId and ns.ApiCompat.GetSpellInfo(evt.spellId) or {}
        local spellName = spellInfo.name or tostring(evt.spellId or "Melee")
        addToBucket(evt, string.format("Dealt: %s %s%s", spellName, ns.Helpers.FormatNumber(amount), evt.critical and " (crit)" or ""), TIMELINE_COLORS.damageDealt)
    end

    -- 3) Render damage taken bars (downward from center line)
    for _, evt in ipairs(damageTakenEvents) do
        local offset = evt.timestampOffset or 0
        local amount = evt.amount or 0
        local barHeight = math.max(1, (amount / maxDamageTaken) * halfHeight)
        local x = timeToX(offset)

        local tex = acquireTexture(self.timelineTexturePool, container)
        tex:SetDrawLayer("ARTWORK", 1)
        tex:SetWidth(TIMELINE_BAR_WIDTH)
        tex:SetHeight(barHeight)
        tex:SetPoint("TOPLEFT", container, "LEFT", x, 0)
        tex:SetVertexColor(unpack(TIMELINE_COLORS.damageTaken))

        local spellInfo = evt.spellId and ns.ApiCompat.GetSpellInfo(evt.spellId) or {}
        local spellName = spellInfo.name or tostring(evt.spellId or "Melee")
        addToBucket(evt, string.format("Taken: %s %s%s", spellName, ns.Helpers.FormatNumber(amount), evt.critical and " (crit)" or ""), TIMELINE_COLORS.damageTaken)
    end

    -- 4) Render healing bars (upward from center line, on top of damage dealt)
    for _, evt in ipairs(healingEvents) do
        local offset = evt.timestampOffset or 0
        local amount = evt.amount or 0
        local barHeight = math.max(1, (amount / maxHealing) * halfHeight * 0.8)
        local x = timeToX(offset)

        local tex = acquireTexture(self.timelineTexturePool, container)
        tex:SetDrawLayer("ARTWORK", 2)
        tex:SetWidth(TIMELINE_BAR_WIDTH)
        tex:SetHeight(barHeight)
        tex:SetPoint("BOTTOMLEFT", container, "LEFT", x, 0)
        tex:SetVertexColor(unpack(TIMELINE_COLORS.healing))

        local spellInfo = evt.spellId and ns.ApiCompat.GetSpellInfo(evt.spellId) or {}
        local spellName = spellInfo.name or tostring(evt.spellId or "Heal")
        addToBucket(evt, string.format("Heal: %s %s", spellName, ns.Helpers.FormatNumber(amount)), TIMELINE_COLORS.healing)
    end

    -- 5) Render death markers
    local deathCauses = session.deathCauses or {}
    local deathOffsets = {}

    -- Gather from deathCauses
    for _, cause in ipairs(deathCauses) do
        if cause.timestampOffset then
            deathOffsets[#deathOffsets + 1] = cause.timestampOffset
        end
    end

    -- Fallback: scan rawEvents for death events if deathCauses is empty
    if #deathOffsets == 0 then
        for _, evt in ipairs(rawEvents) do
            if evt.eventType == "death" and evt.destMine then
                deathOffsets[#deathOffsets + 1] = evt.timestampOffset or 0
            end
        end
    end

    for _, offset in ipairs(deathOffsets) do
        local x = timeToX(offset)
        local tex = acquireTexture(self.timelineTexturePool, container)
        tex:SetDrawLayer("OVERLAY", 1)
        tex:SetWidth(TIMELINE_DEATH_WIDTH)
        tex:SetPoint("TOPLEFT", container, "TOPLEFT", x, -2)
        tex:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", x, 14)
        tex:SetVertexColor(unpack(TIMELINE_COLORS.death))

        local bucketIdx = math.floor((offset / duration) * (bucketCount - 1)) + 1
        bucketIdx = math.max(1, math.min(bucketIdx, bucketCount))
        buckets[bucketIdx][#buckets[bucketIdx] + 1] = {
            text = string.format("DEATH at %.1fs", offset),
            r = TIMELINE_COLORS.death[1],
            g = TIMELINE_COLORS.death[2],
            b = TIMELINE_COLORS.death[3],
        }
    end

    -- 6) Create tooltip hitboxes for non-empty buckets
    for i = 1, bucketCount do
        if #buckets[i] > 0 then
            local hitbox = acquireHitbox(self.timelineHitboxPool, container)
            local bucketX = TIMELINE_MARGIN_LEFT + (i - 1) * BUCKET_WIDTH
            hitbox:SetPoint("TOPLEFT", container, "TOPLEFT", bucketX, -2)
            hitbox:SetSize(BUCKET_WIDTH, TIMELINE_HEIGHT - 14)
            hitbox:SetFrameLevel(container:GetFrameLevel() + 5)

            -- Cap tooltip lines to keep GameTooltip manageable
            local lines = buckets[i]
            if #lines > 8 then
                local capped = {}
                for li = 1, 7 do
                    capped[li] = lines[li]
                end
                capped[8] = { text = string.format("... and %d more events", #lines - 7), r = 0.6, g = 0.6, b = 0.6 }
                lines = capped
            end
            hitbox._tooltipLines = lines
        end
    end
end

function CombatDetailView:FilterRawEvents(session)
    local actorFilter = string.lower(ns.Helpers.Trim(self.actorFilter:GetText() or ""))
    local spellFilter = tonumber(self.spellFilter:GetText() or "")
    local eventTypeFilter = string.lower(ns.Helpers.Trim(self.eventTypeFilter:GetText() or ""))
    local windowFilter = string.lower(ns.Helpers.Trim(self.windowFilter:GetText() or ""))
    local selectedWindow = windowFilter ~= "" and findWindowByType(session, windowFilter) or nil

    local filtered = {}
    for _, rawEvent in ipairs(session.rawEvents or {}) do
        local include = true
        if actorFilter ~= "" then
            local source = string.lower(tostring(rawEvent.sourceGuid or ""))
            local dest = string.lower(tostring(rawEvent.destGuid or ""))
            include = string.find(source, actorFilter, 1, true) ~= nil or string.find(dest, actorFilter, 1, true) ~= nil
        end
        if include and spellFilter and rawEvent.spellId ~= spellFilter then
            include = false
        end
        if include and eventTypeFilter ~= "" and string.lower(tostring(rawEvent.eventType or "")) ~= eventTypeFilter then
            include = false
        end
        if include and selectedWindow then
            local offset = rawEvent.timestampOffset or 0
            include = offset >= selectedWindow.startTimeOffset and offset <= selectedWindow.endTimeOffset
        end
        if include then
            filtered[#filtered + 1] = rawEvent
        end
    end
    return filtered
end

function CombatDetailView:Refresh(payload)
    if payload and payload.sessionId then
        self.sessionId = payload.sessionId
        if ns.Addon.SetReviewedSession then
            ns.Addon:SetReviewedSession(payload.sessionId, "detail")
        end
    end

    local store = ns.Addon:GetModule("CombatStore")
    local session = self.sessionId and store:GetCombatById(self.sessionId) or store:GetLatestSession(store:GetCurrentCharacterKey())

    if not session then
        self.emptyState:Show()
        for _, collection in ipairs({ self.metricCards, self.metricBars, self.spellRows }) do
            for _, widget in ipairs(collection) do
                widget:Hide()
            end
        end
        self.overviewTitle:Hide()
        self.overviewCaption:Hide()
        self.overviewPanel:Hide()
        self.scoreTitle:Hide()
        self.scoreCaption:Hide()
        self.spellsTitle:Hide()
        self.spellsCaption:Hide()
        self.timelineTitle:Hide()
        self.timelineCaption:Hide()
        self.timelineContainer:Hide()
        self.timelineLegend:Hide()
        if self.multiLaneTitle then self.multiLaneTitle:Hide() end
        if self.multiLaneCaption then self.multiLaneCaption:Hide() end
        if self.multiLaneContainer then self.multiLaneContainer:Hide() end
        if self.multiLaneFallback then self.multiLaneFallback:Hide() end
        for _, lw in ipairs(self.multiLaneWidgets or {}) do lw:Hide() end
        if self.tradeLedgerView and self.tradeLedgerView.frame then self.tradeLedgerView.frame:Hide() end
        self.ccTitle:Hide()
        self.ccCaption:Hide()
        self.ccSummary:Hide()
        for _, row in ipairs(self.ccRows) do row:Hide() end
        self.defTitle:Hide()
        self.defCaption:Hide()
        for _, row in ipairs(self.defRows) do row:Hide() end
        self.deathTitle:Hide()
        self.deathCaption:Hide()
        for _, row in ipairs(self.deathFrames) do row:Hide() end
        self.rawTitle:Hide()
        self.rawCaption:Hide()
        self.rawMeta:Hide()
        self.rawShell:Hide()
        if self.exportDiagButton then self.exportDiagButton:Hide() end
        return
    end

    if self.lastRenderedSessionId ~= session.id and self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    end

    self.emptyState:Hide()
    self.sessionId = session.id
    self.lastRenderedSessionId = session.id

    -- T067: Export Diagnostics button visibility — show when import was non-authoritative or debug flag set
    if self.exportDiagModal then
        self.exportDiagModal.currentSession = session
    end
    local diagAuthority = session.importedTotals and session.importedTotals.totalAuthority
    if (diagAuthority and diagAuthority ~= "authoritative") or CA_DEBUG_EXPORT then
        self.exportDiagButton:Show()
    else
        self.exportDiagButton:Hide()
    end

    self.title:SetText(string.format("Combat Detail • %s", ns.Helpers.ResolveOpponentName(session, "Selected Fight")))
    self.caption:SetText(string.format(
        "%s fight review with visual sections for scores, spells, and opener timing. Character: %s.",
        prettifyToken(session.context),
        store:GetSessionCharacterLabel(session)
    ))

    self.overviewTitle:Show()
    self.overviewCaption:Show()
    self.overviewPanel:Show()
    self.scoreTitle:Show()
    self.scoreCaption:Show()
    self.spellsTitle:Show()
    self.spellsCaption:Show()
    self.timelineTitle:Show()
    self.timelineCaption:Show()
    self.timelineContainer:Show()
    self.timelineLegend:Show()
    self.rawTitle:Show()
    self.rawCaption:Show()
    self.rawMeta:Show()
    self.rawShell:Show()

    local opponent = ns.Helpers.ResolveOpponentName(session, "Unknown Opponent")
    local readQuality = formatDisplayLabel(session.analysisConfidence or "limited")
    local readSource = formatDisplayLabel(session.finalDamageSource or "damage_meter")
    -- Rich label from the data confidence pipeline (e.g. "Full Raw", "Enriched").
    local richQuality = session.dataConfidence
        and formatDisplayLabel(session.dataConfidence)
        or readQuality

    -- T024: Show/hide degraded-session banner based on import authority.
    -- When shown, shift metricCards[1] below the banner so it is not occluded.
    -- Cards 2-4 chain-anchor from card 1 and follow automatically.
    if self.degradedBanner then
        local importedTotals = session.importedTotals or {}
        if importedTotals.totalAuthority == "failed" then
            self.degradedBanner:Show()
            self.metricCards[1]:ClearAllPoints()
            self.metricCards[1]:SetPoint("TOPLEFT", self.degradedBanner, "BOTTOMLEFT", 0, -4)
        else
            self.degradedBanner:Hide()
            self.metricCards[1]:ClearAllPoints()
            self.metricCards[1]:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        end
    end

    -- T022/T023: Use GetDamageDisplayState to render the damage value correctly.
    local dmgState     = GetDamageDisplayState(session)
    local dmgDisplayValue = dmgState.value
    local dmgSubtext
    if dmgState.style == "failed" then
        dmgDisplayValue = "—"
        dmgSubtext = string.format("Damage unavailable — %s", dmgState.reason or "import failed")
    elseif dmgState.style == "estimated" then
        dmgSubtext = string.format("%s DPS (est.) over %s against %s.", ns.Helpers.FormatNumber(session.metrics.sustainedDps or 0), ns.Helpers.FormatDuration(session.duration or 0), opponent)
    else
        dmgSubtext = string.format("%s DPS over %s against %s.", ns.Helpers.FormatNumber(session.metrics.sustainedDps or 0), ns.Helpers.FormatDuration(session.duration or 0), opponent)
    end

    self.metricCards[1]:SetData(
        dmgDisplayValue,
        "Damage Done",
        dmgSubtext,
        dmgState.style == "failed" and Theme.warning or Theme.accent
    )
    self.metricCards[2]:SetData(
        string.format("%.1f", session.metrics.pressureScore or 0),
        "Pressure",
        string.format("Burst %.1f with opener damage %s.", session.metrics.burstScore or 0, ns.Helpers.FormatNumber(session.metrics.openerDamage or 0)),
        Theme.warning
    )
    self.metricCards[3]:SetData(
        string.format("%.1f", session.metrics.survivabilityScore or 0),
        "Survivability",
        string.format("%s taken, %s healing, %d deaths.", ns.Helpers.FormatNumber(session.totals.damageTaken or 0), ns.Helpers.FormatNumber(session.totals.healingDone or 0), session.survival and session.survival.deaths or 0),
        Theme.success
    )
    self.metricCards[4]:SetData(
        richQuality,
        "Read Quality",
        string.format("%s capture with %s resolution.", richQuality, readSource),
        session.analysisConfidence == "high" and Theme.success or Theme.warning
    )
    for _, card in ipairs(self.metricCards) do
        card:Show()
    end

    self.overviewPanel.body:SetText(buildOverviewText(session))

    self.metricBars[1]:SetData("Pressure Score", string.format("%.1f / 100", session.metrics.pressureScore or 0), "How much offensive threat the session carried.", (session.metrics.pressureScore or 0) / 100, Theme.accent)
    self.metricBars[2]:SetData("Burst Score", string.format("%.1f / 100", session.metrics.burstScore or 0), "Short-window kill pressure and go quality.", (session.metrics.burstScore or 0) / 100, Theme.warning)
    self.metricBars[3]:SetData("Survivability", string.format("%.1f / 100", session.metrics.survivabilityScore or 0), "Defensive trades, incoming damage, and self-stabilization.", (session.metrics.survivabilityScore or 0) / 100, Theme.success)
    self.metricBars[4]:SetData("Rotation Flow", string.format("%.1f / 100", session.metrics.rotationalConsistencyScore or 0), string.format("Idle time %.1fs across %d recorded casts.", session.idleTime or 0, session.openerFingerprint and session.openerFingerprint.openerCastCount or 0), (session.metrics.rotationalConsistencyScore or 0) / 100, Theme.accent)
    self.metricBars[5]:SetData("Proc Follow-Through", string.format("%.1f / 100", session.metrics.procConversionScore or 0), string.format("%d proc windows with %d casts inside them.", session.metrics.procWindowsObserved or 0, session.metrics.procWindowCastCount or 0), (session.metrics.procConversionScore or 0) / 100, Theme.warning)
    for _, bar in ipairs(self.metricBars) do
        bar:Show()
    end

    local spellRows = buildSpellRows(session, #self.spellRows)
    for index, row in ipairs(self.spellRows) do
        local spellRow = spellRows[index]
        if spellRow then
            row:SetData(
                spellRow.icon,
                spellRow.name,
                string.format(
                    "Damage %s  |  Healing %s  |  Casts %d  |  Hits %d",
                    ns.Helpers.FormatNumber(spellRow.damage),
                    ns.Helpers.FormatNumber(spellRow.healing),
                    spellRow.casts,
                    spellRow.hits
                ),
                ns.Helpers.FormatNumber(spellRow.amount),
                spellRow.share,
                Theme.accent
            )
        else
            row:Hide()
        end
    end

    -- Render graphical timeline
    self:BuildTimeline(session)

    -- Multi-lane timeline from session.timelineEvents.
    local LANE_COLORS = {
        player_cast   = { 0.35, 0.78, 0.90, 1.0 },
        visible_aura  = { 0.60, 0.82, 0.44, 1.0 },
        cc_received   = { 0.96, 0.74, 0.38, 1.0 },
        kill_window   = { 0.90, 0.30, 0.25, 1.0 },
        death         = { 1.0, 0.0, 0.0, 1.0 },
        match_state   = { 0.60, 0.69, 0.78, 1.0 },
    }
    local LANE_ORDER = { "player_cast", "visible_aura", "cc_received", "kill_window", "death", "match_state" }
    local LANE_LABELS = {
        player_cast  = "Player Casts",
        visible_aura = "Visible Auras",
        cc_received  = "CC Received",
        kill_window  = "Kill Windows",
        death        = "Deaths",
        match_state  = "Match State",
    }

    -- Hide previous lane widgets
    for _, laneWidget in ipairs(self.multiLaneWidgets or {}) do
        laneWidget:Hide()
    end
    self.multiLaneWidgets = {}

    local timelineEvents = session.timelineEvents or {}
    local duration = math.max(session.duration or 0, 0.1)

    if #timelineEvents > 0 then
        -- Group events by lane
        local laneGroups = {}
        for _, evt in ipairs(timelineEvents) do
            local lane = evt.lane or "unknown"
            if not laneGroups[lane] then
                laneGroups[lane] = {}
            end
            local laneEvts = laneGroups[lane]
            laneEvts[#laneEvts + 1] = {
                t = evt.offset or evt.timestampOffset or 0,
                color = LANE_COLORS[lane] or Theme.accent,
                duration = evt.duration,
                tooltip = evt.label or evt.spellName or lane,
            }
        end

        local laneCount = 0
        local laneHeight = 20
        local laneGap = 4
        local prevLaneWidget = nil

        for _, laneName in ipairs(LANE_ORDER) do
            local events = laneGroups[laneName]
            if events and #events > 0 then
                laneCount = laneCount + 1
                local laneWidget = ns.Widgets.CreateTimelineLane(
                    self.canvas, events, duration, 750, laneHeight
                )
                if prevLaneWidget then
                    laneWidget:SetPoint("TOPLEFT", prevLaneWidget, "BOTTOMLEFT", 0, -laneGap)
                else
                    laneWidget:SetPoint("TOPLEFT", self.multiLaneContainer, "TOPLEFT", 0, 0)
                end

                -- Add lane label on the left side
                local lbl = laneWidget:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lbl:SetPoint("LEFT", laneWidget, "LEFT", 4, 0)
                lbl:SetTextColor(unpack(Theme.text))
                lbl:SetText(LANE_LABELS[laneName] or laneName)

                laneWidget:Show()
                self.multiLaneWidgets[#self.multiLaneWidgets + 1] = laneWidget
                prevLaneWidget = laneWidget
            end
        end

        if laneCount > 0 then
            self.multiLaneTitle:Show()
            self.multiLaneCaption:Show()
            self.multiLaneContainer:Show()
            self.multiLaneFallback:Hide()
            local totalLaneHeight = laneCount * laneHeight + (laneCount - 1) * laneGap
            self.multiLaneContainer:SetHeight(totalLaneHeight)
        else
            self.multiLaneTitle:Hide()
            self.multiLaneCaption:Hide()
            self.multiLaneContainer:Hide()
            self.multiLaneFallback:Hide()
        end
    else
        -- Fallback for legacy sessions or restricted capture
        self.multiLaneTitle:Show()
        self.multiLaneCaption:Show()
        self.multiLaneContainer:Hide()
        local hasRawEvts = session.rawEvents and #session.rawEvents > 0
        if hasRawEvts then
            self.multiLaneFallback:SetText("Limited timeline data. Raw events are available below for inspection.")
        else
            self.multiLaneFallback:SetText("Limited timeline data available for this session (legacy or restricted capture).")
        end
        self.multiLaneFallback:Show()
        self.multiLaneContainer:SetHeight(10)
    end

    -- T096: Refresh trade ledger
    if self.tradeLedgerView then
        self.tradeLedgerView:Refresh(session)
    end

    -- CC Received section
    local ccReceived = session.ccReceived or {}
    if #ccReceived > 0 then
        self.ccTitle:Show()
        self.ccCaption:Show()
        self.ccSummary:Show()
        local ccUptime = session.metrics and session.metrics.ccUptimePct or 0
        local timeUnderCC = session.metrics and session.metrics.timeUnderCC or 0
        self.ccSummary:SetText(string.format(
            "Total CC uptime: %.1f%%  |  Time under CC: %s",
            ccUptime,
            ns.Helpers.FormatDuration(timeUnderCC)
        ))
        for index, row in ipairs(self.ccRows) do
            local entry = ccReceived[index]
            if entry then
                row:SetText(string.format(
                    "%s  —  %.1fs  —  from %s",
                    entry.spellName or "Unknown",
                    entry.duration or 0,
                    entry.sourceName or "Unknown"
                ))
                row:Show()
            else
                row:Hide()
            end
        end
    else
        self.ccTitle:Hide()
        self.ccCaption:Hide()
        self.ccSummary:Hide()
        for _, row in ipairs(self.ccRows) do row:Hide() end
    end

    -- Defensive Timing section
    local cdSequence = session.cdSequence or {}
    if #cdSequence > 0 then
        self.defTitle:Show()
        self.defCaption:Show()
        for index, row in ipairs(self.defRows) do
            local entry = cdSequence[index]
            if entry then
                local classification = entry.classification or "no_cc_context"
                local colorR, colorG, colorB
                if classification == "preemptive" then
                    colorR, colorG, colorB = unpack(Theme.success)
                elseif classification == "reactive_early" then
                    colorR, colorG, colorB = unpack(Theme.warning)
                elseif classification == "reactive_late" then
                    colorR, colorG, colorB = 0.90, 0.30, 0.25
                else
                    colorR, colorG, colorB = unpack(Theme.textMuted)
                end
                row:SetText(string.format(
                    "%s  —  %s  —  %.2fs lag",
                    entry.spellName or "Unknown",
                    prettifyToken(classification),
                    entry.lagSeconds or 0
                ))
                row:SetTextColor(colorR, colorG, colorB, 1.0)
                row:Show()
            else
                row:Hide()
            end
        end
    else
        self.defTitle:Hide()
        self.defCaption:Hide()
        for _, row in ipairs(self.defRows) do row:Hide() end
    end

    -- Death Analysis section
    local deathCauses = session.deathCauses or {}
    if #deathCauses > 0 then
        self.deathTitle:Show()
        self.deathCaption:Show()
        for index, frame in ipairs(self.deathFrames) do
            local cause = deathCauses[index]
            if cause then
                local sourceName = cause.sourceName or "Unknown"
                local burstWindow = cause.burstWindow or 0
                local totalBurst = cause.totalBurst or 0
                local recentDamage = cause.recentDamage or {}
                local chainParts = {}
                for _, dmg in ipairs(recentDamage) do
                    chainParts[#chainParts + 1] = dmg.spellName or "Unknown"
                end
                local chainText = #chainParts > 0
                    and table.concat(chainParts, " \226\134\146 ")
                    or "no spells recorded"
                local line = string.format(
                    "Killed by %s in %.1fs burst window. Kill chain: %s (total: %sk damage).",
                    sourceName,
                    burstWindow,
                    chainText,
                    ns.Helpers.FormatNumber(totalBurst)
                )
                if cause.wasCCed then
                    local ccName = cause.ccSpellName or "Unknown CC"
                    line = line .. string.format(
                        "  |cffee5544WARNING: You were CCed by %s during the kill window.|r",
                        ccName
                    )
                end
                frame:SetText(line)
                frame:SetTextColor(0.90, 0.30, 0.25, 1.0)
                frame:Show()
            else
                frame:Hide()
            end
        end
    else
        self.deathTitle:Hide()
        self.deathCaption:Hide()
        for _, frame in ipairs(self.deathFrames) do frame:Hide() end
    end

    -- Show raw events only if there are rawEvents
    local hasRawEvents = session.rawEvents and #session.rawEvents > 0
    if hasRawEvents then
        self.rawTitle:Show()
        self.rawCaption:Show()
        self.rawMeta:Show()
        self.rawShell:Show()
    else
        self.rawTitle:Hide()
        self.rawCaption:Hide()
        self.rawMeta:Hide()
        self.rawShell:Hide()
    end

    local filteredRawEvents = self:FilterRawEvents(session)
    local totalPages = math.max(1, math.ceil(#filteredRawEvents / Constants.DETAIL_RAW_PAGE_SIZE))
    if self.rawPage > totalPages then
        self.rawPage = totalPages
    end
    self.prevButton:SetEnabled(self.rawPage > 1)
    self.nextButton:SetEnabled(self.rawPage < totalPages)

    local filterLine, rawText, _ = buildRawEventSection(
        session,
        filteredRawEvents,
        self.rawPage,
        ns.Helpers.Trim(self.actorFilter:GetText() or ""),
        ns.Helpers.Trim(self.spellFilter:GetText() or ""),
        ns.Helpers.Trim(self.eventTypeFilter:GetText() or ""),
        ns.Helpers.Trim(self.windowFilter:GetText() or "")
    )
    self.rawMeta:SetText(filterLine)
    ns.Widgets.SetBodyText(self.rawContent, self.rawText, rawText)
    local multiLaneHeight = 0
    if #(session.timelineEvents or {}) > 0 then
        multiLaneHeight = (self.multiLaneContainer and self.multiLaneContainer:GetHeight() or 0) + 60
    elseif self.multiLaneFallback and self.multiLaneFallback:IsShown() then
        multiLaneHeight = 60
    end
    local tradeLedgerHeight = 0
    if self.tradeLedgerView and self.tradeLedgerView.frame and self.tradeLedgerView.frame:IsShown() then
        tradeLedgerHeight = self.tradeLedgerView.frame:GetHeight() + 20
    end
    -- T059: explicit bottom padding via LAYOUT token so last row is never clipped
    local L = ns.Widgets.LAYOUT
    ns.Widgets.SetCanvasHeight(self.canvas, 2240 + multiLaneHeight + tradeLedgerHeight + L.ROW_GAP * 2)
end

ns.Addon:RegisterModule("CombatDetailView", CombatDetailView)
