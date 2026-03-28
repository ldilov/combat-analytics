local _, ns = ...

local Helpers = ns.Helpers
local Theme   = ns.Widgets.THEME

local COLOR_A = { 0.40, 0.78, 1.00, 1.0 }
local COLOR_B = { 0.96, 0.74, 0.38, 1.0 }

local LOW_SAMPLE_THRESHOLD = 5

local BuildComparatorView = {
    viewId  = "builds",
    _indexA = 1,
    _indexB = 2,
    _list   = nil,
    _elems  = {},
}

-- helpers -------------------------------------------------------------------

-- Resolve PvP talent names from stored spell IDs.
-- C_Spell.GetSpellName() works synchronously for cached spells; PvP talents
-- are always cached because the client needs them for the combat UI.
local function resolvePvpTalentNames(pvpTalents)
    if not pvpTalents or #pvpTalents == 0 then return nil end
    local names = {}
    for _, spellId in ipairs(pvpTalents) do
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)
        if name and name ~= "" then
            names[#names + 1] = name
        end
    end
    return #names > 0 and names or nil
end

-- Extract snapshot metadata from a bucket's last session (for buckets created
-- before the specName field was introduced).
local function snapshotFromLastSession(bucket)
    if not bucket or not bucket.lastSessionId then return nil end
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return nil end
    local session = store:GetCombatById(bucket.lastSessionId)
    return session and session.playerSnapshot or nil
end

-- Return specName, pvpTalentNames table from a bucket (resolving snapshot if
-- needed). Used both for the label string and the filter chip row.
local function resolveBuildMeta(bucket)
    if not bucket then return nil, nil end
    local specName   = bucket.specName
    local pvpTalents = bucket.pvpTalents
    if not specName then
        local snap = snapshotFromLastSession(bucket)
        if snap then
            specName   = snap.specName
            pvpTalents = snap.pvpTalents
        end
    end
    local pvpNames = resolvePvpTalentNames(pvpTalents)
    return specName, pvpNames
end

local function buildLabel(bucket)
    if not bucket then return "(none)" end
    local f    = bucket.fights or 0
    local fStr = string.format("(%dF)", f)

    local specName, pvpNames = resolveBuildMeta(bucket)

    if not specName then
        -- Last resort: show truncated hash so it's always legible.
        return string.format("Build %s  %s", string.sub(bucket.key or "?", 1, 8), fStr)
    end

    if pvpNames then
        return string.format("%s  \226\128\148  %s  %s", specName, table.concat(pvpNames, ", "), fStr)
    end
    return string.format("%s  %s", specName, fStr)
end

local METRIC_DEFS = {
    { label = "Record",        field = "record",   neutral = true  },
    { label = "Win Rate",      field = "winRate",  low = false     },
    { label = "Avg Pressure",  field = "pressure", low = false     },
    { label = "Avg Damage",    field = "damage",   low = false     },
    { label = "Avg Deaths",    field = "deaths",   low = true      },
    { label = "Avg Dmg Taken", field = "taken",    low = true      },
}

local function computeMetrics(bucket)
    if not bucket then return nil end
    local f = bucket.fights or 0
    if f == 0 then return nil end
    local prefix = f < LOW_SAMPLE_THRESHOLD and "~" or ""
    local wr  = (bucket.wins or 0) / f
    local pr  = (bucket.totalPressureScore or 0) / f
    local dmg = (bucket.totalDamageDone or 0) / f
    local dt  = (bucket.totalDeaths or 0) / f
    local tk  = (bucket.totalDamageTaken or 0) / f
    return {
        record   = string.format("%s%dW %dL", prefix, bucket.wins or 0, bucket.losses or 0),
        winRate  = string.format("%s%.1f%%", prefix, wr * 100),
        pressure = string.format("%s%.1f", prefix, pr),
        damage   = string.format("%s%s", prefix, Helpers.FormatNumber(dmg)),
        deaths   = string.format("%s%.1f", prefix, dt),
        taken    = string.format("%s%s", prefix, Helpers.FormatNumber(tk)),
        -- raw values for winner comparison and bar rendering
        _wr = wr, _pr = pr, _dmg = dmg, _dt = dt, _tk = tk,
    }
end

local RAW = { winRate = "_wr", pressure = "_pr", damage = "_dmg", deaths = "_dt", taken = "_tk" }

-- element pool ---------------------------------------------------------------

function BuildComparatorView:_clear()
    for _, el in ipairs(self._elems) do
        if el and el.Hide then el:Hide() end
    end
    self._elems = {}
end

function BuildComparatorView:_track(el)
    self._elems[#self._elems + 1] = el
    return el
end

-- Build ----------------------------------------------------------------------

function BuildComparatorView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.frame:Hide()

    self.title = ns.Widgets.CreateSectionTitle(
        self.frame, "Build Comparator",
        "TOPLEFT", self.frame, "TOPLEFT", 16, -16)

    self.caption = ns.Widgets.CreateCaption(
        self.frame,
        "Compare talent builds side-by-side using your historical performance data. "
            .. "Values prefixed with ~ have fewer than 5 sessions.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Build A row
    self.labelA = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.labelA:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -18)
    self.labelA:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], COLOR_A[4])
    self.labelA:SetText("Build A:")

    self.prevA = ns.Widgets.CreateButton(self.frame, "<", 24, 22)
    self.prevA:SetPoint("LEFT", self.labelA, "RIGHT", 8, 0)
    self.prevA:SetScript("OnClick", function()
        self._indexA = math.max(1, self._indexA - 1)
        self:Refresh()
    end)

    self.nameA = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.nameA:SetPoint("LEFT", self.prevA, "RIGHT", 6, 0)
    self.nameA:SetWidth(340)
    self.nameA:SetJustifyH("LEFT")

    self.nextA = ns.Widgets.CreateButton(self.frame, ">", 24, 22)
    self.nextA:SetPoint("LEFT", self.nameA, "RIGHT", 6, 0)
    self.nextA:SetScript("OnClick", function()
        self._indexA = self._indexA + 1
        self:Refresh()
    end)

    -- Build B row
    self.labelB = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.labelB:SetPoint("TOPLEFT", self.labelA, "BOTTOMLEFT", 0, -10)
    self.labelB:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], COLOR_B[4])
    self.labelB:SetText("Build B:")

    self.prevB = ns.Widgets.CreateButton(self.frame, "<", 24, 22)
    self.prevB:SetPoint("LEFT", self.labelB, "RIGHT", 8, 0)
    self.prevB:SetScript("OnClick", function()
        self._indexB = math.max(1, self._indexB - 1)
        self:Refresh()
    end)

    self.nameB = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.nameB:SetPoint("LEFT", self.prevB, "RIGHT", 6, 0)
    self.nameB:SetWidth(340)
    self.nameB:SetJustifyH("LEFT")

    self.nextB = ns.Widgets.CreateButton(self.frame, ">", 24, 22)
    self.nextB:SetPoint("LEFT", self.nameB, "RIGHT", 6, 0)
    self.nextB:SetScript("OnClick", function()
        self._indexB = self._indexB + 1
        self:Refresh()
    end)

    -- Scrollable canvas
    self.shell, self.scrollFrame, self.canvas =
        ns.Widgets.CreateScrollCanvas(self.frame, 680, 300)
    self.shell:SetPoint("TOPLEFT", self.labelB, "BOTTOMLEFT", 0, -14)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    return self.frame
end

-- Refresh --------------------------------------------------------------------

function BuildComparatorView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    if not store then return end

    -- Prefer per-character build list; fall back to global
    local charKey = store:GetCurrentCharacterKey()
    local list    = store:GetAggregateBuckets("builds", charKey)
    if #list == 0 then
        list = store:GetAggregateBuckets("builds")
    end
    self._list = list

    self:_clear()

    local count = #list

    if count == 0 then
        self.nameA:SetText("(no build history)")
        self.nameB:SetText("(no build history)")
        self.prevA:SetEnabled(false)
        self.nextA:SetEnabled(false)
        self.prevB:SetEnabled(false)
        self.nextB:SetEnabled(false)
        local fs = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -8)
        fs:SetTextColor(unpack(Theme.textMuted))
        fs:SetText("No build history yet. Complete combat sessions to populate this view.")
        self:_track(fs)
        ns.Widgets.SetCanvasHeight(self.canvas, 40)
        return
    end

    self._indexA = Helpers.Clamp(self._indexA, 1, count)
    self._indexB = Helpers.Clamp(self._indexB, 1, count)

    local bucketA = list[self._indexA]
    local bucketB = list[self._indexB]

    self.nameA:SetText(buildLabel(bucketA))
    self.nameB:SetText(buildLabel(bucketB))
    self.prevA:SetEnabled(self._indexA > 1)
    self.nextA:SetEnabled(self._indexA < count)
    self.prevB:SetEnabled(self._indexB > 1)
    self.nextB:SetEnabled(self._indexB < count)

    local mA = computeMetrics(bucketA)
    local mB = computeMetrics(bucketB)

    self:_renderComparison(bucketA, bucketB, mA, mB)
end

-- filter chip row ------------------------------------------------------------

-- Renders spec name and PvP talent pills above the comparison bars.
function BuildComparatorView:_renderFilterChips(bucketA, bucketB, y)
    local canvas = self.canvas
    local PILL_H = 18
    local PILL_GAP = 6

    local specA, pvpA = resolveBuildMeta(bucketA)
    local specB, pvpB = resolveBuildMeta(bucketB)

    local hasChips = specA or specB
    if not hasChips then return y end

    local xOffset = 0

    -- Build A chips
    if specA then
        local pill = ns.Widgets.CreatePill(canvas, nil, PILL_H)
        pill:SetData(specA, COLOR_A, { COLOR_A[1] * 0.25, COLOR_A[2] * 0.25, COLOR_A[3] * 0.25, 0.85 }, COLOR_A)
        local tw = pill.text:GetStringWidth() or 40
        pill:SetSize(tw + 16, PILL_H)
        pill:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOffset, -y)
        self:_track(pill)
        xOffset = xOffset + tw + 16 + PILL_GAP

        if pvpA then
            for _, talentName in ipairs(pvpA) do
                local tp = ns.Widgets.CreatePill(canvas, nil, PILL_H)
                tp:SetData(talentName, Theme.text, Theme.panelAlt, Theme.border)
                local tpw = tp.text:GetStringWidth() or 30
                tp:SetSize(tpw + 12, PILL_H)
                tp:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOffset, -y)
                self:_track(tp)
                xOffset = xOffset + tpw + 12 + PILL_GAP
            end
        end
    end

    y = y + PILL_H + 4
    xOffset = 0

    -- Build B chips
    if specB then
        local pill = ns.Widgets.CreatePill(canvas, nil, PILL_H)
        pill:SetData(specB, COLOR_B, { COLOR_B[1] * 0.25, COLOR_B[2] * 0.25, COLOR_B[3] * 0.25, 0.85 }, COLOR_B)
        local tw = pill.text:GetStringWidth() or 40
        pill:SetSize(tw + 16, PILL_H)
        pill:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOffset, -y)
        self:_track(pill)
        xOffset = xOffset + tw + 16 + PILL_GAP

        if pvpB then
            for _, talentName in ipairs(pvpB) do
                local tp = ns.Widgets.CreatePill(canvas, nil, PILL_H)
                tp:SetData(talentName, Theme.text, Theme.panelAlt, Theme.border)
                local tpw = tp.text:GetStringWidth() or 30
                tp:SetSize(tpw + 12, PILL_H)
                tp:SetPoint("TOPLEFT", canvas, "TOPLEFT", xOffset, -y)
                self:_track(tp)
                xOffset = xOffset + tpw + 12 + PILL_GAP
            end
        end
    end

    y = y + PILL_H + 10
    return y
end

-- low-sample warning badge ---------------------------------------------------

function BuildComparatorView:_renderLowSampleBadge(bucketA, bucketB, y)
    local canvas  = self.canvas
    local fightsA = bucketA and bucketA.fights or 0
    local fightsB = bucketB and bucketB.fights or 0

    if fightsA >= LOW_SAMPLE_THRESHOLD and fightsB >= LOW_SAMPLE_THRESHOLD then
        return y
    end

    local warningParts = {}
    if fightsA < LOW_SAMPLE_THRESHOLD then
        warningParts[#warningParts + 1] = string.format("Build A: %d fights", fightsA)
    end
    if fightsB < LOW_SAMPLE_THRESHOLD then
        warningParts[#warningParts + 1] = string.format("Build B: %d fights", fightsB)
    end

    local warningText = "Low sample  \226\128\148  " .. table.concat(warningParts, ", ")

    local badge = ns.Widgets.CreatePill(canvas, nil, 20,
        Theme.severityMedium, Theme.warning)
    badge:SetData(warningText, Theme.text, Theme.severityMedium, Theme.warning)
    local tw = badge.text:GetStringWidth() or 80
    badge:SetSize(tw + 16, 20)
    badge:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    self:_track(badge)

    y = y + 28
    return y
end

-- mirrored delta bar rendering -----------------------------------------------

-- BAR_DEFS maps each non-neutral metric to its raw field, format string, and
-- whether lower is better (for the winner/color logic).
local BAR_DEFS = {
    { label = "Win Rate",      rawField = "_wr",  fmt = "%.1f%%", scale = 100, low = false },
    { label = "Avg Pressure",  rawField = "_pr",  fmt = "%.1f",   scale = 1,   low = false },
    { label = "Avg Damage",    rawField = "_dmg", fmt = nil,      scale = 1,   low = false },
    { label = "Avg Deaths",    rawField = "_dt",  fmt = "%.1f",   scale = 1,   low = true  },
    { label = "Avg Dmg Taken", rawField = "_tk",  fmt = nil,      scale = 1,   low = true  },
}

-- Determine the winner of a metric comparison. Returns "A", "B", or "tie".
local function metricWinner(rawA, rawB, isLow)
    if rawA == rawB then return "tie" end
    if isLow then
        return rawA < rawB and "A" or "B"
    end
    return rawA > rawB and "A" or "B"
end

function BuildComparatorView:_renderComparison(bucketA, bucketB, mA, mB)
    local canvas   = self.canvas
    local BAR_W    = 540
    local BAR_H    = 14
    local ROW_H    = 46
    local y        = 0

    -- 1. Filter chips (spec + PvP talent pills)
    y = self:_renderFilterChips(bucketA, bucketB, y)

    -- 2. Low-sample warning badge
    y = self:_renderLowSampleBadge(bucketA, bucketB, y)

    -- 3. Column legend (Build A | vs | Build B)
    local legendA = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legendA:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    legendA:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], COLOR_A[4])
    legendA:SetText("Build A")
    self:_track(legendA)

    local legendB = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legendB:SetPoint("TOPRIGHT", canvas, "TOPLEFT", BAR_W, -y)
    legendB:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], COLOR_B[4])
    legendB:SetJustifyH("RIGHT")
    legendB:SetText("Build B")
    self:_track(legendB)

    y = y + 18

    -- Separator
    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(BAR_W, 1)
    self:_track(sep)
    y = y + 6

    -- 4. Record row (text only, no bar -- neutral metric)
    if mA or mB then
        local recLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        recLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        recLabel:SetTextColor(unpack(Theme.textMuted))
        recLabel:SetText("Record")
        self:_track(recLabel)

        local recA = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        recA:SetPoint("TOPLEFT", canvas, "TOPLEFT", 80, -y)
        recA:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 1)
        recA:SetText(mA and mA.record or "\226\128\148")
        self:_track(recA)

        local recB = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        recB:SetPoint("TOPRIGHT", canvas, "TOPLEFT", BAR_W, -y)
        recB:SetJustifyH("RIGHT")
        recB:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], 1)
        recB:SetText(mB and mB.record or "\226\128\148")
        self:_track(recB)

        y = y + 22
    end

    -- 5. Mirrored delta bars for each non-neutral metric
    local winsA, winsB = 0, 0

    for _, def in ipairs(BAR_DEFS) do
        local rawA = mA and mA[def.rawField] or 0
        local rawB = mB and mB[def.rawField] or 0

        local winner = metricWinner(rawA, rawB, def.low)
        if winner == "A" then
            winsA = winsA + 1
        elseif winner == "B" then
            winsB = winsB + 1
        end

        -- Row background (alternating)
        local bg = canvas:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.08, 0.10, 0.14, 0.35)
        bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", -4, -(y - 2))
        bg:SetSize(BAR_W + 8, ROW_H - 2)
        self:_track(bg)

        -- Metric label
        local metricLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        metricLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        metricLabel:SetTextColor(unpack(Theme.textMuted))
        metricLabel:SetText(def.label)
        self:_track(metricLabel)

        -- Formatted value strings for A and B
        local displayA, displayB
        if def.fmt then
            displayA = string.format(def.fmt, rawA * def.scale)
            displayB = string.format(def.fmt, rawB * def.scale)
        else
            displayA = Helpers.FormatNumber(rawA * def.scale)
            displayB = Helpers.FormatNumber(rawB * def.scale)
        end

        local valAFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valAFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -(y + 14))
        valAFs:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 1)
        valAFs:SetText(mA and displayA or "\226\128\148")
        self:_track(valAFs)

        local valBFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valBFs:SetPoint("TOPRIGHT", canvas, "TOPLEFT", BAR_W, -(y + 14))
        valBFs:SetJustifyH("RIGHT")
        valBFs:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], 1)
        valBFs:SetText(mB and displayB or "\226\128\148")
        self:_track(valBFs)

        -- MirroredDeltaBar — use winner-highlighted colors
        local leftColor  = (winner == "A") and Theme.success or COLOR_A
        local rightColor = (winner == "B") and Theme.success or COLOR_B

        local bar = ns.Widgets.CreateMirroredDeltaBar(
            canvas, rawA, rawB, leftColor, rightColor, "", BAR_W, BAR_H)
        bar:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -(y + 28))
        self:_track(bar)

        y = y + ROW_H
    end

    -- 6. Separator before verdict
    y = y + 6
    local sep2 = canvas:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(unpack(Theme.border))
    sep2:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep2:SetSize(BAR_W, 1)
    self:_track(sep2)
    y = y + 10

    -- 7. Metric win counter badge
    local totalMetrics = #BAR_DEFS
    if mA and mB then
        local badgeText
        if winsA > winsB then
            badgeText = string.format("Build A leads %d/%d metrics", winsA, totalMetrics)
        elseif winsB > winsA then
            badgeText = string.format("Build B leads %d/%d metrics", winsB, totalMetrics)
        else
            badgeText = string.format("Even  \226\128\148  %d/%d metrics each", winsA, totalMetrics)
        end

        local badgeColor, badgeBorder
        if winsA > winsB then
            badgeColor  = { COLOR_A[1] * 0.25, COLOR_A[2] * 0.25, COLOR_A[3] * 0.25, 0.9 }
            badgeBorder = COLOR_A
        elseif winsB > winsA then
            badgeColor  = { COLOR_B[1] * 0.25, COLOR_B[2] * 0.25, COLOR_B[3] * 0.25, 0.9 }
            badgeBorder = COLOR_B
        else
            badgeColor  = Theme.panelAlt
            badgeBorder = Theme.borderStrong
        end

        local winBadge = ns.Widgets.CreatePill(canvas, nil, 22, badgeColor, badgeBorder)
        winBadge:SetData(badgeText, Theme.text, badgeColor, badgeBorder)
        local bw = winBadge.text:GetStringWidth() or 100
        winBadge:SetSize(bw + 20, 22)
        winBadge:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        self:_track(winBadge)

        -- Delta badge showing the lead difference
        local leadDelta = winsA - winsB
        if leadDelta ~= 0 then
            local deltaBadge = ns.Widgets.CreateDeltaBadge(canvas, leadDelta, "%d")
            deltaBadge:SetPoint("LEFT", winBadge, "RIGHT", 8, 0)
            self:_track(deltaBadge)
        end

        y = y + 30
    else
        -- Insufficient data message
        local noDataFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        noDataFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        noDataFs:SetTextColor(unpack(Theme.accent))
        noDataFs:SetText("Insufficient data for one or both builds.")
        self:_track(noDataFs)
        y = y + 24
    end

    ns.Widgets.SetCanvasHeight(canvas, y + 16)
end

ns.Addon:RegisterModule("BuildComparatorView", BuildComparatorView)
