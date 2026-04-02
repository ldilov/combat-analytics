local _, ns = ...

local Constants = ns.Constants
local Theme     = ns.Widgets.THEME

-- ── palette ──────────────────────────────────────────────────────────────────
local COLOR_A   = { 0.40, 0.78, 1.00, 1.0 }
local COLOR_B   = { 0.96, 0.74, 0.38, 1.0 }

-- Confidence badge colors: NO_DATA=gray, LOW=yellow/orange, MEDIUM=blue, HIGH=green
local CONF_COLOR = {
    [Constants.CONFIDENCE_TIER.NO_DATA] = { 0.55, 0.55, 0.55, 1.0 },
    [Constants.CONFIDENCE_TIER.LOW]     = { 0.96, 0.74, 0.38, 1.0 },
    [Constants.CONFIDENCE_TIER.MEDIUM]  = { 0.40, 0.78, 1.00, 1.0 },
    [Constants.CONFIDENCE_TIER.HIGH]    = { 0.44, 0.82, 0.60, 1.0 },
}

local CONF_LABEL = {
    [Constants.CONFIDENCE_TIER.NO_DATA] = "No Data",
    [Constants.CONFIDENCE_TIER.LOW]     = "Low",
    [Constants.CONFIDENCE_TIER.MEDIUM]  = "Medium",
    [Constants.CONFIDENCE_TIER.HIGH]    = "High",
}

local CONTEXT_OPTIONS = {
    { key = "",                               label = "All Contexts"   },
    { key = Constants.CONTEXT.ARENA,          label = "Arena"          },
    { key = Constants.CONTEXT.BATTLEGROUND,   label = "Battleground"   },
    { key = Constants.CONTEXT.DUEL,           label = "Duel"           },
    { key = Constants.CONTEXT.WORLD_PVP,      label = "World PvP"      },
    { key = Constants.CONTEXT.TRAINING_DUMMY, label = "Training Dummy" },
    { key = Constants.CONTEXT.GENERAL,        label = "General"        },
}

local SORT_OPTIONS = {
    { key = "recent",     label = "Most Recent"      },
    { key = "sessions",   label = "Session Count"    },
    { key = "winrate",    label = "Win Rate in Scope"},
    { key = "name",       label = "Name A–Z"         },
}

local DIFF_MAX_COMPACT = 3

-- ── stat freshness display maps ───────────────────────────────────────────────

local FRESHNESS_LABEL = {
    [Constants.SNAPSHOT_FRESHNESS.FRESH]           = "Fresh",
    [Constants.SNAPSHOT_FRESHNESS.PENDING_REFRESH] = "Pending",
    [Constants.SNAPSHOT_FRESHNESS.DEGRADED]        = "Degraded",
    [Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE]     = "N/A",
}

local FRESHNESS_COLOR = {
    [Constants.SNAPSHOT_FRESHNESS.FRESH]           = { 0.44, 0.82, 0.60, 1.0 },
    [Constants.SNAPSHOT_FRESHNESS.PENDING_REFRESH] = { 0.96, 0.84, 0.20, 1.0 },
    [Constants.SNAPSHOT_FRESHNESS.DEGRADED]        = { 0.96, 0.60, 0.20, 1.0 },
    [Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE]     = { 0.55, 0.55, 0.55, 1.0 },
}

-- ── stat keys ─────────────────────────────────────────────────────────────────

local STAT_ROWS = {
    { key = "critPct",           label = "Crit"        },
    { key = "hastePct",          label = "Haste"       },
    { key = "masteryPct",        label = "Mastery"     },
    { key = "versDamageDonePct", label = "Versatility" },
}

-- ── visual constants ──────────────────────────────────────────────────────────

local BAR_MAX_WIDTH   = 280   -- max pixel width of a stat bar (at 50% stat)
local BAR_HEIGHT      = 10
local BAR_TRACK_COLOR = { 0.10, 0.10, 0.12, 0.8 }
local DIAMOND_RADIUS  = 80
local DIAMOND_SIZE    = 200

-- ── geometry helpers ──────────────────────────────────────────────────────────

local function DrawLine(parent, x1, y1, x2, y2, thickness, r, g, b, a)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.5 then return nil end
    local angle = math.atan2(dy, dx)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8x8")
    line:SetVertexColor(r, g, b, a or 1)
    line:SetSize(length, thickness)
    local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    line:SetPoint("CENTER", parent, "CENTER", cx, cy)
    line:SetRotation(-angle)
    return line
end

local function statToRadius(statPct)
    return math.min((statPct or 0) / 50, 1) * DIAMOND_RADIUS
end

-- Win rate → background color (returns r,g,b,a for SetColorTexture).
-- See also winRateColor() in _renderSingleBuildOverview which returns a
-- table for SetTextColor. Same thresholds, different opacity/brightness.
local function wrColor(rate)
    if rate > 0.55 then return 0.20, 0.50, 0.25, 0.6
    elseif rate >= 0.45 then return 0.50, 0.45, 0.15, 0.6
    else return 0.50, 0.20, 0.20, 0.6
    end
end

-- ── module table ──────────────────────────────────────────────────────────────
local BuildComparatorView = {
    viewId          = "builds",
    _elems          = {},
    _sortKey        = "recent",
    _searchText     = "",
    _selectedA      = nil,
    _selectedB      = nil,
    _scope          = nil,
    _diffExpanded   = false,
    _profilesCache  = nil,
}

-- ── service helpers ──────────────────────────────────────────────────────────

local function getCatalog()
    return ns.Addon:GetModule("BuildCatalogService")
end

local function getComparison()
    return ns.Addon:GetModule("BuildComparisonService")
end

local function getStore()
    return ns.Addon:GetModule("CombatStore")
end

-- ── element pool (forward declarations, defined after _clearDiff below) ──────

-- ── profile list helpers ──────────────────────────────────────────────────────

-- Return sorted+filtered profile list for the selector panels.
local function filterAndSort(profiles, searchText, sortKey, scope, compSvc)
    if not profiles then return {} end

    local lower = searchText and searchText:lower() or ""

    -- Build filtered list; always keep index-1 (Current Live Build) pinned.
    local pinned = profiles[1]
    local rest   = {}
    for i = 2, #profiles do
        local p  = profiles[i]
        local catalog = getCatalog()
        local label = catalog and catalog:GetDisplayLabel(p.buildId) or (p.buildId or "?")
        if lower == "" or label:lower():find(lower, 1, true) then
            rest[#rest + 1] = p
        end
    end

    -- Sort rest
    if sortKey == "sessions" then
        table.sort(rest, function(a, b)
            return (a.sessionCount or 0) > (b.sessionCount or 0)
        end)
    elseif sortKey == "winrate" and compSvc and scope then
        -- Compute win rates on demand (small N, no caching needed here)
        local store = getStore()
        local rateFor = {}
        for _, p in ipairs(rest) do
            local sessions = store and store:GetSessionsForBuild(p.buildId, scope) or {}
            local wins = 0
            for _, s in ipairs(sessions) do
                if s.result == Constants.SESSION_RESULT.WON then
                    wins = wins + 1
                end
            end
            rateFor[p.buildId] = #sessions > 0 and (wins / #sessions) or -1
        end
        table.sort(rest, function(a, b)
            return (rateFor[a.buildId] or -1) > (rateFor[b.buildId] or -1)
        end)
    elseif sortKey == "name" then
        local catalog = getCatalog()
        table.sort(rest, function(a, b)
            local la = catalog and catalog:GetDisplayLabel(a.buildId) or ""
            local lb = catalog and catalog:GetDisplayLabel(b.buildId) or ""
            return la:lower() < lb:lower()
        end)
    else -- "recent" (default) — already sorted by lastSeenAt desc from catalog
        -- no-op; catalog returns in desc order already
    end

    -- Rebuild with pinned first
    local result = {}
    if pinned then result[1] = pinned end
    for _, p in ipairs(rest) do
        result[#result + 1] = p
    end
    return result
end


-- ── Build ─────────────────────────────────────────────────────────────────────

function BuildComparatorView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.frame:Hide()

    -- Title
    self.title = ns.Widgets.CreateSectionTitle(
        self.frame, "Build Comparator",
        "TOPLEFT", self.frame, "TOPLEFT", 16, -16)

    -- Caption (T050)
    self.caption = ns.Widgets.CreateCaption(
        self.frame,
        "Compare your current build against a previous setup — including secondary stats.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    -- Freshness warning banner (T027) — shown when snapshot is degraded
    self.freshnessBanner = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.freshnessBanner:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -6)
    self.freshnessBanner:SetTextColor(0.96, 0.74, 0.38, 1.0)
    self.freshnessBanner:SetText("(!) Build data loading -- talent information may be incomplete")
    self.freshnessBanner:Hide()

    -- Controls row: search box + sort dropdown
    local ctrlAnchor = self.freshnessBanner
    self.searchBox = CreateFrame("EditBox", nil, self.frame, "InputBoxTemplate")
    self.searchBox:SetSize(180, 22)
    self.searchBox:SetPoint("TOPLEFT", ctrlAnchor, "BOTTOMLEFT", 0, -8)
    self.searchBox:SetAutoFocus(false)
    self.searchBox:SetScript("OnTextChanged", function(eb, userInput)
        if userInput then
            self._searchText = eb:GetText()
            self._profilesCache = nil
            self:Refresh()
        end
    end)
    self.searchBox:SetScript("OnEscapePressed", function(eb)
        eb:ClearFocus()
    end)
    -- placeholder
    self.searchPlaceholder = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.searchPlaceholder:SetPoint("LEFT", self.searchBox, "LEFT", 6, 0)
    self.searchPlaceholder:SetTextColor(0.45, 0.50, 0.56, 1.0)
    self.searchPlaceholder:SetText("Search builds…")
    self.searchBox:HookScript("OnTextChanged", function(eb)
        if eb:GetText() == "" then
            self.searchPlaceholder:Show()
        else
            self.searchPlaceholder:Hide()
        end
    end)
    self.searchBox:HookScript("OnEditFocusGained", function()
        self.searchPlaceholder:Hide()
    end)
    self.searchBox:HookScript("OnEditFocusLost", function(eb)
        if eb:GetText() == "" then self.searchPlaceholder:Show() end
    end)

    -- Sort dropdown (simple button-driven cycle)
    self.sortBtn = ns.Widgets.CreateButton(self.frame, "Sort: Most Recent", 160, 22)
    self.sortBtn:SetPoint("LEFT", self.searchBox, "RIGHT", 8, 0)
    self.sortBtn:SetScript("OnClick", function()
        self:_cycleSortKey()
    end)

    -- Scope controls row
    local scopeY = -8
    self.scopeLabel = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.scopeLabel:SetPoint("TOPLEFT", self.searchBox, "BOTTOMLEFT", 0, scopeY)
    self.scopeLabel:SetTextColor(unpack(Theme.textMuted))
    self.scopeLabel:SetText("Scope:")

    -- Context dropdown
    self.contextBtn = ns.Widgets.CreateButton(self.frame, "All Contexts", 130, 22)
    self.contextBtn:SetPoint("LEFT", self.scopeLabel, "RIGHT", 6, 0)
    self.contextBtn:SetScript("OnClick", function()
        self:_cycleContextScope()
    end)

    -- Scope description (updated after selection)
    self.scopeDesc = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.scopeDesc:SetPoint("LEFT", self.contextBtn, "RIGHT", 8, 0)
    self.scopeDesc:SetTextColor(unpack(Theme.textMuted))
    self.scopeDesc:SetText("")

    -- Quick-actions bar — T055: LAYOUT tokens; T056: swapBtn right-anchored to avoid overlap
    local L      = ns.Widgets.LAYOUT
    local btnH   = L.ROW_HEIGHT + 2
    local btnGap = L.ROW_GAP + 2

    self.vsPrevBtn = ns.Widgets.CreateButton(self.frame, "vs Previous", 90, btnH)
    self.vsPrevBtn:SetPoint("TOPLEFT", self.scopeLabel, "BOTTOMLEFT", 0, -L.SECTION_TOP_PAD)
    self.vsPrevBtn:SetScript("OnClick", function()
        self:_selectCurrentVsPrevious()
    end)

    self.vsBestBtn = ns.Widgets.CreateButton(self.frame, "vs Best", 80, btnH)
    self.vsBestBtn:SetPoint("LEFT", self.vsPrevBtn, "RIGHT", btnGap, 0)
    self.vsBestBtn:SetScript("OnClick", function()
        self:_selectCurrentVsBest()
    end)

    self.vsMostBtn = ns.Widgets.CreateButton(self.frame, "vs Most Used", 100, btnH)
    self.vsMostBtn:SetPoint("LEFT", self.vsBestBtn, "RIGHT", btnGap, 0)
    self.vsMostBtn:SetScript("OnClick", function()
        self:_selectCurrentVsMostUsed()
    end)

    -- T056: Swap button anchored to right edge — TOP aligns with vs-buttons, no left overlap
    self.swapBtn = ns.Widgets.CreateButton(self.frame, "Swap A <> B", L.CARD_PAD * 2 + 68, btnH)
    self.swapBtn:SetPoint("TOP", self.vsPrevBtn, "TOP", 0, 0)
    self.swapBtn:SetPoint("RIGHT", self.frame, "RIGHT", -L.CARD_PAD, 0)
    self.swapBtn:SetScript("OnClick", function()
        local tmp = self._selectedA
        self._selectedA = self._selectedB
        self._selectedB = tmp
        self:Refresh()
    end)

    -- Single-build empty state (T029) — shown when < 2 profiles
    self.emptyOneBuild = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyOneBuild:SetPoint("CENTER", self.frame, "CENTER", 0, -40)
    self.emptyOneBuild:SetWidth(400)
    self.emptyOneBuild:SetJustifyH("CENTER")
    self.emptyOneBuild:SetJustifyV("MIDDLE")
    self.emptyOneBuild:SetWordWrap(true)
    self.emptyOneBuild:SetTextColor(unpack(Theme.textMuted))
    self.emptyOneBuild:SetText(
        "Only one talent build recorded so far.\n"
        .. "Switch to a different talent setup and play a match to create a second build for comparison.")
    self.emptyOneBuild:Hide()

    -- T043/T044: Capture and Refresh stat-profile buttons (below the vs-buttons row, left-aligned)
    self.captureBtn = ns.Widgets.CreateButton(self.frame, "Capture", 100, 22)
    self.captureBtn:SetPoint("TOPLEFT", self.vsPrevBtn, "BOTTOMLEFT", 0, -btnGap - 2)
    self.captureBtn:SetScript("OnClick", function()
        local catalogSvc = ns.Addon:GetModule("BuildCatalogService")
        if not catalogSvc then return end
        C_Timer.After(0, function()
            local res = catalogSvc:CaptureAndPersistCurrentBuild()
            if res and res.ok then
                self.statStatusText:SetText("|cFF44D264Captured!|r")
                self.statStatusText:Show()
                C_Timer.After(3, function()
                    if self.statStatusText then self.statStatusText:SetText("") end
                end)
                self:Refresh()
            else
                local reason = (res and res.reason) or "unknown_error"
                self.statStatusText:SetText("|cFFFF4444" .. reason .. "|r")
                self.statStatusText:Show()
            end
        end)
    end)

    self.refreshLiveBtn = ns.Widgets.CreateButton(self.frame, "Refresh Stats", 110, 22)
    self.refreshLiveBtn:SetPoint("LEFT", self.captureBtn, "RIGHT", 6, 0)
    self.refreshLiveBtn:SetScript("OnClick", function()
        local catalogSvc = ns.Addon:GetModule("BuildCatalogService")
        if not catalogSvc then return end
        local profile = catalogSvc:GetCurrentLiveStatProfile()
        if profile then
            self.statStatusText:SetText("|cFF44D264Stats refreshed|r")
            self.statStatusText:Show()
            C_Timer.After(3, function()
                if self.statStatusText then self.statStatusText:SetText("") end
            end)
            self:Refresh()
        else
            self.statStatusText:SetText("|cFFFF4444Stats unavailable|r")
            self.statStatusText:Show()
        end
    end)

    -- Status text for capture/refresh feedback
    self.statStatusText = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.statStatusText:SetPoint("LEFT", self.refreshLiveBtn, "RIGHT", 8, 0)
    self.statStatusText:SetText("")

    -- T045: "no stat snapshot" hint label for the selected left build
    -- This is a static anchor spacer (always present but may be hidden).
    self.noStatHint = self.frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.noStatHint:SetPoint("TOPLEFT", self.captureBtn, "BOTTOMLEFT", 0, -4)
    self.noStatHint:SetTextColor(0.55, 0.55, 0.55, 1.0)
    self.noStatHint:SetText("No stat snapshot — click Capture")
    self.noStatHint:Hide()

    -- Invisible spacer frame to act as a stable anchor for the selector panels,
    -- sitting below the capture row regardless of whether noStatHint is visible.
    self.captureSpacer = CreateFrame("Frame", nil, self.frame)
    self.captureSpacer:SetSize(1, 18)
    self.captureSpacer:SetPoint("TOPLEFT", self.captureBtn, "BOTTOMLEFT", 0, -4)

    -- Dropdown selectors (replace old scroll list panels)
    self.dropdownA = self:_buildDropdown("A", COLOR_A)
    self.dropdownA.button:SetPoint("TOPLEFT", self.captureSpacer, "BOTTOMLEFT", 0, -8)

    self.dropdownB = self:_buildDropdown("B", COLOR_B)
    self.dropdownB.button:SetPoint("LEFT", self.dropdownA.button, "RIGHT", 8, 0)

    -- Re-anchor swap button next to dropdowns
    self.swapBtn:ClearAllPoints()
    self.swapBtn:SetPoint("LEFT", self.dropdownB.button, "RIGHT", 8, 0)

    -- Scrollable content area (visual graphics go here)
    self.diffShell, self.diffScroll, self.diffCanvas =
        ns.Widgets.CreateScrollCanvas(self.frame, 660, 260)
    self.diffShell:SetPoint("TOPLEFT", self.dropdownA.button, "BOTTOMLEFT", 0, -8)
    self.diffShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    return self.frame
end

-- Build a compact dropdown selector for side A or B.
-- Returns a table: { button, popup, side, _rowButtons }
function BuildComparatorView:_buildDropdown(side, color)
    local dd = { side = side, color = color, _rowButtons = {} }

    -- Toggle button (280px wide, 26px tall)
    dd.button = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
    dd.button:SetSize(280, 26)
    ns.Widgets.ApplyBackdrop(dd.button, Theme.panel, Theme.border)

    dd.buttonText = dd.button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dd.buttonText:SetPoint("LEFT", dd.button, "LEFT", 8, 0)
    dd.buttonText:SetPoint("RIGHT", dd.button, "RIGHT", -8, 0)
    dd.buttonText:SetJustifyH("LEFT")
    dd.buttonText:SetWordWrap(false)
    dd.buttonText:SetTextColor(color[1], color[2], color[3], 1.0)
    dd.buttonText:SetText("Build " .. side .. ": (none)")

    -- Hover highlight
    dd.button:SetScript("OnEnter", function(btn)
        btn:SetBackdropBorderColor(color[1], color[2], color[3], 0.8)
    end)
    dd.button:SetScript("OnLeave", function(btn)
        btn:SetBackdropBorderColor(Theme.border[1], Theme.border[2], Theme.border[3], Theme.border[4])
    end)

    -- Popup frame (scrollable, max 150px tall)
    dd.popup = CreateFrame("Frame", nil, dd.button, "BackdropTemplate")
    dd.popup:SetPoint("TOPLEFT", dd.button, "BOTTOMLEFT", 0, -2)
    dd.popup:SetSize(280, 150)
    dd.popup:SetFrameStrata("DIALOG")
    ns.Widgets.ApplyBackdrop(dd.popup, Theme.panel, Theme.border)
    dd.popup:Hide()

    dd.popupScroll = CreateFrame("ScrollFrame", nil, dd.popup, "UIPanelScrollFrameTemplate")
    dd.popupScroll:SetPoint("TOPLEFT", dd.popup, "TOPLEFT", 4, -4)
    dd.popupScroll:SetPoint("BOTTOMRIGHT", dd.popup, "BOTTOMRIGHT", -22, 4)

    dd.popupCanvas = CreateFrame("Frame", nil, dd.popupScroll)
    dd.popupCanvas:SetWidth(250)
    dd.popupScroll:SetScrollChild(dd.popupCanvas)

    -- Toggle on button click
    dd.button:SetScript("OnClick", function()
        if dd.popup:IsShown() then
            dd.popup:Hide()
        else
            -- Close the other dropdown first
            local other = (side == "A") and self.dropdownB or self.dropdownA
            if other and other.popup then other.popup:Hide() end
            dd.popup:Show()
        end
    end)

    -- Close on click-outside: full-screen intercept frame (reliable, no polling)
    dd.interceptor = CreateFrame("Button", nil, UIParent)
    dd.interceptor:SetAllPoints(UIParent)
    dd.interceptor:SetFrameStrata("FULLSCREEN")
    dd.interceptor:EnableMouse(true)
    dd.interceptor:SetScript("OnClick", function()
        dd.popup:Hide()
    end)
    dd.interceptor:Hide()

    dd.popup:SetScript("OnShow", function()
        dd.interceptor:Show()
        dd.popup:SetFrameStrata("FULLSCREEN_DIALOG")
    end)
    dd.popup:SetScript("OnHide", function()
        dd.interceptor:Hide()
    end)

    return dd
end

-- Populate a dropdown's popup with the current profile list.
function BuildComparatorView:_populateDropdown(dd, profiles, side)
    -- Reuse existing row frames to prevent frame accumulation (WoW frames
    -- cannot be garbage-collected). Hide excess rows if profile count shrinks.
    dd._rowButtons = dd._rowButtons or {}

    local canvas  = dd.popupCanvas
    local ROW_H   = 22
    local y       = 0
    local catalog = getCatalog()
    local selectedId = (side == "A") and self._selectedA or self._selectedB
    local otherId    = (side == "A") and self._selectedB or self._selectedA

    for i, p in ipairs(profiles) do
        local bid   = p.buildId
        local label = catalog and catalog:GetDisplayLabel(bid) or (bid or "?")
        if p.isCurrentBuild then
            label = "★ " .. label
        end

        local isSelected = (bid == selectedId)
        local isOther    = (bid == otherId)

        -- Reuse or create row frame
        local row = dd._rowButtons[i]
        if not row then
            row = {}
            row.btn = CreateFrame("Button", nil, canvas)
            row.btn:EnableMouse(true)
            row.bg = row.btn:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.fs = row.btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.fs:SetPoint("LEFT", row.btn, "LEFT", 6, 0)
            row.fs:SetJustifyH("LEFT")
            row.fs:SetWordWrap(false)
            dd._rowButtons[i] = row
        end

        row.btn:SetSize(canvas:GetWidth(), ROW_H)
        row.btn:ClearAllPoints()
        row.btn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        row.fs:SetWidth(canvas:GetWidth() - 12)
        row.btn:Show()

        if isSelected then
            row.bg:SetColorTexture(dd.color[1] * 0.3, dd.color[2] * 0.3, dd.color[3] * 0.3, 0.7)
        elseif isOther then
            row.bg:SetColorTexture(0.12, 0.12, 0.12, 0.5)
        else
            row.bg:SetColorTexture(0.06, 0.08, 0.10, 0.0)
        end

        if isOther then
            row.fs:SetTextColor(0.40, 0.40, 0.40, 1.0)
            row.fs:SetText(label)
            row.btn:SetScript("OnClick", nil)
            row.btn:SetScript("OnEnter", function(b)
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetText("Already selected on the other side", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            row.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        else
            row.fs:SetTextColor(1, 1, 1, 1)
            row.fs:SetText(label)
            row.btn:SetScript("OnClick", function()
                if side == "A" then
                    self._selectedA = bid
                else
                    self._selectedB = bid
                end
                dd.popup:Hide()
                self:Refresh()
            end)
            row.btn:SetScript("OnEnter", function()
                if not isSelected then row.bg:SetColorTexture(0.20, 0.30, 0.40, 0.75) end
            end)
            row.btn:SetScript("OnLeave", function()
                if isSelected then
                    row.bg:SetColorTexture(dd.color[1] * 0.3, dd.color[2] * 0.3, dd.color[3] * 0.3, 0.7)
                else
                    row.bg:SetColorTexture(0.06, 0.08, 0.10, 0.0)
                end
            end)
        end

        y = y + ROW_H
    end

    -- Hide excess rows from previous population
    for i = #profiles + 1, #dd._rowButtons do
        if dd._rowButtons[i] and dd._rowButtons[i].btn then
            dd._rowButtons[i].btn:Hide()
        end
    end

    canvas:SetHeight(math.max(y, 1))
    local popupH = math.min(y + 8, 150)
    dd.popup:SetHeight(math.max(popupH, 30))
end

-- ── Refresh ───────────────────────────────────────────────────────────────────

function BuildComparatorView:Refresh()
    local catalog = getCatalog()
    local compSvc = getComparison()
    local store   = getStore()

    -- Resolve character key and scope
    local characterKey = store and store:GetCurrentCharacterKey() or nil
    if not self._scope and compSvc and characterKey then
        local snap = ns.Addon:GetLatestPlayerSnapshot()
        self._scope = compSvc:GetLastScope(characterKey, snap and snap.specId)
    end

    -- Freshness banner (T027)
    local liveBuild = catalog and catalog:GetCurrentLiveBuild()
    local freshness = liveBuild and liveBuild.snapshotFreshness
    if freshness == Constants.SNAPSHOT_FRESHNESS.DEGRADED
    or freshness == Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE then
        self.freshnessBanner:Show()
    else
        self.freshnessBanner:Hide()
    end

    -- Profile list
    local allProfiles = catalog and catalog:GetAllProfiles(characterKey) or {}
    self._profilesCache = filterAndSort(allProfiles, self._searchText, self._sortKey, self._scope, compSvc)

    -- Single-build overview (replaces the old empty state T029)
    if #allProfiles < 2 then
        self.emptyOneBuild:Hide()
        self.dropdownA.button:Hide()
        self.dropdownB.button:Hide()

        -- Hide comparison-only controls
        self.searchBox:Hide()
        if self.searchPlaceholder then self.searchPlaceholder:Hide() end
        self.sortBtn:Hide()
        self.vsPrevBtn:Hide()
        self.vsBestBtn:Hide()
        self.vsMostBtn:Hide()
        self.swapBtn:Hide()
        self.scopeLabel:Hide()
        self.contextBtn:Hide()
        self.scopeDesc:Hide()

        local profile = #allProfiles == 1 and allProfiles[1] or nil
        local liveBuildProfile = profile or (catalog and catalog:GetCurrentLiveBuild())
        self:_renderSingleBuildOverview(liveBuildProfile)
        return
    end

    -- Restore comparison controls hidden by single-build path
    self.searchBox:Show()
    self.sortBtn:Show()
    self.vsPrevBtn:Show()
    self.vsBestBtn:Show()
    self.vsMostBtn:Show()
    self.swapBtn:Show()
    self.scopeLabel:Show()
    self.contextBtn:Show()
    self.scopeDesc:Show()

    self.emptyOneBuild:Hide()
    self.dropdownA.button:Show()
    self.dropdownB.button:Show()
    self.diffShell:Show()

    -- Reset diffShell anchor back to comparison mode (may have been moved by single-build overview)
    self.diffShell:ClearAllPoints()
    self.diffShell:SetPoint("TOPLEFT", self.dropdownA.button, "BOTTOMLEFT", 0, -8)
    self.diffShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    -- Auto-select defaults if needed
    local profiles = self._profilesCache
    if not self._selectedA and #profiles >= 1 then
        self._selectedA = profiles[1].buildId
    end
    if not self._selectedB and #profiles >= 2 then
        -- Pick second distinct profile
        for _, p in ipairs(profiles) do
            if p.buildId ~= self._selectedA then
                self._selectedB = p.buildId
                break
            end
        end
    end

    -- T045: Show hint when the selected left build has no stat snapshot.
    if self.noStatHint then
        local leftProfile = self._selectedA and catalog and catalog:GetProfile(self._selectedA)
        local hasStatSnap = leftProfile and leftProfile.latestStatProfile ~= nil
        if hasStatSnap then
            self.noStatHint:Hide()
        else
            self.noStatHint:Show()
        end
    end

    -- Populate dropdown selectors
    self:_populateDropdown(self.dropdownA, profiles, "A")
    self:_populateDropdown(self.dropdownB, profiles, "B")

    -- Update dropdown button text
    local labelA = self._selectedA and catalog and catalog:GetDisplayLabel(self._selectedA) or "(none)"
    self.dropdownA.buttonText:SetText("Build A: " .. labelA .. "  |v")
    local labelB = self._selectedB and catalog and catalog:GetDisplayLabel(self._selectedB) or "(none)"
    self.dropdownB.buttonText:SetText("Build B: " .. labelB .. "  |v")

    -- Update scope description
    self:_updateScopeDesc()

    -- Run comparison and render results
    self:_renderComparison()
end


-- ── side-panel info update ────────────────────────────────────────────────────

-- Compute a human-readable relative time string (T049).
local function relativeTime(capturedAt)
    if not capturedAt then return "" end
    local delta = time() - capturedAt
    if delta < 60 then
        return "just now"
    elseif delta < 3600 then
        local mins = math.floor(delta / 60)
        return mins .. " min ago"
    else
        local hours = math.floor(delta / 3600)
        return hours .. " hr ago"
    end
end

-- ── visual stat rendering methods ────────────────────────────────────────────

-- Render dual horizontal bars for each secondary stat.
-- Returns the new y position after rendering.
function BuildComparatorView:_renderStatBars(canvas, y, statProfileA, statProfileB, statDelta)
    local hasData = (statProfileA ~= nil) or (statProfileB ~= nil)
    if not hasData then return y end

    -- Section header
    local header = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    header:SetTextColor(unpack(Theme.textMuted))
    header:SetText("Secondary Stats")
    self:_track(header)
    y = y + 16

    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(640, 1)
    self:_track(sep)
    y = y + 8

    local LABEL_W = 80
    local VAL_W   = 50
    local BAR_X   = LABEL_W + 4

    for _, rowDef in ipairs(STAT_ROWS) do
        local vA = statProfileA and statProfileA[rowDef.key]
        local vB = statProfileB and statProfileB[rowDef.key]
        local dv = statDelta and statDelta[rowDef.key]

        -- Stat label
        local lbl = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
        lbl:SetWidth(LABEL_W)
        lbl:SetJustifyH("RIGHT")
        lbl:SetTextColor(0.70, 0.70, 0.70, 1.0)
        lbl:SetText(rowDef.label)
        self:_track(lbl)

        -- Bar A (blue)
        local widthA = math.max(1, math.min((vA or 0) / 50, 1) * BAR_MAX_WIDTH)
        local trackA = canvas:CreateTexture(nil, "BACKGROUND")
        trackA:SetTexture("Interface\\Buttons\\WHITE8x8")
        trackA:SetVertexColor(BAR_TRACK_COLOR[1], BAR_TRACK_COLOR[2], BAR_TRACK_COLOR[3], BAR_TRACK_COLOR[4])
        trackA:SetPoint("TOPLEFT", canvas, "TOPLEFT", BAR_X, -y)
        trackA:SetSize(BAR_MAX_WIDTH, BAR_HEIGHT)
        self:_track(trackA)

        local barA = canvas:CreateTexture(nil, "ARTWORK")
        barA:SetTexture("Interface\\Buttons\\WHITE8x8")
        barA:SetVertexColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 0.85)
        barA:SetPoint("TOPLEFT", canvas, "TOPLEFT", BAR_X, -y)
        barA:SetSize(widthA, BAR_HEIGHT)
        self:_track(barA)

        local valAFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valAFs:SetPoint("LEFT", trackA, "RIGHT", 4, 0)
        valAFs:SetWidth(VAL_W)
        valAFs:SetJustifyH("LEFT")
        valAFs:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 1.0)
        valAFs:SetText(vA and string.format("%.1f%%", vA) or "---")
        self:_track(valAFs)

        y = y + BAR_HEIGHT + 3

        -- Bar B (orange)
        local widthB = math.max(1, math.min((vB or 0) / 50, 1) * BAR_MAX_WIDTH)
        local trackB = canvas:CreateTexture(nil, "BACKGROUND")
        trackB:SetTexture("Interface\\Buttons\\WHITE8x8")
        trackB:SetVertexColor(BAR_TRACK_COLOR[1], BAR_TRACK_COLOR[2], BAR_TRACK_COLOR[3], BAR_TRACK_COLOR[4])
        trackB:SetPoint("TOPLEFT", canvas, "TOPLEFT", BAR_X, -y)
        trackB:SetSize(BAR_MAX_WIDTH, BAR_HEIGHT)
        self:_track(trackB)

        local barB = canvas:CreateTexture(nil, "ARTWORK")
        barB:SetTexture("Interface\\Buttons\\WHITE8x8")
        barB:SetVertexColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], 0.85)
        barB:SetPoint("TOPLEFT", canvas, "TOPLEFT", BAR_X, -y)
        barB:SetSize(widthB, BAR_HEIGHT)
        self:_track(barB)

        local valBFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valBFs:SetPoint("LEFT", trackB, "RIGHT", 4, 0)
        valBFs:SetWidth(VAL_W)
        valBFs:SetJustifyH("LEFT")
        valBFs:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], 1.0)
        valBFs:SetText(vB and string.format("%.1f%%", vB) or "---")
        self:_track(valBFs)

        -- Delta text
        local deltaFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        deltaFs:SetPoint("LEFT", valBFs, "RIGHT", 8, 0)
        deltaFs:SetWidth(60)
        deltaFs:SetJustifyH("LEFT")
        if dv and dv > 0 then
            deltaFs:SetTextColor(0.44, 0.82, 0.60, 1.0)
            deltaFs:SetText(string.format("+%.1f%%", dv))
        elseif dv and dv < 0 then
            deltaFs:SetTextColor(0.86, 0.38, 0.38, 1.0)
            deltaFs:SetText(string.format("%.1f%%", dv))
        else
            deltaFs:SetTextColor(0.55, 0.55, 0.55, 1.0)
            deltaFs:SetText(dv and "0.0%" or "---")
        end
        self:_track(deltaFs)

        y = y + BAR_HEIGHT + 10  -- gap before next stat
    end

    return y
end

-- Render a 4-axis stat diamond (Crit up, Haste right, Mastery down, Vers left).
-- Returns the new y position after rendering.
function BuildComparatorView:_renderStatDiamond(canvas, y, statProfileA, statProfileB)
    local hasData = (statProfileA ~= nil) or (statProfileB ~= nil)
    if not hasData then return y end

    -- Section header
    local header = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    header:SetTextColor(unpack(Theme.textMuted))
    header:SetText("Stat Profile Diamond")
    self:_track(header)
    y = y + 16

    -- Container frame for diamond (centered in canvas)
    local diamond = CreateFrame("Frame", nil, canvas)
    diamond:SetSize(DIAMOND_SIZE, DIAMOND_SIZE)
    diamond:SetPoint("TOPLEFT", canvas, "TOPLEFT", 100, -y)
    self:_track(diamond)

    local cx, cy = 0, 0  -- center of diamond frame (relative to CENTER anchor)

    -- Draw axis lines (thin gray cross)
    local axisColor = { 0.25, 0.25, 0.28, 0.8 }
    -- Vertical axis (Crit top, Mastery bottom)
    local axV = DrawLine(diamond, 0, DIAMOND_RADIUS, 0, -DIAMOND_RADIUS, 1,
        axisColor[1], axisColor[2], axisColor[3], axisColor[4])
    if axV then self:_track(axV) end
    -- Horizontal axis (Vers left, Haste right)
    local axH = DrawLine(diamond, -DIAMOND_RADIUS, 0, DIAMOND_RADIUS, 0, 1,
        axisColor[1], axisColor[2], axisColor[3], axisColor[4])
    if axH then self:_track(axH) end

    -- Axis labels
    local labels = {
        { text = "Crit",    x = 0,                   y = DIAMOND_RADIUS + 12 },
        { text = "Haste",   x = DIAMOND_RADIUS + 8,  y = 0 },
        { text = "Mastery", x = 0,                   y = -(DIAMOND_RADIUS + 12) },
        { text = "Vers",    x = -(DIAMOND_RADIUS + 8), y = 0 },
    }
    for _, lb in ipairs(labels) do
        local fs = diamond:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("CENTER", diamond, "CENTER", lb.x, lb.y)
        fs:SetTextColor(0.60, 0.60, 0.60, 1.0)
        fs:SetText(lb.text)
        self:_track(fs)
    end

    -- Stat axis mapping:
    -- Crit (up):    x=0,  y=+r
    -- Haste (right): x=+r, y=0
    -- Mastery (down): x=0,  y=-r
    -- Vers (left):  x=-r, y=0
    local function getPoints(prof)
        if not prof then return nil end
        local rC = statToRadius(prof.critPct)
        local rH = statToRadius(prof.hastePct)
        local rM = statToRadius(prof.masteryPct)
        local rV = statToRadius(prof.versDamageDonePct)
        return {
            { x = 0,   y = rC },   -- Crit (up)
            { x = rH,  y = 0 },    -- Haste (right)
            { x = 0,   y = -rM },  -- Mastery (down)
            { x = -rV, y = 0 },    -- Vers (left)
        }
    end

    local function drawShape(pts, color, thickness)
        if not pts then return end
        for i = 1, #pts do
            local j = (i % #pts) + 1
            local line = DrawLine(diamond, pts[i].x, pts[i].y, pts[j].x, pts[j].y,
                thickness, color[1], color[2], color[3], color[4] * 0.7)
            if line then self:_track(line) end
        end
        -- Dots at each point
        for _, pt in ipairs(pts) do
            local dot = diamond:CreateTexture(nil, "OVERLAY")
            dot:SetTexture("Interface\\Buttons\\WHITE8x8")
            dot:SetVertexColor(color[1], color[2], color[3], color[4])
            dot:SetSize(6, 6)
            dot:SetPoint("CENTER", diamond, "CENTER", pt.x, pt.y)
            self:_track(dot)
        end
    end

    -- Draw Build A shape (blue, behind)
    drawShape(getPoints(statProfileA), COLOR_A, 2)
    -- Draw Build B shape (orange, on top)
    drawShape(getPoints(statProfileB), COLOR_B, 2)

    y = y + DIAMOND_SIZE + 12
    return y
end

-- Render a scrollable heatmap grid comparing win rates vs opponent specs.
-- Returns the new y position after rendering.
function BuildComparatorView:_renderWinRateHeatmap(canvas, y, buildHashA, buildHashB)
    local store = getStore()
    local db = store and store:GetDB()
    if not db or not db.aggregates or not db.aggregates.buildEffectiveness then
        return y
    end

    local bucketA = db.aggregates.buildEffectiveness[buildHashA]
    local bucketB = db.aggregates.buildEffectiveness[buildHashB]
    if not bucketA and not bucketB then return y end

    -- Collect all spec keys that either build has fought
    local specKeys = {}
    local seen = {}
    local function addSpecs(bucket)
        if not bucket then return end
        for specKey, entry in pairs(bucket) do
            if not seen[specKey] and entry.fights and entry.fights >= 1 then
                seen[specKey] = true
                specKeys[#specKeys + 1] = specKey
            end
        end
    end
    addSpecs(bucketA)
    addSpecs(bucketB)

    if #specKeys == 0 then return y end

    -- Sort by total fights descending
    table.sort(specKeys, function(a, b)
        local fA = ((bucketA and bucketA[a]) and bucketA[a].fights or 0)
                  + ((bucketB and bucketB[a]) and bucketB[a].fights or 0)
        local fB = ((bucketA and bucketA[b]) and bucketA[b].fights or 0)
                  + ((bucketB and bucketB[b]) and bucketB[b].fights or 0)
        return fA > fB
    end)

    -- Section header
    local header = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    header:SetTextColor(unpack(Theme.textMuted))
    header:SetText("Win Rate vs Opponent Specs")
    self:_track(header)
    y = y + 16

    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(640, 1)
    self:_track(sep)
    y = y + 6

    -- Column headers
    local COL_SPEC = 8
    local COL_A    = 220
    local COL_B    = 370
    local COL_D    = 520
    local ROW_H    = 22
    local BAR_W    = 120

    local colHeaders = {
        { x = COL_SPEC, text = "Opponent Spec", color = Theme.textMuted },
        { x = COL_A,    text = "Build A",       color = COLOR_A },
        { x = COL_B,    text = "Build B",       color = COLOR_B },
        { x = COL_D,    text = "Delta",          color = Theme.textMuted },
    }
    for _, ch in ipairs(colHeaders) do
        local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", ch.x, -y)
        fs:SetTextColor(ch.color[1], ch.color[2], ch.color[3], ch.color[4] or 1.0)
        fs:SetText(ch.text)
        self:_track(fs)
    end
    y = y + 16

    for _, specKey in ipairs(specKeys) do
        local specId = tonumber(specKey)
        local specMeta = specId and ns.StaticPvpData and ns.StaticPvpData.GetSpecMeta
                         and ns.StaticPvpData.GetSpecMeta(specId)
        local specName = specMeta and specMeta.name or ("Spec " .. specKey)
        local iconId   = specMeta and specMeta.iconFileDataId or nil

        local entryA = bucketA and bucketA[specKey]
        local entryB = bucketB and bucketB[specKey]
        local wrA = entryA and entryA.fights > 0 and (entryA.wins / entryA.fights) or nil
        local wrB = entryB and entryB.fights > 0 and (entryB.wins / entryB.fights) or nil

        -- Spec icon + name
        if iconId then
            local icon = canvas:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(iconId)
            icon:SetSize(16, 16)
            icon:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_SPEC, -y)
            self:_track(icon)
        end

        local nameFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_SPEC + 20, -y)
        nameFs:SetWidth(180)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        nameFs:SetTextColor(1, 1, 1, 1)
        nameFs:SetText(specName)
        self:_track(nameFs)

        -- Build A win rate bar + text
        if wrA then
            local bgA = canvas:CreateTexture(nil, "BACKGROUND")
            bgA:SetTexture("Interface\\Buttons\\WHITE8x8")
            local rr, gg, bb, aa = wrColor(wrA)
            bgA:SetVertexColor(rr, gg, bb, aa)
            bgA:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_A, -(y + 1))
            bgA:SetSize(math.max(1, wrA * BAR_W), ROW_H - 4)
            self:_track(bgA)

            local fsA = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fsA:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_A + 2, -y)
            fsA:SetTextColor(1, 1, 1, 1)
            fsA:SetText(string.format("%.0f%% (%d)", wrA * 100, entryA.fights))
            self:_track(fsA)
        else
            local fsA = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fsA:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_A + 2, -y)
            fsA:SetTextColor(0.45, 0.45, 0.45, 1.0)
            fsA:SetText("---")
            self:_track(fsA)
        end

        -- Build B win rate bar + text
        if wrB then
            local bgB = canvas:CreateTexture(nil, "BACKGROUND")
            bgB:SetTexture("Interface\\Buttons\\WHITE8x8")
            local rr, gg, bb, aa = wrColor(wrB)
            bgB:SetVertexColor(rr, gg, bb, aa)
            bgB:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_B, -(y + 1))
            bgB:SetSize(math.max(1, wrB * BAR_W), ROW_H - 4)
            self:_track(bgB)

            local fsB = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fsB:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_B + 2, -y)
            fsB:SetTextColor(1, 1, 1, 1)
            fsB:SetText(string.format("%.0f%% (%d)", wrB * 100, entryB.fights))
            self:_track(fsB)
        else
            local fsB = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fsB:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_B + 2, -y)
            fsB:SetTextColor(0.45, 0.45, 0.45, 1.0)
            fsB:SetText("---")
            self:_track(fsB)
        end

        -- Delta
        local deltaFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        deltaFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", COL_D, -y)
        deltaFs:SetWidth(60)
        deltaFs:SetJustifyH("LEFT")
        if wrA and wrB then
            local d = (wrA - wrB) * 100
            if d > 0 then
                deltaFs:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 1.0)
                deltaFs:SetText(string.format("+%.0f%%", d))
            elseif d < 0 then
                deltaFs:SetTextColor(COLOR_B[1], COLOR_B[2], COLOR_B[3], 1.0)
                deltaFs:SetText(string.format("%.0f%%", d))
            else
                deltaFs:SetTextColor(0.55, 0.55, 0.55, 1.0)
                deltaFs:SetText("0%")
            end
        else
            deltaFs:SetTextColor(0.45, 0.45, 0.45, 1.0)
            deltaFs:SetText("---")
        end
        self:_track(deltaFs)

        y = y + ROW_H
    end

    return y + 8
end

-- ── comparison and diff rendering ────────────────────────────────────────────

function BuildComparatorView:_renderComparison()
    self:_clearDiff()

    local compSvc = getComparison()
    if not compSvc or not self._selectedA or not self._selectedB then
        return
    end

    local result = compSvc:Compare(self._selectedA, self._selectedB, self._scope)
    if not result then return end

    local catalog = getCatalog()
    local profA = catalog and catalog:GetProfile(self._selectedA)
    local profB = catalog and catalog:GetProfile(self._selectedB)
    local statA = profA and profA.latestStatProfile
    local statB = profB and profB.latestStatProfile

    -- Empty-scope state (T030)
    if result.samplesA == 0 and result.samplesB == 0 then
        self:_renderEmptyScope()
        return
    end

    local canvas = self.diffCanvas
    local y = 8

    -- 1. Stat Bars
    y = self:_renderStatBars(canvas, y, statA, statB, result.statDelta)
    y = y + 8

    -- 2. Stat Diamond
    y = self:_renderStatDiamond(canvas, y, statA, statB)
    y = y + 8

    -- 3. Talent Diff panel
    self:_renderDiffPanel(result, y)

    -- Recalculate y from diff panel rendering (it sets canvas height internally)
    -- 4. Win Rate Heatmap — appended after diff panel
    local afterDiff = (self.diffCanvas:GetHeight() or y) + 4
    y = self:_renderWinRateHeatmap(canvas, afterDiff, self._selectedA, self._selectedB)

    ns.Widgets.SetCanvasHeight(canvas, (y or afterDiff) + 16)
end

function BuildComparatorView:_clearDiff()
    for _, el in ipairs(self._elems) do
        if el and el.Hide then el:Hide() end
    end
    self._elems = {}
end

function BuildComparatorView:_track(el)
    self._elems[#self._elems + 1] = el
    return el
end

-- Alias for _clearDiff (used by single-build overview path)
BuildComparatorView._clear = BuildComparatorView._clearDiff

-- Empty scope state (T030)
function BuildComparatorView:_renderEmptyScope()
    local canvas = self.diffCanvas
    local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 12, -24)
    fs:SetWidth(620)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetTextColor(unpack(Theme.textMuted))
    fs:SetText(
        "No sessions found for the current scope.\n"
        .. "Try broadening the filter or selecting a different context.")
    self:_track(fs)
    ns.Widgets.SetCanvasHeight(canvas, 80)
end

-- Diff panel (T023). startY allows the caller to chain after other visuals.
function BuildComparatorView:_renderDiffPanel(result, startY)
    local canvas = self.diffCanvas
    local diff   = result and result.diff
    local y      = (startY or 8) + 8

    -- Diff header
    local header = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
    header:SetTextColor(unpack(Theme.textMuted))
    header:SetText("Talent Diff")
    self:_track(header)
    y = y + 18

    -- Separator
    local sep = canvas:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(Theme.border))
    sep:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep:SetSize(640, 1)
    self:_track(sep)
    y = y + 6

    if not diff or diff.isIdentical then
        local identFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        identFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        identFs:SetTextColor(0.44, 0.82, 0.60, 1.0)
        identFs:SetText("Builds are identical in talent selection.")
        self:_track(identFs)
        y = y + 24
        ns.Widgets.SetCanvasHeight(canvas, y + 8)
        return
    end

    local changes = diff.changes or {}
    local total   = diff.totalChanges or #changes
    local displayCount = self._diffExpanded and total or math.min(DIFF_MAX_COMPACT, total)

    for i = 1, displayCount do
        local ch = changes[i]
        if not ch then break end

        local changeColor
        if ch.changeType == "added" then
            changeColor = { 0.44, 0.82, 0.60, 1.0 }
        elseif ch.changeType == "removed" then
            changeColor = { 0.86, 0.38, 0.38, 1.0 }
        elseif ch.changeType == "choice_changed" then
            changeColor = { 0.96, 0.74, 0.38, 1.0 }
        elseif ch.changeType == "rank_changed" then
            changeColor = { 0.70, 0.70, 0.90, 1.0 }
        elseif ch.changeType == "hero_changed" then
            changeColor = { 0.40, 0.78, 1.00, 1.0 }
        elseif ch.changeType == "pvp_changed" then
            changeColor = { 0.80, 0.60, 1.00, 1.0 }
        else
            changeColor = { unpack(Theme.text) }
        end

        local icon = ch.changeType == "added"         and "[+]"
                  or ch.changeType == "removed"        and "[-]"
                  or ch.changeType == "choice_changed" and "[~]"
                  or ch.changeType == "rank_changed"   and "[R]"
                  or ch.changeType == "hero_changed"   and "[H]"
                  or ch.changeType == "pvp_changed"    and "[P]"
                  or "[?]"

        local spellText
        if ch.changeType == "choice_changed" then
            local na = ch.spellNameA or ("Node " .. tostring(ch.nodeId or "?"))
            local nb = ch.spellNameB or ("Entry " .. tostring(ch.entryIdB or "?"))
            spellText = string.format("%s → %s", na, nb)
        elseif ch.changeType == "rank_changed" then
            local sn = ch.spellNameA or ("Node " .. tostring(ch.nodeId or "?"))
            spellText = string.format("%s  rank %d → %d", sn, ch.rankA or 0, ch.rankB or 0)
        elseif ch.changeType == "hero_changed" then
            spellText = string.format("%s → %s",
                ch.heroNameA or tostring(ch.heroIdA or "?"),
                ch.heroNameB or tostring(ch.heroIdB or "?"))
        elseif ch.changeType == "pvp_changed" then
            if ch.addedToB then
                spellText = string.format("Added: %s", ch.spellName or tostring(ch.spellId or "?"))
                changeColor = { 0.44, 0.82, 0.60, 1.0 }
                icon = "[+]"
            else
                spellText = string.format("Removed: %s", ch.spellName or tostring(ch.spellId or "?"))
                changeColor = { 0.86, 0.38, 0.38, 1.0 }
                icon = "[-]"
            end
        else
            spellText = ch.spellNameA or ch.spellNameB or ("Node " .. tostring(ch.nodeId or "?"))
        end

        -- T058: icon row — spell texture + coloured label + change-type badge
        local L        = ns.Widgets.LAYOUT
        local iconTex  = ch.spellId and GetSpellTexture(ch.spellId)
        local iconRow  = ns.Widgets.CreateIconRow(canvas, { maxLabelWidth = 440, maxValueWidth = 60 })
        iconRow:SetWidth(620)
        iconRow:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        iconRow:SetData(iconTex, spellText, nil, icon)
        iconRow.labelFs:SetTextColor(changeColor[1], changeColor[2], changeColor[3], changeColor[4])
        self:_track(iconRow)
        y = y + L.ROW_HEIGHT + L.ROW_GAP
    end

    -- "X more differences" expand button
    if not self._diffExpanded and total > DIFF_MAX_COMPACT then
        local remaining = total - DIFF_MAX_COMPACT
        local expandBtn = ns.Widgets.CreateButton(canvas, string.format("%d more differences…", remaining), 180, 20)
        expandBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        expandBtn:SetScript("OnClick", function()
            self._diffExpanded = true
            self:_renderComparison()
        end)
        self:_track(expandBtn)
        y = y + 26
    elseif self._diffExpanded and total > DIFF_MAX_COMPACT then
        local collapseBtn = ns.Widgets.CreateButton(canvas, "Show less", 100, 20)
        collapseBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        collapseBtn:SetScript("OnClick", function()
            self._diffExpanded = false
            self:_renderComparison()
        end)
        self:_track(collapseBtn)
        y = y + 26
    end

    ns.Widgets.SetCanvasHeight(canvas, y + 12)
end


-- ── scope helpers ─────────────────────────────────────────────────────────────

function BuildComparatorView:_cycleSortKey()
    local next = { recent = "sessions", sessions = "winrate", winrate = "name", name = "recent" }
    self._sortKey = next[self._sortKey] or "recent"

    local labels = { recent = "Most Recent", sessions = "Session Count", winrate = "Win Rate", name = "Name A–Z" }
    self.sortBtn:SetText("Sort: " .. (labels[self._sortKey] or "Most Recent"))
    self._profilesCache = nil
    self:Refresh()
end

function BuildComparatorView:_cycleContextScope()
    -- Find current context index and advance
    local current = self._scope and self._scope.context or ""
    local idx = 1
    for i, opt in ipairs(CONTEXT_OPTIONS) do
        if opt.key == current then idx = i; break end
    end
    local nextIdx = (idx % #CONTEXT_OPTIONS) + 1
    local chosen  = CONTEXT_OPTIONS[nextIdx]

    self._scope = self._scope or {}
    self._scope.context = chosen.key ~= "" and chosen.key or nil
    self.contextBtn:SetText(chosen.label)

    -- Persist scope
    local compSvc = getComparison()
    local store   = getStore()
    if compSvc and store then
        local snap = ns.Addon:GetLatestPlayerSnapshot()
        compSvc:SaveScope(store:GetCurrentCharacterKey(), snap and snap.specId, self._scope)
    end

    self._profilesCache = nil
    self:Refresh()
end

function BuildComparatorView:_updateScopeDesc()
    local store = getStore()
    if not store then return end

    local contextLabel = "all contexts"
    if self._scope and self._scope.context then
        for _, opt in ipairs(CONTEXT_OPTIONS) do
            if opt.key == self._scope.context then
                contextLabel = opt.label:lower()
                break
            end
        end
    end

    local charKey = store:GetCurrentCharacterKey()
    -- Count sessions with this scope
    local totalFiltered = 0
    if self._selectedA then
        local sessions = store:GetSessionsForBuild(self._selectedA, self._scope) or {}
        totalFiltered = totalFiltered + #sessions
    end
    if self._selectedB and self._selectedB ~= self._selectedA then
        local sessions = store:GetSessionsForBuild(self._selectedB, self._scope) or {}
        totalFiltered = totalFiltered + #sessions
    end

    self.scopeDesc:SetText(string.format(
        "%d session%s · %s", totalFiltered, totalFiltered == 1 and "" or "s", contextLabel))
end

-- ── quick actions ──────────────────────────────────────────────────────────────

function BuildComparatorView:_selectCurrentVsPrevious()
    local catalog = getCatalog()
    local store   = getStore()
    if not catalog or not store then return end

    local charKey  = store:GetCurrentCharacterKey()
    local profiles = catalog:GetAllProfiles(charKey)
    if #profiles < 2 then return end

    -- profiles[1] is current; profiles[2] is the most-recent other
    self._selectedA = profiles[1].buildId
    self._selectedB = profiles[2].buildId
    self:Refresh()
end

function BuildComparatorView:_selectCurrentVsBest()
    local catalog = getCatalog()
    local compSvc = getComparison()
    local store   = getStore()
    if not catalog or not compSvc or not store then return end

    local snap    = ns.Addon:GetLatestPlayerSnapshot()
    local charKey = store:GetCurrentCharacterKey()
    local live    = catalog:GetCurrentLiveBuild()
    if not live then return end

    local bestId = compSvc:GetBestHistoricalInScope(charKey, snap and snap.specId, self._scope)
    if not bestId or bestId == live.buildId then return end

    self._selectedA = live.buildId
    self._selectedB = bestId
    self:Refresh()
end

-- Quick action: compare the current live build against the most-used build in
-- the active scope. Wires FR-035 "Compare current to most-used build in scope".
function BuildComparatorView:_selectCurrentVsMostUsed()
    local catalog = getCatalog()
    local compSvc = getComparison()
    local store   = getStore()
    if not catalog or not compSvc or not store then return end

    local snap    = ns.Addon:GetLatestPlayerSnapshot()
    local charKey = store:GetCurrentCharacterKey()
    local live    = catalog:GetCurrentLiveBuild()
    if not live then return end

    local mostId = compSvc:GetMostUsedInScope(charKey, snap and snap.specId, self._scope)
    if not mostId or mostId == live.buildId then return end

    self._selectedA = live.buildId
    self._selectedB = mostId
    self:Refresh()
end

-- ── Single-Build Overview ─────────────────────────────────────────────────────
-- Renders a full Build Overview dashboard when only one build exists.
-- Surfaces performance data, secondary stats, and effectiveness vs opponent
-- specs — making the Builds tab useful from the very first session.

local WINRATE_GREEN  = { 0.44, 0.82, 0.60, 1.0 }
local WINRATE_YELLOW = { 0.96, 0.84, 0.20, 1.0 }
local WINRATE_RED    = { 0.86, 0.38, 0.38, 1.0 }

local function winRateColor(rate)
    if rate > 0.55 then return WINRATE_GREEN end
    if rate >= 0.45 then return WINRATE_YELLOW end
    return WINRATE_RED
end

local function fmtPct(val)
    if val == nil then return "—" end
    return string.format("%.1f%%", val)
end

function BuildComparatorView:_renderSingleBuildOverview(profile)
    self:_clear()

    if not profile then
        self.emptyOneBuild:SetText("No builds captured yet.\nEnter combat to record your first build.")
        self.emptyOneBuild:Show()
        self.diffShell:Hide()
        return
    end
    self.emptyOneBuild:Hide()

    local catalog = getCatalog()
    local store   = getStore()
    local L       = ns.Widgets.LAYOUT

    local buildId   = profile.buildId
    local buildHash = profile.buildId -- buildId IS the canonical hash
    local label     = catalog and catalog:GetDisplayLabel(buildId) or (buildId or "?")

    -- Use the diffShell scroll area for the overview content
    self.diffShell:Show()
    self.diffShell:ClearAllPoints()
    self.diffShell:SetPoint("TOPLEFT", self.captureBtn, "BOTTOMLEFT", 0, -12)
    self.diffShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    local canvas = self.diffCanvas
    local y = 0

    -- ── 1. Build Identity Header ────────────────────────────────────────────
    local titleFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    titleFs:SetWidth(620)
    titleFs:SetJustifyH("LEFT")
    titleFs:SetWordWrap(false)
    titleFs:SetText("Build Overview")
    self:_track(titleFs)
    y = y + 22

    local nameFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    nameFs:SetWidth(620)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    nameFs:SetTextColor(COLOR_A[1], COLOR_A[2], COLOR_A[3], 1.0)
    nameFs:SetText(label)
    self:_track(nameFs)
    y = y + 18

    -- Session count + freshness badge
    local sessionCount = profile.sessionCount or 0
    local statProf = profile.latestStatProfile
    local freshness = statProf and statProf.snapshotFreshness or Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE
    local fCol = FRESHNESS_COLOR[freshness] or FRESHNESS_COLOR[Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE]
    local fLabel = FRESHNESS_LABEL[freshness] or freshness

    local metaFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    metaFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    metaFs:SetWidth(620)
    metaFs:SetJustifyH("LEFT")
    local metaText = string.format("%d session%s recorded", sessionCount, sessionCount == 1 and "" or "s")
    if statProf then
        local ts = statProf.capturedAt and relativeTime(statProf.capturedAt) or ""
        metaText = metaText .. string.format("  |  Stats: %s %s", fLabel, ts ~= "" and ("(" .. ts .. ")") or "")
    else
        metaText = metaText .. "  |  No stat snapshot — click Capture"
    end
    metaFs:SetTextColor(fCol[1], fCol[2], fCol[3], 0.9)
    metaFs:SetText(metaText)
    self:_track(metaFs)
    y = y + 22

    -- ── 2. Secondary Stats Card ─────────────────────────────────────────────
    local statHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statHeader:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    statHeader:SetTextColor(unpack(Theme.textMuted))
    statHeader:SetText("Secondary Stats")
    self:_track(statHeader)
    y = y + 16

    local sep1 = canvas:CreateTexture(nil, "ARTWORK")
    sep1:SetColorTexture(unpack(Theme.border))
    sep1:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep1:SetSize(640, 1)
    self:_track(sep1)
    y = y + 6

    if statProf then
        local stats = {
            { label = "Critical Strike", value = statProf.critPct },
            { label = "Haste",           value = statProf.hastePct },
            { label = "Mastery",         value = statProf.masteryPct },
            { label = "Versatility",     value = statProf.versDamageDonePct },
            { label = "Item Level",      value = statProf.itemLevelEquipped, isFmt = false },
        }
        for _, stat in ipairs(stats) do
            local row = ns.Widgets.CreateIconRow(canvas, { maxLabelWidth = 160, maxValueWidth = 100, showPlaceholder = false })
            row:SetWidth(400)
            row:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
            local valText
            if stat.isFmt == false then
                valText = stat.value and tostring(math.floor(stat.value)) or "—"
            else
                valText = fmtPct(stat.value)
            end
            row:SetData(nil, stat.label, valText, "")
            row.labelFs:SetTextColor(0.70, 0.70, 0.70, 1.0)
            row.valueFs:SetTextColor(1, 1, 1, 1)
            self:_track(row)
            y = y + L.ROW_HEIGHT + L.ROW_GAP
        end
    else
        local noStatFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noStatFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        noStatFs:SetTextColor(unpack(Theme.textMuted))
        noStatFs:SetText("No stats captured. Click \"Capture\" above to record your current gear stats.")
        self:_track(noStatFs)
        y = y + 20
    end
    y = y + 8

    -- ── 3. Overall Performance Summary ──────────────────────────────────────
    local perfHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    perfHeader:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    perfHeader:SetTextColor(unpack(Theme.textMuted))
    perfHeader:SetText("Performance Summary")
    self:_track(perfHeader)
    y = y + 16

    local sep2 = canvas:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(unpack(Theme.border))
    sep2:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep2:SetSize(640, 1)
    self:_track(sep2)
    y = y + 6

    local sessions = store and store:GetSessionsForBuild(buildId, self._scope) or {}
    if #sessions > 0 then
        local wins, losses, totalDuration = 0, 0, 0
        local sumPressure, sumBurst, sumSurvival, metricCount = 0, 0, 0, 0
        local contextCounts = {}
        for _, s in ipairs(sessions) do
            if s.result == Constants.SESSION_RESULT.WON then wins = wins + 1 end
            if s.result == Constants.SESSION_RESULT.LOST then losses = losses + 1 end
            totalDuration = totalDuration + (s.duration or 0)
            local m = s.metrics
            if m then
                if m.pressureScore then sumPressure = sumPressure + m.pressureScore end
                if m.burstScore then sumBurst = sumBurst + m.burstScore end
                if m.survivabilityScore then sumSurvival = sumSurvival + m.survivabilityScore end
                metricCount = metricCount + 1
            end
            local ctx = s.context or "unknown"
            contextCounts[ctx] = (contextCounts[ctx] or 0) + 1
        end

        local n = #sessions
        local wr = n > 0 and (wins / n) or 0
        local avgDur = n > 0 and (totalDuration / n) or 0
        local avgPress = metricCount > 0 and (sumPressure / metricCount) or 0
        local avgBurst = metricCount > 0 and (sumBurst / metricCount) or 0
        local avgSurv = metricCount > 0 and (sumSurvival / metricCount) or 0

        local summaryLines = {
            { label = "Total Sessions", value = tostring(n) },
            { label = "Win Rate",       value = string.format("%.0f%%  (%dW / %dL)", wr * 100, wins, losses), color = winRateColor(wr) },
            { label = "Avg Duration",   value = string.format("%.0fs", avgDur) },
            { label = "Avg Pressure",   value = string.format("%.1f", avgPress) },
            { label = "Avg Burst",      value = string.format("%.1f", avgBurst) },
            { label = "Avg Survivability", value = string.format("%.1f", avgSurv) },
        }

        for _, line in ipairs(summaryLines) do
            local row = ns.Widgets.CreateIconRow(canvas, { maxLabelWidth = 160, maxValueWidth = 200, showPlaceholder = false })
            row:SetWidth(500)
            row:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
            row:SetData(nil, line.label, line.value, "")
            row.labelFs:SetTextColor(0.70, 0.70, 0.70, 1.0)
            if line.color then
                row.valueFs:SetTextColor(line.color[1], line.color[2], line.color[3], 1.0)
            else
                row.valueFs:SetTextColor(1, 1, 1, 1)
            end
            self:_track(row)
            y = y + L.ROW_HEIGHT + L.ROW_GAP
        end

        -- Context breakdown
        local contextOrder = { "arena", "battleground", "duel", "world_pvp", "training_dummy", "general" }
        local contextNames = { arena = "Arena", battleground = "BG", duel = "Duel", world_pvp = "World PvP", training_dummy = "Dummy", general = "General" }
        local parts = {}
        for _, ctx in ipairs(contextOrder) do
            if contextCounts[ctx] then
                parts[#parts + 1] = string.format("%s: %d", contextNames[ctx] or ctx, contextCounts[ctx])
            end
        end
        if #parts > 0 then
            local ctxFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            ctxFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
            ctxFs:SetWidth(600)
            ctxFs:SetJustifyH("LEFT")
            ctxFs:SetTextColor(0.55, 0.55, 0.55, 1.0)
            ctxFs:SetText("By context:  " .. table.concat(parts, "  |  "))
            self:_track(ctxFs)
            y = y + 18
        end
    else
        local noPerfFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noPerfFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        noPerfFs:SetTextColor(unpack(Theme.textMuted))
        noPerfFs:SetText("No combat sessions recorded with this build yet.")
        self:_track(noPerfFs)
        y = y + 20
    end
    y = y + 12

    -- ── 4. Effectiveness vs Opponent Specs ──────────────────────────────────
    local effHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    effHeader:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    effHeader:SetTextColor(unpack(Theme.textMuted))
    effHeader:SetText("Effectiveness vs Opponent Specs")
    self:_track(effHeader)
    y = y + 16

    local sep3 = canvas:CreateTexture(nil, "ARTWORK")
    sep3:SetColorTexture(unpack(Theme.border))
    sep3:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
    sep3:SetSize(640, 1)
    self:_track(sep3)
    y = y + 6

    -- Gather effectiveness data from aggregates
    local db = store and store:GetDB()
    local buildBucket = db and db.aggregates and db.aggregates.buildEffectiveness and db.aggregates.buildEffectiveness[buildHash]

    local effEntries = {}
    if buildBucket then
        for specKey, entry in pairs(buildBucket) do
            if entry.fights and entry.fights >= 1 then
                local specId = tonumber(specKey)
                local specMeta = specId and ns.StaticPvpData and ns.StaticPvpData.GetSpecMeta and ns.StaticPvpData.GetSpecMeta(specId)
                local specName = specMeta and specMeta.name or ("Spec " .. specKey)
                local className = specMeta and specMeta.classFile or nil
                local iconId = specMeta and specMeta.iconFileDataId or nil
                local wr = entry.fights > 0 and (entry.wins / entry.fights) or 0
                effEntries[#effEntries + 1] = {
                    specId = specId,
                    specName = specName,
                    className = className,
                    iconId = iconId,
                    fights = entry.fights,
                    wins = entry.wins,
                    losses = entry.losses or 0,
                    winRate = wr,
                    avgPressure = entry.avgPressureScore or 0,
                }
            end
        end
    end

    -- Sort by fight count descending
    table.sort(effEntries, function(a, b) return a.fights > b.fights end)

    if #effEntries > 0 then
        -- Column headers
        local colFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        colFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        colFs:SetWidth(600)
        colFs:SetJustifyH("LEFT")
        colFs:SetTextColor(0.50, 0.50, 0.50, 1.0)
        colFs:SetText(string.format("%-28s %8s %10s %12s", "Spec", "Fights", "Win Rate", "Pressure"))
        self:_track(colFs)
        y = y + 16

        for _, eff in ipairs(effEntries) do
            local row = ns.Widgets.CreateIconRow(canvas, { maxLabelWidth = 180, maxValueWidth = 260 })
            row:SetWidth(620)
            row:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)

            local wrText = string.format("%dW/%dL (%.0f%%)", eff.wins, eff.losses, eff.winRate * 100)
            local valText = string.format("%d fights  |  %s  |  P: %.1f", eff.fights, wrText, eff.avgPressure)
            row:SetData(eff.iconId, eff.specName, valText, "")

            local wrCol = winRateColor(eff.winRate)
            row.valueFs:SetTextColor(wrCol[1], wrCol[2], wrCol[3], 1.0)
            self:_track(row)
            y = y + L.ROW_HEIGHT + L.ROW_GAP
        end
    else
        local noEffFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noEffFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, -y)
        noEffFs:SetTextColor(unpack(Theme.textMuted))
        noEffFs:SetText("No opponent matchup data yet. Play some PvP matches to see effectiveness breakdown.")
        self:_track(noEffFs)
        y = y + 20
    end
    y = y + 12

    -- Hint about comparisons
    local hintFs = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, -y)
    hintFs:SetWidth(600)
    hintFs:SetJustifyH("LEFT")
    hintFs:SetWordWrap(true)
    hintFs:SetTextColor(0.45, 0.45, 0.45, 1.0)
    hintFs:SetText("Switch to a different talent setup and play a match to unlock build-vs-build comparison.")
    self:_track(hintFs)
    y = y + 30

    ns.Widgets.SetCanvasHeight(canvas, y + 8)
end

ns.Addon:RegisterModule("BuildComparatorView", BuildComparatorView)
