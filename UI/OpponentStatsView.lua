local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local OpponentStatsView = {
    viewId = "opponents",
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local MAX_BARS = 10
local MAX_ROSTER_SLOTS = 5
local BAR_HEIGHT = 58
local BAR_SPACING = 6
local HEAT_CELL_SIZE = 14
local ROSTER_CARD_WIDTH = 360
local ROSTER_CARD_HEIGHT = 52
local ROSTER_CARD_SPACING = 8
local SECTION_SPACING = 22
local CANVAS_WIDTH = 750

-- Win/loss color ramp for the heat grid.
local function winLossColorRamp(value)
    -- value: 1 = win, -1 = loss, 0 = no data
    if value == 1 then
        return Theme.success[1], Theme.success[2], Theme.success[3]
    elseif value == -1 then
        return Theme.severityHigh[1], Theme.severityHigh[2], Theme.severityHigh[3]
    end
    return Theme.panel[1], Theme.panel[2], Theme.panel[3]
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
function OpponentStatsView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Opponent Analysis", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Aggregated opponent trends across all stored sessions.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(Theme.textMuted))
    self.emptyState:SetText("No opponent aggregates yet.")

    -- Section: Top Opponent Bar Chart
    self.barChartTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Top Opponents", "TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.barChartCaption = ns.Widgets.CreateCaption(self.canvas, "Win rate by fight count against your most-encountered opponents.", "TOPLEFT", self.barChartTitle, "BOTTOMLEFT", 0, -4)

    self.opponentBars = {}
    for index = 1, MAX_BARS do
        local bar = ns.Widgets.CreateMetricBar(self.canvas, CANVAS_WIDTH, BAR_HEIGHT)
        if index == 1 then
            bar:SetPoint("TOPLEFT", self.barChartCaption, "BOTTOMLEFT", 0, -10)
        else
            bar:SetPoint("TOPLEFT", self.opponentBars[index - 1], "BOTTOMLEFT", 0, -BAR_SPACING)
        end
        bar:Hide()
        self.opponentBars[index] = bar
    end

    -- Section: Win/Loss Heat Strip
    self.heatTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Win / Loss Distribution", "TOPLEFT", self.opponentBars[MAX_BARS], "BOTTOMLEFT", 0, -SECTION_SPACING)
    self.heatCaption = ns.Widgets.CreateCaption(self.canvas, "Each cell represents one recent fight. Green = win, red = loss.", "TOPLEFT", self.heatTitle, "BOTTOMLEFT", 0, -4)

    self.heatLegend = ns.Widgets.CreateMiniLegend(self.canvas, {
        { color = Theme.success, label = "Win" },
        { color = Theme.severityHigh, label = "Loss" },
        { color = Theme.panel, label = "No Data" },
    }, 12)
    self.heatLegend:SetPoint("TOPLEFT", self.heatCaption, "BOTTOMLEFT", 0, -6)

    -- Heat grid anchor (created dynamically in Refresh)
    self.heatAnchor = CreateFrame("Frame", nil, self.canvas)
    self.heatAnchor:SetPoint("TOPLEFT", self.heatLegend, "BOTTOMLEFT", 0, -6)
    self.heatAnchor:SetSize(CANVAS_WIDTH, 1)

    -- Section: Arena Roster Cards
    self.rosterTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Last Arena Roster", "TOPLEFT", self.heatAnchor, "BOTTOMLEFT", 0, -SECTION_SPACING)
    self.rosterCaption = ns.Widgets.CreateCaption(self.canvas, "Identified enemy slots from the most recent arena session.", "TOPLEFT", self.rosterTitle, "BOTTOMLEFT", 0, -4)
    self.rosterTitle:Hide()
    self.rosterCaption:Hide()

    -- Roster card frames are pooled
    self.rosterCards = {}
    self.rosterCardPool = {}

    -- Unresolved roster warning anchor (created dynamically)
    self.unresolvedAnchor = CreateFrame("Frame", nil, self.canvas)
    self.unresolvedAnchor:SetPoint("TOPLEFT", self.rosterCaption, "BOTTOMLEFT", 0, -8)
    self.unresolvedAnchor:SetSize(CANVAS_WIDTH, 1)

    -- Duel practice rows (pooled dynamically)
    self.duelPracticePool = {}

    ns.Widgets.SetCanvasHeight(self.canvas, 800)
    return self.frame
end

-- ---------------------------------------------------------------------------
-- Pool management: hide all dynamic elements before each refresh
-- ---------------------------------------------------------------------------
local function hidePool(pool)
    for i = 1, #pool do
        pool[i]:Hide()
    end
end

local function getOrCreateRosterCard(self, index)
    if self.rosterCardPool[index] then
        return self.rosterCardPool[index]
    end

    local card = ns.Widgets.CreateSurface(self.canvas, ROSTER_CARD_WIDTH, ROSTER_CARD_HEIGHT, Theme.panelAlt, Theme.border)

    card.dot = card:CreateTexture(nil, "ARTWORK")
    card.dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    card.dot:SetSize(10, 10)
    card.dot:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
    card.dot:SetVertexColor(unpack(Theme.textMuted))

    card.nameLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.nameLabel:SetPoint("LEFT", card.dot, "RIGHT", 8, 0)
    card.nameLabel:SetTextColor(unpack(Theme.text))
    card.nameLabel:SetJustifyH("LEFT")

    card.specLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.specLabel:SetPoint("TOPLEFT", card.dot, "BOTTOMLEFT", 0, -6)
    card.specLabel:SetPoint("RIGHT", card, "RIGHT", -80, 0)
    card.specLabel:SetTextColor(unpack(Theme.textMuted))
    card.specLabel:SetJustifyH("LEFT")

    -- Confidence pill anchor (positioned at card right edge)
    card.pillAnchor = CreateFrame("Frame", nil, card)
    card.pillAnchor:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    card.pillAnchor:SetSize(84, 18)

    self.rosterCardPool[index] = card
    return card
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function OpponentStatsView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterRef = store:GetCurrentCharacterRef()
    local buckets = store:GetAggregateBuckets("opponents", characterRef)
    local latestSession = store:GetLatestSession(characterRef)
    local usingFallback = false

    if #buckets == 0 then
        buckets = store:GetAggregateBuckets("opponents")
        latestSession = latestSession or store:GetLatestSession()
        usingFallback = #buckets > 0
    end

    -- Reset scroll position
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end

    -- Update caption
    if latestSession then
        self.caption:SetText(string.format(
            "Aggregated opponent trends for %s%s.",
            store:GetSessionCharacterLabel(latestSession),
            usingFallback and " (fallback to all stored sessions)" or ""
        ))
    else
        self.caption:SetText("Aggregated opponent trends for the current character.")
    end

    -- Hide all dynamic pools
    for _, bar in ipairs(self.opponentBars) do bar:Hide() end
    hidePool(self.rosterCardPool)
    hidePool(self.duelPracticePool)

    -- Hide dynamic widgets from previous refresh
    if self.heatGridWidget then
        self.heatGridWidget:Hide()
    end
    if self.unresolvedPill then
        self.unresolvedPill:Hide()
    end

    -- Empty state
    if #buckets == 0 then
        self.emptyState:Show()
        self.barChartTitle:Hide()
        self.barChartCaption:Hide()
        self.heatTitle:Hide()
        self.heatCaption:Hide()
        self.heatLegend:Hide()
        self.rosterTitle:Hide()
        self.rosterCaption:Hide()
        return
    end

    self.emptyState:Hide()
    self.barChartTitle:Show()
    self.barChartCaption:Show()

    -- -----------------------------------------------------------------
    -- 1. Top Opponent Bar Chart
    -- -----------------------------------------------------------------
    local displayCount = math.min(MAX_BARS, #buckets)
    local maxFights = 1
    for index = 1, displayCount do
        local fights = buckets[index].fights or 0
        if fights > maxFights then
            maxFights = fights
        end
    end

    local latestBuildHash = latestSession and latestSession.playerSnapshot and latestSession.playerSnapshot.buildHash or nil
    local lastVisibleBar = self.opponentBars[1]

    for index = 1, displayCount do
        local bucket = buckets[index]
        local bar = self.opponentBars[index]
        local fights = bucket.fights or 0
        local wins = bucket.wins or 0
        local losses = bucket.losses or 0
        local winRate = fights > 0 and (wins / fights) or 0
        local avgDmg = Helpers.FormatNumber((bucket.totalDamageDone or 0) / math.max(fights, 1))
        local avgTaken = Helpers.FormatNumber((bucket.totalDamageTaken or 0) / math.max(fights, 1))
        local avgPressure = (bucket.totalPressureScore or 0) / math.max(fights, 1)

        local fillColor = winRate >= 0.6 and Theme.success
            or winRate >= 0.4 and Theme.accent
            or Theme.warning

        local caption = string.format(
            "W-L: %d-%d (%.0f%%)  |  Avg dmg: %s  |  Avg taken: %s  |  Avg pressure: %.1f",
            wins, losses, winRate * 100, avgDmg, avgTaken, avgPressure
        )

        -- Append duel practice lens if available
        if latestBuildHash then
            local duelPractice = store:GetDuelPracticeSummary(
                latestBuildHash,
                bucket.key,
                usingFallback and nil or characterRef
            )
            if duelPractice and duelPractice.fights >= 3 then
                caption = caption .. string.format(
                    "  |  Duel lens: %d fights, opener %s, avg dur %s",
                    duelPractice.fights or 0,
                    Helpers.FormatNumber(duelPractice.averageOpenerDamage or 0),
                    Helpers.FormatDuration(duelPractice.averageDuration or 0)
                )
            end
        end

        bar:SetData(
            bucket.label or bucket.key,
            string.format("%d fights", fights),
            caption,
            fights / maxFights,
            fillColor
        )
        bar:Show()
        lastVisibleBar = bar
    end

    -- Re-anchor heat section below last visible bar
    self.heatTitle:ClearAllPoints()
    self.heatTitle:SetPoint("TOPLEFT", lastVisibleBar, "BOTTOMLEFT", 0, -SECTION_SPACING)

    -- -----------------------------------------------------------------
    -- 2. Win/Loss Heat Strip
    -- -----------------------------------------------------------------
    -- Build heat grid data: rows = opponents (up to displayCount), cols = last N fights
    local maxCols = 20
    local heatRows = {}
    local rowLabels = {}
    local actualCols = 0

    for index = 1, displayCount do
        local bucket = buckets[index]
        local results = bucket.recentResults or {}
        local row = {}
        for col = 1, maxCols do
            local result = results[col]
            if result == "won" or result == "win" then
                row[col] = 1
            elseif result == "lost" or result == "loss" then
                row[col] = -1
            else
                row[col] = 0
            end
        end
        heatRows[index] = row
        -- Truncate long names for row labels
        local label = bucket.label or bucket.key or ""
        if #label > 10 then
            label = string.sub(label, 1, 9) .. "."
        end
        rowLabels[index] = label
        if #results > actualCols then
            actualCols = #results
        end
    end

    -- Use at least 5 columns, cap at maxCols
    actualCols = math.max(math.min(actualCols, maxCols), 5)

    -- Generate column labels (fight numbers)
    local colLabels = {}
    for col = 1, actualCols do
        colLabels[col] = tostring(col)
    end

    self.heatTitle:Show()
    self.heatCaption:Show()
    self.heatLegend:Show()

    if self.heatGridWidget then
        self.heatGridWidget:Hide()
    end

    self.heatGridWidget = ns.Widgets.CreateHeatGrid(
        self.canvas,
        displayCount,
        actualCols,
        heatRows,
        winLossColorRamp,
        { rowLabels = rowLabels, colLabels = colLabels },
        HEAT_CELL_SIZE
    )
    self.heatGridWidget:SetPoint("TOPLEFT", self.heatAnchor, "TOPLEFT", 0, 0)
    self.heatGridWidget:Show()

    local heatGridHeight = (displayCount * HEAT_CELL_SIZE) + (colLabels and 14 or 0)
    self.heatAnchor:SetSize(CANVAS_WIDTH, math.max(heatGridHeight, 1))

    -- -----------------------------------------------------------------
    -- 3. Arena Roster Cards
    -- -----------------------------------------------------------------
    self.rosterTitle:ClearAllPoints()
    self.rosterTitle:SetPoint("TOPLEFT", self.heatAnchor, "BOTTOMLEFT", 0, -SECTION_SPACING)

    local showRoster = false
    local rosterCardCount = 0
    local lastRosterElement = self.rosterCaption

    if latestSession and latestSession.context == "arena" then
        local arenaData = type(latestSession.arena) == "table" and latestSession.arena or nil
        local slots = arenaData and arenaData.slots or nil
        local slotCount = 0
        if slots then
            for _ in pairs(slots) do slotCount = slotCount + 1 end
        end

        if slotCount > 0 then
            showRoster = true
            self.rosterTitle:Show()
            self.rosterCaption:Show()
            self.rosterCaption:SetText(string.format(
                "Identified enemy slots from arena session %s.",
                date("%Y-%m-%d %H:%M", latestSession.timestamp or 0)
            ))

            -- Determine confidence for pills
            local sessionConfidence = latestSession.captureQuality
                and latestSession.captureQuality.fieldConfidence
                or nil

            for slot = 1, MAX_ROSTER_SLOTS do
                local slotData = slots[slot]
                if slotData then
                    rosterCardCount = rosterCardCount + 1
                    local card = getOrCreateRosterCard(self, rosterCardCount)

                    -- Class-colored dot
                    local classFile = slotData.classFile
                    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
                        local cc = RAID_CLASS_COLORS[classFile]
                        card.dot:SetVertexColor(cc.r, cc.g, cc.b, 1)
                        card.nameLabel:SetTextColor(cc.r, cc.g, cc.b, 1)
                    else
                        card.dot:SetVertexColor(unpack(Theme.textMuted))
                        card.nameLabel:SetTextColor(unpack(Theme.text))
                    end

                    local name = slotData.name or slotData.guid or "Unknown"
                    card.nameLabel:SetText(name)

                    local specParts = {}
                    if slotData.specName then
                        specParts[#specParts + 1] = slotData.specName
                    end
                    if slotData.classFile then
                        specParts[#specParts + 1] = slotData.classFile
                    end
                    local specText = #specParts > 0 and table.concat(specParts, " / ") or "?"
                    if slotData.pressureScore then
                        specText = specText .. string.format("  |  Pressure: %.1f", slotData.pressureScore)
                    end
                    card.specLabel:SetText(specText)

                    -- Confidence pill for this slot
                    if card.confidencePill then
                        card.confidencePill:Hide()
                    end
                    local slotConfidence = slotData.fieldConfidence
                        or (sessionConfidence and sessionConfidence.roster)
                        or (latestSession.captureQuality and latestSession.captureQuality.confidence and
                            latestSession.captureQuality.confidence)
                        or nil
                    if slotConfidence then
                        card.confidencePill = ns.Widgets.CreateConfidencePill(card, slotConfidence)
                        card.confidencePill:ClearAllPoints()
                        card.confidencePill:SetPoint("RIGHT", card, "RIGHT", -10, 0)
                    end

                    -- Position cards in a 2-column layout
                    card:ClearAllPoints()
                    local col = (rosterCardCount - 1) % 2
                    local row = math.floor((rosterCardCount - 1) / 2)
                    if row == 0 and col == 0 then
                        card:SetPoint("TOPLEFT", self.rosterCaption, "BOTTOMLEFT", 0, -8)
                    elseif col == 0 then
                        -- Left column, subsequent rows
                        local prevLeftIndex = rosterCardCount - 2
                        card:SetPoint("TOPLEFT", self.rosterCardPool[prevLeftIndex], "BOTTOMLEFT", 0, -ROSTER_CARD_SPACING)
                    else
                        -- Right column
                        card:SetPoint("TOPLEFT", self.rosterCardPool[rosterCardCount - 1], "TOPRIGHT", ROSTER_CARD_SPACING, 0)
                    end

                    card:Show()
                    if col == 0 then
                        lastRosterElement = card
                    end
                end
            end

            -- 4. Unresolved roster warning chip
            local unresolved = arenaData.unresolvedGuids or {}
            local unresolvedCount = 0
            for _ in pairs(unresolved) do unresolvedCount = unresolvedCount + 1 end

            if unresolvedCount > 0 then
                if self.unresolvedPill then
                    self.unresolvedPill:Hide()
                end
                self.unresolvedPill = ns.Widgets.CreatePill(
                    self.canvas, nil, nil,
                    Theme.severityMedium, Theme.warning
                )
                self.unresolvedPill:SetData(
                    string.format("%d Unresolved", unresolvedCount),
                    Theme.text,
                    Theme.severityMedium,
                    Theme.warning
                )
                self.unresolvedPill:ClearAllPoints()
                self.unresolvedPill:SetPoint("TOPLEFT", lastRosterElement, "BOTTOMLEFT", 0, -8)
                self.unresolvedPill:Show()
                lastRosterElement = self.unresolvedPill
            end
        end
    end

    if not showRoster then
        self.rosterTitle:Hide()
        self.rosterCaption:Hide()
    end

    -- Hide unused roster cards
    for index = rosterCardCount + 1, #self.rosterCardPool do
        self.rosterCardPool[index]:Hide()
    end

    -- -----------------------------------------------------------------
    -- Calculate canvas height
    -- -----------------------------------------------------------------
    local totalHeight = 0

    -- Bar chart section
    totalHeight = totalHeight + 20 + 16 + 10 -- title + caption + gap
    totalHeight = totalHeight + (displayCount * (BAR_HEIGHT + BAR_SPACING))

    -- Heat strip section
    totalHeight = totalHeight + SECTION_SPACING + 20 + 16 + 6 + 14 + 6 -- title + caption + legend + gap
    totalHeight = totalHeight + heatGridHeight

    -- Roster section
    if showRoster then
        totalHeight = totalHeight + SECTION_SPACING + 20 + 16 + 8 -- title + caption + gap
        local rosterRows = math.ceil(rosterCardCount / 2)
        totalHeight = totalHeight + (rosterRows * (ROSTER_CARD_HEIGHT + ROSTER_CARD_SPACING))
        if self.unresolvedPill and self.unresolvedPill:IsShown() then
            totalHeight = totalHeight + 8 + 18 -- gap + pill height
        end
    end

    totalHeight = totalHeight + 40 -- bottom padding

    ns.Widgets.SetCanvasHeight(self.canvas, math.max(totalHeight, 200))
end

ns.Addon:RegisterModule("OpponentStatsView", OpponentStatsView)
