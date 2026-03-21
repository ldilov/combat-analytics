local _, ns = ...

local Theme = ns.Widgets.THEME

local ReplayView = {}

-- Layout constants
local FRAME_W     = 760
local FRAME_H     = 440
local CANVAS_W    = 700
local LABEL_W     = 72
local LANE_H      = 26
local LANE_GAP    = 8
local BAR_H       = 16
local DOT_SIZE    = 7
local TICK_COUNT  = 6
local DISPLAY_CAP = 90   -- clamp timeline display to 90 s

local LANE_DEFS = {
    { label = "Offense",    r = 0.40, g = 0.78, b = 1.00, a = 0.90 },
    { label = "Defense",    r = 0.44, g = 0.82, b = 0.60, a = 0.85 },
    { label = "CC In",      r = 0.96, g = 0.40, b = 0.32, a = 0.85 },
    { label = "Kill Win",   r = 0.96, g = 0.74, b = 0.38, a = 0.85 },
}

-- ─── private helpers ─────────────────────────────────────────────────────────

local function laneY(index)
    return 48 + (index - 1) * (LANE_H + LANE_GAP)
end

local function buildToPx(plotW, displayDuration)
    return function(offset)
        return LABEL_W + (math.min(offset, displayDuration) / displayDuration) * plotW
    end
end

-- ─── element pool ────────────────────────────────────────────────────────────

function ReplayView:_clear()
    for _, el in ipairs(self._elements or {}) do
        if el and el.Hide then el:Hide() end
    end
    self._elements = {}
end

function ReplayView:_add(el)
    self._elements[#self._elements + 1] = el
    return el
end

function ReplayView:_dot(x, y, r, g, b, a)
    local t = self.canvas:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT",
        x - math.floor(DOT_SIZE / 2),
        -(y + math.floor((LANE_H - DOT_SIZE) / 2)))
    t:SetSize(DOT_SIZE, DOT_SIZE)
    self:_add(t)
end

function ReplayView:_bar(x1, x2, y, r, g, b, a)
    local w = math.max(3, x2 - x1)
    local t = self.canvas:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT",
        x1,
        -(y + math.floor((LANE_H - BAR_H) / 2)))
    t:SetSize(w, BAR_H)
    self:_add(t)
end

function ReplayView:_label(x, y, text, font, cr, cg, cb, ca)
    local fs = self.canvas:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", x, -y)
    fs:SetTextColor(cr or unpack(Theme.textMuted))
    fs:SetText(text)
    self:_add(fs)
    return fs
end

-- ─── initialization ───────────────────────────────────────────────────────────

function ReplayView:Initialize()
    self.frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    self.frame:SetSize(FRAME_W, FRAME_H)
    self.frame:SetPoint("CENTER")
    self.frame:SetMovable(true)
    self.frame:EnableMouse(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", self.frame.StartMoving)
    self.frame:SetScript("OnDragStop", self.frame.StopMovingOrSizing)
    self.frame:Hide()
    ns.Widgets.ApplyBackdrop(
        self.frame,
        Theme.background,
        Theme.borderStrong,
        { left = 1, right = 1, top = 1, bottom = 1 }
    )

    -- Header
    self.titleText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.titleText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 16, -14)
    self.titleText:SetTextColor(unpack(Theme.text))

    self.closeBtn = ns.Widgets.CreateButton(self.frame, "Close", 64, 22)
    self.closeBtn:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -10, -12)
    self.closeBtn:SetScript("OnClick", function() self.frame:Hide() end)

    -- Legend strip
    self.legendText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.legendText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 16, -42)
    self.legendText:SetTextColor(unpack(Theme.textMuted))
    self.legendText:SetText(
        "|cff66c8ffOffense|r  "
        .. "|cff70d099Defense|r  "
        .. "|cfff56651CC In|r  "
        .. "|cfff5bd61Kill Window|r  "
        .. "|cffff3333\226\151\134 Death|r"
    )

    -- Canvas (timeline drawing area)
    local canvasH = laneY(5) + 28  -- 4 lanes + time axis
    self.canvas = CreateFrame("Frame", nil, self.frame)
    self.canvas:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 20, -58)
    self.canvas:SetSize(CANVAS_W, canvasH)

    -- Coaching cards area
    self.cardArea = CreateFrame("Frame", nil, self.frame)
    self.cardArea:SetPoint("TOPLEFT", self.canvas, "BOTTOMLEFT", 0, -14)
    self.cardArea:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 12)

    self._elements = {}
end

-- ─── rendering ────────────────────────────────────────────────────────────────

function ReplayView:Render(session)
    self:_clear()

    if not session then
        self:_label(8, 0, "No session data.", "GameFontHighlight",
            unpack(Theme.textMuted))
        return
    end

    local duration        = math.max(1, session.duration or 60)
    local displayDuration = math.min(duration, DISPLAY_CAP)
    local plotW           = CANVAS_W - LABEL_W - 4
    local toPx            = buildToPx(plotW, displayDuration)

    -- Session label in title
    local opponentName = ns.Helpers.ResolveOpponentName(session, "Unknown")
    local resultLabel  = string.lower(tostring(session.result or "unknown"))
    self.titleText:SetText(string.format(
        "Replay  \226\128\148  %s  \194\183  %s  \194\183  %s",
        opponentName,
        resultLabel,
        ns.Helpers.FormatDuration(duration)
    ))

    -- Lane backgrounds + labels
    for i, lane in ipairs(LANE_DEFS) do
        local y = laneY(i)
        -- Lane background
        local bg = self.canvas:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.07, 0.09, 0.13, 0.7)
        bg:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", LABEL_W, -y)
        bg:SetSize(plotW, LANE_H)
        self:_add(bg)
        -- Lane label
        self:_label(0, y + 4, lane.label, "GameFontHighlightSmall")
    end

    local rawEvents = session.rawEvents or {}

    -- === Lane 1: Offensive cast dots ===
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[1]
                self:_dot(toPx(off), laneY(1), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- === Lane 2: Defensive cast dots ===
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine and ev.isCooldownCast then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[2]
                self:_dot(toPx(off), laneY(2), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- === Lane 3: CC Received bars ===
    local d3 = LANE_DEFS[3]
    for _, cc in ipairs(session.ccReceived or {}) do
        local start = cc.startOffset or 0
        local dur   = cc.duration or 2
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(start + dur, displayDuration))
            self:_bar(x1, x2, laneY(3), d3.r, d3.g, d3.b, d3.a)
        end
    end

    -- === Lane 4: Kill window bars ===
    local d4 = LANE_DEFS[4]
    for _, kw in ipairs(session.killWindows or {}) do
        local start = kw.openedAt or 0
        local stop  = kw.closedAt or (start + 5)
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(stop, displayDuration))
            -- Converted kill windows glow green
            local r, g, b, a = d4.r, d4.g, d4.b, d4.a
            if kw.converted then r, g, b = 0.44, 0.82, 0.60 end
            self:_bar(x1, x2, laneY(4), r, g, b, a)
        end
    end

    -- === Death marker (vertical red line) ===
    local deathOffset = nil
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "death" and ev.destMine then
            deathOffset = ev.timestampOffset
            break
        end
    end
    if deathOffset and deathOffset <= displayDuration then
        local dx     = toPx(deathOffset)
        local totalH = laneY(4) + LANE_H - laneY(1)
        local marker = self.canvas:CreateTexture(nil, "OVERLAY")
        marker:SetColorTexture(1.0, 0.20, 0.20, 0.88)
        marker:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", dx - 1, -laneY(1))
        marker:SetSize(2, totalH)
        self:_add(marker)
    end

    -- === Time axis ===
    local axisY = laneY(5)
    for i = 0, TICK_COUNT do
        local t  = math.floor(displayDuration * i / TICK_COUNT)
        local px = toPx(t)
        -- Tick mark
        local tick = self.canvas:CreateTexture(nil, "ARTWORK")
        tick:SetColorTexture(0.35, 0.44, 0.55, 0.7)
        tick:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", px, -axisY)
        tick:SetSize(1, 5)
        self:_add(tick)
        -- Label
        self:_label(px - 8, axisY + 7, tostring(t) .. "s")
    end

    -- === Coaching cards ===
    self:_renderCards(session, rawEvents, deathOffset)
end

function ReplayView:_renderCards(session, rawEvents, deathOffset)
    -- Clear card area children by tracking them in _elements
    local cardArea = self.cardArea
    local function addCard(x, title, body)
        local W = 218
        local bg = cardArea:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.08, 0.10, 0.15, 0.85)
        bg:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x, 0)
        bg:SetSize(W, 72)
        self:_add(bg)

        local titleFs = cardArea:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        titleFs:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x + 7, -7)
        titleFs:SetTextColor(unpack(Theme.accent))
        titleFs:SetText(title)
        self:_add(titleFs)

        local bodyFs = cardArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bodyFs:SetPoint("TOPLEFT", cardArea, "TOPLEFT", x + 7, -26)
        bodyFs:SetWidth(W - 14)
        bodyFs:SetTextColor(unpack(Theme.text))
        bodyFs:SetText(body)
        self:_add(bodyFs)
    end

    -- Card 1: Opener
    local openerCount = 0
    local firstSpell  = nil
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine then
            local off = ev.timestampOffset or 0
            if off <= 8 then
                openerCount = openerCount + 1
                if not firstSpell then firstSpell = ev.spellId end
            end
        end
    end
    local openerBody
    if openerCount > 0 then
        openerBody = string.format("%d casts in first 8s", openerCount)
        if firstSpell then
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(firstSpell)
            local name = info and info.name or ("Spell #" .. tostring(firstSpell))
            openerBody = openerBody .. "\nOpener: " .. name
        end
    else
        openerBody = "No cast data (enable raw events)"
    end
    addCard(0, "Opener", openerBody)

    -- Card 2: CC Pressure
    local ccList  = session.ccReceived or {}
    local ccCount = #ccList
    local ccTotal = 0
    for _, cc in ipairs(ccList) do ccTotal = ccTotal + (cc.duration or 0) end
    local ccBody = ccCount > 0
        and string.format("%d CC windows\n~%.0fs total under CC", ccCount, ccTotal)
        or "No CC events recorded"
    addCard(226, "CC Pressure", ccBody)

    -- Card 3: Death context
    local deathBody
    if deathOffset then
        local preDeath = 0
        for _, ev in ipairs(rawEvents) do
            if ev.eventType == "cast" and ev.sourceMine
            and (ev.timestampOffset or 0) < deathOffset then
                preDeath = preDeath + 1
            end
        end
        deathBody = string.format("Died at %.0fs\n%d player casts tracked before death",
            deathOffset, preDeath)
    else
        deathBody = "No player death recorded"
    end
    addCard(452, "Death Context", deathBody)
end

-- ─── public API ───────────────────────────────────────────────────────────────

function ReplayView:Show(session)
    if not self.frame then
        self:Initialize()
    end
    self:Render(session)
    self.frame:Show()
    self.frame:Raise()
end

function ReplayView:Hide()
    if self.frame then self.frame:Hide() end
end

ns.ReplayView = ReplayView
