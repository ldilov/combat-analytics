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
    local store = ns.Addon:GetModule("CombatStore")
    local characterRef = store:GetCurrentCharacterRef()
    local buckets = store:GetAggregateBuckets("opponents", characterRef)
    local latestSession = store:GetLatestSession(characterRef)
    local usingFallback = false
    if #buckets == 0 then
        buckets = store:GetAggregateBuckets("opponents")
        latestSession = latestSession or store:GetLatestSession()
        usingFallback = #buckets > 0
    end
    if latestSession then
        self.caption:SetText(string.format("Aggregated opponent trends for %s%s.", store:GetSessionCharacterLabel(latestSession), usingFallback and " (fallback to all stored sessions)" or ""))
    else
        self.caption:SetText("Aggregated opponent trends for the current character.")
    end
    if #buckets == 0 then
        ns.Widgets.SetBodyText(self.content, self.text, "No opponent aggregates yet.")
        return
    end

    local latestBuildHash = latestSession and latestSession.playerSnapshot and latestSession.playerSnapshot.buildHash or nil
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

        if latestBuildHash then
            local duelPractice = store:GetDuelPracticeSummary(latestBuildHash, bucket.key, usingFallback and nil or characterRef)
            if duelPractice and duelPractice.fights >= 3 then
                lines[#lines + 1] = string.format(
                    "   latest-build duel lens: fights=%d  opener=%s  avg dur=%s  first go=%s",
                    duelPractice.fights or 0,
                    ns.Helpers.FormatNumber(duelPractice.averageOpenerDamage or 0),
                    ns.Helpers.FormatDuration(duelPractice.averageDuration or 0),
                    duelPractice.averageFirstMajorOffensiveAt and string.format("%.1fs", duelPractice.averageFirstMajorOffensiveAt) or "--"
                )
            end
        end
    end

    -- Arena roster section: show identified enemy slots from the latest arena session.
    -- Slots are populated by ArenaRoundTracker and exported into session.arena.slots.
    if latestSession and latestSession.context == "arena" then
        local arenaData = type(latestSession.arena) == "table" and latestSession.arena or nil
        local slots = arenaData and arenaData.slots or nil
        local slotCount = 0
        if slots then
            for _ in pairs(slots) do slotCount = slotCount + 1 end
        end
        if slotCount > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = string.format("── Arena Roster (last session %s) ──",
                date("%Y-%m-%d %H:%M", latestSession.timestamp or 0))
            for slot = 1, 5 do
                local s = slots[slot]
                if s then
                    local name = s.name or s.guid or "Unknown"
                    local classSpec = s.classFile and s.specName
                        and string.format("%s / %s", s.specName, s.classFile)
                        or (s.classFile or s.specName or "?")
                    local pressure = s.pressureScore and string.format("  pressure=%.1f", s.pressureScore) or ""
                    lines[#lines + 1] = string.format("  Slot %d: %s  [%s]%s",
                        slot, name, classSpec, pressure)
                end
            end
            -- Report unresolved GUIDs (seen in combat but not linked to a slot).
            local unresolved = arenaData.unresolvedGuids or {}
            local unresolvedCount = 0
            for _ in pairs(unresolved) do unresolvedCount = unresolvedCount + 1 end
            if unresolvedCount > 0 then
                lines[#lines + 1] = string.format("  Unresolved GUIDs: %d (seen but not identified)", unresolvedCount)
            end
        end
    end

    ns.Widgets.SetBodyText(self.content, self.text, table.concat(lines, "\n"))
end

ns.Addon:RegisterModule("OpponentStatsView", OpponentStatsView)
