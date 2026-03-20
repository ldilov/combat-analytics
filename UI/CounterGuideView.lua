local _, ns = ...

local Constants = ns.Constants
local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local CounterGuideView = {
    viewId = "counterguide",
    selectedSpecId = nil,
}

-- Ordered spec list grouped by class for the left panel.
local function buildSpecList()
    local archetypes = ns.StaticPvpData and ns.StaticPvpData.SPEC_ARCHETYPES or {}
    local byClass = {}
    for specId, data in pairs(archetypes) do
        local classFile = data.classFile or "UNKNOWN"
        byClass[classFile] = byClass[classFile] or {}
        byClass[classFile][#byClass[classFile] + 1] = {
            specId = specId,
            specName = data.specName or "Unknown",
            classFile = classFile,
            archetype = data.archetype,
        }
    end

    -- Sort specs within each class alphabetically.
    local classList = {}
    for classFile, specs in pairs(byClass) do
        table.sort(specs, function(a, b) return a.specName < b.specName end)
        classList[#classList + 1] = { classFile = classFile, specs = specs }
    end
    table.sort(classList, function(a, b) return a.classFile < b.classFile end)
    return classList
end

function CounterGuideView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Counter Guides", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Select a spec to see matchup data and counter advice.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Left panel: spec list.
    self.listShell, self.listScroll, self.listCanvas = ns.Widgets.CreateScrollCanvas(self.frame, 220, 400)
    self.listShell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.listShell:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 16, 16)

    -- Right panel: detail card.
    self.detailShell, self.detailScroll, self.detailCanvas = ns.Widgets.CreateScrollCanvas(self.frame, 540, 400)
    self.detailShell:SetPoint("TOPLEFT", self.listShell, "TOPRIGHT", 12, 0)
    self.detailShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.specButtons = {}
    self.detailElements = {}

    return self.frame
end

local function getSpecWinLoss(store, specId)
    if not store or not store.GetAggregateBuckets then return 0, 0 end
    local specBuckets = store:GetAggregateBuckets("specs")
    local specKey = tostring(specId)
    if not specBuckets or not specBuckets[specKey] then return 0, 0 end
    return specBuckets[specKey].wins or 0, specBuckets[specKey].losses or 0
end

function CounterGuideView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store and store:GetCurrentCharacterKey() or nil
    local strategyEngine = ns.Addon:GetModule("StrategyEngine")

    -- Build spec list in left panel.
    local classList = buildSpecList()

    -- Release old buttons.
    for _, btn in ipairs(self.specButtons) do
        btn:Hide()
    end
    self.specButtons = {}

    local yOffset = 0
    for _, classGroup in ipairs(classList) do
        -- Class header.
        local header = self.listCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        header:SetPoint("TOPLEFT", self.listCanvas, "TOPLEFT", 4, -yOffset)
        header:SetText(classGroup.classFile)
        if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classGroup.classFile] then
            local cc = RAID_CLASS_COLORS[classGroup.classFile]
            header:SetTextColor(cc.r, cc.g, cc.b, 1)
        else
            header:SetTextColor(unpack(Theme.textMuted))
        end
        yOffset = yOffset + 16

        for _, spec in ipairs(classGroup.specs) do
            local btn = CreateFrame("Button", nil, self.listCanvas)
            btn:SetSize(200, 20)
            btn:SetPoint("TOPLEFT", self.listCanvas, "TOPLEFT", 8, -yOffset)

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", btn, "LEFT", 0, 0)
            btn.label:SetTextColor(unpack(Theme.text))

            local wins, losses = getSpecWinLoss(store, spec.specId)
            local badge = ""
            if wins + losses > 0 then
                badge = string.format("  |cff00cc00%dW|r |cffcc0000%dL|r", wins, losses)
            end
            btn.label:SetText(spec.specName .. badge)

            btn:SetScript("OnClick", function()
                self.selectedSpecId = spec.specId
                self:RefreshDetail()
            end)
            btn:SetScript("OnEnter", function(self)
                self.label:SetTextColor(unpack(Theme.accent))
            end)
            btn:SetScript("OnLeave", function(self)
                self.label:SetTextColor(unpack(Theme.text))
            end)

            self.specButtons[#self.specButtons + 1] = btn
            yOffset = yOffset + 22
        end
        yOffset = yOffset + 6
    end

    ns.Widgets.SetCanvasHeight(self.listCanvas, yOffset + 20)

    -- Auto-select first spec if none selected.
    if not self.selectedSpecId and classList[1] and classList[1].specs[1] then
        self.selectedSpecId = classList[1].specs[1].specId
    end

    self:RefreshDetail()
end

function CounterGuideView:RefreshDetail()
    -- Clear old detail elements.
    for _, elem in ipairs(self.detailElements) do
        elem:Hide()
    end
    self.detailElements = {}

    if not self.selectedSpecId then
        local empty = self.detailCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", self.detailCanvas, "TOPLEFT", 8, -8)
        empty:SetTextColor(unpack(Theme.textMuted))
        empty:SetText("Select a spec from the list.")
        self.detailElements[#self.detailElements + 1] = empty
        ns.Widgets.SetCanvasHeight(self.detailCanvas, 60)
        return
    end

    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store and store:GetCurrentCharacterKey() or nil
    local snapshot = ns.Addon.runtime and ns.Addon.runtime.playerSnapshot or nil
    local buildHash = snapshot and snapshot.buildHash or nil
    local strategyEngine = ns.Addon:GetModule("StrategyEngine")
    local guide = strategyEngine and strategyEngine.GetCounterGuide
        and strategyEngine.GetCounterGuide(self.selectedSpecId, buildHash, characterKey) or nil

    if not guide then
        local noData = self.detailCanvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        noData:SetPoint("TOPLEFT", self.detailCanvas, "TOPLEFT", 8, -8)
        noData:SetTextColor(unpack(Theme.textMuted))
        noData:SetText("No data available for this spec.")
        self.detailElements[#self.detailElements + 1] = noData
        ns.Widgets.SetCanvasHeight(self.detailCanvas, 60)
        return
    end

    local yPos = -8
    local function addLabel(text, color, font)
        local fs = self.detailCanvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
        fs:SetPoint("TOPLEFT", self.detailCanvas, "TOPLEFT", 8, yPos)
        fs:SetPoint("RIGHT", self.detailCanvas, "RIGHT", -8, 0)
        fs:SetTextColor(unpack(color or Theme.text))
        fs:SetText(text)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        self.detailElements[#self.detailElements + 1] = fs
        yPos = yPos - (fs:GetStringHeight() + 6)
        return fs
    end

    -- Spec header.
    local specName = guide.specName or "Unknown"
    local classFile = guide.classFile or ""
    addLabel(string.format("%s %s", classFile, specName), Theme.accent, "GameFontNormalLarge")

    -- Archetype + range.
    addLabel(string.format("Archetype: %s  |  Range: %s", guide.archetypeLabel or "—", guide.rangeBucket or "—"), Theme.textMuted, "GameFontHighlightSmall")

    -- Threat tags.
    if guide.threatTags and #guide.threatTags > 0 then
        addLabel("Threats: " .. table.concat(guide.threatTags, ", "), Theme.warning, "GameFontHighlightSmall")
    end

    -- CC families.
    if guide.ccFamilies and next(guide.ccFamilies) then
        local families = {}
        for family in pairs(guide.ccFamilies) do
            families[#families + 1] = family
        end
        table.sort(families)
        addLabel("CC Families: " .. table.concat(families, ", "), Theme.textMuted, "GameFontHighlightSmall")
    end

    -- Win rate.
    if guide.historicalWinRate then
        local wrColor = guide.historicalWinRate >= 0.5 and Theme.success or Theme.warning
        addLabel(string.format("Win Rate: %.0f%% (%d fights)", guide.historicalWinRate * 100, guide.historicalFights or 0), wrColor)
    else
        addLabel("Win Rate: No data yet", Theme.textMuted, "GameFontHighlightSmall")
    end

    -- Best build.
    if guide.bestBuildVsSpec then
        addLabel(string.format("Best Build: %s (%.0f%% WR, %d fights)",
            guide.bestBuildVsSpec.buildHash or "—",
            (guide.bestBuildVsSpec.winRate or 0) * 100,
            guide.bestBuildVsSpec.fights or 0
        ), Theme.accentSoft, "GameFontHighlightSmall")
    end

    -- Top opponent spells.
    if guide.topSpellsFromOpponent and #guide.topSpellsFromOpponent > 0 then
        yPos = yPos - 6
        addLabel("Top Opponent Spells:", Theme.text)
        for i, spell in ipairs(guide.topSpellsFromOpponent) do
            local spellInfo = ns.ApiCompat.GetSpellInfo(spell.spellId) or {}
            local name = spellInfo.name or string.format("Spell %d", spell.spellId)
            addLabel(string.format("  %d. %s — %s damage (%d hits)", i, name,
                Helpers.FormatNumber(spell.totalDamage or 0),
                spell.hitCount or 0
            ), Theme.textMuted, "GameFontHighlightSmall")
        end
    end

    -- Recommended actions.
    if guide.recommendedActions and #guide.recommendedActions > 0 then
        yPos = yPos - 6
        addLabel("Recommended Actions:", Theme.accent)
        for _, action in ipairs(guide.recommendedActions) do
            addLabel("  • " .. action, Theme.text, "GameFontHighlightSmall")
        end
    end

    ns.Widgets.SetCanvasHeight(self.detailCanvas, math.abs(yPos) + 20)
end

ns.Addon:RegisterModule("CounterGuideView", CounterGuideView)
