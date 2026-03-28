local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local MatchupDetailView = {
    viewId = "matchup",
    selectedSpecId = nil,
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local CONTENT_WIDTH = 740
local DELTA_BAR_WIDTH = 340
local DELTA_BAR_HEIGHT = 14
local SPARKLINE_WIDTH = 160
local SPARKLINE_HEIGHT = 20
local PILL_HEIGHT = 18
local SECTION_GAP = 14
local ITEM_GAP = 6
local SPELL_ROW_HEIGHT = 56
local METRIC_BAR_WIDTH = 340
local METRIC_BAR_HEIGHT = 58

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
function MatchupDetailView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Matchup Detail", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Detailed matchup analysis for a specific opponent spec.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Back button
    self.backButton = ns.Widgets.CreateButton(self.frame, "Back to Class/Spec", 140, 22)
    self.backButton:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -16, -16)
    self.backButton:SetScript("OnClick", function()
        ns.Addon:OpenView("classspec")
    end)

    -- Scrollable content area
    self.shell, self.scroll, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.detailElements = {}

    return self.frame
end

-- ---------------------------------------------------------------------------
-- Helpers: element pool management
-- ---------------------------------------------------------------------------
local function track(self, element)
    self.detailElements[#self.detailElements + 1] = element
    return element
end

local function addLabel(self, yPos, text, color, font)
    local fs = self.canvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
    fs:SetPoint("RIGHT", self.canvas, "RIGHT", -8, 0)
    fs:SetTextColor(unpack(color or Theme.text))
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    track(self, fs)
    return fs, yPos - (fs:GetStringHeight() + ITEM_GAP)
end

local function addSectionTitle(self, yPos, text)
    return addLabel(self, yPos, text, Theme.accent, "GameFontNormalLarge")
end

local function addMutedLabel(self, yPos, text)
    return addLabel(self, yPos, text, Theme.textMuted, "GameFontHighlightSmall")
end

-- ---------------------------------------------------------------------------
-- Helpers: compute per-spec averages from the specBucket
-- ---------------------------------------------------------------------------
local function computeSpecAverages(specBucket)
    local fights = specBucket and specBucket.fights or 0
    if fights == 0 then
        return {
            pressure = 0,
            damage = 0,
            deaths = 0,
            survivability = 0,
        }
    end
    return {
        pressure = (specBucket.totalPressureScore or 0) / fights,
        damage = (specBucket.totalDamageDone or 0) / fights,
        deaths = (specBucket.totalDeaths or 0) / fights,
        survivability = (specBucket.totalSurvivabilityScore or 0) / fights,
    }
end

-- ---------------------------------------------------------------------------
-- Helpers: compute overall player averages as baseline
-- ---------------------------------------------------------------------------
local function computeOverallBaseline(store, characterKey)
    local baseline = store and store.GetSessionBaseline
        and store:GetSessionBaseline(nil, nil, nil, nil, characterKey)
    if not baseline or baseline.fights <= 0 then
        return {
            pressure = 0,
            damage = 0,
            deaths = 0,
            survivability = 0,
        }
    end
    return {
        pressure = baseline.averagePressureScore or 0,
        damage = baseline.averageDamageDone or 0,
        deaths = 0,  -- baseline does not track per-death count; use 0
        survivability = baseline.averageSurvivabilityScore or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function MatchupDetailView:Refresh(payload)
    if payload and payload.specId then
        self.selectedSpecId = payload.specId
    end

    -- Clear old detail elements.
    for _, elem in ipairs(self.detailElements) do
        elem:Hide()
    end
    self.detailElements = {}

    if not self.selectedSpecId then
        local empty = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -8)
        empty:SetTextColor(unpack(Theme.textMuted))
        empty:SetText("No spec selected. Navigate here from the Class/Spec view.")
        self.detailElements[#self.detailElements + 1] = empty
        ns.Widgets.SetCanvasHeight(self.canvas, 60)
        return
    end

    local specId = self.selectedSpecId
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store and store:GetCurrentCharacterKey() or nil
    local snapshot = ns.Addon:GetLatestPlayerSnapshot()
    local buildHash = snapshot and snapshot.buildHash or nil
    local strategyEngine = ns.Addon:GetModule("StrategyEngine")

    -- Fetch data from various sources
    local archetype = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype and ns.StaticPvpData.GetSpecArchetype(specId) or nil
    local mmrBands = store and store.GetSpecWinRateByMMRBand and store:GetSpecWinRateByMMRBand(specId, characterKey) or {}
    local damageSignature = store and store.GetSpecDamageSignature and store:GetSpecDamageSignature(specId) or {}
    local bestBuild = store and store.GetBestBuildVsSpec and store:GetBestBuildVsSpec(specId) or nil
    local guide = strategyEngine and strategyEngine.GetCounterGuide
        and strategyEngine.GetCounterGuide(specId, buildHash, characterKey) or nil

    -- Get spec aggregate bucket for win/loss stats
    local specBuckets = store and store:GetAggregateBuckets("specs") or {}
    local specKey = tostring(specId)
    local specBucket = nil
    for _, bucket in ipairs(specBuckets) do
        if bucket.key == specKey then
            specBucket = bucket
            break
        end
    end
    -- Also check as a hash table (GetAggregateBuckets without characterKey returns a list, but guide uses hash lookup)
    if not specBucket and type(specBuckets) == "table" and specBuckets[specKey] then
        specBucket = specBuckets[specKey]
    end

    local fights = specBucket and specBucket.fights or 0
    local wins = specBucket and specBucket.wins or 0
    local losses = specBucket and specBucket.losses or 0
    local winRate = fights > 0 and (wins / fights) or 0

    local specName = (archetype and archetype.specName) or (guide and guide.specName) or (specBucket and specBucket.label) or "Unknown"
    local classFile = (archetype and archetype.classFile) or (guide and guide.classFile) or ""
    local archetypeLabel = (archetype and archetype.archetype) or (guide and guide.archetypeLabel) or "unknown"
    local rangeBucket = (archetype and archetype.rangeBucket) or (guide and guide.rangeBucket) or "unknown"

    local yPos = -8

    -- -----------------------------------------------------------------------
    -- Section 1: Header — Spec name + class (class-colored), archetype/range pills
    -- -----------------------------------------------------------------------
    local headerColor = Theme.accent
    if classFile and classFile ~= "" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        headerColor = { cc.r, cc.g, cc.b, 1 }
    end

    local _, nextY = addLabel(self, yPos, string.format("%s %s", classFile, specName), headerColor, "GameFontNormalLarge")
    yPos = nextY

    -- Archetype + range pills (inline)
    local pillRow = CreateFrame("Frame", nil, self.canvas)
    pillRow:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
    pillRow:SetSize(CONTENT_WIDTH, PILL_HEIGHT + 4)
    track(self, pillRow)

    local archetypePill = ns.Widgets.CreatePill(pillRow, nil, PILL_HEIGHT, Theme.accentSoft, Theme.borderStrong)
    archetypePill:SetData(archetypeLabel, Theme.text)
    local pillTextWidth = archetypePill.text:GetStringWidth() or 40
    archetypePill:SetSize(pillTextWidth + 16, PILL_HEIGHT)
    archetypePill:SetPoint("LEFT", pillRow, "LEFT", 0, 0)
    track(self, archetypePill)

    local rangePill = ns.Widgets.CreatePill(pillRow, nil, PILL_HEIGHT, Theme.panelAlt, Theme.border)
    rangePill:SetData(rangeBucket, Theme.textMuted)
    local rangePillTextWidth = rangePill.text:GetStringWidth() or 40
    rangePill:SetSize(rangePillTextWidth + 16, PILL_HEIGHT)
    rangePill:SetPoint("LEFT", archetypePill, "RIGHT", 6, 0)
    track(self, rangePill)

    yPos = yPos - (PILL_HEIGHT + ITEM_GAP + 4)

    -- -----------------------------------------------------------------------
    -- Section 2: Win/Loss Stats — metric cards row
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, wrTitleY = addSectionTitle(self, yPos, "Win / Loss Stats")
    yPos = wrTitleY

    local wrColor = winRate >= 0.5 and Theme.success or Theme.warning
    if fights == 0 then wrColor = Theme.textMuted end

    local cardWidth = math.floor((CONTENT_WIDTH - 8 * 2) / 3)
    local cardHeight = 70

    local wrCard = ns.Widgets.CreateMetricCard(self.canvas, cardWidth, cardHeight)
    wrCard:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
    wrCard:SetData(
        string.format("%.0f%%", winRate * 100),
        "Win Rate",
        string.format("%dW - %dL", wins, losses),
        wrColor
    )
    track(self, wrCard)

    local fightCard = ns.Widgets.CreateMetricCard(self.canvas, cardWidth, cardHeight)
    fightCard:SetPoint("LEFT", wrCard, "RIGHT", 4, 0)
    fightCard:SetData(
        tostring(fights),
        "Total Fights",
        "",
        Theme.accent
    )
    track(self, fightCard)

    local avgPressure = fights > 0 and ((specBucket.totalPressureScore or 0) / fights) or 0
    local pressureCard = ns.Widgets.CreateMetricCard(self.canvas, cardWidth, cardHeight)
    pressureCard:SetPoint("LEFT", fightCard, "RIGHT", 4, 0)
    pressureCard:SetData(
        string.format("%.1f", avgPressure),
        "Avg Pressure",
        "",
        Theme.accent
    )
    track(self, pressureCard)

    yPos = yPos - (cardHeight + ITEM_GAP)

    -- -----------------------------------------------------------------------
    -- Section 3: Mirrored Delta Bars — player avg vs matchup baseline
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, deltaTitleY = addSectionTitle(self, yPos, "Performance vs This Matchup")
    yPos = deltaTitleY

    local specAvg = computeSpecAverages(specBucket)
    local overallBaseline = computeOverallBaseline(store, characterKey)

    local deltaMetrics = {
        { label = "Pressure",      left = overallBaseline.pressure,     right = specAvg.pressure,     fmt = "%.1f" },
        { label = "Avg Damage",    left = overallBaseline.damage,       right = specAvg.damage,       fmt = Helpers.FormatNumber },
        { label = "Survivability", left = overallBaseline.survivability, right = specAvg.survivability, fmt = "%.1f" },
        { label = "Deaths/Fight",  left = overallBaseline.deaths,       right = specAvg.deaths,       fmt = "%.2f" },
    }

    -- Legend row
    local legendRow = CreateFrame("Frame", nil, self.canvas)
    legendRow:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
    legendRow:SetSize(CONTENT_WIDTH, 12)
    track(self, legendRow)

    local legendLeft = legendRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legendLeft:SetPoint("LEFT", legendRow, "LEFT", 0, 0)
    legendLeft:SetText("Your Overall Avg")
    legendLeft:SetTextColor(unpack(Theme.accent))

    local legendRight = legendRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legendRight:SetPoint("LEFT", legendLeft, "RIGHT", 16, 0)
    legendRight:SetText("vs This Spec Avg")
    legendRight:SetTextColor(unpack(Theme.warning))

    yPos = yPos - (16 + ITEM_GAP)

    for _, metric in ipairs(deltaMetrics) do
        local leftVal = metric.left or 0
        local rightVal = metric.right or 0

        -- Row container with label on top, bar below
        local rowLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rowLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
        rowLabel:SetText(metric.label)
        rowLabel:SetTextColor(unpack(Theme.text))
        track(self, rowLabel)

        -- Format values for display
        local leftText, rightText
        if type(metric.fmt) == "function" then
            leftText = metric.fmt(leftVal)
            rightText = metric.fmt(rightVal)
        else
            leftText = string.format(metric.fmt, leftVal)
            rightText = string.format(metric.fmt, rightVal)
        end

        local valLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", DELTA_BAR_WIDTH + 24, yPos)
        valLabel:SetText(string.format("%s  vs  %s", leftText, rightText))
        valLabel:SetTextColor(unpack(Theme.textMuted))
        track(self, valLabel)

        yPos = yPos - 14

        local bar = ns.Widgets.CreateMirroredDeltaBar(
            self.canvas,
            leftVal,
            rightVal,
            Theme.accent,
            Theme.warning,
            "",
            DELTA_BAR_WIDTH,
            DELTA_BAR_HEIGHT
        )
        bar:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
        track(self, bar)

        yPos = yPos - (DELTA_BAR_HEIGHT + ITEM_GAP + 2)
    end

    -- -----------------------------------------------------------------------
    -- Section 4: Win Rate by MMR Band — sparkline + table
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, mmrTitleY = addSectionTitle(self, yPos, "Win Rate by MMR Band")
    yPos = mmrTitleY

    if #mmrBands == 0 then
        local _, emptyY = addMutedLabel(self, yPos, "No MMR band data available.")
        yPos = emptyY
    else
        -- Build sparkline data from band win rates (only bands with fights)
        local sparkData = {}
        local hasAnySpark = false
        for _, band in ipairs(mmrBands) do
            if (band.fights or 0) > 0 then
                sparkData[#sparkData + 1] = band.winRate or 0
                hasAnySpark = true
            else
                sparkData[#sparkData + 1] = 0
            end
        end

        -- Sparkline trend across bands
        if hasAnySpark and #sparkData >= 2 then
            local sparkLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sparkLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
            sparkLabel:SetText("WR trend across bands:")
            sparkLabel:SetTextColor(unpack(Theme.textMuted))
            track(self, sparkLabel)

            local sparkline = ns.Widgets.CreateSparkline(
                self.canvas,
                sparkData,
                Theme.success,
                SPARKLINE_WIDTH,
                SPARKLINE_HEIGHT
            )
            sparkline:SetPoint("LEFT", sparkLabel, "RIGHT", 10, 0)
            track(self, sparkline)

            yPos = yPos - (SPARKLINE_HEIGHT + ITEM_GAP)
        end

        -- MMR band rows as MetricBars
        for _, band in ipairs(mmrBands) do
            local bandFights = band.fights or 0
            local bandWR = band.winRate or 0
            local bandColor = Theme.textMuted
            if bandFights > 0 then
                bandColor = bandWR >= 0.5 and Theme.success or Theme.warning
            end

            local bandBar = ns.Widgets.CreateMetricBar(self.canvas, METRIC_BAR_WIDTH, METRIC_BAR_HEIGHT)
            bandBar:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
            bandBar:SetData(
                band.label or "??",
                string.format("%.0f%% WR", bandWR * 100),
                string.format("%dW - %dL  (%d fights)", band.wins or 0, band.losses or 0, bandFights),
                bandFights > 0 and bandWR or 0,
                bandColor
            )
            track(self, bandBar)

            yPos = yPos - (METRIC_BAR_HEIGHT + 4)
        end
    end

    -- -----------------------------------------------------------------------
    -- Section 5: Top Opponent Spells — SpellRows
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, spellTitleY = addSectionTitle(self, yPos, "Top Opponent Spells")
    yPos = spellTitleY

    if #damageSignature == 0 then
        local _, emptyY = addMutedLabel(self, yPos, "No spell data available.")
        yPos = emptyY
    else
        -- Find max damage for relative bar sizing
        local maxDamage = 1
        for i = 1, math.min(5, #damageSignature) do
            if (damageSignature[i].totalDamage or 0) > maxDamage then
                maxDamage = damageSignature[i].totalDamage
            end
        end

        for i = 1, math.min(5, #damageSignature) do
            local spell = damageSignature[i]
            local spellInfo = ns.ApiCompat.GetSpellInfo(spell.spellId) or {}
            local name = spellInfo.name or string.format("Spell %d", spell.spellId)
            local iconID = spellInfo.iconID or spellInfo.icon or 134400
            local share = (spell.totalDamage or 0) / maxDamage

            local row = ns.Widgets.CreateSpellRow(self.canvas, CONTENT_WIDTH - 8, SPELL_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
            row:SetData(
                iconID,
                name,
                string.format("%d hits, %.0f%% crit", spell.hitCount or 0, (spell.critRate or 0) * 100),
                Helpers.FormatNumber(spell.totalDamage or 0),
                share,
                headerColor
            )
            track(self, row)

            yPos = yPos - (SPELL_ROW_HEIGHT + 4)
        end
    end

    -- -----------------------------------------------------------------------
    -- Section 6: Build Comparison — metric bars + delta badge
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, buildTitleY = addSectionTitle(self, yPos, "Build Comparison vs This Spec")
    yPos = buildTitleY

    local allBuilds = store and store.GetAllBuildsVsSpec and store:GetAllBuildsVsSpec(specId, buildHash) or {}
    if #allBuilds > 0 then
        -- Find current build entry
        local currentEntry = nil
        for _, b in ipairs(allBuilds) do
            if b.isCurrent then currentEntry = b; break end
        end

        for _, build in ipairs(allBuilds) do
            local marker = build.isCurrent and " (current)" or ""
            local buildWR = build.winRate or 0
            local buildColor = buildWR >= 0.5 and Theme.success or Theme.warning

            local buildBar = ns.Widgets.CreateMetricBar(self.canvas, METRIC_BAR_WIDTH, METRIC_BAR_HEIGHT)
            buildBar:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)

            local buildLabel = string.format("Build %s%s", build.buildHash or "--", marker)
            -- If this is the current build, show pressure as marker
            local markerPercent = nil
            if currentEntry and not build.isCurrent and currentEntry.winRate > 0 then
                markerPercent = currentEntry.winRate
            end
            buildBar:SetData(
                buildLabel,
                string.format("%.0f%% WR", buildWR * 100),
                string.format("%dW - %dL, %d fights, avg pressure %.1f",
                    build.wins or 0,
                    build.losses or 0,
                    build.fights or 0,
                    build.avgPressure or 0),
                buildWR,
                buildColor,
                markerPercent
            )
            track(self, buildBar)

            yPos = yPos - (METRIC_BAR_HEIGHT + 4)
        end

        -- Best-build delta badge
        if #allBuilds > 1 and allBuilds[1] and not allBuilds[1].isCurrent then
            local best = allBuilds[1]
            if currentEntry and best.winRate > currentEntry.winRate then
                local wrDelta = (best.winRate - currentEntry.winRate) * 100

                local badgeRow = CreateFrame("Frame", nil, self.canvas)
                badgeRow:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
                badgeRow:SetSize(CONTENT_WIDTH, 22)
                track(self, badgeRow)

                local badgeLabel = badgeRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                badgeLabel:SetPoint("LEFT", badgeRow, "LEFT", 0, 0)
                badgeLabel:SetText("Best build WR advantage:")
                badgeLabel:SetTextColor(unpack(Theme.textMuted))

                local badge = ns.Widgets.CreateDeltaBadge(badgeRow, wrDelta, "%.0f%% WR")
                badge:SetPoint("LEFT", badgeLabel, "RIGHT", 8, 0)
                track(self, badge)

                yPos = yPos - (22 + ITEM_GAP)
            end
        end
    else
        local _, emptyY = addMutedLabel(self, yPos, "Not enough build data yet (need 3+ fights).")
        yPos = emptyY
    end

    -- -----------------------------------------------------------------------
    -- Section 7: Counter Guide
    -- -----------------------------------------------------------------------
    yPos = yPos - SECTION_GAP
    local _, guideTitleY = addSectionTitle(self, yPos, "Counter Guide")
    yPos = guideTitleY

    if guide then
        -- Threat tags as pills
        if guide.threatTags and #guide.threatTags > 0 then
            local threatLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            threatLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
            threatLabel:SetText("Threats:")
            threatLabel:SetTextColor(unpack(Theme.textMuted))
            track(self, threatLabel)

            local prevPill = threatLabel
            local prevAnchor = "RIGHT"
            for _, tag in ipairs(guide.threatTags) do
                local pill = ns.Widgets.CreatePill(self.canvas, nil, PILL_HEIGHT, Theme.severityHigh, Theme.warning)
                pill:SetData(tag, Theme.text)
                local tagWidth = pill.text:GetStringWidth() or 40
                pill:SetSize(tagWidth + 16, PILL_HEIGHT)
                pill:SetPoint("LEFT", prevPill, prevAnchor, 6, 0)
                track(self, pill)
                prevPill = pill
                prevAnchor = "RIGHT"
            end

            yPos = yPos - (PILL_HEIGHT + ITEM_GAP + 2)
        end

        -- CC families as pills
        if guide.ccFamilies and #guide.ccFamilies > 0 then
            local families = {}
            local seenFam = {}
            for _, entry in ipairs(guide.ccFamilies) do
                local familyName = type(entry) == "table" and entry.family or tostring(entry)
                if familyName and not seenFam[familyName] then
                    seenFam[familyName] = true
                    families[#families + 1] = familyName
                end
            end
            table.sort(families)

            local ccLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            ccLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
            ccLabel:SetText("CC Families:")
            ccLabel:SetTextColor(unpack(Theme.textMuted))
            track(self, ccLabel)

            local prevPill = ccLabel
            local prevAnchor = "RIGHT"
            for _, familyName in ipairs(families) do
                local pill = ns.Widgets.CreatePill(self.canvas, nil, PILL_HEIGHT, Theme.panelAlt, Theme.border)
                pill:SetData(familyName, Theme.textMuted)
                local famWidth = pill.text:GetStringWidth() or 40
                pill:SetSize(famWidth + 16, PILL_HEIGHT)
                pill:SetPoint("LEFT", prevPill, prevAnchor, 6, 0)
                track(self, pill)
                prevPill = pill
                prevAnchor = "RIGHT"
            end

            yPos = yPos - (PILL_HEIGHT + ITEM_GAP + 2)
        end

        -- Recommended actions
        if guide.recommendedActions and #guide.recommendedActions > 0 then
            yPos = yPos - 4
            local _, actTitleY = addLabel(self, yPos, "Recommended Actions:", Theme.text)
            yPos = actTitleY
            for _, action in ipairs(guide.recommendedActions) do
                local _, actionY = addLabel(self, yPos, "  " .. action, Theme.text, "GameFontHighlightSmall")
                yPos = actionY
            end
        end
    else
        local _, emptyY = addMutedLabel(self, yPos, "No counter guide data available.")
        yPos = emptyY
    end

    ns.Widgets.SetCanvasHeight(self.canvas, math.abs(yPos) + 20)

    -- Update title to reflect selected spec
    self.title:SetText(string.format("Matchup Detail — %s", specName))
    self.caption:SetText(string.format("Detailed matchup analysis for %s %s.", classFile, specName))
end

ns.Addon:RegisterModule("MatchupDetailView", MatchupDetailView)
