local _, ns = ...

local Helpers = ns.Helpers
local Theme = ns.Widgets.THEME

local TradeLedgerView = {}

-- ---------------------------------------------------------------------------
-- Category color palette
-- ---------------------------------------------------------------------------
local CATEGORY_COLORS = {
    offensive    = Theme.accent,
    defensive    = Theme.success,
    trinket      = Theme.warning,
    cc_received  = { 0.96, 0.62, 0.30, 1.0 },
    kill_window  = { 0.90, 0.30, 0.25, 1.0 },
    death        = { 1.00, 0.15, 0.15, 1.0 },
}

local CATEGORY_LABELS = {
    offensive    = "Offensive",
    defensive    = "Defensive",
    trinket      = "Trinket",
    cc_received  = "CC Received",
    kill_window  = "Kill Window",
    death        = "Death",
}

-- Death recap confidence colors for the card border accent.
local RECAP_CONFIDENCE_COLORS = {
    full    = Theme.success,
    partial = Theme.warning,
    minimal = { 0.90, 0.30, 0.25, 1.0 },
}

-- Provenance source display labels.
local PROVENANCE_LABELS = {
    state           = "State",
    damage_meter    = "DamageMeter",
    visible_unit    = "Visible Unit",
    loss_of_control = "Loss of Control",
    estimated       = "Estimated",
    inspect         = "Inspect",
    legacy_import   = "Legacy",
}

-- Layout constants.
local ENTRY_HEIGHT = 28
local TIMESTAMP_WIDTH = 52
local CATEGORY_BAR_WIDTH = 4
local PANEL_WIDTH = 760
local MAX_POOL_SIZE = 60

-- ---------------------------------------------------------------------------
-- Entry frame pool — reuse hidden frames instead of creating/destroying.
-- ---------------------------------------------------------------------------
local function acquireEntry(pool, parent)
    for i = 1, #pool do
        local frame = pool[i]
        if not frame._inUse then
            frame._inUse = true
            frame:SetParent(parent)
            frame:ClearAllPoints()
            frame:Show()
            return frame
        end
    end

    -- Pool exhausted; create a new entry frame.
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(PANEL_WIDTH - 40, ENTRY_HEIGHT)
    ns.Widgets.ApplyBackdrop(frame, Theme.panelAlt, Theme.border)

    -- Category accent bar (left edge).
    frame.catBar = frame:CreateTexture(nil, "ARTWORK")
    frame.catBar:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.catBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.catBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    frame.catBar:SetWidth(CATEGORY_BAR_WIDTH)

    -- Timestamp label.
    frame.timestamp = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.timestamp:SetPoint("LEFT", frame, "LEFT", CATEGORY_BAR_WIDTH + 6, 0)
    frame.timestamp:SetWidth(TIMESTAMP_WIDTH)
    frame.timestamp:SetJustifyH("RIGHT")
    frame.timestamp:SetTextColor(unpack(Theme.textMuted))

    -- Spell name.
    frame.spellName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.spellName:SetPoint("LEFT", frame.timestamp, "RIGHT", 10, 0)
    frame.spellName:SetWidth(200)
    frame.spellName:SetJustifyH("LEFT")
    frame.spellName:SetTextColor(unpack(Theme.text))

    -- Target / source.
    frame.target = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.target:SetPoint("LEFT", frame.spellName, "RIGHT", 8, 0)
    frame.target:SetWidth(160)
    frame.target:SetJustifyH("LEFT")
    frame.target:SetTextColor(unpack(Theme.textMuted))

    -- Outcome pill (small inline badge).
    frame.outcomePill = ns.Widgets.CreatePill(frame, 68, 16, Theme.panelAlt, Theme.border)
    frame.outcomePill:SetPoint("RIGHT", frame, "RIGHT", -8, 0)

    frame._inUse = true
    pool[#pool + 1] = frame
    return frame
end

local function releaseAllEntries(pool)
    for i = 1, #pool do
        pool[i]._inUse = false
        pool[i]:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Provenance tag — tiny inline label showing data source.
-- ---------------------------------------------------------------------------
local function createProvenanceTag(parent, sourceKey)
    local label = PROVENANCE_LABELS[sourceKey] or sourceKey or "Unknown"
    local tag = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    tag:SetSize(#label * 5.6 + 12, 14)
    ns.Widgets.ApplyBackdrop(tag, { 0.12, 0.14, 0.18, 0.9 }, Theme.border)

    tag.text = tag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag.text:SetPoint("CENTER", tag, "CENTER", 0, 0)
    tag.text:SetText(label)
    tag.text:SetTextColor(unpack(Theme.textMuted))

    return tag
end

-- ---------------------------------------------------------------------------
-- Build — construct the panel hierarchy (called once).
-- ---------------------------------------------------------------------------
function TradeLedgerView:Build(parent)
    self.frame = CreateFrame("Frame", nil, parent)
    self.frame:SetSize(PANEL_WIDTH, 1) -- height is dynamic

    -- Section header: Trade Ledger
    self.title = ns.Widgets.CreateSectionTitle(
        self.frame, "Trade Ledger",
        "TOPLEFT", self.frame, "TOPLEFT", 0, 0
    )
    self.caption = ns.Widgets.CreateCaption(
        self.frame,
        "Significant cooldown trades in chronological order. Each row is a meaningful trade moment.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    -- Category legend strip.
    local legendEntries = {}
    local legendOrder = { "offensive", "defensive", "trinket", "cc_received", "kill_window", "death" }
    for _, cat in ipairs(legendOrder) do
        legendEntries[#legendEntries + 1] = {
            color = CATEGORY_COLORS[cat],
            label = CATEGORY_LABELS[cat],
        }
    end
    self.legend = ns.Widgets.CreateMiniLegend(self.frame, legendEntries, 10)
    self.legend:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)

    -- Scrollable canvas for entry rows.
    self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(
        self.frame, PANEL_WIDTH, 300
    )
    self.shell:SetPoint("TOPLEFT", self.legend, "BOTTOMLEFT", 0, -8)

    -- Empty state label.
    self.emptyLabel = self.canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.emptyLabel:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 8, -8)
    self.emptyLabel:SetTextColor(unpack(Theme.textMuted))
    self.emptyLabel:SetText("No trade ledger data for this session.")
    self.emptyLabel:Hide()

    -- Object pool for entry rows.
    self.entryPool = {}

    -- Death recap card container (created once, populated on Refresh).
    self.recapCard = nil

    return self.frame
end

-- ---------------------------------------------------------------------------
-- SetEntryData — populate a pooled entry frame with ledger data.
-- ---------------------------------------------------------------------------
local function setEntryData(entry, data)
    local catColor = CATEGORY_COLORS[data.category] or Theme.accent
    entry.catBar:SetVertexColor(catColor[1], catColor[2], catColor[3], catColor[4] or 1)

    entry.timestamp:SetText(string.format("%.1fs", data.timestamp or 0))

    local nameText = data.spellName or CATEGORY_LABELS[data.category] or data.category or "Unknown"
    if data.category == "kill_window" then
        nameText = "Kill Window"
        if data.amount and data.amount > 0 then
            nameText = nameText .. "  " .. Helpers.FormatNumber(data.amount)
        end
    elseif data.category == "death" then
        nameText = "DEATH"
    end
    entry.spellName:SetText(nameText)
    entry.spellName:SetTextColor(catColor[1], catColor[2], catColor[3], 1)

    -- Target or source context.
    local targetText = ""
    if data.targetName then
        targetText = "-> " .. data.targetName
    end
    if data.duration and data.duration > 0 then
        if targetText ~= "" then
            targetText = targetText .. "  "
        end
        targetText = targetText .. string.format("(%.1fs)", data.duration)
    end
    entry.target:SetText(targetText)

    -- Outcome pill: show source provenance or outcome.
    local outcomeLabel = data.source and PROVENANCE_LABELS[data.source] or nil
    if outcomeLabel then
        entry.outcomePill:SetData(outcomeLabel, Theme.textMuted)
        entry.outcomePill:Show()
    else
        entry.outcomePill:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- BuildRecapCard — create or refresh the death recap card below entries.
-- ---------------------------------------------------------------------------
function TradeLedgerView:BuildRecapCard(recap, anchorTo)
    if not recap then
        if self.recapCard then
            self.recapCard:Hide()
        end
        return nil
    end

    -- Create the card frame once; reuse on subsequent refreshes.
    if not self.recapCard then
        local card = CreateFrame("Frame", nil, self.canvas, "BackdropTemplate")
        card:SetSize(PANEL_WIDTH - 40, 1) -- height computed dynamically

        -- Red accent border.
        local deathRed = { 0.90, 0.20, 0.15, 1.0 }
        ns.Widgets.ApplyBackdrop(card, Theme.panel, deathRed)

        -- Header row.
        card.header = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        card.header:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
        card.header:SetText("Death Recap")
        card.header:SetTextColor(0.90, 0.20, 0.15, 1)

        -- Confidence pill (positioned to the right of header).
        card.confPillAnchor = CreateFrame("Frame", nil, card)
        card.confPillAnchor:SetSize(1, 1)
        card.confPillAnchor:SetPoint("LEFT", card.header, "RIGHT", 10, 0)

        -- Content area: flexible font strings created per-field.
        card.fields = {}
        card.provTags = {}

        self.recapCard = card
    end

    local card = self.recapCard

    -- Hide previous field/tag elements.
    for _, fs in ipairs(card.fields) do fs:Hide() end
    for _, tag in ipairs(card.provTags) do tag:Hide() end
    card.fields = {}
    card.provTags = {}

    -- Update confidence pill.
    if card.confPill then
        card.confPill:Hide()
    end
    local confKey = recap.confidence or "minimal"
    -- Map recap confidence to the SESSION_CONFIDENCE key for ConfidencePill.
    local confMap = {
        full    = "state_plus_damage_meter",
        partial = "partial_roster",
        minimal = "estimated",
    }
    card.confPill = ns.Widgets.CreateConfidencePill(card, confMap[confKey] or "estimated")
    card.confPill:SetPoint("LEFT", card.confPillAnchor, "LEFT", 0, 0)
    card.provTags[#card.provTags + 1] = card.confPill

    -- Update border color based on confidence.
    local borderColor = RECAP_CONFIDENCE_COLORS[confKey] or { 0.90, 0.20, 0.15, 1.0 }
    ns.Widgets.SetBackdropColors(card, Theme.panel, borderColor)

    local yPos = -36
    local fieldPad = 12
    local labelWidth = PANEL_WIDTH - 80

    -- Helper: add a labeled field row with optional provenance tag.
    local function addField(label, value, provenanceSource)
        if not value or value == "" then
            return
        end

        local labelFs = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        labelFs:SetPoint("TOPLEFT", card, "TOPLEFT", fieldPad, yPos)
        labelFs:SetWidth(90)
        labelFs:SetJustifyH("LEFT")
        labelFs:SetText(label)
        labelFs:SetTextColor(unpack(Theme.textMuted))
        card.fields[#card.fields + 1] = labelFs

        local valueFs = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        valueFs:SetPoint("TOPLEFT", labelFs, "TOPRIGHT", 4, 0)
        valueFs:SetWidth(labelWidth - 90)
        valueFs:SetJustifyH("LEFT")
        valueFs:SetWordWrap(true)
        valueFs:SetText(value)
        valueFs:SetTextColor(unpack(Theme.text))
        card.fields[#card.fields + 1] = valueFs

        if provenanceSource then
            local tag = createProvenanceTag(card, provenanceSource)
            tag:SetPoint("RIGHT", card, "RIGHT", -fieldPad, yPos - 6)
            card.provTags[#card.provTags + 1] = tag
        end

        local textHeight = math.max(valueFs:GetStringHeight() or 14, 14)
        yPos = yPos - (textHeight + 6)
    end

    -- Killing blow.
    if recap.killingBlow then
        local kb = recap.killingBlow
        local kbText = string.format(
            "%s from %s",
            kb.spellName or "Unknown",
            kb.sourceName or "Unknown"
        )
        if kb.amount and kb.amount > 0 then
            kbText = kbText .. "  (" .. Helpers.FormatNumber(kb.amount) .. ")"
        end
        addField("Killing Blow", kbText, recap.provenance and recap.provenance.killingBlow)
    else
        addField("Killing Blow", "Unknown — insufficient data", nil)
    end

    -- CC at death.
    if recap.ccAtDeath then
        local cc = recap.ccAtDeath
        local ccText = string.format(
            "%s for %.1fs",
            cc.family or "CC",
            cc.duration or 0
        )
        if cc.source then
            ccText = ccText .. "  from " .. tostring(cc.source)
        end
        addField("CC at Death", ccText, recap.provenance and recap.provenance.ccAtDeath)
    else
        addField("CC at Death", "None detected", nil)
    end

    -- Last defensive.
    if recap.lastDefensive then
        local def = recap.lastDefensive
        local defText = string.format(
            "%s at %.1fs",
            def.spellName or "Unknown",
            def.usedAt or 0
        )
        addField("Last Defensive", defText, recap.provenance and recap.provenance.lastDefensive)
    else
        addField("Last Defensive", "None used", nil)
    end

    -- Unused defensives.
    if recap.unusedDefensives and recap.unusedDefensives > 0 then
        addField(
            "Unused CDs",
            string.format("%d defensive(s) still available", recap.unusedDefensives),
            recap.provenance and recap.provenance.unusedDefensives
        )
    end

    -- Total damage in last window.
    if recap.totalDamageLastWindow and recap.totalDamageLastWindow > 0 then
        addField(
            "Last 5s Damage",
            Helpers.FormatNumber(recap.totalDamageLastWindow),
            recap.provenance and recap.provenance.totalDamageLastWindow
        )
    end

    -- Finalize card height.
    local cardHeight = math.abs(yPos) + 12
    card:SetHeight(cardHeight)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -12)
    card:Show()

    return card
end

-- ---------------------------------------------------------------------------
-- Refresh — populate the view from a session.
-- ---------------------------------------------------------------------------
function TradeLedgerView:Refresh(session)
    releaseAllEntries(self.entryPool)
    self.emptyLabel:Hide()

    if self.recapCard then
        self.recapCard:Hide()
    end

    if not session then
        self.emptyLabel:SetText("No combat session selected.")
        self.emptyLabel:Show()
        ns.Widgets.SetCanvasHeight(self.canvas, 40)
        return
    end

    local service = ns.Addon:GetModule("TradeLedgerService")
    if not service then
        self.emptyLabel:SetText("Trade ledger service unavailable.")
        self.emptyLabel:Show()
        ns.Widgets.SetCanvasHeight(self.canvas, 40)
        return
    end

    -- Build ledger entries.
    local entries = service:BuildTradeLedger(session)
    if not entries or #entries == 0 then
        self.emptyLabel:SetText("No significant trades recorded for this session.")
        self.emptyLabel:Show()
        ns.Widgets.SetCanvasHeight(self.canvas, 40)
        return
    end

    -- Render entry rows.
    local yOffset = 0
    local lastEntry = nil

    for i = 1, #entries do
        local entryFrame = acquireEntry(self.entryPool, self.canvas)
        entryFrame:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, -yOffset)
        setEntryData(entryFrame, entries[i])
        yOffset = yOffset + ENTRY_HEIGHT + 2
        lastEntry = entryFrame
    end

    -- Death recap card (if player died).
    local recap = service:BuildDeathRecap(session)
    local recapCard = self:BuildRecapCard(recap, lastEntry or self.canvas)

    -- Compute total canvas height.
    local totalHeight = yOffset
    if recapCard and recapCard:IsShown() then
        totalHeight = totalHeight + 12 + (recapCard:GetHeight() or 0)
    end
    totalHeight = totalHeight + 16 -- bottom padding

    ns.Widgets.SetCanvasHeight(self.canvas, totalHeight)
end

-- ---------------------------------------------------------------------------
-- Clear — hide everything and release pooled frames.
-- ---------------------------------------------------------------------------
function TradeLedgerView:Clear()
    releaseAllEntries(self.entryPool)
    self.emptyLabel:Show()
    self.emptyLabel:SetText("No combat session selected.")

    if self.recapCard then
        self.recapCard:Hide()
    end

    ns.Widgets.SetCanvasHeight(self.canvas, 40)
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------
ns.Addon:RegisterModule("TradeLedgerView", TradeLedgerView)
