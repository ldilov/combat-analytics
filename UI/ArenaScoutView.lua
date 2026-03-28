local _, ns = ...

local Helpers   = ns.Helpers
local ApiCompat = ns.ApiCompat
local Theme     = ns.Widgets.THEME

-- ---------------------------------------------------------------------------
-- ArenaScoutView (T086 + T087)
-- Floating overlay during arena prep phase. Shows:
--   - Scout card: enemy roster, comp archetype, WR bars, threat spells
--   - Adaptation card: Solo Shuffle between-round tactical advice
-- ---------------------------------------------------------------------------

local ArenaScoutView = {}

-- Layout constants
local FRAME_WIDTH        = 350
local SCOUT_BASE_HEIGHT  = 400
local ADAPT_SECTION_H    = 180
local PAD                = 12
local INNER_WIDTH        = FRAME_WIDTH - PAD * 2
local ENEMY_ROW_HEIGHT   = 72
local PILL_H             = 18
local BAR_HEIGHT         = 10
local SPACING            = 6

-- Healer pressure pill color palette
local HEALER_PRESSURE_COLORS = {
    high   = { bg = Theme.severityHigh,   border = Theme.warning },
    medium = { bg = Theme.severityMedium,  border = Theme.warning },
    low    = { bg = Theme.severityLow,     border = Theme.borderStrong },
    none   = { bg = Theme.panelAlt,        border = Theme.border },
}

-- Confidence pill label mapping
local CONFIDENCE_LABELS = {
    prep    = "Prep Data",
    inspect = "Inspected",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Get class color from the WoW global, with a safe fallback.
local function classColor(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        return cc.r, cc.g, cc.b, 1
    end
    return Theme.text[1], Theme.text[2], Theme.text[3], Theme.text[4] or 1
end

--- Format win rate for display. Returns text and color table.
local function formatWR(wr, fights)
    if not wr or (fights or 0) == 0 then
        return "no prior data", Theme.textMuted
    end
    local pct = wr * 100
    local color = pct >= 50 and Theme.success or Theme.warning
    return string.format("%.0f%% (%d)", pct, fights), color
end

--- Resolve a spell name from a watchFor entry.
local function resolveSpellName(entry)
    if not entry or not entry.spellId then return nil end
    local info = ApiCompat.GetSpellInfo(entry.spellId)
    return info and info.name or nil
end

-- ---------------------------------------------------------------------------
-- T086: Build — frame construction
-- ---------------------------------------------------------------------------

function ArenaScoutView:Build()
    if self.frame then return self.frame end

    -- Main floating frame
    local frame = CreateFrame("Frame", "CombatAnalyticsArenaScout", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, SCOUT_BASE_HEIGHT)
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    ns.Widgets.ApplyBackdrop(frame, Theme.background, Theme.borderStrong)

    -- Title bar
    self.titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    self.titleBar:SetHeight(28)
    self.titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    self.titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    ns.Widgets.ApplyBackdrop(self.titleBar, Theme.header, Theme.border)

    self.titleText = self.titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.titleText:SetPoint("LEFT", self.titleBar, "LEFT", PAD, 0)
    self.titleText:SetText("Arena Scout")
    self.titleText:SetTextColor(unpack(Theme.accent))

    -- Close button
    local closeBtn = CreateFrame("Button", nil, self.titleBar)
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("RIGHT", self.titleBar, "RIGHT", -8, 0)
    closeBtn.text = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeBtn.text:SetPoint("CENTER")
    closeBtn.text:SetText("x")
    closeBtn.text:SetTextColor(unpack(Theme.textMuted))
    closeBtn:SetScript("OnClick", function() self:Hide() end)
    closeBtn:SetScript("OnEnter", function(b) b.text:SetTextColor(unpack(Theme.warning)) end)
    closeBtn:SetScript("OnLeave", function(b) b.text:SetTextColor(unpack(Theme.textMuted)) end)

    -- Comp archetype pill (top section)
    self.compPill = ns.Widgets.CreatePill(frame, 140, PILL_H + 2, Theme.accentSoft, Theme.borderStrong)
    self.compPill:SetPoint("TOPLEFT", self.titleBar, "BOTTOMLEFT", PAD, -SPACING)

    -- Overall WR text
    self.overallWRText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.overallWRText:SetPoint("LEFT", self.compPill, "RIGHT", 8, 0)
    self.overallWRText:SetTextColor(unpack(Theme.textMuted))

    -- Scroll area for enemy rows
    self.scrollShell, self.scrollFrame, self.scrollCanvas = ns.Widgets.CreateScrollCanvas(
        frame, INNER_WIDTH, SCOUT_BASE_HEIGHT - 80
    )
    self.scrollShell:SetPoint("TOPLEFT", self.compPill, "BOTTOMLEFT", 0, -SPACING)
    self.scrollShell:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)

    -- Pre-allocate enemy row pool (up to 5 enemies for Solo Shuffle)
    self.enemyRows = {}
    for i = 1, 5 do
        self.enemyRows[i] = self:CreateEnemyRow(self.scrollCanvas, i)
    end

    -- Adaptation section (initially hidden)
    self.adaptFrame = CreateFrame("Frame", nil, self.scrollCanvas, "BackdropTemplate")
    self.adaptFrame:SetSize(INNER_WIDTH - 20, ADAPT_SECTION_H)
    ns.Widgets.ApplyBackdrop(self.adaptFrame, Theme.panelAlt, Theme.borderStrong)
    self.adaptFrame:Hide()

    self:BuildAdaptationSection()

    self.frame = frame
    self.frame:Hide()
    return self.frame
end

-- ---------------------------------------------------------------------------
-- Create a single enemy row widget
-- ---------------------------------------------------------------------------

function ArenaScoutView:CreateEnemyRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(INNER_WIDTH - 20, ENEMY_ROW_HEIGHT)
    ns.Widgets.ApplyBackdrop(row, Theme.panel, Theme.border)

    -- Class-color accent bar on left
    row.accent = row:CreateTexture(nil, "ARTWORK")
    row.accent:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.accent:SetSize(3, ENEMY_ROW_HEIGHT)
    row.accent:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.accent:SetVertexColor(unpack(Theme.textMuted))

    -- Spec name (class-colored)
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -8)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetTextColor(unpack(Theme.text))

    -- Role pill
    row.rolePill = ns.Widgets.CreatePill(row, 52, PILL_H, Theme.panelAlt, Theme.border)
    row.rolePill:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -6)

    -- Confidence pill (per-slot)
    row.confPill = ns.Widgets.CreatePill(row, 70, PILL_H, Theme.accentSoft, Theme.borderStrong)
    row.confPill:SetPoint("RIGHT", row.rolePill, "LEFT", -4, 0)

    -- WR bar shell
    row.wrBarShell = CreateFrame("Frame", nil, row, "BackdropTemplate")
    row.wrBarShell:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -6)
    row.wrBarShell:SetSize(INNER_WIDTH - 50, BAR_HEIGHT)
    ns.Widgets.ApplyBackdrop(row.wrBarShell, Theme.barShell, Theme.border,
        { left = 0, right = 0, top = 0, bottom = 0 })

    row.wrFill = row.wrBarShell:CreateTexture(nil, "ARTWORK")
    row.wrFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.wrFill:SetPoint("TOPLEFT", row.wrBarShell, "TOPLEFT", 0, 0)
    row.wrFill:SetPoint("BOTTOMLEFT", row.wrBarShell, "BOTTOMLEFT", 0, 0)
    row.wrFill:SetWidth(1)
    row.wrFill:SetVertexColor(unpack(Theme.accent))

    -- WR text overlay
    row.wrText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.wrText:SetPoint("LEFT", row.wrBarShell, "RIGHT", 6, 0)
    row.wrText:SetJustifyH("LEFT")
    row.wrText:SetTextColor(unpack(Theme.textMuted))

    -- Threat spells ("watch for") label
    row.threatLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.threatLabel:SetPoint("TOPLEFT", row.wrBarShell, "BOTTOMLEFT", 0, -4)
    row.threatLabel:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.threatLabel:SetJustifyH("LEFT")
    row.threatLabel:SetTextColor(unpack(Theme.warning))

    row:Hide()

    --- Populate the row from an enemy entry.
    function row:SetEnemyData(enemy)
        if not enemy then
            self:Hide()
            return
        end

        -- Class-color accent and name
        local r, g, b, a = classColor(enemy.classFile)
        self.accent:SetVertexColor(r, g, b, a)

        local nameStr = enemy.specName or "Unknown"
        if enemy.classFile then
            nameStr = string.format("|cff%02x%02x%02x%s|r",
                math.floor(r * 255), math.floor(g * 255), math.floor(b * 255),
                nameStr)
        end
        self.nameText:SetText(nameStr)

        -- Role pill
        local roleDisplay = enemy.role or "DPS"
        if roleDisplay == "HEALER" then
            roleDisplay = "Healer"
        elseif roleDisplay == "TANK" then
            roleDisplay = "Tank"
        else
            roleDisplay = enemy.rangeBucket == "melee" and "Melee" or
                          enemy.rangeBucket == "ranged" and "Ranged" or "DPS"
        end
        self.rolePill:SetData(roleDisplay, Theme.text, Theme.panelAlt, Theme.border)

        -- Confidence pill
        local confLabel = CONFIDENCE_LABELS[enemy.confidence] or "Scouted"
        local confBg = enemy.confidence == "inspect" and Theme.severityLow or Theme.accentSoft
        self.confPill:SetData(confLabel, Theme.text, confBg, Theme.borderStrong)

        -- WR bar
        local wrLabel, wrColor = formatWR(enemy.historicalWR, enemy.historicalFights)
        self.wrText:SetText(wrLabel)
        self.wrText:SetTextColor(unpack(wrColor))

        if enemy.historicalWR and (enemy.historicalFights or 0) > 0 then
            local wr = Helpers.Clamp(enemy.historicalWR, 0, 1)
            local barWidth = math.max(1, self.wrBarShell:GetWidth() * wr)
            self.wrFill:SetWidth(barWidth)
            self.wrFill:SetVertexColor(unpack(wrColor))
            self.wrFill:Show()
        else
            self.wrFill:SetWidth(1)
            self.wrFill:Hide()
        end

        -- Threat spells
        local watchFor = enemy.watchFor or {}
        local spellNames = {}
        for _, entry in ipairs(watchFor) do
            local name = resolveSpellName(entry)
            if name then
                spellNames[#spellNames + 1] = name
            end
        end
        if #spellNames > 0 then
            self.threatLabel:SetText("Watch: " .. table.concat(spellNames, ", "))
            self.threatLabel:Show()
        else
            self.threatLabel:SetText("")
            self.threatLabel:Hide()
        end

        self:Show()
    end

    return row
end

-- ---------------------------------------------------------------------------
-- T087: Adaptation card section construction
-- ---------------------------------------------------------------------------

function ArenaScoutView:BuildAdaptationSection()
    local af = self.adaptFrame

    -- Section divider header
    self.adaptHeader = af:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.adaptHeader:SetPoint("TOPLEFT", af, "TOPLEFT", PAD, -8)
    self.adaptHeader:SetText("Round Adaptation")
    self.adaptHeader:SetTextColor(unpack(Theme.accent))

    -- Round number indicator
    self.roundPill = ns.Widgets.CreatePill(af, 60, PILL_H, Theme.accentSoft, Theme.borderStrong)
    self.roundPill:SetPoint("TOPRIGHT", af, "TOPRIGHT", -PAD, -8)

    -- Death cause text
    self.deathCauseLabel = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.deathCauseLabel:SetPoint("TOPLEFT", self.adaptHeader, "BOTTOMLEFT", 0, -8)
    self.deathCauseLabel:SetTextColor(unpack(Theme.textMuted))
    self.deathCauseLabel:SetText("Death Cause:")

    self.deathCauseText = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.deathCauseText:SetPoint("TOPLEFT", self.deathCauseLabel, "BOTTOMLEFT", 0, -2)
    self.deathCauseText:SetPoint("RIGHT", af, "RIGHT", -PAD, 0)
    self.deathCauseText:SetJustifyH("LEFT")
    self.deathCauseText:SetWordWrap(true)
    self.deathCauseText:SetTextColor(unpack(Theme.warning))

    -- Highest pressure source
    self.pressureLabel = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.pressureLabel:SetPoint("TOPLEFT", self.deathCauseText, "BOTTOMLEFT", 0, -6)
    self.pressureLabel:SetTextColor(unpack(Theme.textMuted))
    self.pressureLabel:SetText("Highest Pressure:")

    self.pressureText = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.pressureText:SetPoint("TOPLEFT", self.pressureLabel, "BOTTOMLEFT", 0, -2)
    self.pressureText:SetPoint("RIGHT", af, "RIGHT", -PAD, 0)
    self.pressureText:SetJustifyH("LEFT")
    self.pressureText:SetTextColor(unpack(Theme.text))

    -- Healer pressure pill
    self.healerPressureLabel = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.healerPressureLabel:SetPoint("TOPLEFT", self.pressureText, "BOTTOMLEFT", 0, -6)
    self.healerPressureLabel:SetTextColor(unpack(Theme.textMuted))
    self.healerPressureLabel:SetText("Healer Pressure:")

    self.healerPressurePill = ns.Widgets.CreatePill(af, 64, PILL_H, Theme.panelAlt, Theme.border)
    self.healerPressurePill:SetPoint("LEFT", self.healerPressureLabel, "RIGHT", 6, 0)

    -- Tactical suggestion text
    self.suggestionLabel = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.suggestionLabel:SetPoint("TOPLEFT", self.healerPressureLabel, "BOTTOMLEFT", 0, -8)
    self.suggestionLabel:SetTextColor(unpack(Theme.textMuted))
    self.suggestionLabel:SetText("Suggestion:")

    self.suggestionText = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.suggestionText:SetPoint("TOPLEFT", self.suggestionLabel, "BOTTOMLEFT", 0, -2)
    self.suggestionText:SetPoint("RIGHT", af, "RIGHT", -PAD, 0)
    self.suggestionText:SetJustifyH("LEFT")
    self.suggestionText:SetWordWrap(true)
    self.suggestionText:SetTextColor(unpack(Theme.success))
end

-- ---------------------------------------------------------------------------
-- T086: Show scout card data
-- ---------------------------------------------------------------------------

function ArenaScoutView:Show(scoutCard)
    if not self.frame then self:Build() end
    if not scoutCard then return end

    -- Comp archetype pill
    local compLabel = scoutCard.compArchetype or "Unknown Comp"
    self.compPill:SetData(compLabel, Theme.text, Theme.accentSoft, Theme.borderStrong)

    -- Overall WR
    if scoutCard.overallWR then
        local pct = scoutCard.overallWR * 100
        local color = pct >= 50 and Theme.success or Theme.warning
        self.overallWRText:SetText(string.format("Overall: %.0f%%", pct))
        self.overallWRText:SetTextColor(unpack(color))
    else
        self.overallWRText:SetText("No prior data")
        self.overallWRText:SetTextColor(unpack(Theme.textMuted))
    end

    -- Populate enemy rows
    local enemies = scoutCard.enemies or {}
    local enemyCount = math.min(#enemies, #self.enemyRows)
    local yOffset = 0

    for i = 1, #self.enemyRows do
        local row = self.enemyRows[i]
        if i <= enemyCount then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.scrollCanvas, "TOPLEFT", 0, -yOffset)
            row:SetEnemyData(enemies[i])
            yOffset = yOffset + ENEMY_ROW_HEIGHT + SPACING
        else
            row:Hide()
        end
    end

    -- Position adaptation frame below enemy rows (hidden until ShowAdaptation)
    self.adaptFrame:ClearAllPoints()
    self.adaptFrame:SetPoint("TOPLEFT", self.scrollCanvas, "TOPLEFT", 0, -yOffset)

    -- Size the frame and canvas
    local totalHeight = yOffset
    if self.adaptFrame:IsShown() then
        totalHeight = totalHeight + ADAPT_SECTION_H + SPACING
    end
    ns.Widgets.SetCanvasHeight(self.scrollCanvas, math.max(totalHeight, 100))

    -- Adjust main frame height based on content
    local frameHeight = 80 + math.min(totalHeight + 40, 500)
    self.frame:SetHeight(frameHeight)

    self.frame:Show()
end

-- ---------------------------------------------------------------------------
-- T086: Hide
-- ---------------------------------------------------------------------------

function ArenaScoutView:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- T087: Show adaptation card (Solo Shuffle between-round)
-- ---------------------------------------------------------------------------

function ArenaScoutView:ShowAdaptation(adaptationCard)
    if not self.frame then self:Build() end
    if not adaptationCard then return end

    -- Round number indicator
    local roundNum = adaptationCard.roundNumber or 0
    if roundNum > 0 then
        self.roundPill:SetData(string.format("Rd %d", roundNum), Theme.text,
            Theme.accentSoft, Theme.borderStrong)
        self.roundPill:Show()
    else
        self.roundPill:Hide()
    end

    -- Death cause
    if adaptationCard.deathCause then
        self.deathCauseText:SetText(adaptationCard.deathCause)
        self.deathCauseText:SetTextColor(unpack(Theme.warning))
        self.deathCauseLabel:Show()
        self.deathCauseText:Show()
    else
        self.deathCauseLabel:Show()
        self.deathCauseText:SetText("Survived previous round")
        self.deathCauseText:SetTextColor(unpack(Theme.success))
    end

    -- Highest pressure source
    local pressureSlot = adaptationCard.highestPressureSlot
    if pressureSlot then
        local specName = pressureSlot.specName or pressureSlot.className or "Unknown"
        local pressureAmt = pressureSlot.pressureAmount
        if pressureAmt then
            self.pressureText:SetText(string.format("%s (%.0f pressure)", specName, pressureAmt))
        else
            self.pressureText:SetText(specName)
        end
        self.pressureLabel:Show()
        self.pressureText:Show()
    else
        self.pressureLabel:Show()
        self.pressureText:SetText("N/A")
        self.pressureText:SetTextColor(unpack(Theme.textMuted))
    end

    -- Healer pressure pill
    local hp = adaptationCard.healerPressure or "none"
    local hpColors = HEALER_PRESSURE_COLORS[hp] or HEALER_PRESSURE_COLORS.none
    self.healerPressurePill:SetData(
        hp:sub(1, 1):upper() .. hp:sub(2),
        Theme.text,
        hpColors.bg,
        hpColors.border
    )

    -- Tactical suggestion
    local suggestion = adaptationCard.tacticalSuggestion or adaptationCard.suggestion or ""
    if suggestion ~= "" then
        self.suggestionText:SetText(suggestion)
        self.suggestionLabel:Show()
        self.suggestionText:Show()
    else
        self.suggestionLabel:Hide()
        self.suggestionText:Hide()
    end

    -- Matchup reminder (append to title if available)
    if adaptationCard.matchupReminder then
        self.adaptHeader:SetText("Round Adaptation  |  " .. adaptationCard.matchupReminder)
    else
        self.adaptHeader:SetText("Round Adaptation")
    end

    -- Resize adaptation frame to fit content
    local adaptHeight = 8 + 16 + 8  -- header padding
    adaptHeight = adaptHeight + 14 + 2 + (self.deathCauseText:GetStringHeight() or 12) + 6
    adaptHeight = adaptHeight + 14 + 2 + (self.pressureText:GetStringHeight() or 12) + 6
    adaptHeight = adaptHeight + 14 + PILL_H + 8
    if suggestion ~= "" then
        adaptHeight = adaptHeight + 14 + 2 + (self.suggestionText:GetStringHeight() or 12)
    end
    adaptHeight = math.max(adaptHeight + 8, 120)
    self.adaptFrame:SetHeight(adaptHeight)

    self.adaptFrame:Show()

    -- Recalculate canvas height if scout content is already shown
    self:RefreshCanvasHeight()
end

-- ---------------------------------------------------------------------------
-- T087: Hide adaptation card
-- ---------------------------------------------------------------------------

function ArenaScoutView:HideAdaptation()
    if self.adaptFrame then
        self.adaptFrame:Hide()
    end
    self:RefreshCanvasHeight()
end

-- ---------------------------------------------------------------------------
-- Internal: recalculate scroll canvas height
-- ---------------------------------------------------------------------------

function ArenaScoutView:RefreshCanvasHeight()
    if not self.scrollCanvas then return end

    local yOffset = 0
    for _, row in ipairs(self.enemyRows) do
        if row:IsShown() then
            yOffset = yOffset + ENEMY_ROW_HEIGHT + SPACING
        end
    end

    if self.adaptFrame and self.adaptFrame:IsShown() then
        self.adaptFrame:ClearAllPoints()
        self.adaptFrame:SetPoint("TOPLEFT", self.scrollCanvas, "TOPLEFT", 0, -yOffset)
        yOffset = yOffset + (self.adaptFrame:GetHeight() or ADAPT_SECTION_H) + SPACING
    end

    ns.Widgets.SetCanvasHeight(self.scrollCanvas, math.max(yOffset, 100))

    local frameHeight = 80 + math.min(yOffset + 40, 500)
    if self.frame then
        self.frame:SetHeight(frameHeight)
    end
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

ns.Addon:RegisterModule("ArenaScoutView", ArenaScoutView)
