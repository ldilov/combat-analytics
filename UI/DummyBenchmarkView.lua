local _, ns = ...

local DummyBenchmarkView = {
    viewId = "dummy",
}

-- ---------------------------------------------------------------------------
-- Data helpers
-- ---------------------------------------------------------------------------

local function getBenchmarkAverages(benchmark)
    local sessions = math.max(benchmark.sessions or 1, 1)
    return {
        sustained = (benchmark.totalSustainedDps or 0) / sessions,
        burst = (benchmark.totalBurstDps or 0) / sessions,
        opener = (benchmark.totalOpenerDamage or 0) / sessions,
        rotation = (benchmark.totalRotationScore or 0) / sessions,
    }
end

local function findTopBenchmark(benchmarks, selector)
    local best = nil
    local bestValue = nil

    for _, benchmark in ipairs(benchmarks) do
        local value = selector(benchmark)
        if not best or value > (bestValue or 0) then
            best = benchmark
            bestValue = value
        end
    end

    return best, bestValue or 0
end

--- Collect per-session metric arrays for a given benchmark, ordered oldest first.
--- Walks the full session store once for the character and groups by benchmark key.
--- Returns a table keyed by benchmark.key, each value = { sustainedDps[], openerDamage[], rotationScore[] }.
local function collectPerSessionTrends(store, characterKey, benchmarks)
    local Constants = ns.Constants
    local db = store:GetDB()

    -- Build a lookup from benchmark key back to the benchmark record.
    local benchmarkByKey = {}
    for _, bm in ipairs(benchmarks) do
        benchmarkByKey[bm.key] = bm
    end

    -- We need a way to derive the same benchmark key per session that
    -- updateDummyBenchmarkRecord uses.  Reproduce the key logic here.
    local trends = {}
    for _, sessionId in ipairs(db.combats.order or {}) do
        local session = db.combats.byId[sessionId]
        if session and session.context == Constants.CONTEXT.TRAINING_DUMMY then
            local snapshot = session.playerSnapshot or {}
            local sessionCharKey = store:GetSessionCharacterKey(session)

            -- Only include sessions for the active character.
            if sessionCharKey == characterKey then
                local opponent = session.primaryOpponent or {}
                local dummyInfo = opponent.creatureId
                    and ns.StaticPvpData
                    and ns.StaticPvpData.GetDummyInfo
                    and ns.StaticPvpData.GetDummyInfo(opponent.creatureId)
                    or nil
                local buildHash = snapshot.buildHash or "unknown"
                local specId = snapshot.specId or 0
                local bmKey = table.concat({
                    tostring(sessionCharKey),
                    tostring(buildHash),
                    tostring(specId),
                    tostring(dummyInfo and dummyInfo.benchmarkGroup or opponent.name or "dummy"),
                    tostring(opponent.level or 0),
                }, "#")

                -- Only collect if this key matches one of the displayed benchmarks.
                if benchmarkByKey[bmKey] then
                    local bucket = trends[bmKey]
                    if not bucket then
                        bucket = { sustainedDps = {}, openerDamage = {}, rotationScore = {} }
                        trends[bmKey] = bucket
                    end
                    local m = session.metrics or {}
                    bucket.sustainedDps[#bucket.sustainedDps + 1] = m.sustainedDps or 0
                    bucket.openerDamage[#bucket.openerDamage + 1] = m.openerDamage or 0
                    bucket.rotationScore[#bucket.rotationScore + 1] = m.rotationalConsistencyScore or 0
                end
            end
        end
    end

    return trends
end

--- Compute best / median / worst from a numeric array.
local function computeSpread(values)
    if not values or #values == 0 then
        return { best = 0, median = 0, worst = 0 }
    end

    -- Build a sorted copy (ascending).
    local sorted = {}
    for i = 1, #values do
        sorted[i] = values[i]
    end
    table.sort(sorted)

    local n = #sorted
    local medianIndex = math.ceil(n / 2)
    return {
        worst = sorted[1],
        median = sorted[medianIndex],
        best = sorted[n],
    }
end

-- ---------------------------------------------------------------------------
-- Dynamic element tracking
-- ---------------------------------------------------------------------------

local function hideAndClear(list)
    for i = #list, 1, -1 do
        local element = list[i]
        if element and element.Hide then
            element:Hide()
        end
        list[i] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

function DummyBenchmarkView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()
    self.dynamicElements = {}

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Training Dummy Benchmarks", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Benchmark board for sustained damage, opener quality, burst threat, and cast cadence across your stored dummy sessions.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.emptyState:SetText("No dummy benchmark sessions yet.")

    -- Top metric cards (3)
    self.cards = {}
    for index = 1, 3 do
        local card = ns.Widgets.CreateMetricCard(self.canvas, 244, 88)
        if index == 1 then
            card:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
        else
            card:SetPoint("TOPLEFT", self.cards[index - 1], "TOPRIGHT", 9, 0)
        end
        self.cards[index] = card
    end

    -- Trend section title + caption (positioned below cards, above sparklines)
    self.trendTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Trend Analysis", "TOPLEFT", self.cards[1], "BOTTOMLEFT", 0, -22)
    self.trendCaption = ns.Widgets.CreateCaption(self.canvas, "Sustained DPS and opener damage trends across sessions for the top benchmark. The consistency band shows your best, median, and worst opener damage.", "TOPLEFT", self.trendTitle, "BOTTOMLEFT", 0, -4)

    -- Sparkline labels (static; sparklines themselves are dynamic)
    self.sustainedSparkLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.sustainedSparkLabel:SetPoint("TOPLEFT", self.trendCaption, "BOTTOMLEFT", 0, -14)
    self.sustainedSparkLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.sustainedSparkLabel:SetText("Sustained DPS Trend")

    self.openerSparkLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.openerSparkLabel:SetPoint("TOPLEFT", self.sustainedSparkLabel, "BOTTOMLEFT", 0, -42)
    self.openerSparkLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.openerSparkLabel:SetText("Opener Damage Trend")

    -- Consistency band label
    self.consistencyLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.consistencyLabel:SetPoint("TOPLEFT", self.openerSparkLabel, "BOTTOMLEFT", 0, -42)
    self.consistencyLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.consistencyLabel:SetText("Opener Consistency (Worst / Median / Best)")

    -- Rotation gauge label
    self.gaugeLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.gaugeLabel:SetPoint("TOPLEFT", self.consistencyLabel, "BOTTOMLEFT", 0, -32)
    self.gaugeLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.gaugeLabel:SetText("Rotation Consistency Score")

    -- Board section
    self.boardTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Benchmark Board", "TOPLEFT", self.gaugeLabel, "BOTTOMLEFT", 0, -36)
    self.boardCaption = ns.Widgets.CreateCaption(self.canvas, "Each bar represents average sustained DPS for that benchmark. Captions keep the burst, opener, and rotation context visible.", "TOPLEFT", self.boardTitle, "BOTTOMLEFT", 0, -4)

    self.rows = {}
    for index = 1, 10 do
        local row = ns.Widgets.CreateMetricBar(self.canvas, 750, 60)
        if index == 1 then
            row:SetPoint("TOPLEFT", self.boardCaption, "BOTTOMLEFT", 0, -12)
        else
            row:SetPoint("TOPLEFT", self.rows[index - 1], "BOTTOMLEFT", 0, -8)
        end
        self.rows[index] = row
    end

    -- Canvas height will be recalculated during Refresh.
    ns.Widgets.SetCanvasHeight(self.canvas, 1200)
    return self.frame
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function DummyBenchmarkView:Refresh()
    local store = ns.Addon:GetModule("CombatStore")
    local characterKey = store:GetCurrentCharacterKey()
    local benchmarks = store:GetDummyBenchmarks(characterKey)
    local latestSession = store:GetLatestSession(characterKey)
    local Theme = ns.Widgets.THEME

    -- Clean up dynamic elements from previous refresh.
    hideAndClear(self.dynamicElements)

    if latestSession then
        self.caption:SetText(string.format("Benchmark board for %s across stored dummy sessions.", store:GetSessionCharacterLabel(latestSession)))
    else
        self.caption:SetText("Benchmark board for the current character across stored dummy sessions.")
    end

    -- Reset scroll position.
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end

    -- Empty state
    if #benchmarks == 0 then
        self.emptyState:Show()
        self.trendTitle:Hide()
        self.trendCaption:Hide()
        self.sustainedSparkLabel:Hide()
        self.openerSparkLabel:Hide()
        self.consistencyLabel:Hide()
        self.gaugeLabel:Hide()
        self.boardTitle:Hide()
        self.boardCaption:Hide()
        for _, card in ipairs(self.cards) do
            card:Hide()
        end
        for _, row in ipairs(self.rows) do
            row:Hide()
        end
        return
    end

    self.emptyState:Hide()
    self.boardTitle:Show()
    self.boardCaption:Show()

    -- -----------------------------------------------------------------------
    -- Top metric cards
    -- -----------------------------------------------------------------------

    local bestSustained = findTopBenchmark(benchmarks, function(benchmark)
        return getBenchmarkAverages(benchmark).sustained
    end)
    local bestBurst = findTopBenchmark(benchmarks, function(benchmark)
        return getBenchmarkAverages(benchmark).burst
    end)
    local mostPracticed = findTopBenchmark(benchmarks, function(benchmark)
        return benchmark.sessions or 0
    end)

    local bestSustainedAverages = bestSustained and getBenchmarkAverages(bestSustained) or nil
    local bestBurstAverages = bestBurst and getBenchmarkAverages(bestBurst) or nil
    local mostPracticedAverages = mostPracticed and getBenchmarkAverages(mostPracticed) or nil

    self.cards[1]:SetData(
        bestSustainedAverages and ns.Helpers.FormatNumber(bestSustainedAverages.sustained) or "--",
        "Best Sustained DPS",
        bestSustained and string.format("%s (%s) across %d sessions.", bestSustained.dummyName or "Dummy", bestSustained.benchmarkGroup or "general", bestSustained.sessions or 0) or "No data.",
        Theme.accent
    )
    self.cards[1]:Show()

    self.cards[2]:SetData(
        bestBurstAverages and ns.Helpers.FormatNumber(bestBurstAverages.burst) or "--",
        "Best Burst Benchmark",
        bestBurst and string.format("%s opener %s.", bestBurst.dummyName or "Dummy", ns.Helpers.FormatNumber(bestBurstAverages.opener or 0)) or "No data.",
        Theme.warning
    )
    self.cards[2]:Show()

    self.cards[3]:SetData(
        mostPracticed and tostring(mostPracticed.sessions or 0) or "--",
        "Most Practiced Target",
        mostPracticed and string.format("%s rotation %.1f.", mostPracticed.dummyName or "Dummy", mostPracticedAverages.rotation or 0) or "No data.",
        Theme.success
    )
    self.cards[3]:Show()

    -- -----------------------------------------------------------------------
    -- Trend analysis section
    -- -----------------------------------------------------------------------

    local trends = collectPerSessionTrends(store, characterKey, benchmarks)

    -- Pick the top benchmark (most sessions) for trend display.
    local trendBenchmark = mostPracticed or bestSustained or benchmarks[1]
    local trendData = trendBenchmark and trends[trendBenchmark.key] or nil
    local hasTrendData = trendData and #trendData.sustainedDps >= 2

    if hasTrendData then
        self.trendTitle:Show()
        self.trendCaption:Show()
        self.sustainedSparkLabel:Show()
        self.openerSparkLabel:Show()
        self.consistencyLabel:Show()
        self.gaugeLabel:Show()

        -- 1. Sustained DPS sparkline
        local sustainedSparkline = ns.Widgets.CreateSparkline(
            self.canvas,
            trendData.sustainedDps,
            Theme.accent,
            360,
            28
        )
        sustainedSparkline:SetPoint("TOPLEFT", self.sustainedSparkLabel, "BOTTOMLEFT", 0, -4)
        self.dynamicElements[#self.dynamicElements + 1] = sustainedSparkline

        -- Sustained DPS value summary beside sparkline
        local sustainedSummary = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sustainedSummary:SetPoint("LEFT", sustainedSparkline, "RIGHT", 16, 0)
        sustainedSummary:SetTextColor(unpack(Theme.text))
        local latestSustained = trendData.sustainedDps[#trendData.sustainedDps]
        local firstSustained = trendData.sustainedDps[1]
        local sustainedDelta = latestSustained - firstSustained
        local sustainedPrefix = sustainedDelta >= 0 and "+" or ""
        sustainedSummary:SetText(string.format(
            "Latest: %s DPS  (%s%s)",
            ns.Helpers.FormatNumber(latestSustained),
            sustainedPrefix,
            ns.Helpers.FormatNumber(sustainedDelta)
        ))
        self.dynamicElements[#self.dynamicElements + 1] = sustainedSummary

        -- 2. Opener damage sparkline
        local openerSparkline = ns.Widgets.CreateSparkline(
            self.canvas,
            trendData.openerDamage,
            Theme.warning,
            360,
            28
        )
        openerSparkline:SetPoint("TOPLEFT", self.openerSparkLabel, "BOTTOMLEFT", 0, -4)
        self.dynamicElements[#self.dynamicElements + 1] = openerSparkline

        -- Opener value summary beside sparkline
        local openerSummary = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        openerSummary:SetPoint("LEFT", openerSparkline, "RIGHT", 16, 0)
        openerSummary:SetTextColor(unpack(Theme.text))
        local latestOpener = trendData.openerDamage[#trendData.openerDamage]
        local firstOpener = trendData.openerDamage[1]
        local openerDelta = latestOpener - firstOpener
        local openerPrefix = openerDelta >= 0 and "+" or ""
        openerSummary:SetText(string.format(
            "Latest: %s  (%s%s)",
            ns.Helpers.FormatNumber(latestOpener),
            openerPrefix,
            ns.Helpers.FormatNumber(openerDelta)
        ))
        self.dynamicElements[#self.dynamicElements + 1] = openerSummary

        -- 3. Opener consistency band (segmented bar: worst / median-worst / best-median)
        local spread = computeSpread(trendData.openerDamage)
        local segments = {
            {
                value = spread.worst,
                color = { Theme.severityHigh[1], Theme.severityHigh[2], Theme.severityHigh[3], 0.7 },
                label = ns.Helpers.FormatNumber(spread.worst),
            },
            {
                value = math.max(spread.median - spread.worst, 0),
                color = { Theme.warning[1], Theme.warning[2], Theme.warning[3], 0.7 },
                label = ns.Helpers.FormatNumber(spread.median),
            },
            {
                value = math.max(spread.best - spread.median, 0),
                color = { Theme.success[1], Theme.success[2], Theme.success[3], 0.7 },
                label = ns.Helpers.FormatNumber(spread.best),
            },
        }

        local consistencyBar = ns.Widgets.CreateSegmentedBar(
            self.canvas,
            segments,
            360,
            18
        )
        consistencyBar:SetPoint("TOPLEFT", self.consistencyLabel, "BOTTOMLEFT", 0, -4)
        self.dynamicElements[#self.dynamicElements + 1] = consistencyBar

        -- Consistency band text summary
        local consistencySummary = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        consistencySummary:SetPoint("LEFT", consistencyBar, "RIGHT", 16, 0)
        consistencySummary:SetTextColor(unpack(Theme.textMuted))
        local variance = spread.best > 0 and ((spread.best - spread.worst) / spread.best * 100) or 0
        consistencySummary:SetText(string.format("Range: %.0f%% variance across %d sessions", variance, #trendData.openerDamage))
        self.dynamicElements[#self.dynamicElements + 1] = consistencySummary

        -- 4. Rotation consistency gauge
        local avgRotation = trendBenchmark and getBenchmarkAverages(trendBenchmark).rotation or 0
        local gaugeThresholds = {
            { value = 40, color = Theme.severityHigh },
            { value = 70, color = Theme.warning },
        }
        local gaugeColor = Theme.success
        if avgRotation < 40 then
            gaugeColor = Theme.severityHigh
        elseif avgRotation < 70 then
            gaugeColor = Theme.warning
        end

        local gauge = ns.Widgets.CreateGauge(
            self.canvas,
            avgRotation,
            0,
            100,
            gaugeThresholds,
            gaugeColor,
            360,
            16
        )
        gauge:SetPoint("TOPLEFT", self.gaugeLabel, "BOTTOMLEFT", 0, -4)
        self.dynamicElements[#self.dynamicElements + 1] = gauge

        -- Gauge value label
        local gaugeValue = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        gaugeValue:SetPoint("LEFT", gauge, "RIGHT", 16, 0)
        gaugeValue:SetTextColor(unpack(Theme.text))
        gaugeValue:SetText(string.format("%.1f / 100", avgRotation))
        self.dynamicElements[#self.dynamicElements + 1] = gaugeValue

        -- 5. Rotation consistency gap histogram + opener delta + proc rate
        local Metrics = ns.Addon:GetModule("Metrics") or ns.Metrics
        local rotConsistency = Metrics and Metrics.ComputeRotationConsistency
            and Metrics:ComputeRotationConsistency(latestSession) or nil

        if rotConsistency and rotConsistency.gapHistogram and #rotConsistency.gapHistogram > 0 then
            local rcTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Rotation Consistency",
                "TOPLEFT", gauge, "BOTTOMLEFT", 0, -22)
            self.dynamicElements[#self.dynamicElements + 1] = rcTitle

            -- Gap histogram as segmented bar (5 buckets)
            local labels = rotConsistency.gapLabels or {}
            local hist = rotConsistency.gapHistogram
            local histColors = {
                { Theme.success[1], Theme.success[2], Theme.success[3], 0.8 },
                { Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.8 },
                { Theme.warning[1], Theme.warning[2], Theme.warning[3], 0.8 },
                { Theme.severityHigh[1], Theme.severityHigh[2], Theme.severityHigh[3], 0.7 },
                { Theme.severityCritical[1], Theme.severityCritical[2], Theme.severityCritical[3], 0.7 },
            }
            local histSegments = {}
            for i = 1, 5 do
                histSegments[i] = {
                    value = hist[i] or 0,
                    color = histColors[i] or histColors[1],
                    label = labels[i] or "",
                }
            end
            local gapBar = ns.Widgets.CreateSegmentedBar(self.canvas, histSegments, 360, 18)
            gapBar:SetPoint("TOPLEFT", rcTitle, "BOTTOMLEFT", 0, -6)
            self.dynamicElements[#self.dynamicElements + 1] = gapBar

            local gapSummary = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            gapSummary:SetPoint("LEFT", gapBar, "RIGHT", 16, 0)
            gapSummary:SetTextColor(unpack(Theme.textMuted))
            gapSummary:SetText(string.format("Cast gaps: %d total", rotConsistency.totalGaps or 0))
            self.dynamicElements[#self.dynamicElements + 1] = gapSummary

            -- Opener best vs median delta bar
            local openerBand = Metrics.ComputeOpenerVarianceBand
                and Metrics:ComputeOpenerVarianceBand(store:GetDummySessions and store:GetDummySessions(characterKey) or {}) or nil
            if openerBand and openerBand.best > 0 then
                local deltaBar = ns.Widgets.CreateMirroredDeltaBar(
                    self.canvas,
                    openerBand.median, openerBand.best,
                    Theme.warning, Theme.success,
                    string.format("Median %s / Best %s", ns.Helpers.FormatNumber(openerBand.median), ns.Helpers.FormatNumber(openerBand.best)),
                    360, 18
                )
                deltaBar:SetPoint("TOPLEFT", gapBar, "BOTTOMLEFT", 0, -10)
                self.dynamicElements[#self.dynamicElements + 1] = deltaBar
            end

            -- Proc conversion rate text
            local procText = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            procText:SetPoint("TOPLEFT", gapBar, "BOTTOMLEFT", 0, -34)
            procText:SetTextColor(unpack(Theme.text))
            procText:SetText(string.format("Proc conversion rate: %.0f%%", (rotConsistency.procConversionRate or 0) * 100))
            self.dynamicElements[#self.dynamicElements + 1] = procText
        end
    else
        -- Not enough data for trends -- hide the section and reposition the board.
        self.trendTitle:Hide()
        self.trendCaption:Hide()
        self.sustainedSparkLabel:Hide()
        self.openerSparkLabel:Hide()
        self.consistencyLabel:Hide()
        self.gaugeLabel:Hide()

        -- Move board title directly below cards when trend section is hidden.
        self.boardTitle:ClearAllPoints()
        self.boardTitle:SetPoint("TOPLEFT", self.cards[1], "BOTTOMLEFT", 0, -22)
    end

    -- When trend section is visible, ensure board title is anchored below the gauge
    -- plus the rotation consistency section (~120px extra).
    if hasTrendData then
        self.boardTitle:ClearAllPoints()
        self.boardTitle:SetPoint("TOPLEFT", self.gaugeLabel, "BOTTOMLEFT", 0, -156)
    end

    -- -----------------------------------------------------------------------
    -- Benchmark board rows
    -- -----------------------------------------------------------------------

    local maxSustained = 1
    for _, benchmark in ipairs(benchmarks) do
        maxSustained = math.max(maxSustained, getBenchmarkAverages(benchmark).sustained)
    end

    for index, row in ipairs(self.rows) do
        local benchmark = benchmarks[index]
        if benchmark then
            local averages = getBenchmarkAverages(benchmark)
            row:SetData(
                string.format("%s  |  %s  |  %d sessions", benchmark.dummyName or "Training Dummy", benchmark.benchmarkGroup or "general", benchmark.sessions or 0),
                string.format("%s DPS", ns.Helpers.FormatNumber(averages.sustained)),
                string.format("Burst %s  |  Opener %s  |  Rotation %.1f", ns.Helpers.FormatNumber(averages.burst), ns.Helpers.FormatNumber(averages.opener), averages.rotation or 0),
                averages.sustained / maxSustained,
                Theme.accent
            )
            row:Show()
        else
            row:Hide()
        end
    end

    -- -----------------------------------------------------------------------
    -- Compute final canvas height
    -- -----------------------------------------------------------------------
    local visibleRows = math.min(#benchmarks, 10)
    -- Cards: 88, gap 22, trend section ~220 when visible, rotation consistency ~120,
    -- gap 22, board header ~40, rows: visibleRows * 68, bottom padding 32.
    local trendHeight = hasTrendData and 360 or 0
    local totalHeight = 88 + 22 + trendHeight + 22 + 40 + (visibleRows * 68) + 32
    ns.Widgets.SetCanvasHeight(self.canvas, totalHeight)
end

ns.Addon:RegisterModule("DummyBenchmarkView", DummyBenchmarkView)
