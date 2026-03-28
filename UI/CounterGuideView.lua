local _, ns = ...

local ApiCompat = ns.ApiCompat
local Helpers   = ns.Helpers
local Theme     = ns.Widgets.THEME

local CounterGuideView = {
    viewId          = "counterguide",
    selectedSpecId  = nil,
    buildFilterMode = "all", -- "all" | "current" (T119)
}

-- ─────────────────────────────────────────────────────────────────────────────
-- CC-family colour palette and display labels
-- ─────────────────────────────────────────────────────────────────────────────
local CC_COLORS = {
    stun         = { 0.95, 0.40, 0.10, 1.0 },
    incapacitate = { 0.95, 0.75, 0.10, 1.0 },
    polymorph    = { 0.45, 0.45, 1.00, 1.0 },
    root         = { 0.25, 0.85, 0.25, 1.0 },
    fear         = { 0.70, 0.20, 0.85, 1.0 },
    silence      = { 0.60, 0.60, 0.60, 1.0 },
    disorient    = { 0.90, 0.55, 0.15, 1.0 },
    sleep        = { 0.20, 0.65, 0.90, 1.0 },
    disarm       = { 0.80, 0.50, 0.20, 1.0 },
    knockback    = { 0.55, 0.90, 0.40, 1.0 },
}

local CC_LABEL = {
    stun         = "Stun",
    incapacitate = "Incap",
    polymorph    = "Poly",
    root         = "Root",
    fear         = "Fear",
    silence      = "Silence",
    disorient    = "Disorient",
    sleep        = "Sleep",
    disarm       = "Disarm",
    knockback    = "Knockback",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Threat-bar color thresholds: green < 0.45, yellow 0.45–0.70, red > 0.70
-- ─────────────────────────────────────────────────────────────────────────────
local THREAT_THRESHOLDS = {
    { value = 0.45, color = Theme.warning },
    { value = 0.70, color = { 0.90, 0.20, 0.15, 1.0 } },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Maps fight count to a SESSION_CONFIDENCE key for the ConfidencePill widget
-- ─────────────────────────────────────────────────────────────────────────────
local function fightCountToConfidence(fights)
    if fights > 10 then
        return "state_plus_damage_meter"
    elseif fights >= 3 then
        return "partial_roster"
    else
        return "estimated"
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function buildSpecList()
    local archetypes = ns.StaticPvpData and ns.StaticPvpData.SPEC_ARCHETYPES or {}
    local byClass    = {}
    for specId, data in pairs(archetypes) do
        local cf = data.classFile or "UNKNOWN"
        byClass[cf] = byClass[cf] or {}
        byClass[cf][#byClass[cf] + 1] = {
            specId    = specId,
            specName  = data.specName or "Unknown",
            classFile = cf,
            archetype = data.archetype,
        }
    end
    local classList = {}
    for cf, specs in pairs(byClass) do
        table.sort(specs, function(a, b) return a.specName < b.specName end)
        classList[#classList + 1] = { classFile = cf, specs = specs }
    end
    table.sort(classList, function(a, b) return a.classFile < b.classFile end)
    return classList
end

local function getSpecWinLoss(store, specId)
    if not store or not store.GetAggregateBucketByKey then return 0, 0 end
    local bucket = store:GetAggregateBucketByKey("specs", specId)
    if not bucket then return 0, 0 end
    return bucket.wins or 0, bucket.losses or 0
end

local function hideElements(pool)
    for _, e in ipairs(pool) do
        if e and e.Hide then e:Hide() end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build (frame construction)
-- ─────────────────────────────────────────────────────────────────────────────
function CounterGuideView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title   = ns.Widgets.CreateSectionTitle(self.frame, "Counter Guides", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame,
        "Select a spec to see threat assessment, CC families, key spells, and counter strategy.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.listShell, self.listScroll, self.listCanvas = ns.Widgets.CreateScrollCanvas(self.frame, 220, 400)
    self.listShell:SetPoint("TOPLEFT",    self.caption, "BOTTOMLEFT", 0, -12)
    self.listShell:SetPoint("BOTTOMLEFT", self.frame,   "BOTTOMLEFT", 16, 16)

    self.detailShell, self.detailScroll, self.detailCanvas = ns.Widgets.CreateScrollCanvas(self.frame, 540, 400)
    self.detailShell:SetPoint("TOPLEFT",     self.listShell, "TOPRIGHT",    12, 0)
    self.detailShell:SetPoint("BOTTOMRIGHT", self.frame,     "BOTTOMRIGHT", -16, 16)

    self.specButtons    = {}
    self.detailElements = {}

    return self.frame
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Refresh — spec list (left panel)
-- ─────────────────────────────────────────────────────────────────────────────
function CounterGuideView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local classList = buildSpecList()

    for _, btn in ipairs(self.specButtons) do btn:Hide() end
    self.specButtons = {}

    local yOffset = 0
    for _, classGroup in ipairs(classList) do
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
            btn:SetSize(200, 22)
            btn:SetPoint("TOPLEFT", self.listCanvas, "TOPLEFT", 8, -yOffset)

            -- Small spec icon
            local iconTex = btn:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(16, 16)
            iconTex:SetPoint("LEFT", btn, "LEFT", 0, 0)
            local _, _, _, iconId = ApiCompat.GetSpecializationInfoByID(spec.specId)
            if iconId then
                iconTex:SetTexture(iconId)
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            else
                iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            end

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
            btn.label:SetTextColor(unpack(Theme.text))

            local wins, losses = getSpecWinLoss(store, spec.specId)
            local badge = ""
            if wins + losses > 0 then
                badge = string.format("  |cff00cc00%dW|r|cffcc0000%dL|r", wins, losses)
            end
            btn.label:SetText(spec.specName .. badge)

            local specId = spec.specId
            btn:SetScript("OnClick",  function() self.selectedSpecId = specId; self:RefreshDetail() end)
            btn:SetScript("OnEnter",  function(b) b.label:SetTextColor(unpack(Theme.accent)) end)
            btn:SetScript("OnLeave",  function(b) b.label:SetTextColor(unpack(Theme.text)) end)

            self.specButtons[#self.specButtons + 1] = btn
            yOffset = yOffset + 24
        end
        yOffset = yOffset + 6
    end

    ns.Widgets.SetCanvasHeight(self.listCanvas, yOffset + 20)

    if not self.selectedSpecId and classList[1] and classList[1].specs[1] then
        self.selectedSpecId = classList[1].specs[1].specId
    end
    self:RefreshDetail()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RefreshDetail — right panel
-- ─────────────────────────────────────────────────────────────────────────────
function CounterGuideView:RefreshDetail()
    hideElements(self.detailElements)
    self.detailElements = {}

    local canvas = self.detailCanvas
    local el     = self.detailElements

    if not self.selectedSpecId then
        local e = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        e:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -8)
        e:SetTextColor(unpack(Theme.textMuted))
        e:SetText("Select a spec from the list.")
        el[#el + 1] = e
        ns.Widgets.SetCanvasHeight(canvas, 60)
        return
    end

    local store          = ns.Addon:GetModule("CombatStore")
    local snapshot       = ns.Addon:GetLatestPlayerSnapshot()
    local buildHash      = snapshot and snapshot.buildHash or nil
    local characterKey   = store and store:GetCurrentCharacterKey() or nil
    local strategyEngine = ns.Addon:GetModule("StrategyEngine")

    local guide = strategyEngine and strategyEngine.GetCounterGuide
        and strategyEngine.GetCounterGuide(self.selectedSpecId, buildHash, characterKey) or nil

    if not guide then
        local e = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        e:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -8)
        e:SetTextColor(unpack(Theme.textMuted))
        e:SetText("No guide data available for this spec.")
        el[#el + 1] = e
        ns.Widgets.SetCanvasHeight(canvas, 60)
        return
    end

    local yPos    = -8
    local PAD     = 8
    local WIDTH   = 490
    local BAR_W   = WIDTH - 90
    local BAR_H   = 14

    -- ── layout helpers ───────────────────────────────────────────────────────
    local function addText(text, color, font, indent)
        indent = indent or PAD
        local fs = canvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", indent, yPos)
        fs:SetWidth(WIDTH - indent)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetTextColor(unpack(color or Theme.text))
        fs:SetText(text)
        el[#el + 1] = fs
        yPos = yPos - (fs:GetStringHeight() + 6)
        return fs
    end

    local function addRule(extraTop)
        yPos = yPos - (extraTop or 4)
        local line = canvas:CreateTexture(nil, "BACKGROUND")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT",  canvas, "TOPLEFT",  PAD, yPos)
        line:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -PAD, yPos)
        line:SetColorTexture(Theme.border[1], Theme.border[2], Theme.border[3], 0.4)
        el[#el + 1] = line
        yPos = yPos - 6
    end

    local function addSection(text)
        addRule()
        addText(text, Theme.accent, "GameFontNormal")
    end

    -- ── SPEC HEADER ──────────────────────────────────────────────────────────
    local specId    = guide.specId or self.selectedSpecId
    local specName  = guide.specName or "Unknown"
    local classFile = guide.classFile or ""
    local ICON_S    = 40

    local iconFrame = CreateFrame("Frame", nil, canvas)
    iconFrame:SetSize(ICON_S, ICON_S)
    iconFrame:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
    iconFrame:SetFrameLevel(canvas:GetFrameLevel() + 1)

    local iconBg = iconFrame:CreateTexture(nil, "BACKGROUND")
    iconBg:SetAllPoints()
    iconBg:SetColorTexture(0.08, 0.08, 0.08, 1)

    local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    do
        local _, _, _, iconId = ApiCompat.GetSpecializationInfoByID(specId)
        if iconId then
            iconTex:SetTexture(iconId)
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
    end
    el[#el + 1] = iconFrame

    -- Spec name (class-coloured)
    local nameFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameFs:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 8, -2)
    nameFs:SetText(specName)
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        nameFs:SetTextColor(cc.r, cc.g, cc.b, 1)
    else
        nameFs:SetTextColor(unpack(Theme.text))
    end
    el[#el + 1] = nameFs

    local subFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subFs:SetPoint("TOPLEFT", nameFs, "BOTTOMLEFT", 0, -2)
    subFs:SetTextColor(unpack(Theme.textMuted))
    local rangePretty = guide.rangeBucket and
        (guide.rangeBucket:sub(1,1):upper() .. guide.rangeBucket:sub(2)) or "—"
    subFs:SetText(string.format("%s  ·  %s  ·  %s",
        classFile, guide.archetypeLabel or "—", rangePretty))
    el[#el + 1] = subFs

    yPos = yPos - (ICON_S + 12)

    -- ── THREAT GAUGE (T078.1 — CreateGauge replaces manual bar) ─────────────
    addRule(2)

    local fights       = guide.historicalFights or 0
    local threatScore, isEstimated
    if fights >= 3 and guide.historicalWinRate then
        threatScore = 1.0 - guide.historicalWinRate
        isEstimated = false
    elseif guide.baselineThreatScore then
        threatScore = guide.baselineThreatScore
        isEstimated = true
    else
        threatScore = 0.5
        isEstimated = true
    end

    local thrLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    thrLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
    thrLabel:SetTextColor(unpack(Theme.textMuted))
    thrLabel:SetText("Threat Level")
    el[#el + 1] = thrLabel

    local thrVal = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    thrVal:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + BAR_W + 6, yPos)
    if isEstimated then
        thrVal:SetText(string.format("~%.0f%%  est.", threatScore * 100))
        thrVal:SetTextColor(unpack(Theme.textMuted))
    else
        thrVal:SetText(string.format("%.0f%%", threatScore * 100))
        thrVal:SetTextColor(unpack(Theme.text))
    end
    el[#el + 1] = thrVal
    yPos = yPos - 18

    do
        -- Pick fill color by threshold: green < 0.45, yellow 0.45-0.70, red > 0.70
        local tr, tg, tb = 0.25, 0.80, 0.35
        if threatScore >= 0.70 then
            tr, tg, tb = 0.90, 0.20, 0.15
        elseif threatScore >= 0.45 then
            tr, tg, tb = 0.90, 0.65, 0.10
        end
        local gaugeAlpha = isEstimated and 0.45 or 0.85

        local threatGauge = ns.Widgets.CreateGauge(
            canvas,
            threatScore,            -- value
            0,                      -- min
            1,                      -- max
            THREAT_THRESHOLDS,      -- threshold markers at 0.45 and 0.70
            { tr, tg, tb, gaugeAlpha }, -- fill color
            BAR_W,                  -- width
            BAR_H                   -- height
        )
        threatGauge:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
        el[#el + 1] = threatGauge
        yPos = yPos - (BAR_H + 8)
    end

    -- ── WIN-RATE GAUGE (T078.2 — CreateGauge replaces manual bar) ───────────
    local wrLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wrLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
    wrLabel:SetTextColor(unpack(Theme.textMuted))
    wrLabel:SetText("Your Win Rate")
    el[#el + 1] = wrLabel

    local wrVal = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wrVal:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + BAR_W + 6, yPos)
    if guide.historicalWinRate and fights >= 3 then
        local wr = guide.historicalWinRate
        wrVal:SetText(string.format("%.0f%%  (%d)", wr * 100, fights))
        wrVal:SetTextColor(unpack(wr >= 0.5 and Theme.success or Theme.warning))
    else
        wrVal:SetText(fights > 0 and string.format("%d fight%s", fights, fights == 1 and "" or "s") or "No data")
        wrVal:SetTextColor(unpack(Theme.textMuted))
    end
    el[#el + 1] = wrVal
    yPos = yPos - 18

    do
        local wr = guide.historicalWinRate
        if wr and fights >= 3 then
            local wrR = wr >= 0.5 and 0.25 or 0.90
            local wrG = wr >= 0.5 and 0.80 or 0.65

            local wrGauge = ns.Widgets.CreateGauge(
                canvas,
                wr,             -- value
                0,              -- min
                1,              -- max
                { { value = 0.5, color = Theme.textMuted } }, -- 50% midpoint marker
                { wrR, wrG, 0.10, 0.85 },  -- fill color
                BAR_W,          -- width
                BAR_H           -- height
            )
            wrGauge:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
            el[#el + 1] = wrGauge
        else
            -- Empty gauge for no-data state
            local wrGauge = ns.Widgets.CreateGauge(
                canvas,
                0,              -- value
                0, 1, nil,      -- min, max, no thresholds
                Theme.barShell, -- invisible fill
                BAR_W, BAR_H
            )
            wrGauge:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
            el[#el + 1] = wrGauge
        end
        yPos = yPos - (BAR_H + 4)
    end

    -- ── WIN-RATE CONFIDENCE PILL (T078.3) ───────────────────────────────────
    do
        local wrConfidence = fightCountToConfidence(fights)
        local confPill = ns.Widgets.CreateConfidencePill(canvas, wrConfidence)
        confPill:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
        el[#el + 1] = confPill
        yPos = yPos - 24
    end

    -- ── THREAT TAGS ──────────────────────────────────────────────────────────
    if guide.threatTags and #guide.threatTags > 0 then
        addSection("Threat Tags")
        local tx = PAD
        for _, tag in ipairs(guide.threatTags) do
            local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetText("  " .. tag .. "  ")
            fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", tx, yPos)
            fs:SetTextColor(unpack(Theme.warning))
            el[#el + 1] = fs
            local tw = fs:GetStringWidth() + 4
            if tx + tw > WIDTH then
                yPos = yPos - 20
                tx = PAD
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", tx, yPos)
            end
            tx = tx + tw + 6
        end
        yPos = yPos - 22
    end

    -- ── DR FAMILY VISUALIZATION ───────────────────────────────────────────────
    if guide.ccFamilies and next(guide.ccFamilies) then
        addSection("CC Families  (DR Groups)")

        -- guide.ccFamilies is an array of {spellId, family} objects; extract
        -- unique family name strings (same pattern used in SuggestionsView).
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

        local TAG_H   = 20
        local TAG_PAD = 8
        local tx      = PAD

        for _, family in ipairs(families) do
            local label  = CC_LABEL[family] or family
            local colors = CC_COLORS[family] or { 0.7, 0.7, 0.7, 1.0 }
            local approxW = #label * 7 + TAG_PAD * 2

            if tx + approxW > WIDTH then
                yPos = yPos - (TAG_H + 4)
                tx = PAD
            end

            -- Pill background
            local pill = canvas:CreateTexture(nil, "BACKGROUND")
            pill:SetSize(approxW, TAG_H)
            pill:SetPoint("TOPLEFT", canvas, "TOPLEFT", tx, yPos)
            pill:SetColorTexture(
                colors[1] * 0.20, colors[2] * 0.20, colors[3] * 0.20, 0.95)
            el[#el + 1] = pill

            -- Pill text
            local pillFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pillFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", tx + TAG_PAD, yPos - 3)
            pillFs:SetText(label)
            pillFs:SetTextColor(colors[1], colors[2], colors[3], 1.0)
            el[#el + 1] = pillFs

            tx = tx + approxW + 6
        end
        yPos = yPos - (TAG_H + 10)
    end

    -- ── KEY SPELLS TO WATCH (T078.4 — CreateSpellRow with damage fill bars) ─
    if guide.topSpellsFromOpponent and #guide.topSpellsFromOpponent > 0 then
        addSection("Key Spells to Watch")

        local maxSpells = math.min(8, #guide.topSpellsFromOpponent)
        local SPELL_ROW_W = WIDTH - PAD
        local SPELL_ROW_H = 56

        -- Determine the maximum damage across all listed spells for fill scaling
        local maxDamage = 0
        for i = 1, maxSpells do
            local dmg = guide.topSpellsFromOpponent[i].totalDamage or 0
            if dmg > maxDamage then maxDamage = dmg end
        end
        if maxDamage == 0 then maxDamage = 1 end

        for i = 1, maxSpells do
            local spell     = guide.topSpellsFromOpponent[i]
            local spellInfo = ApiCompat.GetSpellInfo(spell.spellId)
            local spellName = spellInfo and spellInfo.name or ("Spell " .. spell.spellId)
            local spellIcon = spellInfo and spellInfo.iconID or 134400
            local totalDmg  = spell.totalDamage or 0
            local hitCount  = spell.hitCount or 0
            local fillShare = totalDmg / maxDamage

            local detailStr = string.format("%s  (%d hits)",
                Helpers.FormatNumber(totalDmg), hitCount)

            local row = ns.Widgets.CreateSpellRow(canvas, SPELL_ROW_W, SPELL_ROW_H)
            row:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
            row:SetData(spellIcon, spellName, detailStr, Helpers.FormatNumber(totalDmg), fillShare)
            el[#el + 1] = row

            yPos = yPos - (SPELL_ROW_H + 4)
        end

        yPos = yPos - 4
    end

    -- ── COUNTER STRATEGY CARDS ────────────────────────────────────────────────
    if guide.recommendedActions and #guide.recommendedActions > 0 then
        addSection("Counter Strategy")
        for _, action in ipairs(guide.recommendedActions) do
            local cardBg = canvas:CreateTexture(nil, "BACKGROUND")
            cardBg:SetHeight(24)
            cardBg:SetPoint("TOPLEFT",  canvas, "TOPLEFT",  PAD, yPos)
            cardBg:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -PAD, yPos)
            cardBg:SetColorTexture(
                Theme.panel[1] + 0.04, Theme.panel[2] + 0.04, Theme.panel[3] + 0.04, 0.75)
            el[#el + 1] = cardBg

            local bullet = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            bullet:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD + 6, yPos - 4)
            bullet:SetPoint("RIGHT",   canvas, "RIGHT",  -PAD, 0)
            bullet:SetJustifyH("LEFT")
            bullet:SetWordWrap(true)
            bullet:SetTextColor(unpack(Theme.text))
            bullet:SetText("▸  " .. action)
            el[#el + 1] = bullet
            yPos = yPos - (bullet:GetStringHeight() + 10)
        end
    end

    -- ── INTERRUPT PRIORITY + SAFE WINDOWS ───────────────────────────────────
    if guide.interruptPriority and #guide.interruptPriority > 0 then
        addSection("Interrupt Priority")
        for i, spell in ipairs(guide.interruptPriority) do
            addText(string.format("%d.  %s", i, spell), Theme.text, "GameFontHighlightSmall", PAD + 4)
        end
    end

    if guide.safeWindows and #guide.safeWindows > 0 then
        addSection("Safe Offensive Windows")
        for _, w in ipairs(guide.safeWindows) do
            addText("✦  " .. w, Theme.success, "GameFontHighlightSmall", PAD + 4)
        end
    end

    -- ── MURLOK GLOBAL WIN RATE ───────────────────────────────────────────────
    if guide.murlokWinRate then
        addRule()
        addText(string.format("Global win rate (murlok.io): %.1f%%", guide.murlokWinRate * 100),
            Theme.textMuted, "GameFontHighlightSmall")
    end

    -- ── BEST BUILD VS THIS SPEC (T078.5 — DeltaBadge for WR difference) ─────
    if guide.bestBuildVsSpec then
        addSection("Best Build vs This Spec")
        local b = guide.bestBuildVsSpec

        addText(string.format("Build %s  →  %.0f%% WR  (%d fights)",
            b.buildHash or "—", (b.winRate or 0) * 100, b.fights or 0),
            Theme.accentSoft, "GameFontHighlightSmall")

        -- Show a DeltaBadge if the recommended build differs from current build
        -- and the WR delta can be computed.
        if buildHash and b.buildHash and b.buildHash ~= buildHash and b.winRate then
            local currentBuildWR = guide.historicalWinRate or 0
            local delta = (b.winRate - currentBuildWR) * 100

            local deltaBadge = ns.Widgets.CreateDeltaBadge(canvas, delta, "%.0f%% WR")
            deltaBadge:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
            el[#el + 1] = deltaBadge

            local noteFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            noteFs:SetPoint("LEFT", deltaBadge, "RIGHT", 6, 0)
            noteFs:SetWidth(WIDTH - PAD - 100)
            noteFs:SetJustifyH("LEFT")
            noteFs:SetTextColor(unpack(Theme.textMuted))
            noteFs:SetText("vs your current build")
            el[#el + 1] = noteFs

            yPos = yPos - 24
        end
    end

    -- ── DATA GAP NOTICE ───────────────────────────────────────────────────────
    if fights < 3 then
        addRule()
        addText(
            "Not enough match history vs this spec yet — play more games to unlock personalised stats.",
            Theme.textMuted, "GameFontHighlightSmall")
    end

    -- ── MATCHUP MEMORY (T118 + T119) ────────────────────────────────────────
    do
        local ok, memSvc = pcall(function()
            return ns.Addon:GetModule("MatchupMemoryService")
        end)
        if ok and memSvc and memSvc.BuildMatchupMemoryCard then
            local db = store and store:GetDB() or nil
            local allSessions = {}
            if db and db.combats and db.combats.byId then
                for _, sid in ipairs(db.combats.order or {}) do
                    local s = db.combats.byId[sid]
                    if s then allSessions[#allSessions + 1] = s end
                end
            end

            -- T119: build filter toggle pills
            local filterHash = nil
            if buildHash then
                local activeBg  = Theme.accent
                local passiveBg = Theme.panel

                local allPill = ns.Widgets.CreatePill(canvas, 80, 18)
                allPill:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
                local curPill = ns.Widgets.CreatePill(canvas, 100, 18)
                curPill:SetPoint("LEFT", allPill, "RIGHT", 4, 0)

                local function refreshPills()
                    local isAll = (self.buildFilterMode == "all")
                    allPill:SetData("All Builds", isAll and Theme.text or Theme.textMuted,
                        isAll and activeBg or passiveBg)
                    curPill:SetData("Current Build", (not isAll) and Theme.text or Theme.textMuted,
                        (not isAll) and activeBg or passiveBg)
                end
                refreshPills()

                allPill:SetScript("OnMouseUp", function()
                    self.buildFilterMode = "all"; self:RefreshDetail()
                end)
                curPill:SetScript("OnMouseUp", function()
                    self.buildFilterMode = "current"; self:RefreshDetail()
                end)
                el[#el + 1] = allPill
                el[#el + 1] = curPill
                yPos = yPos - 26

                if self.buildFilterMode == "current" then
                    filterHash = buildHash
                end
            end

            local ok2, card = pcall(function()
                return memSvc:BuildMatchupMemoryCard(self.selectedSpecId, allSessions, filterHash)
            end)
            if ok2 and card then
                addSection("Matchup Memory")

                if not card.insufficientData then
                    -- Death patterns (top 3)
                    if card.commonDeathPatterns and #card.commonDeathPatterns > 0 then
                        addText("Common Death Patterns:", Theme.textMuted, "GameFontHighlightSmall")
                        for i, dp in ipairs(card.commonDeathPatterns) do
                            local label = dp.pattern or "unknown"
                            label = label:gsub("|", " / ")
                            addText(string.format("%d.  %s  (%dx)", i, label, dp.count or 0),
                                Theme.text, "GameFontHighlightSmall", PAD + 4)
                        end
                    end

                    -- Average first go timing
                    if card.averageFirstGoTiming then
                        addText(string.format("Avg First Go: %.1fs", card.averageFirstGoTiming),
                            Theme.accent, "GameFontHighlightSmall")
                    end

                    -- Best build DeltaBadge
                    if card.bestBuildHash and card.bestBuildWR then
                        local currentWR = card.winRate or 0
                        local delta = (card.bestBuildWR - currentWR) * 100
                        local deltaBadge = ns.Widgets.CreateDeltaBadge(canvas, delta, "%.0f%% WR")
                        deltaBadge:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
                        el[#el + 1] = deltaBadge

                        local buildFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        buildFs:SetPoint("LEFT", deltaBadge, "RIGHT", 6, 0)
                        buildFs:SetTextColor(unpack(Theme.textMuted))
                        buildFs:SetText(string.format("Best build %s (%.0f%% WR)",
                            tostring(card.bestBuildHash):sub(1, 8), card.bestBuildWR * 100))
                        el[#el + 1] = buildFs
                        yPos = yPos - 24
                    end

                    -- Top danger spells
                    if card.topDangerSpells and #card.topDangerSpells > 0 then
                        addText("Top Danger Spells:", Theme.textMuted, "GameFontHighlightSmall")
                        for _, ds in ipairs(card.topDangerSpells) do
                            addText(string.format("  %s  (%dx)", ds.spellName or "?", ds.count or 0),
                                Theme.warning, "GameFontHighlightSmall", PAD + 4)
                        end
                    end

                    -- Recent trend pill
                    if card.recentTrend and card.recentTrend ~= "insufficient_data" then
                        local trendColors = {
                            improving = Theme.success,
                            declining = { 0.90, 0.20, 0.15, 1.0 },
                            stable    = Theme.textMuted,
                        }
                        local trendLabels = {
                            improving = "Improving",
                            declining = "Declining",
                            stable    = "Stable",
                        }
                        local col = trendColors[card.recentTrend] or Theme.textMuted
                        local pill = ns.Widgets.CreatePill(canvas, 80, 18, col)
                        pill:SetData(trendLabels[card.recentTrend] or card.recentTrend)
                        pill:SetPoint("TOPLEFT", canvas, "TOPLEFT", PAD, yPos)
                        el[#el + 1] = pill
                        yPos = yPos - 26
                    end
                else
                    -- Insufficient data state
                    addText(string.format("Building profile — %d more game%s needed",
                        card.neededSessions or 0,
                        (card.neededSessions or 0) == 1 and "" or "s"),
                        Theme.textMuted, "GameFontHighlightSmall")
                    if card.fallbackAdvice then
                        local fa = card.fallbackAdvice
                        if fa.playStyle then
                            addText(fa.playStyle, Theme.textMuted, "GameFontHighlightSmall", PAD + 4)
                        elseif fa.archetype then
                            addText("Archetype: " .. fa.archetype, Theme.textMuted, "GameFontHighlightSmall", PAD + 4)
                        end
                    end
                end
            end
        end
    end

    ns.Widgets.SetCanvasHeight(canvas, math.abs(yPos) + 30)
end

ns.Addon:RegisterModule("CounterGuideView", CounterGuideView)
