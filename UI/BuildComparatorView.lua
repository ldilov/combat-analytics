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

-- ── stat section local factory (T046) ─────────────────────────────────────────

local STAT_ROWS = {
    { key = "critPct",           label = "Crit"        },
    { key = "hastePct",          label = "Haste"       },
    { key = "masteryPct",        label = "Mastery"     },
    { key = "versDamageDonePct", label = "Versatility" },
}

-- Creates a frame with four labeled stat rows (Crit, Haste, Mastery, Vers).
-- Each row: left-label | left-value | delta | right-value
local function CreateStatRowSection(parent)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetSize(660, 120)

    local LABEL_W  = 80
    local VAL_W    = 70
    local DELTA_W  = 90
    local ROW_H    = 22
    local PAD_LEFT = 8

    -- Column header
    local colA = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colA:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W, -2)
    colA:SetWidth(VAL_W)
    colA:SetJustifyH("CENTER")
    colA:SetTextColor(0.40, 0.78, 1.00, 1.0)
    colA:SetText("Build A")

    local colDelta = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colDelta:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W + VAL_W, -2)
    colDelta:SetWidth(DELTA_W)
    colDelta:SetJustifyH("RIGHT")
    colDelta:SetTextColor(0.70, 0.70, 0.70, 1.0)
    colDelta:SetText("Delta")

    local colB = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colB:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W + VAL_W + DELTA_W, -2)
    colB:SetWidth(VAL_W)
    colB:SetJustifyH("CENTER")
    colB:SetTextColor(0.96, 0.74, 0.38, 1.0)
    colB:SetText("Build B")

    section.rows = {}
    local yBase = ROW_H + 4

    for i, rowDef in ipairs(STAT_ROWS) do
        local y = yBase + (i - 1) * ROW_H

        local lbl = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT, -y)
        lbl:SetWidth(LABEL_W)
        lbl:SetJustifyH("RIGHT")
        lbl:SetTextColor(0.70, 0.70, 0.70, 1.0)
        lbl:SetText(rowDef.label)

        local valA = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valA:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W + 4, -y)
        valA:SetWidth(VAL_W)
        valA:SetJustifyH("CENTER")
        valA:SetText("—")

        local delta = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        delta:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W + VAL_W, -y)
        delta:SetWidth(DELTA_W)
        delta:SetJustifyH("RIGHT")
        delta:SetText("")

        local valB = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valB:SetPoint("TOPLEFT", section, "TOPLEFT", PAD_LEFT + LABEL_W + VAL_W + DELTA_W + 4, -y)
        valB:SetWidth(VAL_W)
        valB:SetJustifyH("CENTER")
        valB:SetText("—")

        section.rows[i] = {
            key   = rowDef.key,
            label = lbl,
            valA  = valA,
            delta = delta,
            valB  = valB,
        }
    end

    section:SetHeight(yBase + #STAT_ROWS * ROW_H + 4)
    return section
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

-- ── element pool ─────────────────────────────────────────────────────────────

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
    self.freshnessBanner:SetText("\226\138\160 Build data loading — talent information may be incomplete")
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
            self:_renderSelectorPanels()
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
    self.swapBtn = ns.Widgets.CreateButton(self.frame, "Swap A\226\134\148B", L.CARD_PAD * 2 + 68, btnH)
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
            self:_renderStatSection(profile, profile)
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

    -- Selector panels (A and B) — created once, populated in Refresh
    local selectorAnchor = self.captureSpacer

    -- Panel A
    self.panelA = self:_buildSidePanel("A", COLOR_A, selectorAnchor, 0)
    -- Panel B
    self.panelB = self:_buildSidePanel("B", COLOR_B, selectorAnchor, 340)

    -- T057: Dynamic panel widths — recalculate on resize and on first show
    -- OnShow fires when the Builds tab becomes visible (covers the fw==0 at Build() time case)
    self.frame:SetScript("OnSizeChanged", function() self:_recalcPanelWidths() end)
    self.frame:HookScript("OnShow", function() self:_recalcPanelWidths() end)
    self:_recalcPanelWidths()

    -- Scrollable content area below the side panels — holds stat rows + talent diff.
    -- Anchored directly to panelA bottom so it fills remaining frame height.
    self.diffShell, self.diffScroll, self.diffCanvas =
        ns.Widgets.CreateScrollCanvas(self.frame, 660, 260)
    self.diffShell:SetPoint("TOPLEFT", self.panelA.frame, "BOTTOMLEFT", 0, -8)
    self.diffShell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    -- T046: Stat rows section — lives INSIDE the scroll canvas (prevents overflow)
    self.statSection = CreateStatRowSection(self.diffCanvas)
    self.statSection:SetPoint("TOPLEFT", self.diffCanvas, "TOPLEFT", 0, 0)
    self.statSection:Hide()

    return self.frame
end

-- Build one side-panel (A or B). Returns a table with sub-widgets.
function BuildComparatorView:_buildSidePanel(side, color, anchor, xOffset)
    local isA = (side == "A")
    local panel = { side = side, color = color }

    -- Header label
    panel.label = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOffset, -12)
    panel.label:SetTextColor(color[1], color[2], color[3], color[4])
    panel.label:SetText("Build " .. side .. ":")

    -- Scrollable list frame (120px fits ~5 entries comfortably)
    panel.listFrame = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
    panel.listFrame:SetSize(310, 120)
    panel.listFrame:SetPoint("TOPLEFT", panel.label, "BOTTOMLEFT", 0, -4)
    ns.Widgets.ApplyBackdrop(panel.listFrame, Theme.panel, Theme.border)

    panel.scrollFrame = CreateFrame("ScrollFrame", nil, panel.listFrame, "UIPanelScrollFrameTemplate")
    panel.scrollFrame:SetPoint("TOPLEFT", panel.listFrame, "TOPLEFT", 4, -4)
    panel.scrollFrame:SetPoint("BOTTOMRIGHT", panel.listFrame, "BOTTOMRIGHT", -22, 4)

    panel.listCanvas = CreateFrame("Frame", nil, panel.scrollFrame)
    panel.listCanvas:SetWidth(panel.scrollFrame:GetWidth())
    panel.scrollFrame:SetScrollChild(panel.listCanvas)

    -- Info row: display label + session count + confidence badge
    panel.frame = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
    panel.frame:SetSize(310, 60)
    panel.frame:SetPoint("TOPLEFT", panel.listFrame, "BOTTOMLEFT", 0, -6)
    ns.Widgets.ApplyBackdrop(panel.frame, Theme.panelAlt, Theme.border)

    panel.nameLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.nameLabel:SetPoint("TOPLEFT", panel.frame, "TOPLEFT", 8, -8)
    panel.nameLabel:SetWidth(290)
    panel.nameLabel:SetJustifyH("LEFT")
    panel.nameLabel:SetTextColor(color[1], color[2], color[3], 1.0)
    panel.nameLabel:SetText("—")

    panel.sampleLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.sampleLabel:SetPoint("TOPLEFT", panel.nameLabel, "BOTTOMLEFT", 0, -4)
    panel.sampleLabel:SetTextColor(unpack(Theme.textMuted))
    panel.sampleLabel:SetText("No sessions")

    panel.confidenceLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.confidenceLabel:SetPoint("LEFT", panel.sampleLabel, "RIGHT", 8, 0)
    panel.confidenceLabel:SetText("")

    panel.metricsLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.metricsLabel:SetPoint("TOPLEFT", panel.sampleLabel, "BOTTOMLEFT", 0, -2)
    panel.metricsLabel:SetWidth(290)
    panel.metricsLabel:SetJustifyH("LEFT")
    panel.metricsLabel:SetTextColor(unpack(Theme.text))
    panel.metricsLabel:SetText("")

    -- "No combat history" placeholder
    panel.noHistoryLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.noHistoryLabel:SetPoint("TOPLEFT", panel.sampleLabel, "BOTTOMLEFT", 0, -2)
    panel.noHistoryLabel:SetTextColor(unpack(Theme.textMuted))
    panel.noHistoryLabel:SetText("No combat history in this scope")
    panel.noHistoryLabel:Hide()

    -- T048: Freshness badge — displayed to the right of the build name label.
    panel.freshnessBadge = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.freshnessBadge:SetPoint("LEFT", panel.nameLabel, "RIGHT", 6, 0)
    panel.freshnessBadge:SetText("")

    -- T049: Capture timestamp label below the freshness badge.
    panel.captureTimeLabel = panel.frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.captureTimeLabel:SetPoint("TOPLEFT", panel.nameLabel, "BOTTOMLEFT", 0, -14)
    panel.captureTimeLabel:SetTextColor(0.55, 0.55, 0.55, 1.0)
    panel.captureTimeLabel:SetText("")

    -- Store the panel
    if isA then
        self.panelA = panel
    else
        self.panelB = panel
    end
    return panel
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

    -- Single-build empty state (T029)
    if #allProfiles < 2 then
        self.emptyOneBuild:Show()
        -- Show captured build name in the Build A header so user sees confirmation
        if #allProfiles == 1 and catalog then
            local label = catalog:GetDisplayLabel(allProfiles[1].buildId) or "—"
            self.panelA.label:SetText("Build A: " .. label)
        else
            self.panelA.label:SetText("Build A:")
        end
        self.panelA.listFrame:Hide()
        self.panelA.scrollFrame:Hide()
        self.panelA.frame:Hide()
        self.panelB.listFrame:Hide()
        self.panelB.scrollFrame:Hide()
        self.panelB.frame:Hide()
        self.diffShell:Hide()
        self:_clear()
        return
    end

    self.emptyOneBuild:Hide()
    self.panelA.listFrame:Show()
    self.panelA.scrollFrame:Show()
    self.panelA.frame:Show()
    self.panelB.listFrame:Show()
    self.panelB.scrollFrame:Show()
    self.panelB.frame:Show()
    self.diffShell:Show()

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

    -- Render selector lists
    self:_renderSelectorPanels()

    -- Update scope description
    self:_updateScopeDesc()

    -- Run comparison and render results
    self:_renderComparison()
end

-- ── selector panel rendering ─────────────────────────────────────────────────

function BuildComparatorView:_renderSelectorPanels()
    local catalog = getCatalog()
    local profiles = self._profilesCache or {}

    -- Re-filter if needed (search changed without full Refresh)
    if self._needsRefilter then
        local allP = catalog and catalog:GetAllProfiles(getStore() and getStore():GetCurrentCharacterKey()) or {}
        profiles = filterAndSort(allP, self._searchText, self._sortKey, self._scope, getComparison())
        self._profilesCache = profiles
        self._needsRefilter = false
    end

    self:_populateList(self.panelA, profiles, "A")
    self:_populateList(self.panelB, profiles, "B")
end

function BuildComparatorView:_populateList(panel, profiles, side)
    local canvas = panel.listCanvas
    -- Clear previous row buttons
    panel._rowButtons = panel._rowButtons or {}
    for _, btn in ipairs(panel._rowButtons) do
        if btn.Hide then btn:Hide() end
    end
    panel._rowButtons = {}

    local ROW_H   = 22
    local y       = 0
    local catalog = getCatalog()

    for _, p in ipairs(profiles) do
        local bid      = p.buildId
        local isThisSide = (side == "A" and bid == self._selectedA) or (side == "B" and bid == self._selectedB)
        local isOther    = (side == "A" and bid == self._selectedB) or (side == "B" and bid == self._selectedA)
        local label    = catalog and catalog:GetDisplayLabel(bid) or (bid or "?")
        if p.isCurrentBuild then
            label = "\226\138\134 " .. label  -- star prefix for current live build
        end

        local btn = CreateFrame("Button", nil, canvas)
        btn:SetSize(canvas:GetWidth(), ROW_H)
        btn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -y)
        btn:EnableMouse(true)

        -- Background
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if isThisSide then
            bg:SetColorTexture(0.15, 0.25, 0.35, 0.85)
        elseif isOther then
            bg:SetColorTexture(0.12, 0.12, 0.12, 0.5)
        else
            bg:SetColorTexture(0.06, 0.08, 0.10, 0.0)
        end

        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", btn, "LEFT", 6, 0)
        fs:SetWidth(canvas:GetWidth() - 8)
        fs:SetJustifyH("LEFT")

        if isOther then
            fs:SetTextColor(0.40, 0.40, 0.40, 1.0)
            fs:SetText(label)
            -- tooltip for disabled slot
            btn:SetScript("OnEnter", function(b)
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetText("Already selected on the other side", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        else
            fs:SetTextColor(1, 1, 1, 1)
            fs:SetText(label)
            btn:SetScript("OnClick", function()
                if side == "A" then
                    self._selectedA = bid
                else
                    self._selectedB = bid
                end
                self:Refresh()
            end)
            btn:SetScript("OnEnter", function(b)
                bg:SetColorTexture(0.20, 0.30, 0.40, 0.75)
            end)
            btn:SetScript("OnLeave", function()
                if isThisSide then
                    bg:SetColorTexture(0.15, 0.25, 0.35, 0.85)
                else
                    bg:SetColorTexture(0.06, 0.08, 0.10, 0.0)
                end
            end)
        end

        panel._rowButtons[#panel._rowButtons + 1] = btn
        y = y + ROW_H
    end

    canvas:SetHeight(math.max(y, 1))
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

function BuildComparatorView:_updatePanelInfo(panel, buildId, result)
    local catalog = getCatalog()
    local label = catalog and catalog:GetDisplayLabel(buildId) or "—"
    panel.nameLabel:SetText(label)

    -- T048/T049: freshness badge and capture timestamp
    local profile = buildId and catalog and catalog:GetProfile(buildId)
    local statProf = profile and profile.latestStatProfile
    local freshness = statProf and statProf.snapshotFreshness or Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE
    if panel.freshnessBadge then
        local col = FRESHNESS_COLOR[freshness] or FRESHNESS_COLOR[Constants.SNAPSHOT_FRESHNESS.UNAVAILABLE]
        panel.freshnessBadge:SetTextColor(col[1], col[2], col[3], col[4])
        panel.freshnessBadge:SetText("[" .. (FRESHNESS_LABEL[freshness] or freshness) .. "]")
    end
    if panel.captureTimeLabel then
        local ts = statProf and statProf.capturedAt
        -- Use result's per-side capturedAt when the comparison result provides it
        if result then
            ts = (panel.side == "A") and result.buildAStatCapturedAt or result.buildBStatCapturedAt
        end
        panel.captureTimeLabel:SetText(ts and relativeTime(ts) or "")
    end

    if not result then
        panel.sampleLabel:SetText("No sessions")
        panel.confidenceLabel:SetText("")
        panel.metricsLabel:SetText("")
        panel.noHistoryLabel:Show()
        panel.metricsLabel:Hide()
        return
    end

    local samples    = (panel.side == "A") and result.samplesA or result.samplesB
    local confidence = (panel.side == "A") and result.confidenceA or result.confidenceB
    local metrics    = (panel.side == "A") and result.metricsA or result.metricsB

    local tier = confidence or Constants.CONFIDENCE_TIER.NO_DATA
    local col  = CONF_COLOR[tier] or CONF_COLOR[Constants.CONFIDENCE_TIER.NO_DATA]
    local confText = string.format("%s — %d session%s",
        CONF_LABEL[tier] or tier, samples, samples == 1 and "" or "s")
    panel.sampleLabel:SetText(samples == 1 and "1 session" or (samples .. " sessions"))
    panel.confidenceLabel:SetTextColor(col[1], col[2], col[3], col[4])
    panel.confidenceLabel:SetText(confText)

    -- Metrics row — hidden below LOW confidence
    if tier == Constants.CONFIDENCE_TIER.NO_DATA or tier == Constants.CONFIDENCE_TIER.LOW then
        panel.metricsLabel:SetText("")
        panel.metricsLabel:Hide()
        if samples == 0 then
            panel.noHistoryLabel:Show()
        else
            panel.noHistoryLabel:Hide()
        end
    else
        panel.noHistoryLabel:Hide()
        panel.metricsLabel:Show()
        if metrics then
            local wr = metrics.winRate and string.format("%.0f%%", metrics.winRate * 100) or "—"
            local pr = metrics.pressureScore and string.format("%.1f", metrics.pressureScore) or "—"
            local bu = metrics.burstScore and string.format("%.1f", metrics.burstScore) or "—"
            panel.metricsLabel:SetText(string.format(
                "WR %s  |  Pressure %s  |  Burst %s", wr, pr, bu))
        else
            panel.metricsLabel:SetText("")
        end
    end
end

-- T046/T047: Populate the stat row section from the comparison result.
function BuildComparatorView:_renderStatSection(statProfileA, statProfileB, statDelta)
    if not self.statSection then return end

    local function fmtStat(val)
        if val == nil then return "—" end
        return string.format("%.1f%%", val)
    end

    local function fmtDelta(val)
        if val == nil then return "|cFF888888—|r" end
        if val > 0 then
            return string.format("|cFF00FF00+%.1f%%|r", val)
        elseif val < 0 then
            return string.format("|cFFFF4444%.1f%%|r", val)
        else
            return string.format("|cFF888888%.1f%%|r", val)
        end
    end

    local hasData = statProfileA ~= nil or statProfileB ~= nil
    if not hasData then
        self.statSection:Hide()
        -- Reset canvas height so _renderDiffPanel sets the authoritative final height
        if self.diffCanvas then
            ns.Widgets.SetCanvasHeight(self.diffCanvas, 1)
        end
        return
    end

    self.statSection:Show()
    -- Ensure scroll canvas is tall enough for the stat section
    if self.diffCanvas then
        local minH = self.statSection:GetHeight() + 8
        local curH = self.diffCanvas:GetHeight() or 0
        if curH < minH then
            ns.Widgets.SetCanvasHeight(self.diffCanvas, minH)
        end
    end
    for _, row in ipairs(self.statSection.rows) do
        local k = row.key
        local vA = statProfileA and statProfileA[k]
        local vB = statProfileB and statProfileB[k]
        local dv = statDelta and statDelta[k]
        row.valA:SetText(fmtStat(vA))
        row.valB:SetText(fmtStat(vB))
        row.delta:SetText(fmtDelta(dv))
    end
end

-- ── comparison and diff rendering ────────────────────────────────────────────

function BuildComparatorView:_renderComparison()
    self:_clearDiff()

    local compSvc = getComparison()
    if not compSvc or not self._selectedA or not self._selectedB then
        self:_updatePanelInfo(self.panelA, self._selectedA, nil)
        self:_updatePanelInfo(self.panelB, self._selectedB, nil)
        return
    end

    local result = compSvc:Compare(self._selectedA, self._selectedB, self._scope)
    if not result then
        self:_updatePanelInfo(self.panelA, self._selectedA, nil)
        self:_updatePanelInfo(self.panelB, self._selectedB, nil)
        return
    end

    self:_updatePanelInfo(self.panelA, self._selectedA, result)
    self:_updatePanelInfo(self.panelB, self._selectedB, result)

    -- T046/T047: Render stat section from comparison result
    local catalog = getCatalog()
    local profA = catalog and catalog:GetProfile(self._selectedA)
    local profB = catalog and catalog:GetProfile(self._selectedB)
    self:_renderStatSection(
        profA and profA.latestStatProfile,
        profB and profB.latestStatProfile,
        result.statDelta)

    -- Empty-scope state (T030)
    if result.samplesA == 0 and result.samplesB == 0 then
        self:_renderEmptyScope()
        return
    end

    -- Diff panel
    self:_renderDiffPanel(result)
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

-- Empty scope state (T030)
function BuildComparatorView:_renderEmptyScope()
    local canvas = self.diffCanvas
    local startY = self:_diffStartY()
    local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 12, -(startY + 16))
    fs:SetWidth(620)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetTextColor(unpack(Theme.textMuted))
    fs:SetText(
        "No sessions found for the current scope.\n"
        .. "Try broadening the filter or selecting a different context.")
    self:_track(fs)
    ns.Widgets.SetCanvasHeight(canvas, startY + 60)
end

-- Diff panel (T023)
function BuildComparatorView:_renderDiffPanel(result)
    local canvas = self.diffCanvas
    local diff   = result and result.diff
    local y      = self:_diffStartY() + 8

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

-- Returns the Y offset where diff content should start inside diffCanvas,
-- accounting for the stat section if it is visible.
function BuildComparatorView:_diffStartY()
    if self.statSection and self.statSection:IsShown() then
        return self.statSection:GetHeight() + 8
    end
    return 0
end

-- ── layout helpers ────────────────────────────────────────────────────────────

-- T057: Recalculate side-panel widths based on current frame width.
-- Panels each get half the frame width minus three CARD_PAD gutters, clamped to 220px min.
function BuildComparatorView:_recalcPanelWidths()
    local L  = ns.Widgets.LAYOUT
    local fw = self.frame:GetWidth()
    if not fw or fw <= 0 then return end
    local pw = math.max(220, math.floor((fw / 2) - (L.CARD_PAD * 3)))

    local function resizePanel(p)
        if not p then return end
        if p.listFrame then p.listFrame:SetWidth(pw) end
        if p.frame     then p.frame:SetWidth(pw) end
        local innerW = pw - 20
        if p.nameLabel    then p.nameLabel:SetWidth(innerW) end
        if p.metricsLabel then p.metricsLabel:SetWidth(innerW) end
    end

    resizePanel(self.panelA)
    resizePanel(self.panelB)

    -- Re-anchor panel B header label so it sits right of panel A
    if self.panelB and self.panelB.label and self.captureSpacer then
        self.panelB.label:ClearAllPoints()
        self.panelB.label:SetPoint("TOPLEFT", self.captureSpacer, "BOTTOMLEFT", pw + L.CARD_PAD, -12)
    end
end

-- ── scope helpers ─────────────────────────────────────────────────────────────

function BuildComparatorView:_cycleSortKey()
    local next = { recent = "sessions", sessions = "winrate", winrate = "name", name = "recent" }
    self._sortKey = next[self._sortKey] or "recent"

    local labels = { recent = "Most Recent", sessions = "Session Count", winrate = "Win Rate", name = "Name A–Z" }
    self.sortBtn:SetText("Sort: " .. (labels[self._sortKey] or "Most Recent"))
    self._profilesCache = nil
    self:_renderSelectorPanels()
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

ns.Addon:RegisterModule("BuildComparatorView", BuildComparatorView)
