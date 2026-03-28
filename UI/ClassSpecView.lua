local _, ns = ...

local Theme = ns.Widgets.THEME
local Helpers = ns.Helpers

local ClassSpecView = {
    viewId = "classspec",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local BAR_WIDTH = 740
local BAR_HEIGHT = 52
local HEAT_CELL_SIZE = 42
local HEAT_COLS = 4
local HEAT_COL_LABELS = { "Fights", "Win%", "Press", "Taken" }

--- Return {r,g,b,a} table for the given classFile, falling back to accent.
local function classColor(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        return { cc.r, cc.g, cc.b, 1 }
    end
    return Theme.accent
end

--- Heat-grid color ramp: 0..1 value mapped from cold (panel) to warm (accent).
local function heatColorRamp(value)
    local t = ns.Helpers.Clamp(value or 0, 0, 1)
    -- Interpolate from dark muted to bright accent.
    local cold = Theme.panelAlt
    local hot = Theme.accent
    local r = cold[1] + (hot[1] - cold[1]) * t
    local g = cold[2] + (hot[2] - cold[2]) * t
    local b = cold[3] + (hot[3] - cold[3]) * t
    return r, g, b
end

--- Group spec buckets by their parent class, preserving per-class sort by fights.
--- Returns an ordered list of { classFile, className, specs = { bucket, ... } }.
local function groupSpecsByClass(specBuckets)
    local classMap = {}   -- classFile -> { classFile, className, specs }
    local classOrder = {} -- insertion order

    for _, bucket in ipairs(specBuckets) do
        local specId = tonumber(bucket.key)
        local profile = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype
            and ns.StaticPvpData.GetSpecArchetype(specId)
        local classFile = profile and profile.classFile or "UNKNOWN"
        local className = profile and profile.classFile or bucket.label

        if not classMap[classFile] then
            classMap[classFile] = { classFile = classFile, className = className, specs = {}, totalFights = 0 }
            classOrder[#classOrder + 1] = classFile
        end
        local group = classMap[classFile]
        group.specs[#group.specs + 1] = bucket
        group.totalFights = group.totalFights + (bucket.fights or 0)
    end

    -- Sort class groups by total fights descending.
    table.sort(classOrder, function(a, b)
        return classMap[a].totalFights > classMap[b].totalFights
    end)

    local result = {}
    for _, cf in ipairs(classOrder) do
        result[#result + 1] = classMap[cf]
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

function ClassSpecView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Class / Spec Analysis", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Rollups by class and spec to expose matchup trends.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scroll, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    -- Dynamic element pools: hide and recycle on each Refresh.
    self.pool = {}

    return self.frame
end

-- ---------------------------------------------------------------------------
-- Pool management
-- ---------------------------------------------------------------------------

local function releasePool(pool)
    for i = 1, #pool do
        pool[i]:Hide()
        pool[i]:ClearAllPoints()
    end
end

local function trackFrame(pool, frame)
    pool[#pool + 1] = frame
    return frame
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function ClassSpecView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterRef = store:GetCurrentCharacterRef()
    local classBuckets = store:GetAggregateBuckets("classes", characterRef)
    local specBuckets = store:GetAggregateBuckets("specs", characterRef)
    local latestSession = store:GetLatestSession(characterRef)
    local usingFallback = false

    if #classBuckets == 0 and #specBuckets == 0 then
        classBuckets = store:GetAggregateBuckets("classes")
        specBuckets = store:GetAggregateBuckets("specs")
        latestSession = latestSession or store:GetLatestSession()
        usingFallback = (#classBuckets > 0 or #specBuckets > 0)
    end

    if latestSession then
        self.caption:SetText(string.format(
            "Rollups by class and spec for %s to expose matchup trends%s.",
            store:GetSessionCharacterLabel(latestSession),
            usingFallback and " (fallback to all stored sessions)" or ""
        ))
    else
        self.caption:SetText("Rollups by class and spec for the current character to expose matchup trends.")
    end

    -- Release old dynamic elements.
    releasePool(self.pool)
    self.pool = {}

    local yOffset = 0

    -- -----------------------------------------------------------------------
    -- Section 1: Class-grouped win-rate bars
    -- -----------------------------------------------------------------------
    local classTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Classes", "TOPLEFT", self.canvas, "TOPLEFT", 4, -yOffset)
    trackFrame(self.pool, classTitle)
    yOffset = yOffset + 22

    if #classBuckets == 0 then
        local noData = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noData:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        noData:SetText("No class aggregates yet.")
        noData:SetTextColor(unpack(Theme.textMuted))
        trackFrame(self.pool, noData)
        yOffset = yOffset + 18
    else
        for index = 1, math.min(13, #classBuckets) do
            local bucket = classBuckets[index]
            local fights = bucket.fights or 0
            local wins = bucket.wins or 0
            local losses = bucket.losses or 0
            local winRate = fights > 0 and (wins / fights) or 0
            local avgPressure = fights > 0 and ((bucket.totalPressureScore or 0) / fights) or 0
            local avgDamageTaken = fights > 0 and ((bucket.totalDamageTaken or 0) / fights) or 0
            local fillColor = classColor(bucket.key)

            local bar = ns.Widgets.CreateMetricBar(self.canvas, BAR_WIDTH, BAR_HEIGHT)
            bar:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
            bar:SetData(
                string.format("%s", bucket.label or bucket.key),
                string.format("%d%%  W-L %d-%d", math.floor(winRate * 100 + 0.5), wins, losses),
                string.format(
                    "%d fights  |  avg pressure %.1f  |  avg taken %s",
                    fights, avgPressure, Helpers.FormatNumber(avgDamageTaken)
                ),
                winRate,
                fillColor
            )
            trackFrame(self.pool, bar)
            yOffset = yOffset + BAR_HEIGHT + 4
        end
    end

    yOffset = yOffset + 12

    -- -----------------------------------------------------------------------
    -- Section 2: Spec heat-grid + clickable spec rows
    -- -----------------------------------------------------------------------
    local specTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Specs", "TOPLEFT", self.canvas, "TOPLEFT", 4, -yOffset)
    trackFrame(self.pool, specTitle)
    yOffset = yOffset + 22

    if #specBuckets == 0 then
        local noData = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noData:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        noData:SetText("No spec aggregates yet.")
        noData:SetTextColor(unpack(Theme.textMuted))
        trackFrame(self.pool, noData)
        yOffset = yOffset + 18
    else
        local hint = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        hint:SetText("Click a spec row to see full matchup details.")
        hint:SetTextColor(unpack(Theme.textMuted))
        trackFrame(self.pool, hint)
        yOffset = yOffset + 18

        -- Compute global maxima for heat-grid normalization.
        local maxFights = 1
        local maxPressure = 1
        local maxTaken = 1
        for _, bucket in ipairs(specBuckets) do
            local f = bucket.fights or 0
            if f > maxFights then maxFights = f end
            local p = f > 0 and ((bucket.totalPressureScore or 0) / f) or 0
            if p > maxPressure then maxPressure = p end
            local t = f > 0 and ((bucket.totalDamageTaken or 0) / f) or 0
            if t > maxTaken then maxTaken = t end
        end

        -- Group specs by class for visual cohesion.
        local classGroups = groupSpecsByClass(specBuckets)

        for _, group in ipairs(classGroups) do
            local cc = classColor(group.classFile)
            local specs = group.specs
            local specCount = #specs

            -- Class sub-header with total fights.
            local classHeader = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            classHeader:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
            classHeader:SetText(group.className)
            classHeader:SetTextColor(cc[1], cc[2], cc[3], cc[4] or 1)
            trackFrame(self.pool, classHeader)
            yOffset = yOffset + 18

            -- Heat-grid: rows = specs in this class, cols = Fights / WR / Pressure / Taken.
            local gridData = {}
            local rowLabels = {}
            for si = 1, specCount do
                local bucket = specs[si]
                local fights = bucket.fights or 0
                local winRate = fights > 0 and (bucket.wins or 0) / fights or 0
                local avgPressure = fights > 0 and ((bucket.totalPressureScore or 0) / fights) or 0
                local avgTaken = fights > 0 and ((bucket.totalDamageTaken or 0) / fights) or 0

                gridData[si] = {
                    fights / maxFights,         -- normalized fights
                    winRate,                     -- already 0..1
                    avgPressure / maxPressure,   -- normalized pressure
                    avgTaken / maxTaken,          -- normalized taken
                }
                rowLabels[si] = bucket.label or bucket.key
            end

            local grid = ns.Widgets.CreateHeatGrid(
                self.canvas,
                specCount,
                HEAT_COLS,
                gridData,
                heatColorRamp,
                { rowLabels = rowLabels, colLabels = HEAT_COL_LABELS },
                HEAT_CELL_SIZE
            )
            grid:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
            trackFrame(self.pool, grid)

            local gridHeight = (HEAT_COL_LABELS and 14 or 0) + specCount * HEAT_CELL_SIZE
            local gridWidth = 60 + HEAT_COLS * HEAT_CELL_SIZE  -- label offset + cells

            -- Clickable spec rows positioned to the right of the heat-grid.
            local rowXOffset = 8 + gridWidth + 16
            local rowWidth = math.max(200, BAR_WIDTH - gridWidth - 16)
            local rowYBase = yOffset + (HEAT_COL_LABELS and 14 or 0)

            for si = 1, specCount do
                local bucket = specs[si]
                local specId = tonumber(bucket.key)
                local fights = bucket.fights or 0
                local wins = bucket.wins or 0
                local losses = bucket.losses or 0
                local winRate = fights > 0 and (wins / fights) or 0
                local avgPressure = fights > 0 and ((bucket.totalPressureScore or 0) / fights) or 0

                local specProfile = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype
                    and ns.StaticPvpData.GetSpecArchetype(specId)
                local descriptor = specProfile
                    and string.format("%s / %s", specProfile.rangeBucket or "unknown", specProfile.archetype or "unknown")
                    or "untyped"

                local rowHeight = HEAT_CELL_SIZE - 2
                local btn = CreateFrame("Button", nil, self.canvas, "BackdropTemplate")
                btn:SetSize(rowWidth, rowHeight)
                btn:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", rowXOffset, -(rowYBase + (si - 1) * HEAT_CELL_SIZE))
                ns.Widgets.ApplyBackdrop(btn, Theme.panel, Theme.border)

                -- Win-rate fill bar inside the button.
                local fill = btn:CreateTexture(nil, "BACKGROUND")
                fill:SetTexture("Interface\\Buttons\\WHITE8x8")
                fill:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
                fill:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, 1)
                local fillWidth = math.max(1, (rowWidth - 2) * winRate)
                fill:SetWidth(fillWidth)
                fill:SetVertexColor(cc[1], cc[2], cc[3], 0.15)

                btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.label:SetPoint("LEFT", btn, "LEFT", 8, 0)
                btn.label:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
                btn.label:SetJustifyH("LEFT")
                btn.label:SetTextColor(unpack(Theme.text))
                btn.label:SetText(string.format(
                    "%s  %d%% WR  %d-%d  avg %.1f  |  %s",
                    bucket.label or bucket.key,
                    math.floor(winRate * 100 + 0.5),
                    wins, losses,
                    avgPressure,
                    descriptor
                ))

                btn:SetScript("OnClick", function()
                    ns.Addon:OpenView("matchup", { specId = specId })
                end)
                btn:SetScript("OnEnter", function(self)
                    self.label:SetTextColor(unpack(Theme.accent))
                    ns.Widgets.SetBackdropColors(self, Theme.panelHover, Theme.borderStrong)
                end)
                btn:SetScript("OnLeave", function(self)
                    self.label:SetTextColor(unpack(Theme.text))
                    ns.Widgets.SetBackdropColors(self, Theme.panel, Theme.border)
                end)

                trackFrame(self.pool, btn)
            end

            yOffset = yOffset + gridHeight + 10
        end
    end

    ns.Widgets.SetCanvasHeight(self.canvas, yOffset + 20)
end

ns.Addon:RegisterModule("ClassSpecView", ClassSpecView)
