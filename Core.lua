local ADDON_NAME, ns = ...

local Constants = ns.Constants

local Addon = {
    name = ADDON_NAME,
    version = "0.1.0",
    modules = {},
    coreInitialized = false,
    runtimeInitialized = false,
    initialized = false,
    runtime = {
        currentSession = nil,
        currentMatch = nil,
        pendingDuel = nil,
        reviewedSessionId = nil,
        latestSummarySessionId = nil,
        summaryOpenAt = nil,
        latestPlayerSnapshot = nil,
        totalRawEvents = 0,
        warnings = {},
        traceLog = {},
    },
}

ns.Addon = Addon

local PREFIX = "|cff35c7e5[CombatAnalytics]|r"
local WARNING_LOG_LIMIT = 100

local function chat(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function appendBounded(list, value, limit)
    list[#list + 1] = value
    while #list > limit do
        table.remove(list, 1)
    end
end

local function safeModuleCall(addon, moduleName, methodName)
    local module = addon:GetModule(moduleName)
    if not module or type(module[methodName]) ~= "function" then
        return true
    end

    local ok, err = xpcall(function()
        module[methodName](module)
    end, debugstack)
    if not ok then
        addon:Warn(string.format("%s initialization failed.", moduleName))
        addon:Debug("%s", err)
        return false
    end
    return true
end

local function registerSlashCommands(addon)
    if addon.slashRegistered then
        return true
    end

    if type(SlashCmdList) ~= "table" then
        addon:Warn("Slash command registration deferred because SlashCmdList is unavailable.")
        return false
    end

    SlashCmdList.COMBATANALYTICS = function(msg)
        addon:HandleCommand(msg)
    end
    _G.SLASH_COMBATANALYTICS1 = "/ca"
    _G.SLASH_COMBATANALYTICS2 = "/caa"
    _G.SLASH_COMBATANALYTICS3 = "/combatanalytics"
    addon.slashRegistered = true
    return true
end

local function stringifyTraceValue(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "number" then
        return string.format("%.3f", value)
    end
    return tostring(value)
end

local function formatTraceFields(fields)
    if fields == nil then
        return ""
    end
    if type(fields) ~= "table" then
        return tostring(fields)
    end

    local parts = {}
    for _, key in ipairs(ns.Helpers.ArrayKeys(fields)) do
        local value = fields[key]
        if type(value) ~= "table" then
            parts[#parts + 1] = string.format("%s=%s", tostring(key), stringifyTraceValue(value))
        end
    end
    return table.concat(parts, " ")
end

function Addon:RegisterModule(name, module)
    self.modules[name] = module
    module.name = name
    module.addon = self
    return module
end

function Addon:GetModule(name)
    return self.modules[name]
end

function Addon:GetDB()
    return CombatAnalyticsDB
end

function Addon:GetSetting(key)
    local db = self:GetDB()
    local settings = db and db.settings or nil
    if settings and settings[key] ~= nil then
        return settings[key]
    end
    return Constants.DEFAULT_SETTINGS[key]
end

function Addon:SetSetting(key, value)
    local db = self:GetDB()
    if not db then
        return
    end
    db.settings[key] = value
end

function Addon:IsDebugEnabled()
    return self:GetSetting("enableDebugLogging")
end

function Addon:IsTraceEnabled()
    return self:GetSetting("enableTraceLogging")
end

function Addon:Print(message)
    chat(string.format("%s %s", PREFIX, message))
end

function Addon:PrintSuccess(message)
    chat(string.format("%s |cff73d98b%s|r", PREFIX, message))
end

function Addon:PrintWarning(message)
    chat(string.format("%s |cffffb347%s|r", PREFIX, message))
end

function Addon:AppendTraceEntry(label, fields)
    local log = self:GetTraceLog()
    log[#log + 1] = {
        timestamp = ns.ApiCompat.GetServerTime(),
        relative = ns.Helpers.Now(),
        label = tostring(label or "trace"),
        detail = formatTraceFields(fields),
    }

    local limit = Constants.TRACE_LOG_LIMIT or 200
    while #log > limit do
        table.remove(log, 1)
    end
end

function Addon:RecordWarning(message)
    local entry = {
        timestamp = ns.ApiCompat.GetServerTime(),
        message = tostring(message or "unknown"),
    }

    appendBounded(self.runtime.warnings, entry, WARNING_LOG_LIMIT)

    local db = self:GetDB()
    local maintenance = db and db.maintenance or nil
    if maintenance then
        maintenance.warnings = maintenance.warnings or {}
        appendBounded(maintenance.warnings, entry, WARNING_LOG_LIMIT)
    end
end

function Addon:Debug(message, ...)
    if not self:IsDebugEnabled() then
        return
    end

    local formatted = message
    if select("#", ...) > 0 then
        formatted = string.format(message, ...)
    end
    self:AppendTraceEntry("debug", { message = formatted })
end

function Addon:Warn(message)
    self:RecordWarning(message)
    self:AppendTraceEntry("warn", { message = message })
end

function Addon:GetTraceLog()
    local db = self:GetDB()
    local maintenance = db and db.maintenance or nil
    if maintenance then
        maintenance.traceLog = maintenance.traceLog or {}
        return maintenance.traceLog
    end

    self.runtime.traceLog = self.runtime.traceLog or {}
    return self.runtime.traceLog
end

function Addon:Trace(label, fields)
    if not self:IsTraceEnabled() then
        return
    end
    self:AppendTraceEntry(label, fields)
end

function Addon:ClearTraceLog()
    local log = self:GetTraceLog()
    for index = #log, 1, -1 do
        log[index] = nil
    end
end

function Addon:DumpTraceLog(limit)
    local log = self:GetTraceLog()
    if #log == 0 then
        self:Print("Trace log is empty.")
        return
    end

    limit = math.floor(tonumber(limit) or 20)
    if limit < 1 then
        limit = 1
    elseif limit > (Constants.TRACE_LOG_LIMIT or 200) then
        limit = Constants.TRACE_LOG_LIMIT or 200
    end

    local startIndex = math.max(1, #log - limit + 1)
    self:Print(string.format("Trace dump (%d of %d entries):", #log - startIndex + 1, #log))
    for index = startIndex, #log do
        local entry = log[index]
        local timeText = date("%H:%M:%S", entry.timestamp or time())
        local detail = entry.detail ~= "" and (" " .. entry.detail) or ""
        self:Print(string.format("%s rel=%.3f %s%s", timeText, entry.relative or 0, entry.label or "trace", detail))
    end
end

function Addon:SetLatestPlayerSnapshot(snapshot)
    self.runtime.latestPlayerSnapshot = snapshot
end

function Addon:GetLatestPlayerSnapshot()
    return self.runtime.latestPlayerSnapshot
end

function Addon:SetReviewedSession(sessionId, source)
    self.runtime.reviewedSessionId = sessionId
    self:Trace("ui.reviewed_session.set", {
        sessionId = sessionId or "nil",
        source = source or "unknown",
    })
end

function Addon:GetReviewedSession()
    return self.runtime.reviewedSessionId
end

function Addon:ClearReviewedSession()
    self.runtime.reviewedSessionId = nil
    self:Trace("ui.reviewed_session.cleared")
end

function Addon:TryRegisterSlashCommands()
    return registerSlashCommands(self)
end

function Addon:PrintCommandHelp()
    self:Print("|cff73d98bReady|r  |cff35c7e5/ca|r opens the dashboard, |cff35c7e5/ca history|r shows sessions, |cff35c7e5/ca insights|r shows coaching.")
    self:Print("|cffd7e9ffUtilities|r  |cff35c7e5/ca detail|r, |cff35c7e5/ca cleanup|r, |cff35c7e5/ca settings|r, |cff35c7e5/ca trace|r.")
    self:Print("|cffd7e9ffDebug|r  |cff35c7e5/ca debug actors|r — actor registry, |cff35c7e5/ca debug timeline|r — lane/chronology/confidence counts, |cff35c7e5/ca debug coverage|r — lane coverage.")
end

function Addon:OpenView(viewId, payload)
    if not self.runtimeInitialized then
        self:InitializeRuntime()
    end

    if InCombatLockdown and InCombatLockdown() then
        self:PrintWarning("CombatAnalytics UI cannot open during combat. Use /ca after combat ends.")
        return
    end

    local mainFrame = self:GetModule("MainFrame")
    if mainFrame then
        local ok, err = xpcall(function()
            mainFrame:ShowView(viewId, payload)
        end, debugstack)
        if not ok then
            self:Warn("CombatAnalytics UI failed to open.")
            self:PrintWarning("CombatAnalytics UI failed to open.")
            self:Debug("%s", err)
        end
    end
end

function Addon:ShowSummary(sessionId)
    self.runtime.latestSummarySessionId = sessionId
    self.runtime.summaryOpenAt = ns.Helpers.Now() + Constants.SUMMARY_AUTO_OPEN_DELAY
end

function Addon:HandleCommand(input)
    local tracker = self:GetModule("CombatTracker")
    if tracker and tracker.FlushSessionForInspection then
        tracker:FlushSessionForInspection()
    end

    local rawInput = ns.Helpers.Trim(input or "")
    if rawInput == "" then
        self:OpenView("summary")
        return
    end

    local command, argument = string.match(rawInput, "^(%S+)%s*(.-)$")
    command = string.lower(command or "")
    argument = string.lower(ns.Helpers.Trim(argument or ""))

    if command == "summary" then
        self:OpenView("summary")
        return
    end

    if command == "history" then
        self:OpenView("history")
        return
    end

    if command == "options" or command == "settings" then
        local settingsPanel = self:GetModule("SettingsPanel")
        if settingsPanel and settingsPanel.Open then
            settingsPanel:Open()
        else
            self:PrintWarning("CombatAnalytics settings panel is not available.")
        end
        return
    end

    if command == "insights" then
        self:OpenView("insights")
        return
    end

    if command == "cleanup" then
        self:OpenView("cleanup")
        return
    end

    if command == "trace" or command == "traces" then
        if argument == "on" then
            self:SetSetting("enableTraceLogging", true)
            self:PrintSuccess("Trace logging enabled.")
            return
        end
        if argument == "off" then
            self:SetSetting("enableTraceLogging", false)
            self:PrintSuccess("Trace logging disabled.")
            return
        end
        if argument == "clear" then
            self:ClearTraceLog()
            self:PrintSuccess("Trace log cleared.")
            return
        end

        self:DumpTraceLog(argument ~= "" and argument or nil)
        return
    end

    if command == "debug" then
        -- T122: Diagnostic export subcommand
        if argument == "export" then
            local store = self:GetModule("CombatStore")
            local session = nil
            if self.runtime.reviewedSessionId and store then
                session = store:GetSessionById(self.runtime.reviewedSessionId)
            end
            if not session and store then
                session = store:GetLatestSession(store:GetCurrentCharacterKey())
            end
            if not session then
                self:PrintWarning("No session available for diagnostic export.")
                return
            end
            self:Print("|cff35c7e5--- Diagnostic Export ---|r")
            self:Print(string.format("  id: %s", session.id or "?"))
            self:Print(string.format("  context: %s | subcontext: %s", session.context or "?", session.subcontext or "?"))
            self:Print(string.format("  result: %s | duration: %.1fs", session.result or "?", session.duration or 0))
            self:Print(string.format("  confidence: %s", session.captureQuality and session.captureQuality.confidence or "?"))
            -- Match/round identity
            local arena = session.arena or {}
            self:Print(string.format("  matchKey: %s | roundKey: %s", arena.matchKey or "none", arena.roundKey or "none"))
            -- Slot confidence
            local roster = arena.roster or {}
            for i, slot in ipairs(roster) do
                local fc = slot.fieldConfidence or {}
                local parts = {}
                for k, v in pairs(fc) do parts[#parts + 1] = k .. "=" .. tostring(v) end
                self:Print(string.format("  slot[%d]: %s (%s) conf={%s}", i, slot.name or "?", slot.specName or "?", table.concat(parts, ",")))
            end
            -- DM session IDs
            local dm = session.damageMeterImport or {}
            self:Print(string.format("  dmSessionIds: %d", #(dm.sessionIds or {})))
            -- Timeline event counts by lane
            local laneCounts = {}
            for _, evt in ipairs(session.timelineEvents or {}) do
                local lane = evt.lane or "unknown"
                laneCounts[lane] = (laneCounts[lane] or 0) + 1
            end
            local laneStr = {}
            for lane, count in pairs(laneCounts) do
                laneStr[#laneStr + 1] = string.format("%s=%d", lane, count)
            end
            self:Print(string.format("  timelineEvents: %d total {%s}", #(session.timelineEvents or {}), table.concat(laneStr, ", ")))
            -- Provenance map
            local prov = session.provenance or {}
            local provParts = {}
            for field, source in pairs(prov) do
                provParts[#provParts + 1] = string.format("%s:%s", field, type(source) == "table" and source.source or tostring(source))
            end
            self:Print(string.format("  provenance: {%s}", table.concat(provParts, ", ")))
            -- T028: Build catalog summary
            local catalogSvc = self:GetModule("BuildCatalogService")
            local liveBuild  = catalogSvc and catalogSvc:GetCurrentLiveBuild()
            if liveBuild then
                self:Print(string.format("  currentBuildId: %s", liveBuild.buildId or "?"))
                self:Print(string.format("  loadoutId: %s", liveBuild.loadoutId or "?"))
                self:Print(string.format("  snapshotFreshness: %s", liveBuild.snapshotFreshness or "?"))
            else
                self:Print("  currentBuildId: (no live build)")
            end
            local store = self:GetModule("CombatStore")
            if store then
                local db2 = store:GetDB()
                local catalog = db2 and db2.buildCatalog
                if catalog then
                    local profileCount = catalog.order and #catalog.order or 0
                    self:Print(string.format("  buildCatalog: %d profile%s",
                        profileCount, profileCount == 1 and "" or "s"))
                    for i, bid in ipairs(catalog.order or {}) do
                        if i > 5 then
                            self:Print(string.format("    … (%d more)", profileCount - 5))
                            break
                        end
                        local p = catalog.byId[bid]
                        if p then
                            self:Print(string.format(
                                "    [%s] sessions=%d current=%s warnings=%s",
                                string.sub(bid, 1, 12) .. "…",
                                p.sessionCount or 0,
                                p.isCurrentBuild and "yes" or "no",
                                p.isMigratedWithWarnings and "yes" or "no"))
                        end
                    end
                end
            end

            -- Also save to export key
            local db = self:GetDB()
            if db then
                db.diagnosticExport = {
                    sessionId = session.id,
                    exportedAt = os.time(),
                    context = session.context,
                    confidence = session.captureQuality and session.captureQuality.confidence,
                    timelineEventCount = #(session.timelineEvents or {}),
                    laneCounts = laneCounts,
                    currentBuildId = liveBuild and liveBuild.buildId or nil,
                    snapshotFreshness = liveBuild and liveBuild.snapshotFreshness or nil,
                }
            end
            self:Print("|cff35c7e5--- End Diagnostic Export ---|r")
            return
        end

        -- T027: /ca debug coverage — per-lane coverage scores for most recent session.
        if argument == "coverage" then
            local store = self:GetModule("CombatStore")
            local session = nil
            if self.runtime.reviewedSessionId and store then
                session = store:GetSessionById(self.runtime.reviewedSessionId)
            end
            if not session and store then
                session = store:GetLatestSession(store:GetCurrentCharacterKey())
            end
            if not session then
                self:PrintWarning("No session available.")
                return
            end
            local cov = session.coverage
            if not cov then
                self:PrintWarning("No coverage data in this session (session may predate CoverageService).")
                return
            end
            self:Print("|cff35c7e5--- Coverage Report ---|r")
            self:Print(string.format("  Session: %s | %s/%s", session.id or "?", session.context or "?", session.subcontext or "?"))
            -- Sorted lane list for stable output.
            local lanes = {}
            for lane in pairs(cov) do lanes[#lanes + 1] = lane end
            table.sort(lanes)
            for _, lane in ipairs(lanes) do
                local rec = cov[lane]
                if type(rec) == "table" then
                    local score    = rec.score      or 0
                    local evCount  = rec.eventCount  or 0
                    local dropped  = rec.droppedCount or 0
                    local summary  = rec.summary     or ""
                    local bar = string.rep("|cff00cc44#|r", math.floor(score * 10)) ..
                                string.rep("|cff666666-|r", 10 - math.floor(score * 10))
                    self:Print(string.format("  %-20s [%s] %.2f  ev=%d drop=%d%s",
                        lane, bar, score, evCount, dropped,
                        summary ~= "" and ("  " .. summary) or ""))
                end
            end
            self:Print("|cff35c7e5--- End Coverage Report ---|r")
            return
        end

        -- /ca debug actors — dump UnitGraphService actor registry
        if argument == "actors" then
            local ugs = self:GetModule("UnitGraphService")
            if not ugs or not ugs.DumpState then
                self:PrintWarning("UnitGraphService.DumpState not available.")
                return
            end
            local lines = ugs:DumpState()
            if type(lines) == "table" then
                for _, line in ipairs(lines) do
                    self:Print(line)
                end
            else
                self:Print(tostring(lines))
            end
            return
        end

        -- /ca debug timeline — count timeline events by lane → chronology → confidence
        if argument == "timeline" then
            local store = self:GetModule("CombatStore")
            local session = nil
            if self.runtime.reviewedSessionId and store then
                session = store:GetSessionById(self.runtime.reviewedSessionId)
            end
            if not session and store then
                session = store:GetLatestSession(store:GetCurrentCharacterKey())
            end
            if not session then
                self:PrintWarning("No session available.")
                return
            end
            local byLane = {}
            for _, evt in ipairs(session.timelineEvents or {}) do
                local lane  = evt.lane       or "unknown"
                local chron = evt.chronology or "realtime"
                local conf  = evt.confidence or "unknown"
                if not byLane[lane]        then byLane[lane]        = {} end
                if not byLane[lane][chron] then byLane[lane][chron] = {} end
                byLane[lane][chron][conf] = (byLane[lane][chron][conf] or 0) + 1
            end
            self:Print("|cff35c7e5--- Timeline Summary ---|r")
            self:Print(string.format("  Session: %s | total events: %d",
                session.id or "?", #(session.timelineEvents or {})))
            local laneOrder = {}
            for lane in pairs(byLane) do laneOrder[#laneOrder + 1] = lane end
            table.sort(laneOrder)
            for _, lane in ipairs(laneOrder) do
                local chronMap   = byLane[lane]
                local chronOrder = {}
                for chron in pairs(chronMap) do chronOrder[#chronOrder + 1] = chron end
                table.sort(chronOrder)
                for _, chron in ipairs(chronOrder) do
                    local confMap   = chronMap[chron]
                    local confOrder = {}
                    for conf in pairs(confMap) do confOrder[#confOrder + 1] = conf end
                    table.sort(confOrder)
                    local parts = {}
                    for _, conf in ipairs(confOrder) do
                        parts[#parts + 1] = string.format("%s=%d", conf, confMap[conf])
                    end
                    self:Print(string.format("  %-22s [%-10s] {%s}",
                        lane, chron, table.concat(parts, ", ")))
                end
            end
            self:Print("|cff35c7e5--- End Timeline Summary ---|r")
            return
        end

        local enabled = not self:IsDebugEnabled()
        self:SetSetting("enableDebugLogging", enabled)
        self:PrintSuccess(string.format("Debug %s.", enabled and "enabled" or "disabled"))
        return
    end

    if command == "export" then
        local store = self:GetModule("CombatStore")
        local serializer = self:GetModule("ExportSerializer")
        if not store or not serializer then
            self:PrintWarning("Export module not available.")
            return
        end
        local sessionId = self.runtime.reviewedSessionId
        local session = nil
        if sessionId then
            session = store:GetSessionById(sessionId)
        end
        if not session then
            local characterKey = store:GetCurrentCharacterKey()
            session = store:GetLatestSession(characterKey)
        end
        if not session then
            self:PrintWarning("No session to export.")
            return
        end
        local text = serializer.Serialize(session)
        self:ShowExportFrame(text)
        return
    end

    if command == "stats" then
        local store = self:GetModule("CombatStore")
        local dbStats = store and store:GetStorageStats() or {}
        local active = tracker and tracker:GetCurrentSession() or nil
        self:Print(string.format(
            "Stats: stored_sessions=%d stored_matches=%d raw_events=%d active_session=%s active_context=%s",
            dbStats.sessions or 0,
            dbStats.matches or 0,
            dbStats.totalRawEvents or 0,
            active and active.id or "none",
            active and active.context or "none"
        ))
        return
    end

    if command == "minimap" then
        local current = self:GetSetting("showMinimapButton")
        local next = not current
        self:SetSetting("showMinimapButton", next)
        local minimapButton = self:GetModule("MinimapButton")
        if minimapButton then
            minimapButton:RefreshVisibility()
        end
        if next then
            self:Print("Minimap button |cff70d196shown|r. Drag to reposition.")
        else
            self:Print("Minimap button |cffe64d40hidden|r. Use |cff35c7e5/ca minimap|r to show it again.")
        end
        return
    end

    -- T123: Manual regression matrix checklist
    if command == "regression" then
        self:Print("|cff35c7e5--- Regression Matrix ---|r")
        self:Print("|cffFFD700Arena:|r")
        self:Print("  [ ] 2v2 Skirmish — session created, opponent identified, timeline populated")
        self:Print("  [ ] 3v3 Rated — matchKey/roundKey stable, roster resolved, DM import")
        self:Print("  [ ] Solo Shuffle — round tracking, scout card, adaptation card")
        self:Print("  [ ] Inspect failure — graceful fallback, no error spam")
        self:Print("|cffFFD700Duel:|r")
        self:Print("  [ ] Accepted duel — session created, opponent identified")
        self:Print("  [ ] Cancelled duel — no stale session left")
        self:Print("  [ ] To-the-death — subcontext classified correctly")
        self:Print("|cffFFD700Dummy:|r")
        self:Print("  [ ] Single target — session captured, benchmark updated")
        self:Print("  [ ] Repeated pulls — each finalized, aggregates increment")
        self:Print("|cffFFD700General:|r")
        self:Print("  [ ] /reload during arena prep — no orphan sessions")
        self:Print("  [ ] Logout after match — session finalized before save")
        self:Print("  [ ] Legacy DB (v2-v5) — migration runs, UI renders without error")
        self:Print("  [ ] Mixed-version DB — v2+v3+v4+v5+v6 sessions load together")
        self:Print("|cffFFD700Data Quality:|r")
        self:Print("  [ ] ConfidencePill shows correct label for each session type")
        self:Print("  [ ] Provenance fields populated for new sessions")
        self:Print("  [ ] Timeline events have correct lanes")
        self:Print("|cff35c7e5--- End Regression Matrix ---|r")
        return
    end

    self:PrintCommandHelp()
end

function Addon:Initialize()
    self:InitializeCore()
    self:InitializeRuntime()
end

function Addon:InitializeCore()
    if self.coreInitialized then
        return
    end

    safeModuleCall(self, "CombatStore", "Initialize")
    self.coreInitialized = true
end

function Addon:InitializeRuntime()
    if self.runtimeInitialized then
        return
    end

    self:InitializeCore()

    self:TryRegisterSlashCommands()
    safeModuleCall(self, "UnitGraphService", "Initialize")
    safeModuleCall(self, "ArenaRoundTracker", "Initialize")
    safeModuleCall(self, "SpellAttributionPipeline", "Initialize")
    safeModuleCall(self, "CombatTracker", "Initialize")
    safeModuleCall(self, "SnapshotService", "Initialize")
    safeModuleCall(self, "DamageMeterService", "Initialize")
    safeModuleCall(self, "PartySyncService", "Initialize")
    -- MinimapButton: create and show/hide based on saved setting so the
    -- button appears immediately on login without needing /ca minimap.
    safeModuleCall(self, "MinimapButton", "Initialize")
    -- SettingsPanel: register the canvas category with the Blizzard
    -- Settings system at startup so it appears in Settings → Addons
    -- without the user needing to open it via /ca settings first.
    safeModuleCall(self, "SettingsPanel", "Initialize")

    self.runtimeInitialized = true
    self.initialized = true

    if not self.runtime.loginBannerShown then
        self.runtime.loginBannerShown = true
        self:PrintCommandHelp()
    end
end

function Addon:ShowExportFrame(text)
    if not self.exportFrame then
        local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        f:SetSize(520, 160)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            f:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
        title:SetText("CombatAnalytics Export")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

        local editBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        editBox:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
        editBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 40)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        f.editBox = editBox

        local selectBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        selectBtn:SetSize(100, 22)
        selectBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
        selectBtn:SetText("Select All")
        selectBtn:SetScript("OnClick", function()
            editBox:SetFocus()
            editBox:HighlightText()
        end)

        self.exportFrame = f
    end

    self.exportFrame.editBox:SetText(text or "")
    self.exportFrame:Show()
    self.exportFrame.editBox:SetFocus()
    self.exportFrame.editBox:HighlightText()
end

Addon:RegisterModule("Core", Addon)
