local _, ns = ...

local OpponentStatsView = {
    viewId = "opponents",
}

function OpponentStatsView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetAllPoints()

    self.title = ns.Widgets.CreateSectionTitle(self.frame, "Opponent Analysis", "TOPLEFT", self.frame, "TOPLEFT", 16, -16)
    self.caption = ns.Widgets.CreateCaption(self.frame, "Aggregated opponent trends across all stored sessions.", "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)
    self.scrollFrame, self.content, self.text = ns.Widgets.CreateBodyText(self.frame, 808, 410)
    self.scrollFrame:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -12)
    self.scrollFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 16)
    return self.frame
end

function OpponentStatsView:Refresh()
    local buckets = ns.Addon:GetModule("CombatStore"):GetAggregateBuckets("opponents")
    if #buckets == 0 then
        ns.Widgets.SetBodyText(self.content, self.text, "No opponent aggregates yet.")
        return
    end

    local lines = {}
    for index = 1, math.min(25, #buckets) do
        local bucket = buckets[index]
        lines[#lines + 1] = string.format(
            "%d. %s  fights=%d  W-L=%d-%d  avg dmg=%s  avg taken=%s  avg pressure=%.1f",
            index,
            bucket.label or bucket.key,
            bucket.fights or 0,
            bucket.wins or 0,
            bucket.losses or 0,
            ns.Helpers.FormatNumber((bucket.totalDamageDone or 0) / math.max(bucket.fights or 1, 1)),
            ns.Helpers.FormatNumber((bucket.totalDamageTaken or 0) / math.max(bucket.fights or 1, 1)),
            (bucket.totalPressureScore or 0) / math.max(bucket.fights or 1, 1)
        )
    end

    ns.Widgets.SetBodyText(self.content, self.text, table.concat(lines, "\n"))
end

ns.Addon:RegisterModule("OpponentStatsView", OpponentStatsView)
