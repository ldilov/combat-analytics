local _, ns = ...

-- UI/Insights/Sections/FightTimelineRead.lua
--
-- "Fight Timeline Read" section of the new Insights tab. Renders a
-- 5-node horizontal strip summarising one fight, with a click-to-expand
-- inline drawer that surfaces the matching metric value plus any coaching
-- reason codes tied to that node.
--
-- All node data comes from the pure-logic module ns.InsightsTimeline. This
-- file is purely a renderer.

local Theme           = ns.Widgets.THEME
local Timeline        = ns.InsightsTimeline

local NODE_HEIGHT     = 64
local STRIP_HEIGHT    = NODE_HEIGHT + 26      -- label + value + indicator
local DRAWER_PAD_Y    = 12
local DRAWER_LINE_H   = 16
local DRAWER_MIN_H    = 36
local NODE_GAP        = 6
local INDICATOR_SIZE  = 14

local STATUS_COLOR = {
    good    = Theme.success,
    late    = Theme.warning,
    miss    = Theme.warning,
    loss    = Theme.warning,
    unknown = Theme.textMuted,
}

local STATUS_BADGE = {
    good    = "on time",
    late    = "late",
    miss    = "missed",
    loss    = "loss",
    unknown = "no data",
}

local FightTimelineRead = {}

-- ---------------------------------------------------------------------------
-- Node frame factory
-- ---------------------------------------------------------------------------
local function createNodeFrame(parent, width)
    local node = ns.Widgets.CreateSurface(parent, width, NODE_HEIGHT, Theme.panel, Theme.border)
    node:EnableMouse(true)

    node.indicator = node:CreateTexture(nil, "ARTWORK")
    node.indicator:SetTexture("Interface\\Buttons\\WHITE8x8")
    node.indicator:SetSize(INDICATOR_SIZE, INDICATOR_SIZE)
    node.indicator:SetPoint("TOP", node, "TOP", 0, -8)

    node.label = node:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    node.label:SetPoint("TOP", node.indicator, "BOTTOM", 0, -4)
    node.label:SetTextColor(unpack(Theme.text))

    node.value = node:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    node.value:SetPoint("TOP", node.label, "BOTTOM", 0, -2)
    node.value:SetTextColor(unpack(Theme.text))

    node.statusBadge = node:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    node.statusBadge:SetPoint("BOTTOM", node, "BOTTOM", 0, 4)
    node.statusBadge:SetTextColor(unpack(Theme.textMuted))

    function node:Apply(descriptor)
        local color = STATUS_COLOR[descriptor.status] or Theme.textMuted
        self.indicator:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        self.label:SetText(descriptor.label or "")
        self.value:SetText(descriptor.valueText or "--")
        self.value:SetTextColor(color[1], color[2], color[3], color[4] or 1)
        self.statusBadge:SetText(STATUS_BADGE[descriptor.status] or "")
        self._descriptor = descriptor
    end

    function node:SetActive(active)
        self._active = active and true or false
        if self._active then
            ns.Widgets.SetBackdropColors(self, Theme.panelHover, Theme.accent)
        else
            ns.Widgets.SetBackdropColors(self, Theme.panel, Theme.border)
        end
    end

    node:SetScript("OnEnter", function(self)
        if not self._active then
            ns.Widgets.SetBackdropColors(self, Theme.panelHover, Theme.borderStrong)
        end
    end)
    node:SetScript("OnLeave", function(self)
        if not self._active then
            ns.Widgets.SetBackdropColors(self, Theme.panel, Theme.border)
        end
    end)

    return node
end

local function reasonLine(suggestion)
    local rc = suggestion.reasonCode or "UNKNOWN"
    local sev = suggestion.severity or "info"
    return string.format("- %s   [%s]", rc, sev)
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function FightTimelineRead:Build(canvas, anchor, width)
    self.canvas = canvas
    self.width  = width or 760
    self.activeNodeKey = nil

    self.title = ns.Widgets.CreateSectionTitle(
        canvas, "Fight Timeline Read",
        "TOPLEFT", anchor, "BOTTOMLEFT", 0, -18
    )
    self.caption = ns.Widgets.CreateCaption(
        canvas, "Five moments per fight. Click any node to inspect related coaching notes.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    self.row = CreateFrame("Frame", nil, canvas)
    self.row:SetSize(self.width, STRIP_HEIGHT)
    self.row:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)

    local nodeCount = #Timeline.NODE_ORDER
    local nodeWidth = math.floor((self.width - (nodeCount - 1) * NODE_GAP) / nodeCount)

    self.nodes = {}
    for i, key in ipairs(Timeline.NODE_ORDER) do
        local node = createNodeFrame(self.row, nodeWidth)
        if i == 1 then
            node:SetPoint("TOPLEFT", self.row, "TOPLEFT", 0, 0)
        else
            node:SetPoint("TOPLEFT", self.nodes[i - 1], "TOPRIGHT", NODE_GAP, 0)
        end
        node._nodeKey = key
        node:SetScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then
                self:OnNodeClick(key)
            end
        end)
        self.nodes[i] = node
    end

    self.drawer = ns.Widgets.CreateSurface(canvas, self.width, DRAWER_MIN_H, Theme.panelAlt, Theme.border)
    self.drawer:SetPoint("TOPLEFT", self.row, "BOTTOMLEFT", 0, -8)
    self.drawer:Hide()

    self.drawer.title = self.drawer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.drawer.title:SetPoint("TOPLEFT", self.drawer, "TOPLEFT", 10, -8)
    self.drawer.title:SetTextColor(unpack(Theme.text))

    self.drawer.body = self.drawer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.drawer.body:SetPoint("TOPLEFT", self.drawer.title, "BOTTOMLEFT", 0, -6)
    self.drawer.body:SetPoint("RIGHT", self.drawer, "RIGHT", -10, 0)
    self.drawer.body:SetJustifyH("LEFT")
    self.drawer.body:SetJustifyV("TOP")
    self.drawer.body:SetTextColor(unpack(Theme.textMuted))

    self._lastNodes = {}
    self._lastSuggestions = {}
end

-- ---------------------------------------------------------------------------
-- Refresh — recompute node data from session + suggestions.
-- Returns the total height the section currently occupies, so the parent
-- view can extend the canvas.
-- ---------------------------------------------------------------------------
function FightTimelineRead:Refresh(session, suggestions, visible)
    if not self.row then return 0 end

    if visible == false then
        self.title:Hide()
        self.caption:Hide()
        self.row:Hide()
        self.drawer:Hide()
        return 0
    end

    self.title:Show()
    self.caption:Show()
    self.row:Show()

    local nodes = Timeline.BuildNodes(session)
    self._lastNodes = nodes
    self._lastSuggestions = suggestions or {}

    for i, frame in ipairs(self.nodes) do
        local descriptor = nodes[i]
        if descriptor then
            frame:Apply(descriptor)
            frame:SetActive(self.activeNodeKey == descriptor.key)
            frame:Show()
        else
            frame:Hide()
        end
    end

    if self.activeNodeKey then
        self:_RenderDrawer(self.activeNodeKey)
    else
        self.drawer:Hide()
    end

    return self:_Height()
end

-- ---------------------------------------------------------------------------
-- Click handler
-- ---------------------------------------------------------------------------
function FightTimelineRead:OnNodeClick(nodeKey)
    if self.activeNodeKey == nodeKey then
        self.activeNodeKey = nil
        for _, frame in ipairs(self.nodes) do frame:SetActive(false) end
        self.drawer:Hide()
    else
        self.activeNodeKey = nodeKey
        for _, frame in ipairs(self.nodes) do
            frame:SetActive(frame._nodeKey == nodeKey)
        end
        self:_RenderDrawer(nodeKey)
    end
    if self._onLayoutChange then self._onLayoutChange() end
end

function FightTimelineRead:_RenderDrawer(nodeKey)
    local descriptor
    for _, n in ipairs(self._lastNodes or {}) do
        if n.key == nodeKey then descriptor = n; break end
    end
    if not descriptor then
        self.drawer:Hide()
        return
    end

    local titleText = string.format("%s — %s",
        descriptor.label or nodeKey,
        STATUS_BADGE[descriptor.status] or descriptor.status or "")

    local lines = { descriptor.detail or "" }
    local reasons = Timeline.GetReasonsForNode(nodeKey, self._lastSuggestions)
    if #reasons > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Related coaching notes:"
        for _, s in ipairs(reasons) do
            lines[#lines + 1] = reasonLine(s)
        end
    end

    self.drawer.title:SetText(titleText)
    self.drawer.body:SetText(table.concat(lines, "\n"))

    local approxLines = math.max(2, #lines)
    local height = math.max(DRAWER_MIN_H, DRAWER_PAD_Y + 18 + DRAWER_LINE_H * approxLines)
    height = math.min(height, 220)
    self.drawer:SetHeight(height)
    self.drawer:Show()
end

function FightTimelineRead:_Height()
    -- title (18) + gap + caption (18) + gap + strip + gap + drawer (when visible)
    local h = 18 + 4 + 18 + 8 + STRIP_HEIGHT
    if self.drawer:IsShown() then
        h = h + 8 + (self.drawer:GetHeight() or DRAWER_MIN_H)
    end
    return h
end

function FightTimelineRead:OnLayoutChange(callback)
    self._onLayoutChange = callback
end

ns.InsightsFightTimelineRead = FightTimelineRead
return FightTimelineRead
