local _, ns = ...

local Theme = ns.Widgets.THEME

local ClassSpecView = {
    viewId = "classspec",
}

function ClassSpecView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Class / Spec Analysis", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Rollups by class and spec to expose matchup trends.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)

    self.shell, self.scroll, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)
    self.shell:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.shell:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)

    self.specButtons = {}
    self.classHeaders = {}

    return self.frame
end

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
        self.caption:SetText(string.format("Rollups by class and spec for %s to expose matchup trends%s.", store:GetSessionCharacterLabel(latestSession), usingFallback and " (fallback to all stored sessions)" or ""))
    else
        self.caption:SetText("Rollups by class and spec for the current character to expose matchup trends.")
    end

    -- Release old buttons and headers
    for _, btn in ipairs(self.specButtons) do
        btn:Hide()
    end
    self.specButtons = {}
    for _, hdr in ipairs(self.classHeaders) do
        hdr:Hide()
    end
    self.classHeaders = {}

    local yOffset = 0

    -- Classes section header
    local classTitle = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    classTitle:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 4, -yOffset)
    classTitle:SetText("Classes")
    classTitle:SetTextColor(unpack(Theme.text))
    self.classHeaders[#self.classHeaders + 1] = classTitle
    yOffset = yOffset + 22

    if #classBuckets == 0 then
        local noData = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noData:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        noData:SetText("No class aggregates yet.")
        noData:SetTextColor(unpack(Theme.textMuted))
        self.classHeaders[#self.classHeaders + 1] = noData
        yOffset = yOffset + 18
    else
        for index = 1, math.min(12, #classBuckets) do
            local bucket = classBuckets[index]
            local label = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
            label:SetTextColor(unpack(Theme.text))
            label:SetText(string.format(
                "%d. %s  fights=%d  W-L=%d-%d  avg pressure=%.1f",
                index,
                bucket.label or bucket.key,
                bucket.fights or 0,
                bucket.wins or 0,
                bucket.losses or 0,
                (bucket.totalPressureScore or 0) / math.max(bucket.fights or 1, 1)
            ))
            self.classHeaders[#self.classHeaders + 1] = label
            yOffset = yOffset + 18
        end
    end

    yOffset = yOffset + 12

    -- Specs section header
    local specTitle = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    specTitle:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 4, -yOffset)
    specTitle:SetText("Specs")
    specTitle:SetTextColor(unpack(Theme.text))
    self.classHeaders[#self.classHeaders + 1] = specTitle
    yOffset = yOffset + 22

    if #specBuckets == 0 then
        local noData = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noData:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        noData:SetText("No spec aggregates yet.")
        noData:SetTextColor(unpack(Theme.textMuted))
        self.classHeaders[#self.classHeaders + 1] = noData
        yOffset = yOffset + 18
    else
        local caption = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        caption:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
        caption:SetText("Click a spec to see full matchup details.")
        caption:SetTextColor(unpack(Theme.textMuted))
        self.classHeaders[#self.classHeaders + 1] = caption
        yOffset = yOffset + 18

        for index = 1, math.min(12, #specBuckets) do
            local bucket = specBuckets[index]
            local specProfile = ns.StaticPvpData and ns.StaticPvpData.GetSpecArchetype and ns.StaticPvpData.GetSpecArchetype(tonumber(bucket.key))
            local descriptor = specProfile and string.format("%s / %s", specProfile.rangeBucket or "unknown", specProfile.archetype or "unknown") or "untyped"

            local btn = CreateFrame("Button", nil, self.canvas, "BackdropTemplate")
            btn:SetSize(760, 24)
            btn:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -yOffset)
            ns.Widgets.ApplyBackdrop(btn, Theme.panel, Theme.border)

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", btn, "LEFT", 8, 0)
            btn.label:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
            btn.label:SetJustifyH("LEFT")
            btn.label:SetTextColor(unpack(Theme.text))
            btn.label:SetText(string.format(
                "%d. %s  fights=%d  W-L=%d-%d  avg pressure=%.1f  |  %s",
                index,
                bucket.label or bucket.key,
                bucket.fights or 0,
                bucket.wins or 0,
                bucket.losses or 0,
                (bucket.totalPressureScore or 0) / math.max(bucket.fights or 1, 1),
                descriptor
            ))

            local specId = tonumber(bucket.key)
            btn:SetScript("OnClick", function()
                ns.Addon:OpenView("matchup", { specId = specId })
            end)
            btn:SetScript("OnEnter", function(self)
                self.label:SetTextColor(unpack(Theme.accent))
                ns.Widgets.ApplyBackdrop(self, Theme.panelHover, Theme.borderStrong)
            end)
            btn:SetScript("OnLeave", function(self)
                self.label:SetTextColor(unpack(Theme.text))
                ns.Widgets.ApplyBackdrop(self, Theme.panel, Theme.border)
            end)

            self.specButtons[#self.specButtons + 1] = btn
            yOffset = yOffset + 26
        end
    end

    ns.Widgets.SetCanvasHeight(self.canvas, yOffset + 20)
end

ns.Addon:RegisterModule("ClassSpecView", ClassSpecView)
