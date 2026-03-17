local _, ns = ...

local DummyBenchmarkView = {
    viewId = "dummy",
}

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

function DummyBenchmarkView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Training Dummy Benchmarks", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Benchmark board for sustained damage, opener quality, burst threat, and cast cadence across your stored dummy sessions.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.emptyState = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyState:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, 0)
    self.emptyState:SetTextColor(unpack(ns.Widgets.THEME.textMuted))
    self.emptyState:SetText("No dummy benchmark sessions yet.")

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

    self.boardTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Benchmark Board", "TOPLEFT", self.cards[1], "BOTTOMLEFT", 0, -22)
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

    ns.Widgets.SetCanvasHeight(self.canvas, 940)
    return self.frame
end

function DummyBenchmarkView:Refresh()
    local benchmarks = ns.Addon:GetModule("CombatStore"):GetDummyBenchmarks()
    if self.scrollFrame and self.scrollFrame.scrollBar then
        self.scrollFrame.scrollBar:SetValue(0)
    elseif self.scrollFrame and self.scrollFrame.SetVerticalScroll then
        self.scrollFrame:SetVerticalScroll(0)
    end
    if #benchmarks == 0 then
        self.emptyState:Show()
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
        bestSustained and string.format("%s across %d sessions.", bestSustained.dummyName or "Dummy", bestSustained.sessions or 0) or "No data.",
        ns.Widgets.THEME.accent
    )
    self.cards[1]:Show()

    self.cards[2]:SetData(
        bestBurstAverages and ns.Helpers.FormatNumber(bestBurstAverages.burst) or "--",
        "Best Burst Benchmark",
        bestBurst and string.format("%s opener %s.", bestBurst.dummyName or "Dummy", ns.Helpers.FormatNumber(bestBurstAverages.opener or 0)) or "No data.",
        ns.Widgets.THEME.warning
    )
    self.cards[2]:Show()

    self.cards[3]:SetData(
        mostPracticed and tostring(mostPracticed.sessions or 0) or "--",
        "Most Practiced Target",
        mostPracticed and string.format("%s rotation %.1f.", mostPracticed.dummyName or "Dummy", mostPracticedAverages.rotation or 0) or "No data.",
        ns.Widgets.THEME.success
    )
    self.cards[3]:Show()

    local maxSustained = 1
    for _, benchmark in ipairs(benchmarks) do
        maxSustained = math.max(maxSustained, getBenchmarkAverages(benchmark).sustained)
    end

    for index, row in ipairs(self.rows) do
        local benchmark = benchmarks[index]
        if benchmark then
            local averages = getBenchmarkAverages(benchmark)
            row:SetData(
                string.format("%s  |  %d sessions", benchmark.dummyName or "Training Dummy", benchmark.sessions or 0),
                string.format("%s DPS", ns.Helpers.FormatNumber(averages.sustained)),
                string.format("Burst %s  |  Opener %s  |  Rotation %.1f", ns.Helpers.FormatNumber(averages.burst), ns.Helpers.FormatNumber(averages.opener), averages.rotation or 0),
                averages.sustained / maxSustained,
                ns.Widgets.THEME.accent
            )
            row:Show()
        else
            row:Hide()
        end
    end
end

ns.Addon:RegisterModule("DummyBenchmarkView", DummyBenchmarkView)
