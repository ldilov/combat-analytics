local _, ns = ...

local Helpers = ns.Helpers
local Theme   = ns.Widgets.THEME

local BuildComparatorView = {
    viewId  = "builds",
    _indexA = 1,
    _indexB = 2,
    _list   = nil,
    _elems  = {},
}

-- ─── helpers ─────────────────────────────────────────────────────────────────

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

local function buildLabel(bucket)
    if not bucket then return "(none)" end
    local f    = bucket.fights or 0
    local fStr = string.format("(%dF)", f)

    -- Prefer metadata stored directly on the bucket; fall back to last session.
    local specName   = bucket.specName
    local pvpTalents = bucket.pvpTalents
    if not specName then
        local snap = snapshotFromLastSession(bucket)
        if snap then
            specName   = snap.specName
            pvpTalents = snap.pvpTalents
        end
    end

    if not specName then
        -- Last resort: show truncated hash so it's always legible.
        return string.format("Build %s  %s", string.sub(bucket.key or "?", 1, 8), fStr)
    end

    local pvpNames = resolvePvpTalentNames(pvpTalents)
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
    local prefix = f < 5 and "~" or ""
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
        -- raw values for winner comparison
        _wr = wr, _pr = pr, _dmg = dmg, _dt = dt, _tk = tk,
    }
end

local RAW = { winRate = "_wr", pressure = "_pr", damage = "_dmg", deaths = "_dt", taken = "_tk" }

-- ─── element pool ─────────────────────────────────────────────────────────────

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

-- ─── Build ────────────────────────────────────────────────────────────────────

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
    self.labelA:SetTextColor(0.40, 0.78, 1.00, 1.0)
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
    self.labelB:SetTextColor(0.96, 0.74, 0.38, 1.0)
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

    -- Scrollable table canvas
    self.shell, self.scrollFrame, self.canvas =
        ns.Widgets.CreateScrollCanvas(self.frame, 680, 300)
    self.shell:SetPoint("TOPLEFT", self.labelB, "BOTTOMLEFT", 0, -14)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    return self.frame
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

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

    self:_renderTable(mA, mB)
end

-- ─── table rendering ──────────────────────────────────────────────────────────

function BuildComparatorView:_renderTable(mA, mB)
    local canvas    = self.canvas
    local C0, C1, C2 = 0, 180, 380
    local ROW_H     = 24
    local y         = 0

    local function cell(text, x, color)
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, -y)
        if color then
            fs:SetTextColor(unpack(color))
        else
            fs:SetTextColor(unpack(Theme.text))
        end
        fs:SetText(text)
        self:_track(fs)
    end

    -- Column headers
    cell("Metric",  C0, Theme.textMuted)
    cell("Build A", C1, { 0.40, 0.78, 1.00, 1.0 })
    cell("Build B", C2, { 0.96, 0.74, 0.38, 1.0 })
    y = y + ROW_H

    -- Separator
    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(580, 1)
    self:_track(sep)
    y = y + 6

    local winsA, winsB = 0, 0

    for rowIdx, m in ipairs(METRIC_DEFS) do
        local valA = mA and mA[m.field] or "\226\128\148"
        local valB = mB and mB[m.field] or "\226\128\148"
        local colA = Theme.text
        local colB = Theme.text

        -- Green-highlight the winning side for non-neutral metrics
        if not m.neutral and mA and mB then
            local rawField = RAW[m.field]
            if rawField then
                local rA = mA[rawField] or 0
                local rB = mB[rawField] or 0
                local aBetter = m.low and (rA < rB) or (rA > rB)
                local bBetter = m.low and (rB < rA) or (rB > rA)
                if aBetter then colA = Theme.success; winsA = winsA + 1
                elseif bBetter then colB = Theme.success; winsB = winsB + 1
                end
            end
        end

        -- Alternating row background
        if rowIdx % 2 == 0 then
            local bg = canvas:CreateTexture(nil, "BACKGROUND")
            bg:SetColorTexture(0.08, 0.10, 0.14, 0.45)
            bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", -4, -y)
            bg:SetSize(588, ROW_H - 2)
            self:_track(bg)
        end

        cell(m.label, C0, Theme.textMuted)
        cell(valA,    C1, colA)
        cell(valB,    C2, colB)
        y = y + ROW_H
    end

    -- Verdict
    y = y + 10
    local sep2 = canvas:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(unpack(Theme.border))
    sep2:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep2:SetSize(580, 1)
    self:_track(sep2)
    y = y + 8

    local totalNonNeutral = 5  -- winRate, pressure, damage, deaths, taken
    local verdict
    if mA and mB then
        if winsA > winsB then
            verdict = string.format(
                "Build A outperforms Build B on %d of %d tracked metrics.",
                winsA, totalNonNeutral)
        elseif winsB > winsA then
            verdict = string.format(
                "Build B outperforms Build A on %d of %d tracked metrics.",
                winsB, totalNonNeutral)
        else
            verdict = "Builds are evenly matched across all tracked metrics."
        end
    else
        verdict = "Insufficient data for one or both builds."
    end

    cell(verdict, 0, Theme.accent)
    y = y + ROW_H

    ns.Widgets.SetCanvasHeight(canvas, y + 16)
end

ns.Addon:RegisterModule("BuildComparatorView", BuildComparatorView)
