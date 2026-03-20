local _, ns = ...

local MinimapButton = {
    radius = 80,
}

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Note_05"

local function updatePosition(button)
    local angle = ns.Addon:GetSetting("minimapAngle") or 225
    local radians = math.rad(angle)
    local x = math.cos(radians) * MinimapButton.radius
    local y = math.sin(radians) * MinimapButton.radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function MinimapButton:Initialize()
    if self.initialized then
        self:RefreshVisibility()
        return
    end
    self.initialized = true
    self:RefreshVisibility()
end

function MinimapButton:EnsureButton()
    if self.button then
        return self.button
    end

    local button = CreateFrame("Button", nil, Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")

    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button.border:SetSize(54, 54)
    button.border:SetPoint("TOPLEFT")

    button.background = button:CreateTexture(nil, "BACKGROUND")
    button.background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    button.background:SetSize(20, 20)
    button.background:SetPoint("CENTER", button, "CENTER", 0, 0)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(ICON_TEXTURE)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("CENTER", button, "CENTER", 0, 0)

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button.highlight:SetBlendMode("ADD")
    button.highlight:SetAllPoints(button)

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.Addon:Print("Use |cff35c7e5/ca minimap|r to hide or show the minimap button.")
            return
        end
        ns.Addon:OpenView("summary")
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("CombatAnalytics", 0.90, 0.94, 0.98)
        GameTooltip:AddLine("Left-click: Open addon UI", 0.60, 0.69, 0.78)
        GameTooltip:AddLine("Right-click: Command hint", 0.60, 0.69, 0.78)

        local store = ns.Addon:GetModule("CombatStore")
        if store then
            local characterKey = store:GetCurrentCharacterKey()
            local session = store:GetLatestSession(characterKey)
            if session and session.timestamp and (GetTime() - (session.timestamp or 0) < 1800) then
                local result = session.result and string.lower(tostring(session.result)) or "unknown"
                local opponentName = session.primaryOpponent and session.primaryOpponent.name or "Unknown"
                local duration = ns.Helpers.FormatDuration(session.duration or 0)
                local damage = ns.Helpers.FormatNumber(session.totals and session.totals.damageDone or 0)
                local r, g, b = 0.60, 0.69, 0.78
                if result == "won" then
                    r, g, b = 0.44, 0.82, 0.60
                elseif result == "lost" then
                    r, g, b = 0.90, 0.30, 0.25
                end
                local resultLabel = result == "won" and "Won" or result == "lost" and "Lost" or "Draw"
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(
                    string.format("Last: %s vs %s — %s — %s dmg", resultLabel, opponentName, duration, damage),
                    r, g, b
                )
            end
        end

        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:SetScript("OnDragStart", function(self)
        self.dragging = true
    end)

    button:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)

    button:SetScript("OnUpdate", function(self)
        if not self.dragging then
            return
        end

        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetScale()
        cx = cx / scale
        cy = cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        ns.Addon:SetSetting("minimapAngle", angle)
        updatePosition(self)
    end)

    self.button = button
    updatePosition(button)
    return button
end

function MinimapButton:RefreshVisibility()
    if ns.Addon:GetSetting("showMinimapButton") then
        local button = self:EnsureButton()
        if not button then
            return
        end
        self.button:Show()
        updatePosition(self.button)
    elseif self.button then
        self.button:Hide()
    end
end

ns.Addon:RegisterModule("MinimapButton", MinimapButton)
