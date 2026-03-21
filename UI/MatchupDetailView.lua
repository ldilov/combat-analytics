local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local MatchupDetailView = {
    viewId = "matchup",
    selectedSpecId = nil,
}

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
    local snapshot = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot or nil
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
    local avgPressure = fights > 0 and ((specBucket and specBucket.totalPressureScore or 0) / fights) or 0

    local specName = (archetype and archetype.specName) or (guide and guide.specName) or (specBucket and specBucket.label) or "Unknown"
    local classFile = (archetype and archetype.classFile) or (guide and guide.classFile) or ""
    local archetypeLabel = (archetype and archetype.archetype) or (guide and guide.archetypeLabel) or "unknown"
    local rangeBucket = (archetype and archetype.rangeBucket) or (guide and guide.rangeBucket) or "unknown"

    local yPos = -8

    local function addLabel(text, color, font)
        local fs = self.canvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
        fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, yPos)
        fs:SetPoint("RIGHT", self.canvas, "RIGHT", -8, 0)
        fs:SetTextColor(unpack(color or Theme.text))
        fs:SetText(text)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        self.detailElements[#self.detailElements + 1] = fs
        yPos = yPos - (fs:GetStringHeight() + 6)
        return fs
    end

    -- Section 1: Header — Spec name + class (class-colored), archetype, range
    local headerColor = Theme.accent
    if classFile and classFile ~= "" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        headerColor = { cc.r, cc.g, cc.b, 1 }
    end
    addLabel(string.format("%s %s", classFile, specName), headerColor, "GameFontNormalLarge")
    addLabel(string.format("Archetype: %s  |  Range: %s", archetypeLabel, rangeBucket), Theme.textMuted, "GameFontHighlightSmall")

    -- Section 2: Win/Loss Stats
    yPos = yPos - 6
    addLabel("Win / Loss Stats", Theme.accent, "GameFontNormalLarge")
    addLabel(string.format("Total Fights: %d", fights), Theme.text)
    local winsColor = wins > 0 and Theme.success or Theme.text
    local lossesColor = losses > 0 and Theme.warning or Theme.text
    addLabel(string.format("Wins: %d  |  Losses: %d", wins, losses), Theme.text)

    local wrColor = winRate >= 0.5 and Theme.success or Theme.warning
    if fights == 0 then wrColor = Theme.textMuted end
    addLabel(string.format("Win Rate: %.0f%%", winRate * 100), wrColor)
    addLabel(string.format("Avg Pressure Score: %.1f", avgPressure), Theme.textMuted, "GameFontHighlightSmall")

    -- Section 3: Win Rate by MMR Band
    yPos = yPos - 6
    addLabel("Win Rate by MMR Band", Theme.accent, "GameFontNormalLarge")
    if #mmrBands == 0 then
        addLabel("No MMR band data available.", Theme.textMuted, "GameFontHighlightSmall")
    else
        for _, band in ipairs(mmrBands) do
            local bandFights = band.fights or 0
            local bandWR = band.winRate or 0
            local bandColor = Theme.textMuted
            if bandFights > 0 then
                bandColor = bandWR >= 0.5 and Theme.success or Theme.warning
            end
            addLabel(string.format("  %s — %d fights, %.0f%% WR (%dW-%dL)",
                band.label or "??",
                bandFights,
                bandWR * 100,
                band.wins or 0,
                band.losses or 0
            ), bandColor, "GameFontHighlightSmall")
        end
    end

    -- Section 4: Top Opponent Spells
    yPos = yPos - 6
    addLabel("Top Opponent Spells", Theme.accent, "GameFontNormalLarge")
    if #damageSignature == 0 then
        addLabel("No spell data available.", Theme.textMuted, "GameFontHighlightSmall")
    else
        for i = 1, math.min(5, #damageSignature) do
            local spell = damageSignature[i]
            local spellInfo = ns.ApiCompat.GetSpellInfo(spell.spellId) or {}
            local name = spellInfo.name or string.format("Spell %d", spell.spellId)
            addLabel(string.format("  %d. %s — %s damage, %d hits, %.0f%% crit",
                i,
                name,
                Helpers.FormatNumber(spell.totalDamage or 0),
                spell.hitCount or 0,
                (spell.critRate or 0) * 100
            ), Theme.text, "GameFontHighlightSmall")
        end
    end

    -- Section 5: Build Comparison
    yPos = yPos - 6
    addLabel("Build Comparison vs This Spec", Theme.accent, "GameFontNormalLarge")
    local allBuilds = store and store.GetAllBuildsVsSpec and store:GetAllBuildsVsSpec(specId, buildHash) or {}
    if #allBuilds > 0 then
        for i, build in ipairs(allBuilds) do
            local marker = build.isCurrent and " (current)" or ""
            local color = build.isCurrent and Theme.accent or Theme.text
            local wrColor = build.winRate >= 0.5 and Theme.success or Theme.warning
            addLabel(string.format("  %d. Build %s%s — %.0f%% WR (%dW-%dL, %d fights, avg pressure %.1f)",
                i,
                build.buildHash or "—",
                marker,
                build.winRate * 100,
                build.wins or 0,
                build.losses or 0,
                build.fights or 0,
                build.avgPressure or 0
            ), wrColor, "GameFontHighlightSmall")
        end
        -- Check if a better build exists
        if #allBuilds > 1 and allBuilds[1] and not allBuilds[1].isCurrent then
            local best = allBuilds[1]
            local currentEntry = nil
            for _, b in ipairs(allBuilds) do
                if b.isCurrent then currentEntry = b; break end
            end
            if currentEntry and best.winRate > currentEntry.winRate + 0.15 then
                addLabel(string.format("  A better build has %.0f%% higher win rate vs this spec!",
                    (best.winRate - currentEntry.winRate) * 100
                ), Theme.warning, "GameFontHighlightSmall")
            end
        end
    else
        addLabel("Not enough build data yet (need 3+ fights).", Theme.textMuted, "GameFontHighlightSmall")
    end

    -- Section 6: Counter Guide
    yPos = yPos - 6
    addLabel("Counter Guide", Theme.accent, "GameFontNormalLarge")
    if guide then
        -- Threat tags
        if guide.threatTags and #guide.threatTags > 0 then
            addLabel("Threats: " .. table.concat(guide.threatTags, ", "), Theme.warning, "GameFontHighlightSmall")
        end

        -- CC families — guide.ccFamilies is an array of {spellId, family} objects.
        if guide.ccFamilies and #guide.ccFamilies > 0 then
            local families = {}
            local seenFam  = {}
            for _, entry in ipairs(guide.ccFamilies) do
                local familyName = type(entry) == "table" and entry.family or tostring(entry)
                if familyName and not seenFam[familyName] then
                    seenFam[familyName] = true
                    families[#families + 1] = familyName
                end
            end
            table.sort(families)
            addLabel("CC Families: " .. table.concat(families, ", "), Theme.textMuted, "GameFontHighlightSmall")
        end

        -- Recommended actions
        if guide.recommendedActions and #guide.recommendedActions > 0 then
            yPos = yPos - 4
            addLabel("Recommended Actions:", Theme.text)
            for _, action in ipairs(guide.recommendedActions) do
                addLabel("  " .. action, Theme.text, "GameFontHighlightSmall")
            end
        end
    else
        addLabel("No counter guide data available.", Theme.textMuted, "GameFontHighlightSmall")
    end

    ns.Widgets.SetCanvasHeight(self.canvas, math.abs(yPos) + 20)

    -- Update title to reflect selected spec
    self.title:SetText(string.format("Matchup Detail — %s", specName))
    self.caption:SetText(string.format("Detailed matchup analysis for %s %s.", classFile, specName))
end

ns.Addon:RegisterModule("MatchupDetailView", MatchupDetailView)
