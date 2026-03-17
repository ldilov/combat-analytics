local _, ns = ...

local ClassSpecView = {
    viewId = "classspec",
}

function ClassSpecView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Class / Spec Analysis", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Rollups by class and spec to expose matchup trends.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)
    self.scrollFrame, self.content, self.text = ns.Widgets.CreateBodyText(self.frame, 808, 410)
    self.scrollFrame:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)
    return self.frame
end

function ClassSpecView:Refresh()
    local classBuckets = ns.Addon:GetModule("CombatStore"):GetAggregateBuckets("classes")
    local specBuckets = ns.Addon:GetModule("CombatStore"):GetAggregateBuckets("specs")
    local lines = { "Classes" }

    if #classBuckets == 0 then
        lines[#lines + 1] = "No class aggregates yet."
    else
        for index = 1, math.min(12, #classBuckets) do
            local bucket = classBuckets[index]
            lines[#lines + 1] = string.format(
                "%d. %s  fights=%d  W-L=%d-%d  avg pressure=%.1f",
                index,
                bucket.label or bucket.key,
                bucket.fights or 0,
                bucket.wins or 0,
                bucket.losses or 0,
                (bucket.totalPressureScore or 0) / math.max(bucket.fights or 1, 1)
            )
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Specs"
    if #specBuckets == 0 then
        lines[#lines + 1] = "No spec aggregates yet."
    else
        for index = 1, math.min(12, #specBuckets) do
            local bucket = specBuckets[index]
            lines[#lines + 1] = string.format(
                "%d. %s  fights=%d  W-L=%d-%d  avg pressure=%.1f",
                index,
                bucket.label or bucket.key,
                bucket.fights or 0,
                bucket.wins or 0,
                bucket.losses or 0,
                (bucket.totalPressureScore or 0) / math.max(bucket.fights or 1, 1)
            )
        end
    end

    ns.Widgets.SetBodyText(self.content, self.text, table.concat(lines, "\n"))
end

ns.Addon:RegisterModule("ClassSpecView", ClassSpecView)
