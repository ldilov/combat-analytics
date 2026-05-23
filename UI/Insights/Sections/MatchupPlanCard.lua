local _, ns = ...

-- UI/Insights/Sections/MatchupPlanCard.lua
--
-- "Matchup Plan" section of the new Insights tab. Folds the old Strategy
-- Spotlight + Matchup Memory cards into a single dense card driven by
-- ns.InsightsMatchupSummary (pure logic) + StrategyEngine.GetCounterGuide.
--
-- Anchors below the Fight Timeline Read section in the InsightsView scroll
-- canvas. Hidden when the onboarding visibility map says matchupPlan = false
-- (e.g., during the cold / sparse states).

local Theme    = ns.Widgets.THEME
local Summary  = ns.InsightsMatchupSummary

local CARD_WIDTH       = 760
local TITLE_HEIGHT     = 18
local CAPTION_HEIGHT   = 18
local CARD_PAD_TOP     = 12
local CARD_MIN_HEIGHT  = 140

local MatchupPlanCard = {}

local function joinList(list, separator)
    if type(list) ~= "table" or #list == 0 then return "" end
    return table.concat(list, separator or ", ")
end

local function spellLine(entry, index)
    if type(entry) ~= "table" then return string.format("%d. %s", index, tostring(entry)) end
    local label = entry.label or entry.name or (entry.spellId and ("spell " .. tostring(entry.spellId))) or "unknown"
    return string.format("%d. %s", index, label)
end

-- ---------------------------------------------------------------------------
-- Build (one-time)
-- ---------------------------------------------------------------------------
function MatchupPlanCard:Build(canvas, anchor, width)
    self.canvas = canvas
    self.width  = width or CARD_WIDTH

    self.title = ns.Widgets.CreateSectionTitle(
        canvas, "Matchup Plan",
        "TOPLEFT", anchor, "BOTTOMLEFT", 0, -18
    )
    self.caption = ns.Widgets.CreateCaption(
        canvas, "Strategy and history vs the primary opponent for this session.",
        "TOPLEFT", self.title, "BOTTOMLEFT", 0, -4
    )

    self.card = ns.Widgets.CreateSurface(canvas, self.width, CARD_MIN_HEIGHT, Theme.panelAlt, Theme.border)
    self.card:SetPoint("TOPLEFT", self.caption, "BOTTOMLEFT", 0, -8)

    -- Spec line (large header)
    self.card.specLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.card.specLabel:SetPoint("TOPLEFT", self.card, "TOPLEFT", 12, -12)
    self.card.specLabel:SetTextColor(unpack(Theme.text))

    self.card.winRate = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.card.winRate:SetPoint("TOPRIGHT", self.card, "TOPRIGHT", -12, -14)
    self.card.winRate:SetTextColor(unpack(Theme.text))
    self.card.winRate:SetJustifyH("RIGHT")

    -- Sub line (archetype, range, threat)
    self.card.subLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.card.subLabel:SetPoint("TOPLEFT", self.card.specLabel, "BOTTOMLEFT", 0, -4)
    self.card.subLabel:SetTextColor(unpack(Theme.textMuted))

    -- Threats / CC chip line
    self.card.threatLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.card.threatLabel:SetPoint("TOPLEFT", self.card.subLabel, "BOTTOMLEFT", 0, -6)
    self.card.threatLabel:SetPoint("RIGHT", self.card, "RIGHT", -12, 0)
    self.card.threatLabel:SetJustifyH("LEFT")
    self.card.threatLabel:SetTextColor(unpack(Theme.text))

    self.card.ccLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.card.ccLabel:SetPoint("TOPLEFT", self.card.threatLabel, "BOTTOMLEFT", 0, -4)
    self.card.ccLabel:SetPoint("RIGHT", self.card, "RIGHT", -12, 0)
    self.card.ccLabel:SetJustifyH("LEFT")
    self.card.ccLabel:SetTextColor(unpack(Theme.text))

    -- Recommended actions (multi-line)
    self.card.actions = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.card.actions:SetPoint("TOPLEFT", self.card.ccLabel, "BOTTOMLEFT", 0, -10)
    self.card.actions:SetPoint("RIGHT", self.card, "RIGHT", -12, 0)
    self.card.actions:SetJustifyH("LEFT")
    self.card.actions:SetJustifyV("TOP")
    self.card.actions:SetTextColor(unpack(Theme.text))
    self.card.actions:SetSpacing(2)

    -- Top opponent spells (muted)
    self.card.topSpells = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.card.topSpells:SetPoint("TOPLEFT", self.card.actions, "BOTTOMLEFT", 0, -8)
    self.card.topSpells:SetPoint("RIGHT", self.card, "RIGHT", -12, 0)
    self.card.topSpells:SetJustifyH("LEFT")
    self.card.topSpells:SetJustifyV("TOP")
    self.card.topSpells:SetTextColor(unpack(Theme.textMuted))
    self.card.topSpells:SetSpacing(2)

    -- Empty-state overlay
    self.emptyLabel = self.card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.emptyLabel:SetPoint("CENTER", self.card, "CENTER", 0, 0)
    self.emptyLabel:SetTextColor(unpack(Theme.textMuted))
    self.emptyLabel:Hide()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function MatchupPlanCard:Refresh(session, visible)
    if not self.card then return 0 end
    if visible == false then
        self.title:Hide(); self.caption:Hide(); self.card:Hide()
        return 0
    end

    -- Resolve the strategy guide lazily; allow tests to inject one via session.
    local guide = nil
    local specId = session and session.primaryOpponent and tonumber(session.primaryOpponent.specId)
    if specId then
        local strategyEngine = ns.Addon and ns.Addon.GetModule and ns.Addon:GetModule("StrategyEngine", true) or nil
        local buildHash      = session.playerSnapshot and session.playerSnapshot.buildHash or nil
        local characterKey   = session.characterKey or session.character or nil
        if strategyEngine and strategyEngine.GetCounterGuide then
            local ok, result = pcall(strategyEngine.GetCounterGuide, specId, buildHash, characterKey)
            if ok then guide = result end
        end
    end

    local summary = Summary.Build(session, guide)

    self.title:Show(); self.caption:Show(); self.card:Show()

    if not Summary.HasMeaningfulData(summary) then
        self.card.specLabel:SetText(summary.specLabel or "Matchup Plan")
        self.card.winRate:SetText("")
        self.card.subLabel:SetText("")
        self.card.threatLabel:SetText("")
        self.card.ccLabel:SetText("")
        self.card.actions:SetText("")
        self.card.topSpells:SetText("")
        self.emptyLabel:SetText(
            specId and "Not enough fights yet vs this spec — coaching unlocks after a few sessions."
                   or  "No opponent spec attached to this session."
        )
        self.emptyLabel:Show()
        self.card:SetHeight(CARD_MIN_HEIGHT)
        return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + CARD_MIN_HEIGHT
    end

    self.emptyLabel:Hide()

    self.card.specLabel:SetText(string.format("vs %s  (%s)", summary.specLabel, summary.archetypeLabel))
    self.card.winRate:SetText(summary.winRateText or "")

    local subPieces = {}
    if summary.rangeBucket and summary.rangeBucket ~= "unknown" then
        subPieces[#subPieces + 1] = "range: " .. summary.rangeBucket
    end
    if summary.threatScore then
        subPieces[#subPieces + 1] = string.format("threat %d", summary.threatScore)
    end
    self.card.subLabel:SetText(joinList(subPieces, "  |  "))

    if #summary.threatTags > 0 then
        self.card.threatLabel:SetText("Threats: " .. joinList(summary.threatTags))
    else
        self.card.threatLabel:SetText("")
    end

    if #summary.ccFamilies > 0 then
        self.card.ccLabel:SetText("CC: " .. joinList(summary.ccFamilies))
    else
        self.card.ccLabel:SetText("")
    end

    local actionLines = {}
    for _, a in ipairs(summary.recommendedActions) do
        actionLines[#actionLines + 1] = "- " .. tostring(a)
    end
    self.card.actions:SetText(table.concat(actionLines, "\n"))

    if #summary.topSpells > 0 then
        local lines = { "Watch for:" }
        for i, sp in ipairs(summary.topSpells) do
            lines[#lines + 1] = spellLine(sp, i)
        end
        self.card.topSpells:SetText(table.concat(lines, "\n"))
    else
        self.card.topSpells:SetText("")
    end

    -- Resize the card based on visible content roughly. Each line ≈ 14px.
    local lineCount = 4 + #actionLines + (#summary.topSpells > 0 and (#summary.topSpells + 1) or 0)
    local desired = math.max(CARD_MIN_HEIGHT, CARD_PAD_TOP + 18 + lineCount * 14 + 12)
    self.card:SetHeight(desired)

    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + desired
end

function MatchupPlanCard:_Height()
    if not self.card or not self.card:IsShown() then return 0 end
    return TITLE_HEIGHT + 4 + CAPTION_HEIGHT + 8 + (self.card:GetHeight() or CARD_MIN_HEIGHT)
end

ns.InsightsMatchupPlanCard = MatchupPlanCard
return MatchupPlanCard
