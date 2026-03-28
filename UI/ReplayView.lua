local _, ns = ...

local Theme = ns.Widgets.THEME
local Constants = ns.Constants
local SPELL_CATEGORIES = Constants.SPELL_CATEGORIES or {}
local TIMELINE_LANE = Constants.TIMELINE_LANE or {}

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

-- Source pill colors (muted, small)
local SOURCE_PILL_COLORS = {
    state     = { bg = { 0.14, 0.28, 0.44, 0.90 }, border = { 0.35, 0.60, 0.90, 0.80 } },
    timeline  = { bg = { 0.18, 0.38, 0.24, 0.90 }, border = { 0.44, 0.82, 0.60, 0.80 } },
    loc       = { bg = { 0.40, 0.28, 0.12, 0.90 }, border = { 0.96, 0.62, 0.30, 0.80 } },
    estimated = { bg = { 0.22, 0.24, 0.26, 0.90 }, border = { 0.50, 0.54, 0.58, 0.80 } },
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

--- Determine whether session has usable timelineEvents.
local function hasTimelineEvents(session)
    local te = session and session.timelineEvents
    return te and type(te) == "table" and #te > 0
end

--- Filter timelineEvents by lane type.
local function filterTimeline(timelineEvents, laneType)
    local result = {}
    for _, ev in ipairs(timelineEvents) do
        if ev.lane == laneType then
            result[#result + 1] = ev
        end
    end
    return result
end

--- Check if a spellId is categorized as defensive.
local function isDefensiveSpell(spellId)
    return spellId and SPELL_CATEGORIES[spellId] == "defensive"
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
    if cr then
        fs:SetTextColor(cr, cg or 1, cb or 1, ca or 1)
    else
        fs:SetTextColor(unpack(Theme.textMuted))
    end
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

    -- Legend strip — will be populated in Render via CreateMiniLegend
    -- Placeholder frame to anchor the legend row
    self.legendRow = CreateFrame("Frame", nil, self.frame)
    self.legendRow:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 16, -42)
    self.legendRow:SetSize(CANVAS_W, 14)

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

    -- Also clear legend row children
    if self._legendWidgets then
        for _, w in ipairs(self._legendWidgets) do
            if w and w.Hide then w:Hide() end
        end
    end
    self._legendWidgets = {}

    if not session then
        self:_label(8, 0, "No session data.", "GameFontHighlight")
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

    -- ─── Legend strip (color swatches + confidence pill) ────────────────────
    self:_renderLegend(session)

    -- Determine data source
    local useTimeline = hasTimelineEvents(session)
    local rawEvents   = session.rawEvents or {}

    -- Per-lane source labels
    local laneSourceLabels = self:_buildLaneSourceLabels(session, useTimeline)

    -- Lane backgrounds + labels + source pills
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
        -- Per-lane source pill at the right end of the lane label area
        local srcInfo = laneSourceLabels[i]
        if srcInfo then
            local colors = SOURCE_PILL_COLORS[srcInfo.key] or SOURCE_PILL_COLORS.estimated
            local pill = ns.Widgets.CreatePill(self.canvas, 46, 14, colors.bg, colors.border)
            pill:SetPoint("TOPLEFT", self.canvas, "TOPLEFT",
                LABEL_W + plotW + 2,
                -(y + math.floor((LANE_H - 14) / 2)))
            pill:SetData(srcInfo.text, Theme.textMuted)
            self:_add(pill)
        end
    end

    -- ─── Render lane data ───────────────────────────────────────────────────
    if useTimeline then
        self:_renderFromTimeline(session.timelineEvents, toPx, displayDuration)
    else
        self:_renderFromRawEvents(rawEvents, session, toPx, displayDuration)
    end

    -- === Death marker (vertical red line) ===
    local deathOffset = self:_findDeathOffset(session, useTimeline, rawEvents)
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
    local effectiveRawEvents = useTimeline
        and self:_syntheticRawEventsFromTimeline(session.timelineEvents)
        or rawEvents
    self:_renderCards(session, effectiveRawEvents, deathOffset)
end

-- ─── Legend rendering ─────────────────────────────────────────────────────────

function ReplayView:_renderLegend(session)
    local legendEntries = {
        { color = { LANE_DEFS[1].r, LANE_DEFS[1].g, LANE_DEFS[1].b, LANE_DEFS[1].a }, label = "Offense" },
        { color = { LANE_DEFS[2].r, LANE_DEFS[2].g, LANE_DEFS[2].b, LANE_DEFS[2].a }, label = "Defense" },
        { color = { LANE_DEFS[3].r, LANE_DEFS[3].g, LANE_DEFS[3].b, LANE_DEFS[3].a }, label = "CC In" },
        { color = { LANE_DEFS[4].r, LANE_DEFS[4].g, LANE_DEFS[4].b, LANE_DEFS[4].a }, label = "Kill Window" },
        { color = { 1.0, 0.20, 0.20, 0.88 }, label = "\226\151\134 Death" },
    }

    local legend = ns.Widgets.CreateMiniLegend(self.legendRow, legendEntries, 10)
    legend:SetPoint("LEFT", self.legendRow, "LEFT", 0, 0)
    self._legendWidgets[#self._legendWidgets + 1] = legend

    -- Confidence pill anchored to the right of the legend
    local confidence = session
        and session.captureQuality
        and session.captureQuality.confidence
        or nil
    if confidence then
        local pill = ns.Widgets.CreateConfidencePill(self.legendRow, confidence)
        pill:SetPoint("LEFT", legend, "RIGHT", 12, 0)
        self._legendWidgets[#self._legendWidgets + 1] = pill
    end
end

-- ─── Per-lane source labels ──────────────────────────────────────────────────

function ReplayView:_buildLaneSourceLabels(session, useTimeline)
    -- Returns { [laneIndex] = { key = "state"|"timeline"|..., text = "..." } }
    local labels = {}

    if useTimeline then
        labels[1] = { key = "timeline", text = "timeline" }
        labels[2] = { key = "timeline", text = "timeline" }

        -- CC lane: check if timeline cc_received events trace to LOC source
        local ccEvents = filterTimeline(session.timelineEvents, TIMELINE_LANE.CC_RECEIVED)
        local hasLocSource = false
        for _, ev in ipairs(ccEvents) do
            if ev.source == "loss_of_control" or ev.provenance == "loss_of_control" then
                hasLocSource = true
                break
            end
        end
        labels[3] = hasLocSource
            and { key = "loc", text = "loc" }
            or  { key = "timeline", text = "timeline" }

        labels[4] = { key = "estimated", text = "estimated" }
    else
        labels[1] = { key = "state", text = "state" }
        labels[2] = { key = "state", text = "state" }

        -- CC lane from rawEvents uses ccReceived which comes from LOC events
        local ccList = session.ccReceived or {}
        labels[3] = #ccList > 0
            and { key = "loc", text = "loc" }
            or  { key = "state", text = "state" }

        labels[4] = { key = "estimated", text = "estimated" }
    end

    return labels
end

-- ─── Timeline-based rendering (v6+ sessions) ────────────────────────────────

function ReplayView:_renderFromTimeline(timelineEvents, toPx, displayDuration)
    -- Lane 1: Offense — player_cast events that are NOT defensive
    local castEvents = filterTimeline(timelineEvents, TIMELINE_LANE.PLAYER_CAST)
    for _, ev in ipairs(castEvents) do
        local off = ev.timestampOffset or ev.t or 0
        if off <= displayDuration and not isDefensiveSpell(ev.spellId) then
            local d = LANE_DEFS[1]
            self:_dot(toPx(off), laneY(1), d.r, d.g, d.b, d.a)
        end
    end

    -- Lane 2: Defense — player_cast events where spellId is defensive
    for _, ev in ipairs(castEvents) do
        local off = ev.timestampOffset or ev.t or 0
        if off <= displayDuration and isDefensiveSpell(ev.spellId) then
            local d = LANE_DEFS[2]
            self:_dot(toPx(off), laneY(2), d.r, d.g, d.b, d.a)
        end
    end

    -- Lane 3: CC Received — cc_received lane events (bars)
    local d3 = LANE_DEFS[3]
    local ccEvents = filterTimeline(timelineEvents, TIMELINE_LANE.CC_RECEIVED)
    for _, ev in ipairs(ccEvents) do
        local start = ev.timestampOffset or ev.t or 0
        local dur   = ev.duration or 2
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(start + dur, displayDuration))
            self:_bar(x1, x2, laneY(3), d3.r, d3.g, d3.b, d3.a)
        end
    end

    -- Lane 4: Kill Window — kill_window lane events (bars)
    local d4 = LANE_DEFS[4]
    local kwEvents = filterTimeline(timelineEvents, TIMELINE_LANE.KILL_WINDOW)
    for _, ev in ipairs(kwEvents) do
        local start = ev.timestampOffset or ev.t or 0
        local stop  = ev.endOffset or ev.closedAt or (start + (ev.duration or 5))
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(stop, displayDuration))
            local r, g, b, a = d4.r, d4.g, d4.b, d4.a
            if ev.converted then r, g, b = 0.44, 0.82, 0.60 end
            self:_bar(x1, x2, laneY(4), r, g, b, a)
        end
    end
end

-- ─── Raw events rendering (legacy / fallback) ───────────────────────────────

function ReplayView:_renderFromRawEvents(rawEvents, session, toPx, displayDuration)
    -- Lane 1: Offensive cast dots
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[1]
                self:_dot(toPx(off), laneY(1), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- Lane 2: Defensive cast dots
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "cast" and ev.sourceMine and ev.isCooldownCast then
            local off = ev.timestampOffset or 0
            if off <= displayDuration then
                local d = LANE_DEFS[2]
                self:_dot(toPx(off), laneY(2), d.r, d.g, d.b, d.a)
            end
        end
    end

    -- Lane 3: CC Received bars
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

    -- Lane 4: Kill window bars
    local d4 = LANE_DEFS[4]
    for _, kw in ipairs(session.killWindows or {}) do
        local start = kw.openedAt or 0
        local stop  = kw.closedAt or (start + 5)
        if start <= displayDuration then
            local x1 = toPx(start)
            local x2 = toPx(math.min(stop, displayDuration))
            local r, g, b, a = d4.r, d4.g, d4.b, d4.a
            if kw.converted then r, g, b = 0.44, 0.82, 0.60 end
            self:_bar(x1, x2, laneY(4), r, g, b, a)
        end
    end
end

-- ─── Death offset resolution ─────────────────────────────────────────────────

function ReplayView:_findDeathOffset(session, useTimeline, rawEvents)
    if useTimeline then
        local deathEvents = filterTimeline(session.timelineEvents, TIMELINE_LANE.DEATH)
        for _, ev in ipairs(deathEvents) do
            local off = ev.timestampOffset or ev.t
            if off then return off end
        end
    end
    -- Fallback: search rawEvents
    for _, ev in ipairs(rawEvents) do
        if ev.eventType == "death" and ev.destMine then
            return ev.timestampOffset
        end
    end
    return nil
end

-- ─── Synthetic raw events for coaching cards (timeline mode) ─────────────────

function ReplayView:_syntheticRawEventsFromTimeline(timelineEvents)
    local synthetic = {}
    local castEvents = filterTimeline(timelineEvents, TIMELINE_LANE.PLAYER_CAST)
    for _, ev in ipairs(castEvents) do
        synthetic[#synthetic + 1] = {
            eventType       = "cast",
            sourceMine      = true,
            timestampOffset = ev.timestampOffset or ev.t or 0,
            spellId         = ev.spellId,
            isCooldownCast  = isDefensiveSpell(ev.spellId),
        }
    end
    local deathEvents = filterTimeline(timelineEvents, TIMELINE_LANE.DEATH)
    for _, ev in ipairs(deathEvents) do
        synthetic[#synthetic + 1] = {
            eventType       = "death",
            destMine        = true,
            timestampOffset = ev.timestampOffset or ev.t or 0,
        }
    end
    return synthetic
end

-- ─── Coaching cards ──────────────────────────────────────────────────────────

function ReplayView:_renderCards(session, rawEvents, deathOffset)
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
