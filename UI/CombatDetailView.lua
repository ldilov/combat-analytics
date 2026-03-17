local _, ns = ...

local Constants = ns.Constants

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

local function buildSpellBreakdown(session)
    local rows = {}
    for spellId, aggregate in pairs(session.spells or {}) do
        rows[#rows + 1] = {
            spellId = spellId,
            damage = aggregate.totalDamage or 0,
            healing = aggregate.totalHealing or 0,
            casts = aggregate.castCount or 0,
            hits = aggregate.hitCount or 0,
        }
    end
    table.sort(rows, function(left, right)
        return (left.damage + left.healing) > (right.damage + right.healing)
    end)

    local lines = {}
    for index = 1, math.min(12, #rows) do
        local row = rows[index]
        lines[#lines + 1] = string.format(
            "%d. %s (%d) dmg=%s heal=%s casts=%d hits=%d",
            index,
            (ns.ApiCompat.GetSpellInfo(row.spellId) or {}).name or "Spell",
            row.spellId,
            ns.Helpers.FormatNumber(row.damage),
            ns.Helpers.FormatNumber(row.healing),
            row.casts,
            row.hits
        )
    end
    if #lines == 0 then
        return "No spell totals were captured for this session."
    end
    return table.concat(lines, "\n")
end

function CombatDetailView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Combat Detail", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Spell breakdown plus raw event log when available. Midnight-safe sessions use imported post-combat totals.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

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

    self.scrollFrame, self.content, self.text = ns.Widgets.CreateBodyText(self.frame, 808, 368)
    self.scrollFrame:SetPoint("TOPLEFT", self.filterBar, "BOTTOMLEFT", 0, -10)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

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
    end

    local store = ns.Addon:GetModule("CombatStore")
    local session = self.sessionId and store:GetCombatById(self.sessionId) or store:GetLatestSession()
    if not session then
        ns.Widgets.SetBodyText(self.content, self.text, "No combat session selected.")
        return
    end

    self.sessionId = session.id
    local filteredRawEvents = self:FilterRawEvents(session)
    local totalPages = math.max(1, math.ceil(#filteredRawEvents / Constants.DETAIL_RAW_PAGE_SIZE))
    if self.rawPage > totalPages then
        self.rawPage = totalPages
    end
    self.prevButton:SetEnabled(self.rawPage > 1)
    self.nextButton:SetEnabled(self.rawPage < totalPages)

    local startIndex = (self.rawPage - 1) * Constants.DETAIL_RAW_PAGE_SIZE + 1
    local endIndex = math.min(startIndex + Constants.DETAIL_RAW_PAGE_SIZE - 1, #filteredRawEvents)
    local rawLines = {}
    for index = startIndex, endIndex do
        local eventRecord = filteredRawEvents[index]
        rawLines[#rawLines + 1] = string.format(
            "%6.2f  %-10s  spell=%s  amount=%s  source=%s  dest=%s",
            eventRecord.timestampOffset or 0,
            eventRecord.eventType or "other",
            tostring(eventRecord.spellId or "-"),
            tostring(eventRecord.amount or "-"),
            tostring(eventRecord.sourceGuid or "-"),
            tostring(eventRecord.destGuid or "-")
        )
    end

    local rawEventSection = (#rawLines > 0 and table.concat(rawLines, "\n")) or "No raw events match the current filters."
    if #(session.rawEvents or {}) == 0 and session.metrics and session.metrics.limitedBySource then
        rawEventSection = "Raw event timeline is unavailable in Midnight-safe mode. Spell totals above were imported from the built-in Damage Meter after combat."
    end

    local identity = session.identity or {}
    local identityEvidence = identity.evidence or {}
    local importInfo = session.import or {}

    local text = table.concat({
        string.format("Session: %s", session.id),
        string.format("Context: %s %s", session.context or "unknown", session.subcontext or ""),
        string.format("Result: %s", session.result or "unknown"),
        string.format(
            "Identity: kind=%s provisional=%s confidence=%s source=%s reason=%s",
            identity.kind or "unknown",
            identity.provisional and "yes" or "no",
            tostring(identity.confidence or 0),
            identity.source or "unknown",
            identity.reason or "unknown"
        ),
        string.format(
            "Identity Subject: guid=%s name=%s creatureId=%s subjectKey=%s",
            identity.opponentGuid or "none",
            identity.opponentName or "none",
            tostring(identity.opponentCreatureId or 0),
            identity.subjectKey or "none"
        ),
        string.format(
            "Identity Evidence: duel=%.1f dummy=%.1f worldPvP=%.1f repeatedHostile=%d",
            identityEvidence.duelScore or 0,
            identityEvidence.dummyScore or 0,
            identityEvidence.worldPvpScore or 0,
            identityEvidence.repeatedHostilePlayerEvents or 0
        ),
        string.format(
            "Import: source=%s sessionId=%s confidence=%s durationDelta=%s signalScore=%s breakdown=%s",
            importInfo.source or "none",
            tostring(importInfo.damageMeterSessionId or 0),
            tostring(importInfo.confidence or 0),
            importInfo.durationDelta and string.format("%.1f", importInfo.durationDelta) or "--",
            tostring(importInfo.signalScore or 0),
            importInfo.damageBreakdown or "none"
        ),
        string.format(
            "Fight Snapshot: ilvl=%s  mastery=%s  versatility=%s dmg / %s DR",
            session.playerSnapshot and session.playerSnapshot.equippedItemLevel and string.format("%.1f", session.playerSnapshot.equippedItemLevel) or "--",
            session.playerSnapshot and session.playerSnapshot.masteryEffect and string.format("%.1f%%", session.playerSnapshot.masteryEffect) or "--",
            session.playerSnapshot and session.playerSnapshot.versatilityDamageDone and string.format("%.1f%%", session.playerSnapshot.versatilityDamageDone) or "--",
            session.playerSnapshot and session.playerSnapshot.versatilityDamageTaken and string.format("%.1f%%", session.playerSnapshot.versatilityDamageTaken) or "--"
        ),
        string.format("Raw Events Page: %d / %d", self.rawPage, totalPages),
        string.format("Filters: actor=%s spell=%s event=%s window=%s", self.actorFilter:GetText() or "", self.spellFilter:GetText() or "", self.eventTypeFilter:GetText() or "", self.windowFilter:GetText() or ""),
        "",
        "Totals",
        string.format("Damage=%s  Healing=%s  Taken=%s", ns.Helpers.FormatNumber(session.totals.damageDone or 0), ns.Helpers.FormatNumber(session.totals.healingDone or 0), ns.Helpers.FormatNumber(session.totals.damageTaken or 0)),
        string.format("Pressure=%.1f  Burst=%.1f  Survivability=%.1f  Utility=%.1f", session.metrics.pressureScore or 0, session.metrics.burstScore or 0, session.metrics.survivabilityScore or 0, session.metrics.utilityEfficiencyScore or 0),
        string.format("Rotation=%.1f  ProcFollowThrough=%.1f  ProcWindows=%d  ProcCasts=%d", session.metrics.rotationalConsistencyScore or 0, session.metrics.procConversionScore or 0, session.metrics.procWindowsObserved or 0, session.metrics.procWindowCastCount or 0),
        "",
        "Spell Breakdown",
        buildSpellBreakdown(session),
        "",
        "Raw Events",
        rawEventSection,
    }, "\n")

    ns.Widgets.SetBodyText(self.content, self.text, text)
end

ns.Addon:RegisterModule("CombatDetailView", CombatDetailView)
