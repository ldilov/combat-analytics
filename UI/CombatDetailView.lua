local _, ns = ...

local Constants = ns.Constants
local Theme = ns.Widgets.THEME

local CombatDetailView = {
    viewId = "detail",
    rawPage = 1,
    sessionId = nil,
}

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
    local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown Opponent"
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

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 368)
    self.shell:SetPoint("TOPLEFT", self.filterBar, "BOTTOMLEFT", 0, -10)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(Theme.textMuted))
    self.emptyState:SetText("No combat session selected.")

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

    self.rawTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Raw Timeline", "TOPLEFT", self.spellRows[#self.spellRows], "BOTTOMLEFT", 0, -22)
    self.rawCaption = ns.Widgets.CreateCaption(self.canvas, "Filtered raw events stay available here, but they are now the support layer instead of the whole screen.", "TOPLEFT", self.rawTitle, "BOTTOMLEFT", 0, -4)
    self.rawMeta = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.rawMeta:SetPoint("TOPLEFT", self.rawCaption, "BOTTOMLEFT", 0, -10)
    self.rawMeta:SetTextColor(unpack(Theme.textMuted))

    self.rawShell, self.rawContent, self.rawText = ns.Widgets.CreateBodyText(self.canvas, 750, 210)
    self.rawShell:SetPoint("TOPLEFT", self.rawMeta, "BOTTOMLEFT", 0, -8)

    ns.Widgets.SetCanvasHeight(self.canvas, 1520)
    return self.frame
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
        self.rawTitle:Hide()
        self.rawCaption:Hide()
        self.rawMeta:Hide()
        self.rawShell:Hide()
        return
    end

    if self.lastRenderedSessionId ~= session.id and self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    end

    self.emptyState:Hide()
    self.sessionId = session.id
    self.lastRenderedSessionId = session.id
    self.title:SetText(string.format("Combat Detail • %s", session.primaryOpponent and (session.primaryOpponent.name or "Unknown Opponent") or "Selected Fight"))
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
    self.rawTitle:Show()
    self.rawCaption:Show()
    self.rawMeta:Show()
    self.rawShell:Show()

    local opponent = session.primaryOpponent and (session.primaryOpponent.name or session.primaryOpponent.guid) or "Unknown Opponent"
    local readQuality = formatDisplayLabel(session.analysisConfidence or "limited")
    local readSource = formatDisplayLabel(session.finalDamageSource or "damage_meter")
    -- Rich label from the data confidence pipeline (e.g. "Full Raw", "Enriched").
    local richQuality = session.dataConfidence
        and formatDisplayLabel(session.dataConfidence)
        or readQuality

    self.metricCards[1]:SetData(
        ns.Helpers.FormatNumber(session.totals.damageDone or 0),
        "Damage Done",
        string.format("%s DPS over %s against %s.", ns.Helpers.FormatNumber(session.metrics.sustainedDps or 0), ns.Helpers.FormatDuration(session.duration or 0), opponent),
        Theme.accent
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
    ns.Widgets.SetCanvasHeight(self.canvas, 1520)
end

ns.Addon:RegisterModule("CombatDetailView", CombatDetailView)
